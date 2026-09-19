/* ============================================================================
   cases/03_leaves.sql — A3: leaves, on QA2 E11 (QA2 Branch 2, QA2 Morning 07:00-15:00, Mon-Fri; Saturday and
   Sunday are rest days) and QA2 E10 (hired last year: carry-over). Annual entitlement 15 days a year.

   Settings as delivered: LeaveCountsRestDays 0 (working days only), LeaveAllowNegativeBalance 0.
   A3i (payout on termination) and A3j (exit-permission conversion at period close) need a payroll run / the
   period close and are in cases/05_payroll.sql, inside its rolled-back transaction.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO

/* ---------------------------------------------------------------- A3a, A3b, A3c: what a leave costs ---- */
DECLARE @E11 INT = dbo.QA2_Emp(N'E11'), @Hr INT = dbo.QA2_User(N'hr'), @B2 INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA2 Branch 2');
DECLARE @M DATE = CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month') + '-01' AS DATE);
DECLARE @exp NVARCHAR(700), @act NVARCHAR(700), @ok BIT, @rid INT, @f DATE, @t DATE, @n INT, @bal0 DECIMAL(6,2), @bal1 DECIMAL(6,2);
DECLARE @yr INT = YEAR(@M);

/* A3a: Wednesday -> next Tuesday: 7 calendar days over a Saturday and a Sunday = 5 working days */
SET @f = dbo.QA2_Date('A3a'); SET @t = DATEADD(DAY, 6, @f);
SET @bal0 = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E11 AND LeaveTypeId = 1);
EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E11, @RaisedByUserId = @Hr, @LeaveTypeId = 1, @FromDate = @f, @ToDate = @t, @Reason = N'QA2 A3a';
SET @rid = dbo.QA2_LastRequest(@E11); EXEC dbo.QA2_Approve @rid, 'Leave';
EXEC dbo.QA2_ComputeRange @E11, @f, @t;
SET @bal1 = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E11 AND LeaveTypeId = 1);
SELECT @n = COUNT(*) FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E11 AND WorkDate BETWEEN @f AND @t AND [Status] = 'Leave';
SELECT @act = CONCAT('request ', ri.[Status], ', DaysRequested=', lr.DaysRequested, ', title="', ri.Title, '"; balance ', @bal0, ' -> ', @bal1,
                     '; ledger usage=', (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = lr.LeaveRequestId AND MovementType = 'Usage'),
                     '; attendance days marked Leave=', @n, ' of 7'),
       @ok = CASE WHEN ri.[Status] = 'Approved' AND lr.DaysRequested = 5 AND @bal0 - @bal1 = 5 AND @n = 7 AND ri.Title LIKE N'%5 working day%' THEN 1 ELSE 0 END
FROM workflow.LEAVE_REQUEST lr JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId WHERE lr.RequestInstanceId = @rid;
EXEC dbo.QA2_Check 'A3a', 'annual leave Wednesday -> next Tuesday over two rest days (LeaveCountsRestDays = 0)',
     'the balance is used for the 5 WORKING days only: DaysRequested 5, the request says "5 working days", ledger -5; attendance marks every one of the 7 calendar days Leave', @act, @ok;

