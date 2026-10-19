/* ============================================================================
   tests/qa3/leave/year_close.sql -- QA3 LEV-1 / LEV-9 / LEV-12 / LEV-13 (docs/99_qa3_leave.sql), in the CURRENT year
   (Beirut), the only one hr.usp_LeaveYear_Open opens:
   - the close of last year sits in last year (December, the 31st): this year's card is entitlement + carry, last year's
     card ends at 0 (LEV-1);
   - the tier follows WHOLE years of service at 1 January (LEV-12);
   - an employee with no tier for their service still has last year closed, once; a second run writes nothing (LEV-9);
   - an inactive type is not granted (LEV-13);
   - hr.usp_LeaveYear_Undo takes the opening back and the year opens again to the same rows; it is refused when leave of
     the year was used in a period already paid (LEV-9).
   Runs on a real dev database: each phase is one transaction that is rolled back; seeded rows start with 'QA3 '; only the
   QA3 employees are opened (@EmployeeId). Prints 'ok year_close', or raises the first wrong result. Needs 99.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID('tempdb..#qa3_fail') IS NOT NULL DROP TABLE #qa3_fail;
CREATE TABLE #qa3_fail (Msg NVARCHAR(4000));
IF OBJECT_ID('tempdb..#qa3_year_seed') IS NOT NULL DROP PROCEDURE #qa3_year_seed;
GO
/* 'QA3 Tiered' (carry-over; tiers from 1 year: 10 days, from 5 years: 20), 'QA3 Inactive' (deactivated, tier 0: 30).
   E1 hired 1 March six years ago with 7 days left last year; E2 hired 15 January five years ago (4 WHOLE years at
   1 January); E3 hired last June (no tier yet) with 3 days left last year. */
CREATE PROCEDURE #qa3_year_seed
    @Y INT OUTPUT, @Tiered INT OUTPUT, @Inactive INT OUTPUT, @E1 INT OUTPUT, @E2 INT OUTPUT, @E3 INT OUTPUT, @User INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Y = YEAR(CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));
    SET @User = (SELECT TOP 1 UserId FROM security.[USER] WHERE IsActive = 1 ORDER BY UserId);
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Year Branch', 1);
    DECLARE @B INT = SCOPE_IDENTITY();
    DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
    DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);
    INSERT INTO hr.LEAVE_TYPE (Name, IsPaid, CarryOver, RequiresCertificate, MinServiceMonthsToUse, NoticePreferredDays, FixedEntitlementDays, IsDiscretionary, IsActive)
    VALUES (N'QA3 Tiered', 1, 1, 0, 0, 0, NULL, 0, 1), (N'QA3 Inactive', 1, 1, 0, 0, 0, NULL, 0, 0);
    SET @Tiered = (SELECT LeaveTypeId FROM hr.LEAVE_TYPE WHERE Name = N'QA3 Tiered');
    SET @Inactive = (SELECT LeaveTypeId FROM hr.LEAVE_TYPE WHERE Name = N'QA3 Inactive');
    INSERT INTO hr.LEAVE_ACCRUAL_TIER (LeaveTypeId, MinServiceYears, AnnualDays) VALUES (@Tiered, 1, 10), (@Tiered, 5, 20), (@Inactive, 0, 30);
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@B, @Dep, @Pos, N'QA3 Year E1', DATEFROMPARTS(@Y - 6, 3, 1), NULL, 5, 'en'),
           (@B, @Dep, @Pos, N'QA3 Year E2', DATEFROMPARTS(@Y - 5, 1, 15), NULL, 5, 'en'),
           (@B, @Dep, @Pos, N'QA3 Year E3', DATEFROMPARTS(@Y - 1, 6, 10), NULL, 5, 'en');
    SET @E1 = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Year E1');
    SET @E2 = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Year E2');
    SET @E3 = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Year E3');
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note)
    VALUES (@E1, @Tiered, CONCAT(@Y - 1, '-01'), 'Accrual', 20, DATEFROMPARTS(@Y - 1, 1, 1), N'QA3 last year''s entitlement'),
           (@E1, @Tiered, CONCAT(@Y - 1, '-07'), 'Usage', -13, DATEFROMPARTS(@Y - 1, 7, 7), N'QA3 last year''s leave'),
           (@E3, @Tiered, CONCAT(@Y - 1, '-06'), 'Accrual', 3, DATEFROMPARTS(@Y - 1, 6, 10), N'QA3 last year''s part-year grant');
