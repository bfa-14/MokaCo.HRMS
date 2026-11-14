/* Script 110: "something is wrong with this day". The employee reports their own day, their branch manager the days
   of the branches they manage; nobody else. HR accepts (the API raises and approves a correction with the reported
   times, then marks the report - the same three calls this scenario makes, in one transaction) or rejects with a
   note; the reporter may withdraw while it is open. One open report per employee-day. Nobody decides a report
   about their own day.
   Runs on a dev database with docs/110_day_reports.sql applied, inside a transaction that is rolled back.
   sqlcmd -I -b -i tests/qa3/attendance/10_day_reports.sql   ->  prints 'ok 10_day_reports' */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
BEGIN TRAN;
DECLARE @fails INT = 0, @err NVARCHAR(2000), @id INT, @id2 INT, @cid INT, @n INT;
DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
DECLARE @Y DATE = DATEADD(DAY, -1, @Today), @Y2 DATE = DATEADD(DAY, -2, @Today);
DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);
DECLARE @ids TABLE (Id INT);
DECLARE @list TABLE (ReportId INT, EmployeeId INT, EmployeeName NVARCHAR(200), BranchId INT, BranchName NVARCHAR(200), WorkDate DATE,
                     ClaimedIn DATETIME2, ClaimedOut DATETIME2, [Message] NVARCHAR(400), ReportedByUserId INT, ReportedBy NVARCHAR(200),
                     ReportedAtUtc DATETIME2, [Status] VARCHAR(12), DecidedBy NVARCHAR(200), DecidedAtUtc DATETIME2, DecisionNote NVARCHAR(400),
                     CorrectionId INT, AttendanceId BIGINT, CurrentFirstIn DATETIME2, CurrentLastOut DATETIME2, CurrentStatus VARCHAR(20),
                     CurrentWorkedMinutes INT, CurrentHasAnomaly BIT, IsAboutMe BIT, CanDecide BIT);
DECLARE @dec TABLE (ReportId INT, [Status] VARCHAR(12), CorrectionId INT);
DECLARE @wd TABLE (ReportId INT, [Status] VARCHAR(12));

/* two branches; a manager for each; HR (sees everything); two workers of branch one, one of branch two */
INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Report One', 1); DECLARE @B1 INT = SCOPE_IDENTITY();
INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Report Two', 1); DECLARE @B2 INT = SCOPE_IDENTITY();
INSERT INTO security.[USER] (Username, PasswordHash, IsActive)
VALUES (N'qa3.rep.mgr1', N'x', 1), (N'qa3.rep.mgr2', N'x', 1), (N'qa3.rep.hr', N'x', 1), (N'qa3.rep.w1', N'x', 1), (N'qa3.rep.w2', N'x', 1);
DECLARE @UMgr1 INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.rep.mgr1');
DECLARE @UMgr2 INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.rep.mgr2');
DECLARE @UHr   INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.rep.hr');
DECLARE @UW1   INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.rep.w1');
DECLARE @UW2   INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.rep.w2');
INSERT INTO security.[ROLE] (Name) VALUES (N'QA3 Rep HR'); DECLARE @RHr INT = SCOPE_IDENTITY();
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId) SELECT @RHr, PermissionId FROM security.PERMISSION WHERE Code IN ('EMP_VIEW_ALL', 'ATTENDANCE_CORRECT');
INSERT INTO security.USER_ROLE (UserId, RoleId) VALUES (@UHr, @RHr);
INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate)
VALUES (@UMgr1, @B1, @Dep, @Pos, N'QA3 Rep Manager One', '2020-01-01'), (@UMgr2, @B2, @Dep, @Pos, N'QA3 Rep Manager Two', '2020-01-01'),
       (@UHr, @B1, @Dep, @Pos, N'QA3 Rep HR', '2020-01-01'),
       (@UW1, @B1, @Dep, @Pos, N'QA3 Rep Worker One', '2020-01-01'), (@UW2, @B1, @Dep, @Pos, N'QA3 Rep Worker Two', '2020-01-01'),
       (NULL, @B2, @Dep, @Pos, N'QA3 Rep Other Branch', '2020-01-01');
