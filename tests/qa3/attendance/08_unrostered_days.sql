/* Script 108 (docs/108_unrostered_days.sql) - A DAY WITH PUNCHES THAT THE APPROVED ROSTER DOES NOT KNOW.
   The day is listed with its state; a person decides it (a shift, a rest day that was worked, or not work with a
   reason); who may decide is two permissions by the day's date (OFFROSTER_TODAY / OFFROSTER_PAST) inside the caller's
   branches - no longer EMP_VIEW_ALL; a dismissal answers the punches it saw and is reopened by a later punch; the
   Roster page's writer is the same door (same permissions, the decision filed, today's day derived at once);
   payroll readiness counts the undecided completed days and blocks from the month of setting
   OffRosterBlocksPayrollFrom, while attendance.usp_Attendance_PayrollReadiness keeps its 11 columns; a period
   already paid for the employee is read-only (listed, not decidable, not counted).
   Runs on a dev database with docs/108_unrostered_days.sql applied, inside a transaction that is rolled back.
   sqlcmd -I -b -i tests/qa3/attendance/08_unrostered_days.sql   ->  prints 'ok 08_unrostered_days' */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
BEGIN TRAN;
DECLARE @fails INT = 0, @err NVARCHAR(2000), @m NVARCHAR(2000), @n INT, @n0 INT, @c0 INT, @c1 INT, @bit BIT;
DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
DECLARE @CM DATE = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);
DECLARE @PM DATE = DATEADD(MONTH, -1, @CM), @PMEnd DATE = EOMONTH(DATEADD(MONTH, -1, @Today));
DECLARE @PMText CHAR(7) = CONVERT(CHAR(7), @PM, 23), @CMText CHAR(7) = CONVERT(CHAR(7), @CM, 23);
DECLARE @X DATE = DATEADD(DAY, 9, @PM), @X2 DATE = DATEADD(DAY, 12, @PM);
DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);

/* the counts before anything of this scenario exists (a dev database may hold days of its own) */
SELECT @c0 = UndecidedUnrosteredDays FROM attendance.fn_PayrollReadiness(@PMText, NULL);
SELECT @c1 = UndecidedUnrosteredDays FROM attendance.fn_PayrollReadiness(@CMText, NULL);

/* ---- two branches, their managers, HR, and somebody who only sees everything ---- */
INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Unrostered One', 1); DECLARE @B1 INT = SCOPE_IDENTITY();
INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Unrostered Two', 1); DECLARE @B2 INT = SCOPE_IDENTITY();
INSERT INTO security.[USER] (Username, PasswordHash, IsActive)
VALUES (N'qa3.unr.mgr1', N'x', 1), (N'qa3.unr.mgr2', N'x', 1), (N'qa3.unr.hr', N'x', 1), (N'qa3.unr.sees', N'x', 1);
DECLARE @UMgr1 INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.unr.mgr1');
DECLARE @UMgr2 INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.unr.mgr2');
DECLARE @UHr   INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.unr.hr');
DECLARE @USees INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.unr.sees');
INSERT INTO security.[ROLE] (Name) VALUES (N'QA3 Unr Today'); DECLARE @RToday INT = SCOPE_IDENTITY();
INSERT INTO security.[ROLE] (Name) VALUES (N'QA3 Unr Past');  DECLARE @RPast  INT = SCOPE_IDENTITY();
INSERT INTO security.[ROLE] (Name) VALUES (N'QA3 Unr HR');    DECLARE @RHr    INT = SCOPE_IDENTITY();
INSERT INTO security.[ROLE] (Name) VALUES (N'QA3 Unr Sees');  DECLARE @RSees  INT = SCOPE_IDENTITY();
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId) SELECT @RToday, PermissionId FROM security.PERMISSION WHERE Code = 'OFFROSTER_TODAY';
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId) SELECT @RPast,  PermissionId FROM security.PERMISSION WHERE Code = 'OFFROSTER_PAST';
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId) SELECT @RHr,    PermissionId FROM security.PERMISSION WHERE Code IN ('EMP_VIEW_ALL', 'OFFROSTER_TODAY', 'OFFROSTER_PAST');
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId) SELECT @RSees,  PermissionId FROM security.PERMISSION WHERE Code = 'EMP_VIEW_ALL';
IF (SELECT COUNT(*) FROM security.ROLE_PERMISSION WHERE RoleId = @RHr) <> 3
    BEGIN SET @fails += 1; RAISERROR('08: the two permissions OFFROSTER_TODAY / OFFROSTER_PAST are not in security.PERMISSION (is script 108 applied?).', 16, 1); END
INSERT INTO security.USER_ROLE (UserId, RoleId) VALUES (@UMgr1, @RToday), (@UHr, @RHr), (@USees, @RSees);

INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate)
VALUES (@UMgr1, @B1, @Dep, @Pos, N'QA3 Unr Manager One', '2020-01-01'), (@UMgr2, @B2, @Dep, @Pos, N'QA3 Unr Manager Two', '2020-01-01'),
       (NULL, @B1, @Dep, @Pos, N'QA3 Unr Past Worker', '2020-01-01'), (NULL, @B1, @Dep, @Pos, N'QA3 Unr Past Visitor', '2020-01-01'),
       (NULL, @B1, @Dep, @Pos, N'QA3 Unr Today Worker', '2020-01-01'), (NULL, @B1, @Dep, @Pos, N'QA3 Unr Today Roster Door', '2020-01-01'),
       (NULL, @B1, @Dep, @Pos, N'QA3 Unr Today Planned', '2020-01-01'), (NULL, @B1, @Dep, @Pos, N'QA3 Unr Today Open', '2020-01-01'),
       (NULL, @B1, @Dep, @Pos, N'QA3 Unr Past Middle', '2020-01-01'),
       (NULL, @B2, @Dep, @Pos, N'QA3 Unr Other Branch', '2020-01-01');
