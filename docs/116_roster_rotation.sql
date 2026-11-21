/* ============================================================================
   116_roster_rotation.sql - THE AUTO-ROSTER'S SECOND METHOD: A FIXED ROTATION (the owner's sheet rule).

   The auto-roster (script 96) chooses rest days by fairness. The owner rosters by a fixed rotation instead, kept in
   a spreadsheet until now. This script stores what that rule needs; the rule itself is in the API
   (Services/Attendance/AutoRoster/RotationRule.cs) and is offered in the auto-roster drawer as the method
   "Fixed rotation". Everything else of the auto-roster is unchanged: the preview, the manager's edits, the one
   atomic save, the approval.

   THE RULE, per employee and day (w = whole weeks since the branch's start date, a Monday; weekday 0 = Monday):
     - days off alternate week by week: two days off when (w + Group) is even, one day off when it is odd;
     - the days off MOVE two weekdays later every two weeks: shift = (2 x (w div 2)) mod 7;
         two-day week: off on (PairRestDay + shift) mod 7 and the next weekday;  one-day week: off on (SingleRestDay + shift) mod 7;
     - a working day is a morning or an evening: lead L1 works mornings on even weeks and evenings on odd weeks, lead
       L2 the opposite (so each shift has a lead); everybody else goes, in the order of the list, to the shift that
       has fewer people so far that day, and on a tie the weeks, days and rows take turns.

   Tables
     attendance.ROSTER_ROTATION          per branch: StartDate (a Monday), MorningShiftId, EveningShiftId
     attendance.ROSTER_ROTATION_MEMBER   per employee: RotationGroup (0/1), SingleRestDay, PairRestDay (0 = Monday ... 6 = Sunday),
                                         LeadSlot ('L1' | 'L2' | NULL), SortOrder (the order of the list)
   Procedures (the caller is the last parameter; who may: as every auto-roster call - EMP_VIEW_ALL, or the branch's manager)
     attendance.usp_RosterRotation_Get   @BranchId, @CallerUserId  -> (1) the branch's rotation, 0 or 1 row
                                                                      (2) its members: the branch's people of today, with what is stored
     attendance.usp_RosterRotation_Save  @BranchId, @StartDate, @MorningShiftId, @EveningShiftId, @MembersJson, @CallerUserId
         @MembersJson: [{ "employeeId", "group", "singleRestDay", "pairRestDay", "leadSlot", "sortOrder" }] - replaces the
         members of the branch's people; at most one L1 and one L2.
   MARKER of this script for the deploy guard: attendance.usp_RosterRotation_Get.

   Idempotent. Apply: sqlcmd -C -I -b -d <database> -i docs/116_roster_rotation.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('attendance.ROSTER_RHYTHM') IS NULL OR OBJECT_ID('hr.fn_CallerScope') IS NULL OR OBJECT_ID('attendance.SHIFT') IS NULL
BEGIN RAISERROR('116_roster_rotation.sql: apply script 96 (auto-roster) first - attendance.ROSTER_RHYTHM / hr.fn_CallerScope not found. Nothing was applied.', 16, 1); SET NOEXEC ON; END
GO

/* ------------------------- 1. the tables ------------------------- */
IF OBJECT_ID('attendance.ROSTER_ROTATION') IS NULL
BEGIN
    CREATE TABLE attendance.ROSTER_ROTATION (
        BranchId       INT          NOT NULL CONSTRAINT PK_ROSTER_ROTATION PRIMARY KEY
                                    CONSTRAINT FK_ROSTER_ROTATION_Branch REFERENCES hr.BRANCH (BranchId),
        StartDate      DATE         NOT NULL CONSTRAINT CK_ROSTER_ROTATION_Monday CHECK (DATEDIFF(DAY, '19000101', StartDate) % 7 = 0),  -- a Monday
        MorningShiftId INT          NOT NULL CONSTRAINT FK_ROSTER_ROTATION_Morning REFERENCES attendance.SHIFT (ShiftId),
        EveningShiftId INT          NOT NULL CONSTRAINT FK_ROSTER_ROTATION_Evening REFERENCES attendance.SHIFT (ShiftId),
        UpdatedAt      DATETIME2(3) NOT NULL CONSTRAINT DF_ROSTER_ROTATION_UpdatedAt DEFAULT SYSUTCDATETIME(),
        UpdatedBy      INT          NULL,
        CONSTRAINT CK_ROSTER_ROTATION_TwoShifts CHECK (MorningShiftId <> EveningShiftId)
    );
    PRINT 'table attendance.ROSTER_ROTATION created';
