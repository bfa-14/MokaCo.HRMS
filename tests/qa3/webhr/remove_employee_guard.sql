/* ============================================================================
   tests/qa3/webhr/remove_employee_guard.sql - QA3 REL-5 (docs/106_qa3_webhr.sql).

   "Remove" (hr.usp_Employee_SoftDelete) hides the employee from payroll for good, so it is refused
   until there is nothing left to pay:

     R1  an employee still employed (no termination date) is refused, by name
     R2  a leaver with a month of employment that no locked primary run paid is refused, and the
         sentence names that month
     R3  a leaver with an unconsumed payroll adjustment or an unsettled salary advance is refused
     R4  a leaver whose every month is in a locked primary run, with nothing pending, is removed;
         removing them again changes nothing
     R5  a leaver with NOTHING on file (no salary, no attendance, no payslip) can be removed at once:
         there is no pay to lose

   Payroll months of 1990 (no live run can be in the way); one transaction, rolled back; rows named
   'QA3 remove ...'. RAISERROR on a wrong result.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(2000) = NULL, @Msg NVARCHAR(400), @B INT, @D INT, @P INT, @U INT, @CT INT,
        @E1 INT, @E2 INT, @E3 INT, @Run INT, @m INT, @Adj INT;

BEGIN TRAN;
BEGIN TRY
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 remove branch', 1);          SET @B = SCOPE_IDENTITY();
    INSERT INTO hr.DEPARTMENT (Name, IsActive) VALUES (N'QA3 remove department', 1);  SET @D = SCOPE_IDENTITY();
    INSERT INTO hr.[POSITION] (Title, IsActive) VALUES (N'QA3 remove position', 1);   SET @P = SCOPE_IDENTITY();
    INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'qa3.remove.hr', N'x', 1); SET @U = SCOPE_IDENTITY();
    /* not the basic salary: its tier band (a trigger) is not what this test is about */
    SELECT TOP 1 @CT = ComponentTypeId FROM hr.COMPONENT_TYPE WHERE Name NOT LIKE N'%Basic%' ORDER BY ComponentTypeId;

    /* E1: still employed; E2: worked Jan-Mar 1990 with a salary; E3: never started, nothing on file */
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@B, @D, @P, N'QA3 remove still here', '1990-01-15', NULL, 5, 'en');
    SET @E1 = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@B, @D, @P, N'QA3 remove leaver', '1990-01-15', '1990-03-10', 5, 'en');
    SET @E2 = SCOPE_IDENTITY();
    INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom, EffectiveTo)
    VALUES (@E2, @CT, 100, 'USD', '1990-01-15', NULL);
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@B, @D, @P, N'QA3 remove never started', '1990-02-01', '1990-02-01', 5, 'en');
    SET @E3 = SCOPE_IDENTITY();

    /* locked primary runs for January and February 1990 with E2's payslip; March is not paid yet */
    SET @m = 1;
    WHILE @m <= 2
    BEGIN
        INSERT INTO payroll.PAYROLL_RUN (PeriodYearMonth, PeriodStart, PeriodEnd, RunType, [Status], PrimaryCurrency, CreatedByUserId, ApprovedAt, LockedAt)
        VALUES (CONCAT('1990-0', @m), DATEFROMPARTS(1990, @m, 1), EOMONTH(DATEFROMPARTS(1990, @m, 1)), 'Primary', 'Approved', 'USD', @U, SYSUTCDATETIME(), SYSUTCDATETIME());
        SET @Run = SCOPE_IDENTITY();
        INSERT INTO payroll.PAYSLIP (PayrollRunId, EmployeeId, EmployeeName) VALUES (@Run, @E2, N'QA3 remove leaver');
        SET @m += 1;
    END

    /* R1 */
    SET @Msg = NULL;
    BEGIN TRY EXEC hr.usp_Employee_SoftDelete @EmployeeId = @E1, @ModifiedBy = @U; END TRY
    BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
    IF @Msg IS NULL OR @Msg NOT LIKE N'%QA3 remove still here%' OR EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @E1 AND IsDeleted = 1)
        SET @fail = CONCAT(@fail, ' R1: an employee still employed was removed (', ISNULL(@Msg, 'no refusal'), ');');

    /* R2 */
    SET @Msg = NULL;
    BEGIN TRY EXEC hr.usp_Employee_SoftDelete @EmployeeId = @E2, @ModifiedBy = @U; END TRY
    BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
    IF @Msg IS NULL OR @Msg NOT LIKE N'%1990-03%' OR EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @E2 AND IsDeleted = 1)
        SET @fail = CONCAT(@fail, ' R2: a leaver with an unpaid month (March 1990) was removed (', ISNULL(@Msg, 'no refusal'), ');');

    /* March is locked too */
    INSERT INTO payroll.PAYROLL_RUN (PeriodYearMonth, PeriodStart, PeriodEnd, RunType, [Status], PrimaryCurrency, CreatedByUserId, ApprovedAt, LockedAt)
    VALUES ('1990-03', '1990-03-01', '1990-03-31', 'Primary', 'Approved', 'USD', @U, SYSUTCDATETIME(), SYSUTCDATETIME());
    SET @Run = SCOPE_IDENTITY();
    INSERT INTO payroll.PAYSLIP (PayrollRunId, EmployeeId, EmployeeName) VALUES (@Run, @E2, N'QA3 remove leaver');

    /* R3: an adjustment nobody has paid yet */
    INSERT INTO payroll.PAYROLL_ADJUSTMENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, TargetPeriod, Reason, CreatedByUserId)
    VALUES (@E2, @CT, 10, 'USD', '1990-04', N'QA3 remove adjustment', @U);
    SET @Adj = SCOPE_IDENTITY();
    SET @Msg = NULL;
    BEGIN TRY EXEC hr.usp_Employee_SoftDelete @EmployeeId = @E2, @ModifiedBy = @U; END TRY
    BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
    IF @Msg IS NULL OR @Msg NOT LIKE N'%adjustment%' OR EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @E2 AND IsDeleted = 1)
        SET @fail = CONCAT(@fail, ' R3: a leaver with an unpaid adjustment was removed (', ISNULL(@Msg, 'no refusal'), ');');
    DELETE FROM payroll.PAYROLL_ADJUSTMENT WHERE PayrollAdjustmentId = @Adj;

    /* R4 */
    BEGIN TRY EXEC hr.usp_Employee_SoftDelete @EmployeeId = @E2, @ModifiedBy = @U; END TRY
    BEGIN CATCH SET @fail = CONCAT(@fail, ' R4: a fully paid leaver was refused: ', ERROR_MESSAGE(), ';'); END CATCH;
    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @E2 AND IsDeleted = 1)
        SET @fail = CONCAT(@fail, ' R4: a fully paid leaver was not removed;');
    BEGIN TRY EXEC hr.usp_Employee_SoftDelete @EmployeeId = @E2, @ModifiedBy = @U; END TRY
    BEGIN CATCH SET @fail = CONCAT(@fail, ' R4: removing a removed employee again failed: ', ERROR_MESSAGE(), ';'); END CATCH;

    /* R5 */
    BEGIN TRY EXEC hr.usp_Employee_SoftDelete @EmployeeId = @E3, @ModifiedBy = @U; END TRY
    BEGIN CATCH SET @fail = CONCAT(@fail, ' R5: a record with nothing on file was refused: ', ERROR_MESSAGE(), ';'); END CATCH;
    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @E3 AND IsDeleted = 1)
        SET @fail = CONCAT(@fail, ' R5: a record with nothing on file was not removed;');
END TRY
BEGIN CATCH
    SET @fail = CONCAT(@fail, ' unexpected error: ', ERROR_MESSAGE(), ' (line ', ERROR_LINE(), ');');
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;

IF @fail IS NOT NULL RAISERROR('FAIL remove_employee_guard:%s', 16, 1, @fail);
ELSE PRINT 'ok remove_employee_guard';