UPDATE hr.BRANCH SET ManagerEmployeeId = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Unr Manager One') WHERE BranchId = @B1;
UPDATE hr.BRANCH SET ManagerEmployeeId = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Unr Manager Two') WHERE BranchId = @B2;
DECLARE @EPast  INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Unr Past Worker');
DECLARE @EVisit INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Unr Past Visitor');
DECLARE @ETod   INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Unr Today Worker');
DECLARE @EDoor  INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Unr Today Roster Door');
DECLARE @EPlan  INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Unr Today Planned');
DECLARE @EOpen  INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Unr Today Open');
DECLARE @EOther INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Unr Other Branch');
DECLARE @EMid   INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Unr Past Middle');

INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
VALUES (N'QA3 Unr 08-16', '08:00', '16:00', NULL, 0, 30, 1);
DECLARE @S INT = SCOPE_IDENTITY();
INSERT INTO attendance.DEVICE (SerialNumber, BranchId, [Name]) VALUES (CONCAT('QA3-UNR-', @B1), @B1, N'QA3 unrostered device');
DECLARE @Dev INT = SCOPE_IDENTITY();
/* both months approved for branch one, last month for branch two: nobody of this scenario has a roster row */
INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status], ApprovedAt)
VALUES (@B1, @PM, 'Approved', DATEADD(DAY, -40, SYSUTCDATETIME())), (@B1, @CM, 'Approved', DATEADD(DAY, -10, SYSUTCDATETIME())),
       (@B2, @PM, 'Approved', DATEADD(DAY, -40, SYSUTCDATETIME()));

/* the punches: a worked past day (in 08:02, out 16:10), a visitor's single punch, the other branch's day, and today's */
INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
VALUES (@Dev, 'QA3', @EPast,  DATEADD(MINUTE, 482, CAST(@X AS DATETIME2)), 0, 'Device', CONVERT(VARCHAR(64), NEWID())),
       (@Dev, 'QA3', @EPast,  DATEADD(MINUTE, 970, CAST(@X AS DATETIME2)), 1, 'Device', CONVERT(VARCHAR(64), NEWID())),
       (@Dev, 'QA3', @EVisit, DATEADD(MINUTE, 485, CAST(@X AS DATETIME2)), 0, 'Device', CONVERT(VARCHAR(64), NEWID())),
       (@Dev, 'QA3', @EOther, DATEADD(MINUTE, 480, CAST(@X AS DATETIME2)), 0, 'Device', CONVERT(VARCHAR(64), NEWID())),
       (@Dev, 'QA3', @EOther, DATEADD(MINUTE, 960, CAST(@X AS DATETIME2)), 1, 'Device', CONVERT(VARCHAR(64), NEWID())),
       (@Dev, 'QA3', @ETod,   DATEADD(MINUTE, 485, CAST(@Today AS DATETIME2)), 0, 'Device', CONVERT(VARCHAR(64), NEWID())),
       (@Dev, 'QA3', @EDoor,  DATEADD(MINUTE, 490, CAST(@Today AS DATETIME2)), 0, 'Device', CONVERT(VARCHAR(64), NEWID())),
       (@Dev, 'QA3', @EOpen,  DATEADD(MINUTE, 495, CAST(@Today AS DATETIME2)), 0, 'Device', CONVERT(VARCHAR(64), NEWID()));
/* as the processor leaves them: read, with nothing to write (the approved roster has no row for these days) */
UPDATE attendance.RAW_DEVICE_LOG SET IsProcessed = 1 WHERE DeviceId = @Dev;

DECLARE @list TABLE (EmployeeId INT, EmployeeName NVARCHAR(200), BranchId INT, BranchName NVARCHAR(200), WorkDate DATE,
                     FirstPunch DATETIME2, LastPunch DATETIME2, PunchCount INT, WorkedMinutes INT, IsToday BIT, IsPaid BIT, OutsideEmployment BIT,
                     HolidayName NVARCHAR(200), HolidayNameAr NVARCHAR(200), OpenRosterRequestId INT, ApprovedOvertimeMinutes INT,
                     [State] VARCHAR(10), DismissNote NVARCHAR(400), DismissedBy NVARCHAR(200), DismissedAtUtc DATETIME2, PunchesChanged BIT, CanDecide BIT);
DECLARE @dec TABLE (EmployeeId INT, WorkDate DATE, Decision VARCHAR(10), ShiftAssignmentId INT, AttendanceId BIGINT);
DECLARE @re TABLE (EmployeeId INT, WorkDate DATE);
DECLARE @up TABLE (Id INT);

/* ---- 1. the list: every such day, scoped, with who may decide ---- */
INSERT INTO @list EXEC attendance.usp_UnrosteredDay_GetList @FromDate = @PM, @ToDate = @Today, @CallerUserId = NULL;
IF (SELECT COUNT(*) FROM @list WHERE EmployeeId IN (@EPast, @EVisit, @ETod, @EDoor, @EOpen, @EOther) AND [State] = 'Open' AND CanDecide = 1) <> 6
    BEGIN SET @fails += 1; RAISERROR('08: the system does not see the six days as open and decidable.', 16, 1); END
IF NOT EXISTS (SELECT 1 FROM @list WHERE EmployeeId = @EPast AND WorkDate = @X AND PunchCount = 2 AND WorkedMinutes = 488 AND IsToday = 0 AND BranchId = @B1)
    BEGIN SET @fails += 1; RAISERROR('08: the past day is not listed with its punches (2 punches, 488 minutes between them).', 16, 1); END
