/* ============================================================================
   96_auto_roster.sql — the auto-roster (6/5 rhythm, fair weekends): what it keeps, what it reads,
   and the one procedure it saves through. The specification is docs/AUTO_ROSTER.md.

   THE IDEA. One action per branch and month drafts the roster: every employee alternates a 6-day
   week (1 rest day) and a 5-day week (2 rest days), Saturdays and Sundays off are shared fairly, and
   leaves, public holidays, locks and the manager's own edits are respected. The planning is pure C#
   (Services/Attendance/AutoRoster); the database only hands it everything in one read
   (usp_AutoRoster_GetContext) and takes the reviewed draft back in one transaction
   (usp_AutoRoster_Commit). Nothing is planned or saved on its own; the month is then submitted for
   approval exactly as before.

   TABLES
     attendance.ROSTER_RHYTHM         per employee: the Monday the 6/5 alternation is counted from and
                                      whether that week was a 6- or a 5-day week, so the rhythm never
                                      restarts at a month end; OnRotation = 0 keeps someone out of the
                                      planning (shown, never planned). A row may hold the flag alone
                                      (no anchor yet): the planner then starts the rhythm afresh.
     attendance.ROSTER_CELL           per employee-day: what the generator last wrote (AutoState 'work' |
                                      'rest' | 'none', AutoShiftId), why (ReasonCode), and the manager's
                                      pin. A day is AUTO only while SHIFT_ASSIGNMENT still equals
                                      AutoState/AutoShiftId ('none' = no row): any other writer (Set day,
                                      copy, swap) makes it manual without having to know this table.
     attendance.ROSTER_AUTO_RUN       one row per save: branch, month, mode, the drawer's parameters and
                                      the counts — the audit trail and the branch's "last used" settings.
     attendance.STAFFING_REQUIREMENT  minimum / target on duty per branch and weekday (NULL = every
                                      day), optionally per shift; a weekday row beats an every-day row.
   SETTINGS (core.SETTING, Section 'Roster'): RosterRhythmStart, RosterHolidayCountsAsRest,
     RosterMaxConsecutiveWorkDays, RosterPreferredMaxConsecutiveWorkDays, RosterFairnessLookbackWeeks,
     RosterPairRestDays, RosterPatternRestDays, RosterMinHoursBetweenShifts, RosterMinWeeklyRestHours.
     A re-run keeps the values HR chose and refreshes the descriptions.

   PROCEDURES — the caller is always the last parameter. Who may plan a branch: hr.fn_CallerScope
   (EMP_VIEW_ALL), or the branch's manager (hr.BRANCH.ManagerEmployeeId); an employee's branch is the
   one they belong to ON the day (hr.fn_EmployeeBranchOn).
     usp_AutoRoster_GetContext            everything the planner reads: 15 result sets, one call
     usp_AutoRoster_Commit                saves the reviewed cells. The rows the preview was made from are
                                          re-read under lock; only the cells that really change go through
                                          usp_Roster_AssertEditable and are written, so an unchanged day
                                          never marks an approved month "changed since approval". Deletes
                                          included: a public holiday off is NO row.
     usp_RosterCell_SetPin / _GetRange    the pin ("keep when regenerating") and the grid's cell overlay
     usp_StaffingRequirement_GetByBranch / _Save, usp_RosterRhythm_Save
   NOTHING EXISTING IS ALTERED: SHIFT_ASSIGNMENT, its trigger, the guard and the other generators stay
   as they are.

   Every refusal is RAISERROR(msg,16,1) + RETURN 1 (ROLLBACK first inside a transaction).
   Idempotent: IF NOT EXISTS / CREATE OR ALTER. Apply with sqlcmd -C -I (test database: apply-sql-test.sh).
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ───────────────────────── 1. tables ───────────────────────── */

/* the 6/5 rhythm of one employee: a week an even number of weeks from AnchorWeekStart has AnchorWorkDays working
   days, the weeks in between the other number (11 - AnchorWorkDays).
   The anchor is NULL (both columns) for someone taken off rotation before any rhythm was planned for them. A made-up
   anchor would be read back as their real rhythm when they return, and an arbitrary Monday would then decide whether
   their first planned week has 6 or 5 working days; with none, the planner applies its own first-week rule (D2). */
IF OBJECT_ID('attendance.ROSTER_RHYTHM') IS NULL
BEGIN
    CREATE TABLE attendance.ROSTER_RHYTHM (
        EmployeeId      INT          NOT NULL,
        AnchorWeekStart DATE         NULL,
        AnchorWorkDays  TINYINT      NULL,
        OnRotation      BIT          NOT NULL CONSTRAINT DF_RosterRhythm_OnRotation DEFAULT (1),
        UpdatedAt       DATETIME2(3) NOT NULL CONSTRAINT DF_RosterRhythm_UpdatedAt  DEFAULT (SYSUTCDATETIME()),
        UpdatedBy       INT          NULL,
        CONSTRAINT PK_ROSTER_RHYTHM PRIMARY KEY (EmployeeId),
        CONSTRAINT FK_RosterRhythm_Employee FOREIGN KEY (EmployeeId) REFERENCES hr.EMPLOYEE (EmployeeId),
        CONSTRAINT CK_RosterRhythm_Monday   CHECK (DATEDIFF(DAY, '19000101', AnchorWeekStart) % 7 = 0),   -- 1 Jan 1900 was a Monday
        CONSTRAINT CK_RosterRhythm_WorkDays CHECK (AnchorWorkDays IN (5, 6)),
        CONSTRAINT CK_RosterRhythm_Anchor   CHECK ((AnchorWeekStart IS NULL AND AnchorWorkDays IS NULL)
                                                   OR (AnchorWeekStart IS NOT NULL AND AnchorWorkDays IS NOT NULL))
    );
END
GO
/* a table made by an earlier draft of this script had the anchor NOT NULL; the CHECKs on the columns must go while
   the columns change */
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('attendance.ROSTER_RHYTHM') AND name = 'AnchorWeekStart' AND is_nullable = 0)
BEGIN
    ALTER TABLE attendance.ROSTER_RHYTHM DROP CONSTRAINT CK_RosterRhythm_Monday, CK_RosterRhythm_WorkDays;
    ALTER TABLE attendance.ROSTER_RHYTHM ALTER COLUMN AnchorWeekStart DATE NULL;
    ALTER TABLE attendance.ROSTER_RHYTHM ALTER COLUMN AnchorWorkDays TINYINT NULL;
    ALTER TABLE attendance.ROSTER_RHYTHM ADD
        CONSTRAINT CK_RosterRhythm_Monday   CHECK (DATEDIFF(DAY, '19000101', AnchorWeekStart) % 7 = 0),
        CONSTRAINT CK_RosterRhythm_WorkDays CHECK (AnchorWorkDays IN (5, 6));
END
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_RosterRhythm_Anchor' AND parent_object_id = OBJECT_ID('attendance.ROSTER_RHYTHM'))
    ALTER TABLE attendance.ROSTER_RHYTHM ADD
        CONSTRAINT CK_RosterRhythm_Anchor CHECK ((AnchorWeekStart IS NULL AND AnchorWorkDays IS NULL)
                                                 OR (AnchorWeekStart IS NOT NULL AND AnchorWorkDays IS NOT NULL));
GO

/* what the generator last wrote on a day, why, and the manager's pin. No foreign key on AutoShiftId: a shift that
   was planned once must stay deletable. */
IF OBJECT_ID('attendance.ROSTER_CELL') IS NULL
BEGIN
    CREATE TABLE attendance.ROSTER_CELL (
        EmployeeId  INT           NOT NULL,
        WorkDate    DATE          NOT NULL,
        AutoState   VARCHAR(10)   NULL,         -- what the generator wrote; NULL = manual
        AutoShiftId INT           NULL,
        AutoRunId   INT           NULL,
        ReasonCode  VARCHAR(40)   NULL,
        ReasonArgs  NVARCHAR(400) NULL,
        IsPinned    BIT           NOT NULL CONSTRAINT DF_RosterCell_IsPinned  DEFAULT (0),
        PinnedBy    INT           NULL,
        PinnedAt    DATETIME2(3)  NULL,
        UpdatedAt   DATETIME2(3)  NOT NULL CONSTRAINT DF_RosterCell_UpdatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_ROSTER_CELL PRIMARY KEY (EmployeeId, WorkDate),
        CONSTRAINT FK_RosterCell_Employee FOREIGN KEY (EmployeeId) REFERENCES hr.EMPLOYEE (EmployeeId),
        CONSTRAINT CK_RosterCell_AutoState CHECK (AutoState IN ('work', 'rest', 'none'))
    );
END
GO

IF OBJECT_ID('attendance.ROSTER_AUTO_RUN') IS NULL
BEGIN
    CREATE TABLE attendance.ROSTER_AUTO_RUN (
        RunId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ROSTER_AUTO_RUN PRIMARY KEY,
        BranchId     INT           NOT NULL,
        MonthDate    DATE          NOT NULL,
        Mode         VARCHAR(20)   NOT NULL,
        ParamsJson   NVARCHAR(MAX) NULL,
        RowsInserted INT           NULL,
        RowsUpdated  INT           NULL,
        RowsDeleted  INT           NULL,
        IssueCount   INT           NULL,
        CreatedBy    INT           NULL,
        CreatedAt    DATETIME2(3)  NOT NULL CONSTRAINT DF_RosterAutoRun_CreatedAt DEFAULT (SYSUTCDATETIME())
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('attendance.ROSTER_AUTO_RUN') AND name = 'IX_RosterAutoRun_Branch')
    CREATE INDEX IX_RosterAutoRun_Branch ON attendance.ROSTER_AUTO_RUN (BranchId, RunId);
