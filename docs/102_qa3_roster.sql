/* ============================================================================
   102_qa3_roster.sql - QA3 (deep test, 2026-10-19), unit C: ROSTERS.

   PREREQUISITES (checked below): 87 (hr.fn_CallerScope), 96 (the auto-roster), 99 (workflow.LEAVE_REQUEST.
   ApprovedToDate and hr.usp_LeaveLedger_Reprice), 100 (usp_Attendance_ComputeDay: a day outside the employment is
   'None' and loses its non-manual unpaid record). Apply after 101 too (its reversal calls usp_Roster_RederiveMonth
   once this script has created it). Idempotent. Run with sqlcmd -I.

   ROS-1 / REL-1  NOBODY IS ROSTERED OUTSIDE THEIR EMPLOYMENT.
       hr.usp_Employee_Update: the unpaid days outside the employment (after a termination date on file, before the
       hire date) that have a roster row or a non-manual record are derived again FIRST with
       attendance.usp_Attendance_ComputeDay (script 100: the day is 'None', its non-manual record goes with its
       exit-permission posting); then their roster rows go (a record still pointing at one - a manual day, a day
       with a correction on file - lets go of it first; the SHIFT_ASSIGNMENT trigger marks the months as changed).
       All of it inside the employee update's transaction. Then the leave is priced again (unit D's
       hr.usp_LeaveLedger_Reprice) from the earlier of the old and the new hire / termination date - a day outside
       the employment costs nothing - as for a transfer from its date (ROS-8).
       The generators - _GenerateRange, _CopyPeriod, _ApplyPattern - skip days outside the employment, retired shifts
       (SHIFT.IsActive = 0) and the public holidays of the employee's branch of the day, and never put a rest day on
       an approved leave day (auto-roster rule D5: the day gets a working row instead, and an existing row inside a
       leave is not overwritten). _Upsert refuses a day outside the employment and a retired shift.
   ROS-2 / ATT-1  APPROVAL RE-DERIVES THE MONTH. NEW attendance.usp_Roster_RederiveMonth @BranchId, @Year, @Month
       (the contract): ComputeDay for every employee-day of the branch-month (branch of the day) from the 1st to
       min(Beirut yesterday, month end) that has a roster row or a record, then hr.usp_LeaveLedger_Reprice for those
       employees and the month (ROS-12). No result set. It stamps ROSTER_MONTH.RederivedAt / RederivedStatus (new),
       the marker of the nightly safety net attendance.usp_Roster_RederivePending (a month approved - or approved
       again - since its last re-derivation, or no longer approved after one). The API calls
       attendance.usp_Roster_RederiveForRequest right after a ROSTER_APPROVAL request ends Approved.
       REL-16: the page may re-derive a month on demand (@CallerUserId: scoped like every roster writer).
   ROS-3  Copy previous month / Apply patterns work on ONE branch: @BranchId (required) - only the days the employee
       belongs to that branch, in the source month and in the target month.
   ROS-14 SCOPE. Every writer takes @CallerUserId (last, NULL = the system) and usp_Roster_AssertEditable refuses a
       change on a day whose branch the caller does not manage, unless they hold EMP_VIEW_ALL (the auto-roster's rule
       D12, same sentence). usp_Roster_Clear (its @UserId), usp_RosterMonth_Get and usp_RosterApproval_Create
       check the branch the same way.
   WF-7   usp_RosterApproval_Create: the request stays filed against the submitter (RaisedBy = the caller), but its
       BranchManager steps are resolved against the ROSTER'S branch - its manager signs, whoever put it up.
   ROS-4 / LEV-5  NEW attendance.usp_Roster_GetLeaveDays: per employee-day leave from the APPROVED requests
       (FromDate..ISNULL(ApprovedToDate, ToDate), a half day 0.5), branch of the day, caller-scoped. Exit-permission
       conversions are not leave days.
   ROS-8 / REL-9  A dated transfer stamps LastChangedUtc on the months of both branches where rows moved, and
       ModifiedUtc on the moved rows, so both read "changed since approval" (usp_EmployeeBranchHistory_CancelFuture
       likewise); the leave from the transfer on is re-priced. usp_ShiftAssignment_GetGaps takes @BranchId.
   ATT-14 / ROS-5  The transfer's re-derivation stops at Beirut today (records only for today, nothing in the future).
   ROS-10 usp_ShiftAssignment_GetGaps leaves out the public holidays of the branch of the day.
   ROS-6  HR (EMP_VIEW_ALL) may ADD a missing roster row on a past day of an approved month when the day has no
       attendance record and is unpaid (usp_ShiftAssignment_Upsert, which then derives the day). Every refusal of
       the guard names its own reason (recorded / past / a generator / not HR).
   ROS-7  usp_RosterMonth_Get and usp_RosterApproval_Create read the approval from the latest APPROVED request, so a
       rejected re-submission keeps the month "changed since approval" and Submit live.
   ROS-13 usp_ShiftAssignment_GenerateRange_Bulk runs each employee's generation quiet (@Quiet, @RowsInserted OUTPUT -
       an INSERT...EXEC capture would forbid capturing the bulk itself) and returns EmployeesProcessed and RowsInserted.
   Also: the one-open-request check of usp_RosterApproval_Create runs inside the transaction under an application
       lock; usp_ShiftAssignment_CopyPeriod's most-frequent-shift tie-break is deterministic (working first, then the
       earliest start, then the lowest id).

   DATA REPAIRS (guarded, idempotent, never a paid day):
     R1 the unpaid days outside the employment (after the termination date, before the hire date) are derived again
        (script 100 removes their non-manual records), then their roster rows are removed (ROS-1);
     R2 attendance records dated after Beirut today that hold no punch and are not manual (left by the holiday
        recompute and by transfers, ATT-14 / ROS-5) are removed;
     R3 nothing to run for approved months: their RederivedAt is NULL, so the first nightly run re-derives them;
     R4 approved leave reaching before the hire date or past a termination date on file is priced again (unit D's
        hr.usp_LeaveLedger_Reprice: those days cost nothing; paid months are left as they are) - what saving the
        employee form now does.

   Every refusal is RAISERROR(msg,16,1) + RETURN 1 (ROLLBACK first inside a transaction). Pure ASCII: an em dash in
   a message is NCHAR(8212).
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF COL_LENGTH('workflow.LEAVE_REQUEST', 'ApprovedToDate') IS NULL
    RAISERROR('102_qa3_roster.sql needs script 99 (workflow.LEAVE_REQUEST.ApprovedToDate). Apply 99 first.', 16, 1);
GO
IF OBJECT_ID('hr.usp_LeaveLedger_Reprice') IS NULL
    RAISERROR('102_qa3_roster.sql needs script 99 (hr.usp_LeaveLedger_Reprice). Apply 99 first.', 16, 1);
GO
IF OBJECT_ID('hr.fn_CallerScope') IS NULL OR OBJECT_ID('attendance.usp_AutoRoster_Commit') IS NULL
    RAISERROR('102_qa3_roster.sql needs scripts 87 (hr.fn_CallerScope) and 96 (the auto-roster). Apply them first.', 16, 1);
GO
/* script 100's ComputeDay knows the employment window (no version before it reads TerminationDate) */
IF ISNULL(OBJECT_DEFINITION(OBJECT_ID('attendance.usp_Attendance_ComputeDay')), N'') NOT LIKE N'%TerminationDate%'
    RAISERROR('102_qa3_roster.sql needs script 100 (usp_Attendance_ComputeDay: a day outside the employment). Apply 100 first.', 16, 1);
GO

/* ---------------------------------------------------------------- 0. the safety net's marker */
IF COL_LENGTH('attendance.ROSTER_MONTH', 'RederivedAt') IS NULL
    ALTER TABLE attendance.ROSTER_MONTH ADD RederivedAt DATETIME2 NULL;
IF COL_LENGTH('attendance.ROSTER_MONTH', 'RederivedStatus') IS NULL
    ALTER TABLE attendance.ROSTER_MONTH ADD RederivedStatus VARCHAR(30) NULL;
GO

/* ---------------------------------------------------------------- 1. the guard of every roster writer */
/* Reads #roster_change (EmployeeId, WorkDate): the rows that would actually change. Unchanged from 85 except:
   - @CallerUserId (ROS-14): EMP_VIEW_ALL, or the manager of the branch the employee belongs to ON that day
     (the auto-roster's rule D12, same sentence). NULL = the system itself.
   - (b) names its reason (ROS-6): a recorded day, a past day whose row would change, a missing past day a
     generator would fill, a missing past day somebody other than HR would add. With @AllowPastInsert = 1 (the
     single-day writer) HR may add a missing past day that has no record; the writer derives it. */
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
    /* what is left are MISSING past days with no record (the "worked without roster" days): HR adds them one by one */
    IF EXISTS (SELECT 1 FROM @locked) AND @AllowPastInsert = 0
    BEGIN
        SET @msg = N'This day is already in an approved roster and is in the past ' + NCHAR(8212) + N' a generator does not fill it; HR can add the missing day on its own.';
        RAISERROR(@msg, 16, 1); RETURN 1;
    END
    IF EXISTS (SELECT 1 FROM @locked) AND @SeesAll = 0
    BEGIN
        SET @msg = N'This day is already in an approved roster and is in the past ' + NCHAR(8212) + N' only HR can add the missing day.';
        RAISERROR(@msg, 16, 1); RETURN 1;
    END

    RETURN 0;
END;
GO

/* ---------------------------------------------------------------- 2. one cell */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_Upsert
    @EmployeeId INT, @WorkDate DATE, @ShiftId INT = NULL, @IsRestDay BIT = 0,
    @CallerUserId INT = NULL          -- 102 (ROS-14): the signed-in user; NULL = the system
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

    /* 102 (ROS-6): a missing day HR added to the past of an APPROVED month is derived now - the punches of a
       "worked without roster" day become an attendance record (the guard let it through: no record, not paid) */
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    IF @Inserted = 1 AND @WorkDate < @Today
       AND EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                   WHERE rm.BranchId = hr.fn_EmployeeBranchOn(@EmployeeId, @WorkDate)
                     AND rm.MonthDate = DATEFROMPARTS(YEAR(@WorkDate), MONTH(@WorkDate), 1)
                     AND rm.[Status] = 'Approved')
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @EmployeeId, @WorkDate = @WorkDate;

    SELECT ShiftAssignmentId FROM attendance.SHIFT_ASSIGNMENT
    WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate;
    RETURN 0;
END;
GO

/* ---------------------------------------------------------------- 3. one row out */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_Delete
    @ShiftAssignmentId INT,
    @CallerUserId INT = NULL          -- 102 (ROS-14)
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#roster_change') IS NOT NULL DROP TABLE #roster_change;
    CREATE TABLE #roster_change (EmployeeId INT NOT NULL, WorkDate DATE NOT NULL);
    INSERT INTO #roster_change (EmployeeId, WorkDate)
    SELECT EmployeeId, WorkDate FROM attendance.SHIFT_ASSIGNMENT WHERE ShiftAssignmentId = @ShiftAssignmentId;
    DECLARE @rc INT;
    EXEC @rc = attendance.usp_Roster_AssertEditable @CallerUserId = @CallerUserId;
    DROP TABLE #roster_change;
    IF @rc <> 0 RETURN 1;

    UPDATE rm SET LastChangedUtc = SYSUTCDATETIME()
    FROM attendance.ROSTER_MONTH rm
    JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.ShiftAssignmentId = @ShiftAssignmentId
    WHERE rm.BranchId = hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate)
      AND rm.MonthDate = DATEFROMPARTS(YEAR(sa.WorkDate), MONTH(sa.WorkDate), 1);

    /* 102: an attendance day still pointing at the row (its month was approved once and is open again) lets go of
       it first - the delete would otherwise die on the foreign key. The next derivation of the day re-reads it. */
    UPDATE attendance.ATTENDANCE_RECORD SET ShiftAssignmentId = NULL WHERE ShiftAssignmentId = @ShiftAssignmentId;

    DELETE FROM attendance.SHIFT_ASSIGNMENT WHERE ShiftAssignmentId = @ShiftAssignmentId;
    RETURN 0;