IF NOT EXISTS (SELECT 1 FROM @list WHERE EmployeeId = @ETod AND WorkDate = @Today AND IsToday = 1 AND PunchCount = 1)
    BEGIN SET @fails += 1; RAISERROR('08: today''s day is not listed as a day of today.', 16, 1); END

DELETE FROM @list;
INSERT INTO @list EXEC attendance.usp_UnrosteredDay_GetList @FromDate = @PM, @ToDate = @Today, @CallerUserId = @UMgr1;
IF EXISTS (SELECT 1 FROM @list WHERE EmployeeId = @EOther)
    BEGIN SET @fails += 1; RAISERROR('08: a branch manager sees another branch''s day.', 16, 1); END
IF (SELECT COUNT(*) FROM @list WHERE EmployeeId IN (@EPast, @EVisit, @ETod, @EDoor, @EOpen)) <> 5
    BEGIN SET @fails += 1; RAISERROR('08: a branch manager does not see the five days of the branch.', 16, 1); END
IF EXISTS (SELECT 1 FROM @list WHERE EmployeeId = @ETod AND CanDecide = 0) OR EXISTS (SELECT 1 FROM @list WHERE EmployeeId = @EPast AND CanDecide = 1)
    BEGIN SET @fails += 1; RAISERROR('08: with OFFROSTER_TODAY only, CanDecide must be 1 for today and 0 for a past day.', 16, 1); END

DELETE FROM @list;
INSERT INTO @list EXEC attendance.usp_UnrosteredDay_GetList @FromDate = @PM, @ToDate = @Today, @EmployeeId = @EVisit, @CallerUserId = @UHr;
IF (SELECT COUNT(*) FROM @list) <> 1 OR NOT EXISTS (SELECT 1 FROM @list WHERE EmployeeId = @EVisit AND CanDecide = 1)
    BEGIN SET @fails += 1; RAISERROR('08: the employee filter does not narrow the list to one decidable day for HR.', 16, 1); END

/* ---- 2. who may decide: the permission of the day's date, inside the caller's branches ---- */
SET @err = NULL;
BEGIN TRY INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EPast, @WorkDate = @X, @Decision = 'Shift', @ShiftId = @S, @CallerUserId = @UMgr1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
IF ISNULL(@err, N'') NOT LIKE N'You may not decide a past day%'
    BEGIN SET @fails += 1; SET @m = CONCAT('08: a manager with OFFROSTER_TODAY only deciding a past day: ', ISNULL(@err, 'allowed')); RAISERROR(@m, 16, 1); END

SET @err = NULL;
BEGIN TRY INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EOther, @WorkDate = @X, @Decision = 'Dismiss', @Note = N'not mine', @CallerUserId = @UMgr1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
IF ISNULL(@err, N'') <> N'You can only decide days of the branches you manage.'
    BEGIN SET @fails += 1; SET @m = CONCAT('08: a manager deciding another branch''s day: ', ISNULL(@err, 'allowed')); RAISERROR(@m, 16, 1); END

/* EMP_VIEW_ALL is no longer the key: seeing everything decides nothing, through either door */
SET @err = NULL;
BEGIN TRY INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EPast, @WorkDate = @X, @Decision = 'Shift', @ShiftId = @S, @CallerUserId = @USees; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
IF ISNULL(@err, N'') NOT LIKE N'You may not decide a past day%'
    BEGIN SET @fails += 1; SET @m = CONCAT('08: EMP_VIEW_ALL without OFFROSTER_PAST deciding a past day: ', ISNULL(@err, 'allowed')); RAISERROR(@m, 16, 1); END
SET @err = NULL;
BEGIN TRY INSERT INTO @up EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @EPast, @WorkDate = @X, @ShiftId = @S, @IsRestDay = 0, @CallerUserId = @USees; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
IF ISNULL(@err, N'') NOT LIKE N'This day is already in an approved roster and is in the past%needs the permission to decide past days that are not on the roster.'
    BEGIN SET @fails += 1; SET @m = CONCAT('08: EMP_VIEW_ALL without OFFROSTER_PAST adding the past day on the roster: ', ISNULL(@err, 'allowed')); RAISERROR(@m, 16, 1); END
IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @EPast AND WorkDate = @X)
    BEGIN SET @fails += 1; RAISERROR('08: a refused decision left a roster row behind.', 16, 1); END

/* ---- 3. not work: a reason, nothing written, and a later punch opens the day again ---- */
SET @err = NULL;
BEGIN TRY INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EVisit, @WorkDate = @X, @Decision = 'Dismiss', @Note = N'   ', @CallerUserId = @UHr; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
IF ISNULL(@err, N'') NOT LIKE N'Say why these punches were not work%'
    BEGIN SET @fails += 1; SET @m = CONCAT('08: a dismissal without a reason: ', ISNULL(@err, 'allowed')); RAISERROR(@m, 16, 1); END

DELETE FROM @dec;
INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EVisit, @WorkDate = @X, @Decision = 'Dismiss', @Note = N'  came in to collect a payslip ', @CallerUserId = @UHr;
IF NOT EXISTS (SELECT 1 FROM @dec WHERE EmployeeId = @EVisit AND Decision = 'Dismissed' AND ShiftAssignmentId IS NULL AND AttendanceId IS NULL)
    BEGIN SET @fails += 1; RAISERROR('08: a dismissal did not answer (Dismissed, no roster row, no attendance day).', 16, 1); END
IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @EVisit AND WorkDate = @X)
   OR EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @EVisit AND WorkDate = @X)
    BEGIN SET @fails += 1; RAISERROR('08: a dismissal wrote a roster row or an attendance day.', 16, 1); END