/* A3c: Wednesday -> Friday containing a public holiday of the branch on the Thursday */
SET @f = dbo.QA2_Date('A3c'); SET @t = DATEADD(DAY, 2, @f);
DECLARE @hol DATE = DATEADD(DAY, 1, @f);
IF OBJECT_ID('core.usp_Holiday_Upsert') IS NOT NULL
BEGIN TRY
    EXEC core.usp_Holiday_Upsert @HolidayId = NULL, @HolidayDate = @hol, @Name = N'QA2 Branch 2 Holiday', @NameAr = NULL, @IsPaid = 1, @BranchId = @B2, @ActedByUserId = @Hr;
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @act = CONCAT('holiday: ', ERROR_MESSAGE()); EXEC dbo.QA2_Note @act; END CATCH;
SET @bal0 = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E11 AND LeaveTypeId = 1);
EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E11, @RaisedByUserId = @Hr, @LeaveTypeId = 1, @FromDate = @f, @ToDate = @t, @Reason = N'QA2 A3c';
SET @rid = dbo.QA2_LastRequest(@E11); EXEC dbo.QA2_Approve @rid, 'Leave';
EXEC dbo.QA2_ComputeRange @E11, @f, @t;
SET @bal1 = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E11 AND LeaveTypeId = 1);
SELECT @act = CONCAT('DaysRequested=', lr.DaysRequested, '; balance ', @bal0, ' -> ', @bal1, '; statuses ',
                     (SELECT STRING_AGG(CONCAT(CONVERT(CHAR(5), a.WorkDate, 110), ' ', a.[Status]), ', ') WITHIN GROUP (ORDER BY a.WorkDate) FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E11 AND a.WorkDate BETWEEN @f AND @t)),
       @ok = CASE WHEN lr.DaysRequested = 2 AND @bal0 - @bal1 = 2 THEN 1 ELSE 0 END
FROM workflow.LEAVE_REQUEST lr WHERE lr.RequestInstanceId = @rid;
EXEC dbo.QA2_Check 'A3c', 'annual leave Wednesday -> Friday containing a public holiday of the branch (Thursday)', 'the holiday is not deducted: 2 days used, not 3', @act, @ok;

/* A3b: a leave spanning the month end: the last working day of M and the first two of M+1 */
DECLARE @last DATE = (SELECT MAX(WorkDate) FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E11 AND IsRestDay = 0 AND WorkDate <= EOMONTH(@M));
DECLARE @second DATE = (SELECT MAX(x.WorkDate) FROM (SELECT TOP 2 WorkDate FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E11 AND IsRestDay = 0 AND WorkDate > EOMONTH(@M) ORDER BY WorkDate) x);
SET @f = @last; SET @t = @second;
EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E11, @RaisedByUserId = @Hr, @LeaveTypeId = 1, @FromDate = @f, @ToDate = @t, @Reason = N'QA2 A3b';
SET @rid = dbo.QA2_LastRequest(@E11); EXEC dbo.QA2_Approve @rid, 'Leave';
EXEC dbo.QA2_ComputeRange @E11, @f, @t;
DECLARE @MNext CHAR(7) = CONVERT(CHAR(7), DATEADD(MONTH, 1, @M), 23), @MThis CHAR(7) = CONVERT(CHAR(7), @M, 23);
SELECT @act = CONCAT('leave ', CONVERT(CHAR(10), @f, 23), ' -> ', CONVERT(CHAR(10), @t, 23), ', DaysRequested=', lr.DaysRequested,
                     '; ledger usage by month: ', (SELECT STRING_AGG(CONCAT(l.PeriodYearMonth, ' ', l.Days), ', ') WITHIN GROUP (ORDER BY l.PeriodYearMonth) FROM hr.LEAVE_LEDGER l WHERE l.LeaveRequestId = lr.LeaveRequestId AND l.MovementType = 'Usage'),
                     '; Leave days in attendance: ', (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E11 AND a.[Status] = 'Leave' AND a.WorkDate BETWEEN @f AND EOMONTH(@M)), ' in M, ',
                     (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E11 AND a.[Status] = 'Leave' AND a.WorkDate > EOMONTH(@M) AND a.WorkDate <= @t), ' in M+1'),
       @ok = CASE WHEN lr.DaysRequested = 3
                   AND (SELECT -SUM(l.Days) FROM hr.LEAVE_LEDGER l WHERE l.LeaveRequestId = lr.LeaveRequestId AND l.MovementType = 'Usage' AND l.PeriodYearMonth = @MThis) = 1
                   AND (SELECT -SUM(l.Days) FROM hr.LEAVE_LEDGER l WHERE l.LeaveRequestId = lr.LeaveRequestId AND l.MovementType = 'Usage' AND l.PeriodYearMonth = @MNext) = 2
                   AND (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E11 AND a.[Status] = 'Leave' AND a.WorkDate BETWEEN @f AND EOMONTH(@M)) >= 1
                   AND (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E11 AND a.[Status] = 'Leave' AND a.WorkDate > EOMONTH(@M) AND a.WorkDate <= @t) >= 2 THEN 1 ELSE 0 END
