/* ============================================================================
   123_roster_leaders.sql - THE AUTO-ROSTER'S SHIFT LEADERS FOR EVERY METHOD, THE HOURS OF A SHIFT ON EACH DATE OF
   THE PLAN, AND THE NEW-HIRE RULE'S SETTING.

   WHAT WAS MISSING
   - Shift leaders existed only as Lead 1 / Lead 2 of the fixed-rotation list (script 116): at most two per branch,
     and a branch planned by the "Fair weekends" method had no way to name them without filling a whole rotation.
   - The planner measured the rest between two shifts with the hours a shift has TODAY, even for a date on which the
     shift ran other hours (script 117 dates a shift's hours).
   - The owner's rule "a new employee works 6 days every week during the first 3 months" had no setting.

   WHAT THIS SCRIPT ADDS (nothing existing is redefined)
   1. attendance.ROSTER_SHIFT_LEADER (BranchId, EmployeeId, CreatedAtUtc, CreatedByUserId; PK BranchId + EmployeeId):
      the branch's shift leaders, any number. The planner never puts two leaders on the same shift of a day when it
      can avoid it, whichever method plans.
   2. attendance.usp_AutoRoster_GetLeaders  @BranchId, @CallerUserId
        -> EmployeeId, FullName, IsStored, LeadSlot: the stored leaders UNION the rotation list's Lead 1 / Lead 2
           (script 116; the people whose branch today is this one, as usp_RosterRotation_Get lists them), one row
           per person - so the leads of a rotation keep counting as leaders. IsStored = on the branch's own list;
           LeadSlot = 'L1' / 'L2' when a lead of the rotation list.
      attendance.usp_AutoRoster_SaveLeaders @BranchId, @EmployeeIdsJson ([3, 5, 8]), @CallerUserId
        replaces the branch's own list (an empty array clears it; the rotation's leads are not touched). Refuses a
        person who is not in that branch - unless already on its list (a leader moved to another branch mid-month
        can be kept for the days still worked here, or taken off).
      Who may: as every auto-roster call - EMP_VIEW_ALL, or the branch's manager (the API: ATTENDANCE_VIEW to read,
      ATTENDANCE_MANAGE to save).
   3. attendance.usp_AutoRoster_GetShiftHours @FromDate, @ToDate
        -> ShiftId, EffectiveFrom, StartTime, EndTime, CrossesMidnight, BreakMinutes: every version of every shift
           in force at some point of [From, To] - the latest one starting on or before From, and each one starting
           inside. A shift with no version on or before From (no SHIFT_HOURS row at all: made by an older procedure)
           answers, as attendance.fn_ShiftHoursOn does, with its attendance.SHIFT row dated 2000-01-01.
   4. Setting RosterNewHireSixDayMonths (int, default 3, Section 'Roster'): during this many months from the hire date
      an employee works 6 days every week; then 6 and 5 in turn, starting with a 6-day week. Added when missing; a
      value HR already chose is kept.

   The API reads 2 and 3 after the planning context (AutoRosterRepository): while this script is not applied both
   lists are empty and the planner works as before (leaders from the rotation list only, today's shift hours).
   MARKER for the deploy guard: attendance.usp_AutoRoster_GetLeaders - the LAST object the script creates, so a run
   that stopped half-way still reads as missing.

   Idempotent. Apply: sqlcmd -C -I -b -d <database> -i docs/123_roster_leaders.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('attendance.ROSTER_ROTATION_MEMBER') IS NULL OR OBJECT_ID('attendance.SHIFT_HOURS') IS NULL
   OR OBJECT_ID('hr.fn_CallerScope') IS NULL OR COL_LENGTH('core.SETTING', 'Section') IS NULL
BEGIN
    RAISERROR('123_roster_leaders.sql: the fixed rotation (script 116) or the dated shift hours (script 117) is not in this database. Apply the earlier numbered scripts first. Nothing was applied.', 16, 1);
    SET NOEXEC ON;
END
GO

/* PRODUCTION HOLDS OBJECTS THE REPOSITORY NEVER HAD. Nothing below may replace one of them: an object that already
   carries one of this script's names must be this script's own - the table with its columns, a procedure whose text
   says "script 123". Anything else stops the script here, naming it, with nothing applied. */