DELETE FROM @list;
INSERT INTO @list EXEC attendance.usp_UnrosteredDay_GetList @FromDate = @X, @ToDate = @X, @EmployeeId = @EVisit, @CallerUserId = @UHr;
IF NOT EXISTS (SELECT 1 FROM @list WHERE [State] = 'Dismissed' AND DismissNote = N'came in to collect a payslip' AND PunchesChanged = 0 AND DismissedAtUtc IS NOT NULL)
    BEGIN SET @fails += 1; RAISERROR('08: the dismissed day is not listed as Dismissed with its trimmed reason.', 16, 1); END

SET @err = NULL;
BEGIN TRY INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EVisit, @WorkDate = @X, @Decision = 'Dismiss', @Note = N'again', @CallerUserId = @UHr; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
IF ISNULL(@err, N'') NOT LIKE N'This day is no longer waiting for a decision%'
    BEGIN SET @fails += 1; SET @m = CONCAT('08: dismissing a dismissed day: ', ISNULL(@err, 'allowed')); RAISERROR(@m, 16, 1); END

/* a second punch arrives for the dismissed day: the dismissal answered ONE punch, so the day is open again */
INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash, IsProcessed)
VALUES (@Dev, 'QA3', @EVisit, DATEADD(MINUTE, 960, CAST(@X AS DATETIME2)), 1, 'Device', CONVERT(VARCHAR(64), NEWID()), 1);
DELETE FROM @list;
INSERT INTO @list EXEC attendance.usp_UnrosteredDay_GetList @FromDate = @X, @ToDate = @X, @EmployeeId = @EVisit, @CallerUserId = @UHr;
IF NOT EXISTS (SELECT 1 FROM @list WHERE [State] = 'Open' AND PunchesChanged = 1 AND PunchCount = 2 AND DismissNote = N'came in to collect a payslip')
    BEGIN SET @fails += 1; RAISERROR('08: a punch after the dismissal did not open the day again (Open, PunchesChanged, the old reason shown).', 16, 1); END

/* dismissed again on the new punches, then taken back by hand */
DELETE FROM @dec;
INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EVisit, @WorkDate = @X, @Decision = 'Dismiss', @Note = N'left again without working', @CallerUserId = @UHr;
SET @err = NULL;
BEGIN TRY INSERT INTO @re EXEC attendance.usp_UnrosteredDay_Reopen @EmployeeId = @EVisit, @WorkDate = @X, @CallerUserId = @UMgr1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
IF ISNULL(@err, N'') NOT LIKE N'You may not decide a past day%'
    BEGIN SET @fails += 1; SET @m = CONCAT('08: a manager without OFFROSTER_PAST taking a past dismissal back: ', ISNULL(@err, 'allowed')); RAISERROR(@m, 16, 1); END
INSERT INTO @re EXEC attendance.usp_UnrosteredDay_Reopen @EmployeeId = @EVisit, @WorkDate = @X, @CallerUserId = @UHr;
DELETE FROM @list;
INSERT INTO @list EXEC attendance.usp_UnrosteredDay_GetList @FromDate = @X, @ToDate = @X, @EmployeeId = @EVisit, @CallerUserId = @UHr;
IF NOT EXISTS (SELECT 1 FROM @list WHERE [State] = 'Open' AND PunchesChanged = 0 AND DismissNote IS NULL)
    BEGIN SET @fails += 1; RAISERROR('08: a dismissal taken back did not leave the day plainly open.', 16, 1); END
IF (SELECT COUNT(*) FROM attendance.UNROSTERED_DAY_DECISION WHERE EmployeeId = @EVisit AND WorkDate = @X) <> 2
   OR EXISTS (SELECT 1 FROM attendance.UNROSTERED_DAY_DECISION WHERE EmployeeId = @EVisit AND WorkDate = @X AND IsCurrent = 1)
   OR NOT EXISTS (SELECT 1 FROM attendance.UNROSTERED_DAY_DECISION WHERE EmployeeId = @EVisit AND WorkDate = @X AND ReopenedByUserId = @UHr AND ReopenedAtUtc IS NOT NULL)
    BEGIN SET @fails += 1; RAISERROR('08: the history of the two dismissals (both kept, none current, the second taken back by HR) is wrong.', 16, 1); END
SET @err = NULL;
BEGIN TRY INSERT INTO @re EXEC attendance.usp_UnrosteredDay_Reopen @EmployeeId = @EVisit, @WorkDate = @X, @CallerUserId = @UHr; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
IF ISNULL(@err, N'') NOT LIKE N'This day is no longer waiting for a decision%'
    BEGIN SET @fails += 1; SET @m = CONCAT('08: taking back a dismissal that is not there: ', ISNULL(@err, 'allowed')); RAISERROR(@m, 16, 1); END

/* a punch that arrives BETWEEN the two a dismissal answered moves neither the first nor the last: the count does,
   and the day is open again all the same (another day of last month, dismissed again at the end: it is never counted) */
INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash, IsProcessed)
VALUES (@Dev, 'QA3', @EMid, DATEADD(MINUTE, 480, CAST(@X2 AS DATETIME2)), 0, 'Device', CONVERT(VARCHAR(64), NEWID()), 1),
       (@Dev, 'QA3', @EMid, DATEADD(MINUTE, 960, CAST(@X2 AS DATETIME2)), 1, 'Device', CONVERT(VARCHAR(64), NEWID()), 1);