END
IF OBJECT_ID('attendance.ROSTER_ROTATION_MEMBER') IS NULL
BEGIN
    CREATE TABLE attendance.ROSTER_ROTATION_MEMBER (
        EmployeeId    INT          NOT NULL CONSTRAINT PK_ROSTER_ROTATION_MEMBER PRIMARY KEY
                                   CONSTRAINT FK_ROSTER_ROTATION_MEMBER_Employee REFERENCES hr.EMPLOYEE (EmployeeId),
        RotationGroup TINYINT      NOT NULL CONSTRAINT CK_ROSTER_ROTATION_MEMBER_Group CHECK (RotationGroup IN (0, 1)),
        SingleRestDay TINYINT      NOT NULL CONSTRAINT CK_ROSTER_ROTATION_MEMBER_Single CHECK (SingleRestDay BETWEEN 0 AND 6),   -- 0 = Monday
        PairRestDay   TINYINT      NOT NULL CONSTRAINT CK_ROSTER_ROTATION_MEMBER_Pair CHECK (PairRestDay BETWEEN 0 AND 6),       -- the first of the two
        LeadSlot      VARCHAR(2)   NULL     CONSTRAINT CK_ROSTER_ROTATION_MEMBER_Lead CHECK (LeadSlot IN ('L1', 'L2')),
        SortOrder     INT          NOT NULL CONSTRAINT DF_ROSTER_ROTATION_MEMBER_Sort DEFAULT 0,
        UpdatedAt     DATETIME2(3) NOT NULL CONSTRAINT DF_ROSTER_ROTATION_MEMBER_UpdatedAt DEFAULT SYSUTCDATETIME(),
        UpdatedBy     INT          NULL
    );
    PRINT 'table attendance.ROSTER_ROTATION_MEMBER created';
END
GO

/* ------------------------- 2. read ------------------------- */
CREATE OR ALTER PROCEDURE attendance.usp_RosterRotation_Get
    @BranchId     INT,
    @CallerUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId)
    BEGIN RAISERROR('Branch not found.', 16, 1); RETURN 1; END
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    IF @SeesAll = 0 AND NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId AND ManagerEmployeeId = @CallerEmp)
    BEGIN RAISERROR('You can only plan rosters for the branches you manage.', 16, 1); RETURN 1; END

    SELECT r.BranchId, r.StartDate, r.MorningShiftId, r.EveningShiftId
    FROM attendance.ROSTER_ROTATION r WHERE r.BranchId = @BranchId;

    /* The members: everybody the rule is stored for whose branch today is this one. People without a stored row are
       not listed here - the auto-roster's own staff list names them, and the page proposes their values. */
    SELECT m.EmployeeId, m.RotationGroup, m.SingleRestDay, m.PairRestDay, m.LeadSlot, m.SortOrder
    FROM attendance.ROSTER_ROTATION_MEMBER m
    JOIN hr.EMPLOYEE e ON e.EmployeeId = m.EmployeeId
    WHERE e.BranchId = @BranchId AND e.IsDeleted = 0
    ORDER BY m.SortOrder, m.EmployeeId;
END;
GO