GO

/* precedence when the planner reads it: a weekday row beats an every-day row (same ShiftId) */
IF OBJECT_ID('attendance.STAFFING_REQUIREMENT') IS NULL
BEGIN
    CREATE TABLE attendance.STAFFING_REQUIREMENT (
        StaffingRequirementId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_STAFFING_REQUIREMENT PRIMARY KEY,
        BranchId     INT     NOT NULL,
        DayOfWeek    TINYINT NULL,          -- 1 = Monday .. 7 = Sunday (ISO); NULL = every day
        ShiftId      INT     NULL,          -- NULL = any shift
        MinOnDuty    INT     NOT NULL,
        TargetOnDuty INT     NULL,
        IsActive     BIT     NOT NULL CONSTRAINT DF_StaffingReq_IsActive DEFAULT (1),
        CONSTRAINT FK_StaffingReq_Branch FOREIGN KEY (BranchId) REFERENCES hr.BRANCH (BranchId),
        CONSTRAINT FK_StaffingReq_Shift  FOREIGN KEY (ShiftId)  REFERENCES attendance.SHIFT (ShiftId),
        CONSTRAINT CK_StaffingReq_Day    CHECK (DayOfWeek BETWEEN 1 AND 7),
        CONSTRAINT CK_StaffingReq_Min    CHECK (MinOnDuty >= 0),
        CONSTRAINT CK_StaffingReq_Target CHECK (TargetOnDuty IS NULL OR TargetOnDuty >= MinOnDuty)
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('attendance.STAFFING_REQUIREMENT') AND name = 'IX_StaffingReq_Branch')
    CREATE INDEX IX_StaffingReq_Branch ON attendance.STAFFING_REQUIREMENT (BranchId) INCLUDE (DayOfWeek, ShiftId, MinOnDuty, TargetOnDuty, IsActive);
GO

/* ───────────────────────── 2. settings (Section 'Roster') ───────────────────────── */
DECLARE @s TABLE (SettingKey VARCHAR(60), SettingValue NVARCHAR(200), DataType VARCHAR(60), [Description] NVARCHAR(300), Section VARCHAR(30), SortOrder INT);
INSERT INTO @s (SettingKey, SettingValue, DataType, [Description], Section, SortOrder) VALUES
 ('RosterRhythmStart', 'Aligned', 'string',
  N'Aligned = every employee''s first planned week is a 6-day week, then 5, 6, 5... Staggered = half the team starts on a 5-day week, so the number on duty is even week to week. Used only for employees whose rhythm is not stored yet.', 'Roster', 10),
 ('RosterHolidayCountsAsRest', '0', 'bool',
  N'0 = a public holiday off is an extra day off: the week still gets its rest days (1 in a 6-day week, 2 in a 5-day week). 1 = a holiday off counts as one of the week''s rest days.', 'Roster', 20),
 ('RosterMaxConsecutiveWorkDays', '7', 'int',
  N'The auto-roster never plans more working days in a row than this; a longer run already on the roster is reported. Rest days, leave days and holidays off break a run.', 'Roster', 30),
 ('RosterPreferredMaxConsecutiveWorkDays', '6', 'int',
  N'The auto-roster tries to keep working runs at or below this many days. A longer run, up to the hard limit, is allowed and shown as information.', 'Roster', 40),
 ('RosterFairnessLookbackWeeks', '26', 'int',
  N'How many weeks of saved roster the auto-roster looks back over to share Saturdays and Sundays off fairly: whoever has had fewer weekend days off than their share gets the next ones.', 'Roster', 50),
 ('RosterPairRestDays', '1', 'bool',
  N'1 = in a 5-day week the auto-roster prefers the two rest days next to each other. 0 = no preference: they are spread to keep the number on duty level.', 'Roster', 60),
 ('RosterPatternRestDays', 'Preference', 'string',
  N'How the auto-roster uses the rest days of an employee''s weekly pattern. Preference = preferred for the weekday rest, but fairness and the 6/5 rhythm come first. Unavailable = they are always rest days.', 'Roster', 70),
 ('RosterMinHoursBetweenShifts', '11', 'int',
  N'Fewer hours than this between the end of one shift and the start of the next is a warning in the auto-roster preview (for example a closing shift followed by an opening one).', 'Roster', 80),
 ('RosterMinWeeklyRestHours', '36', 'int',
  N'A week whose longest rest, from the end of one shift to the start of the next, is shorter than this many hours is a warning in the auto-roster preview.', 'Roster', 90);

INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, [Description], Section, SortOrder, ModifiedAt)
SELECT s.SettingKey, s.SettingValue, s.DataType, s.[Description], s.Section, s.SortOrder, SYSUTCDATETIME()
FROM @s s
WHERE NOT EXISTS (SELECT 1 FROM core.SETTING x WHERE x.SettingKey = s.SettingKey);
PRINT CONCAT('SETTINGS | Roster: ', @@ROWCOUNT, ' new key(s)');

/* a re-run keeps the value HR chose; the type, the description and the place on the Settings page follow this script */
UPDATE x
SET x.DataType = s.DataType, x.[Description] = s.[Description], x.Section = s.Section, x.SortOrder = s.SortOrder
FROM core.SETTING x
JOIN @s s ON s.SettingKey = x.SettingKey;
GO

/* ───────────────────────── 3. attendance.usp_AutoRoster_GetContext ───────────────────────── */
/* Everything the planner reads, in one call, as 15 result sets in a fixed order:
     1 Header  2 Settings  3 Staff  4 StaffDays  5 Rows  6 Locks  7 Holidays  8 HolidaysWorked  9 Leaves
     10 Shifts  11 Patterns  12 Rhythm  13 Cells  14 Staffing  15 LastRun
   Window = the Monday on/before the 1st to the Sunday on/after the last day, so the weeks that straddle a month
   end are planned whole. History = @LookbackWeeks whole weeks before the window (weekend fairness, rhythm). */