END;
GO

/* ---------------------------------------------------------------- 4. the generators */
/* What every generator plans now (ROS-1, ROS-9, D5):
   - only days inside the employment (HireDate .. TerminationDate) of an employee not removed;
   - no row on a public holiday of the employee's branch of the day (D1/D4: a holiday off is NO row);
   - never a retired shift (SHIFT.IsActive = 0): such a day is left empty, and shows as a gap;
   - never a REST day on a day of approved leave (FromDate .. ISNULL(ApprovedToDate, ToDate), a half day included):
     the day gets a working row instead (D5: so the leave costs what it was priced at), and with Overwrite on an
     existing row inside a leave is left as it is.
   The rows that would land go through the guard (with the caller) before anything is written; RETURN 1 on a
   refusal so _Bulk can roll back. */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_GenerateRange
    @EmployeeId INT,
    @FromDate   DATE,
    @ToDate     DATE,
    @ShiftId    INT,
    @Weekdays   CHAR(7) = '1111100',
    @Overwrite  BIT = 0,
    @CallerUserId INT = NULL,         -- 102 (ROS-14)
    @BranchId     INT = NULL,         -- 102: only the days the employee belongs to this branch (NULL = every day)
    @Quiet        BIT = 0,            -- 102 (ROS-13): 1 = no result set (the bulk reads @RowsInserted instead)
    @RowsInserted INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @msg NVARCHAR(400);
    SET @RowsInserted = 0;

    IF @FromDate > @ToDate
    BEGIN RAISERROR('FromDate must be on or before ToDate.', 16, 1); RETURN 1; END
    IF DATEDIFF(DAY, @FromDate, @ToDate) > 366
    BEGIN RAISERROR('Generate at most a year at a time.', 16, 1); RETURN 1; END
    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId)
    BEGIN RAISERROR('Employee not found.', 16, 1); RETURN 1; END
    DECLARE @ShiftActive BIT = (SELECT IsActive FROM attendance.SHIFT WHERE ShiftId = @ShiftId);
    IF @ShiftActive IS NULL
    BEGIN RAISERROR('Shift not found.', 16, 1); RETURN 1; END
    IF @ShiftActive = 0
    BEGIN
        SET @msg = N'That shift is retired ' + NCHAR(8212) + N' choose an active shift.';
        RAISERROR(@msg, 16, 1); RETURN 1;
    END

    IF OBJECT_ID('tempdb..#roster_plan') IS NOT NULL DROP TABLE #roster_plan;

    ;WITH cal_dates AS (
        SELECT @FromDate AS d
        UNION ALL
        SELECT DATEADD(DAY, 1, d) FROM cal_dates WHERE d < @ToDate
    )
    SELECT @EmployeeId AS EmployeeId,
           c.d         AS WorkDate,
           CASE WHEN m.IsWork = 1 OR lv.OnLeave = 1 THEN @ShiftId ELSE NULL END AS ShiftId,
           CAST(CASE WHEN m.IsWork = 1 OR lv.OnLeave = 1 THEN 0 ELSE 1 END AS BIT) AS IsRestDay,
           lv.OnLeave
    INTO #roster_plan
    FROM cal_dates c
    JOIN hr.EMPLOYEE e ON e.EmployeeId = @EmployeeId AND e.IsDeleted = 0
    CROSS APPLY (SELECT CASE WHEN SUBSTRING(@Weekdays, ((DATEPART(WEEKDAY, c.d) + @@DATEFIRST - 2) % 7) + 1, 1) = '1'
                             THEN 1 ELSE 0 END AS IsWork) m
    CROSS APPLY (SELECT hr.fn_EmployeeBranchOn(@EmployeeId, c.d) AS BranchId) b
    CROSS APPLY (SELECT CAST(CASE WHEN EXISTS (
                     SELECT 1 FROM workflow.LEAVE_REQUEST lr
                     JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId AND ri.[Status] = 'Approved'
                     WHERE lr.EmployeeId = @EmployeeId
                       AND c.d BETWEEN lr.FromDate AND ISNULL(lr.ApprovedToDate, lr.ToDate)) THEN 1 ELSE 0 END AS BIT) AS OnLeave) lv
    WHERE c.d >= e.HireDate
      AND (e.TerminationDate IS NULL OR c.d <= e.TerminationDate)
      AND core.fn_IsHoliday(c.d, b.BranchId) = 0
      AND (@BranchId IS NULL OR b.BranchId = @BranchId)
    OPTION (MAXRECURSION 400);

    IF OBJECT_ID('tempdb..#roster_change') IS NOT NULL DROP TABLE #roster_change;
    CREATE TABLE #roster_change (EmployeeId INT NOT NULL, WorkDate DATE NOT NULL);
    INSERT INTO #roster_change (EmployeeId, WorkDate)
    SELECT p.EmployeeId, p.WorkDate
    FROM #roster_plan p
    LEFT JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.EmployeeId = p.EmployeeId AND sa.WorkDate = p.WorkDate
    WHERE sa.ShiftAssignmentId IS NULL
       OR (@Overwrite = 1 AND p.OnLeave = 0
           AND (ISNULL(sa.ShiftId, -1) <> ISNULL(p.ShiftId, -1) OR sa.IsRestDay <> p.IsRestDay));
    DECLARE @rc INT;
    EXEC @rc = attendance.usp_Roster_AssertEditable @CallerUserId = @CallerUserId;
    DROP TABLE #roster_change;
    IF @rc <> 0 BEGIN DROP TABLE #roster_plan; RETURN 1; END

    IF @Overwrite = 1
        UPDATE sa
        SET sa.ShiftId = p.ShiftId, sa.IsRestDay = p.IsRestDay
        FROM attendance.SHIFT_ASSIGNMENT sa
        JOIN #roster_plan p ON p.EmployeeId = sa.EmployeeId AND p.WorkDate = sa.WorkDate
        WHERE p.OnLeave = 0
          AND (ISNULL(sa.ShiftId, -1) <> ISNULL(p.ShiftId, -1) OR sa.IsRestDay <> p.IsRestDay);

    INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
    SELECT p.EmployeeId, p.ShiftId, p.WorkDate, p.IsRestDay
    FROM #roster_plan p
    WHERE NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                      WHERE sa.EmployeeId = p.EmployeeId AND sa.WorkDate = p.WorkDate);

    SET @RowsInserted = @@ROWCOUNT;
    DROP TABLE #roster_plan;
    IF @Quiet = 0 SELECT @RowsInserted AS RowsInserted;
    RETURN 0;
END;
GO