DELETE FROM @dec;
INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EMid, @WorkDate = @X2, @Decision = 'Dismiss', @Note = N'stock count, paid separately', @CallerUserId = @UHr;
INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash, IsProcessed)
VALUES (@Dev, 'QA3', @EMid, DATEADD(MINUTE, 720, CAST(@X2 AS DATETIME2)), 1, 'Device', CONVERT(VARCHAR(64), NEWID()), 1);
DELETE FROM @list;
INSERT INTO @list EXEC attendance.usp_UnrosteredDay_GetList @FromDate = @X2, @ToDate = @X2, @EmployeeId = @EMid, @CallerUserId = @UHr;
IF NOT EXISTS (SELECT 1 FROM @list WHERE [State] = 'Open' AND PunchesChanged = 1 AND PunchCount = 3 AND WorkedMinutes = 480)
    BEGIN SET @fails += 1; RAISERROR('08: a punch arriving between the first and the last did not open the dismissed day again.', 16, 1); END
DELETE FROM @dec;
INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EMid, @WorkDate = @X2, @Decision = 'Dismiss', @Note = N'stock count, three punches', @CallerUserId = @UHr;
IF NOT EXISTS (SELECT 1 FROM attendance.fn_UnrosteredDays(@X2, @X2) WHERE EmployeeId = @EMid AND IsDismissed = 1)
    BEGIN SET @fails += 1; RAISERROR('08: a day dismissed again on its new punches does not stand as dismissed.', 16, 1); END

/* ---- 4. a working day on a shift: the roster row, the decision on file, the day derived at once ---- */
SET @err = NULL;
BEGIN TRY INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EPast, @WorkDate = @X, @Decision = 'Shift', @CallerUserId = @UHr; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
IF ISNULL(@err, N'') NOT LIKE N'Choose the shift%'
    BEGIN SET @fails += 1; SET @m = CONCAT('08: a shift decision without its shift: ', ISNULL(@err, 'allowed')); RAISERROR(@m, 16, 1); END

DELETE FROM @dec;
INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EPast, @WorkDate = @X, @Decision = 'Shift', @ShiftId = @S, @Note = N'covered for a colleague', @CallerUserId = @UHr;
IF NOT EXISTS (SELECT 1 FROM @dec d
               JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.ShiftAssignmentId = d.ShiftAssignmentId AND sa.EmployeeId = @EPast AND sa.WorkDate = @X AND sa.ShiftId = @S AND sa.IsRestDay = 0
               JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = d.AttendanceId AND a.EmployeeId = @EPast AND a.WorkDate = @X AND a.ShiftAssignmentId = sa.ShiftAssignmentId
               WHERE d.Decision = 'Shift')
    BEGIN SET @fails += 1; RAISERROR('08: the shift decision did not add the roster row and derive the day on it.', 16, 1); END
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @EPast AND WorkDate = @X AND [Status] = 'Present' AND WorkedMinutes > 0)
    BEGIN SET @fails += 1; RAISERROR('08: the day derived from the punches is not a Present day with worked minutes.', 16, 1); END
IF NOT EXISTS (SELECT 1 FROM attendance.UNROSTERED_DAY_DECISION c
               JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.ShiftAssignmentId = c.ShiftAssignmentId
               WHERE c.EmployeeId = @EPast AND c.WorkDate = @X AND c.Decision = 'Shift' AND c.ShiftId = @S AND c.IsCurrent = 1
                 AND c.DecidedByUserId = @UHr AND c.Note = N'covered for a colleague' AND c.PunchCount = 2)
    BEGIN SET @fails += 1; RAISERROR('08: the shift decision is not on file with who, the note and the punches it answered.', 16, 1); END
DELETE FROM @list;
INSERT INTO @list EXEC attendance.usp_UnrosteredDay_GetList @FromDate = @X, @ToDate = @X, @EmployeeId = @EPast, @CallerUserId = @UHr;
IF EXISTS (SELECT 1 FROM @list)
    BEGIN SET @fails += 1; RAISERROR('08: a decided day is still on the list.', 16, 1); END
SET @err = NULL;
BEGIN TRY INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EPast, @WorkDate = @X, @Decision = 'RestDay', @CallerUserId = @UHr; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
IF ISNULL(@err, N'') NOT LIKE N'This day is no longer waiting for a decision%'
    BEGIN SET @fails += 1; SET @m = CONCAT('08: deciding a day that is already decided: ', ISNULL(@err, 'allowed')); RAISERROR(@m, 16, 1); END

/* ---- 5. today, by the branch manager: a rest day that was worked, derived at once ---- */
DELETE FROM @dec;
INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @ETod, @WorkDate = @Today, @Decision = 'RestDay', @ShiftId = @S, @CallerUserId = @UMgr1;
IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @ETod AND WorkDate = @Today AND IsRestDay = 1 AND ShiftId IS NULL)
    BEGIN SET @fails += 1; RAISERROR('08: a rest day worked was not stored as a rest day with no shift.', 16, 1); END
IF NOT EXISTS (SELECT 1 FROM @dec d JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = d.AttendanceId
               WHERE d.Decision = 'RestDay' AND a.EmployeeId = @ETod AND a.WorkDate = @Today AND a.[Status] = 'RestDay')
    BEGIN SET @fails += 1; RAISERROR('08: today''s day was not derived at once as a RestDay.', 16, 1); END
IF NOT EXISTS (SELECT 1 FROM attendance.UNROSTERED_DAY_DECISION WHERE EmployeeId = @ETod AND WorkDate = @Today AND Decision = 'RestDay' AND IsCurrent = 1 AND DecidedByUserId = @UMgr1)
    BEGIN SET @fails += 1; RAISERROR('08: the manager''s decision on today is not on file.', 16, 1); END

