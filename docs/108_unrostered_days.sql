/* ============================================================================
   108_unrostered_days.sql - A DAY SOMEBODY WORKED THAT THE APPROVED ROSTER DOES NOT KNOW: SEEN, DECIDED, COUNTED.

   THE RULE THAT STAYS. In a branch-month whose roster is Approved, punches on a day the employee has no roster row
   for write NO attendance record (script 83; usp_Attendance_ComputeDay). Nothing is paid and nothing is deducted for
   such a day until a person says what it was. The system never guesses a shift and never writes a roster row itself.

   WHAT WAS MISSING. The day showed nowhere on Daily attendance, and nobody was made to decide it: only the
   Anomalies page listed it, with a link to the roster, and payroll could be locked over it.

   1  THE DAY IS A FACT OF ITS OWN: attendance.fn_UnrosteredDays(@FromDate, @ToDate) - the one definition, read by
      the list, by the decision, by the roster writer and by payroll readiness. Same predicate as
      attendance.usp_Attendance_GetWorkedWithoutRoster (script 87), which is left exactly as it is (its 9 columns are
      a contract, and production had it before the repo did).
   2  THE DECISION: attendance.usp_UnrosteredDay_Decide
        Shift     add the day to the roster with a shift       -> the day is derived from its punches at once
        RestDay   add it as a rest day that was worked         -> derived at once (status RestDay, minutes kept)
        Dismiss   the punches were not work (a note is required) -> nothing is written to the roster or to attendance
      A dismissal answers the punches it saw (count, first, last): a punch that arrives later opens the day again.
      attendance.usp_UnrosteredDay_Reopen takes a dismissal back. Every decision is kept in
      attendance.UNROSTERED_DAY_DECISION with who, when and the punches it answered (history included).
      attendance.usp_UnrosteredDay_GetList is the list for the pages: every such day of the caller's branches, its
      state, and CanDecide (may THIS caller decide THIS day).
   3  WHO DECIDES IS A PERMISSION (Security > Role permissions, card Attendance) - no longer "whoever holds
      EMP_VIEW_ALL":
        OFFROSTER_TODAY   decide a day of today
        OFFROSTER_PAST    decide a past day
      Branch scope is unchanged: without EMP_VIEW_ALL a caller acts only on the branches they manage (the branch of
      the DAY). Both permissions are read from the role tables at the moment of the action.
      DEFAULT GRANTS, made ONCE - on the run that creates each code, never again, so a re-run cannot hand back what an
      administrator un-ticked:
        OFFROSTER_TODAY -> the roles 'Manager' and 'HR', and every role that holds ATTENDANCE_MANAGE (they add
                           today's row on the Roster page today);
        OFFROSTER_PAST  -> the role 'HR', and every role that holds ATTENDANCE_MANAGE and EMP_VIEW_ALL (the people
                           script 102 let add a missing past day).
      So nobody loses anything they could do before this script. Who got what is printed (OWNER CHECK).
   4  THE ROSTER PAGE IS THE SAME DOOR. attendance.usp_Roster_AssertEditable (the guard of every roster writer) reads
      the two permissions: a missing PAST day of an approved month needs OFFROSTER_PAST (it was EMP_VIEW_ALL); a
      missing row for TODAY for somebody who has ALREADY PUNCHED today needs OFFROSTER_TODAY. Planning today for
      people who have not punched, and every future day, are untouched.
      attendance.usp_ShiftAssignment_Upsert records the decision whichever door it came through, derives TODAY's day
      at once when it already has punches (it derived past days only: the day then showed nowhere until the next
      punch), and takes @Quiet (last, default 0: no result set).
   5  PAYROLL. attendance.fn_PayrollReadiness gains UndecidedUnrosteredDays (completed days of the period that are
      not on the roster, not dismissed and not in a period already paid for the employee) and UnrosteredDaysBlock.
      Setting OffRosterBlocksPayrollFrom (Payroll, yyyy-MM): from that month on an undecided day makes the period
      NOT ready; before it the days are counted and shown but block nothing. Seeded with the month AFTER the one
      this script is first applied in (one month of warning), empty = never blocks. A re-run keeps the value chosen.
      payroll.usp_PayrollRun_AssertReady names the reason. attendance.usp_Attendance_PayrollReadiness keeps its 11
      columns (its INSERT ... EXEC callers); the API reads attendance.usp_PayrollReadiness_Get (every column) -
      the last procedure this script creates, and its marker in Scripts.Required and deploy/check-scripts.sql.

   NOT CHANGED: usp_Attendance_ComputeDay, the anomaly rules, what a day is paid, the roster approval workflow. A day
   added to an approved month still reads "changed since approval", as every roster change does.

   STALE-COPY GUARDS. Four objects are redefined from script 102 / 103 text: the first batches stop the whole script
   (nothing applied) when the live copy has a parameter this script does not know or does not hold the text the
   repo copy holds - it is then newer than the repo and is merged by hand.

   Needs: 87 (hr.fn_CallerScope), 100, 102, 103. Idempotent. Every refusal is RAISERROR(msg,16,1) + RETURN 1
   (ROLLBACK first inside its own transaction). Pure ASCII: an em dash in a message is NCHAR(8212).
   Apply with sqlcmd -C -I -b.
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

/* ------------------------- prerequisites and stale-copy guards (nothing changes before these pass) ------------------------- */
IF OBJECT_ID('hr.fn_CallerScope') IS NULL OR OBJECT_ID('attendance.usp_Roster_GetLeaveDays') IS NULL
   OR OBJECT_ID('attendance.fn_PayrollReadiness') IS NULL OR OBJECT_ID('payroll.usp_PayrollRun_AssertReady') IS NULL
   OR OBJECT_ID('attendance.fn_AttributedWorkDate') IS NULL OR OBJECT_ID('payroll.fn_IsPeriodPaid') IS NULL
BEGIN RAISERROR('108_unrostered_days.sql needs scripts 87, 102 and 103 (hr.fn_CallerScope, attendance.usp_Roster_GetLeaveDays, attendance.fn_PayrollReadiness, payroll.usp_PayrollRun_AssertReady). Nothing was applied.', 16, 1); SET NOEXEC ON; END
GO
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('attendance.usp_Roster_AssertEditable')
           AND name NOT IN (N'@CallerUserId', N'@AllowPastInsert'))
   OR ISNULL(OBJECT_DEFINITION(OBJECT_ID('attendance.usp_Roster_AssertEditable')), N'') NOT LIKE N'%a generator does not fill it%'
BEGIN RAISERROR('108_unrostered_days.sql: the live attendance.usp_Roster_AssertEditable is not the copy of script 102 (a parameter this script does not know, or its text differs). Merge by hand; nothing was applied.', 16, 1); SET NOEXEC ON; END
GO
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('attendance.usp_ShiftAssignment_Upsert')
           AND name NOT IN (N'@EmployeeId', N'@WorkDate', N'@ShiftId', N'@IsRestDay', N'@CallerUserId', N'@Quiet'))
   OR ISNULL(OBJECT_DEFINITION(OBJECT_ID('attendance.usp_ShiftAssignment_Upsert')), N'') NOT LIKE N'%@AllowPastInsert = 1%'
BEGIN RAISERROR('108_unrostered_days.sql: the live attendance.usp_ShiftAssignment_Upsert is not the copy of script 102 (a parameter this script does not know, or its text differs). Merge by hand; nothing was applied.', 16, 1); SET NOEXEC ON; END
GO
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('attendance.fn_PayrollReadiness')
           AND name NOT IN (N'@PeriodYearMonth', N'@AsOfDate'))
   OR ISNULL(OBJECT_DEFINITION(OBJECT_ID('attendance.fn_PayrollReadiness')), N'') NOT LIKE N'%RosteredDaysWithNoRecord%CountedUpTo%'
   OR EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('attendance.fn_PayrollReadiness')
              AND name NOT IN (N'PeriodYearMonth', N'PeriodStart', N'PeriodEnd', N'UnprocessedPunches', N'UnresolvedPinPunches',
                               N'OpenAnomalies', N'PendingCorrections', N'RosteredDaysWithNoRecord', N'UndecidedExitVariances',
                               N'UndecidedAnomalies', N'IsReady', N'CountedUpTo', N'UndecidedUnrosteredDays', N'UnrosteredDaysBlock'))