/* ---- Bulk: all-or-nothing. 102 (ROS-13): each employee's generation runs quiet and hands back its count, so the one
        result set is the bulk's own - the API used to read the first employee's RowsInserted as EmployeesProcessed and
        report 0 - and RowsInserted is the sum. (An INSERT...EXEC capture here would forbid any caller from capturing
        the bulk itself: INSERT...EXEC cannot be nested.) ---- */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_GenerateRange_Bulk
    @EmployeeIds NVARCHAR(MAX),
    @FromDate    DATE,
    @ToDate      DATE,
    @ShiftId     INT,
    @Weekdays    CHAR(7) = '1111100',
    @Overwrite   BIT = 0,
    @CallerUserId INT = NULL,         -- 102 (ROS-14)
    @BranchId     INT = NULL          -- 102: only the days each employee belongs to this branch
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Emp INT, @Count INT = 0, @Rows INT = 0, @rc INT, @r INT;

    DECLARE emp_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT CAST(LTRIM(RTRIM(value)) AS INT)
        FROM STRING_SPLIT(@EmployeeIds, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

    BEGIN TRAN;
    OPEN emp_cur;
    FETCH NEXT FROM emp_cur INTO @Emp;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @rc = NULL, @r = NULL;
        EXEC @rc = attendance.usp_ShiftAssignment_GenerateRange
             @EmployeeId = @Emp, @FromDate = @FromDate, @ToDate = @ToDate,
             @ShiftId = @ShiftId, @Weekdays = @Weekdays, @Overwrite = @Overwrite,
             @CallerUserId = @CallerUserId, @BranchId = @BranchId,
             @Quiet = 1, @RowsInserted = @r OUTPUT;
        IF ISNULL(@rc, 1) <> 0
        BEGIN
            CLOSE emp_cur; DEALLOCATE emp_cur;
            IF @@TRANCOUNT > 0 ROLLBACK TRAN;
            RETURN 1;          -- the refusal was already raised by the nested proc
        END
        SET @Rows = @Rows + ISNULL(@r, 0);
        SET @Count = @Count + 1;
        FETCH NEXT FROM emp_cur INTO @Emp;
    END
    CLOSE emp_cur;
    DEALLOCATE emp_cur;
    COMMIT TRAN;

    SELECT @Count AS EmployeesProcessed, @Rows AS RowsInserted;
    RETURN 0;
END;
GO

/* ---- Copy period. 102 (ROS-3): ONE branch - the source month's rows of the days the employee belonged to it, onto
        the target month's days they belong to it. The most frequent row per weekday wins as before; a tie is decided
        the same way every time (102): a working shift before a rest day, then the earliest start, then the lowest id. ---- */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_CopyPeriod
    @SourceYearMonth CHAR(7),         -- e.g. '2026-06'
    @TargetYearMonth CHAR(7),         -- e.g. '2026-07'
    @EmployeeId      INT = NULL,      -- NULL = everyone of the branch
    @Overwrite       BIT = 0,
    @BranchId        INT = NULL,      -- 102 (ROS-3): required
    @CallerUserId    INT = NULL       -- 102 (ROS-14)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @msg NVARCHAR(400);

    IF @BranchId IS NULL
    BEGIN
        SET @msg = N'Choose a branch ' + NCHAR(8212) + N' copying a month works on one branch at a time.';
        RAISERROR(@msg, 16, 1); RETURN 1;
    END
    IF NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId)
    BEGIN RAISERROR('Branch not found.', 16, 1); RETURN 1; END

    DECLARE @srcFrom DATE = TRY_CAST(@SourceYearMonth + '-01' AS DATE);
    DECLARE @tgtFrom DATE = TRY_CAST(@TargetYearMonth + '-01' AS DATE);
    IF @srcFrom IS NULL OR @tgtFrom IS NULL
    BEGIN RAISERROR('Periods must look like ''2026-06''.', 16, 1); RETURN 1; END
    DECLARE @srcTo   DATE = EOMONTH(@srcFrom);
    DECLARE @tgtTo   DATE = EOMONTH(@tgtFrom);

    IF OBJECT_ID('tempdb..#roster_plan') IS NOT NULL DROP TABLE #roster_plan;

    ;WITH cal_dates AS (
        SELECT @tgtFrom AS d
        UNION ALL
        SELECT DATEADD(DAY, 1, d) FROM cal_dates WHERE d < @tgtTo
    ),
    tgt_days AS (
        SELECT d AS WorkDate, ((DATEPART(WEEKDAY, d) + @@DATEFIRST - 2) % 7) + 1 AS Dow
        FROM cal_dates
    ),
    src AS (
        SELECT sa.EmployeeId, sa.WorkDate, sa.ShiftId, sa.IsRestDay
        FROM attendance.SHIFT_ASSIGNMENT sa
        WHERE sa.WorkDate BETWEEN @srcFrom AND @srcTo
          AND (@EmployeeId IS NULL OR sa.EmployeeId = @EmployeeId)
          AND (sa.IsRestDay = 1 OR sa.ShiftId IS NOT NULL)                  -- a row with neither says nothing
          AND hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate) = @BranchId
    ),
    src_rows AS (
        SELECT s.EmployeeId,
               ((DATEPART(WEEKDAY, s.WorkDate) + @@DATEFIRST - 2) % 7) + 1 AS Dow,
               s.ShiftId, s.IsRestDay,
               COUNT(*) AS Freq
        FROM src s
        GROUP BY s.EmployeeId,
                 ((DATEPART(WEEKDAY, s.WorkDate) + @@DATEFIRST - 2) % 7) + 1,
                 s.ShiftId, s.IsRestDay
    ),
    src_pattern AS (
        SELECT r.EmployeeId, r.Dow, r.ShiftId, r.IsRestDay,
               ROW_NUMBER() OVER (PARTITION BY r.EmployeeId, r.Dow
                                  ORDER BY r.Freq DESC, r.IsRestDay ASC, sh.StartTime ASC, r.ShiftId ASC) AS rn
        FROM src_rows r
        LEFT JOIN attendance.SHIFT sh ON sh.ShiftId = r.ShiftId
    ),
    /* D5: the working shift a leave day gets when the copied weekday is a rest day - the employee's most frequent
       ACTIVE working shift of the source month */
    usual AS (
        SELECT x.EmployeeId, x.ShiftId
        FROM (SELECT s.EmployeeId, s.ShiftId,
                     ROW_NUMBER() OVER (PARTITION BY s.EmployeeId ORDER BY COUNT(*) DESC, MIN(sh.StartTime) ASC, s.ShiftId ASC) AS rn
              FROM src s
              JOIN attendance.SHIFT sh ON sh.ShiftId = s.ShiftId AND sh.IsActive = 1
              WHERE s.IsRestDay = 0
              GROUP BY s.EmployeeId, s.ShiftId) x
        WHERE x.rn = 1
    )
    SELECT sp.EmployeeId, td.WorkDate,
           CASE WHEN sp.IsRestDay = 1 AND lv.OnLeave = 1 THEN u.ShiftId ELSE sp.ShiftId END AS ShiftId,
           CAST(CASE WHEN sp.IsRestDay = 1 AND lv.OnLeave = 1 THEN 0 ELSE sp.IsRestDay END AS BIT) AS IsRestDay,
           lv.OnLeave
    INTO #roster_plan
    FROM src_pattern sp
    JOIN tgt_days td ON td.Dow = sp.Dow
    JOIN hr.EMPLOYEE e ON e.EmployeeId = sp.EmployeeId AND e.IsDeleted = 0
    LEFT JOIN attendance.SHIFT sh ON sh.ShiftId = sp.ShiftId
    LEFT JOIN usual u ON u.EmployeeId = sp.EmployeeId
    CROSS APPLY (SELECT hr.fn_EmployeeBranchOn(sp.EmployeeId, td.WorkDate) AS BranchId) b
    CROSS APPLY (SELECT CAST(CASE WHEN EXISTS (
                     SELECT 1 FROM workflow.LEAVE_REQUEST lr
                     JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId AND ri.[Status] = 'Approved'
                     WHERE lr.EmployeeId = sp.EmployeeId
                       AND td.WorkDate BETWEEN lr.FromDate AND ISNULL(lr.ApprovedToDate, lr.ToDate)) THEN 1 ELSE 0 END AS BIT) AS OnLeave) lv
    WHERE sp.rn = 1
      AND td.WorkDate >= e.HireDate AND (e.TerminationDate IS NULL OR td.WorkDate <= e.TerminationDate)    -- 102 (ROS-1)
      AND b.BranchId = @BranchId                                                                          -- 102 (ROS-3)
      /* script 85 (D1): A COPY KEEPS THE HOLIDAYS of the target month - no row on a public holiday of the branch */
      AND core.fn_IsHoliday(td.WorkDate, b.BranchId) = 0
      AND (sp.IsRestDay = 1 OR sh.IsActive = 1)                                   -- 102 (ROS-9): never a retired shift
      AND NOT (sp.IsRestDay = 1 AND lv.OnLeave = 1 AND u.ShiftId IS NULL)        -- D5 with no working shift to give
    OPTION (MAXRECURSION 400);

    IF OBJECT_ID('tempdb..#roster_change') IS NOT NULL DROP TABLE #roster_change;
    CREATE TABLE #roster_change (EmployeeId INT NOT NULL, WorkDate DATE NOT NULL);
    INSERT INTO #roster_change (EmployeeId, WorkDate)
    SELECT p.EmployeeId, p.WorkDate
    FROM #roster_plan p
    LEFT JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.EmployeeId = p.EmployeeId AND sa.WorkDate = p.WorkDate
    WHERE sa.ShiftAssignmentId IS NULL
       OR (@Overwrite = 1 AND p.OnLeave = 0
           AND (ISNULL(sa.ShiftId, -1) <> ISNULL(p.ShiftId, -1) OR sa.IsRestDay <> p.IsRestDay));
    DECLARE @rc INT;
    EXEC @rc = attendance.usp_Roster_AssertEditable @CallerUserId = @CallerUserId;
    DROP TABLE #roster_change;
    IF @rc <> 0 BEGIN DROP TABLE #roster_plan; RETURN 1; END

    IF @Overwrite = 1
        UPDATE sa
        SET sa.ShiftId = p.ShiftId, sa.IsRestDay = p.IsRestDay
        FROM attendance.SHIFT_ASSIGNMENT sa
        JOIN #roster_plan p ON p.EmployeeId = sa.EmployeeId AND p.WorkDate = sa.WorkDate
        WHERE p.OnLeave = 0
          AND (ISNULL(sa.ShiftId, -1) <> ISNULL(p.ShiftId, -1) OR sa.IsRestDay <> p.IsRestDay);

    INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
    SELECT p.EmployeeId, p.ShiftId, p.WorkDate, p.IsRestDay
    FROM #roster_plan p
    WHERE NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                      WHERE sa.EmployeeId = p.EmployeeId AND sa.WorkDate = p.WorkDate);

    DECLARE @Inserted INT = @@ROWCOUNT;
    DROP TABLE #roster_plan;
    SELECT @Inserted AS RowsInserted;
    RETURN 0;
END;
GO

/* ---- Apply pattern. 102 (ROS-3): ONE branch, the days each employee belongs to it. ---- */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_ApplyPattern
    @FromDate   DATE,
    @ToDate     DATE,
    @EmployeeId INT = NULL,
    @Overwrite  BIT = 0,
    @BranchId     INT = NULL,         -- 102 (ROS-3): required
    @CallerUserId INT = NULL          -- 102 (ROS-14)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @msg NVARCHAR(400);

    IF @FromDate > @ToDate
    BEGIN RAISERROR('FromDate must be on or before ToDate.', 16, 1); RETURN 1; END
    IF DATEDIFF(DAY, @FromDate, @ToDate) > 366
    BEGIN RAISERROR('Apply patterns to at most a year at a time.', 16, 1); RETURN 1; END
    IF @BranchId IS NULL
    BEGIN
        SET @msg = N'Choose a branch ' + NCHAR(8212) + N' weekly patterns are applied to one branch at a time.';
        RAISERROR(@msg, 16, 1); RETURN 1;
    END
    IF NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId)
    BEGIN RAISERROR('Branch not found.', 16, 1); RETURN 1; END

    IF OBJECT_ID('tempdb..#roster_plan') IS NOT NULL DROP TABLE #roster_plan;

    ;WITH cal_dates AS (
        SELECT @FromDate AS d
        UNION ALL
        SELECT DATEADD(DAY, 1, d) FROM cal_dates WHERE d < @ToDate
    ),
    cal_days AS (
        SELECT d AS WorkDate, ((DATEPART(WEEKDAY, d) + @@DATEFIRST - 2) % 7) + 1 AS Dow
        FROM cal_dates
    ),
    /* D5: the working shift a leave day gets when the pattern rests that weekday - the pattern's most frequent
       active working shift */
    usual AS (
        SELECT x.EmployeeId, x.ShiftId
        FROM (SELECT p.EmployeeId, p.ShiftId,
                     ROW_NUMBER() OVER (PARTITION BY p.EmployeeId ORDER BY COUNT(*) DESC, MIN(sh.StartTime) ASC, p.ShiftId ASC) AS rn
              FROM attendance.EMPLOYEE_SHIFT_PATTERN p
              JOIN attendance.SHIFT sh ON sh.ShiftId = p.ShiftId AND sh.IsActive = 1
              WHERE p.IsActive = 1 AND p.IsRestDay = 0
              GROUP BY p.EmployeeId, p.ShiftId) x
        WHERE x.rn = 1
    )
    SELECT p.EmployeeId, cd.WorkDate,
           CASE WHEN p.IsRestDay = 1 AND lv.OnLeave = 1 THEN u.ShiftId ELSE p.ShiftId END AS ShiftId,
           CAST(CASE WHEN p.IsRestDay = 1 AND lv.OnLeave = 1 THEN 0 ELSE p.IsRestDay END AS BIT) AS IsRestDay,
           lv.OnLeave
    INTO #roster_plan
    FROM attendance.EMPLOYEE_SHIFT_PATTERN p
    JOIN cal_days cd   ON cd.Dow = p.DayOfWeek
    JOIN hr.EMPLOYEE e ON e.EmployeeId = p.EmployeeId AND e.IsDeleted = 0
    LEFT JOIN attendance.SHIFT sh ON sh.ShiftId = p.ShiftId
    LEFT JOIN usual u ON u.EmployeeId = p.EmployeeId
    CROSS APPLY (SELECT hr.fn_EmployeeBranchOn(p.EmployeeId, cd.WorkDate) AS BranchId) b
    CROSS APPLY (SELECT CAST(CASE WHEN EXISTS (
                     SELECT 1 FROM workflow.LEAVE_REQUEST lr
                     JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId AND ri.[Status] = 'Approved'
                     WHERE lr.EmployeeId = p.EmployeeId
                       AND cd.WorkDate BETWEEN lr.FromDate AND ISNULL(lr.ApprovedToDate, lr.ToDate)) THEN 1 ELSE 0 END AS BIT) AS OnLeave) lv
    WHERE p.IsActive = 1
      AND (@EmployeeId IS NULL OR p.EmployeeId = @EmployeeId)
      AND e.HireDate <= cd.WorkDate
      AND (e.TerminationDate IS NULL OR e.TerminationDate >= cd.WorkDate)
      AND b.BranchId = @BranchId                                                  -- 102 (ROS-3)
      AND core.fn_IsHoliday(cd.WorkDate, b.BranchId) = 0                         -- 102: a holiday off is no row
      AND (p.IsRestDay = 1 OR sh.IsActive = 1)                                   -- 102 (ROS-9): never a retired shift
      AND NOT (p.IsRestDay = 1 AND lv.OnLeave = 1 AND u.ShiftId IS NULL)         -- D5 with no working shift to give
    OPTION (MAXRECURSION 400);

    IF OBJECT_ID('tempdb..#roster_change') IS NOT NULL DROP TABLE #roster_change;
    CREATE TABLE #roster_change (EmployeeId INT NOT NULL, WorkDate DATE NOT NULL);
    INSERT INTO #roster_change (EmployeeId, WorkDate)
    SELECT p.EmployeeId, p.WorkDate
    FROM #roster_plan p
    LEFT JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.EmployeeId = p.EmployeeId AND sa.WorkDate = p.WorkDate
    WHERE sa.ShiftAssignmentId IS NULL
       OR (@Overwrite = 1 AND p.OnLeave = 0
           AND (ISNULL(sa.ShiftId, -1) <> ISNULL(p.ShiftId, -1) OR sa.IsRestDay <> p.IsRestDay));
    DECLARE @rc INT;
    EXEC @rc = attendance.usp_Roster_AssertEditable @CallerUserId = @CallerUserId;
    DROP TABLE #roster_change;
    IF @rc <> 0 BEGIN DROP TABLE #roster_plan; RETURN 1; END

    IF @Overwrite = 1
        UPDATE sa
        SET sa.ShiftId = p.ShiftId, sa.IsRestDay = p.IsRestDay
        FROM attendance.SHIFT_ASSIGNMENT sa
        JOIN #roster_plan p ON p.EmployeeId = sa.EmployeeId AND p.WorkDate = sa.WorkDate
        WHERE p.OnLeave = 0
          AND (ISNULL(sa.ShiftId, -1) <> ISNULL(p.ShiftId, -1) OR sa.IsRestDay <> p.IsRestDay);

    INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
    SELECT p.EmployeeId, p.ShiftId, p.WorkDate, p.IsRestDay
    FROM #roster_plan p
    WHERE NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                      WHERE sa.EmployeeId = p.EmployeeId AND sa.WorkDate = p.WorkDate);

    DECLARE @Inserted INT = @@ROWCOUNT;
    DROP TABLE #roster_plan;
    SELECT @Inserted AS RowsInserted;
    RETURN 0;