/* ---- 6. the Roster page is the same door ---- */
/* without OFFROSTER_TODAY: somebody who HAS punched today is refused; planning today for somebody who has not is not */
DELETE FROM security.USER_ROLE WHERE UserId = @UMgr1 AND RoleId = @RToday;
SET @err = NULL;
BEGIN TRY INSERT INTO @up EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @EDoor, @WorkDate = @Today, @ShiftId = @S, @IsRestDay = 0, @CallerUserId = @UMgr1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
IF ISNULL(@err, N'') NOT LIKE N'This day is already in an approved roster month and the employee has punched today%needs the permission to decide today''s days that are not on the roster.'
    BEGIN SET @fails += 1; SET @m = CONCAT('08: the roster door for today without OFFROSTER_TODAY, employee punched: ', ISNULL(@err, 'allowed')); RAISERROR(@m, 16, 1); END
DELETE FROM @up;
INSERT INTO @up EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @EPlan, @WorkDate = @Today, @ShiftId = @S, @IsRestDay = 0, @CallerUserId = @UMgr1;
IF (SELECT COUNT(*) FROM @up) <> 1 OR NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @EPlan AND WorkDate = @Today AND ShiftId = @S)
    BEGIN SET @fails += 1; RAISERROR('08: planning today for somebody who has not punched needs no new permission and must still answer one row.', 16, 1); END
IF EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @EPlan AND WorkDate = @Today)
   OR EXISTS (SELECT 1 FROM attendance.UNROSTERED_DAY_DECISION WHERE EmployeeId = @EPlan)
    BEGIN SET @fails += 1; RAISERROR('08: a planned day of today (no punch) was derived or filed as a decision.', 16, 1); END

/* with the permission back: adding the row on the roster files the decision and derives today's day */
INSERT INTO security.USER_ROLE (UserId, RoleId) VALUES (@UMgr1, @RToday);
DELETE FROM @up;
INSERT INTO @up EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @EDoor, @WorkDate = @Today, @ShiftId = @S, @IsRestDay = 0, @CallerUserId = @UMgr1;
IF (SELECT COUNT(*) FROM @up) <> 1
    BEGIN SET @fails += 1; RAISERROR('08: the one-cell writer no longer answers one row (ShiftAssignmentId).', 16, 1); END
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @EDoor AND WorkDate = @Today AND [Status] = 'Present')
    BEGIN SET @fails += 1; RAISERROR('08: today''s day added on the roster was not derived at once.', 16, 1); END
IF NOT EXISTS (SELECT 1 FROM attendance.UNROSTERED_DAY_DECISION WHERE EmployeeId = @EDoor AND WorkDate = @Today AND Decision = 'Shift' AND DecidedByUserId = @UMgr1 AND IsCurrent = 1 AND PunchCount = 1)
    BEGIN SET @fails += 1; RAISERROR('08: a day added on the roster did not file the decision.', 16, 1); END

/* ---- 7. the past-days permission given to a branch manager: own branch yes, another branch no ---- */
INSERT INTO security.USER_ROLE (UserId, RoleId) VALUES (@UMgr1, @RPast);
DELETE FROM @dec;
INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EVisit, @WorkDate = @X, @Decision = 'Shift', @ShiftId = @S, @CallerUserId = @UMgr1;
IF NOT EXISTS (SELECT 1 FROM @dec WHERE EmployeeId = @EVisit AND Decision = 'Shift' AND ShiftAssignmentId IS NOT NULL AND AttendanceId IS NOT NULL)
    BEGIN SET @fails += 1; RAISERROR('08: a manager holding OFFROSTER_PAST could not decide a past day of the own branch.', 16, 1); END
SET @err = NULL;
BEGIN TRY INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EOther, @WorkDate = @X, @Decision = 'Shift', @ShiftId = @S, @CallerUserId = @UMgr1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
IF ISNULL(@err, N'') <> N'You can only decide days of the branches you manage.'
    BEGIN SET @fails += 1; SET @m = CONCAT('08: OFFROSTER_PAST does not widen the branch scope, yet another branch''s day: ', ISNULL(@err, 'allowed')); RAISERROR(@m, 16, 1); END

/* ---- 8. payroll readiness: undecided completed days, blocking from the month of the setting ---- */
/* last month: of this scenario only the other branch's day is still undecided (the worker's and the visitor's joined
   the roster); the current month: today's open day is NOT counted until the day is over */
SELECT @n = UndecidedUnrosteredDays FROM attendance.fn_PayrollReadiness(@PMText, NULL);
IF @n <> @c0 + 1
    BEGIN SET @fails += 1; SET @m = CONCAT('08: readiness of last month counts ', @n - @c0, ' undecided day(s) of this scenario; 1 expected.'); RAISERROR(@m, 16, 1); END
SELECT @n = UndecidedUnrosteredDays FROM attendance.fn_PayrollReadiness(@CMText, NULL);
IF @n <> @c1
    BEGIN SET @fails += 1; SET @m = CONCAT('08: readiness of this month counts today''s open day (', @n - @c1, ' more than before); completed days only.'); RAISERROR(@m, 16, 1); END
DECLARE @Tomorrow DATE = DATEADD(DAY, 1, @Today);
IF MONTH(@Tomorrow) = MONTH(@Today)
BEGIN
    SELECT @n0 = UndecidedUnrosteredDays FROM attendance.fn_PayrollReadiness(@CMText, @Today);
    SELECT @n  = UndecidedUnrosteredDays FROM attendance.fn_PayrollReadiness(@CMText, @Tomorrow);
    IF @n <> @n0 + 1
        BEGIN SET @fails += 1; SET @m = CONCAT('08: once today is over its open day must count (', @n - @n0, ' more; 1 expected).'); RAISERROR(@m, 16, 1); END
END