DECLARE @EMgr1 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Rep Manager One');
DECLARE @EHr   INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Rep HR');
DECLARE @EW1   INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Rep Worker One');
DECLARE @EW2   INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Rep Worker Two');
DECLARE @EO    INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Rep Other Branch');
UPDATE hr.BRANCH SET ManagerEmployeeId = @EMgr1 WHERE BranchId = @B1;
UPDATE hr.BRANCH SET ManagerEmployeeId = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Rep Manager Two') WHERE BranchId = @B2;
INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom)
SELECT e.EmployeeId, e.BranchId, e.HireDate FROM hr.EMPLOYEE e WHERE e.BranchId IN (@B1, @B2)
  AND NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY h WHERE h.EmployeeId = e.EmployeeId);

/* worker one yesterday: in at 08:03, never out (a manual day, as a missing punch would leave it) */
INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, FirstInUtc, [Status], DayFraction, StandardMinutes, WorkedMinutes, [Source], HasAnomaly, BranchId)
VALUES (@EW1, @Y, DATEADD(MINUTE, 483, CAST(@Y AS DATETIME2)), 'Present', 0, 480, 0, 'Device', 1, @B1);
DECLARE @Att BIGINT = (SELECT AttendanceId FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @EW1 AND WorkDate = @Y);

/* 1. the worker reports their own day */
BEGIN TRY
    DELETE FROM @ids;
    INSERT INTO @ids EXEC attendance.usp_DayReport_Create @EmployeeId = @EW1, @WorkDate = @Y, @ClaimedOut = NULL, @Message = N'x', @CallerUserId = @UW1;
END TRY BEGIN CATCH SET @fails += 1; SET @err = ERROR_MESSAGE(); RAISERROR('10: the worker could not report their own day: %s', 16, 1, @err); END CATCH
DELETE FROM attendance.DAY_REPORT WHERE EmployeeId = @EW1;   -- start again with the real report below

DECLARE @Out DATETIME2 = DATEADD(MINUTE, 1380, CAST(@Y AS DATETIME2));   -- 23:00
DELETE FROM @ids;
INSERT INTO @ids EXEC attendance.usp_DayReport_Create @EmployeeId = @EW1, @WorkDate = @Y, @ClaimedOut = @Out,
    @Message = N'I forgot to punch out. I left at 23:00 after closing.', @CallerUserId = @UW1;
SET @id = (SELECT Id FROM @ids);

/* 2. refusals: someone else's day, another branch, no message, the future, a time on another day, out before in,
      a second open report for the same day */
DECLARE @cases TABLE (Label NVARCHAR(60), Expect NVARCHAR(100), Emp INT, Day DATE, InT DATETIME2, OutT DATETIME2, Msg NVARCHAR(400), Caller INT);
INSERT INTO @cases VALUES
 (N'colleague', N'You can only report your own days', @EW1, @Y2, NULL, NULL, N'x', @UW2),
 (N'other branch manager', N'You can only report your own days', @EW1, @Y2, NULL, NULL, N'x', @UMgr2),
 (N'no message', N'Say what is wrong', @EW1, @Y2, NULL, NULL, N'  ', @UW1),
 (N'future', N'has not happened yet', @EW1, DATEADD(DAY, 1, @Today), NULL, NULL, N'x', @UW1),
 (N'time on another day', N'The times must be on', @EW1, @Y2, DATEADD(HOUR, 8, CAST(@Y AS DATETIME2)), NULL, N'x', @UW1),
 (N'out before in', N'must be after', @EW1, @Y2, DATEADD(HOUR, 16, CAST(@Y2 AS DATETIME2)), DATEADD(HOUR, 8, CAST(@Y2 AS DATETIME2)), N'x', @UW1),
 (N'second open report', N'already waiting for HR', @EW1, @Y, NULL, NULL, N'x', @UMgr1);