END;
GO

/* usp_ShiftAssignment_ApplyPatternForMonth is defined only in an UNNUMBERED script (attendance_full_v3.sql). Its body
   there was checked against the API (it passes @YearMonth, @EmployeeId, @Overwrite and reads RowsInserted); this
   guard stops the script if the live procedure has a parameter the redefinition below would drop (CON-7). */
IF EXISTS (SELECT 1 FROM sys.parameters p
           WHERE p.object_id = OBJECT_ID('attendance.usp_ShiftAssignment_ApplyPatternForMonth')
             AND p.name NOT IN ('@YearMonth', '@EmployeeId', '@Overwrite', '@BranchId', '@CallerUserId'))
    RAISERROR('102_qa3_roster.sql: the live attendance.usp_ShiftAssignment_ApplyPatternForMonth has a parameter this script does not know - it is newer than the repo. Merge it by hand before applying 102.', 16, 1);
GO
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_ApplyPatternForMonth
    @YearMonth CHAR(7), @EmployeeId INT = NULL, @Overwrite BIT = 0,
    @BranchId INT = NULL,             -- 102 (ROS-3): required (the nested procedure refuses NULL)
    @CallerUserId INT = NULL          -- 102 (ROS-14)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATE = TRY_CAST(@YearMonth + '-01' AS DATE);
    IF @from IS NULL BEGIN RAISERROR('Period must look like ''2026-06''.', 16, 1); RETURN 1; END
    DECLARE @to   DATE = EOMONTH(@from);
    DECLARE @rc INT;
    EXEC @rc = attendance.usp_ShiftAssignment_ApplyPattern
         @FromDate = @from, @ToDate = @to, @EmployeeId = @EmployeeId, @Overwrite = @Overwrite,
         @BranchId = @BranchId, @CallerUserId = @CallerUserId;
    RETURN ISNULL(@rc, 1);
END;
GO

/* ---------------------------------------------------------------- 5. the gaps */
/* 102 (ROS-8): @BranchId = one branch, by the employee's branch ON the day (the page's banner showed the gaps of
   whoever was on the grid, so a transferred employee's days landed in the wrong branch's banner).
   102 (ROS-10): a public holiday of the branch of the day is not a gap - a holiday off is NO row (D1/D4), and
   "Fix these" used to roster people onto it. BranchId is appended to the result (existing readers keep theirs). */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_GetGaps
    @FromDate DATE, @ToDate DATE,
    @CallerUserId INT = NULL,         -- script 87 (BUG-04): without EMP_VIEW_ALL, own rows and the branches managed
    @BranchId     INT = NULL          -- 102 (ROS-8)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    ;WITH cal_dates AS (
        SELECT @FromDate AS d
        UNION ALL
        SELECT DATEADD(DAY, 1, d) FROM cal_dates WHERE d < @ToDate
    )
    SELECT e.EmployeeId, e.FullName, c.d AS WorkDate, b.BranchId
    FROM cal_dates c
    CROSS JOIN hr.EMPLOYEE e
    CROSS APPLY (SELECT hr.fn_EmployeeBranchOn(e.EmployeeId, c.d) AS BranchId) b
    WHERE e.IsDeleted = 0
      AND e.HireDate <= c.d
      AND (e.TerminationDate IS NULL OR e.TerminationDate >= c.d)
      AND (@SeesAll = 1 OR e.EmployeeId = @CallerEmp
           OR EXISTS (SELECT 1 FROM hr.BRANCH mb WHERE mb.ManagerEmployeeId = @CallerEmp AND mb.BranchId = b.BranchId))
      AND (@BranchId IS NULL OR b.BranchId = @BranchId)
      AND core.fn_IsHoliday(c.d, b.BranchId) = 0
      AND NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                      WHERE sa.EmployeeId = e.EmployeeId AND sa.WorkDate = c.d)
    ORDER BY c.d, e.FullName
    OPTION (MAXRECURSION 400);
END;
GO

/* ---------------------------------------------------------------- 6. clearing a month */
/* Unchanged from 85 except 102 (ROS-14): @UserId (the caller the API already passes) must hold EMP_VIEW_ALL or
   manage the branch. */
CREATE OR ALTER PROCEDURE attendance.usp_Roster_Clear
    @BranchId INT, @Year INT, @Month INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Month < 1 OR @Month > 12 OR @Year < 2000 OR @Year > 2100
    BEGIN RAISERROR('Give a real year and month.', 16, 1); RETURN 1; END
    IF NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId)
    BEGIN RAISERROR('Branch not found.', 16, 1); RETURN 1; END

    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@UserId);
    IF @SeesAll = 0 AND NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId AND ManagerEmployeeId = @CallerEmp)
    BEGIN RAISERROR('You can only plan rosters for the branches you manage.', 16, 1); RETURN 1; END

    DECLARE @MonthDate DATE = DATEFROMPARTS(@Year, @Month, 1);
    DECLARE @NextMonth DATE = DATEADD(MONTH, 1, @MonthDate);

    /* (a) no open or approved roster request for that branch + month */
    DECLARE @Rid INT, @RStatus VARCHAR(20), @RClosedAt DATETIME2;
    SELECT TOP 1 @Rid = ri.RequestInstanceId, @RStatus = ri.[Status], @RClosedAt = ri.ClosedAt
    FROM workflow.ROSTER_APPROVAL ra
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
    WHERE ra.BranchId = @BranchId AND ra.MonthDate = @MonthDate
      AND ri.[Status] IN ('Pending', 'OnHold', 'Approved')
    ORDER BY CASE ri.[Status] WHEN 'Approved' THEN 0 ELSE 1 END, ri.RequestInstanceId DESC;

    IF @RStatus = 'Approved'
    BEGIN
        DECLARE @When VARCHAR(20) = CONVERT(VARCHAR(11), ISNULL(@RClosedAt,
            (SELECT ApprovedAt FROM attendance.ROSTER_MONTH WHERE BranchId = @BranchId AND MonthDate = @MonthDate)), 106);
        RAISERROR('This roster cannot be cleared: it was approved on %s (request #%d).', 16, 1, @When, @Rid);
        RETURN 1;
    END
    IF @RStatus IS NOT NULL
    BEGIN RAISERROR('This roster cannot be cleared: it is waiting for approval (request #%d).', 16, 1, @Rid); RETURN 1; END
    IF EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH
               WHERE BranchId = @BranchId AND MonthDate = @MonthDate AND [Status] = 'Approved')
    BEGIN
        DECLARE @When2 VARCHAR(20) = CONVERT(VARCHAR(11),
            (SELECT ApprovedAt FROM attendance.ROSTER_MONTH WHERE BranchId = @BranchId AND MonthDate = @MonthDate), 106);
        RAISERROR('This roster cannot be cleared: it was approved on %s.', 16, 1, @When2);
        RETURN 1;
    END

    /* (b) no attendance processed on those days for those employees (the branch of the DAY, script 85) */
    DECLARE @Days INT = (
        SELECT COUNT(DISTINCT ar.WorkDate)
        FROM attendance.ATTENDANCE_RECORD ar
        WHERE ar.WorkDate >= @MonthDate AND ar.WorkDate < @NextMonth
          AND (hr.fn_EmployeeBranchOn(ar.EmployeeId, ar.WorkDate) = @BranchId
               OR EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                          WHERE sa.ShiftAssignmentId = ar.ShiftAssignmentId AND hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate) = @BranchId)));
    IF @Days > 0
    BEGIN
        DECLARE @DaysText VARCHAR(20) = CONCAT(@Days, CASE WHEN @Days = 1 THEN ' day' ELSE ' days' END);
        RAISERROR('This roster cannot be cleared: attendance already recorded for %s.', 16, 1, @DaysText);
        RETURN 1;
    END

    BEGIN TRAN;
        DELETE sa
        FROM attendance.SHIFT_ASSIGNMENT sa
        WHERE hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate) = @BranchId
          AND sa.WorkDate >= @MonthDate AND sa.WorkDate < @NextMonth;
        DECLARE @Deleted INT = @@ROWCOUNT;

        DELETE FROM attendance.ROSTER_MONTH WHERE BranchId = @BranchId AND MonthDate = @MonthDate;
        DECLARE @HeaderDeleted INT = @@ROWCOUNT;
    COMMIT;

    SELECT @Deleted AS RowsDeleted, CAST(@HeaderDeleted AS BIT) AS HeaderDeleted;
    RETURN 0;
END;
GO

/* ---------------------------------------------------------------- 7. where a month stands */
/* 102 (ROS-14): @CallerUserId - EMP_VIEW_ALL or the branch's manager.
   102 (ROS-7): the approval the month is measured against is the latest APPROVED request's (ROSTER_MONTH.ApprovedAt
   only for a month approved without a request). It used to be the LATEST request's: once a re-submission was
   rejected the month read "not changed since approval" while it still differed from what was signed, and Submit
   stayed off for good. */
CREATE OR ALTER PROCEDURE [attendance].[usp_RosterMonth_Get]
    @BranchId INT, @MonthDate DATE,
    @CallerUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    IF @SeesAll = 0 AND NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId AND ManagerEmployeeId = @CallerEmp)
    BEGIN RAISERROR('You can only plan rosters for the branches you manage.', 16, 1); RETURN 1; END

    SET @MonthDate = DATEFROMPARTS(YEAR(@MonthDate), MONTH(@MonthDate), 1);
    DECLARE @NextMonth DATE = DATEADD(MONTH, 1, @MonthDate);

    DECLARE @OpenRid INT, @OpenStatus VARCHAR(20);
    SELECT TOP 1 @OpenRid = ri.RequestInstanceId, @OpenStatus = ri.[Status]
    FROM workflow.ROSTER_APPROVAL ra
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
    WHERE ra.BranchId = @BranchId AND ra.MonthDate = @MonthDate
      AND ri.[Status] IN ('Draft', 'Pending', 'OnHold')
    ORDER BY ri.RequestInstanceId DESC;

    DECLARE @ApprovedAt DATETIME2 = (
        SELECT TOP 1 ri.ClosedAt
        FROM workflow.ROSTER_APPROVAL ra
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
        WHERE ra.BranchId = @BranchId AND ra.MonthDate = @MonthDate AND ri.[Status] = 'Approved'
        ORDER BY ri.ClosedAt DESC, ri.RequestInstanceId DESC);
    IF @ApprovedAt IS NULL
        SET @ApprovedAt = (SELECT ApprovedAt FROM attendance.ROSTER_MONTH
                           WHERE BranchId = @BranchId AND MonthDate = @MonthDate AND [Status] = 'Approved');

    DECLARE @LastChanged DATETIME2 = (
        SELECT MAX(x.Utc) FROM (
            SELECT MAX(sa.ModifiedUtc) AS Utc
            FROM attendance.SHIFT_ASSIGNMENT sa
            WHERE hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate) = @BranchId      -- script 85 (D7): the branch of the DAY
              AND sa.WorkDate >= @MonthDate AND sa.WorkDate < @NextMonth
            UNION ALL
            SELECT LastChangedUtc FROM attendance.ROSTER_MONTH
            WHERE BranchId = @BranchId AND MonthDate = @MonthDate) x
        WHERE x.Utc IS NOT NULL);

    SELECT rm.RosterMonthId, rm.BranchId, rm.MonthDate, rm.[Status], rm.ApprovedAt,
           rm.RequestInstanceId, ri.[Status] AS RequestStatus,
           @OpenRid     AS OpenRequestId,
           @OpenStatus  AS OpenRequestStatus,
           @ApprovedAt  AS LastApprovedAt,
           CAST(CASE WHEN @ApprovedAt IS NULL THEN 0
                     WHEN @LastChanged > @ApprovedAt THEN 1 ELSE 0 END AS BIT) AS ChangedSinceApproval,
           @LastChanged AS LastChangedUtc,
           rm.RederivedAt                                   -- 102: when attendance was last derived again for the month
    FROM attendance.ROSTER_MONTH rm
    LEFT JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = rm.RequestInstanceId
    WHERE rm.BranchId = @BranchId AND rm.MonthDate = @MonthDate;
    RETURN 0;