/* a dismissal clears the count */
DELETE FROM @dec;
INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EOther, @WorkDate = @X, @Decision = 'Dismiss', @Note = N'training visit, not a shift', @CallerUserId = @UHr;
SELECT @n = UndecidedUnrosteredDays FROM attendance.fn_PayrollReadiness(@PMText, NULL);
IF @n <> @c0
    BEGIN SET @fails += 1; SET @m = CONCAT('08: a dismissed day is still counted by readiness (', @n - @c0, ' left).'); RAISERROR(@m, 16, 1); END
INSERT INTO @re EXEC attendance.usp_UnrosteredDay_Reopen @EmployeeId = @EOther, @WorkDate = @X, @CallerUserId = @UHr;

/* the setting: before its month the days are counted and block nothing; from its month on they make the period not ready */
IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'OffRosterBlocksPayrollFrom' AND DataType = 'month')
    BEGIN SET @fails += 1; RAISERROR('08: setting OffRosterBlocksPayrollFrom (DataType month) is missing.', 16, 1); END
UPDATE core.SETTING SET SettingValue = @CMText WHERE SettingKey = 'OffRosterBlocksPayrollFrom';
SELECT @n = UndecidedUnrosteredDays, @bit = UnrosteredDaysBlock FROM attendance.fn_PayrollReadiness(@PMText, NULL);
IF @n < 1 OR @bit <> 0
    BEGIN SET @fails += 1; RAISERROR('08: a period before the month of the setting must count the days and not block.', 16, 1); END
/* IsReady = the seven older counts are zero AND the days do not block. Read both ways round, so the verdict is seen
   to follow the setting and nothing else (a dev database may hold other open counts of its own: @others). */
DECLARE @others INT, @ready BIT;
SELECT @others = UnprocessedPunches + UnresolvedPinPunches + OpenAnomalies + PendingCorrections + RosteredDaysWithNoRecord
               + UndecidedExitVariances + UndecidedAnomalies, @ready = IsReady
FROM attendance.fn_PayrollReadiness(@PMText, NULL);
IF @ready <> CASE WHEN @others = 0 THEN 1 ELSE 0 END
    BEGIN SET @fails += 1; SET @m = CONCAT('08: before the month of the setting the undecided days must not change the verdict (IsReady ', @ready, ', other open counts ', @others, ').'); RAISERROR(@m, 16, 1); END
UPDATE core.SETTING SET SettingValue = @PMText WHERE SettingKey = 'OffRosterBlocksPayrollFrom';
SELECT @bit = UnrosteredDaysBlock FROM attendance.fn_PayrollReadiness(@PMText, NULL);
IF @bit <> 1 OR (SELECT IsReady FROM attendance.fn_PayrollReadiness(@PMText, NULL)) <> 0
    BEGIN SET @fails += 1; RAISERROR('08: from the month of the setting an undecided day must make the period NOT ready.', 16, 1); END
/* the scenario's own days leave no other count open, so on a database with nothing else open the setting alone flips the verdict */
IF @others > 0 PRINT CONCAT('note 08: this database has ', @others, ' other open readiness count(s) for ', @PMText, ': the flip of IsReady by the setting alone was not observed.');

/* the 11 columns of the old readiness procedure are a contract (INSERT ... EXEC callers); it carries the new verdict */
DECLARE @r11 TABLE (PeriodYearMonth CHAR(7), PeriodStart DATE, PeriodEnd DATE, UnprocessedPunches INT, UnresolvedPinPunches INT, OpenAnomalies INT,
                    PendingCorrections INT, RosteredDaysWithNoRecord INT, UndecidedExitVariances INT, UndecidedAnomalies INT, IsReady BIT);
INSERT INTO @r11 EXEC attendance.usp_Attendance_PayrollReadiness @PeriodYearMonth = @PMText;
IF (SELECT COUNT(*) FROM @r11 WHERE IsReady = 0) <> 1
    BEGIN SET @fails += 1; RAISERROR('08: attendance.usp_Attendance_PayrollReadiness must keep 11 columns and say NOT ready.', 16, 1); END
DECLARE @r15 TABLE (PeriodYearMonth CHAR(7), PeriodStart DATE, PeriodEnd DATE, UnprocessedPunches INT, UnresolvedPinPunches INT, OpenAnomalies INT,
                    PendingCorrections INT, RosteredDaysWithNoRecord INT, UndecidedExitVariances INT, UndecidedAnomalies INT, IsReady BIT,
                    CountedUpTo DATE, UndecidedUnrosteredDays INT, UnrosteredDaysBlock BIT, UnrosteredBlocksFrom CHAR(7));
INSERT INTO @r15 EXEC attendance.usp_PayrollReadiness_Get @PeriodYearMonth = @PMText;
IF NOT EXISTS (SELECT 1 FROM @r15 WHERE UndecidedUnrosteredDays >= 1 AND UnrosteredDaysBlock = 1 AND UnrosteredBlocksFrom = @PMText AND IsReady = 0 AND CountedUpTo = @PMEnd)
    BEGIN SET @fails += 1; RAISERROR('08: attendance.usp_PayrollReadiness_Get does not answer the count, the block and its month.', 16, 1); END

/* the gate of Create / Generate / Approve names the reason (after the anomaly sentence, which stays first) */
IF (SELECT UndecidedAnomalies FROM attendance.fn_PayrollReadiness(@PMText, NULL)) = 0
BEGIN
    SET @err = NULL;
    BEGIN TRY EXEC payroll.usp_PayrollRun_AssertReady @PeriodYearMonth = @PMText; END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    IF ISNULL(@err, N'') NOT LIKE N'Attendance for ' + @PMText + N' has % with punches that the approved roster does not know and nobody has decided, up to %Decide them in Attendance > Daily attendance before running payroll.'
        BEGIN SET @fails += 1; SET @m = CONCAT('08: the payroll gate on undecided days: ', ISNULL(@err, 'allowed')); RAISERROR(@m, 16, 1); END