BEGIN RAISERROR('108_unrostered_days.sql: the live attendance.fn_PayrollReadiness is not the copy of script 103 (a parameter or a column this script does not know). Merge by hand; nothing was applied.', 16, 1); SET NOEXEC ON; END
GO
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('payroll.usp_PayrollRun_AssertReady')
           AND name NOT IN (N'@PeriodYearMonth', N'@AsOfDate'))
   OR ISNULL(OBJECT_DEFINITION(OBJECT_ID('payroll.usp_PayrollRun_AssertReady')), N'') NOT LIKE N'%Open the readiness check and clear the counts%'
BEGIN RAISERROR('108_unrostered_days.sql: the live payroll.usp_PayrollRun_AssertReady is not the copy of script 103 (a parameter this script does not know, or its text differs). Merge by hand; nothing was applied.', 16, 1); SET NOEXEC ON; END
GO

/* ==================================== 1. the two permissions, granted once ==================================== */
DECLARE @new TABLE (Code VARCHAR(50) NOT NULL);
IF NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'OFFROSTER_TODAY')
BEGIN
    INSERT INTO security.PERMISSION (Code, Name, Module)
    VALUES ('OFFROSTER_TODAY', N'Decide a day that is not on the roster: today', 'Attendance');
    INSERT INTO @new (Code) VALUES ('OFFROSTER_TODAY');
    PRINT 'permission OFFROSTER_TODAY created';
END
ELSE PRINT 'permission OFFROSTER_TODAY already there (its role grants are left as they are)';
IF NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'OFFROSTER_PAST')
BEGIN
    INSERT INTO security.PERMISSION (Code, Name, Module)
    VALUES ('OFFROSTER_PAST', N'Decide a day that is not on the roster: past days', 'Attendance');
    INSERT INTO @new (Code) VALUES ('OFFROSTER_PAST');
    PRINT 'permission OFFROSTER_PAST created';
END
ELSE PRINT 'permission OFFROSTER_PAST already there (its role grants are left as they are)';

/* the default grants - ONLY for a code created just now (a re-run never grants again: the Role permissions page deletes
   an un-ticked row, so "not granted" and "taken away" look the same afterwards) */
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
SELECT r.RoleId, p.PermissionId
FROM security.[ROLE] r
JOIN security.PERMISSION p ON p.Code IN (SELECT Code FROM @new)
WHERE NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION x WHERE x.RoleId = r.RoleId AND x.PermissionId = p.PermissionId)
  AND (   (p.Code = 'OFFROSTER_TODAY'
           AND (r.Name IN (N'Manager', N'HR')
                OR EXISTS (SELECT 1 FROM security.ROLE_PERMISSION rp JOIN security.PERMISSION q ON q.PermissionId = rp.PermissionId
                           WHERE rp.RoleId = r.RoleId AND q.Code = 'ATTENDANCE_MANAGE')))
       OR (p.Code = 'OFFROSTER_PAST'
           AND (r.Name = N'HR'
                OR (    EXISTS (SELECT 1 FROM security.ROLE_PERMISSION rp JOIN security.PERMISSION q ON q.PermissionId = rp.PermissionId
                                WHERE rp.RoleId = r.RoleId AND q.Code = 'ATTENDANCE_MANAGE')
                    AND EXISTS (SELECT 1 FROM security.ROLE_PERMISSION rp JOIN security.PERMISSION q ON q.PermissionId = rp.PermissionId
                                WHERE rp.RoleId = r.RoleId AND q.Code = 'EMP_VIEW_ALL')))));
PRINT CONCAT('default role grants made now: ', @@ROWCOUNT);
GO

/* ==================================== 2. the setting: from which month an undecided day blocks payroll ==================================== */
DECLARE @s TABLE (SettingKey VARCHAR(60), SettingValue NVARCHAR(200), DataType VARCHAR(60), [Description] NVARCHAR(300), Section VARCHAR(30), SortOrder INT);
INSERT INTO @s (SettingKey, SettingValue, DataType, [Description], Section, SortOrder) VALUES
 ('OffRosterBlocksPayrollFrom',
  /* one month of warning: the month AFTER the one this script is first applied in */
  CONVERT(CHAR(7), DATEADD(MONTH, 1, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE)), 23),
  'month',
  N'A day somebody punched on that the approved roster does not know must be decided (Attendance > Daily attendance). From this month on (yyyy-MM) an undecided one blocks the payroll run of its month; before it, such days are only counted. Empty = they never block.',
  'Payroll', 48);

INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, [Description], Section, SortOrder, ModifiedAt)
SELECT s.SettingKey, s.SettingValue, s.DataType, s.[Description], s.Section, s.SortOrder, SYSUTCDATETIME()
FROM @s s
WHERE NOT EXISTS (SELECT 1 FROM core.SETTING x WHERE x.SettingKey = s.SettingKey);
PRINT CONCAT('SETTINGS | Payroll: ', @@ROWCOUNT, ' new key(s)');

/* a re-run keeps the value chosen; the type, the description and the place on the Settings page follow this script */
UPDATE x
SET x.DataType = s.DataType, x.[Description] = s.[Description], x.Section = s.Section, x.SortOrder = s.SortOrder
FROM core.SETTING x
JOIN @s s ON s.SettingKey = x.SettingKey;
GO

/* ==================================== 3. the decisions on file ==================================== */
/* One row per decision; IsCurrent = 1 on the latest decision of an employee-day (the procedures below keep it so).
   PunchCount / FirstPunch / LastPunch are the punches the decision ANSWERED, exactly as the list showed them (the
   terminal's wall clock, as RAW_DEVICE_LOG stores it). A dismissal stands only while they still equal the day's. */
IF OBJECT_ID('attendance.UNROSTERED_DAY_DECISION') IS NULL
BEGIN
    CREATE TABLE attendance.UNROSTERED_DAY_DECISION (
        DecisionId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_UNROSTERED_DAY_DECISION PRIMARY KEY,
        EmployeeId        INT NOT NULL CONSTRAINT FK_UNROSTERED_DAY_DECISION_Employee REFERENCES hr.EMPLOYEE (EmployeeId),
        WorkDate          DATE NOT NULL,
        Decision          VARCHAR(10) NOT NULL
                          CONSTRAINT CK_UNROSTERED_DAY_DECISION_Decision CHECK (Decision IN ('Shift', 'RestDay', 'Dismissed')),
        ShiftId           INT NULL,                -- the shift chosen ('Shift')
        ShiftAssignmentId INT NULL,                -- the roster row the decision added ('Shift', 'RestDay'); not a foreign key: history outlives a row
        Note              NVARCHAR(400) NULL,      -- required for 'Dismissed'
        PunchCount        INT NOT NULL,
        FirstPunch        DATETIME2 NOT NULL,
        LastPunch         DATETIME2 NOT NULL,
        DecidedByUserId   INT NULL,                -- NULL = the system itself (never through the API)
        DecidedAtUtc      DATETIME2(3) NOT NULL CONSTRAINT DF_UNROSTERED_DAY_DECISION_DecidedAt DEFAULT SYSUTCDATETIME(),
        ReopenedByUserId  INT NULL,                -- a dismissal taken back by hand
        ReopenedAtUtc     DATETIME2(3) NULL,
        IsCurrent         BIT NOT NULL CONSTRAINT DF_UNROSTERED_DAY_DECISION_IsCurrent DEFAULT 1
    );
    CREATE INDEX IX_UNROSTERED_DAY_DECISION_Day ON attendance.UNROSTERED_DAY_DECISION (EmployeeId, WorkDate, IsCurrent);
    PRINT 'table attendance.UNROSTERED_DAY_DECISION created';