DECLARE @Label NVARCHAR(60), @Expect NVARCHAR(100), @cE INT, @cD DATE, @cI DATETIME2, @cO DATETIME2, @cM NVARCHAR(400), @cC INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT * FROM @cases;
OPEN c; FETCH NEXT FROM c INTO @Label, @Expect, @cE, @cD, @cI, @cO, @cM, @cC;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @err = NULL;
    BEGIN TRY
        DELETE FROM @ids;
        INSERT INTO @ids EXEC attendance.usp_DayReport_Create @EmployeeId = @cE, @WorkDate = @cD, @ClaimedIn = @cI, @ClaimedOut = @cO, @Message = @cM, @CallerUserId = @cC;
    END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    IF @err IS NULL OR CHARINDEX(@Expect, @err) = 0
        BEGIN SET @fails += 1; SET @err = CONCAT(@Label, N': ', ISNULL(@err, N'accepted')); RAISERROR('10: %s', 16, 1, @err); END
    FETCH NEXT FROM c INTO @Label, @Expect, @cE, @cD, @cI, @cO, @cM, @cC;
END
CLOSE c; DEALLOCATE c;

/* the branch manager may report a day of their branch */
DELETE FROM @ids;
INSERT INTO @ids EXEC attendance.usp_DayReport_Create @EmployeeId = @EW2, @WorkDate = @Y2, @Message = N'She worked the closing shift, the machine was off.', @CallerUserId = @UMgr1;
SET @id2 = (SELECT Id FROM @ids);
IF @id2 IS NULL BEGIN SET @fails += 1; RAISERROR('10: the branch manager could not report a day of their branch.', 16, 1); END

/* 3. the lists: the worker sees their report (Mine), HR sees both in the queue and may decide them; the worker's queue is empty */
INSERT INTO @list EXEC attendance.usp_DayReport_GetList @Scope = 'Mine', @CallerUserId = @UW1;
IF (SELECT COUNT(*) FROM @list) <> 1 OR (SELECT IsAboutMe FROM @list) <> 1 OR (SELECT CanDecide FROM @list) <> 0
    BEGIN SET @fails += 1; RAISERROR('10: the worker''s own list is wrong.', 16, 1); END
DELETE FROM @list;
INSERT INTO @list EXEC attendance.usp_DayReport_GetList @Scope = 'Queue', @Status = 'Open', @CallerUserId = @UHr;
IF (SELECT COUNT(*) FROM @list WHERE ReportId IN (@id, @id2) AND CanDecide = 1) <> 2
   OR (SELECT CurrentFirstIn FROM @list WHERE ReportId = @id) IS NULL
    BEGIN SET @fails += 1; RAISERROR('10: HR''s queue does not hold both reports, decidable, with the day as it stands.', 16, 1); END
DELETE FROM @list;
INSERT INTO @list EXEC attendance.usp_DayReport_GetList @Scope = 'Queue', @CallerUserId = @UW1;
IF EXISTS (SELECT 1 FROM @list) BEGIN SET @fails += 1; RAISERROR('10: a worker has a queue to decide.', 16, 1); END
/* manager two sees nothing of branch one */
DELETE FROM @list;
INSERT INTO @list EXEC attendance.usp_DayReport_GetList @Scope = 'Queue', @CallerUserId = @UMgr2;
IF EXISTS (SELECT 1 FROM @list WHERE ReportId IN (@id, @id2)) BEGIN SET @fails += 1; RAISERROR('10: another branch''s manager sees branch one''s reports.', 16, 1); END

/* 4. deciding: nobody decides their own day; reject needs a note; accept needs the approved correction */
SET @err = NULL;
BEGIN TRY INSERT INTO @dec EXEC attendance.usp_DayReport_Decide @ReportId = @id, @Accept = 0, @Note = N'no', @CallerUserId = @UW1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
IF CHARINDEX(N'Somebody else decides', ISNULL(@err, N'')) = 0 BEGIN SET @fails += 1; RAISERROR('10: a worker decided a report about their own day.', 16, 1); END
SET @err = NULL;
BEGIN TRY INSERT INTO @dec EXEC attendance.usp_DayReport_Decide @ReportId = @id, @Accept = 0, @Note = N'  ', @CallerUserId = @UHr; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
IF CHARINDEX(N'Say why the report is rejected', ISNULL(@err, N'')) = 0 BEGIN SET @fails += 1; RAISERROR('10: a rejection without a note was taken.', 16, 1); END
SET @err = NULL;
BEGIN TRY INSERT INTO @dec EXEC attendance.usp_DayReport_Decide @ReportId = @id, @Accept = 1, @CorrectionId = NULL, @CallerUserId = @UHr; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
IF CHARINDEX(N'needs the approved correction', ISNULL(@err, N'')) = 0 BEGIN SET @fails += 1; RAISERROR('10: an accept without its correction was taken.', 16, 1); END