FROM workflow.LEAVE_REQUEST lr WHERE lr.RequestInstanceId = @rid;
EXEC dbo.QA2_Check 'A3b', 'a 3-working-day leave spanning the month end (the last working day of M + the first two of M+1)',
     'usage is split per month in the ledger and the balance reports (1 day in M, 2 in M+1); attendance is Leave in both months', @act, @ok;
GO

/* ---------------------------------------------------------------- A3d: half-day leave (D3) ---- */
DECLARE @E11 INT = dbo.QA2_Emp(N'E11'), @Hr INT = dbo.QA2_User(N'hr');
DECLARE @act NVARCHAR(700), @ok BIT, @rid1 INT, @rid2 INT, @d1 DATE = dbo.QA2_Date('A3d1'), @d2 DATE = dbo.QA2_Date('A3d2'), @t DATETIME2(0), @bal0 DECIMAL(6,2), @bal1 DECIMAL(6,2), @err NVARCHAR(400);
SET @bal0 = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E11 AND LeaveTypeId = 1);
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('workflow.usp_LeaveRequest_Create') AND name = '@HalfDay')
BEGIN TRY
    EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E11, @RaisedByUserId = @Hr, @LeaveTypeId = 1, @FromDate = @d1, @ToDate = @d1, @Reason = N'QA2 A3d present PM', @HalfDay = 'AM';
    SET @rid1 = dbo.QA2_LastRequest(@E11); EXEC dbo.QA2_Approve @rid1, 'Leave';
    EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E11, @RaisedByUserId = @Hr, @LeaveTypeId = 1, @FromDate = @d2, @ToDate = @d2, @Reason = N'QA2 A3d absent PM', @HalfDay = 'AM';
    SET @rid2 = dbo.QA2_LastRequest(@E11); EXEC dbo.QA2_Approve @rid2, 'Leave';
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @err = ERROR_MESSAGE(); END CATCH;
ELSE SET @err = 'usp_LeaveRequest_Create has no @HalfDay parameter';
/* day 1: present for the afternoon half 11:00-15:00; day 2: nobody came */
SET @t = dbo.QA2_At('A3d1', '11:00', 0); EXEC dbo.QA2_Punch @E11, @t, 0;  SET @t = dbo.QA2_At('A3d1', '15:00', 0); EXEC dbo.QA2_Punch @E11, @t, 1;
EXEC dbo.QA2_Process;
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E11, @WorkDate = @d2;
SET @bal1 = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E11 AND LeaveTypeId = 1);
SELECT @act = CONCAT(ISNULL(@err + ' | ', ''), 'balance ', @bal0, ' -> ', @bal1, ' for the two half days',
       ' | present PM: ', ISNULL((SELECT CONCAT(a.[Status], ' fraction ', a.DayFraction, ' worked ', a.WorkedMinutes, ' anomalies ', ISNULL((SELECT STRING_AGG(CONCAT(an.[Type], ' ', an.[Minutes]), ',') FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId), 'none')) FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E11 AND a.WorkDate = @d1), 'no record'),
       ' | absent PM: ',  ISNULL((SELECT CONCAT(a.[Status], ' fraction ', a.DayFraction, ' anomalies ', ISNULL((SELECT STRING_AGG(CONCAT(an.[Type], ' ', an.[Minutes], ' ', ISNULL(an.Decision, 'undecided')), ',') FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId), 'none')) FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E11 AND a.WorkDate = @d2), 'no record'));