CREATE OR ALTER PROCEDURE attendance.usp_AutoRoster_GetContext
    @BranchId      INT,
    @MonthDate     DATE,                -- any day of the month; normalised to the 1st
    @LookbackWeeks INT = NULL,          -- NULL = the setting RosterFairnessLookbackWeeks
    @CallerUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @MonthDate IS NULL
    BEGIN RAISERROR('Give a real month.', 16, 1); RETURN 1; END
    SET @MonthDate = DATEFROMPARTS(YEAR(@MonthDate), MONTH(@MonthDate), 1);

    IF NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId)
    BEGIN RAISERROR('Branch not found.', 16, 1); RETURN 1; END
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    IF @SeesAll = 0 AND NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId AND ManagerEmployeeId = @CallerEmp)
    BEGIN RAISERROR('You can only plan rosters for the branches you manage.', 16, 1); RETURN 1; END

    IF @LookbackWeeks IS NULL
        SET @LookbackWeeks = TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'RosterFairnessLookbackWeeks') AS INT);
    SET @LookbackWeeks = ISNULL(@LookbackWeeks, 26);
    IF @LookbackWeeks < 0  SET @LookbackWeeks = 0;
    IF @LookbackWeeks > 52 SET @LookbackWeeks = 52;      -- a year of history is plenty, and keeps the reads small

    DECLARE @Today       DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @MonthTo     DATE = EOMONTH(@MonthDate);
    DECLARE @WindowFrom  DATE = DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @MonthDate) % 7), @MonthDate);     -- 1 Jan 1900 was a Monday
    DECLARE @WindowTo    DATE = DATEADD(DAY, 6 - (DATEDIFF(DAY, '19000101', @MonthTo) % 7), @MonthTo);
    DECLARE @HistoryFrom DATE = DATEADD(DAY, -7 * @LookbackWeeks, @WindowFrom);
    /* the days after the window a run can join (the cap, clamped 1..31 like the API): rows and leave are read
       that far, so the cap and the 6/5 hold across the join with the next month */
    DECLARE @Cap INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'RosterMaxConsecutiveWorkDays') AS INT), 7);
    IF @Cap < 1  SET @Cap = 1;
    IF @Cap > 31 SET @Cap = 31;
    DECLARE @HorizonTo   DATE = DATEADD(DAY, @Cap, @WindowTo);
    /* holiday cover goes to whoever worked the fewest holidays in the last 12 months; the history needs the
       holidays too (a holiday off is not a weekend rested), so the list starts at the earlier of the two */
    DECLARE @YearBefore  DATE = DATEADD(MONTH, -12, @WindowFrom);
    DECLARE @HolidayFrom DATE = CASE WHEN @HistoryFrom < @YearBefore THEN @HistoryFrom ELSE @YearBefore END;

    DECLARE @MonthStatus VARCHAR(30), @OpenRid INT;
    SELECT TOP 1 @MonthStatus = rm.[Status]
    FROM attendance.ROSTER_MONTH rm
    WHERE rm.BranchId = @BranchId AND rm.MonthDate = @MonthDate
    ORDER BY rm.RosterMonthId DESC;
    SELECT TOP 1 @OpenRid = ri.RequestInstanceId
    FROM workflow.ROSTER_APPROVAL ra
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
    WHERE ra.BranchId = @BranchId AND ra.MonthDate = @MonthDate
      AND ri.[Status] IN ('Draft', 'Pending', 'OnHold')
    ORDER BY ri.RequestInstanceId DESC;

    /* every day from the history start to the window end: whole weeks, Monday first */
    CREATE TABLE #cal (d DATE NOT NULL PRIMARY KEY);
    ;WITH weeks AS (
        SELECT @HistoryFrom AS w
        UNION ALL
        SELECT DATEADD(DAY, 7, w) FROM weeks WHERE DATEADD(DAY, 7, w) <= @WindowTo
    )
    INSERT INTO #cal (d)
    SELECT DATEADD(DAY, o.n, wk.w)
    FROM weeks wk
    CROSS JOIN (VALUES (0), (1), (2), (3), (4), (5), (6)) o (n)
    OPTION (MAXRECURSION 400);

    /* fn_EmployeeBranchOn only ever answers a branch from the employee's history or the employee record, so
       nobody else can belong to this branch on any day: this keeps the per-day calls below to the few who can */
    CREATE TABLE #cand (EmployeeId INT NOT NULL PRIMARY KEY, HireDate DATE NOT NULL, TerminationDate DATE NULL);
    INSERT INTO #cand (EmployeeId, HireDate, TerminationDate)
    SELECT e.EmployeeId, e.HireDate, e.TerminationDate
    FROM hr.EMPLOYEE e
    WHERE e.IsDeleted = 0
      AND e.HireDate <= @WindowTo
      AND (e.TerminationDate IS NULL OR e.TerminationDate >= @WindowFrom)
      AND (e.BranchId = @BranchId
           OR EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY h WHERE h.EmployeeId = e.EmployeeId AND h.BranchId = @BranchId));

    /* employed days and the branch of each; the staff are those in this branch on at least one window day */
    CREATE TABLE #sd (EmployeeId INT NOT NULL, WorkDate DATE NOT NULL, BranchId INT NULL, PRIMARY KEY (EmployeeId, WorkDate));
    INSERT INTO #sd (EmployeeId, WorkDate, BranchId)
    SELECT c.EmployeeId, k.d, hr.fn_EmployeeBranchOn(c.EmployeeId, k.d)
    FROM #cand c
    JOIN #cal k ON k.d >= c.HireDate AND (c.TerminationDate IS NULL OR k.d <= c.TerminationDate);

    CREATE TABLE #staff (EmployeeId INT NOT NULL PRIMARY KEY);
    INSERT INTO #staff (EmployeeId)
    SELECT DISTINCT sd.EmployeeId
    FROM #sd sd
    WHERE sd.WorkDate BETWEEN @WindowFrom AND @WindowTo AND sd.BranchId = @BranchId;

    DELETE sd FROM #sd sd WHERE NOT EXISTS (SELECT 1 FROM #staff s WHERE s.EmployeeId = sd.EmployeeId);

    /* 1. Header */
    SELECT b.BranchId, b.Name AS BranchName, @MonthDate AS MonthDate, @WindowFrom AS WindowFrom, @WindowTo AS WindowTo,
           @HistoryFrom AS HistoryFrom, @Today AS Today, @MonthStatus AS MonthStatus, @OpenRid AS OpenRequestId
    FROM hr.BRANCH b
    WHERE b.BranchId = @BranchId;

    /* 2. Settings */
    SELECT st.SettingKey, st.SettingValue
    FROM core.SETTING st
    WHERE st.SettingKey LIKE 'Roster%'
    ORDER BY st.SettingKey;

    /* 3. Staff — off-rotation people included: they are shown, never planned */
    SELECT e.EmployeeId, e.FullName, e.PositionId, p.Title AS Position, e.HireDate, e.TerminationDate
    FROM #staff s
    JOIN hr.EMPLOYEE e ON e.EmployeeId = s.EmployeeId
    LEFT JOIN hr.[POSITION] p ON p.PositionId = e.PositionId
    ORDER BY e.FullName, e.EmployeeId;

    /* 4. StaffDays — every employed day of the staff, history and window, with the branch of that day */
    SELECT sd.EmployeeId, sd.WorkDate, sd.BranchId
    FROM #sd sd
    ORDER BY sd.EmployeeId, sd.WorkDate;

    /* 5. Rows — in EVERY branch: a week is counted whole even when part of it was worked elsewhere, and the
          branch was authorised above. History, window and the days after it up to the horizon. */
    SELECT sa.EmployeeId, sa.WorkDate, sa.ShiftId, sa.IsRestDay
    FROM attendance.SHIFT_ASSIGNMENT sa
    JOIN #staff s ON s.EmployeeId = sa.EmployeeId
    WHERE sa.WorkDate BETWEEN @HistoryFrom AND @HorizonTo
    ORDER BY sa.EmployeeId, sa.WorkDate;

    /* 6. Locks — target-month days the planner never changes, in any month state: paid, already judged by
          attendance, or before today in Beirut (the guard alone locks the past only in an approved month) */
    SELECT x.EmployeeId, x.WorkDate, x.Reason
    FROM (
        SELECT sd.EmployeeId, sd.WorkDate,
               CASE WHEN payroll.fn_IsPeriodPaid(sd.EmployeeId, sd.WorkDate) = 1 THEN 'Paid'
                    WHEN EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD ar
                                 WHERE ar.EmployeeId = sd.EmployeeId AND ar.WorkDate = sd.WorkDate) THEN 'Recorded'
                    WHEN sd.WorkDate < @Today THEN 'Past' END AS Reason
        FROM #sd sd
        WHERE sd.WorkDate BETWEEN @MonthDate AND @MonthTo) x
    WHERE x.Reason IS NOT NULL
    ORDER BY x.EmployeeId, x.WorkDate;

    /* 7. Holidays — of every branch, or of this one */
    SELECT h.HolidayDate, h.BranchId, h.IsPaid, h.Name
    FROM core.HOLIDAY h
    WHERE h.HolidayDate BETWEEN @HolidayFrom AND @WindowTo
      AND (h.BranchId IS NULL OR h.BranchId = @BranchId)
    ORDER BY h.HolidayDate, h.BranchId;

    /* 8. HolidaysWorked — working rows on those holidays in the 12 months before the window. Set-based on
          purpose: a calendar over a year plus the window would pass MAXRECURSION 400. A date that is both an
          all-branch and a branch holiday counts once. */
    SELECT sa.EmployeeId, COUNT(*) AS Days
    FROM attendance.SHIFT_ASSIGNMENT sa
    JOIN #staff s ON s.EmployeeId = sa.EmployeeId
    WHERE sa.WorkDate >= @YearBefore AND sa.WorkDate < @WindowFrom
      AND sa.IsRestDay = 0 AND sa.ShiftId IS NOT NULL
      AND EXISTS (SELECT 1 FROM core.HOLIDAY h
                  WHERE h.HolidayDate = sa.WorkDate AND (h.BranchId IS NULL OR h.BranchId = @BranchId))
    GROUP BY sa.EmployeeId
    ORDER BY sa.EmployeeId;

    /* 9. Leaves — approved, pending and on hold: a leave still waiting is never planned as a rest day either */
    SELECT lr.EmployeeId, lr.FromDate, lr.ToDate, lr.HalfDay, ri.[Status] AS [Status], lt.IsPaid
    FROM workflow.LEAVE_REQUEST lr
    JOIN #staff s ON s.EmployeeId = lr.EmployeeId
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
    JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId = lr.LeaveTypeId
    WHERE ri.[Status] IN ('Approved', 'Pending', 'OnHold')
      AND lr.FromDate <= @HorizonTo AND lr.ToDate >= @HistoryFrom
    ORDER BY lr.EmployeeId, lr.FromDate;

    /* 10. Shifts — all of them: history rows can name a shift that is no longer active */
    SELECT sh.ShiftId, sh.Name, sh.StartTime, sh.EndTime, sh.CrossesMidnight, sh.BreakMinutes, sh.IsActive
    FROM attendance.SHIFT sh
    ORDER BY sh.ShiftId;

    /* 11. Patterns */
    SELECT p.EmployeeId, p.DayOfWeek, p.ShiftId, p.IsRestDay
    FROM attendance.EMPLOYEE_SHIFT_PATTERN p
    JOIN #staff s ON s.EmployeeId = p.EmployeeId
    WHERE p.IsActive = 1
    ORDER BY p.EmployeeId, p.DayOfWeek;

    /* 12. Rhythm — AnchorWeekStart / AnchorWorkDays NULL: only the on-rotation flag is stored, no rhythm yet */
    SELECT r.EmployeeId, r.AnchorWeekStart, r.AnchorWorkDays, r.OnRotation
    FROM attendance.ROSTER_RHYTHM r
    JOIN #staff s ON s.EmployeeId = r.EmployeeId
    ORDER BY r.EmployeeId;

    /* 13. Cells — as stored; whether a day is still AUTO is decided against Rows */
    SELECT c.EmployeeId, c.WorkDate, c.AutoState, c.AutoShiftId, c.ReasonCode, c.IsPinned
    FROM attendance.ROSTER_CELL c
    JOIN #staff s ON s.EmployeeId = c.EmployeeId
    WHERE c.WorkDate BETWEEN @WindowFrom AND @WindowTo
    ORDER BY c.EmployeeId, c.WorkDate;

    /* 14. Staffing */
    SELECT sr.DayOfWeek, sr.ShiftId, sr.MinOnDuty, sr.TargetOnDuty
    FROM attendance.STAFFING_REQUIREMENT sr
    WHERE sr.BranchId = @BranchId AND sr.IsActive = 1
    ORDER BY ISNULL(sr.DayOfWeek, 0), ISNULL(sr.ShiftId, 0);

    /* 15. LastRun — the branch's latest save, whatever the month: the drawer opens on those parameters */
    SELECT TOP 1 ar.RunId, ar.MonthDate, ar.Mode, ar.ParamsJson, ar.CreatedAt
    FROM attendance.ROSTER_AUTO_RUN ar
    WHERE ar.BranchId = @BranchId
    ORDER BY ar.RunId DESC;

    RETURN 0;