END;
GO

/* ---------------------------------------------------------------- 8. putting a month up for approval */
/* Unchanged from 85 except:
   - 102 (WF-7 / ROS-14): the submitter must hold EMP_VIEW_ALL or manage the branch;
   - 102 (WF-7): the request stays filed against the submitter (RaisedBy = the caller, as before), but its
     BranchManager steps are resolved against the ROSTER'S branch. The engine resolves "branch manager" from the
     requester's own branch, so HR (or anybody based elsewhere) submitting a branch's month had it signed by the
     manager of their own branch. A step the engine resolved to somebody else is pointed at the roster branch's
     manager - pending, or skipped with the engine's own reasons when that post is vacant or is the requester - and
     the request moves to its first step still needing a signature (approved automatically when none is left).
     When the submitter belongs to the branch nothing changes: the engine already resolved it that way.
   - the one-open-request rule and the changed-since check run inside the transaction, under an application lock
     on the branch-month: two submissions at the same moment cannot both pass them;
   - 102 (ROS-7): the approval measured against is the latest APPROVED request's. */
CREATE OR ALTER PROCEDURE [workflow].[usp_RosterApproval_Create]
    @EmployeeId     INT,
    @RaisedByUserId INT,
    @BranchId       INT,
    @MonthDate      DATE,           -- any day; normalised to the 1st
    @Title          NVARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @msg NVARCHAR(400);
    SET @MonthDate = DATEFROMPARTS(YEAR(@MonthDate), MONTH(@MonthDate), 1);
    DECLARE @NextMonth DATE = DATEADD(MONTH, 1, @MonthDate);

    IF NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId)
    BEGIN RAISERROR('Branch not found.', 16, 1); RETURN 1; END

    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@RaisedByUserId);
    IF @SeesAll = 0 AND NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId AND ManagerEmployeeId = @CallerEmp)
    BEGIN RAISERROR('You can only plan rosters for the branches you manage.', 16, 1); RETURN 1; END

    IF NOT EXISTS (SELECT 1
                   FROM attendance.SHIFT_ASSIGNMENT sa
                   JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId AND e.IsDeleted = 0
                   WHERE hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate) = @BranchId      -- script 85 (D7): the branch of the DAY
                     AND sa.WorkDate >= @MonthDate AND sa.WorkDate < @NextMonth)
    BEGIN
        SET @msg = N'No roster rows exist for that branch and month ' + NCHAR(8212) + N' build the roster first.';
        RAISERROR(@msg, 16, 1); RETURN 1;
    END

    BEGIN TRAN;

    DECLARE @lk INT, @LockName NVARCHAR(255) = CONCAT(N'workflow.roster-approval:', @BranchId, N':', CONVERT(CHAR(7), @MonthDate, 120));
    EXEC @lk = sp_getapplock @Resource = @LockName, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
    IF @lk < 0
    BEGIN ROLLBACK; RAISERROR('Another submission of this roster is in progress. Try again in a moment.', 16, 1); RETURN 1; END

    /* (a) one open request at a time */
    DECLARE @OpenRid INT = (
        SELECT TOP 1 ri.RequestInstanceId
        FROM workflow.ROSTER_APPROVAL ra WITH (UPDLOCK, HOLDLOCK)
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
        WHERE ra.BranchId = @BranchId AND ra.MonthDate = @MonthDate
          AND ri.[Status] IN ('Draft', 'Pending', 'OnHold')
        ORDER BY ri.RequestInstanceId DESC);
    IF @OpenRid IS NOT NULL
    BEGIN ROLLBACK; RAISERROR('This roster is already waiting for approval (request #%d).', 16, 1, @OpenRid); RETURN 1; END

    /* (b) after an approval, only a CHANGED roster may go up again (102, ROS-7: the latest APPROVED request) */
    DECLARE @ApprovedAt DATETIME2 = (
        SELECT TOP 1 ri.ClosedAt
        FROM workflow.ROSTER_APPROVAL ra
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
        WHERE ra.BranchId = @BranchId AND ra.MonthDate = @MonthDate AND ri.[Status] = 'Approved'
        ORDER BY ri.ClosedAt DESC, ri.RequestInstanceId DESC);
    IF @ApprovedAt IS NULL
        SET @ApprovedAt = (SELECT ApprovedAt FROM attendance.ROSTER_MONTH
                           WHERE BranchId = @BranchId AND MonthDate = @MonthDate AND [Status] = 'Approved');

    IF @ApprovedAt IS NOT NULL
    BEGIN
        DECLARE @Changed BIT = CASE WHEN EXISTS (
                SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                WHERE hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate) = @BranchId
                  AND sa.WorkDate >= @MonthDate AND sa.WorkDate < @NextMonth
                  AND sa.ModifiedUtc > @ApprovedAt)
            OR EXISTS (
                SELECT 1 FROM attendance.ROSTER_MONTH rm
                WHERE rm.BranchId = @BranchId AND rm.MonthDate = @MonthDate
                  AND rm.LastChangedUtc > @ApprovedAt)
            THEN 1 ELSE 0 END;
        IF @Changed = 0
        BEGIN
            ROLLBACK;
            DECLARE @When VARCHAR(20) = CONVERT(VARCHAR(11), @ApprovedAt, 106);   -- '19 Aug 2026'
            RAISERROR('This roster was approved on %s and has not changed since.', 16, 1, @When);
            RETURN 1;
        END
    END

    /* usp_Request_Submit returns SIX columns - the capture table must match. */
    DECLARE @T TABLE (RequestInstanceId    INT,
                      [Status]             VARCHAR(20),
                      CurrentStepNo        INT,
                      WorkflowDefinitionId INT,
                      WorkflowVersion      INT,
                      MinRequesterTier     INT);
    INSERT INTO @T
    EXEC workflow.usp_Request_Submit
         @RequestTypeCode = 'ROSTER_APPROVAL',
         @EmployeeId      = @EmployeeId,
         @RaisedByUserId  = @RaisedByUserId,
         @Title           = @Title;

    DECLARE @Rid INT = (SELECT TOP 1 RequestInstanceId FROM @T);
    IF @Rid IS NULL
    BEGIN ROLLBACK; RAISERROR('The workflow engine refused the submission.', 16, 1); RETURN 1; END

    INSERT INTO workflow.ROSTER_APPROVAL (RequestInstanceId, BranchId, MonthDate)
    VALUES (@Rid, @BranchId, @MonthDate);

    /* 102 (WF-7): the branch manager who signs is the ROSTER branch's */
    DECLARE @SubjectUser INT = (SELECT UserId FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId);
    DECLARE @MgrUser INT = (SELECT m.UserId
                            FROM hr.BRANCH b
                            JOIN hr.EMPLOYEE m ON m.EmployeeId = b.ManagerEmployeeId AND m.IsDeleted = 0
                            WHERE b.BranchId = @BranchId);
    DECLARE @fix TABLE (StepNo INT PRIMARY KEY, NewStatus VARCHAR(20) NOT NULL, NewReason NVARCHAR(300) NULL, WasStatus VARCHAR(20) NOT NULL);
    INSERT INTO @fix (StepNo, NewStatus, NewReason, WasStatus)
    SELECT si.StepNo,
           CASE WHEN @MgrUser IS NOT NULL AND @MgrUser <> ISNULL(@SubjectUser, -1) THEN 'Pending'
                WHEN si.FallbackRoleId IS NOT NULL THEN 'Pending'                      -- a deputy covers the step
                ELSE 'Skipped' END,
           CASE WHEN @MgrUser IS NOT NULL AND @MgrUser <> ISNULL(@SubjectUser, -1) THEN NULL
                WHEN si.FallbackRoleId IS NOT NULL THEN NULL
                WHEN @MgrUser IS NULL THEN N'No approver could be resolved (post vacant or no login).'
                ELSE N'Approver is the requester - nobody approves their own request.' END,
           si.[Status]
    FROM workflow.REQUEST_STEP_INSTANCE si
    WHERE si.RequestInstanceId = @Rid
      AND si.ApproverType = 'BranchManager'
      AND si.[Status] IN ('Pending', 'Skipped')
      AND ISNULL(si.ResolvedUserId, -1) <> ISNULL(@MgrUser, -1);
    IF EXISTS (SELECT 1 FROM @fix)
    BEGIN
        UPDATE si
        SET ResolvedUserId = @MgrUser, [Status] = f.NewStatus, SkipReason = f.NewReason
        FROM workflow.REQUEST_STEP_INSTANCE si
        JOIN @fix f ON f.StepNo = si.StepNo
        WHERE si.RequestInstanceId = @Rid;

        DELETE s
        FROM workflow.WORKFLOW_SIGNATURE s
        JOIN @fix f ON f.StepNo = s.StepNo
        WHERE s.RequestInstanceId = @Rid AND s.[Action] = 'Skipped' AND f.NewStatus <> 'Skipped';

        INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
        SELECT @Rid, f.StepNo, 'Skipped', NULL, f.NewReason
        FROM @fix f
        WHERE f.NewStatus = 'Skipped' AND f.WasStatus <> 'Skipped';

        DECLARE @Next INT = (SELECT MIN(StepNo) FROM workflow.REQUEST_STEP_INSTANCE
                             WHERE RequestInstanceId = @Rid AND [Status] = 'Pending');
        IF @Next IS NULL
            UPDATE workflow.REQUEST_INSTANCE
            SET [Status] = 'Approved', CurrentStepNo = NULL, ClosedAt = ISNULL(ClosedAt, SYSUTCDATETIME()),
                ClosedReason = ISNULL(ClosedReason, 'Approved automatically: every step was skipped.')
            WHERE RequestInstanceId = @Rid;
        ELSE
            UPDATE workflow.REQUEST_INSTANCE
            SET [Status] = 'Pending', CurrentStepNo = @Next, ClosedAt = NULL, ClosedReason = NULL
            WHERE RequestInstanceId = @Rid;
    END

    /* month state, pointing at the live request. An APPROVED month stays Approved while the
       re-approval is open (75); anything else becomes PendingApproval. */
    MERGE attendance.ROSTER_MONTH AS t
    USING (SELECT @BranchId AS BranchId, @MonthDate AS MonthDate) AS s
       ON t.BranchId = s.BranchId AND t.MonthDate = s.MonthDate
    WHEN MATCHED THEN UPDATE SET [Status] = CASE WHEN t.[Status] = 'Approved' THEN 'Approved' ELSE 'PendingApproval' END,
                                 RequestInstanceId = @Rid
    WHEN NOT MATCHED THEN INSERT (BranchId, MonthDate, [Status], RequestInstanceId)
                          VALUES (s.BranchId, s.MonthDate, 'PendingApproval', @Rid);

    /* auto-approve path: effects again now that the payload exists (idempotent). The API re-derives the month
       afterwards (attendance.usp_Roster_RederiveForRequest), outside this transaction. */
    IF (SELECT [Status] FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @Rid) = 'Approved'
        EXEC workflow.usp_Request_ApplyApprovalEffects @RequestInstanceId = @Rid;

    COMMIT;

    SELECT ri.RequestInstanceId, ri.[Status], ri.CurrentStepNo
    FROM workflow.REQUEST_INSTANCE ri WHERE ri.RequestInstanceId = @Rid;
    RETURN 0;