SET @ok = CASE WHEN @err IS NULL AND @bal0 - @bal1 = 1.0
                AND EXISTS (SELECT 1 FROM workflow.LEAVE_REQUEST WHERE RequestInstanceId = @rid1 AND DaysRequested = 0.5 AND HalfDay = 'AM')
                AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E11 AND a.WorkDate = @d1 AND a.[Status] = 'Present' AND a.DayFraction = 1.00
                                   AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId))
                AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E11 AND a.WorkDate = @d2 AND a.DayFraction = 0.50
                                   AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId AND an.[Type] = 'HalfDayAbsence' AND an.Decision IS NULL)) THEN 1 ELSE 0 END;
EXEC dbo.QA2_Check 'A3d', 'half-day leave AM on two days: present 11:00-15:00 on the first, absent on the second',
     'each costs 0.5 of the balance (-1.0 in all); present PM: Present, full day, no anomaly; absent PM: half a day and a HalfDayAbsence anomaly for HR', @act, @ok;
GO

/* ---------------------------------------------------------------- A3e, A3f: an approval that is taken back ---- */
DECLARE @E11 INT = dbo.QA2_Emp(N'E11'), @Hr INT = dbo.QA2_User(N'hr'), @Owner INT = dbo.QA2_User(N'owner'), @Gm INT = dbo.QA2_User(N'gm');
DECLARE @act NVARCHAR(700), @ok BIT, @rid INT, @d DATE, @bal0 DECIMAL(6,2), @bal1 DECIMAL(6,2), @bal2 DECIMAL(6,2), @step INT, @err NVARCHAR(400), @mid NVARCHAR(100);

/* A3e: approved, then the last approver withdraws the decision the same day */
SET @d = dbo.QA2_Date('A3e');
SET @bal0 = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E11 AND LeaveTypeId = 1);
EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E11, @RaisedByUserId = @Hr, @LeaveTypeId = 1, @FromDate = @d, @ToDate = @d, @Reason = N'QA2 A3e';
SET @rid = dbo.QA2_LastRequest(@E11); EXEC dbo.QA2_Approve @rid, 'Leave';
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E11, @WorkDate = @d;
SET @bal1 = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E11 AND LeaveTypeId = 1);
SET @mid = (SELECT CONCAT([Status], ' fraction ', ISNULL(CAST(DayFraction AS VARCHAR(10)), 'NULL')) FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E11 AND WorkDate = @d);
SELECT @step = MAX(StepNo) FROM workflow.WORKFLOW_SIGNATURE WHERE RequestInstanceId = @rid AND RetractedAt IS NULL AND [Action] = 'Approved';
DECLARE @lastSigner INT = (SELECT TOP 1 ActedByUserId FROM workflow.WORKFLOW_SIGNATURE WHERE RequestInstanceId = @rid AND StepNo = @step AND [Action] = 'Approved' AND RetractedAt IS NULL ORDER BY SignatureId DESC);
BEGIN TRY
    /* the same-day retract of the LAST decision, by the person who signed it (usp_Request_WithdrawDecision is for a request still open) */
    EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @lastSigner, @Reason = N'QA2 A3e: approved by mistake', @SignedWithPassword = 1;
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @err = ERROR_MESSAGE(); END CATCH;
SET @bal2 = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E11 AND LeaveTypeId = 1);
SELECT @act = CONCAT(ISNULL('withdraw: ' + @err + ' | ', ''), 'balance ', @bal0, ' -> ', @bal1, ' (approved) -> ', @bal2, ' (withdrawn); request now ', ri.[Status],
                     '; usage rows left=', (SELECT COUNT(*) FROM hr.LEAVE_LEDGER l JOIN workflow.LEAVE_REQUEST lr ON lr.LeaveRequestId = l.LeaveRequestId WHERE lr.RequestInstanceId = @rid AND l.MovementType = 'Usage'),
                     '; attendance ', @mid, ' -> ', (SELECT CONCAT([Status], ' fraction ', DayFraction) FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E11 AND WorkDate = @d)),
       @ok = CASE WHEN @err IS NULL AND @bal1 = @bal0 - 1 AND @bal2 = @bal0 AND ri.[Status] IN ('Pending', 'OnHold') AND @mid LIKE 'Leave%'
                   AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E11 AND WorkDate = @d AND [Status] = 'Present' AND DayFraction = 1.00) THEN 1 ELSE 0 END