END
GO

/* ==================================== 4. may this caller decide a day of that date? ==================================== */
/* The permission only: OFFROSTER_TODAY for today, OFFROSTER_PAST for a day before it. Branch scope is the caller's
   procedure's own business (hr.fn_CallerScope + the manager of the branch of the day). NULL = the system: yes. */
CREATE OR ALTER FUNCTION attendance.fn_MayDecideUnrostered (@CallerUserId INT, @WorkDate DATE)
RETURNS BIT
AS
BEGIN
    IF @CallerUserId IS NULL RETURN 1;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @Code VARCHAR(50) = CASE WHEN @WorkDate >= @Today THEN 'OFFROSTER_TODAY' ELSE 'OFFROSTER_PAST' END;
    RETURN CASE WHEN EXISTS (SELECT 1
                             FROM security.USER_ROLE ur
                             JOIN security.ROLE_PERMISSION rp ON rp.RoleId = ur.RoleId
                             JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
                             WHERE ur.UserId = @CallerUserId AND p.Code = @Code) THEN 1 ELSE 0 END;
END;
GO

/* ==================================== 5. the days themselves ==================================== */
/* Employee-days that have punches but no attendance record because the APPROVED roster of the month gives the employee
   no row for the day - the predicate of attendance.usp_Attendance_GetWorkedWithoutRoster (script 87), word for word,
   for everybody (no caller scope: the readers add their own). FirstPunch / LastPunch are every raw punch attributed
   to the day (no debounce, either direction). IsDismissed = 1 while the current decision is a dismissal that still
   answers these very punches. */
CREATE OR ALTER FUNCTION attendance.fn_UnrosteredDays (@FromDate DATE, @ToDate DATE)
RETURNS TABLE
AS RETURN
WITH p AS (
    SELECT r.EmployeeId, attendance.fn_AttributedWorkDate(r.EmployeeId, r.PunchTimeUtc) AS WorkDate, r.PunchTimeUtc
    FROM attendance.RAW_DEVICE_LOG r
    WHERE r.EmployeeId IS NOT NULL
      AND r.PunchTimeUtc >= CAST(@FromDate AS DATETIME2) AND r.PunchTimeUtc < CAST(DATEADD(DAY, 2, @ToDate) AS DATETIME2)
), d AS (
    SELECT p.EmployeeId, p.WorkDate, MIN(p.PunchTimeUtc) AS FirstPunch, MAX(p.PunchTimeUtc) AS LastPunch, COUNT(*) AS PunchCount
    FROM p WHERE p.WorkDate BETWEEN @FromDate AND @ToDate
    GROUP BY p.EmployeeId, p.WorkDate
)
SELECT d.EmployeeId, d.WorkDate, x.BranchId, d.FirstPunch, d.LastPunch, d.PunchCount,
       DATEDIFF(MINUTE, d.FirstPunch, d.LastPunch) AS WorkedMinutes,
       k.DecisionId AS DismissalId,
       CAST(CASE WHEN k.DecisionId IS NOT NULL AND k.PunchCount = d.PunchCount
                      AND k.FirstPunch = d.FirstPunch AND k.LastPunch = d.LastPunch THEN 1 ELSE 0 END AS BIT) AS IsDismissed
FROM d
JOIN hr.EMPLOYEE e ON e.EmployeeId = d.EmployeeId AND e.IsDeleted = 0
CROSS APPLY (SELECT hr.fn_EmployeeBranchOn(d.EmployeeId, d.WorkDate) AS BranchId) x
OUTER APPLY (SELECT TOP 1 c.DecisionId, c.PunchCount, c.FirstPunch, c.LastPunch
             FROM attendance.UNROSTERED_DAY_DECISION c
             WHERE c.EmployeeId = d.EmployeeId AND c.WorkDate = d.WorkDate AND c.IsCurrent = 1 AND c.Decision = 'Dismissed'
             ORDER BY c.DecisionId DESC) k
WHERE EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
              WHERE rm.BranchId = x.BranchId AND rm.MonthDate = DATEFROMPARTS(YEAR(d.WorkDate), MONTH(d.WorkDate), 1) AND rm.[Status] = 'Approved')
  AND NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa WHERE sa.EmployeeId = d.EmployeeId AND sa.WorkDate = d.WorkDate)
  AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = d.EmployeeId AND a.WorkDate = d.WorkDate);
GO

/* ==================================== 6. the roster guard reads the two permissions ==================================== */
/* The body of script 102 (the guard of EVERY roster writer), with three changes, all marked 108:
   - @MayToday / @MayPast: attendance.fn_MayDecideUnrostered for the caller;
   - a missing row for TODAY for somebody who has already punched today needs OFFROSTER_TODAY;
   - a missing PAST day needs OFFROSTER_PAST (it was @SeesAll, i.e. EMP_VIEW_ALL). */