END;
GO

/* ---------------------------------------------------------------- 9. the employee form: termination, hire, transfer */
/* Unchanged from 85 (D7, the dated transfer) except:
   - 102 (ROS-1 / REL-1): nobody stays rostered outside their employment. The days not yet paid for the employee
     after a termination date on file, or before the hire date, that have a roster row or a non-manual record are
     derived again FIRST (script 100: no longer a working day for anybody - the non-manual record goes, with its
     exit-permission posting); then the roster rows on those days go (a record still pointing at one - a manual day,
     a day with a correction on file - lets go of it first; the SHIFT_ASSIGNMENT trigger marks the months as
     changed). Inside the update's transaction. Re-running it is a no-op.
   - 102 (ROS-8 / REL-9): a transfer moves the rows from its date into the other branch's month: those rows get a
     new ModifiedUtc and both branches' months a new LastChangedUtc, so both read "changed since approval"; the leave
     from the transfer on is re-priced (unit D's hr.usp_LeaveLedger_Reprice).
   - 102 (ATT-14 / ROS-5): the transfer's days are derived again up to TODAY only (today only when it already has a
     record) - never a future day, which used to get an Absent record and lock the roster.
   - 102 (unit D's handoff): a hire or termination date set, changed or cleared re-prices the leave too, from the
     earlier of the old and the new date to the last approved leave day - approved leave beyond a new last day stops
     consuming the balance (and inflating the payout); a termination cleared, it consumes again. One call with the
     transfer's, from the earliest date that moved. */
CREATE OR ALTER PROCEDURE [hr].[usp_Employee_Update]
    @EmployeeId INT, @BranchId INT, @DepartmentId INT, @PositionId INT,
    @FullName NVARCHAR(150), @NationalId VARCHAR(50) = NULL, @NssfNumber VARCHAR(50) = NULL,
    @HireDate DATE, @TerminationDate DATE = NULL, @ModifiedBy INT = NULL,
    @Email NVARCHAR(150) = NULL, @PhoneNumber VARCHAR(30) = NULL,
    @PreferredLanguage CHAR(2) = 'en',
    @BranchEffectiveFrom DATE = NULL        -- script 85 (D7): when the branch changes, the day the transfer takes effect (NULL = today in Beirut)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @msg NVARCHAR(400);

    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @OldBranch INT, @OldHire DATE, @OldTerm DATE;
    SELECT @OldBranch = BranchId, @OldHire = HireDate, @OldTerm = TerminationDate FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId;
    DECLARE @CurrentBranchToStore INT = @BranchId, @Transferred BIT = 0, @Eff DATE = NULL;
    IF @OldBranch IS NOT NULL AND @OldBranch <> @BranchId
    BEGIN
        SET @Transferred = 1;
        SET @Eff = ISNULL(@BranchEffectiveFrom, @Today);
        IF @Eff < @HireDate
        BEGIN RAISERROR('A transfer cannot take effect before the employee was hired.', 16, 1); RETURN 1; END
        IF EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeId = @EmployeeId AND EffectiveFrom > @Eff)
        BEGIN RAISERROR('A later transfer is already on file for this employee. A transfer cannot be dated before it.', 16, 1); RETURN 1; END
        /* D10: moving somebody out of a branch on a day that is already paid re-files paid days under another branch */
        IF payroll.fn_IsPeriodPaid(@EmployeeId, @Eff) = 1
        BEGIN
            SET @msg = N'This period is paid ' + NCHAR(8212) + N' raise a payroll adjustment instead.';
            RAISERROR(@msg, 16, 1); RETURN 1;
        END
        IF @Eff > @Today SET @CurrentBranchToStore = @OldBranch;      -- not yet: the nightly job moves them on the day
    END

    /* 102 (ROS-8): the rows the transfer moves, with the branch they belong to before it */
    DECLARE @moved TABLE (ShiftAssignmentId INT PRIMARY KEY, WorkDate DATE NOT NULL, OldBranch INT NULL, NewBranch INT NULL);
    IF @Transferred = 1
        INSERT INTO @moved (ShiftAssignmentId, WorkDate, OldBranch)
        SELECT sa.ShiftAssignmentId, sa.WorkDate, hr.fn_EmployeeBranchOn(@EmployeeId, sa.WorkDate)
        FROM attendance.SHIFT_ASSIGNMENT sa
        WHERE sa.EmployeeId = @EmployeeId AND sa.WorkDate >= @Eff;

    /* 102 (ROS-1): the roster rows outside the employment, on days not yet paid */
    DECLARE @gone TABLE (ShiftAssignmentId INT PRIMARY KEY, WorkDate DATE NOT NULL);

    BEGIN TRAN;
    IF @Transferred = 1
    BEGIN
        /* somebody created before branch history existed (or inserted around the procedures): their past starts here */
        IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeId = @EmployeeId)
            INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom, Note, CreatedBy)
            VALUES (@EmployeeId, @OldBranch, ISNULL(@OldHire, @HireDate), N'The branch on file before the first recorded transfer.', @ModifiedBy);
        IF EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeId = @EmployeeId AND EffectiveFrom = @Eff)
            UPDATE hr.EMPLOYEE_BRANCH_HISTORY SET BranchId = @BranchId, Note = N'Transfer (re-entered).', CreatedBy = @ModifiedBy, CreatedAt = SYSUTCDATETIME()
            WHERE EmployeeId = @EmployeeId AND EffectiveFrom = @Eff;
        ELSE
            INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom, Note, CreatedBy)
            VALUES (@EmployeeId, @BranchId, @Eff, N'Transfer.', @ModifiedBy);
    END
    UPDATE hr.EMPLOYEE
    SET BranchId = @CurrentBranchToStore, DepartmentId = @DepartmentId, PositionId = @PositionId,
        FullName = @FullName, NationalId = @NationalId, NssfNumber = @NssfNumber,
        HireDate = @HireDate, TerminationDate = @TerminationDate,
        Email = NULLIF(LTRIM(RTRIM(@Email)), N''),
        PhoneNumber = NULLIF(LTRIM(RTRIM(@PhoneNumber)), ''),
        PreferredLanguage = ISNULL(@PreferredLanguage, 'en'),
        ModifiedAt = SYSUTCDATETIME(), ModifiedBy = @ModifiedBy
    WHERE EmployeeId = @EmployeeId;

    /* 102 (ROS-8): both branches see that their month changed */
    IF @Transferred = 1
    BEGIN
        DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
        UPDATE @moved SET NewBranch = hr.fn_EmployeeBranchOn(@EmployeeId, WorkDate);
        DELETE FROM @moved WHERE ISNULL(OldBranch, -1) = ISNULL(NewBranch, -1);
        UPDATE sa SET ModifiedUtc = @Now
        FROM attendance.SHIFT_ASSIGNMENT sa
        JOIN @moved m ON m.ShiftAssignmentId = sa.ShiftAssignmentId;
        UPDATE rm SET LastChangedUtc = @Now
        FROM attendance.ROSTER_MONTH rm
        WHERE EXISTS (SELECT 1 FROM @moved m
                      WHERE rm.MonthDate = DATEFROMPARTS(YEAR(m.WorkDate), MONTH(m.WorkDate), 1)
                        AND (rm.BranchId = m.OldBranch OR rm.BranchId = m.NewBranch));
    END

    /* 102 (ROS-1 / REL-1): the unpaid days outside the employment with a roster row or a non-manual record are
       derived again FIRST - script 100 removes the non-manual record (attendance records point at SHIFT_ASSIGNMENT)
       - and only then do the rows go */
    INSERT INTO @gone (ShiftAssignmentId, WorkDate)
    SELECT sa.ShiftAssignmentId, sa.WorkDate
    FROM attendance.SHIFT_ASSIGNMENT sa
    WHERE sa.EmployeeId = @EmployeeId
      AND (sa.WorkDate < @HireDate OR (@TerminationDate IS NOT NULL AND sa.WorkDate > @TerminationDate))
      AND payroll.fn_IsPeriodPaid(@EmployeeId, sa.WorkDate) = 0;
    DECLARE @outside TABLE (WorkDate DATE PRIMARY KEY);
    INSERT INTO @outside (WorkDate)
    SELECT g.WorkDate FROM @gone g
    UNION
    SELECT ar.WorkDate
    FROM attendance.ATTENDANCE_RECORD ar
    WHERE ar.EmployeeId = @EmployeeId AND ar.IsManual = 0
      AND (ar.WorkDate < @HireDate OR (@TerminationDate IS NOT NULL AND ar.WorkDate > @TerminationDate))
      AND payroll.fn_IsPeriodPaid(@EmployeeId, ar.WorkDate) = 0;
    DECLARE @Day DATE;
    DECLARE out_cur CURSOR LOCAL FAST_FORWARD FOR SELECT WorkDate FROM @outside ORDER BY WorkDate;
    OPEN out_cur; FETCH NEXT FROM out_cur INTO @Day;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @EmployeeId, @WorkDate = @Day;   -- 'None' there (script 100)
        FETCH NEXT FROM out_cur INTO @Day;
    END
    CLOSE out_cur; DEALLOCATE out_cur;
    IF EXISTS (SELECT 1 FROM @gone)
    BEGIN
        /* what still points at a row is a day ComputeDay keeps for HR (manual, or a correction on file) */
        UPDATE ar SET ShiftAssignmentId = NULL
        FROM attendance.ATTENDANCE_RECORD ar
        JOIN @gone g ON g.ShiftAssignmentId = ar.ShiftAssignmentId;
        DELETE sa
        FROM attendance.SHIFT_ASSIGNMENT sa
        JOIN @gone g ON g.ShiftAssignmentId = sa.ShiftAssignmentId;
    END
    COMMIT TRAN;

    /* after a transfer, the days from its date up to TODAY (ATT-14 / ROS-5: never a future day) */
    DECLARE @days TABLE (WorkDate DATE PRIMARY KEY);
    IF @Transferred = 1 AND @Eff <= @Today
    BEGIN
        DECLARE @d DATE = @Eff;
        WHILE @d <= @Today
        BEGIN
            /* only days that have something to say: a record, or (before today) a roster row; a day outside the
               employment was dealt with above */
            IF NOT EXISTS (SELECT 1 FROM @outside WHERE WorkDate = @d)
               AND (EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @EmployeeId AND WorkDate = @d)
                    OR (@d < @Today AND EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @EmployeeId AND WorkDate = @d)))
                INSERT INTO @days (WorkDate) VALUES (@d);
            SET @d = DATEADD(DAY, 1, @d);
        END
    END

    DECLARE day_cur CURSOR LOCAL FAST_FORWARD FOR SELECT WorkDate FROM @days ORDER BY WorkDate;
    OPEN day_cur; FETCH NEXT FROM day_cur INTO @Day;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @EmployeeId, @WorkDate = @Day;   -- paid and manual days are skipped there
        FETCH NEXT FROM day_cur INTO @Day;
    END
    CLOSE day_cur; DEALLOCATE day_cur;

    /* 102: the leave priced again (unit D's hr.usp_LeaveLedger_Reprice; paid months are left as they are) from the
       earliest date that moved to the last approved leave day:
       - ROS-8: a transfer's date - the leave from it on belongs to the other branch's roster and holidays;
       - unit D: a hire or termination date set, changed or cleared - from the earlier of the old and the new date
         (a day outside the employment costs nothing) */
    DECLARE @RepriceFrom DATE = CASE WHEN @Transferred = 1 THEN @Eff END;
    IF @OldHire IS NOT NULL AND @OldHire <> @HireDate
        SET @RepriceFrom = (SELECT MIN(v.d) FROM (VALUES (@RepriceFrom), (@OldHire), (@HireDate)) v(d));
    IF @OldHire IS NOT NULL AND ISNULL(@OldTerm, '99991231') <> ISNULL(@TerminationDate, '99991231')
        SET @RepriceFrom = (SELECT MIN(v.d) FROM (VALUES (@RepriceFrom), (@OldTerm), (@TerminationDate)) v(d));
    IF @RepriceFrom IS NOT NULL
    BEGIN
        DECLARE @LeaveTo DATE = (SELECT MAX(ISNULL(lr.ApprovedToDate, lr.ToDate))
                                 FROM workflow.LEAVE_REQUEST lr
                                 JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId AND ri.[Status] = 'Approved'
                                 WHERE lr.EmployeeId = @EmployeeId AND ISNULL(lr.ApprovedToDate, lr.ToDate) >= @RepriceFrom);
        IF @LeaveTo IS NOT NULL
            EXEC hr.usp_LeaveLedger_Reprice @EmployeeId = @EmployeeId, @FromDate = @RepriceFrom, @ToDate = @LeaveTo;
    END
    RETURN 0;