FROM workflow.REQUEST_INSTANCE ri WHERE ri.RequestInstanceId = @rid;
EXEC dbo.QA2_Check 'A3e', 'an approved one-day leave is retracted by its last approver the same day',
     'the ledger Usage row is removed and the balance restored; the request is pending again; the attendance day goes back to what the punches say (Present, full day) without anybody reprocessing it', @act, @ok;
/* leave it closed so it cannot overlap anything later */
BEGIN TRY EXEC workflow.usp_Request_Cancel @RequestInstanceId = @rid, @ActedByUserId = @Hr, @Reason = N'QA2 A3e done'; END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; END CATCH;

/* A3f: approved and posted, then reopened by GM + Owner and rejected */
SET @d = dbo.QA2_Date('A3f'); SET @err = NULL;
SET @bal0 = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E11 AND LeaveTypeId = 1);
EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E11, @RaisedByUserId = @Hr, @LeaveTypeId = 1, @FromDate = @d, @ToDate = @d, @Reason = N'QA2 A3f';
SET @rid = dbo.QA2_LastRequest(@E11); EXEC dbo.QA2_Approve @rid, 'Leave';
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E11, @WorkDate = @d;
SET @bal1 = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E11 AND LeaveTypeId = 1);
BEGIN TRY
    EXEC workflow.usp_Request_Reopen @RequestInstanceId = @rid, @ActedByUserId = @Gm, @Reason = N'QA2 A3f: the dates were wrong';
    EXEC workflow.usp_Request_Reopen @RequestInstanceId = @rid, @ActedByUserId = @Owner, @Reason = N'QA2 A3f: the dates were wrong';
    DECLARE @i INT = 1, @u INT;
    WHILE @i <= 3 AND (SELECT [Status] FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid) IN ('Pending', 'OnHold')
    BEGIN
        SET @u = CASE @i WHEN 1 THEN @Owner WHEN 2 THEN @Hr ELSE dbo.QA2_User(N'manager') END;
        BEGIN TRY EXEC workflow.usp_Request_Reject @RequestInstanceId = @rid, @ActedByUserId = @u, @Reason = N'QA2 A3f rejected after reopen', @SignedWithPassword = 1; END TRY
        BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; END CATCH;
        SET @i += 1;
    END
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @err = ERROR_MESSAGE(); END CATCH;
SET @bal2 = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E11 AND LeaveTypeId = 1);
SELECT @act = CONCAT(ISNULL('reopen: ' + @err + ' | ', ''), 'balance ', @bal0, ' -> ', @bal1, ' (approved) -> ', @bal2, ' (reopened + rejected); request ', ri.[Status],
                     '; attendance ', (SELECT CONCAT([Status], ' fraction ', DayFraction) FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E11 AND WorkDate = @d)),
       @ok = CASE WHEN @err IS NULL AND @bal1 = @bal0 - 1 AND @bal2 = @bal0 AND ri.[Status] = 'Rejected'
                   AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E11 AND WorkDate = @d AND [Status] = 'Present' AND DayFraction = 1.00) THEN 1 ELSE 0 END
FROM workflow.REQUEST_INSTANCE ri WHERE ri.RequestInstanceId = @rid;
EXEC dbo.QA2_Check 'A3f', 'an approved leave that already posted is reopened by the General Manager + the Owner and then rejected',
     'same restoration: Usage row removed, balance back, request Rejected, attendance day back to Present by its punches', @act, @ok;
GO