END;
GO

/* ---------------- phase 1: open, read, re-run, undo, open again ---------------- */
BEGIN TRAN;
BEGIN TRY
    DECLARE @Y INT, @Tiered INT, @Inactive INT, @E1 INT, @E2 INT, @E3 INT, @User INT, @msg NVARCHAR(2000);
    EXEC #qa3_year_seed @Y OUTPUT, @Tiered OUTPUT, @Inactive OUTPUT, @E1 OUTPUT, @E2 OUTPUT, @E3 OUTPUT, @User OUTPUT;
    DECLARE @o TABLE (LeaveTypeName NVARCHAR(60), EmployeesOpened INT, DaysGranted DECIMAL(9,2), ProratedEmployees INT, DaysCarriedOver DECIMAL(9,2), DaysExpired DECIMAL(9,2));
    INSERT INTO @o EXEC hr.usp_LeaveYear_Open @Year = @Y, @ActedByUserId = @User, @EmployeeId = @E1, @CarryOverMaxDays = 5;
    INSERT INTO @o EXEC hr.usp_LeaveYear_Open @Year = @Y, @ActedByUserId = @User, @EmployeeId = @E2, @CarryOverMaxDays = 5;
    INSERT INTO @o EXEC hr.usp_LeaveYear_Open @Year = @Y, @ActedByUserId = @User, @EmployeeId = @E3, @CarryOverMaxDays = 5;
    DECLARE @PrevDec CHAR(7) = CONCAT(@Y - 1, '-12'), @Jan CHAR(7) = CONCAT(@Y, '-01'), @Dec31 DATE = DATEFROMPARTS(@Y - 1, 12, 31);

    /* LEV-1: E1's close is -7 on 31 December last year; the carry (5, the cap) and the entitlement (20) are in January */
    IF NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1 AND LeaveTypeId = @Tiered AND MovementType = 'Adjustment'
                     AND PeriodYearMonth = @PrevDec AND EffectiveDate = @Dec31 AND Days = -7 AND SourceType = 'LeaveYear' AND SourceRef = @Y)
       OR NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1 AND LeaveTypeId = @Tiered AND MovementType = 'CarryOver'
                        AND PeriodYearMonth = @Jan AND Days = 5)
       OR NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1 AND LeaveTypeId = @Tiered AND MovementType = 'Accrual'
                        AND PeriodYearMonth = @Jan AND Days = 20)
    BEGIN
        SET @msg = CONCAT('FAIL year_close (LEV-1): E1 should have close -7 on ', CONVERT(CHAR(10), @Dec31, 23), ', carry 5 and entitlement 20 in ', @Jan, '; has: ',
                          (SELECT STRING_AGG(CONCAT(PeriodYearMonth, ' ', MovementType, ' ', Days), '; ') FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1 AND LeaveTypeId = @Tiered));
        RAISERROR(@msg, 16, 1);
    END
    /* the cards (hr.usp_Leave_GetBalanceByYear sums hr.vw_LEAVE_BALANCE over the year's periods): this year 20 + 5 = 25 (it
       used to be 18: the close was subtracted from the new year); last year 20 - 13 - 7 = 0 */
    DECLARE @r DECIMAL(7,2);
    SET @r = (SELECT SUM(Remaining) FROM hr.vw_LEAVE_BALANCE WHERE EmployeeId = @E1 AND LeaveTypeId = @Tiered AND PeriodYearMonth BETWEEN @Jan AND CONCAT(@Y, '-12'));
    IF @r <> 25 BEGIN SET @msg = CONCAT('FAIL year_close (LEV-1): this year''s card for E1 should be 25; got ', @r); RAISERROR(@msg, 16, 1); END
    SET @r = (SELECT SUM(Remaining) FROM hr.vw_LEAVE_BALANCE WHERE EmployeeId = @E1 AND LeaveTypeId = @Tiered AND PeriodYearMonth BETWEEN CONCAT(@Y - 1, '-01') AND @PrevDec);
    IF @r <> 0 BEGIN SET @msg = CONCAT('FAIL year_close (LEV-1): last year''s card for E1 should end at 0 once closed; got ', @r); RAISERROR(@msg, 16, 1); END
    IF (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1 AND LeaveTypeId = @Tiered) <> 25
        RAISERROR('FAIL year_close (LEV-1): the all-time balance and this year''s card disagree.', 16, 1);

    /* LEV-12: E2 has 4 whole years at 1 January -> the 1-year tier, 10 days (not 20) */
    IF NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E2 AND LeaveTypeId = @Tiered AND MovementType = 'Accrual' AND PeriodYearMonth = @Jan AND Days = 10)
    BEGIN
        SET @msg = CONCAT('FAIL year_close (LEV-12): hired 15 January five years ago is 4 whole years: 10 days; got ',
                          ISNULL((SELECT CAST(SUM(Days) AS VARCHAR(20)) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E2 AND LeaveTypeId = @Tiered AND MovementType = 'Accrual'), 'none'));
        RAISERROR(@msg, 16, 1);
    END
    /* LEV-9: E3 has no tier yet: the opening row says so at 0 days, and last year's 3 days are closed and carried */
    IF NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E3 AND LeaveTypeId = @Tiered AND MovementType = 'Accrual' AND PeriodYearMonth = @Jan
                     AND Days = 0 AND Note LIKE N'Annual entitlement ' + CAST(@Y AS NVARCHAR(4)) + N': no tier%')
       OR (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E3 AND LeaveTypeId = @Tiered AND MovementType = 'Adjustment' AND PeriodYearMonth = @PrevDec) <> -3
       OR (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E3 AND LeaveTypeId = @Tiered AND MovementType = 'CarryOver' AND PeriodYearMonth = @Jan) <> 3
    BEGIN
        SET @msg = CONCAT('FAIL year_close (LEV-9): E3 (no tier) should get a 0-day opening, close -3 and carry 3; has: ',
                          (SELECT STRING_AGG(CONCAT(PeriodYearMonth, ' ', MovementType, ' ', Days), '; ') FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E3 AND LeaveTypeId = @Tiered));
        RAISERROR(@msg, 16, 1);
    END
    /* LEV-13: the inactive type was granted to nobody */
    IF EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE LeaveTypeId = @Inactive)
        RAISERROR('FAIL year_close (LEV-13): a deactivated leave type was granted at year open.', 16, 1);

    /* LEV-9: a second run writes nothing */
    DECLARE @rows INT = (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE EmployeeId IN (@E1, @E2, @E3));
    DELETE FROM @o;
    INSERT INTO @o EXEC hr.usp_LeaveYear_Open @Year = @Y, @ActedByUserId = @User, @EmployeeId = @E1, @CarryOverMaxDays = 5;
    INSERT INTO @o EXEC hr.usp_LeaveYear_Open @Year = @Y, @ActedByUserId = @User, @EmployeeId = @E3, @CarryOverMaxDays = 5;
    IF (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE EmployeeId IN (@E1, @E2, @E3)) <> @rows OR EXISTS (SELECT 1 FROM @o)
        RAISERROR('FAIL year_close (LEV-9): opening the year a second time wrote rows again.', 16, 1);

    /* LEV-9: undo E1, then open again: the same rows come back, once */
    DECLARE @before NVARCHAR(1000) = (SELECT STRING_AGG(CONCAT(PeriodYearMonth, ' ', MovementType, ' ', Days), '; ') WITHIN GROUP (ORDER BY PeriodYearMonth, MovementType)
                                      FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1);
    DECLARE @u TABLE (EmployeesUndone INT, MovementsRemoved INT);
    INSERT INTO @u EXEC hr.usp_LeaveYear_Undo @Year = @Y, @ActedByUserId = @User, @EmployeeId = @E1;
    IF EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1 AND SourceType = 'LeaveYear' AND SourceRef = @Y)
       OR (SELECT EmployeesUndone FROM @u) <> 1
        RAISERROR('FAIL year_close (undo): the opening rows of E1 are still there after the undo.', 16, 1);
    IF (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E3) = 0
        RAISERROR('FAIL year_close (undo): undoing E1 touched E3.', 16, 1);
    INSERT INTO @o EXEC hr.usp_LeaveYear_Open @Year = @Y, @ActedByUserId = @User, @EmployeeId = @E1, @CarryOverMaxDays = 5;
    IF (SELECT STRING_AGG(CONCAT(PeriodYearMonth, ' ', MovementType, ' ', Days), '; ') WITHIN GROUP (ORDER BY PeriodYearMonth, MovementType)
        FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1) <> @before
    BEGIN
        SET @msg = CONCAT('FAIL year_close (undo): after undo + open E1 should have ', @before, '; has ',
                          (SELECT STRING_AGG(CONCAT(PeriodYearMonth, ' ', MovementType, ' ', Days), '; ') WITHIN GROUP (ORDER BY PeriodYearMonth, MovementType)
                           FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1));
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