END;
GO

/* ───────────────────────── 4. attendance.usp_AutoRoster_Commit ───────────────────────── */
/* Saves the reviewed draft of one branch-month in one transaction: all of it, or none of it.
   @ChangesJson: [{ employeeId, workDate, action ("upsert" | "delete"), shiftId, isRestDay, expectedExists,
                    expectedShiftId, expectedIsRestDay, isAuto, reasonCode, isPinned }]   (reasonArgs optional)
   @RhythmJson:  [{ employeeId, anchorWeekStart, anchorWorkDays, onRotation,
                    expectedAnchorWeekStart, expectedAnchorWorkDays, expectedOnRotation }]   (expected* optional)
   The expected* fields are the row the preview was made from; a day whose row has moved since is not saved over
   somebody else's edit. For the rhythm they are the stored ROSTER_RHYTHM row (anchor NULL = none; no row = on
   rotation, no anchor), flat or nested as expected: { anchorWeekStart, anchorWorkDays, onRotation }; a rhythm row
   without expectedOnRotation is not checked. Result: RunId, RowsInserted, RowsUpdated, RowsDeleted. */
CREATE OR ALTER PROCEDURE attendance.usp_AutoRoster_Commit
    @BranchId     INT,
    @MonthDate    DATE,                     -- any day of the month; normalised to the 1st
    @Mode         VARCHAR(20),              -- FillEmpty | ReplanAuto | ReplanAll (kept with the run)
    @ChangesJson  NVARCHAR(MAX),
    @RhythmJson   NVARCHAR(MAX) = NULL,
    @ParamsJson   NVARCHAR(MAX) = NULL,     -- the drawer's request: the branch's "last used" parameters
    @IssueCount   INT = 0,
    @CallerUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @MonthDate IS NULL
    BEGIN RAISERROR('Give a real month.', 16, 1); RETURN 1; END
    SET @MonthDate = DATEFROMPARTS(YEAR(@MonthDate), MONTH(@MonthDate), 1);
    DECLARE @MonthTo    DATE = EOMONTH(@MonthDate);
    DECLARE @WindowFrom DATE = DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @MonthDate) % 7), @MonthDate);
    DECLARE @WindowTo   DATE = DATEADD(DAY, 6 - (DATEDIFF(DAY, '19000101', @MonthTo) % 7), @MonthTo);
    DECLARE @Today      DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @Name NVARCHAR(150), @Day DATE, @DayText VARCHAR(20), @ShiftName NVARCHAR(60);

    /* ---- 1. who, which mode ---- */
    IF NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId)
    BEGIN RAISERROR('Branch not found.', 16, 1); RETURN 1; END
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    IF @SeesAll = 0 AND NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId AND ManagerEmployeeId = @CallerEmp)
    BEGIN RAISERROR('You can only plan rosters for the branches you manage.', 16, 1); RETURN 1; END
    IF @Mode IS NULL OR @Mode NOT IN ('FillEmpty', 'ReplanAuto', 'ReplanAll')
    BEGIN RAISERROR('Choose a real mode.', 16, 1); RETURN 1; END

    /* The whole branch-month is read-only while its roster waits for approval. The guard below sees only the days
       that change; a save that changes none would still rewrite the cells and the rhythm under the approvers. */
    DECLARE @OpenRid INT = (
        SELECT TOP 1 ri.RequestInstanceId
        FROM workflow.ROSTER_APPROVAL ra
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
        WHERE ra.BranchId = @BranchId AND ra.MonthDate = @MonthDate
          AND ri.[Status] IN ('Draft', 'Pending', 'OnHold')
        ORDER BY ri.RequestInstanceId DESC);
    IF @OpenRid IS NOT NULL
    BEGIN
        RAISERROR(N'Waiting for approval — request #%d. Withdraw or wait for the decision before editing.', 16, 1, @OpenRid);
        RETURN 1;
    END

    /* ---- 2. the cells, read and checked before anything is locked ---- */
    IF @ChangesJson IS NULL OR LTRIM(RTRIM(@ChangesJson)) = N'' SET @ChangesJson = N'[]';
    IF ISJSON(@ChangesJson) = 0
    BEGIN RAISERROR('The roster changes could not be read.', 16, 1); RETURN 1; END

    CREATE TABLE #chg (
        EmployeeId        INT           NULL,
        WorkDate          DATE          NULL,
        [Action]          VARCHAR(10)   NULL,       -- upsert | delete
        ShiftId           INT           NULL,
        IsRestDay         BIT           NULL,
        ExpectedExists    BIT           NULL,
        ExpectedShiftId   INT           NULL,
        ExpectedIsRestDay BIT           NULL,
        IsAuto            BIT           NULL,
        ReasonCode        VARCHAR(40)   NULL,
        ReasonArgs        NVARCHAR(400) NULL,
        IsPinned          BIT           NULL,       -- NULL = leave the pin as it is
        CurId             INT           NULL,       -- the row as it stands, read under lock
        CurShiftId        INT           NULL,
        CurIsRestDay      BIT           NULL,
        CurPinned         BIT           NULL,
        Op                VARCHAR(10)   NULL);      -- insert | update | delete; NULL = the row already says so
    /* the expected state is read flat (expectedExists, ...) or as the API model nests it (expected: { exists,
       shiftId, isRestDay }), so the save does not depend on how the cell list was serialised */
    INSERT INTO #chg (EmployeeId, WorkDate, [Action], ShiftId, IsRestDay, ExpectedExists, ExpectedShiftId, ExpectedIsRestDay,
                      IsAuto, ReasonCode, ReasonArgs, IsPinned)
    SELECT j.employeeId, TRY_CAST(j.workDate AS DATE), LEFT(LOWER(LTRIM(RTRIM(j.[action]))), 10), j.shiftId, j.isRestDay,
           ISNULL(j.expectedExists, j.nestedExists),
           CASE WHEN j.expectedExists IS NOT NULL THEN j.expectedShiftId   ELSE j.nestedShiftId   END,
           CASE WHEN j.expectedExists IS NOT NULL THEN j.expectedIsRestDay ELSE j.nestedIsRestDay END,
           ISNULL(j.isAuto, 0), LEFT(NULLIF(LTRIM(RTRIM(j.reasonCode)), N''), 40), LEFT(j.reasonArgs, 400), j.isPinned
    FROM OPENJSON(@ChangesJson) WITH (
        employeeId        INT           '$.employeeId',
        workDate          NVARCHAR(40)  '$.workDate',
        [action]          NVARCHAR(20)  '$.action',
        shiftId           INT           '$.shiftId',
        isRestDay         BIT           '$.isRestDay',
        expectedExists    BIT           '$.expectedExists',
        expectedShiftId   INT           '$.expectedShiftId',
        expectedIsRestDay BIT           '$.expectedIsRestDay',
        nestedExists      BIT           '$.expected.exists',
        nestedShiftId     INT           '$.expected.shiftId',
        nestedIsRestDay   BIT           '$.expected.isRestDay',
        isAuto            BIT           '$.isAuto',
        reasonCode        NVARCHAR(100) '$.reasonCode',
        reasonArgs        NVARCHAR(MAX) '$.reasonArgs',
        isPinned          BIT           '$.isPinned') j;

    IF EXISTS (SELECT 1 FROM #chg
               WHERE EmployeeId IS NULL OR WorkDate IS NULL OR ExpectedExists IS NULL
                  OR [Action] IS NULL OR [Action] NOT IN ('upsert', 'delete')
                  OR ([Action] = 'upsert' AND IsRestDay IS NULL))
       OR EXISTS (SELECT 1 FROM #chg GROUP BY EmployeeId, WorkDate HAVING COUNT(*) > 1)
    BEGIN RAISERROR('The roster changes could not be read.', 16, 1); RETURN 1; END
    UPDATE #chg SET ShiftId = NULL, IsRestDay = NULL WHERE [Action] = 'delete';

    IF EXISTS (SELECT 1 FROM #chg c WHERE NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE e WHERE e.EmployeeId = c.EmployeeId))
    BEGIN RAISERROR('Employee not found.', 16, 1); RETURN 1; END

    /* in the month: the days around it belong to the months they are in, with their own approval */
    SELECT TOP 1 @Day = c.WorkDate FROM #chg c WHERE c.WorkDate < @MonthDate OR c.WorkDate > @MonthTo ORDER BY c.WorkDate;
    IF @Day IS NOT NULL
    BEGIN
        SET @DayText = CONVERT(VARCHAR(11), @Day, 106);
        RAISERROR('%s is not in the month being saved.', 16, 1, @DayText);
        RETURN 1;
    END

    /* in this branch ON that day: a transferred employee's other days are the other branch's to plan */
    SELECT TOP 1 @Name = e.FullName, @Day = c.WorkDate
    FROM #chg c
    JOIN hr.EMPLOYEE e ON e.EmployeeId = c.EmployeeId
    WHERE ISNULL(hr.fn_EmployeeBranchOn(c.EmployeeId, c.WorkDate), -1) <> @BranchId
    ORDER BY c.WorkDate, e.FullName;
    IF @Name IS NOT NULL
    BEGIN
        SET @DayText = CONVERT(VARCHAR(11), @Day, 106);
        RAISERROR(N'%s is not in this branch on %s.', 16, 1, @Name, @DayText);
        RETURN 1;
    END

    SELECT TOP 1 @Name = e.FullName, @Day = c.WorkDate
    FROM #chg c
    JOIN hr.EMPLOYEE e ON e.EmployeeId = c.EmployeeId
    WHERE e.IsDeleted = 1 OR e.HireDate > c.WorkDate OR e.TerminationDate < c.WorkDate
    ORDER BY c.WorkDate, e.FullName;
    IF @Name IS NOT NULL
    BEGIN
        SET @DayText = CONVERT(VARCHAR(11), @Day, 106);
        RAISERROR(N'%s is not employed on %s.', 16, 1, @Name, @DayText);
        RETURN 1;
    END

    /* a working day is a shift, a rest day is IsRestDay with no shift; a row with neither tells attendance and
       payroll nothing, and a rest day with a shift is read differently by each of them */
    SELECT TOP 1 @Name = e.FullName, @Day = c.WorkDate
    FROM #chg c
    JOIN hr.EMPLOYEE e ON e.EmployeeId = c.EmployeeId
    WHERE c.[Action] = 'upsert' AND c.IsRestDay = 0 AND c.ShiftId IS NULL
    ORDER BY c.WorkDate, e.FullName;
    IF @Name IS NOT NULL
    BEGIN
        SET @DayText = CONVERT(VARCHAR(11), @Day, 106);
        RAISERROR(N'%s on %s: choose a shift, or mark the day as a rest day.', 16, 1, @Name, @DayText);
        RETURN 1;
    END
    SELECT TOP 1 @Name = e.FullName, @Day = c.WorkDate
    FROM #chg c
    JOIN hr.EMPLOYEE e ON e.EmployeeId = c.EmployeeId
    WHERE c.[Action] = 'upsert' AND c.IsRestDay = 1 AND c.ShiftId IS NOT NULL
    ORDER BY c.WorkDate, e.FullName;
    IF @Name IS NOT NULL
    BEGIN
        SET @DayText = CONVERT(VARCHAR(11), @Day, 106);
        RAISERROR(N'%s on %s: a rest day carries no shift.', 16, 1, @Name, @DayText);
        RETURN 1;
    END

    /* The next two hold for what is WRITTEN. A cell sent back exactly as its row already stands (the expected-state
       check below proves it does) writes nothing, so a day kept as it was is not refused for it. */
    SELECT TOP 1 @ShiftName = ISNULL(sh.Name, CONCAT(N'#', c.ShiftId))
    FROM #chg c
    LEFT JOIN attendance.SHIFT sh ON sh.ShiftId = c.ShiftId
    WHERE c.[Action] = 'upsert' AND c.IsRestDay = 0 AND c.ShiftId IS NOT NULL AND ISNULL(sh.IsActive, 0) = 0
      AND NOT (c.ExpectedExists = 1 AND ISNULL(c.ExpectedIsRestDay, 0) = 0 AND ISNULL(c.ExpectedShiftId, -1) = c.ShiftId)
    ORDER BY c.WorkDate;
    IF @ShiftName IS NOT NULL
    BEGIN RAISERROR(N'Shift %s is not active.', 16, 1, @ShiftName); RETURN 1; END

    /* a rest row outranks a holiday in the day rule: it would take the holiday away (and its premium) */
    IF EXISTS (SELECT 1 FROM #chg c
               WHERE c.[Action] = 'upsert' AND c.IsRestDay = 1 AND core.fn_IsHoliday(c.WorkDate, @BranchId) = 1
                 AND NOT (c.ExpectedExists = 1 AND ISNULL(c.ExpectedIsRestDay, 0) = 1 AND c.ExpectedShiftId IS NULL))
    BEGIN RAISERROR(N'A holiday is not a rest day — leave the day empty.', 16, 1); RETURN 1; END

    SELECT TOP 1 @Name = e.FullName, @Day = c.WorkDate
    FROM #chg c
    JOIN hr.EMPLOYEE e ON e.EmployeeId = c.EmployeeId
    JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.EmployeeId = c.EmployeeId AND sa.WorkDate = c.WorkDate
    WHERE c.[Action] = 'delete'
      AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD ar WHERE ar.ShiftAssignmentId = sa.ShiftAssignmentId)
    ORDER BY c.WorkDate, e.FullName;
    IF @Name IS NOT NULL
    BEGIN
        SET @DayText = CONVERT(VARCHAR(11), @Day, 106);
        RAISERROR(N'%s has an attendance record on %s — that roster day cannot be removed.', 16, 1, @Name, @DayText);
        RETURN 1;
    END

    /* the rhythm: one row per employee of this branch's month, anchored on a Monday. As in usp_RosterRhythm_Save,
       the anchor comes as a pair or not at all (someone only taken off rotation), and onRotation NULL = unchanged.
       The expected state is read flat or nested, like the cells' (whichever form carries a value). */
    IF @RhythmJson IS NULL OR LTRIM(RTRIM(@RhythmJson)) = N'' SET @RhythmJson = N'[]';
    IF ISJSON(@RhythmJson) = 0
    BEGIN RAISERROR('The rhythm could not be read.', 16, 1); RETURN 1; END
    CREATE TABLE #rhy (
        EmployeeId         INT          NULL,
        AnchorText         NVARCHAR(40) NULL,
        AnchorWeekStart    DATE         NULL,
        AnchorWorkDays     INT          NULL,
        OnRotation         BIT          NULL,       -- NULL = leave the flag as it is
        ExpAnchorText      NVARCHAR(40) NULL,
        ExpAnchorWeekStart DATE         NULL,       -- the stored row the preview was made from (anchor NULL = none)
        ExpAnchorWorkDays  INT          NULL,
        ExpOnRotation      BIT          NULL,       -- NULL = not sent: the row is not checked
        CurAnchorWeekStart DATE         NULL,       -- the stored row as it stands, read under lock; no row = on rotation,
        CurAnchorWorkDays  INT          NULL,       --   no anchor (what the planner assumes too)
        CurOnRotation      BIT          NOT NULL DEFAULT (1));
    INSERT INTO #rhy (EmployeeId, AnchorText, AnchorWeekStart, AnchorWorkDays, OnRotation,
                      ExpAnchorText, ExpAnchorWeekStart, ExpAnchorWorkDays, ExpOnRotation)
    SELECT j.employeeId, j.anchorWeekStart, TRY_CAST(j.anchorWeekStart AS DATE), j.anchorWorkDays, j.onRotation,
           x.AnchorText, TRY_CAST(x.AnchorText AS DATE), x.WorkDays, x.OnRotation
    FROM OPENJSON(@RhythmJson) WITH (
        employeeId              INT          '$.employeeId',
        anchorWeekStart         NVARCHAR(40) '$.anchorWeekStart',
        anchorWorkDays          INT          '$.anchorWorkDays',
        onRotation              BIT          '$.onRotation',
        expectedAnchorWeekStart NVARCHAR(40) '$.expectedAnchorWeekStart',
        expectedAnchorWorkDays  INT          '$.expectedAnchorWorkDays',
        expectedOnRotation      BIT          '$.expectedOnRotation',
        nestedAnchorWeekStart   NVARCHAR(40) '$.expected.anchorWeekStart',
        nestedAnchorWorkDays    INT          '$.expected.anchorWorkDays',
        nestedOnRotation        BIT          '$.expected.onRotation') j
    CROSS APPLY (SELECT CASE WHEN j.expectedAnchorWeekStart IS NOT NULL OR j.expectedAnchorWorkDays IS NOT NULL
                                  OR j.expectedOnRotation IS NOT NULL THEN 1 ELSE 0 END AS Flat) f
    CROSS APPLY (SELECT CASE WHEN f.Flat = 1 THEN j.expectedAnchorWeekStart ELSE j.nestedAnchorWeekStart END AS AnchorText,
                        CASE WHEN f.Flat = 1 THEN j.expectedAnchorWorkDays  ELSE j.nestedAnchorWorkDays  END AS WorkDays,
                        CASE WHEN f.Flat = 1 THEN j.expectedOnRotation      ELSE j.nestedOnRotation      END AS OnRotation) x;
    IF EXISTS (SELECT 1 FROM #rhy WHERE EmployeeId IS NULL OR (AnchorText IS NOT NULL AND AnchorWeekStart IS NULL))
       OR EXISTS (SELECT 1 FROM #rhy GROUP BY EmployeeId HAVING COUNT(*) > 1)
       /* an expected state is the whole stored row: the flag, and the anchor as a pair (both NULL = none) */
       OR EXISTS (SELECT 1 FROM #rhy
                  WHERE (ExpAnchorText IS NOT NULL AND ExpAnchorWeekStart IS NULL)
                     OR (ExpAnchorWeekStart IS NULL AND ExpAnchorWorkDays IS NOT NULL)
                     OR (ExpAnchorWeekStart IS NOT NULL AND ExpAnchorWorkDays IS NULL)
                     OR (ExpAnchorWeekStart IS NOT NULL AND ExpOnRotation IS NULL))
    BEGIN RAISERROR('The rhythm could not be read.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM #rhy WHERE (AnchorWeekStart IS NULL AND AnchorWorkDays IS NOT NULL)
                                     OR (AnchorWeekStart IS NOT NULL AND AnchorWorkDays IS NULL))
    BEGIN RAISERROR('Give the starting week and its working days together.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM #rhy WHERE DATEDIFF(DAY, '19000101', AnchorWeekStart) % 7 <> 0)
    BEGIN RAISERROR('The rhythm starts on a Monday.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM #rhy WHERE AnchorWorkDays NOT IN (5, 6))
    BEGIN RAISERROR('A week of the rhythm has 6 or 5 working days.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM #rhy r WHERE NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE e WHERE e.EmployeeId = r.EmployeeId))
    BEGIN RAISERROR('Employee not found.', 16, 1); RETURN 1; END
    ;WITH days AS (
        SELECT @WindowFrom AS d
        UNION ALL
        SELECT DATEADD(DAY, 1, d) FROM days WHERE d < @WindowTo
    )
    SELECT TOP 1 @Name = e.FullName
    FROM #rhy r
    JOIN hr.EMPLOYEE e ON e.EmployeeId = r.EmployeeId
    WHERE NOT EXISTS (SELECT 1 FROM days
                      WHERE e.IsDeleted = 0 AND e.HireDate <= days.d
                        AND (e.TerminationDate IS NULL OR e.TerminationDate >= days.d)
                        AND hr.fn_EmployeeBranchOn(r.EmployeeId, days.d) = @BranchId)
    ORDER BY e.FullName
    OPTION (MAXRECURSION 400);
    IF @Name IS NOT NULL
    BEGIN RAISERROR(N'%s is not on this branch''s roster in this month.', 16, 1, @Name); RETURN 1; END

    /* ---- 3. under lock: the rows must still be the rows the preview was made from ---- */
    BEGIN TRAN;

    /* HOLDLOCK also locks the days that have no row, so nobody inserts one between this read and the write */
    UPDATE c
    SET c.CurId = sa.ShiftAssignmentId, c.CurShiftId = sa.ShiftId, c.CurIsRestDay = sa.IsRestDay
    FROM #chg c
    JOIN attendance.SHIFT_ASSIGNMENT sa WITH (UPDLOCK, HOLDLOCK) ON sa.EmployeeId = c.EmployeeId AND sa.WorkDate = c.WorkDate;

    UPDATE c
    SET c.CurPinned = rc.IsPinned
    FROM #chg c
    JOIN attendance.ROSTER_CELL rc WITH (UPDLOCK, HOLDLOCK) ON rc.EmployeeId = c.EmployeeId AND rc.WorkDate = c.WorkDate;

    /* the cells were planned on this rhythm: a flip or a first save made since the preview must not be overwritten
       by the preview's (also locked where there is no row, so none appears before the MERGE below) */
    UPDATE r
    SET r.CurAnchorWeekStart = t.AnchorWeekStart, r.CurAnchorWorkDays = t.AnchorWorkDays, r.CurOnRotation = t.OnRotation
    FROM #rhy r
    JOIN attendance.ROSTER_RHYTHM t WITH (UPDLOCK, HOLDLOCK) ON t.EmployeeId = r.EmployeeId;

    IF EXISTS (SELECT 1 FROM #chg c
               WHERE (c.ExpectedExists = 1 AND (c.CurId IS NULL
                                                OR ISNULL(c.CurShiftId, -1) <> ISNULL(c.ExpectedShiftId, -1)
                                                OR c.CurIsRestDay <> ISNULL(c.ExpectedIsRestDay, 0)))
                  OR (c.ExpectedExists = 0 AND c.CurId IS NOT NULL))
       OR EXISTS (SELECT 1 FROM #rhy r
                  WHERE r.ExpOnRotation IS NOT NULL
                    AND EXISTS (SELECT r.CurAnchorWeekStart, r.CurAnchorWorkDays, r.CurOnRotation       -- NULL-safe: EXCEPT
                                EXCEPT                                                                  --   treats NULLs as equal
                                SELECT r.ExpAnchorWeekStart, r.ExpAnchorWorkDays, r.ExpOnRotation))
    BEGIN
        ROLLBACK;
        RAISERROR(N'The roster changed since the preview — preview again.', 16, 1);
        RETURN 1;
    END

    /* The rhythm belongs to the person, not to this month: every later month of the branch they are in is planned on
       their flag and anchor. A first anchor is this plan's own, and the alternation simply continues from it whoever
       plans next. Taking someone off (or back on) rotation, or replacing an anchor they have, is for a manager of the
       branch they are in today or are moving into, as in usp_RosterRhythm_Save; otherwise a save of a month a
       person has since left would take them out of their new branch's planning. */
    IF @SeesAll = 0
    BEGIN
        SELECT TOP 1 @Name = e.FullName
        FROM #rhy r
        JOIN hr.EMPLOYEE e ON e.EmployeeId = r.EmployeeId
        WHERE (ISNULL(r.OnRotation, r.CurOnRotation) <> r.CurOnRotation
               OR (r.AnchorWeekStart IS NOT NULL AND r.CurAnchorWeekStart IS NOT NULL
                   AND (r.AnchorWeekStart <> r.CurAnchorWeekStart OR r.AnchorWorkDays <> r.CurAnchorWorkDays)))
          AND NOT EXISTS (SELECT 1 FROM hr.BRANCH mb
                          WHERE mb.ManagerEmployeeId = @CallerEmp
                            AND (mb.BranchId = hr.fn_EmployeeBranchOn(r.EmployeeId, @Today)
                                 OR EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY h
                                            WHERE h.EmployeeId = r.EmployeeId AND h.BranchId = mb.BranchId
                                              AND h.EffectiveFrom > @Today)))
        ORDER BY e.FullName;
        IF @Name IS NOT NULL
        BEGIN
            ROLLBACK;
            RAISERROR(N'%s belongs to another branch now — their rotation and rhythm are set there.', 16, 1, @Name);
            RETURN 1;
        END
    END

    /* only what really changes is written: an unchanged day keeps its ModifiedUtc, so it never marks an
       approved month "changed since approval" */
    UPDATE #chg
    SET Op = CASE WHEN [Action] = 'upsert' AND CurId IS NULL THEN 'insert'
                  WHEN [Action] = 'upsert' AND (ISNULL(CurShiftId, -1) <> ISNULL(ShiftId, -1) OR CurIsRestDay <> IsRestDay) THEN 'update'
                  WHEN [Action] = 'delete' AND CurId IS NOT NULL THEN 'delete' END;

    /* a pin on a day with no row is void (left over from a cleared roster): only a pinned saved row is kept */
    IF EXISTS (SELECT 1 FROM #chg WHERE Op IN ('update', 'delete') AND CurPinned = 1)
    BEGIN
        ROLLBACK;
        RAISERROR(N'This day is pinned — unpin it before re-planning it.', 16, 1);
        RETURN 1;
    END

    /* ---- 4. the guard of every roster writer sees exactly the days that change ---- */
    IF OBJECT_ID('tempdb..#roster_change') IS NOT NULL DROP TABLE #roster_change;
    CREATE TABLE #roster_change (EmployeeId INT NOT NULL, WorkDate DATE NOT NULL);
    INSERT INTO #roster_change (EmployeeId, WorkDate)
    SELECT EmployeeId, WorkDate FROM #chg WHERE Op IS NOT NULL;
    DECLARE @rc INT;
    EXEC @rc = attendance.usp_Roster_AssertEditable;
    DROP TABLE #roster_change;
    IF ISNULL(@rc, 1) <> 0
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK;
        RETURN 1;              -- the guard already raised the refusal
    END

    /* The guard locks the past only in an approved month. The auto-roster never changes a day before today or a
       day attendance already judged, whatever the month's state: attendance for it was derived without this row,
       and approving the month later does not re-derive it. The planner leaves these days alone; this makes sure.
       It runs after the guard so that an approved month still answers with the guard's own sentence. */
    SELECT TOP 1 @Name = e.FullName, @Day = c.WorkDate
    FROM #chg c
    JOIN hr.EMPLOYEE e ON e.EmployeeId = c.EmployeeId
    WHERE c.Op IS NOT NULL
      AND (c.WorkDate < @Today
           OR EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD ar WHERE ar.EmployeeId = c.EmployeeId AND ar.WorkDate = c.WorkDate))
    ORDER BY c.WorkDate, e.FullName;
    IF @Name IS NOT NULL
    BEGIN
        ROLLBACK;
        SET @DayText = CONVERT(VARCHAR(11), @Day, 106);
        RAISERROR(N'%s on %s is in the past or already has attendance — the auto-roster does not change it.', 16, 1, @Name, @DayText);
        RETURN 1;
    END

    /* ---- 5. write ---- */
    DECLARE @Inserted INT = (SELECT COUNT(*) FROM #chg WHERE Op = 'insert');
    DECLARE @Updated  INT = (SELECT COUNT(*) FROM #chg WHERE Op = 'update');
    DECLARE @Deleted  INT = (SELECT COUNT(*) FROM #chg WHERE Op = 'delete');

    /* the run first: its id marks the cells the generator wrote */
    INSERT INTO attendance.ROSTER_AUTO_RUN (BranchId, MonthDate, Mode, ParamsJson, RowsInserted, RowsUpdated, RowsDeleted, IssueCount, CreatedBy)
    VALUES (@BranchId, @MonthDate, @Mode,
            CASE WHEN ISJSON(@ParamsJson) = 1 THEN @ParamsJson END,      -- read back as the drawer's defaults: only JSON is kept
            @Inserted, @Updated, @Deleted, @IssueCount, @CallerUserId);
    DECLARE @RunId INT = CAST(SCOPE_IDENTITY() AS INT);

    DELETE sa
    FROM attendance.SHIFT_ASSIGNMENT sa
    JOIN #chg c ON c.CurId = sa.ShiftAssignmentId
    WHERE c.Op = 'delete';

    UPDATE sa
    SET sa.ShiftId = c.ShiftId, sa.IsRestDay = c.IsRestDay
    FROM attendance.SHIFT_ASSIGNMENT sa
    JOIN #chg c ON c.CurId = sa.ShiftAssignmentId
    WHERE c.Op = 'update';

    INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
    SELECT c.EmployeeId, c.ShiftId, c.WorkDate, c.IsRestDay
    FROM #chg c
    WHERE c.Op = 'insert';

    /* what the generator wrote (isAuto) or that the manager's edit is now the day (AutoState NULL). The pin: as
       sent; off where the day has no row after the save, or had none before it (a pin left over from a cleared
       roster must not come back with the new row); otherwise unchanged. */
    MERGE attendance.ROSTER_CELL WITH (HOLDLOCK) AS t
    USING (
        SELECT c.EmployeeId, c.WorkDate,
               CASE WHEN c.IsAuto = 1 THEN CASE WHEN c.[Action] = 'delete' THEN 'none'
                                                WHEN c.IsRestDay = 1 THEN 'rest'
                                                ELSE 'work' END END AS AutoState,
               CASE WHEN c.IsAuto = 1 AND c.[Action] = 'upsert' AND c.IsRestDay = 0 THEN c.ShiftId END AS AutoShiftId,
               CASE WHEN c.IsAuto = 1 THEN @RunId END AS AutoRunId,
               c.ReasonCode, c.ReasonArgs,
               CASE WHEN c.[Action] = 'delete' THEN CAST(0 AS BIT)
                    WHEN c.IsPinned IS NOT NULL THEN c.IsPinned
                    WHEN c.CurId IS NULL THEN CAST(0 AS BIT) END AS NewPin          -- NULL = unchanged
        FROM #chg c) AS s
       ON t.EmployeeId = s.EmployeeId AND t.WorkDate = s.WorkDate
    WHEN MATCHED THEN UPDATE SET
        AutoState   = s.AutoState,
        AutoShiftId = s.AutoShiftId,
        AutoRunId   = s.AutoRunId,
        ReasonCode  = s.ReasonCode,
        ReasonArgs  = s.ReasonArgs,
        IsPinned    = ISNULL(s.NewPin, t.IsPinned),
        PinnedBy    = CASE WHEN s.NewPin IS NULL THEN t.PinnedBy WHEN s.NewPin = 0 THEN NULL
                           WHEN t.IsPinned = 1 THEN t.PinnedBy ELSE @CallerUserId END,
        PinnedAt    = CASE WHEN s.NewPin IS NULL THEN t.PinnedAt WHEN s.NewPin = 0 THEN NULL
                           WHEN t.IsPinned = 1 THEN t.PinnedAt ELSE SYSUTCDATETIME() END,
        UpdatedAt   = SYSUTCDATETIME()
    /* a manual day with nothing to remember needs no row: no row already means manual and unpinned */
    WHEN NOT MATCHED BY TARGET AND (s.AutoState IS NOT NULL OR s.ReasonCode IS NOT NULL OR s.NewPin = 1) THEN
        INSERT (EmployeeId, WorkDate, AutoState, AutoShiftId, AutoRunId, ReasonCode, ReasonArgs, IsPinned, PinnedBy, PinnedAt)
        VALUES (s.EmployeeId, s.WorkDate, s.AutoState, s.AutoShiftId, s.AutoRunId, s.ReasonCode, s.ReasonArgs,
                ISNULL(s.NewPin, 0),
                CASE WHEN s.NewPin = 1 THEN @CallerUserId END,
                CASE WHEN s.NewPin = 1 THEN SYSUTCDATETIME() END);

    /* stored once, then kept: the alternation continues from here in every later month. Someone only taken off
       rotation is stored with the flag alone: no anchor is made up for them (see the table). No row and no anchor
       while on rotation: nothing to store. */
    MERGE attendance.ROSTER_RHYTHM WITH (HOLDLOCK) AS t
    USING #rhy AS s
       ON t.EmployeeId = s.EmployeeId
    WHEN MATCHED THEN UPDATE SET
        AnchorWeekStart = ISNULL(s.AnchorWeekStart, t.AnchorWeekStart),
        AnchorWorkDays  = ISNULL(s.AnchorWorkDays, t.AnchorWorkDays),
        OnRotation      = ISNULL(s.OnRotation, t.OnRotation),
        UpdatedAt       = SYSUTCDATETIME(),
        UpdatedBy       = @CallerUserId
    WHEN NOT MATCHED BY TARGET AND (s.AnchorWeekStart IS NOT NULL OR s.OnRotation = 0) THEN
        INSERT (EmployeeId, AnchorWeekStart, AnchorWorkDays, OnRotation, UpdatedBy)
        VALUES (s.EmployeeId, s.AnchorWeekStart, s.AnchorWorkDays, ISNULL(s.OnRotation, 1), @CallerUserId);

    COMMIT;

    SELECT @RunId AS RunId, @Inserted AS RowsInserted, @Updated AS RowsUpdated, @Deleted AS RowsDeleted;
    RETURN 0;
END;
GO

/* ───────────────────────── 5. pins and the cell overlay ───────────────────────── */
/* "Keep when regenerating": a pinned day with a row is a fact to the planner in every mode. Writes no roster row,
   so it needs no guard; the branch is the one the employee belongs to on that day. */
CREATE OR ALTER PROCEDURE attendance.usp_RosterCell_SetPin
    @EmployeeId   INT,
    @WorkDate     DATE,
    @IsPinned     BIT,
    @CallerUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @IsPinned = ISNULL(@IsPinned, 0);

    IF @WorkDate IS NULL
    BEGIN RAISERROR('Give a real day.', 16, 1); RETURN 1; END
    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId)
    BEGIN RAISERROR('Employee not found.', 16, 1); RETURN 1; END

    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    IF @SeesAll = 0 AND NOT EXISTS (SELECT 1 FROM hr.BRANCH
                                    WHERE BranchId = hr.fn_EmployeeBranchOn(@EmployeeId, @WorkDate) AND ManagerEmployeeId = @CallerEmp)
    BEGIN RAISERROR('You can only plan rosters for the branches you manage.', 16, 1); RETURN 1; END

    /* unpinning stays allowed without a row: it clears a pin a cleared roster left behind */
    IF @IsPinned = 1 AND NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate)
    BEGIN RAISERROR('Only a saved day can be pinned.', 16, 1); RETURN 1; END

    MERGE attendance.ROSTER_CELL WITH (HOLDLOCK) AS t
    USING (SELECT @EmployeeId AS EmployeeId, @WorkDate AS WorkDate) AS s
       ON t.EmployeeId = s.EmployeeId AND t.WorkDate = s.WorkDate
    WHEN MATCHED THEN UPDATE SET
        IsPinned  = @IsPinned,
        PinnedBy  = CASE WHEN @IsPinned = 0 THEN NULL WHEN t.IsPinned = 1 THEN t.PinnedBy ELSE @CallerUserId END,
        PinnedAt  = CASE WHEN @IsPinned = 0 THEN NULL WHEN t.IsPinned = 1 THEN t.PinnedAt ELSE SYSUTCDATETIME() END,
        UpdatedAt = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET AND @IsPinned = 1 THEN
        INSERT (EmployeeId, WorkDate, IsPinned, PinnedBy, PinnedAt)
        VALUES (s.EmployeeId, s.WorkDate, 1, @CallerUserId, SYSUTCDATETIME());

    RETURN 0;
END;
GO

/* The grid's overlay: per stored cell, whether it is pinned and whether it is still what the generator wrote.
   AUTO is decided against the row as it stands, so an edit made through any other path shows as manual. Scoped
   like the roster read (script 87): EMP_VIEW_ALL, the branch's manager, or the caller's own days. */
CREATE OR ALTER PROCEDURE attendance.usp_RosterCell_GetRange
    @BranchId     INT,
    @FromDate     DATE,
    @ToDate       DATE,
    @CallerUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    DECLARE @Manages BIT = CASE WHEN EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId AND ManagerEmployeeId = @CallerEmp)
                                THEN 1 ELSE 0 END;

    SELECT rc.EmployeeId, rc.WorkDate,
           CAST(CASE WHEN rc.IsPinned = 1 AND sa.ShiftAssignmentId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsPinned,
           CAST(CASE WHEN rc.AutoState = 'none' AND sa.ShiftAssignmentId IS NULL THEN 1
                     WHEN rc.AutoState = 'rest' AND sa.IsRestDay = 1 THEN 1
                     WHEN rc.AutoState = 'work' AND sa.IsRestDay = 0 AND sa.ShiftId = rc.AutoShiftId THEN 1
                     ELSE 0 END AS BIT) AS IsAuto,
           rc.ReasonCode
    FROM attendance.ROSTER_CELL rc
    LEFT JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.EmployeeId = rc.EmployeeId AND sa.WorkDate = rc.WorkDate
    WHERE rc.WorkDate BETWEEN @FromDate AND @ToDate
      AND hr.fn_EmployeeBranchOn(rc.EmployeeId, rc.WorkDate) = @BranchId
      AND (@SeesAll = 1 OR @Manages = 1 OR rc.EmployeeId = @CallerEmp)
    ORDER BY rc.WorkDate, rc.EmployeeId;
END;
GO

/* ───────────────────────── 6. staffing requirements ───────────────────────── */
CREATE OR ALTER PROCEDURE attendance.usp_StaffingRequirement_GetByBranch
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

    SELECT sr.DayOfWeek, sr.ShiftId, sr.MinOnDuty, sr.TargetOnDuty
    FROM attendance.STAFFING_REQUIREMENT sr
    WHERE sr.BranchId = @BranchId AND sr.IsActive = 1
    ORDER BY ISNULL(sr.DayOfWeek, 0), ISNULL(sr.ShiftId, 0);
    RETURN 0;
END;
GO

/* Replaces the branch's whole set: [{ dayOfWeek, shiftId, minOnDuty, targetOnDuty }] (dayOfWeek / shiftId NULL =
   every day / any shift; an empty list clears them). */
CREATE OR ALTER PROCEDURE attendance.usp_StaffingRequirement_Save
    @BranchId     INT,
    @RowsJson     NVARCHAR(MAX),
    @CallerUserId INT = NULL
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

    IF @RowsJson IS NULL OR LTRIM(RTRIM(@RowsJson)) = N'' SET @RowsJson = N'[]';
    IF ISJSON(@RowsJson) = 0
    BEGIN RAISERROR('The staffing rows could not be read.', 16, 1); RETURN 1; END

    DECLARE @rows TABLE (DayOfWeek INT NULL, ShiftId INT NULL, MinOnDuty INT NULL, TargetOnDuty INT NULL);
    INSERT INTO @rows (DayOfWeek, ShiftId, MinOnDuty, TargetOnDuty)
    SELECT j.dayOfWeek, j.shiftId, j.minOnDuty, j.targetOnDuty
    FROM OPENJSON(@RowsJson) WITH (
        dayOfWeek    INT '$.dayOfWeek',
        shiftId      INT '$.shiftId',
        minOnDuty    INT '$.minOnDuty',
        targetOnDuty INT '$.targetOnDuty') j;

    IF EXISTS (SELECT 1 FROM @rows WHERE DayOfWeek NOT BETWEEN 1 AND 7)
    BEGIN RAISERROR('A weekday is 1 (Monday) to 7 (Sunday).', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM @rows WHERE MinOnDuty IS NULL OR MinOnDuty < 0)
    BEGIN RAISERROR('The minimum on duty is 0 or more.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM @rows WHERE TargetOnDuty < MinOnDuty)
    BEGIN RAISERROR('The target on duty cannot be below the minimum.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM @rows r WHERE r.ShiftId IS NOT NULL
                                       AND NOT EXISTS (SELECT 1 FROM attendance.SHIFT sh WHERE sh.ShiftId = r.ShiftId))
    BEGIN RAISERROR('Shift not found.', 16, 1); RETURN 1; END
    /* one figure per weekday and shift: two would leave the planner to guess which one HR meant */
    IF EXISTS (SELECT 1 FROM @rows GROUP BY DayOfWeek, ShiftId HAVING COUNT(*) > 1)
    BEGIN RAISERROR('Each weekday and shift takes one requirement only.', 16, 1); RETURN 1; END

    BEGIN TRAN;
        DELETE FROM attendance.STAFFING_REQUIREMENT WHERE BranchId = @BranchId;
        INSERT INTO attendance.STAFFING_REQUIREMENT (BranchId, DayOfWeek, ShiftId, MinOnDuty, TargetOnDuty, IsActive)
        SELECT @BranchId, r.DayOfWeek, r.ShiftId, r.MinOnDuty, r.TargetOnDuty, 1
        FROM @rows r;
    COMMIT;
    RETURN 0;
END;
GO

/* ───────────────────────── 7. attendance.usp_RosterRhythm_Save ───────────────────────── */
/* The drawer's staff list: On rotation, and "this week is a 5-day week" (a new anchor).
   [{ employeeId, onRotation, anchorWeekStart, anchorWorkDays }] — the anchor fields are optional, and come as a
   pair. The rhythm belongs to the person, not the branch, and it is present and future state: every later month
   of the branch they are in is planned on it. So a manager may set it for someone in their branch today, or
   moving into it on a later date — never for someone who was in it once (the anchor week can lie in the past, and
   a branch of the past is not one the caller plans for the person any more). */
CREATE OR ALTER PROCEDURE attendance.usp_RosterRhythm_Save
    @RowsJson     NVARCHAR(MAX),
    @CallerUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);

    IF @RowsJson IS NULL OR LTRIM(RTRIM(@RowsJson)) = N'' SET @RowsJson = N'[]';
    IF ISJSON(@RowsJson) = 0
    BEGIN RAISERROR('The rhythm could not be read.', 16, 1); RETURN 1; END

    CREATE TABLE #rhy (EmployeeId INT NULL, OnRotation BIT NULL, AnchorText NVARCHAR(40) NULL,
                       AnchorWeekStart DATE NULL, AnchorWorkDays INT NULL);
    INSERT INTO #rhy (EmployeeId, OnRotation, AnchorText, AnchorWeekStart, AnchorWorkDays)
    SELECT j.employeeId, j.onRotation, j.anchorWeekStart, TRY_CAST(j.anchorWeekStart AS DATE), j.anchorWorkDays
    FROM OPENJSON(@RowsJson) WITH (
        employeeId      INT          '$.employeeId',
        onRotation      BIT          '$.onRotation',
        anchorWeekStart NVARCHAR(40) '$.anchorWeekStart',
        anchorWorkDays  INT          '$.anchorWorkDays') j;

    IF EXISTS (SELECT 1 FROM #rhy WHERE EmployeeId IS NULL OR (AnchorText IS NOT NULL AND AnchorWeekStart IS NULL))
       OR EXISTS (SELECT 1 FROM #rhy GROUP BY EmployeeId HAVING COUNT(*) > 1)
    BEGIN RAISERROR('The rhythm could not be read.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM #rhy r WHERE NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE e WHERE e.EmployeeId = r.EmployeeId))
    BEGIN RAISERROR('Employee not found.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM #rhy WHERE (AnchorWeekStart IS NULL AND AnchorWorkDays IS NOT NULL)
                                     OR (AnchorWeekStart IS NOT NULL AND AnchorWorkDays IS NULL))
    BEGIN RAISERROR('Give the starting week and its working days together.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM #rhy WHERE DATEDIFF(DAY, '19000101', AnchorWeekStart) % 7 <> 0)
    BEGIN RAISERROR('The rhythm starts on a Monday.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM #rhy WHERE AnchorWorkDays NOT IN (5, 6))
    BEGIN RAISERROR('A week of the rhythm has 6 or 5 working days.', 16, 1); RETURN 1; END

    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    IF @SeesAll = 0 AND EXISTS (
        SELECT 1 FROM #rhy r
        WHERE NOT EXISTS (SELECT 1 FROM hr.BRANCH mb
                          WHERE mb.ManagerEmployeeId = @CallerEmp
                            AND (mb.BranchId = hr.fn_EmployeeBranchOn(r.EmployeeId, @Today)
                                 OR EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY h
                                            WHERE h.EmployeeId = r.EmployeeId AND h.BranchId = mb.BranchId AND h.EffectiveFrom > @Today))))
    BEGIN RAISERROR('You can only plan rosters for the branches you manage.', 16, 1); RETURN 1; END

    /* No row and no anchor: on rotation is already the default, so nothing is stored. Taking someone OFF rotation
       stores the flag alone, exactly as the commit does: no anchor is made up (see the table), so when they come
       back the planner starts their rhythm by its own rule. The drawer sends the real anchor when it has one. */
    BEGIN TRAN;
        MERGE attendance.ROSTER_RHYTHM WITH (HOLDLOCK) AS t
        USING #rhy AS s
           ON t.EmployeeId = s.EmployeeId
        WHEN MATCHED THEN UPDATE SET
            OnRotation      = ISNULL(s.OnRotation, t.OnRotation),
            AnchorWeekStart = ISNULL(s.AnchorWeekStart, t.AnchorWeekStart),
            AnchorWorkDays  = ISNULL(s.AnchorWorkDays, t.AnchorWorkDays),
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedBy       = @CallerUserId
        WHEN NOT MATCHED BY TARGET AND (s.AnchorWeekStart IS NOT NULL OR s.OnRotation = 0) THEN
            INSERT (EmployeeId, AnchorWeekStart, AnchorWorkDays, OnRotation, UpdatedBy)
            VALUES (s.EmployeeId, s.AnchorWeekStart, s.AnchorWorkDays, ISNULL(s.OnRotation, 1), @CallerUserId);
    COMMIT;
    RETURN 0;
END;
GO

PRINT 'auto-roster: tables, Roster settings and procedures in place';
GO