/* accept, as the API does it: correction requested by the reporter with the reported out, approved by HR, report marked */
DELETE FROM @ids;
INSERT INTO @ids EXEC attendance.usp_Correction_Create @AttendanceId = @Att, @RequestedBy = @UW1, @NewLastOutUtc = @Out,
    @Reason = N'Day report: I forgot to punch out. I left at 23:00 after closing.';
SET @cid = (SELECT Id FROM @ids);
EXEC attendance.usp_Correction_Approve @CorrectionId = @cid, @ApprovedBy = @UHr;
DELETE FROM @dec;
INSERT INTO @dec EXEC attendance.usp_DayReport_Decide @ReportId = @id, @Accept = 1, @CorrectionId = @cid, @CallerUserId = @UHr;
IF (SELECT [Status] FROM attendance.DAY_REPORT WHERE ReportId = @id) <> 'Accepted'
   OR (SELECT CorrectionId FROM attendance.DAY_REPORT WHERE ReportId = @id) <> @cid
   OR (SELECT LastOutUtc FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @Att) <> @Out
   OR (SELECT WorkedMinutes FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @Att) <= 0
    BEGIN SET @fails += 1; RAISERROR('10: accepting did not mark the report or write the day.', 16, 1); END
/* decided once */
SET @err = NULL;
BEGIN TRY INSERT INTO @dec EXEC attendance.usp_DayReport_Decide @ReportId = @id, @Accept = 0, @Note = N'late', @CallerUserId = @UHr; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
IF CHARINDEX(N'no longer open', ISNULL(@err, N'')) = 0 BEGIN SET @fails += 1; RAISERROR('10: a decided report was decided again.', 16, 1); END

/* 5. withdraw: only the reporter, only while open; then a new report for the day is possible */
SET @err = NULL;
BEGIN TRY INSERT INTO @wd EXEC attendance.usp_DayReport_Withdraw @ReportId = @id2, @CallerUserId = @UW2; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
IF CHARINDEX(N'only withdraw a report you sent', ISNULL(@err, N'')) = 0 BEGIN SET @fails += 1; RAISERROR('10: somebody other than the reporter withdrew a report.', 16, 1); END
DELETE FROM @wd;
INSERT INTO @wd EXEC attendance.usp_DayReport_Withdraw @ReportId = @id2, @CallerUserId = @UMgr1;
IF (SELECT [Status] FROM attendance.DAY_REPORT WHERE ReportId = @id2) <> 'Withdrawn' BEGIN SET @fails += 1; RAISERROR('10: the reporter could not withdraw.', 16, 1); END
DELETE FROM @ids;
INSERT INTO @ids EXEC attendance.usp_DayReport_Create @EmployeeId = @EW2, @WorkDate = @Y2, @Message = N'Second try.', @CallerUserId = @UW2;
SET @id2 = (SELECT Id FROM @ids);

/* 6. reject with a note: the reporter reads it */
DELETE FROM @dec;
INSERT INTO @dec EXEC attendance.usp_DayReport_Decide @ReportId = @id2, @Accept = 0, @Note = N'The camera shows you left at 16:00.', @CallerUserId = @UMgr1;
DELETE FROM @list;
INSERT INTO @list EXEC attendance.usp_DayReport_GetList @Scope = 'Mine', @CallerUserId = @UW2;
IF NOT EXISTS (SELECT 1 FROM @list WHERE ReportId = @id2 AND [Status] = 'Rejected' AND DecisionNote LIKE N'The camera%')
    BEGIN SET @fails += 1; RAISERROR('10: the reporter does not see the rejection and its note.', 16, 1); END

ROLLBACK TRAN;
IF @fails = 0 PRINT 'ok 10_day_reports';