/* ---------------- phase 2: the undo is refused once leave of the year was used in a paid period ---------------- */
BEGIN TRAN;
BEGIN TRY
    DECLARE @Y INT, @Tiered INT, @Inactive INT, @E1 INT, @E2 INT, @E3 INT, @User INT, @msg NVARCHAR(2000), @err NVARCHAR(2000);
    EXEC #qa3_year_seed @Y OUTPUT, @Tiered OUTPUT, @Inactive OUTPUT, @E1 OUTPUT, @E2 OUTPUT, @E3 OUTPUT, @User OUTPUT;
    DECLARE @o TABLE (LeaveTypeName NVARCHAR(60), EmployeesOpened INT, DaysGranted DECIMAL(9,2), ProratedEmployees INT, DaysCarriedOver DECIMAL(9,2), DaysExpired DECIMAL(9,2));
    INSERT INTO @o EXEC hr.usp_LeaveYear_Open @Year = @Y, @ActedByUserId = @User, @EmployeeId = @E1, @CarryOverMaxDays = 5;
    /* a month of this year paid for E1: an approved Primary run of the year if there is one, else a new one for a month
       that has no live Primary */
    DECLARE @Run INT, @Paid CHAR(7);
    SELECT TOP 1 @Run = PayrollRunId, @Paid = PeriodYearMonth FROM payroll.PAYROLL_RUN
    WHERE RunType = 'Primary' AND [Status] = 'Approved' AND LEFT(PeriodYearMonth, 4) = CAST(@Y AS CHAR(4)) ORDER BY PeriodYearMonth;
    IF @Run IS NULL
    BEGIN
        SELECT TOP 1 @Paid = m.Ym
        FROM (SELECT CONCAT(@Y, '-', RIGHT(CONCAT('0', v.n), 2)) AS Ym FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12)) v(n)) m
        WHERE NOT EXISTS (SELECT 1 FROM payroll.PAYROLL_RUN r WHERE r.PeriodYearMonth = m.Ym AND r.RunType = 'Primary' AND r.[Status] <> 'Cancelled')
        ORDER BY m.Ym;
        IF @Paid IS NOT NULL
        BEGIN
            INSERT INTO payroll.PAYROLL_RUN (PeriodYearMonth, PeriodStart, PeriodEnd, PrimaryCurrency, Notes, CreatedByUserId, RunType, [Status])
            VALUES (@Paid, CAST(@Paid + '-01' AS DATE), EOMONTH(CAST(@Paid + '-01' AS DATE)), 'USD', N'QA3 paid month', @User, 'Primary', 'Approved');
            SET @Run = SCOPE_IDENTITY();
        END
    END
    IF @Run IS NULL
        PRINT 'year_close: note: no month of this year could be marked paid on this database; the paid-period refusal is not checked.';
    ELSE
    BEGIN
        INSERT INTO payroll.PAYSLIP (PayrollRunId, EmployeeId, EmployeeName) VALUES (@Run, @E1, N'QA3 Year E1');
        DECLARE @UseDate DATE = DATEADD(DAY, 9, CAST(@Paid + '-01' AS DATE));
        INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note)
        VALUES (@E1, @Tiered, @Paid, 'Usage', -2, @UseDate, N'QA3 leave in a paid month');
        DECLARE @u TABLE (EmployeesUndone INT, MovementsRemoved INT);
        BEGIN TRY
            INSERT INTO @u EXEC hr.usp_LeaveYear_Undo @Year = @Y, @ActedByUserId = @User, @EmployeeId = @E1;
        END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
        IF @err IS NULL OR @err NOT LIKE N'%cannot be undone: QA3 Year E1 took leave in ' + @Paid + N', a period already paid%'
        BEGIN
            SET @msg = CONCAT('FAIL year_close (undo, paid): the undo must be refused naming QA3 Year E1 and ', @Paid, '; got: ', ISNULL(@err, 'done'));
            RAISERROR(@msg, 16, 1);
        END
        IF NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1 AND SourceType = 'LeaveYear' AND SourceRef = @Y)
            RAISERROR('FAIL year_close (undo, paid): the refused undo removed rows.', 16, 1);
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

IF EXISTS (SELECT 1 FROM #qa3_fail) RAISERROR('year_close: FAILED (see above).', 16, 1);
ELSE PRINT 'ok year_close';
DROP PROCEDURE #qa3_year_seed;
GO
