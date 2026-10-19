/* ============================================================================
   tests/qa3/leave/approved_span.sql -- QA3 LEV-2 / PAY-8 / ATT-8 / REL-6 (docs/99_qa3_leave.sql).
   A partial approval keeps the FIRST days and the request now says where it ends (ApprovedToDate); PaidSnapshot is the
   type's IsPaid at approval; a fractional approval costs its fraction on its last day; a full approval ends on ToDate;
   the trimmed days are free to ask for again, the approved ones are not; re-pricing an unchanged leave writes nothing.

   Runs on a real dev database: every phase is one transaction that is rolled back; seeded rows start with 'QA3 ' and
   use dates in 2097. A refusal raised under XACT_ABORT dooms the transaction it is caught in, so each phase checks at
   most one refusal, last. Prints 'ok approved_span', or raises the first wrong result. Needs 99 (sqlcmd -I -b).
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID('tempdb..#qa3_fail') IS NOT NULL DROP TABLE #qa3_fail;
CREATE TABLE #qa3_fail (Msg NVARCHAR(4000));
IF OBJECT_ID('tempdb..#qa3_span_seed') IS NOT NULL DROP PROCEDURE #qa3_span_seed;
GO
/* a branch, a shift, a paid and an unpaid type, two employees with a Mon-Fri roster for two weeks of March 2097 */
CREATE PROCEDURE #qa3_span_seed
    @E1 INT OUTPUT, @E2 INT OUTPUT, @Paid INT OUTPUT, @Unpaid INT OUTPUT, @T INT OUTPUT, @Def INT OUTPUT,
    @User INT OUTPUT, @Mon DATE OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Leave Branch', 1);
    DECLARE @B INT = SCOPE_IDENTITY();
    DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
    DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);
    SET @User = (SELECT TOP 1 UserId FROM security.[USER] WHERE IsActive = 1 ORDER BY UserId);
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
    VALUES (N'QA3 Day', '08:00', '16:00', NULL, 0, 30, 1);
    DECLARE @Shift INT = SCOPE_IDENTITY();
    INSERT INTO hr.LEAVE_TYPE (Name, IsPaid, AccrualPerMonth, CarryOver, RequiresCertificate, MinServiceMonthsToUse, NoticePreferredDays, FixedEntitlementDays, IsDiscretionary, IsActive)
    VALUES (N'QA3 Paid', 1, 0, 0, 0, 0, 0, NULL, 0, 1), (N'QA3 Unpaid', 0, 0, 0, 0, 0, 0, NULL, 0, 1);
    SET @Paid = (SELECT LeaveTypeId FROM hr.LEAVE_TYPE WHERE Name = N'QA3 Paid');
    SET @Unpaid = (SELECT LeaveTypeId FROM hr.LEAVE_TYPE WHERE Name = N'QA3 Unpaid');
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@B, @Dep, @Pos, N'QA3 Span E1', '2020-01-01', NULL, 5, 'en'), (@B, @Dep, @Pos, N'QA3 Span E2', '2020-01-01', NULL, 5, 'en');
    SET @E1 = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Span E1');
    SET @E2 = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Span E2');
    SET @Mon = '2097-03-02';
    WHILE DATEDIFF(DAY, '19000101', @Mon) % 7 <> 0 SET @Mon = DATEADD(DAY, 1, @Mon);       -- a Monday
    DECLARE @d DATE = @Mon;
    WHILE @d < DATEADD(DAY, 14, @Mon)
    BEGIN
        INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
        SELECT e.EmployeeId, CASE WHEN DATEDIFF(DAY, '19000101', @d) % 7 < 5 THEN @Shift END, @d,
               CASE WHEN DATEDIFF(DAY, '19000101', @d) % 7 < 5 THEN 0 ELSE 1 END
        FROM (VALUES (@E1), (@E2)) e(EmployeeId);
        SET @d = DATEADD(DAY, 1, @d);
    END
    SET @T = (SELECT RequestTypeId FROM workflow.REQUEST_TYPE WHERE Code = 'LEAVE_REQUEST');
    SET @Def = (SELECT TOP 1 WorkflowDefinitionId FROM workflow.WORKFLOW_DEFINITION WHERE RequestTypeId = @T
                ORDER BY CASE WHEN [Status] = 'Active' THEN 0 ELSE 1 END, WorkflowDefinitionId DESC);
    IF @T IS NULL OR @Def IS NULL RAISERROR('FAIL approved_span: no LEAVE_REQUEST workflow on this database.', 16, 1);