/* ------------------------- 3. save ------------------------- */
CREATE OR ALTER PROCEDURE attendance.usp_RosterRotation_Save
    @BranchId       INT,
    @StartDate      DATE,
    @MorningShiftId INT,
    @EveningShiftId INT,
    @MembersJson    NVARCHAR(MAX),
    @CallerUserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId)
    BEGIN RAISERROR('Branch not found.', 16, 1); RETURN 1; END
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    IF @SeesAll = 0 AND NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId AND ManagerEmployeeId = @CallerEmp)
    BEGIN RAISERROR('You can only plan rosters for the branches you manage.', 16, 1); RETURN 1; END

    IF @StartDate IS NULL
    BEGIN RAISERROR('Choose the start date of the rotation.', 16, 1); RETURN 1; END
    IF DATEDIFF(DAY, '19000101', @StartDate) % 7 <> 0
    BEGIN RAISERROR('The rotation starts on a Monday.', 16, 1); RETURN 1; END
    IF @MorningShiftId IS NULL OR @EveningShiftId IS NULL
    BEGIN RAISERROR('Choose the morning shift and the evening shift.', 16, 1); RETURN 1; END
    IF @MorningShiftId = @EveningShiftId
    BEGIN RAISERROR('The morning and the evening shift must be two different shifts.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM (VALUES (@MorningShiftId), (@EveningShiftId)) v (Id)
               WHERE NOT EXISTS (SELECT 1 FROM attendance.SHIFT s WHERE s.ShiftId = v.Id AND s.IsActive = 1))
    BEGIN RAISERROR('Choose two active shifts.', 16, 1); RETURN 1; END

    IF @MembersJson IS NULL OR LTRIM(RTRIM(@MembersJson)) = N'' SET @MembersJson = N'[]';
    IF ISJSON(@MembersJson) = 0
    BEGIN RAISERROR('The rotation list could not be read.', 16, 1); RETURN 1; END

    DECLARE @m TABLE (EmployeeId INT NULL, RotationGroup INT NULL, SingleRestDay INT NULL, PairRestDay INT NULL, LeadSlot VARCHAR(10) NULL, SortOrder INT NULL);
    INSERT INTO @m (EmployeeId, RotationGroup, SingleRestDay, PairRestDay, LeadSlot, SortOrder)
    SELECT j.employeeId, j.[group], j.singleRestDay, j.pairRestDay, NULLIF(LTRIM(RTRIM(j.leadSlot)), ''), j.sortOrder
    FROM OPENJSON(@MembersJson) WITH (
        employeeId    INT         '$.employeeId',
        [group]       INT         '$.group',
        singleRestDay INT         '$.singleRestDay',
        pairRestDay   INT         '$.pairRestDay',
        leadSlot      VARCHAR(10) '$.leadSlot',
        sortOrder     INT         '$.sortOrder') j;

    IF EXISTS (SELECT 1 FROM @m WHERE EmployeeId IS NULL)
    BEGIN RAISERROR('Every line of the rotation list needs its employee.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM @m GROUP BY EmployeeId HAVING COUNT(*) > 1)
    BEGIN RAISERROR('An employee is on the rotation list once.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM @m x WHERE NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE e WHERE e.EmployeeId = x.EmployeeId AND e.BranchId = @BranchId AND e.IsDeleted = 0))
    BEGIN RAISERROR('Somebody on the rotation list is not in this branch.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM @m WHERE RotationGroup IS NULL OR RotationGroup NOT IN (0, 1))
    BEGIN RAISERROR('The group is A or B.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM @m WHERE SingleRestDay IS NULL OR SingleRestDay NOT BETWEEN 0 AND 6 OR PairRestDay IS NULL OR PairRestDay NOT BETWEEN 0 AND 6)
    BEGIN RAISERROR('A day off is a weekday, Monday to Sunday.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM @m WHERE LeadSlot IS NOT NULL AND LeadSlot NOT IN ('L1', 'L2'))
    BEGIN RAISERROR('A lead is L1 or L2.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM @m WHERE LeadSlot IS NOT NULL GROUP BY LeadSlot HAVING COUNT(*) > 1)
    BEGIN RAISERROR('There is one lead L1 and one lead L2 at most.', 16, 1); RETURN 1; END

    BEGIN TRAN;
        MERGE attendance.ROSTER_ROTATION AS t
        USING (SELECT @BranchId AS BranchId) AS s ON t.BranchId = s.BranchId
        WHEN MATCHED THEN UPDATE SET StartDate = @StartDate, MorningShiftId = @MorningShiftId, EveningShiftId = @EveningShiftId,
                                     UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @CallerUserId
        WHEN NOT MATCHED THEN INSERT (BranchId, StartDate, MorningShiftId, EveningShiftId, UpdatedBy)
                              VALUES (@BranchId, @StartDate, @MorningShiftId, @EveningShiftId, @CallerUserId);

        /* the branch's people of today: their stored lines are replaced by the list (a person left out has no line) */
        DELETE mem
        FROM attendance.ROSTER_ROTATION_MEMBER mem
        JOIN hr.EMPLOYEE e ON e.EmployeeId = mem.EmployeeId
        WHERE e.BranchId = @BranchId;

        INSERT INTO attendance.ROSTER_ROTATION_MEMBER (EmployeeId, RotationGroup, SingleRestDay, PairRestDay, LeadSlot, SortOrder, UpdatedBy)
        SELECT x.EmployeeId, x.RotationGroup, x.SingleRestDay, x.PairRestDay, x.LeadSlot, ISNULL(x.SortOrder, 0), @CallerUserId
        FROM @m x;
    COMMIT;

    SELECT (SELECT COUNT(*) FROM @m) AS Members;
END;
GO

PRINT '116_roster_rotation.sql: the fixed rotation of the auto-roster - in place.';
GO

SET NOEXEC OFF;
GO