DECLARE @foreign NVARCHAR(MAX) = NULL;
DECLARE @own TABLE (Name NVARCHAR(128) NOT NULL, OwnColumn NVARCHAR(128) NULL);      -- OwnColumn: a table, known by a column of ours
INSERT INTO @own (Name, OwnColumn) VALUES
    (N'attendance.ROSTER_SHIFT_LEADER', N'CreatedByUserId'),
    (N'attendance.usp_AutoRoster_GetShiftHours', NULL),
    (N'attendance.usp_AutoRoster_SaveLeaders', NULL),
    (N'attendance.usp_AutoRoster_GetLeaders', NULL);

SELECT @foreign = STRING_AGG(o.Name, N', ')
FROM @own o
WHERE OBJECT_ID(o.Name) IS NOT NULL
  AND (   (o.OwnColumn IS NOT NULL AND (COL_LENGTH(o.Name, o.OwnColumn) IS NULL OR COL_LENGTH(o.Name, N'BranchId') IS NULL
                                        OR COL_LENGTH(o.Name, N'EmployeeId') IS NULL))
       OR (o.OwnColumn IS NULL AND ISNULL(OBJECT_DEFINITION(OBJECT_ID(o.Name)), N'') NOT LIKE N'%script 123%'));

IF NULLIF(@foreign, N'') IS NOT NULL
BEGIN
    RAISERROR('123_roster_leaders.sql: this database already has object(s) with a name this script uses, which it did not create: %s. Nothing was applied; the script must be renamed around them first.', 16, 1, @foreign);
    SET NOEXEC ON;
END
GO

/* ---------------------------------------------------------------- 1. the table */
IF OBJECT_ID('attendance.ROSTER_SHIFT_LEADER') IS NULL
BEGIN
    CREATE TABLE attendance.ROSTER_SHIFT_LEADER (
        BranchId        INT          NOT NULL CONSTRAINT FK_ROSTER_SHIFT_LEADER_Branch REFERENCES hr.BRANCH (BranchId),
        EmployeeId      INT          NOT NULL CONSTRAINT FK_ROSTER_SHIFT_LEADER_Employee REFERENCES hr.EMPLOYEE (EmployeeId),
        CreatedAtUtc    DATETIME2(0) NOT NULL CONSTRAINT DF_ROSTER_SHIFT_LEADER_Created DEFAULT SYSUTCDATETIME(),
        CreatedByUserId INT          NULL,
        CONSTRAINT PK_ROSTER_SHIFT_LEADER PRIMARY KEY (BranchId, EmployeeId)
    );
    PRINT 'table attendance.ROSTER_SHIFT_LEADER created';
END
GO

/* ---------------------------------------------------------------- 2. the setting */
DECLARE @desc NVARCHAR(300) = N'New employees work 6 days every week for this many months from their hire date. After that the auto-roster gives them weeks of 6 and 5 working days in turn, starting with a 6-day week.';
IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'RosterNewHireSixDayMonths')
BEGIN
    INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, [Description], Section, SortOrder, ModifiedAt)
    VALUES ('RosterNewHireSixDayMonths', '3', 'int', @desc, 'Roster', 100, SYSUTCDATETIME());
    PRINT 'SETTINGS | Roster: RosterNewHireSixDayMonths added (3 months)';
END
/* a re-run keeps the value HR chose; the type, the description and the place on the Settings page follow this script */
UPDATE core.SETTING
SET DataType = 'int', [Description] = @desc, Section = 'Roster', SortOrder = 100
WHERE SettingKey = 'RosterNewHireSixDayMonths'
  AND (DataType <> 'int' OR ISNULL([Description], N'') <> @desc OR ISNULL(Section, '') <> 'Roster' OR ISNULL(SortOrder, -1) <> 100);
GO