END

/* empty, a month that is not one, and a later month: never blocking, still counted */
UPDATE core.SETTING SET SettingValue = N'' WHERE SettingKey = 'OffRosterBlocksPayrollFrom';
IF (SELECT UnrosteredDaysBlock FROM attendance.fn_PayrollReadiness(@PMText, NULL)) <> 0
    BEGIN SET @fails += 1; RAISERROR('08: an empty setting must never block.', 16, 1); END
UPDATE core.SETTING SET SettingValue = N'12/2026' WHERE SettingKey = 'OffRosterBlocksPayrollFrom';
IF (SELECT UnrosteredDaysBlock FROM attendance.fn_PayrollReadiness(@PMText, NULL)) <> 0
   OR EXISTS (SELECT 1 FROM attendance.fn_PayrollReadiness(@PMText, NULL) WHERE UndecidedUnrosteredDays < 1)
    BEGIN SET @fails += 1; RAISERROR('08: an unreadable setting must not block, and the days are still counted.', 16, 1); END
DELETE FROM @r15;
INSERT INTO @r15 EXEC attendance.usp_PayrollReadiness_Get @PeriodYearMonth = @PMText;
IF EXISTS (SELECT 1 FROM @r15 WHERE UnrosteredBlocksFrom IS NOT NULL)
    BEGIN SET @fails += 1; RAISERROR('08: an unreadable setting must answer "never" (NULL) as the month the block starts in.', 16, 1); END

/* ---- 9. the old list of script 87 is untouched: 9 columns ---- */
DECLARE @wr TABLE (EmployeeId INT, EmployeeName NVARCHAR(200), BranchId INT, BranchName NVARCHAR(200), WorkDate DATE, FirstPunch DATETIME2, LastPunch DATETIME2, PunchCount INT, WorkedMinutes INT);
INSERT INTO @wr EXEC attendance.usp_Attendance_GetWorkedWithoutRoster @FromDate = @X, @ToDate = @X, @BranchId = @B2;
IF (SELECT COUNT(*) FROM @wr WHERE EmployeeId = @EOther) <> 1
    BEGIN SET @fails += 1; RAISERROR('08: attendance.usp_Attendance_GetWorkedWithoutRoster no longer lists an open day in its 9 columns.', 16, 1); END

/* ---- 10. a period already paid for the employee is read-only: listed, not decidable, not counted ---- */
DECLARE @Run INT = (SELECT TOP 1 PayrollRunId FROM payroll.PAYROLL_RUN WHERE PeriodYearMonth = @PMText AND RunType = 'Primary' AND [Status] <> 'Cancelled');
IF @Run IS NULL
BEGIN
    INSERT INTO payroll.PAYROLL_RUN (PeriodYearMonth, PeriodStart, PeriodEnd, PrimaryCurrency, Notes, CreatedByUserId, RunType, [Status])
    VALUES (@PMText, @PM, @PMEnd, 'USD', N'QA3 unrostered paid month', @UHr, 'Primary', 'Approved');
    SET @Run = SCOPE_IDENTITY();
END
ELSE UPDATE payroll.PAYROLL_RUN SET [Status] = 'Approved' WHERE PayrollRunId = @Run;
SELECT @n0 = UndecidedUnrosteredDays FROM attendance.fn_PayrollReadiness(@PMText, NULL);        -- the other branch's day is still open and unpaid
INSERT INTO payroll.PAYSLIP (PayrollRunId, EmployeeId, EmployeeName) VALUES (@Run, @EOther, N'QA3 Unr Other Branch');
SELECT @n = UndecidedUnrosteredDays FROM attendance.fn_PayrollReadiness(@PMText, NULL);
IF @n <> @n0 - 1
    BEGIN SET @fails += 1; SET @m = CONCAT('08: a day of a period paid for the employee is still counted by readiness (', @n0, ' before the payslip, ', @n, ' after).'); RAISERROR(@m, 16, 1); END
DELETE FROM @list;
INSERT INTO @list EXEC attendance.usp_UnrosteredDay_GetList @FromDate = @X, @ToDate = @X, @EmployeeId = @EOther, @CallerUserId = @UHr;
IF NOT EXISTS (SELECT 1 FROM @list WHERE [State] = 'Open' AND IsPaid = 1 AND CanDecide = 0)
    BEGIN SET @fails += 1; RAISERROR('08: a day of a paid period must be listed as paid and not decidable, even for HR.', 16, 1); END
SET @err = NULL;
BEGIN TRY INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EOther, @WorkDate = @X, @Decision = 'Dismiss', @Note = N'after payday', @CallerUserId = @UHr; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
IF ISNULL(@err, N'') NOT LIKE N'This period is paid%raise a payroll adjustment instead.'
    BEGIN SET @fails += 1; SET @m = CONCAT('08: deciding a day of a paid period: ', ISNULL(@err, 'allowed')); RAISERROR(@m, 16, 1); END
SET @err = NULL;
BEGIN TRY INSERT INTO @dec EXEC attendance.usp_UnrosteredDay_Decide @EmployeeId = @EOther, @WorkDate = @X, @Decision = 'Shift', @ShiftId = @S, @CallerUserId = @UHr; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
IF ISNULL(@err, N'') NOT LIKE N'This period is paid%raise a payroll adjustment instead.'
   OR EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @EOther AND WorkDate = @X)
    BEGIN SET @fails += 1; SET @m = CONCAT('08: adding a day of a paid period: ', ISNULL(@err, 'allowed')); RAISERROR(@m, 16, 1); END

IF @@TRANCOUNT > 0 ROLLBACK TRAN;
IF @fails = 0 PRINT 'ok 08_unrostered_days';