/* ---------------------------------------------------------------- A3g: more than the balance ---- */
DECLARE @E11 INT = dbo.QA2_Emp(N'E11'), @Hr INT = dbo.QA2_User(N'hr');
DECLARE @M DATE = CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month') + '-01' AS DATE);
DECLARE @act NVARCHAR(700), @ok BIT, @rid INT, @f DATE = DATEADD(MONTH, 3, @M), @t DATE = DATEADD(DAY, 39, DATEADD(MONTH, 3, @M)), @bal DECIMAL(6,2), @err NVARCHAR(400), @before INT, @after INT;
SET @bal = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E11 AND LeaveTypeId = 1);
SET @before = (SELECT COUNT(*) FROM workflow.LEAVE_REQUEST WHERE EmployeeId = @E11);
BEGIN TRY
    EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E11, @RaisedByUserId = @Hr, @LeaveTypeId = 1, @FromDate = @f, @ToDate = @t, @Reason = N'QA2 A3g: 40 calendar days';
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @err = ERROR_MESSAGE(); END CATCH;
SET @after = (SELECT COUNT(*) FROM workflow.LEAVE_REQUEST WHERE EmployeeId = @E11);
/* a request raised by mistake must not linger as an overlap for the next one */
IF @after > @before BEGIN SET @rid = dbo.QA2_LastRequest(@E11); BEGIN TRY EXEC workflow.usp_Request_Cancel @RequestInstanceId = @rid, @ActedByUserId = @Hr, @Reason = N'QA2 A3g'; END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; END CATCH; END
/* the discretionary path: a 2-day request granted as discretionary gives the days back */
DECLARE @f2 DATE = DATEADD(MONTH, 2, @M); WHILE DATEDIFF(DAY, '19000101', @f2) % 7 <> 0 SET @f2 = DATEADD(DAY, 1, @f2);     -- a Monday
DECLARE @t2 DATE = DATEADD(DAY, 1, @f2), @b0 DECIMAL(6,2) = @bal, @b1 DECIMAL(6,2);
EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E11, @RaisedByUserId = @Hr, @LeaveTypeId = 1, @FromDate = @f2, @ToDate = @t2, @Reason = N'QA2 A3g discretionary';
SET @rid = dbo.QA2_LastRequest(@E11); EXEC dbo.QA2_Approve @rid, 'Leave', @Discretionary = 1;
SET @b1 = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E11 AND LeaveTypeId = 1);
SELECT @act = CONCAT('balance ', @bal, '; request for 40 calendar days: ', CASE WHEN @after > @before THEN 'ACCEPTED' ELSE CONCAT('refused: ', @err) END,
                     ' | discretionary 2-day request: ', ri.[Status], ', IsDiscretionary=', lr.IsDiscretionary, ', balance ', @b0, ' -> ', @b1),
       @ok = CASE WHEN @after = @before AND @err LIKE N'%balance%' AND ri.[Status] = 'Approved' AND lr.IsDiscretionary = 1 AND @b1 = @b0 THEN 1 ELSE 0 END
FROM workflow.LEAVE_REQUEST lr JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId WHERE lr.RequestInstanceId = @rid;
EXEC dbo.QA2_Check 'A3g', 'a request for more paid leave than the balance holds (LeaveAllowNegativeBalance = 0); then a discretionary grant',
     'the oversized request is refused when it is raised, in words that name the balance; the discretionary approval path still works (approved, days returned, balance unchanged)', @act, @ok;

/* A3g2: taking a DISCRETIONARY approval back must take back both of its ledger rows (the usage and the give-back) */
DECLARE @signer INT = (SELECT TOP 1 ActedByUserId FROM workflow.WORKFLOW_SIGNATURE WHERE RequestInstanceId = @rid AND StepNo IS NOT NULL AND [Action] = 'Approved' AND RetractedAt IS NULL ORDER BY ActedAt DESC, SignatureId DESC);
DECLARE @b2 DECIMAL(6,2), @err2 NVARCHAR(400);
BEGIN TRY
    EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @signer, @Reason = N'QA2 A3g2', @SignedWithPassword = 1;
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @err2 = ERROR_MESSAGE(); END CATCH;
SET @b2 = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E11 AND LeaveTypeId = 1);
SET @act = CONCAT(ISNULL('retract: ' + @err2 + ' | ', ''), 'balance ', @b1, ' with the discretionary leave approved -> ', @b2, ' after the approval is retracted; ledger rows still tied to the request=',
                  (SELECT COUNT(*) FROM hr.LEAVE_LEDGER l JOIN workflow.LEAVE_REQUEST lr ON lr.LeaveRequestId = l.LeaveRequestId WHERE lr.RequestInstanceId = @rid));