CREATE OR ALTER PROCEDURE attendance.usp_Roster_AssertEditable
    @CallerUserId    INT = NULL,
    @AllowPastInsert BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF OBJECT_ID('tempdb..#roster_change') IS NULL RETURN 0;
    IF NOT EXISTS (SELECT 1 FROM #roster_change) RETURN 0;

    DECLARE @msg NVARCHAR(400);

    /* a row for somebody who does not exist would otherwise die on the foreign key */
    IF EXISTS (SELECT 1 FROM #roster_change c
               WHERE NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE e WHERE e.EmployeeId = c.EmployeeId))
    BEGIN RAISERROR('Employee not found.', 16, 1); RETURN 1; END

    /* 102 (ROS-14): whose roster this caller may change */
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    IF @SeesAll = 0 AND EXISTS (
        SELECT 1
        FROM #roster_change c
        WHERE NOT EXISTS (SELECT 1 FROM hr.BRANCH b
                          WHERE b.BranchId = hr.fn_EmployeeBranchOn(c.EmployeeId, c.WorkDate)
                            AND b.ManagerEmployeeId = @CallerEmp))
    BEGIN RAISERROR('You can only plan rosters for the branches you manage.', 16, 1); RETURN 1; END

    /* script 85 (D10): a day that is already PAID for the employee is not re-rostered - that is a payroll adjustment */
    IF EXISTS (SELECT 1 FROM #roster_change c WHERE payroll.fn_IsPeriodPaid(c.EmployeeId, c.WorkDate) = 1)
    BEGIN
        SET @msg = N'This period is paid ' + NCHAR(8212) + N' raise a payroll adjustment instead.';
        RAISERROR(@msg, 16, 1); RETURN 1;
    END

    /* (a) a branch-month with an OPEN roster request is read-only; "the branch" is the one of the day (D7) */
    DECLARE @OpenRid INT = (
        SELECT TOP 1 ri.RequestInstanceId
        FROM #roster_change c
        JOIN workflow.ROSTER_APPROVAL ra ON ra.BranchId = hr.fn_EmployeeBranchOn(c.EmployeeId, c.WorkDate)
                                        AND ra.MonthDate = DATEFROMPARTS(YEAR(c.WorkDate), MONTH(c.WorkDate), 1)
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
        WHERE ri.[Status] IN ('Draft', 'Pending', 'OnHold')
        ORDER BY ri.RequestInstanceId DESC);
    IF @OpenRid IS NOT NULL
    BEGIN
        SET @msg = N'Waiting for approval ' + NCHAR(8212) + N' request #%d. Withdraw or wait for the decision before editing.';
        RAISERROR(@msg, 16, 1, @OpenRid);
        RETURN 1;
    END

    /* (b) in an APPROVED month, the past - and any day attendance already judged - is a record */
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    /* 108: who may add a day the approved roster does not know is read from two permissions (Role permissions,
       card Attendance) - no longer "whoever holds EMP_VIEW_ALL". NULL = the system itself: allowed. */
    DECLARE @MayToday BIT = attendance.fn_MayDecideUnrostered(@CallerUserId, @Today),
            @MayPast  BIT = attendance.fn_MayDecideUnrostered(@CallerUserId, DATEADD(DAY, -1, @Today));
    DECLARE @locked TABLE (EmployeeId INT NOT NULL, WorkDate DATE NOT NULL, IsRecorded BIT NOT NULL, IsInsert BIT NOT NULL);
    INSERT INTO @locked (EmployeeId, WorkDate, IsRecorded, IsInsert)
    SELECT c.EmployeeId, c.WorkDate,
           CASE WHEN EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD ar
                             WHERE ar.EmployeeId = c.EmployeeId AND ar.WorkDate = c.WorkDate) THEN 1 ELSE 0 END,
           CASE WHEN EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                             WHERE sa.EmployeeId = c.EmployeeId AND sa.WorkDate = c.WorkDate) THEN 0 ELSE 1 END
    FROM #roster_change c
    JOIN attendance.ROSTER_MONTH rm ON rm.BranchId = hr.fn_EmployeeBranchOn(c.EmployeeId, c.WorkDate)
                                   AND rm.MonthDate = DATEFROMPARTS(YEAR(c.WorkDate), MONTH(c.WorkDate), 1)
                                   AND rm.[Status] = 'Approved';
    /* 108: a MISSING row for TODAY, for somebody who has ALREADY PUNCHED today, is a "not on roster" day being
       decided - that takes the permission for today. Planning today for people who have not punched, and every
       future day, stay as they were. */
    IF @MayToday = 0 AND EXISTS (
        SELECT 1 FROM @locked l
        WHERE l.WorkDate = @Today AND l.IsInsert = 1 AND l.IsRecorded = 0
          AND EXISTS (SELECT 1 FROM attendance.RAW_DEVICE_LOG r
                      WHERE r.EmployeeId = l.EmployeeId
                        AND r.PunchTimeUtc >= CAST(l.WorkDate AS DATETIME2)
                        AND r.PunchTimeUtc <  CAST(DATEADD(DAY, 2, l.WorkDate) AS DATETIME2)
                        AND attendance.fn_AttributedWorkDate(r.EmployeeId, r.PunchTimeUtc) = l.WorkDate))
    BEGIN
        SET @msg = N'This day is already in an approved roster month and the employee has punched today ' + NCHAR(8212) + N' adding the day needs the permission to decide today''s days that are not on the roster.';
        RAISERROR(@msg, 16, 1); RETURN 1;
    END
    DELETE FROM @locked WHERE IsRecorded = 0 AND WorkDate >= @Today;      -- a future day may still change

    IF EXISTS (SELECT 1 FROM @locked WHERE IsRecorded = 1)
    BEGIN
        SET @msg = N'This day is already in an approved roster and attendance was recorded ' + NCHAR(8212) + N' correct the attendance record instead.';
        RAISERROR(@msg, 16, 1); RETURN 1;
    END
    IF EXISTS (SELECT 1 FROM @locked WHERE IsInsert = 0)
    BEGIN
        SET @msg = N'This day is already in an approved roster and is in the past ' + NCHAR(8212) + N' it can no longer be changed.';
        RAISERROR(@msg, 16, 1); RETURN 1;
    END
    /* what is left are MISSING past days with no record (the "not on roster" days): added one by one, by whoever
       holds the permission for past days (108; it was "HR", meaning EMP_VIEW_ALL, in script 102) */
    IF EXISTS (SELECT 1 FROM @locked) AND @AllowPastInsert = 0
    BEGIN
        SET @msg = N'This day is already in an approved roster and is in the past ' + NCHAR(8212) + N' a generator does not fill it; HR can add the missing day on its own.';
        RAISERROR(@msg, 16, 1); RETURN 1;
    END
    IF EXISTS (SELECT 1 FROM @locked) AND @MayPast = 0
    BEGIN
        SET @msg = N'This day is already in an approved roster and is in the past ' + NCHAR(8212) + N' adding the missing day needs the permission to decide past days that are not on the roster.';
        RAISERROR(@msg, 16, 1); RETURN 1;
    END

    RETURN 0;
END;
GO