END;
GO

/* A transfer recorded ahead of its date can be cancelled until it takes effect (85). 102 (ROS-8): the rows from its
   date go back to the branch before it - both months say so - and the leave from it is re-priced. */
CREATE OR ALTER PROCEDURE hr.usp_EmployeeBranchHistory_CancelFuture
    @EmployeeBranchHistoryId INT, @ActedByUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @Emp INT, @From DATE;
    SELECT @Emp = EmployeeId, @From = EffectiveFrom FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeBranchHistoryId = @EmployeeBranchHistoryId;
    IF @Emp IS NULL BEGIN RAISERROR('That branch history row does not exist.', 16, 1); RETURN 1; END
    /* the past is a record: rosters, attendance and payroll were filed under it */
    IF @From <= @Today
    BEGIN RAISERROR('This transfer has already taken effect and is part of the record. Transfer the employee again instead.', 16, 1); RETURN 1; END

    DECLARE @moved TABLE (ShiftAssignmentId INT PRIMARY KEY, WorkDate DATE NOT NULL, OldBranch INT NULL, NewBranch INT NULL);
    INSERT INTO @moved (ShiftAssignmentId, WorkDate, OldBranch)
    SELECT sa.ShiftAssignmentId, sa.WorkDate, hr.fn_EmployeeBranchOn(@Emp, sa.WorkDate)
    FROM attendance.SHIFT_ASSIGNMENT sa
    WHERE sa.EmployeeId = @Emp AND sa.WorkDate >= @From;

    BEGIN TRAN;
    DELETE FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeBranchHistoryId = @EmployeeBranchHistoryId;
    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    UPDATE @moved SET NewBranch = hr.fn_EmployeeBranchOn(@Emp, WorkDate);
    DELETE FROM @moved WHERE ISNULL(OldBranch, -1) = ISNULL(NewBranch, -1);
    UPDATE sa SET ModifiedUtc = @Now
    FROM attendance.SHIFT_ASSIGNMENT sa
    JOIN @moved m ON m.ShiftAssignmentId = sa.ShiftAssignmentId;
    UPDATE rm SET LastChangedUtc = @Now
    FROM attendance.ROSTER_MONTH rm
    WHERE EXISTS (SELECT 1 FROM @moved m
                  WHERE rm.MonthDate = DATEFROMPARTS(YEAR(m.WorkDate), MONTH(m.WorkDate), 1)
                    AND (rm.BranchId = m.OldBranch OR rm.BranchId = m.NewBranch));
    COMMIT;

    DECLARE @LeaveTo DATE = (SELECT MAX(ISNULL(lr.ApprovedToDate, lr.ToDate))
                             FROM workflow.LEAVE_REQUEST lr
                             JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId AND ri.[Status] = 'Approved'
                             WHERE lr.EmployeeId = @Emp AND ISNULL(lr.ApprovedToDate, lr.ToDate) >= @From);
    IF @LeaveTo IS NOT NULL
        EXEC hr.usp_LeaveLedger_Reprice @EmployeeId = @Emp, @FromDate = @From, @ToDate = @LeaveTo;

    SELECT @EmployeeBranchHistoryId AS EmployeeBranchHistoryId, CAST(1 AS BIT) AS Cancelled;
    RETURN 0;
END;
GO

/* ---------------------------------------------------------------- 10. approval re-derives the month (ROS-2 / ATT-1) */
/* THE CONTRACT: ComputeDay for every employee-day of the branch-month (the employee's branch OF THE DAY) from the 1st
   to min(Beirut yesterday, month end) that has a roster row or an attendance record; then
   hr.usp_LeaveLedger_Reprice for those employees and the month (ROS-12: leave approved before the roster existed is
   priced on the roster as approved; paid periods are skipped there). No result set. Paid and manual days are
   skipped by ComputeDay itself.
   Also: @CallerUserId (the page's "Re-derive month", REL-16) is scoped like every roster writer; @DaysRederived
   tells the page how many days were derived. One run per branch-month at a time (an application lock); the month's
   RederivedAt / RederivedStatus are stamped with the moment the run STARTED, so an approval landing during a run
   still leaves the month to the nightly safety net. */