/* ---------------------------------------------------------------- 3. the hours of the shifts over a period */
CREATE OR ALTER PROCEDURE attendance.usp_AutoRoster_GetShiftHours
    @FromDate DATE,
    @ToDate   DATE
AS
BEGIN
    /* script 123: every version of every shift in force at some point of [@FromDate, @ToDate], for the auto-roster's
       rest maths (a date is measured with the hours in force ON that date). A version runs from its EffectiveFrom to
       the day before the shift's next version. Shifts are not per branch: every shift, active or not. */
    SET NOCOUNT ON;
    IF @FromDate IS NULL OR @ToDate IS NULL OR @FromDate > @ToDate
    BEGIN RAISERROR('Give a real period: a first day on or before the last day.', 16, 1); RETURN 1; END

    SELECT h.ShiftId, h.EffectiveFrom, h.StartTime, h.EndTime, h.CrossesMidnight, h.BreakMinutes
    FROM attendance.SHIFT_HOURS h
    WHERE (h.EffectiveFrom > @FromDate AND h.EffectiveFrom <= @ToDate)                    -- starts inside the period
       OR h.EffectiveFrom = (SELECT MAX(x.EffectiveFrom) FROM attendance.SHIFT_HOURS x     -- in force on its first day
                             WHERE x.ShiftId = h.ShiftId AND x.EffectiveFrom <= @FromDate)
    UNION ALL
    /* no version on or before the first day: what attendance.fn_ShiftHoursOn answers then - the SHIFT row's hours */
    SELECT s.ShiftId, CAST('2000-01-01' AS DATE), s.StartTime, s.EndTime, ISNULL(s.CrossesMidnight, CAST(0 AS BIT)), ISNULL(s.BreakMinutes, 0)
    FROM attendance.SHIFT s
    WHERE NOT EXISTS (SELECT 1 FROM attendance.SHIFT_HOURS x WHERE x.ShiftId = s.ShiftId AND x.EffectiveFrom <= @FromDate)
    ORDER BY ShiftId, EffectiveFrom;
END;
GO

/* ---------------------------------------------------------------- 4. save the branch's shift leaders */
CREATE OR ALTER PROCEDURE attendance.usp_AutoRoster_SaveLeaders
    @BranchId        INT,
    @EmployeeIdsJson NVARCHAR(MAX),
    @CallerUserId    INT = NULL