/* ==================================== 7. the one-cell writer: files the decision, derives today, @Quiet ==================================== */
/* The body of script 102, with four changes, all marked 108:
   - @Quiet (last, default 0): 1 = no result set;
   - the facts of a "not on roster" day are read before the write;
   - adding such a day files the decision (attendance.UNROSTERED_DAY_DECISION), whichever page it came from;
   - TODAY's day is derived at once when it already has punches (past days were, and still are). */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_Upsert
    @EmployeeId INT, @WorkDate DATE, @ShiftId INT = NULL, @IsRestDay BIT = 0,
    @CallerUserId INT = NULL,         -- 102 (ROS-14): the signed-in user; NULL = the system
    @Quiet BIT = 0                    -- 108: 1 = no result set (attendance.usp_UnrosteredDay_Decide calls it)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @msg NVARCHAR(400), @Name NVARCHAR(150), @Hire DATE, @Term DATE, @DayText VARCHAR(20), @BoundText VARCHAR(20);
    SET @IsRestDay = ISNULL(@IsRestDay, 0);

    IF @ShiftId IS NULL AND @IsRestDay = 0
    BEGIN RAISERROR('Choose a shift, or mark the day as a rest day.', 16, 1); RETURN 1; END

    /* 102 (ROS-1): nobody is rostered outside their employment */
    SELECT @Name = FullName, @Hire = HireDate, @Term = TerminationDate FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId;
    IF @Name IS NOT NULL AND (@WorkDate < @Hire OR @WorkDate > @Term)
    BEGIN
        SET @DayText = CONVERT(VARCHAR(11), @WorkDate, 106);
        IF @WorkDate < @Hire
        BEGIN
            SET @BoundText = CONVERT(VARCHAR(11), @Hire, 106);
            SET @msg = N'%s is not employed yet on %s ' + NCHAR(8212) + N' the employment starts on %s.';
        END
        ELSE
        BEGIN
            SET @BoundText = CONVERT(VARCHAR(11), @Term, 106);
            SET @msg = N'%s is no longer employed on %s ' + NCHAR(8212) + N' the employment ended on %s.';
        END
        RAISERROR(@msg, 16, 1, @Name, @DayText, @BoundText);
        RETURN 1;
    END

    /* 102 (ROS-9): a retired shift is never rostered again (a day that already has it may keep it) */
    IF @IsRestDay = 0
       AND EXISTS (SELECT 1 FROM attendance.SHIFT WHERE ShiftId = @ShiftId AND IsActive = 0)
       AND NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT
                       WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate AND ShiftId = @ShiftId AND IsRestDay = 0)
    BEGIN
        SET @msg = N'That shift is retired ' + NCHAR(8212) + N' choose an active shift.';
        RAISERROR(@msg, 16, 1); RETURN 1;
    END

    /* 108: is this a "not on roster" day - punches, an approved month, no row, no record? Its facts are read BEFORE
       the write, because the write is what takes the day off that list. NULL = it is not one. */
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @UFirst DATETIME2, @ULast DATETIME2, @UCount INT;
    IF @WorkDate <= @Today
        SELECT @UFirst = FirstPunch, @ULast = LastPunch, @UCount = PunchCount
        FROM attendance.fn_UnrosteredDays(@WorkDate, @WorkDate) WHERE EmployeeId = @EmployeeId;

    IF OBJECT_ID('tempdb..#roster_change') IS NOT NULL DROP TABLE #roster_change;
    CREATE TABLE #roster_change (EmployeeId INT NOT NULL, WorkDate DATE NOT NULL);
    INSERT INTO #roster_change (EmployeeId, WorkDate)
    SELECT @EmployeeId, @WorkDate
    WHERE NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT
                      WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate
                        AND ISNULL(ShiftId, -1) = ISNULL(@ShiftId, -1) AND IsRestDay = @IsRestDay);
    DECLARE @rc INT;
    EXEC @rc = attendance.usp_Roster_AssertEditable @CallerUserId = @CallerUserId, @AllowPastInsert = 1;
    DROP TABLE #roster_change;
    IF @rc <> 0 RETURN 1;

    DECLARE @Inserted BIT = 0;
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT
               WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate)
        /* a no-op click must not mark the roster as changed */
        UPDATE attendance.SHIFT_ASSIGNMENT
        SET ShiftId = @ShiftId, IsRestDay = @IsRestDay, ModifiedUtc = SYSUTCDATETIME()
        WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate
          AND (ISNULL(ShiftId, -1) <> ISNULL(@ShiftId, -1) OR IsRestDay <> @IsRestDay);
    ELSE
    BEGIN
        INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay, ModifiedUtc)
        VALUES (@EmployeeId, @ShiftId, @WorkDate, @IsRestDay, SYSUTCDATETIME());
        SET @Inserted = 1;
    END

    /* 108: adding the row of a "not on roster" day IS the decision on it, through whichever door it came (the
       Roster page or the decision on the Daily attendance page): who decided, when, and the punches the decision
       answered are kept. A dismissal of the same day no longer stands. */
    IF @Inserted = 1 AND @UCount IS NOT NULL
    BEGIN
        /* the new row first, the older ones retired after it: if the INSERT fails, nothing has changed */
        DECLARE @NewDecision INT;
        INSERT INTO attendance.UNROSTERED_DAY_DECISION
            (EmployeeId, WorkDate, Decision, ShiftId, ShiftAssignmentId, PunchCount, FirstPunch, LastPunch, DecidedByUserId)
        SELECT @EmployeeId, @WorkDate, CASE WHEN @IsRestDay = 1 THEN 'RestDay' ELSE 'Shift' END, @ShiftId,
               sa.ShiftAssignmentId, @UCount, @UFirst, @ULast, @CallerUserId
        FROM attendance.SHIFT_ASSIGNMENT sa WHERE sa.EmployeeId = @EmployeeId AND sa.WorkDate = @WorkDate;
        SET @NewDecision = SCOPE_IDENTITY();
        IF @NewDecision IS NOT NULL
            UPDATE attendance.UNROSTERED_DAY_DECISION SET IsCurrent = 0
            WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate AND IsCurrent = 1 AND DecisionId <> @NewDecision;
    END

    /* 102 (ROS-6): a missing day added to the past of an APPROVED month is derived now - the punches of a
       "not on roster" day become an attendance record (the guard let it through: no record, not paid).
       108: so is TODAY's day when it already has punches - today's punches were processed when they arrived
       (with nothing to write), so without this the day would show nowhere until the next punch. A day of today
       nobody has punched on, and every future day, are still not derived here. */
    IF @Inserted = 1 AND (@WorkDate < @Today OR (@WorkDate = @Today AND @UCount IS NOT NULL))
       AND EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                   WHERE rm.BranchId = hr.fn_EmployeeBranchOn(@EmployeeId, @WorkDate)
                     AND rm.MonthDate = DATEFROMPARTS(YEAR(@WorkDate), MONTH(@WorkDate), 1)
                     AND rm.[Status] = 'Approved')
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @EmployeeId, @WorkDate = @WorkDate;

    IF ISNULL(@Quiet, 0) = 0
        SELECT ShiftAssignmentId FROM attendance.SHIFT_ASSIGNMENT
        WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate;
    RETURN 0;
END;
GO

/* ==================================== 8. the list for the pages ==================================== */
/* Every "not on roster" day of the range the caller may see (EMP_VIEW_ALL: all; otherwise their own days and the
   branches they manage), open and dismissed alike.
     State             'Open' | 'Dismissed' (a dismissal that still answers the day's punches)
     PunchesChanged    1 = it WAS dismissed and punches have arrived or changed since: open again (the old note is shown)
     CanDecide         may THIS caller decide THIS day: the permission of its date, the branch, and not a paid period
     IsPaid            the period is paid for the employee: read-only, a payroll adjustment is the only way
     OutsideEmployment before the hire date or after the termination date: it can be dismissed, not added
     OpenRosterRequestId  the roster of the branch-month is waiting for approval: adding waits for it, dismissing does not
   Not for INSERT ... EXEC: columns may be added. */
CREATE OR ALTER PROCEDURE attendance.usp_UnrosteredDay_GetList
    @FromDate DATE, @ToDate DATE, @BranchId INT = NULL, @EmployeeId INT = NULL,
    @CallerUserId INT = NULL          -- the signed-in user; NULL = the system (everything)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @MayToday BIT = attendance.fn_MayDecideUnrostered(@CallerUserId, @Today),
            @MayPast  BIT = attendance.fn_MayDecideUnrostered(@CallerUserId, DATEADD(DAY, -1, @Today));

    SELECT u.EmployeeId, e.FullName AS EmployeeName, u.BranchId, b.Name AS BranchName, u.WorkDate,
           u.FirstPunch, u.LastPunch, u.PunchCount, u.WorkedMinutes,
           CAST(CASE WHEN u.WorkDate >= @Today THEN 1 ELSE 0 END AS BIT) AS IsToday,
           f.IsPaid,
           CAST(CASE WHEN u.WorkDate < e.HireDate OR u.WorkDate > e.TerminationDate THEN 1 ELSE 0 END AS BIT) AS OutsideEmployment,
           h.Name AS HolidayName, h.NameAr AS HolidayNameAr,
           o.OpenRosterRequestId,
           ISNULL(ot.ApprovedOvertimeMinutes, 0) AS ApprovedOvertimeMinutes,
           CASE WHEN u.IsDismissed = 1 THEN 'Dismissed' ELSE 'Open' END AS [State],
           k.Note AS DismissNote, dn.DismissedBy, k.DecidedAtUtc AS DismissedAtUtc,
           CAST(CASE WHEN k.DecisionId IS NOT NULL AND u.IsDismissed = 0 THEN 1 ELSE 0 END AS BIT) AS PunchesChanged,
           CAST(CASE WHEN f.IsPaid = 1 THEN 0
                     WHEN (CASE WHEN u.WorkDate >= @Today THEN @MayToday ELSE @MayPast END) = 0 THEN 0
                     WHEN @SeesAll = 1 THEN 1
                     WHEN EXISTS (SELECT 1 FROM hr.BRANCH mb WHERE mb.ManagerEmployeeId = @CallerEmp AND mb.BranchId = u.BranchId) THEN 1
                     ELSE 0 END AS BIT) AS CanDecide
    FROM attendance.fn_UnrosteredDays(@FromDate, @ToDate) u
    JOIN hr.EMPLOYEE e ON e.EmployeeId = u.EmployeeId
    JOIN hr.BRANCH b ON b.BranchId = u.BranchId
    CROSS APPLY (SELECT CAST(payroll.fn_IsPeriodPaid(u.EmployeeId, u.WorkDate) AS BIT) AS IsPaid) f
    OUTER APPLY (SELECT TOP 1 hd.Name, hd.NameAr FROM core.HOLIDAY hd
                 WHERE hd.HolidayDate = u.WorkDate AND (hd.BranchId IS NULL OR hd.BranchId = u.BranchId)
                 ORDER BY hd.BranchId DESC) h
    OUTER APPLY (SELECT TOP 1 ri.RequestInstanceId AS OpenRosterRequestId
                 FROM workflow.ROSTER_APPROVAL ra
                 JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
                 WHERE ra.BranchId = u.BranchId AND ra.MonthDate = DATEFROMPARTS(YEAR(u.WorkDate), MONTH(u.WorkDate), 1)
                   AND ri.[Status] IN ('Draft', 'Pending', 'OnHold')
                 ORDER BY ri.RequestInstanceId DESC) o
    OUTER APPLY (SELECT SUM(ISNULL(ovt.ApprovedMinutes, 0)) AS ApprovedOvertimeMinutes
                 FROM workflow.OVERTIME_REQUEST ovt
                 JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ovt.RequestInstanceId
                 WHERE ovt.EmployeeId = u.EmployeeId AND ovt.WorkDate = u.WorkDate AND ri.[Status] = 'Approved') ot
    /* the latest dismissal of the day, whether it still stands or the punches have changed since */
    OUTER APPLY (SELECT TOP 1 c.DecisionId, c.Note, c.DecidedByUserId, c.DecidedAtUtc
                 FROM attendance.UNROSTERED_DAY_DECISION c
                 WHERE c.EmployeeId = u.EmployeeId AND c.WorkDate = u.WorkDate AND c.IsCurrent = 1 AND c.Decision = 'Dismissed'
                 ORDER BY c.DecisionId DESC) k
    OUTER APPLY (SELECT COALESCE((SELECT TOP 1 de.FullName FROM hr.EMPLOYEE de WHERE de.UserId = k.DecidedByUserId AND de.IsDeleted = 0 ORDER BY de.EmployeeId),
                                 (SELECT du.Username FROM security.[USER] du WHERE du.UserId = k.DecidedByUserId)) AS DismissedBy) dn
    WHERE (@BranchId IS NULL OR u.BranchId = @BranchId)
      AND (@EmployeeId IS NULL OR u.EmployeeId = @EmployeeId)
      AND (@SeesAll = 1 OR u.EmployeeId = @CallerEmp
           OR EXISTS (SELECT 1 FROM hr.BRANCH mb WHERE mb.ManagerEmployeeId = @CallerEmp AND mb.BranchId = u.BranchId))
    ORDER BY u.WorkDate DESC, e.FullName;