CREATE OR ALTER PROCEDURE attendance.usp_Roster_RederiveMonth
    @BranchId INT,
    @Year     INT,
    @Month    INT,
    @CallerUserId  INT = NULL,
    @DaysRederived INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @DaysRederived = 0;

    IF @Year IS NULL OR @Month IS NULL OR @Month < 1 OR @Month > 12 OR @Year < 2000 OR @Year > 2100
    BEGIN RAISERROR('Give a real year and month.', 16, 1); RETURN 1; END
    IF NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId)
    BEGIN RAISERROR('Branch not found.', 16, 1); RETURN 1; END
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    IF @SeesAll = 0 AND NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId AND ManagerEmployeeId = @CallerEmp)
    BEGIN RAISERROR('You can only plan rosters for the branches you manage.', 16, 1); RETURN 1; END

    DECLARE @From     DATE = DATEFROMPARTS(@Year, @Month, 1);
    DECLARE @MonthEnd DATE = EOMONTH(@From);
    DECLARE @Today    DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @To       DATE = CASE WHEN DATEADD(DAY, -1, @Today) < @MonthEnd THEN DATEADD(DAY, -1, @Today) ELSE @MonthEnd END;
    DECLARE @Started  DATETIME2 = SYSUTCDATETIME();

    DECLARE @Lock NVARCHAR(255) = CONCAT(N'attendance.roster-rederive:', @BranchId, N':', CONVERT(CHAR(7), @From, 120));
    DECLARE @lk INT;
    EXEC @lk = sp_getapplock @Resource = @Lock, @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = 60000;
    IF @lk < 0 RETURN 0;          -- another run is re-deriving this month right now; its marker says what is left

    BEGIN TRY
        CREATE TABLE #rd (EmployeeId INT NOT NULL, WorkDate DATE NOT NULL, PRIMARY KEY (EmployeeId, WorkDate));
        IF @To >= @From
            INSERT INTO #rd (EmployeeId, WorkDate)
            SELECT x.EmployeeId, x.WorkDate
            FROM (SELECT sa.EmployeeId, sa.WorkDate FROM attendance.SHIFT_ASSIGNMENT sa WHERE sa.WorkDate BETWEEN @From AND @To
                  UNION
                  SELECT ar.EmployeeId, ar.WorkDate FROM attendance.ATTENDANCE_RECORD ar WHERE ar.WorkDate BETWEEN @From AND @To) x
            WHERE hr.fn_EmployeeBranchOn(x.EmployeeId, x.WorkDate) = @BranchId;

        DECLARE @E INT, @D DATE;
        DECLARE rd_cur CURSOR LOCAL FAST_FORWARD FOR SELECT EmployeeId, WorkDate FROM #rd ORDER BY WorkDate, EmployeeId;
        OPEN rd_cur; FETCH NEXT FROM rd_cur INTO @E, @D;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E, @WorkDate = @D;
            SET @DaysRederived = @DaysRederived + 1;
            FETCH NEXT FROM rd_cur INTO @E, @D;
        END
        CLOSE rd_cur; DEALLOCATE rd_cur;

        /* ROS-12: the employees of the branch-month with approved leave in it - priced on the roster as it now stands */
        DECLARE @emps TABLE (EmployeeId INT PRIMARY KEY);
        INSERT INTO @emps (EmployeeId)
        SELECT DISTINCT x.EmployeeId
        FROM (SELECT sa.EmployeeId, sa.WorkDate FROM attendance.SHIFT_ASSIGNMENT sa WHERE sa.WorkDate BETWEEN @From AND @MonthEnd
              UNION
              SELECT EmployeeId, WorkDate FROM #rd) x
        WHERE hr.fn_EmployeeBranchOn(x.EmployeeId, x.WorkDate) = @BranchId
          AND EXISTS (SELECT 1 FROM workflow.LEAVE_REQUEST lr
                      JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId AND ri.[Status] = 'Approved'
                      WHERE lr.EmployeeId = x.EmployeeId AND lr.FromDate <= @MonthEnd AND lr.ToDate >= @From);
        DECLARE em_cur CURSOR LOCAL FAST_FORWARD FOR SELECT EmployeeId FROM @emps ORDER BY EmployeeId;
        OPEN em_cur; FETCH NEXT FROM em_cur INTO @E;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC hr.usp_LeaveLedger_Reprice @EmployeeId = @E, @FromDate = @From, @ToDate = @MonthEnd;
            FETCH NEXT FROM em_cur INTO @E;
        END
        CLOSE em_cur; DEALLOCATE em_cur;

        UPDATE attendance.ROSTER_MONTH
        SET RederivedAt = @Started, RederivedStatus = [Status]
        WHERE BranchId = @BranchId AND MonthDate = @From;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK;
        EXEC sp_releaseapplock @Resource = @Lock, @LockOwner = 'Session';
        THROW;
    END CATCH;
    EXEC sp_releaseapplock @Resource = @Lock, @LockOwner = 'Session';
    RETURN 0;
END;
GO

/* Right after a ROSTER_APPROVAL request ends Approved (the API calls it: the generic approve, a version move that
   closes it, the auto-approval at submission). Nothing to do unless the request is the approval in force of its
   branch-month (its effect applied); otherwise the nightly safety net takes the month when it is. No result set. */
CREATE OR ALTER PROCEDURE attendance.usp_Roster_RederiveForRequest
    @RequestInstanceId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @B INT, @M DATE;
    SELECT @B = ra.BranchId, @M = ra.MonthDate
    FROM workflow.ROSTER_APPROVAL ra
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId AND ri.[Status] = 'Approved'
    JOIN attendance.ROSTER_MONTH rm ON rm.BranchId = ra.BranchId AND rm.MonthDate = ra.MonthDate
                                   AND rm.[Status] = 'Approved' AND rm.RequestInstanceId = ra.RequestInstanceId
    WHERE ra.RequestInstanceId = @RequestInstanceId;
    IF @B IS NULL RETURN 0;
    DECLARE @Y INT = YEAR(@M), @Mo INT = MONTH(@M), @rc INT;
    EXEC @rc = attendance.usp_Roster_RederiveMonth @BranchId = @B, @Year = @Y, @Month = @Mo;
    RETURN ISNULL(@rc, 0);
END;
GO

/* THE NIGHTLY SAFETY NET: every month approved (or approved again) since it was last re-derived, and every month
   re-derived as approved that is approved no longer (an approval taken back). One month failing does not stop the
   others; the result says how many were done and how many failed (the job logs the first error). */
CREATE OR ALTER PROCEDURE attendance.usp_Roster_RederivePending
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @todo TABLE (BranchId INT NOT NULL, MonthDate DATE NOT NULL, PRIMARY KEY (BranchId, MonthDate));
    INSERT INTO @todo (BranchId, MonthDate)
    SELECT rm.BranchId, rm.MonthDate
    FROM attendance.ROSTER_MONTH rm
    WHERE (rm.[Status] = 'Approved' AND (rm.RederivedAt IS NULL OR rm.RederivedAt < ISNULL(rm.ApprovedAt, '19000101')))
       OR (rm.RederivedStatus = 'Approved' AND rm.[Status] <> 'Approved');

    DECLARE @B INT, @M DATE, @Y INT, @Mo INT, @Done INT = 0, @Failed INT = 0, @FirstError NVARCHAR(2048) = NULL;
    DECLARE m_cur CURSOR LOCAL FAST_FORWARD FOR SELECT BranchId, MonthDate FROM @todo ORDER BY MonthDate, BranchId;
    OPEN m_cur; FETCH NEXT FROM m_cur INTO @B, @M;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @Y = YEAR(@M), @Mo = MONTH(@M);
        BEGIN TRY
            EXEC attendance.usp_Roster_RederiveMonth @BranchId = @B, @Year = @Y, @Month = @Mo;
            SET @Done = @Done + 1;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @Failed = @Failed + 1;
            IF @FirstError IS NULL
                SET @FirstError = LEFT(CONCAT(N'branch ', @B, N', ', CONVERT(CHAR(7), @M, 120), N': ', ERROR_MESSAGE()), 2048);
        END CATCH;
        FETCH NEXT FROM m_cur INTO @B, @M;
    END
    CLOSE m_cur; DEALLOCATE m_cur;

    SELECT @Done AS MonthsRederived, @Failed AS MonthsFailed, @FirstError AS FirstError;
END;
GO

/* ---------------------------------------------------------------- 11. who is on leave, by day (ROS-4 / LEV-5) */
/* The roster page's leave overlay. From the APPROVED leave requests - FromDate .. ISNULL(ApprovedToDate, ToDate), a
   partial approval keeping its first days - one row per employee-day, 1.00 a whole day and 0.50 a half day (two
   halves of one day add up to 1.00). Exit-permission minutes converted to leave are not leave days. Filtered to one
   branch (the employee's branch OF THE DAY) when asked, and to what the caller may see (script 87's rule). */
CREATE OR ALTER PROCEDURE attendance.usp_Roster_GetLeaveDays
    @FromDate DATE, @ToDate DATE,
    @BranchId     INT = NULL,
    @CallerUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @FromDate IS NULL OR @ToDate IS NULL OR @FromDate > @ToDate
    BEGIN RAISERROR('''from'' must be on or before ''to''.', 16, 1); RETURN 1; END
    IF DATEDIFF(DAY, @FromDate, @ToDate) > 400
    BEGIN RAISERROR('Ask for at most a year of leave days at a time.', 16, 1); RETURN 1; END

    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);

    ;WITH n AS (
        SELECT TOP (DATEDIFF(DAY, @FromDate, @ToDate) + 1) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
        FROM sys.all_objects
    ),
    d AS (SELECT DATEADD(DAY, i, @FromDate) AS WorkDate FROM n),
    x AS (
        SELECT lr.EmployeeId, d.WorkDate,
               CAST(CASE WHEN lr.HalfDay IS NOT NULL THEN 0.50 ELSE 1.00 END AS DECIMAL(6,2)) AS Part,
               hr.fn_EmployeeBranchOn(lr.EmployeeId, d.WorkDate) AS BranchId
        FROM workflow.LEAVE_REQUEST lr
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId AND ri.[Status] = 'Approved'
        JOIN hr.EMPLOYEE e ON e.EmployeeId = lr.EmployeeId AND e.IsDeleted = 0
        JOIN d ON d.WorkDate BETWEEN lr.FromDate AND ISNULL(lr.ApprovedToDate, lr.ToDate)
        WHERE lr.FromDate <= @ToDate AND ISNULL(lr.ApprovedToDate, lr.ToDate) >= @FromDate
    )
    SELECT x.EmployeeId,
           x.WorkDate AS [Date],
           CAST(CASE WHEN SUM(x.Part) > 1 THEN 1 ELSE SUM(x.Part) END AS DECIMAL(6,2)) AS DaysOnLeave
    FROM x
    WHERE (@BranchId IS NULL OR x.BranchId = @BranchId)
      AND (@SeesAll = 1 OR x.EmployeeId = @CallerEmp
           OR EXISTS (SELECT 1 FROM hr.BRANCH mb WHERE mb.ManagerEmployeeId = @CallerEmp AND mb.BranchId = x.BranchId))
    GROUP BY x.EmployeeId, x.WorkDate
    ORDER BY x.WorkDate, x.EmployeeId;
    RETURN 0;
END;
GO

/* ---------------------------------------------------------------- 12. data repairs */
/* R1 (ROS-1 / REL-1): the days not paid for the employee outside the employment that have a roster row or a
   non-manual record are derived again FIRST (script 100 removes the non-manual record, with its exit-permission
   posting), then their roster rows are removed (a record still pointing at one - manual, or with a correction on
   file - lets go of it first; the trigger marks their months as changed). Idempotent: a second run finds nothing. */
SET NOCOUNT ON;
DECLARE @gone TABLE (ShiftAssignmentId INT PRIMARY KEY, EmployeeId INT NOT NULL, WorkDate DATE NOT NULL);
INSERT INTO @gone (ShiftAssignmentId, EmployeeId, WorkDate)
SELECT sa.ShiftAssignmentId, sa.EmployeeId, sa.WorkDate
FROM attendance.SHIFT_ASSIGNMENT sa
JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId
WHERE (sa.WorkDate < e.HireDate OR (e.TerminationDate IS NOT NULL AND sa.WorkDate > e.TerminationDate))
  AND payroll.fn_IsPeriodPaid(sa.EmployeeId, sa.WorkDate) = 0;
DECLARE @rd TABLE (EmployeeId INT NOT NULL, WorkDate DATE NOT NULL, PRIMARY KEY (EmployeeId, WorkDate));
INSERT INTO @rd (EmployeeId, WorkDate)
SELECT EmployeeId, WorkDate FROM @gone
UNION
SELECT ar.EmployeeId, ar.WorkDate
FROM attendance.ATTENDANCE_RECORD ar
JOIN hr.EMPLOYEE e ON e.EmployeeId = ar.EmployeeId
WHERE ar.IsManual = 0
  AND (ar.WorkDate < e.HireDate OR (e.TerminationDate IS NOT NULL AND ar.WorkDate > e.TerminationDate))
  AND payroll.fn_IsPeriodPaid(ar.EmployeeId, ar.WorkDate) = 0;
DECLARE @E INT, @D DATE, @Derived INT = 0;
DECLARE r1_cur CURSOR LOCAL FAST_FORWARD FOR SELECT EmployeeId, WorkDate FROM @rd ORDER BY EmployeeId, WorkDate;
OPEN r1_cur; FETCH NEXT FROM r1_cur INTO @E, @D;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E, @WorkDate = @D;
    SET @Derived = @Derived + 1;
    FETCH NEXT FROM r1_cur INTO @E, @D;
END
CLOSE r1_cur; DEALLOCATE r1_cur;
DECLARE @Removed INT = 0;
IF EXISTS (SELECT 1 FROM @gone)
BEGIN
    BEGIN TRAN;
    UPDATE ar SET ShiftAssignmentId = NULL
    FROM attendance.ATTENDANCE_RECORD ar
    JOIN @gone g ON g.ShiftAssignmentId = ar.ShiftAssignmentId;
    DELETE sa FROM attendance.SHIFT_ASSIGNMENT sa JOIN @gone g ON g.ShiftAssignmentId = sa.ShiftAssignmentId;
    SET @Removed = @@ROWCOUNT;
    COMMIT;
END
PRINT CONCAT('REPAIR R1 | days outside the employment derived again: ', @Derived, '; roster rows outside it removed: ', @Removed);
GO

/* R2 (ATT-14 / ROS-5): an attendance record dated after today (Beirut) that holds no punch and is not manual was made
   by a re-derivation that ran ahead of time (the holiday recompute, a transfer); it locked the roster day. The day is
   derived when it comes. Paid days and days with a correction on file are left alone. */
SET NOCOUNT ON;
DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
BEGIN TRY
    DELETE ar
    FROM attendance.ATTENDANCE_RECORD ar
    WHERE ar.WorkDate > @Today
      AND ar.IsManual = 0
      AND ar.FirstInUtc IS NULL AND ar.LastOutUtc IS NULL
      AND payroll.fn_IsPeriodPaid(ar.EmployeeId, ar.WorkDate) = 0
      AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_CORRECTION c WHERE c.AttendanceId = ar.AttendanceId);
    PRINT CONCAT('REPAIR R2 | future attendance records without punches removed: ', @@ROWCOUNT);
END TRY
BEGIN CATCH
    PRINT CONCAT('REPAIR R2 | skipped (', ERROR_MESSAGE(), ') - remove those future records by hand.');
END CATCH;
GO

/* R3 (ROS-2): the months approved before this script have RederivedAt NULL - the first nightly run
   (attendance.usp_Roster_RederivePending) derives their completed days again against the approved roster. */
DECLARE @Pending INT = (SELECT COUNT(*) FROM attendance.ROSTER_MONTH WHERE [Status] = 'Approved' AND RederivedAt IS NULL);
PRINT CONCAT('REPAIR R3 | approved roster months the nightly safety net will re-derive: ', @Pending);
GO

/* R4 (unit D's handoff, ROS-1 / REL-1): approved leave that reaches before the hire date or past a termination date on
   file kept consuming the balance (and inflating a leaver's payout). It is priced again by unit D's
   hr.usp_LeaveLedger_Reprice from the first such request's first day to the employee's last approved leave day - the
   days outside the employment cost nothing; paid months are left as they are. The same as saving the employee form
   now. Idempotent: what is already right is left alone. One employee's failure is reported and the others go on. */
SET NOCOUNT ON;
DECLARE @rp TABLE (EmployeeId INT PRIMARY KEY, FromDate DATE NOT NULL, ToDate DATE NOT NULL);
INSERT INTO @rp (EmployeeId, FromDate, ToDate)
SELECT lr.EmployeeId, MIN(lr.FromDate), MAX(ISNULL(lr.ApprovedToDate, lr.ToDate))
FROM workflow.LEAVE_REQUEST lr
JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId AND ri.[Status] = 'Approved'
JOIN hr.EMPLOYEE e ON e.EmployeeId = lr.EmployeeId
WHERE lr.FromDate < e.HireDate
   OR (e.TerminationDate IS NOT NULL AND ISNULL(lr.ApprovedToDate, lr.ToDate) > e.TerminationDate)
GROUP BY lr.EmployeeId;
UPDATE r SET ToDate = x.LastDay
FROM @rp r
CROSS APPLY (SELECT MAX(ISNULL(lr.ApprovedToDate, lr.ToDate)) AS LastDay
             FROM workflow.LEAVE_REQUEST lr
             JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId AND ri.[Status] = 'Approved'
             WHERE lr.EmployeeId = r.EmployeeId) x;
DECLARE @E INT, @F DATE, @T DATE, @Done INT = 0, @Failed INT = 0, @FirstError NVARCHAR(400) = NULL;
DECLARE r4_cur CURSOR LOCAL FAST_FORWARD FOR SELECT EmployeeId, FromDate, ToDate FROM @rp ORDER BY EmployeeId;
OPEN r4_cur; FETCH NEXT FROM r4_cur INTO @E, @F, @T;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC hr.usp_LeaveLedger_Reprice @EmployeeId = @E, @FromDate = @F, @ToDate = @T;
        SET @Done = @Done + 1;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @Failed = @Failed + 1;
        IF @FirstError IS NULL SET @FirstError = CONCAT('employee ', @E, ': ', ERROR_MESSAGE());
    END CATCH;
    FETCH NEXT FROM r4_cur INTO @E, @F, @T;
END
CLOSE r4_cur; DEALLOCATE r4_cur;
PRINT CONCAT('REPAIR R4 | employees whose leave outside the employment was priced again: ', @Done,
             CASE WHEN @Failed > 0 THEN CONCAT('; FAILED for ', @Failed, ' (first: ', @FirstError, ') - re-save those employees') ELSE '' END);
GO

PRINT '102_qa3_roster.sql: QA3 roster fixes in place';
GO