SET @ok = CASE WHEN @err2 IS NULL AND @b2 = @b1 AND NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER l JOIN workflow.LEAVE_REQUEST lr ON lr.LeaveRequestId = l.LeaveRequestId WHERE lr.RequestInstanceId = @rid) THEN 1 ELSE 0 END;
EXEC dbo.QA2_Check 'A3g2', 'the discretionary approval is retracted the same day', 'both ledger rows of the request go (the usage AND the days given back): the balance is what it was, not 2 days richer', @act, @ok;
BEGIN TRY EXEC workflow.usp_Request_Cancel @RequestInstanceId = @rid, @ActedByUserId = @Hr, @Reason = N'QA2 A3g2 done'; END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; END CATCH;
GO

/* ---------------------------------------------------------------- A3h: carry-over cap and expiry (D4) ---- */
DECLARE @E10 INT = dbo.QA2_Emp(N'E10'), @Hr INT = dbo.QA2_User(N'hr');
DECLARE @M DATE = CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month') + '-01' AS DATE);
DECLARE @yr INT = YEAR(@M), @act NVARCHAR(700), @ok BIT, @carried DECIMAL(6,2), @n1 INT = NULL, @n2 INT = NULL, @expired DECIMAL(6,2), @err NVARCHAR(400);
SET @carried = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E10 AND LeaveTypeId = 1 AND MovementType = 'CarryOver' AND YEAR(EffectiveDate) = @yr);
IF OBJECT_ID('hr.usp_LeaveCarryOver_Expire') IS NOT NULL
BEGIN TRY
    DECLARE @asOf DATE = DATEFROMPARTS(@yr, 4, 1);
    DECLARE @x TABLE (EmployeesExpired INT, DaysExpired DECIMAL(9,2));
    INSERT INTO @x EXEC hr.usp_LeaveCarryOver_Expire @AsOfDate = @asOf, @ExpiresOn = '03-31', @EmployeeId = @E10, @ActedByUserId = @Hr;
    SET @n1 = (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E10 AND MovementType = 'Expiry');
    DELETE FROM @x;
    INSERT INTO @x EXEC hr.usp_LeaveCarryOver_Expire @AsOfDate = @asOf, @ExpiresOn = '03-31', @EmployeeId = @E10, @ActedByUserId = @Hr;      -- the nightly job again
    SET @n2 = (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E10 AND MovementType = 'Expiry');
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @err = ERROR_MESSAGE(); END CATCH;
SET @expired = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E10 AND MovementType = 'Expiry');
SET @act = CONCAT(ISNULL(@err + ' | ', ''), '7 days left last year -> carried into ', @yr, ': ', @carried,
                  '; expiry run for 03-31: ', CASE WHEN OBJECT_ID('hr.usp_LeaveCarryOver_Expire') IS NULL THEN 'procedure missing' ELSE CONCAT(@n1, ' Expiry line(s) of ', @expired, ' day(s); after a second run ', @n2, ' line(s)') END,
                  '; balance now ', (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E10 AND LeaveTypeId = 1));
SET @ok = CASE WHEN @carried = 5 AND @n1 = 1 AND @n2 = 1 AND @expired = -5 THEN 1 ELSE 0 END;
EXEC dbo.QA2_Check 'A3h', 'year opened with 7 unused days and a carry-over cap of 5; then the expiry date (03-31) passes with none of them used',
     '5 carried (the 2 beyond the cap lapse); on the expiry date the 5 unused carried days expire with ONE ''Expiry'' ledger line, and running the nightly job again adds nothing', @act, @ok;
GO