END;
GO

/* ==================================== 9. the decision ==================================== */
/* @Decision 'Shift' (with @ShiftId) | 'RestDay' | 'Dismiss' (with @Note). Its own checks are the ones that concern the
   DECISION: still an open day, the caller's branch, the permission of the date, a paid period. Adding the day then goes
   through attendance.usp_ShiftAssignment_Upsert, so every rule of the roster holds as it does on the Roster page
   (the employment window, a retired shift, a roster waiting for approval, ...) with the roster's own sentences.
   One result row: EmployeeId, WorkDate, Decision, ShiftAssignmentId, AttendanceId (the day just derived, or NULL). */
CREATE OR ALTER PROCEDURE attendance.usp_UnrosteredDay_Decide
    @EmployeeId INT, @WorkDate DATE,
    @Decision VARCHAR(10),
    @ShiftId INT = NULL,
    @Note NVARCHAR(400) = NULL,
    @CallerUserId INT = NULL          -- the signed-in user; NULL = the system
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @msg NVARCHAR(400);
    SET @Note = NULLIF(LTRIM(RTRIM(ISNULL(@Note, N''))), N'');

    IF @Decision IS NULL OR @Decision NOT IN ('Shift', 'RestDay', 'Dismiss')
    BEGIN RAISERROR('Choose what the day was: a shift, a rest day that was worked, or not work.', 16, 1); RETURN 1; END
    IF @Decision = 'Shift' AND @ShiftId IS NULL
    BEGIN RAISERROR('Choose the shift the day was worked on.', 16, 1); RETURN 1; END
    IF @Decision = 'Dismiss' AND @Note IS NULL
    BEGIN RAISERROR('Say why these punches were not work. The note is kept with the decision.', 16, 1); RETURN 1; END

    /* still a day waiting for somebody? (decided a moment ago by someone else, or its month is no longer approved) */
    DECLARE @Branch INT, @First DATETIME2, @Last DATETIME2, @Count INT, @Dismissed BIT;
    SELECT @Branch = BranchId, @First = FirstPunch, @Last = LastPunch, @Count = PunchCount, @Dismissed = IsDismissed
    FROM attendance.fn_UnrosteredDays(@WorkDate, @WorkDate) WHERE EmployeeId = @EmployeeId;
    IF @Count IS NULL
    BEGIN RAISERROR('This day is no longer waiting for a decision. Reload the list.', 16, 1); RETURN 1; END
    IF @Decision = 'Dismiss' AND @Dismissed = 1
    BEGIN RAISERROR('This day is no longer waiting for a decision: it is already dismissed. Reload the list.', 16, 1); RETURN 1; END

    /* whose days: every branch with EMP_VIEW_ALL, otherwise the branches the caller manages (the branch of the day) */
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    IF @SeesAll = 0 AND NOT EXISTS (SELECT 1 FROM hr.BRANCH b WHERE b.BranchId = @Branch AND b.ManagerEmployeeId = @CallerEmp)
    BEGIN RAISERROR('You can only decide days of the branches you manage.', 16, 1); RETURN 1; END

    /* who: the permission of the day's date (Role permissions, card Attendance) */
    IF attendance.fn_MayDecideUnrostered(@CallerUserId, @WorkDate) = 0
    BEGIN
        IF @WorkDate >= CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE)
            RAISERROR('You may not decide a day of today that is not on the roster. It needs its own permission (Role permissions, Attendance).', 16, 1);
        ELSE
            RAISERROR('You may not decide a past day that is not on the roster. It needs its own permission (Role permissions, Attendance).', 16, 1);
        RETURN 1;
    END

    /* a paid period is closed for the employee (script 82, D10: the same sentence everywhere) */
    IF payroll.fn_IsPeriodPaid(@EmployeeId, @WorkDate) = 1
    BEGIN
        SET @msg = N'This period is paid ' + NCHAR(8212) + N' raise a payroll adjustment instead.';
        RAISERROR(@msg, 16, 1); RETURN 1;
    END

    DECLARE @OwnTran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END, @rc INT;
    IF @OwnTran = 1 BEGIN TRAN;

    IF @Decision = 'Dismiss'
    BEGIN
        /* the new row first, the older ones retired after it: if the INSERT fails, nothing has changed */
        DECLARE @NewDecision INT;
        INSERT INTO attendance.UNROSTERED_DAY_DECISION
            (EmployeeId, WorkDate, Decision, Note, PunchCount, FirstPunch, LastPunch, DecidedByUserId)
        VALUES (@EmployeeId, @WorkDate, 'Dismissed', @Note, @Count, @First, @Last, @CallerUserId);
        SET @NewDecision = SCOPE_IDENTITY();
        IF @NewDecision IS NULL
        BEGIN
            IF @OwnTran = 1 AND @@TRANCOUNT > 0 ROLLBACK;
            RETURN 1;                                 -- the INSERT's own error has been raised
        END
        UPDATE attendance.UNROSTERED_DAY_DECISION SET IsCurrent = 0
        WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate AND IsCurrent = 1 AND DecisionId <> @NewDecision;
    END
    ELSE
    BEGIN
        DECLARE @IsRest BIT = CASE WHEN @Decision = 'RestDay' THEN 1 ELSE 0 END;
        IF @IsRest = 1 SET @ShiftId = NULL;          -- a rest day holds no shift (the writer stores what it is given)
        EXEC @rc = attendance.usp_ShiftAssignment_Upsert
             @EmployeeId = @EmployeeId, @WorkDate = @WorkDate, @ShiftId = @ShiftId, @IsRestDay = @IsRest,
             @CallerUserId = @CallerUserId, @Quiet = 1;
        IF @rc <> 0
        BEGIN
            IF @OwnTran = 1 AND @@TRANCOUNT > 0 ROLLBACK;
            RETURN 1;                                 -- the writer has already said why
        END
        /* the writer filed the decision (the same row whichever page the add came from); the note belongs on it */
        IF @Note IS NOT NULL
            UPDATE attendance.UNROSTERED_DAY_DECISION SET Note = @Note
            WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate AND IsCurrent = 1 AND Decision IN ('Shift', 'RestDay');
    END

    IF @OwnTran = 1 COMMIT;

    SELECT @EmployeeId AS EmployeeId, @WorkDate AS WorkDate,
           CASE WHEN @Decision = 'Dismiss' THEN 'Dismissed' ELSE @Decision END AS Decision,
           (SELECT sa.ShiftAssignmentId FROM attendance.SHIFT_ASSIGNMENT sa
            WHERE sa.EmployeeId = @EmployeeId AND sa.WorkDate = @WorkDate) AS ShiftAssignmentId,
           (SELECT a.AttendanceId FROM attendance.ATTENDANCE_RECORD a
            WHERE a.EmployeeId = @EmployeeId AND a.WorkDate = @WorkDate) AS AttendanceId;
    RETURN 0;
