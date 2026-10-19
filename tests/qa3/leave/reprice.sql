/* ============================================================================
   tests/qa3/leave/reprice.sql -- QA3 LEV-4 / REL-12 / ROS-12 (docs/99_qa3_leave.sql): a leave costs the working days of
   the roster as it finally stands.
   - a day with no roster row is priced from the employee's weekly pattern (a rest day there is free);
   - hr.usp_LeaveLedger_Reprice re-posts the usage after the roster is built and a holiday added, once (a second call
     writes nothing), leaves a month already paid for the employee as it was paid, re-posts a discretionary pair together,
     prices the days after a termination at nothing, and leaves a fixed-entitlement (calendar) leave alone.
   Runs on a real dev database inside one transaction that is rolled back; seeded rows start with 'QA3 ' and use 2097.
   Prints 'ok reprice', or raises the first wrong result. Needs 99 (sqlcmd -I -b).
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
GO
BEGIN TRAN;
BEGIN TRY
    DECLARE @msg NVARCHAR(2000);
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Reprice Branch', 1);
    DECLARE @B INT = SCOPE_IDENTITY();
    DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
    DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);
    DECLARE @User INT = (SELECT TOP 1 UserId FROM security.[USER] WHERE IsActive = 1 ORDER BY UserId);
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
    VALUES (N'QA3 Day', '08:00', '16:00', NULL, 0, 30, 1);
    DECLARE @Shift INT = SCOPE_IDENTITY();
    INSERT INTO hr.LEAVE_TYPE (Name, IsPaid, CarryOver, RequiresCertificate, MinServiceMonthsToUse, NoticePreferredDays, FixedEntitlementDays, IsDiscretionary, IsActive)
    VALUES (N'QA3 Annual', 1, 1, 0, 0, 0, NULL, 0, 1), (N'QA3 Maternity', 1, 0, 0, 0, 0, 70, 0, 1);
    DECLARE @Annual INT = (SELECT LeaveTypeId FROM hr.LEAVE_TYPE WHERE Name = N'QA3 Annual');
    DECLARE @Mat INT = (SELECT LeaveTypeId FROM hr.LEAVE_TYPE WHERE Name = N'QA3 Maternity');
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@B, @Dep, @Pos, N'QA3 Reprice E1', '2020-01-01', NULL, 5, 'en'),
           (@B, @Dep, @Pos, N'QA3 Reprice E2', '2020-01-01', NULL, 5, 'en'),
           (@B, @Dep, @Pos, N'QA3 Reprice E3', '2020-01-01', NULL, 5, 'en');
    DECLARE @E1 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Reprice E1');
    DECLARE @E2 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Reprice E2');
    DECLARE @E3 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Reprice E3');
    /* the weekly pattern: Mon-Fri on the day shift, Saturday and Sunday off -- and NO roster yet */
    INSERT INTO attendance.EMPLOYEE_SHIFT_PATTERN (EmployeeId, DayOfWeek, ShiftId, IsRestDay)
    SELECT e.EmployeeId, d.Dow, CASE WHEN d.Dow <= 5 THEN @Shift END, CASE WHEN d.Dow <= 5 THEN 0 ELSE 1 END
    FROM (VALUES (@E1), (@E2), (@E3)) e(EmployeeId) CROSS JOIN (VALUES (1),(2),(3),(4),(5),(6),(7)) d(Dow);
    DECLARE @T INT = (SELECT RequestTypeId FROM workflow.REQUEST_TYPE WHERE Code = 'LEAVE_REQUEST');
    DECLARE @Def INT = (SELECT TOP 1 WorkflowDefinitionId FROM workflow.WORKFLOW_DEFINITION WHERE RequestTypeId = @T
                        ORDER BY CASE WHEN [Status] = 'Active' THEN 0 ELSE 1 END, WorkflowDefinitionId DESC);
    DECLARE @Mon DATE = '2097-03-02';
    WHILE DATEDIFF(DAY, '19000101', @Mon) % 7 <> 0 SET @Mon = DATEADD(DAY, 1, @Mon);
    DECLARE @Sun DATE = DATEADD(DAY, 6, @Mon);

    /* 1. no roster: the pattern prices the week at 5 (it was 7: "no roster row = a working day") */
    IF hr.fn_LeaveWorkingDays(@E1, @Mon, @Sun) <> 5
    BEGIN
        SET @msg = CONCAT('FAIL reprice (1): a Mon-Sun week with no roster and a Mon-Fri pattern costs 5; got ', hr.fn_LeaveWorkingDays(@E1, @Mon, @Sun));
        RAISERROR(@msg, 16, 1);
    END

    /* an approved annual leave Mon..Sun, posted: 5 */
    DECLARE @rid INT, @lr INT, @ids NVARCHAR(200), @ids2 NVARCHAR(200), @u DECIMAL(9,2), @a DECIMAL(9,2);
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@T, @Def, @E1, @User, 'Approved', N'QA3 reprice 1', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, IsDiscretionary)
    VALUES (@rid, @E1, @Annual, @Mon, @Sun, 5, 5, 0);
    SET @lr = SCOPE_IDENTITY();
    EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId = @rid, @ActorUserId = @User;
    IF (SELECT -SUM(Days) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr) <> 5
        RAISERROR('FAIL reprice (1): the approved week was not posted at 5.', 16, 1);

    /* 2. the roster is built: Fri off and Sat on instead; Tue becomes a public holiday of the branch. Cost now: Mon, Wed,
          Thu, Sat = 4 */
    DECLARE @d DATE = @Mon;
    WHILE @d <= @Sun
    BEGIN
        DECLARE @dow INT = DATEDIFF(DAY, '19000101', @d) % 7 + 1;
        INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
        VALUES (@E1, CASE WHEN @dow IN (5, 7) THEN NULL ELSE @Shift END, @d, CASE WHEN @dow IN (5, 7) THEN 1 ELSE 0 END);
        SET @d = DATEADD(DAY, 1, @d);
    END
    DECLARE @Tue DATE = DATEADD(DAY, 1, @Mon);
    INSERT INTO core.HOLIDAY (HolidayDate, Name, IsPaid, BranchId) VALUES (@Tue, N'QA3 Holiday', 1, @B);
    EXEC hr.usp_LeaveLedger_Reprice @EmployeeId = @E1, @FromDate = @Mon, @ToDate = @Sun;
    SELECT @u = -SUM(Days) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr AND MovementType = 'Usage';
    IF @u <> 4 OR (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr) <> 1
    BEGIN
        SET @msg = CONCAT('FAIL reprice (2): after the roster and the holiday the week costs 4 in ONE row; got ', ISNULL(CAST(@u AS VARCHAR(20)), 'NULL'),
                          ' in ', (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr), ' row(s)');
        RAISERROR(@msg, 16, 1);
    END
    /* the leave keeps its days: ApprovedToDate is unchanged */
    IF (SELECT ApprovedToDate FROM workflow.LEAVE_REQUEST WHERE LeaveRequestId = @lr) <> @Sun
        RAISERROR('FAIL reprice (2): re-pricing moved the approved days.', 16, 1);

    /* 3. a second call writes nothing */
    SET @ids = (SELECT STRING_AGG(CAST(LeaveLedgerId AS VARCHAR(12)), ',') FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr);
    EXEC hr.usp_LeaveLedger_Reprice @EmployeeId = @E1, @FromDate = @Mon, @ToDate = @Sun;
    SET @ids2 = (SELECT STRING_AGG(CAST(LeaveLedgerId AS VARCHAR(12)), ',') FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr);
    IF @ids <> @ids2 RAISERROR('FAIL reprice (3): a second re-pricing re-posted rows that were already right.', 16, 1);

    /* 4. a leave over a month end, April paid for the employee: April stays as paid, May is re-priced */
    DECLARE @A1 DATE = '2097-04-24';                                      -- the last Monday of April 2097 .. the Friday after next
    WHILE DATEDIFF(DAY, '19000101', @A1) % 7 <> 0 SET @A1 = DATEADD(DAY, 1, @A1);
    DECLARE @A2 DATE = DATEADD(DAY, 11, @A1);
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@T, @Def, @E2, @User, 'Approved', N'QA3 reprice 4', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, IsDiscretionary)
    VALUES (@rid, @E2, @Annual, @A1, @A2, 10, 10, 1);                    -- discretionary: usage and give-back
    SET @lr = SCOPE_IDENTITY();
    EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId = @rid, @ActorUserId = @User;
    DECLARE @aprBefore NVARCHAR(400) = (SELECT STRING_AGG(CONCAT(LeaveLedgerId, ':', MovementType, ':', Days), ',') WITHIN GROUP (ORDER BY LeaveLedgerId)
                                        FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr AND PeriodYearMonth = '2097-04');
    DECLARE @Run INT = (SELECT PayrollRunId FROM payroll.PAYROLL_RUN WHERE PeriodYearMonth = '2097-04' AND RunType = 'Primary' AND [Status] <> 'Cancelled');
    IF @Run IS NULL
    BEGIN
        INSERT INTO payroll.PAYROLL_RUN (PeriodYearMonth, PeriodStart, PeriodEnd, PrimaryCurrency, Notes, CreatedByUserId, RunType, [Status])
        VALUES ('2097-04', '2097-04-01', '2097-04-30', 'USD', N'QA3 paid April', @User, 'Primary', 'Approved');
        SET @Run = SCOPE_IDENTITY();
    END
    ELSE UPDATE payroll.PAYROLL_RUN SET [Status] = 'Approved' WHERE PayrollRunId = @Run;
    INSERT INTO payroll.PAYSLIP (PayrollRunId, EmployeeId, EmployeeName) VALUES (@Run, @E2, N'QA3 Reprice E2');
    /* every weekday of the two weeks becomes a rest day on the roster */
    SET @d = @A1;
    WHILE @d <= @A2
    BEGIN
        INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E2, NULL, @d, 1);
        SET @d = DATEADD(DAY, 1, @d);
    END
    EXEC hr.usp_LeaveLedger_Reprice @EmployeeId = @E2, @FromDate = @A1, @ToDate = @A2;
    IF (SELECT STRING_AGG(CONCAT(LeaveLedgerId, ':', MovementType, ':', Days), ',') WITHIN GROUP (ORDER BY LeaveLedgerId)
        FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr AND PeriodYearMonth = '2097-04') <> @aprBefore
        RAISERROR('FAIL reprice (4): a month already paid for the employee was re-priced.', 16, 1);
    IF EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr AND PeriodYearMonth = '2097-05')
        RAISERROR('FAIL reprice (4): May (all rest days now) still carries usage and give-back rows.', 16, 1);
    /* the discretionary pair stays a pair: the balance moved by nothing */
    IF (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr) <> 0
        RAISERROR('FAIL reprice (4): the discretionary usage and give-back no longer net to zero.', 16, 1);

    /* 5. a termination inside an approved leave: the days after it cost nothing once re-priced */
    DECLARE @M1 DATE = '2097-06-01';                                      -- a Monday in June 2097 .. the Friday after next: 10 days by the pattern
    WHILE DATEDIFF(DAY, '19000101', @M1) % 7 <> 0 SET @M1 = DATEADD(DAY, 1, @M1);
    DECLARE @M2 DATE = DATEADD(DAY, 11, @M1), @Term DATE = DATEADD(DAY, 4, @M1);
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@T, @Def, @E3, @User, 'Approved', N'QA3 reprice 5', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, IsDiscretionary)
    VALUES (@rid, @E3, @Annual, @M1, @M2, 10, 10, 0);
    SET @lr = SCOPE_IDENTITY();
    EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId = @rid, @ActorUserId = @User;
    UPDATE hr.EMPLOYEE SET TerminationDate = @Term WHERE EmployeeId = @E3;   -- leaves on Friday of the first week
    EXEC hr.usp_LeaveLedger_Reprice @EmployeeId = @E3, @FromDate = @M1, @ToDate = @M2;
    SET @u = (SELECT -SUM(Days) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr);
    IF @u <> 5
    BEGIN
        SET @msg = CONCAT('FAIL reprice (5): leaving on day 5 of a 10-day leave leaves 5 days used; got ', ISNULL(CAST(@u AS VARCHAR(20)), 'NULL'));
        RAISERROR(@msg, 16, 1);
    END

    /* 6. a fixed-entitlement (calendar) leave is a span of the calendar: the roster does not re-price it */
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@T, @Def, @E1, @User, 'Approved', N'QA3 reprice 6', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    DECLARE @C1 DATE = '2097-08-03', @C2 DATE = '2097-08-16';
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, IsDiscretionary)
    VALUES (@rid, @E1, @Mat, @C1, @C2, 14, 14, 0);
    SET @lr = SCOPE_IDENTITY();
    EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId = @rid, @ActorUserId = @User;
    SET @ids = (SELECT STRING_AGG(CAST(LeaveLedgerId AS VARCHAR(12)), ',') FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr);
    EXEC hr.usp_LeaveLedger_Reprice @EmployeeId = @E1, @FromDate = @C1, @ToDate = @C2;
    IF (SELECT -SUM(Days) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr) <> 14
       OR (SELECT STRING_AGG(CAST(LeaveLedgerId AS VARCHAR(12)), ',') FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr) <> @ids
        RAISERROR('FAIL reprice (6): a calendar-day leave of 14 days was re-priced.', 16, 1);

    PRINT 'ok reprice';
END TRY
BEGIN CATCH
    DECLARE @e NVARCHAR(4000) = ERROR_MESSAGE();
    IF @@TRANCOUNT > 0 ROLLBACK;
    RAISERROR(N'%s', 16, 1, @e);
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;
GO