END;
GO

/* ---------------- phase 1: what the poster stores ---------------- */
BEGIN TRAN;
BEGIN TRY
    DECLARE @E1 INT, @E2 INT, @Paid INT, @Unpaid INT, @T INT, @Def INT, @User INT, @Mon DATE;
    EXEC #qa3_span_seed @E1 OUTPUT, @E2 OUTPUT, @Paid OUTPUT, @Unpaid OUTPUT, @T OUTPUT, @Def OUTPUT, @User OUTPUT, @Mon OUTPUT;
    DECLARE @msg NVARCHAR(2000), @rid INT, @lr INT, @end DATE, @snap BIT, @usage DECIMAL(9,2), @eff DATE,
            @parts DECIMAL(9,2), @last DECIMAL(9,2);
    DECLARE @Wed DATE = DATEADD(DAY, 2, @Mon), @Thu DATE = DATEADD(DAY, 3, @Mon), @Fri DATE = DATEADD(DAY, 4, @Mon);

    /* (a) Mon-Fri unpaid, 3 of 5 granted: the leave is Mon-Wed */
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@T, @Def, @E1, @User, 'Approved', N'QA3 span a', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, IsDiscretionary)
    VALUES (@rid, @E1, @Unpaid, @Mon, @Fri, 5, 3, 0);
    SET @lr = SCOPE_IDENTITY();
    EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId = @rid, @ActorUserId = @User;
    SELECT @end = ApprovedToDate, @snap = PaidSnapshot FROM workflow.LEAVE_REQUEST WHERE LeaveRequestId = @lr;
    SELECT @usage = -SUM(Days), @eff = MIN(EffectiveDate) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr AND MovementType = 'Usage';
    IF @end IS NULL OR @end <> @Wed OR @snap IS NULL OR @snap <> 0 OR @usage <> 3 OR @eff <> @Mon
    BEGIN
        SET @msg = CONCAT('FAIL approved_span (a): 3 of 5 -> expected ApprovedToDate ', CONVERT(CHAR(10), @Wed, 23),
                          ', PaidSnapshot 0, usage 3 from ', CONVERT(CHAR(10), @Mon, 23), '; got ', ISNULL(CONVERT(CHAR(10), @end, 23), 'NULL'),
                          ', ', ISNULL(CAST(@snap AS VARCHAR(5)), 'NULL'), ', ', ISNULL(CAST(@usage AS VARCHAR(20)), 'NULL'));
        RAISERROR(@msg, 16, 1);
    END
    /* re-pricing an unchanged leave writes nothing: the same ledger row stays */
    DECLARE @before INT = (SELECT MIN(LeaveLedgerId) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr);
    DECLARE @To2 DATE = DATEADD(DAY, 13, @Mon);
    EXEC hr.usp_LeaveLedger_Reprice @EmployeeId = @E1, @FromDate = @Mon, @ToDate = @To2;
    IF (SELECT MIN(LeaveLedgerId) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr) <> @before
       OR (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr) <> 1
        RAISERROR('FAIL approved_span (a): re-pricing an unchanged leave re-posted it.', 16, 1);

    /* (b) the days the partial approval did not grant (Thu, Fri) are free to ask for again */
    DECLARE @n0 INT = (SELECT COUNT(*) FROM workflow.LEAVE_REQUEST WHERE EmployeeId = @E1);
    EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E1, @RaisedByUserId = @User, @LeaveTypeId = @Unpaid,
         @FromDate = @Thu, @ToDate = @Fri, @Reason = N'QA3 the days not granted';
    IF (SELECT COUNT(*) FROM workflow.LEAVE_REQUEST WHERE EmployeeId = @E1) <> @n0 + 1
        RAISERROR('FAIL approved_span (b): the days a partial approval did not grant must be free to ask for.', 16, 1);

    /* (c) 2.5 of 5 paid: Mon, Tue whole, Wed half; PaidSnapshot 1 */
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@T, @Def, @E2, @User, 'Approved', N'QA3 span c', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, IsDiscretionary)
    VALUES (@rid, @E2, @Paid, @Mon, @Fri, 5, 2.5, 0);
    SET @lr = SCOPE_IDENTITY();
    EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId = @rid, @ActorUserId = @User;
    SELECT @end = ApprovedToDate, @snap = PaidSnapshot FROM workflow.LEAVE_REQUEST WHERE LeaveRequestId = @lr;
    SELECT @usage = -SUM(Days) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr AND MovementType = 'Usage';
    SELECT @parts = SUM(Part), @last = MAX(CASE WHEN WorkDate = @Wed THEN Part ELSE 0 END) FROM hr.fn_LeaveRequestDays(@lr, 0);
    IF @end <> @Wed OR @snap <> 1 OR @usage <> 2.5 OR @parts <> 2.5 OR @last <> 0.5
    BEGIN
        SET @msg = CONCAT('FAIL approved_span (c): 2.5 of 5 -> ends ', CONVERT(CHAR(10), @Wed, 23), ' with half that day, usage 2.5, PaidSnapshot 1; got end ',
                          ISNULL(CONVERT(CHAR(10), @end, 23), 'NULL'), ', usage ', ISNULL(CAST(@usage AS VARCHAR(20)), 'NULL'), ', last part ',
                          ISNULL(CAST(@last AS VARCHAR(20)), 'NULL'), ', snapshot ', ISNULL(CAST(@snap AS VARCHAR(5)), 'NULL'));
        RAISERROR(@msg, 16, 1);
    END

    /* (d) a full approval of Mon..Sun: ApprovedToDate = ToDate (the weekend is part of the leave), 5 working days used;
       a second post writes nothing */
    DECLARE @Mon2 DATE = DATEADD(DAY, 7, @Mon), @Sun DATE = DATEADD(DAY, 13, @Mon);
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@T, @Def, @E2, @User, 'Approved', N'QA3 span d', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, IsDiscretionary)
    VALUES (@rid, @E2, @Paid, @Mon2, @Sun, 5, 5, 0);
    SET @lr = SCOPE_IDENTITY();
    EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId = @rid, @ActorUserId = @User;
    EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId = @rid, @ActorUserId = @User;
    SELECT @end = ApprovedToDate FROM workflow.LEAVE_REQUEST WHERE LeaveRequestId = @lr;
    SELECT @usage = -SUM(Days) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr AND MovementType = 'Usage';
    IF @end <> @Sun OR @usage <> 5 OR (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr) <> 1
    BEGIN
        SET @msg = CONCAT('FAIL approved_span (d): a full approval ends on ToDate ', CONVERT(CHAR(10), @Sun, 23), ' with ONE usage row of 5; got ',
                          ISNULL(CONVERT(CHAR(10), @end, 23), 'NULL'), ', ', ISNULL(CAST(@usage AS VARCHAR(20)), 'NULL'), ', rows ',
                          (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr));
        RAISERROR(@msg, 16, 1);
    END

    /* (e) the payload carries the approved span */
    DECLARE @pl TABLE (LeaveRequestId INT, EmployeeId INT, EmployeeName NVARCHAR(200), LeaveTypeId INT, LeaveTypeName NVARCHAR(60), IsPaid BIT,
                       FromDate DATE, ToDate DATE, DaysRequested DECIMAL(9,1), DaysApproved DECIMAL(9,1), Reason NVARCHAR(500),
                       AppliedToLedgerAt DATETIME2, RelationToEmployee NVARCHAR(30), RequiresCertificate BIT, IsDiscretionary BIT,
                       AttachmentCount INT, CurrentBalance DECIMAL(18,2), NoticeGivenDays INT, NoticePreferredDays INT,
                       NoticeShorterThanPreferred BIT, HalfDay CHAR(2), ApprovedToDate DATE, PaidSnapshot BIT);
    DECLARE @ridA INT = (SELECT RequestInstanceId FROM workflow.LEAVE_REQUEST WHERE EmployeeId = @E1 AND LeaveTypeId = @Unpaid AND FromDate = @Mon);
    INSERT INTO @pl EXEC workflow.usp_LeaveRequest_GetPayload @RequestInstanceId = @ridA;
    IF (SELECT ApprovedToDate FROM @pl) <> @Wed OR (SELECT PaidSnapshot FROM @pl) <> 0
        RAISERROR('FAIL approved_span (e): the payload does not carry ApprovedToDate / PaidSnapshot.', 16, 1);