END;
GO

/* ==================================== 10. a dismissal taken back ==================================== */
/* The day is open again. Same people as the decision: the branch, the permission of the date, not a paid period.
   One result row: EmployeeId, WorkDate. */
CREATE OR ALTER PROCEDURE attendance.usp_UnrosteredDay_Reopen
    @EmployeeId INT, @WorkDate DATE,
    @CallerUserId INT = NULL          -- the signed-in user; NULL = the system
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @msg NVARCHAR(400);
    DECLARE @Id INT = (SELECT TOP 1 DecisionId FROM attendance.UNROSTERED_DAY_DECISION
                       WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate AND IsCurrent = 1 AND Decision = 'Dismissed'
                       ORDER BY DecisionId DESC);
    IF @Id IS NULL
    BEGIN RAISERROR('This day is no longer waiting for a decision: it has no dismissal to take back. Reload the list.', 16, 1); RETURN 1; END

    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    IF @SeesAll = 0 AND NOT EXISTS (SELECT 1 FROM hr.BRANCH b
                                    WHERE b.BranchId = hr.fn_EmployeeBranchOn(@EmployeeId, @WorkDate) AND b.ManagerEmployeeId = @CallerEmp)
    BEGIN RAISERROR('You can only decide days of the branches you manage.', 16, 1); RETURN 1; END

    IF attendance.fn_MayDecideUnrostered(@CallerUserId, @WorkDate) = 0
    BEGIN
        IF @WorkDate >= CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE)
            RAISERROR('You may not decide a day of today that is not on the roster. It needs its own permission (Role permissions, Attendance).', 16, 1);
        ELSE
            RAISERROR('You may not decide a past day that is not on the roster. It needs its own permission (Role permissions, Attendance).', 16, 1);
        RETURN 1;
    END

    IF payroll.fn_IsPeriodPaid(@EmployeeId, @WorkDate) = 1
    BEGIN
        SET @msg = N'This period is paid ' + NCHAR(8212) + N' raise a payroll adjustment instead.';
        RAISERROR(@msg, 16, 1); RETURN 1;
    END

    UPDATE attendance.UNROSTERED_DAY_DECISION
    SET IsCurrent = 0, ReopenedByUserId = @CallerUserId, ReopenedAtUtc = SYSUTCDATETIME()
    WHERE DecisionId = @Id;

    SELECT @EmployeeId AS EmployeeId, @WorkDate AS WorkDate;
    RETURN 0;
END;
GO

/* ==================================== 11. payroll readiness counts them ==================================== */
/* The function of script 103 with two columns appended (UndecidedUnrosteredDays, UnrosteredDaysBlock) and IsReady
   reading them. Every reader selects by name; attendance.usp_Attendance_PayrollReadiness keeps its 11 columns. */
CREATE OR ALTER FUNCTION attendance.fn_PayrollReadiness (@PeriodYearMonth CHAR(7), @AsOfDate DATE)
RETURNS TABLE
AS RETURN
WITH p AS (
    SELECT CAST(@PeriodYearMonth + '-01' AS DATE) AS PeriodStart,
           EOMONTH(CAST(@PeriodYearMonth + '-01' AS DATE)) AS PeriodEnd,
           DATEADD(DAY, -1, ISNULL(@AsOfDate, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE))) AS Yesterday
), q AS (
    SELECT PeriodStart, PeriodEnd, CASE WHEN Yesterday < PeriodEnd THEN Yesterday ELSE PeriodEnd END AS UpTo FROM p
), c AS (
    SELECT q.PeriodStart, q.PeriodEnd, q.UpTo,
        (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG
         WHERE IsProcessed = 0 AND EmployeeId IS NOT NULL AND CAST(PunchTimeUtc AS DATE) BETWEEN q.PeriodStart AND q.UpTo) AS UnprocessedPunches,
        /* the punches still WAITING for an owner: script 83's quarantine view, which (script 100, unit B) leaves out
           the punches HR set aside - so the "Set aside" button unblocks payroll */
        (SELECT COUNT(*) FROM attendance.DEVICE_PUNCH_QUARANTINE pq
         WHERE CAST(pq.PunchTime AS DATE) BETWEEN q.PeriodStart AND q.UpTo) AS UnresolvedPinPunches,
        (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD
         WHERE HasAnomaly = 1 AND WorkDate BETWEEN q.PeriodStart AND q.UpTo) AS OpenAnomalies,
        (SELECT COUNT(*) FROM attendance.ATTENDANCE_CORRECTION cr
         JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = cr.AttendanceId
         WHERE cr.ApprovalStatus = 'Pending' AND a.WorkDate BETWEEN q.PeriodStart AND q.UpTo) AS PendingCorrections,
        /* a rostered day of an APPROVED roster month (the branch of the day), inside the employment (QA3 REL-1) */
        (SELECT COUNT(*) FROM attendance.SHIFT_ASSIGNMENT sa
         JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId AND e.IsDeleted = 0
         WHERE sa.WorkDate BETWEEN q.PeriodStart AND q.UpTo
           AND sa.WorkDate >= e.HireDate AND (e.TerminationDate IS NULL OR sa.WorkDate <= e.TerminationDate)
           AND EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                       WHERE rm.BranchId = hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate)
                         AND rm.MonthDate = DATEFROMPARTS(YEAR(sa.WorkDate), MONTH(sa.WorkDate), 1)
                         AND rm.[Status] = 'Approved')
           AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a
                           WHERE a.EmployeeId = sa.EmployeeId AND a.WorkDate = sa.WorkDate)) AS RosteredDaysWithNoRecord,
        (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD
         WHERE WorkDate BETWEEN q.PeriodStart AND q.UpTo AND ExitVarianceMinutes > 0 AND ExitVarianceDisposition IS NULL) AS UndecidedExitVariances,
        (SELECT COUNT(*) FROM attendance.ATTENDANCE_ANOMALY
         WHERE WorkDate BETWEEN q.PeriodStart AND q.UpTo AND Decision IS NULL) AS UndecidedAnomalies,
        /* 108: completed days somebody punched on that the approved roster does not know and nobody has decided
           (no roster row, no record, no dismissal that still stands), outside a period already paid for the employee */
        (SELECT COUNT(*) FROM attendance.fn_UnrosteredDays(q.PeriodStart, q.UpTo) u
         WHERE u.IsDismissed = 0 AND payroll.fn_IsPeriodPaid(u.EmployeeId, u.WorkDate) = 0) AS UndecidedUnrosteredDays,
        /* 108: do they block THIS period? From the month of setting OffRosterBlocksPayrollFrom on; empty, missing or
           unreadable = never (they are still counted) */
        CAST(CASE WHEN q.PeriodStart >= TRY_CAST(NULLIF(LTRIM(RTRIM((SELECT TOP 1 SettingValue FROM core.SETTING
                                                                    WHERE SettingKey = 'OffRosterBlocksPayrollFrom'))), N'') + N'-01' AS DATE)
                  THEN 1 ELSE 0 END AS BIT) AS UnrosteredDaysBlock
    FROM q
)
SELECT @PeriodYearMonth AS PeriodYearMonth, c.PeriodStart, c.PeriodEnd,
       c.UnprocessedPunches, c.UnresolvedPinPunches, c.OpenAnomalies, c.PendingCorrections,
       c.RosteredDaysWithNoRecord, c.UndecidedExitVariances, c.UndecidedAnomalies,
       CAST(CASE WHEN c.UnprocessedPunches = 0 AND c.UnresolvedPinPunches = 0 AND c.OpenAnomalies = 0 AND c.PendingCorrections = 0
                  AND c.RosteredDaysWithNoRecord = 0 AND c.UndecidedExitVariances = 0 AND c.UndecidedAnomalies = 0
                  AND (c.UndecidedUnrosteredDays = 0 OR c.UnrosteredDaysBlock = 0)        -- 108
                 THEN 1 ELSE 0 END AS BIT) AS IsReady,
       c.UpTo AS CountedUpTo,
       c.UndecidedUnrosteredDays, c.UnrosteredDaysBlock                                    -- 108 (appended: every reader selects by name)