AS
BEGIN
    /* script 123: replaces the branch's own list of shift leaders with the people of @EmployeeIdsJson ([3, 5, 8];
       an empty array clears it). The rotation list's Lead 1 / Lead 2 are not touched: they stay leaders as long as
       they are leads there. A leader already on the list keeps the date and the user who added them. */
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId)
    BEGIN RAISERROR('Branch not found.', 16, 1); RETURN 1; END
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    IF @SeesAll = 0 AND NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId AND ManagerEmployeeId = @CallerEmp)
    BEGIN RAISERROR('You can only plan rosters for the branches you manage.', 16, 1); RETURN 1; END

    IF @EmployeeIdsJson IS NULL OR LTRIM(RTRIM(@EmployeeIdsJson)) = N'' SET @EmployeeIdsJson = N'[]';
    IF ISJSON(@EmployeeIdsJson) = 0 OR LEFT(LTRIM(@EmployeeIdsJson), 1) <> N'['
    BEGIN RAISERROR('The shift leaders list could not be read.', 16, 1); RETURN 1; END

    DECLARE @ids TABLE (EmployeeId INT NULL);
    INSERT INTO @ids (EmployeeId)
    SELECT CASE WHEN j.[type] = 2 THEN TRY_CAST(j.[value] AS INT) END
    FROM OPENJSON(@EmployeeIdsJson) j;

    IF EXISTS (SELECT 1 FROM @ids WHERE EmployeeId IS NULL)
    BEGIN RAISERROR('Every line of the shift leaders list needs its employee.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM @ids x WHERE NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE e WHERE e.EmployeeId = x.EmployeeId AND e.IsDeleted = 0))
    BEGIN RAISERROR('Somebody on the shift leaders list was not found.', 16, 1); RETURN 1; END

    DECLARE @outsider NVARCHAR(200) = (
        SELECT TOP 1 e.FullName
        FROM @ids x
        JOIN hr.EMPLOYEE e ON e.EmployeeId = x.EmployeeId
        WHERE ISNULL(e.BranchId, -1) <> @BranchId
          AND NOT EXISTS (SELECT 1 FROM attendance.ROSTER_SHIFT_LEADER l WHERE l.BranchId = @BranchId AND l.EmployeeId = x.EmployeeId)
        ORDER BY e.FullName);
    IF @outsider IS NOT NULL
    BEGIN RAISERROR('%s is not in this branch: only its own people can be its shift leaders.', 16, 1, @outsider); RETURN 1; END

    BEGIN TRAN;
        DELETE l
        FROM attendance.ROSTER_SHIFT_LEADER l
        WHERE l.BranchId = @BranchId
          AND NOT EXISTS (SELECT 1 FROM @ids x WHERE x.EmployeeId = l.EmployeeId);

        INSERT INTO attendance.ROSTER_SHIFT_LEADER (BranchId, EmployeeId, CreatedByUserId)
        SELECT DISTINCT @BranchId, x.EmployeeId, @CallerUserId
        FROM @ids x
        WHERE NOT EXISTS (SELECT 1 FROM attendance.ROSTER_SHIFT_LEADER l WHERE l.BranchId = @BranchId AND l.EmployeeId = x.EmployeeId);
    COMMIT;

    SELECT COUNT(*) AS Leaders FROM attendance.ROSTER_SHIFT_LEADER WHERE BranchId = @BranchId;
END;
GO

/* ---------------------------------------------------------------- 5. read the branch's shift leaders (the MARKER) */
CREATE OR ALTER PROCEDURE attendance.usp_AutoRoster_GetLeaders
    @BranchId     INT,
    @CallerUserId INT = NULL
AS
BEGIN
    /* script 123: everybody the auto-roster keeps apart on a branch's days - its own list (ROSTER_SHIFT_LEADER) and
       the rotation list's Lead 1 / Lead 2 (script 116: members whose branch today is this one) - one row each. */
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId)
    BEGIN RAISERROR('Branch not found.', 16, 1); RETURN 1; END
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    IF @SeesAll = 0 AND NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId AND ManagerEmployeeId = @CallerEmp)
    BEGIN RAISERROR('You can only plan rosters for the branches you manage.', 16, 1); RETURN 1; END

    ;WITH stored AS (
        SELECT l.EmployeeId
        FROM attendance.ROSTER_SHIFT_LEADER l
        WHERE l.BranchId = @BranchId
    ), leads AS (
        SELECT m.EmployeeId, MIN(m.LeadSlot) AS LeadSlot
        FROM attendance.ROSTER_ROTATION_MEMBER m
        JOIN hr.EMPLOYEE e ON e.EmployeeId = m.EmployeeId
        WHERE e.BranchId = @BranchId AND e.IsDeleted = 0 AND m.LeadSlot IN ('L1', 'L2')
        GROUP BY m.EmployeeId
    ), people AS (
        SELECT EmployeeId FROM stored
        UNION
        SELECT EmployeeId FROM leads
    )
    SELECT p.EmployeeId, e.FullName,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM stored s WHERE s.EmployeeId = p.EmployeeId) THEN 1 ELSE 0 END AS BIT) AS IsStored,
           ld.LeadSlot
    FROM people p
    JOIN hr.EMPLOYEE e ON e.EmployeeId = p.EmployeeId
    LEFT JOIN leads ld ON ld.EmployeeId = p.EmployeeId
    WHERE e.IsDeleted = 0
    ORDER BY e.FullName, p.EmployeeId;
END;
GO

PRINT '123_roster_leaders.sql: shift leaders for every method, the shifts'' dated hours for the auto-roster and the new-hire setting - in place.';
GO

SET NOEXEC OFF;
GO