END TRY
BEGIN CATCH
    DECLARE @e NVARCHAR(4000) = ERROR_MESSAGE();
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT INTO #qa3_fail VALUES (@e);
    RAISERROR(N'%s', 16, 1, @e);
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 2: an APPROVED day cannot be asked for again ---------------- */
BEGIN TRAN;
BEGIN TRY
    DECLARE @E1 INT, @E2 INT, @Paid INT, @Unpaid INT, @T INT, @Def INT, @User INT, @Mon DATE;
    EXEC #qa3_span_seed @E1 OUTPUT, @E2 OUTPUT, @Paid OUTPUT, @Unpaid OUTPUT, @T OUTPUT, @Def OUTPUT, @User OUTPUT, @Mon OUTPUT;
    DECLARE @msg NVARCHAR(2000), @err NVARCHAR(2000), @rid INT;
    DECLARE @Wed DATE = DATEADD(DAY, 2, @Mon), @Fri DATE = DATEADD(DAY, 4, @Mon);
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@T, @Def, @E1, @User, 'Approved', N'QA3 span phase 2', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, IsDiscretionary)
    VALUES (@rid, @E1, @Unpaid, @Mon, @Fri, 5, 3, 0);
    EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId = @rid, @ActorUserId = @User;
    BEGIN TRY
        EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E1, @RaisedByUserId = @User, @LeaveTypeId = @Unpaid,
             @FromDate = @Wed, @ToDate = @Wed, @Reason = N'QA3 overlaps an approved day';
    END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    IF @err IS NULL OR @err NOT LIKE N'%overlap an existing leave request from ' + CONVERT(CHAR(10), @Mon, 23) + N' to ' + CONVERT(CHAR(10), @Wed, 23) + N' (Approved)%'
    BEGIN
        SET @msg = CONCAT('FAIL approved_span (phase 2): a request on an APPROVED day must be refused naming ', CONVERT(CHAR(10), @Mon, 23), ' to ',
                          CONVERT(CHAR(10), @Wed, 23), '; got: ', ISNULL(@err, 'accepted'));
        RAISERROR(@msg, 16, 1);
    END
END TRY
BEGIN CATCH
    DECLARE @e NVARCHAR(4000) = ERROR_MESSAGE();
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT INTO #qa3_fail VALUES (@e);
    RAISERROR(N'%s', 16, 1, @e);
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

IF EXISTS (SELECT 1 FROM #qa3_fail) RAISERROR('approved_span: FAILED (see above).', 16, 1);
ELSE PRINT 'ok approved_span';
DROP PROCEDURE #qa3_span_seed;
GO