FROM c;
GO

/* The gate of Create, Generate and Approve (script 103): the two sentences it had, and between them the reason this
   script adds. The anomaly sentence stays first. */
CREATE OR ALTER PROCEDURE payroll.usp_PayrollRun_AssertReady
    @PeriodYearMonth CHAR(7), @AsOfDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Undecided INT, @IsReady BIT, @UpTo DATE, @Unrostered INT, @UnrosteredBlock BIT;
    SELECT @Undecided = UndecidedAnomalies, @IsReady = IsReady, @UpTo = CountedUpTo,
           @Unrostered = UndecidedUnrosteredDays, @UnrosteredBlock = UnrosteredDaysBlock
    FROM attendance.fn_PayrollReadiness(@PeriodYearMonth, @AsOfDate);
    DECLARE @P CHAR(7) = @PeriodYearMonth, @UpToText VARCHAR(10) = CONVERT(VARCHAR(10), @UpTo, 23);
    IF @Undecided > 0
    BEGIN
        DECLARE @Plural VARCHAR(3) = CASE WHEN @Undecided = 1 THEN 'y' ELSE 'ies' END;
        RAISERROR('Attendance for %s has %d undecided anomal%s up to %s (late arrival, early departure or missing punch). Decide them in Attendance > Anomalies before running payroll.', 16, 1, @P, @Undecided, @Plural, @UpToText);
        RETURN 1;
    END
    /* 108: days somebody worked that the approved roster does not know, once setting OffRosterBlocksPayrollFrom covers the period */
    IF @Unrostered > 0 AND @UnrosteredBlock = 1
    BEGIN
        DECLARE @Days VARCHAR(4) = CASE WHEN @Unrostered = 1 THEN 'day' ELSE 'days' END;
        RAISERROR('Attendance for %s has %d %s with punches that the approved roster does not know and nobody has decided, up to %s. Decide them in Attendance > Daily attendance before running payroll.', 16, 1, @P, @Unrostered, @Days, @UpToText);
        RETURN 1;
    END
    IF @IsReady = 0
    BEGIN
        RAISERROR('Attendance for %s is not ready for payroll up to %s. Open the readiness check and clear the counts.', 16, 1, @P, @UpToText);
        RETURN 1;
    END
    RETURN 0;
END;
GO

/* The readiness answer for the API: every column of the function, and the month the block starts in (NULL = never).
   Not for INSERT ... EXEC - columns may be added; SQL callers that capture a result keep using
   attendance.usp_Attendance_PayrollReadiness and its 11 columns. */
CREATE OR ALTER PROCEDURE attendance.usp_PayrollReadiness_Get
    @PeriodYearMonth CHAR(7),
    @AsOfDate DATE = NULL      -- the clock. NULL = today in Beirut; a caller passes a date only to test the rule
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.PeriodYearMonth, r.PeriodStart, r.PeriodEnd, r.UnprocessedPunches, r.UnresolvedPinPunches, r.OpenAnomalies,
           r.PendingCorrections, r.RosteredDaysWithNoRecord, r.UndecidedExitVariances, r.UndecidedAnomalies, r.IsReady,
           r.CountedUpTo, r.UndecidedUnrosteredDays, r.UnrosteredDaysBlock,
           CONVERT(CHAR(7), TRY_CAST(NULLIF(LTRIM(RTRIM((SELECT TOP 1 SettingValue FROM core.SETTING
                                                         WHERE SettingKey = 'OffRosterBlocksPayrollFrom'))), N'') + N'-01' AS DATE), 23) AS UnrosteredBlocksFrom
    FROM attendance.fn_PayrollReadiness(@PeriodYearMonth, @AsOfDate) r;
END;
GO

/* ==================================== 12. OWNER CHECK: who decides, what is waiting ==================================== */
DECLARE @today NVARCHAR(400) = (SELECT STRING_AGG(r.Name, N', ') WITHIN GROUP (ORDER BY r.Name)
                                FROM security.[ROLE] r
                                WHERE EXISTS (SELECT 1 FROM security.ROLE_PERMISSION rp JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
                                              WHERE rp.RoleId = r.RoleId AND p.Code = 'OFFROSTER_TODAY'));
DECLARE @past NVARCHAR(400) = (SELECT STRING_AGG(r.Name, N', ') WITHIN GROUP (ORDER BY r.Name)
                               FROM security.[ROLE] r
                               WHERE EXISTS (SELECT 1 FROM security.ROLE_PERMISSION rp JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
                                             WHERE rp.RoleId = r.RoleId AND p.Code = 'OFFROSTER_PAST'));
PRINT CONCAT('OWNER CHECK (108): a day that is not on the roster is decided by - today: ', ISNULL(@today, N'(no role)'),
             ' | past days: ', ISNULL(@past, N'(no role)'), '. Change it on Security > Role permissions (card Attendance).');

DECLARE @to   DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
DECLARE @from DATE = DATEADD(MONTH, -2, DATEFROMPARTS(YEAR(@to), MONTH(@to), 1));
DECLARE @open INT = (SELECT COUNT(*) FROM attendance.fn_UnrosteredDays(@from, @to) u
                     WHERE u.IsDismissed = 0 AND payroll.fn_IsPeriodPaid(u.EmployeeId, u.WorkDate) = 0);
DECLARE @blocks NVARCHAR(20) = ISNULL(NULLIF(LTRIM(RTRIM((SELECT TOP 1 SettingValue FROM core.SETTING WHERE SettingKey = 'OffRosterBlocksPayrollFrom'))), N''), N'never');
PRINT CONCAT('OWNER CHECK (108): days with punches that are not on the roster and are waiting for a decision since ',
             CONVERT(VARCHAR(10), @from, 23), ' (unpaid periods): ', @open,
             '. They are listed on Attendance > Daily attendance; they block payroll from ', @blocks, ' (setting OffRosterBlocksPayrollFrom).');
PRINT '108_unrostered_days.sql: days that are not on the roster are listed, decided and counted - in place.';
GO

SET NOEXEC OFF;
GO
