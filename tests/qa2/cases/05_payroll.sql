/* ============================================================================
   cases/05_payroll.sql — A5 (payroll), plus the cases of the other areas that need a payroll run or the period
   close: A1l (locked period), A3i (leave payout on termination), A3j (exit-permission conversion).

   WHY A ROLLED-BACK TRANSACTION: the real database holds a locked primary run for M and the table allows one
   live primary per period. Inside ONE transaction that is rolled back at the end, the real run is marked
   Cancelled, the real attendance of M is completed so the readiness gate passes, and the QA2 run is created,
   generated, reviewed and locked. Nothing is persisted. Variants are taken with savepoints. The REFUSAL cases come
   LAST: a refusal caught in a transaction whose procedures SET XACT_ABORT ON leaves it uncommittable (reads still
   work, so the remaining refusals can still be asked for).

   Figures: StandardWorkingDaysPerMonth 26 -> day rate = basic / 26 (1300 -> 50.0000). QA2 Morning standard 450 min.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO

/* ---------------------------------------------------------------- 0. fixtures that are raised like any request (committed; cleanup removes them) ---- */
DECLARE @M DATE = CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month') + '-01' AS DATE);
DECLARE @Hr INT = dbo.QA2_User(N'hr'), @E9 INT = dbo.QA2_Emp(N'E9'), @E10 INT = dbo.QA2_Emp(N'E10'), @rid INT, @f DATE, @t DATE, @msg NVARCHAR(600);
/* A5c: unpaid leave over the month end — the last 3 days of M and the first 2 of M+1 (E10 is rostered every day) */
SET @f = DATEADD(DAY, -2, EOMONTH(@M)); SET @t = DATEADD(DAY, 2, EOMONTH(@M));
BEGIN TRY
    EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E10, @RaisedByUserId = @Hr, @LeaveTypeId = 3, @FromDate = @f, @ToDate = @t, @Reason = N'QA2 A5c unpaid leave';
    SET @rid = dbo.QA2_LastRequest(@E10); EXEC dbo.QA2_Approve @rid, 'Leave';
    EXEC dbo.QA2_ComputeRange @E10, @f, @t;
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @msg = CONCAT('A5c fixture: ', ERROR_MESSAGE()); EXEC dbo.QA2_Note @msg; END CATCH;
/* A5d: an approved advance of 5000 recovered at 2000 a month from M. The request procedure refuses a first deduction in a
   month whose payroll is locked (the real M is), so it is raised for the current month and the QA2 advance row is then
   moved to M — the state an advance raised in time would be in. */
DECLARE @Now CHAR(7) = CONVERT(CHAR(7), CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE), 23), @MChar CHAR(7) = CONVERT(CHAR(7), @M, 23);
BEGIN TRY
    EXEC workflow.usp_SalaryAdvance_Create @EmployeeId = @E9, @RaisedByUserId = @Hr, @Amount = 5000, @CurrencyCode = 'USD', @MonthlyDeduction = 2000, @FirstDeductionPeriod = @Now, @Reason = N'QA2 A5d';
    SET @rid = dbo.QA2_LastRequest(@E9); EXEC dbo.QA2_Approve @rid, 'Advance', @Amount = 5000;
    UPDATE payroll.SALARY_ADVANCE SET FirstDeductionPeriod = @MChar WHERE EmployeeId = @E9;
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @msg = CONCAT('A5d fixture: ', ERROR_MESSAGE()); EXEC dbo.QA2_Note @msg; END CATCH;
SET @msg = CONCAT('payroll fixtures: E10 unpaid leave ', CONVERT(CHAR(10), @f, 23), '..', CONVERT(CHAR(10), @t, 23), ' = ',
                  ISNULL((SELECT TOP 1 ri.[Status] FROM workflow.LEAVE_REQUEST lr JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId WHERE lr.EmployeeId = @E10 AND lr.LeaveTypeId = 3), 'none'),
                  '; E9 advance = ', ISNULL((SELECT TOP 1 CONCAT(Amount, ' at ', MonthlyDeduction, '/month from ', FirstDeductionPeriod) FROM payroll.SALARY_ADVANCE WHERE EmployeeId = @E9), 'none'));
EXEC dbo.QA2_Note @msg;
GO

/* ---------------------------------------------------------------- the transaction ---- */
DECLARE @res TABLE (Seq INT IDENTITY(1,1), Id NVARCHAR(20), [Case] NVARCHAR(400), Expected NVARCHAR(700), Actual NVARCHAR(700), Pass BIT);
DECLARE @notes TABLE (Seq INT IDENTITY(1,1), T NVARCHAR(MAX));
DECLARE @M DATE = CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month') + '-01' AS DATE);
DECLARE @MEnd DATE = EOMONTH(@M), @MChar CHAR(7) = CONVERT(CHAR(7), @M, 23), @DaysInM INT = DAY(EOMONTH(@M));
DECLARE @Hr INT = dbo.QA2_User(N'hr'), @Owner INT = dbo.QA2_User(N'owner');
DECLARE @B1 INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA2 Branch 1'), @B2 INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA2 Branch 2');
DECLARE @E1 INT = dbo.QA2_Emp(N'E1'), @E2 INT = dbo.QA2_Emp(N'E2'), @E4 INT = dbo.QA2_Emp(N'E4'), @E5 INT = dbo.QA2_Emp(N'E5'), @E6 INT = dbo.QA2_Emp(N'E6'),
        @E7 INT = dbo.QA2_Emp(N'E7'), @E8 INT = dbo.QA2_Emp(N'E8'), @E9 INT = dbo.QA2_Emp(N'E9'), @E10 INT = dbo.QA2_Emp(N'E10'), @E11 INT = dbo.QA2_Emp(N'E11');
DECLARE @Tips INT = (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE Name = N'Tips');
DECLARE @exp NVARCHAR(700), @act NVARCHAR(700), @ok BIT, @n INT, @n2 INT, @a1 DECIMAL(18,2), @a2 DECIMAL(18,2), @a3 DECIMAL(18,2), @RunId INT, @SupId INT, @d DATE, @err NVARCHAR(400);
DECLARE @gen TABLE (PayrollRunId INT, PayslipCount INT, PayslipsWithWarnings INT);
DECLARE @rv TABLE (PayrollRunId INT, [Status] VARCHAR(12));
DECLARE @ap TABLE (PayrollRunId INT, [Status] VARCHAR(12), LockedAt DATETIME2);
DECLARE @ready TABLE (PeriodYearMonth CHAR(7), PeriodStart DATE, PeriodEnd DATE, UnprocessedPunches INT, UnresolvedPinPunches INT, OpenAnomalies INT,
                      PendingCorrections INT, RosteredDaysWithNoRecord INT, UndecidedExitVariances INT, UndecidedAnomalies INT, IsReady BIT);
DECLARE @bulk TABLE (EmployeesGiven INT);

BEGIN TRY
    BEGIN TRAN;

    /* ---- P0: the state a payroll officer starts from ---- */
    UPDATE payroll.PAYROLL_RUN SET [Status] = 'Cancelled' WHERE PeriodYearMonth = @MChar AND [Status] <> 'Cancelled';     -- the real runs of M, inside this transaction only
    SET @d = @M; WHILE @d <= @MEnd BEGIN EXEC attendance.usp_Attendance_MarkAbsentees @WorkDate = @d; SET @d = DATEADD(DAY, 1, @d); END
    /* what HR still has to decide on REAL data is set aside here (rolled back); the QA2 rest is decided the way each case needs */
    UPDATE a SET a.ExitVarianceDisposition = 'Ignore' FROM attendance.ATTENDANCE_RECORD a JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
    WHERE a.WorkDate BETWEEN @M AND @MEnd AND a.ExitVarianceMinutes > 0 AND a.ExitVarianceDisposition IS NULL;
    UPDATE an SET an.Decision = 'Excused', an.Note = N'QA2: set aside inside a rolled-back transaction' FROM attendance.ATTENDANCE_ANOMALY an JOIN hr.EMPLOYEE e ON e.EmployeeId = an.EmployeeId
    WHERE an.WorkDate BETWEEN @M AND @MEnd AND an.Decision IS NULL AND e.FullName NOT LIKE N'QA2 %';
    UPDATE a SET a.HasAnomaly = 0 FROM attendance.ATTENDANCE_RECORD a JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
    WHERE a.WorkDate BETWEEN @M AND @MEnd AND a.HasAnomaly = 1 AND e.FullName NOT LIKE N'QA2 %';
    /* A5i: E11's half-day absence is DEDUCTED (half a day, exactly); everything else still undecided on QA2 data is excused */
    DECLARE @halfAn BIGINT = (SELECT TOP 1 AnomalyId FROM attendance.ATTENDANCE_ANOMALY WHERE EmployeeId = @E11 AND [Type] = 'HalfDayAbsence' AND Decision IS NULL);
    IF @halfAn IS NOT NULL EXEC attendance.usp_Anomaly_Decide @AnomalyId = @halfAn, @Decision = 'Deduct', @Note = N'QA2 A5i', @DecidedByUserId = @Hr;
    EXEC attendance.usp_Anomaly_DecideAll @PeriodYearMonth = @MChar, @Decision = 'Excuse', @BranchId = @B1, @Note = N'QA2 payroll', @DecidedByUserId = @Hr;
    EXEC attendance.usp_Anomaly_DecideAll @PeriodYearMonth = @MChar, @Decision = 'Excuse', @BranchId = @B2, @Note = N'QA2 payroll', @DecidedByUserId = @Hr;
    INSERT INTO @ready EXEC attendance.usp_Attendance_PayrollReadiness @MChar;
    SELECT @act = CONCAT('unprocessed=', UnprocessedPunches, ' unresolved=', UnresolvedPinPunches, ' anomalies=', OpenAnomalies, ' corrections=', PendingCorrections, ' missingDays=', RosteredDaysWithNoRecord,
                         ' variances=', UndecidedExitVariances, ' undecidedAnomalies=', UndecidedAnomalies, ' ready=', IsReady), @ok = IsReady FROM @ready;
    INSERT INTO @res SELECT 'P0', 'attendance readiness for M with the QA2 anomalies decided (real leftovers set aside inside the transaction)', 'ready=1', @act, @ok;

    /* ---- A5l: the readiness gates look at days up to today only — an unknown-PIN punch on the 20th ---- */
    DECLARE @Dev INT = (SELECT DeviceId FROM attendance.DEVICE WHERE SerialNumber = 'QA2-DEVICE-001'), @u0 INT, @u10 INT, @u25 INT, @p20 DATETIME2 = DATEADD(HOUR, 8, CAST(DATEADD(DAY, 19, @M) AS DATETIME2));
    SELECT @u0 = UnresolvedPinPunches FROM @ready; DELETE FROM @ready;
    INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash) VALUES (@Dev, 'Q2ZZZ', NULL, @p20, 0, 'QA2', 'QA2-A5L-UNKNOWN-PUNCH');
    DECLARE @asOf10 DATE = DATEADD(DAY, 9, @M), @asOf25 DATE = DATEADD(DAY, 24, @M);
    INSERT INTO @ready EXEC attendance.usp_Attendance_PayrollReadiness @MChar, @asOf10; SELECT @u10 = UnresolvedPinPunches FROM @ready; DELETE FROM @ready;
    INSERT INTO @ready EXEC attendance.usp_Attendance_PayrollReadiness @MChar, @asOf25; SELECT @u25 = UnresolvedPinPunches, @ok = IsReady FROM @ready; DELETE FROM @ready;
    INSERT INTO @res SELECT 'A5l', 'readiness with an unknown-PIN punch on the 20th: asked on the 10th and on the 25th of the month', 'on the 10th the punch is a day still to come (count unchanged, does not block); on the 25th it blocks (count + 1, not ready)',
        CONCAT('unresolved before=', @u0, '; as of the 10th=', @u10, '; as of the 25th=', @u25, ' ready=', @ok), CASE WHEN @u10 = @u0 AND @u25 = @u0 + 1 AND @ok = 0 THEN 1 ELSE 0 END;
    DELETE FROM attendance.RAW_DEVICE_LOG WHERE DedupHash = 'QA2-A5L-UNKNOWN-PUNCH';

    /* ---- A5f: a supplemental BEFORE the primary exists pays only its adjustments; the primary leaves them out ---- */
    INSERT INTO @bulk EXEC payroll.usp_Adjustment_CreateBulk @ComponentTypeId = @Tips, @Amount = 40, @CurrencyCode = 'USD', @TargetPeriod = @MChar, @Reason = N'QA2 early bonus', @CreatedByUserId = @Owner, @BranchId = @B1;
    DECLARE @bonusN INT = (SELECT COUNT(*) FROM payroll.PAYROLL_ADJUSTMENT WHERE Reason = N'QA2 early bonus');
    EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = @MChar, @CreatedByUserId = @Hr, @Notes = N'QA2 supplemental first', @RunType = 'Supplemental';
    SET @SupId = (SELECT MAX(PayrollRunId) FROM payroll.PAYROLL_RUN WHERE Notes = N'QA2 supplemental first');
    INSERT INTO @gen EXEC payroll.usp_PayrollRun_GenerateSupplemental @PayrollRunId = @SupId, @ActedByUserId = @Hr;

    /* the family deduction is a real setting row: changed here, rolled back with everything else.
       5640 puts E9's annual taxable income EXACTLY on the first bracket boundary: (1000 - 30) x 12 - 5640 = 6000 */
    UPDATE core.SETTING SET SettingValue = '5640' WHERE SettingKey = 'TaxFamilyDeductionAnnualUsd';
    EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = @MChar, @CreatedByUserId = @Hr, @Notes = N'QA2 primary', @RunType = 'Primary';
    SET @RunId = (SELECT MAX(PayrollRunId) FROM payroll.PAYROLL_RUN WHERE Notes = N'QA2 primary');
    IF @RunId IS NULL RAISERROR('usp_PayrollRun_Create did not create the QA2 primary', 16, 1);
    DELETE FROM @gen; INSERT INTO @gen EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @RunId, @ActedByUserId = @Hr;
    SELECT @n = COUNT(*), @n2 = SUM(CASE WHEN l.SourceType <> 'Adjustment' THEN 1 ELSE 0 END) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @SupId;
    DECLARE @inPrimary INT = (SELECT COUNT(*) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @RunId AND l.SourceType = 'Adjustment' AND l.Note = N'QA2 early bonus');
    INSERT INTO @res SELECT 'A5f', 'a supplemental created before the primary is locked (here: before it exists); then the primary is generated', CONCAT(@bonusN, ' adjustment lines and nothing else on the supplemental; 0 of them on the primary'),
        CONCAT(@n, ' line(s) on the supplemental of which ', @n2, ' are not adjustments; ', @inPrimary, ' on the primary'), CASE WHEN @bonusN > 0 AND @n = @bonusN AND @n2 = 0 AND @inPrimary = 0 THEN 1 ELSE 0 END;

    /* ---- A5g (part 1): tax exactly on a bracket boundary ---- */
    SELECT @a1 = SUM(l.Amount) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @RunId AND ps.EmployeeId = @E9 AND l.ComponentName = N'Income Tax';
    SELECT @a2 = SUM(l.Amount) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @RunId AND ps.EmployeeId = @E9 AND l.ComponentName = N'NSSF Employee Share';
    INSERT INTO @res SELECT 'A5g1', 'tax on a bracket boundary: E9 basic 1000, NSSF 30, family deduction 5640 -> annual taxable exactly 6000.00', 'NSSF 30.00; tax = 6000 x 2 % / 12 = 10.00 (nothing from the 4 % bracket that STARTS at 6000)',
        CONCAT('NSSF ', @a2, '; tax ', @a1), CASE WHEN @a2 = 30.00 AND @a1 = 10.00 THEN 1 ELSE 0 END;

    /* ---- A5h: the exchange rate changes after the run was created; then the run is regenerated with the law's deduction of 3000 ---- */
    DECLARE @rate0 DECIMAL(28,12) = payroll.fn_RunRate(@RunId, 'LBP', 'USD');
    /* one row per currency pair and rate type (UX_EXCHANGE_RATE_Pair): "a new rate" is that row changing — rolled back with the rest */
    UPDATE core.EXCHANGE_RATE SET Rate = 95000 WHERE FromCurrency = 'USD' AND ToCurrency = 'LBP' AND RateType = (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'PayrollRateType');
    UPDATE core.SETTING SET SettingValue = '3000' WHERE SettingKey = 'TaxFamilyDeductionAnnualUsd';
    DELETE FROM @gen; INSERT INTO @gen EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @RunId, @ActedByUserId = @Hr;
    DECLARE @rate1 DECIMAL(28,12) = payroll.fn_RunRate(@RunId, 'LBP', 'USD');
    DECLARE @lbpUsd DECIMAL(18,2) = payroll.fn_ToPrimary(@RunId, 27000000, 'LBP');
    INSERT INTO @res SELECT 'A5h', 'a new USD->LBP rate (95,000) is recorded after the run was created, and the run is regenerated', 'the run keeps the rate it froze at creation; the LBP allowance converts as before',
        CONCAT('run rate LBP->USD ', @rate0, ' before, ', @rate1, ' after; 27,000,000 LBP = ', @lbpUsd, ' USD'), CASE WHEN @rate0 = @rate1 AND @rate0 > 0 THEN 1 ELSE 0 END;

    /* every QA2 line of the primary, once */
    IF OBJECT_ID('tempdb..#L') IS NOT NULL DROP TABLE #L;
    SELECT ps.EmployeeId, e.FullName, ps.PayslipId, l.ComponentName, l.Category, l.[Sign], l.Amount, l.CurrencyCode, l.SourceType, l.Quantity, l.UnitAmount, l.Note
    INTO #L FROM payroll.PAYSLIP ps JOIN hr.EMPLOYEE e ON e.EmployeeId = ps.EmployeeId AND e.FullName LIKE N'QA2 %'
    JOIN payroll.PAYSLIP_LINE l ON l.PayslipId = ps.PayslipId WHERE ps.PayrollRunId = @RunId;

    /* ---- A5a: hired the 12th, terminated the 20th ---- */
    SELECT @a1 = SUM(Amount) FROM #L WHERE EmployeeId = @E5 AND ComponentName = N'Basic Salary';
    SET @a2 = ROUND(1300.0 * 9 / @DaysInM, 2);
    SELECT @act = CONCAT('basic ', @a1, ' (', (SELECT TOP 1 Note FROM #L WHERE EmployeeId = @E5 AND ComponentName = N'Basic Salary'), '); leave payout ',
                         ISNULL(CAST((SELECT SUM(Amount) FROM #L WHERE EmployeeId = @E5 AND ComponentName = N'Leave Balance Payout') AS VARCHAR(20)), 'no line'),
                         '; indemnity lines ', (SELECT COUNT(*) FROM #L WHERE EmployeeId = @E5 AND ComponentName = N'End-of-Service Indemnity'));
    INSERT INTO @res SELECT 'A5a', 'E5 hired on the 12th and terminated on the 20th of the same month, basic 1300, 6.5 days of leave left, no Separation request',
        CONCAT('basic prorated 9/', @DaysInM, ' = ', @a2, ' with the proration said on the line; leave balance payout 6.5 x 50 = 325.00; no indemnity line'), @act,
        CASE WHEN @a1 = @a2 AND (SELECT SUM(Amount) FROM #L WHERE EmployeeId = @E5 AND ComponentName = N'Leave Balance Payout') = 325.00
                  AND NOT EXISTS (SELECT 1 FROM #L WHERE EmployeeId = @E5 AND ComponentName = N'End-of-Service Indemnity')
                  AND EXISTS (SELECT 1 FROM #L WHERE EmployeeId = @E5 AND ComponentName = N'Basic Salary' AND Note LIKE N'%rorated%') THEN 1 ELSE 0 END;

    /* ---- A5b: basic 1500 -> 1800 from the 16th ---- */
    SELECT @a1 = SUM(Amount), @n = COUNT(*) FROM #L WHERE EmployeeId = @E8 AND ComponentName = N'Basic Salary';
    SET @a2 = ROUND(1500.0 * 15 / @DaysInM, 2) + ROUND(1800.0 * (@DaysInM - 15) / @DaysInM, 2);
    INSERT INTO @res SELECT 'A5b', 'E8 basic 1500 until the 15th, 1800 from the 16th', CONCAT('prorated by days: 1500 x 15/', @DaysInM, ' + 1800 x ', @DaysInM - 15, '/', @DaysInM, ' = ', @a2, ' on two lines'),
        CONCAT(@n, ' basic line(s) totalling ', @a1, ': ', (SELECT STRING_AGG(CONCAT(Amount, ' [', ISNULL(Note, ''), ']'), '; ') FROM #L WHERE EmployeeId = @E8 AND ComponentName = N'Basic Salary')), CASE WHEN @a1 = @a2 AND @n = 2 THEN 1 ELSE 0 END;

    /* ---- A5c: unpaid leave over the month end ---- */
    SELECT @a1 = SUM(Quantity), @a2 = SUM(Amount) FROM #L WHERE EmployeeId = @E10 AND ComponentName = N'Unpaid Leave Deduction' AND SourceType = 'Leave';
    DECLARE @nextUse DECIMAL(6,2) = (SELECT -SUM(l.Days) FROM hr.LEAVE_LEDGER l WHERE l.EmployeeId = @E10 AND l.LeaveTypeId = 3 AND l.MovementType = 'Usage' AND l.PeriodYearMonth = CONVERT(CHAR(7), DATEADD(MONTH, 1, @M), 23));
    INSERT INTO @res SELECT 'A5c', 'E10 unpaid leave from the third-last day of M to the 2nd of M+1', '3 unpaid days deducted in M (3 x 50 = 150.00); the other 2 belong to M+1',
        CONCAT('M: ', @a1, ' day(s), ', @a2, '; ledger usage posted to M+1: ', ISNULL(CAST(@nextUse AS VARCHAR(10)), 'none')), CASE WHEN @a1 = 3 AND @a2 = 150.00 AND @nextUse = 2 THEN 1 ELSE 0 END;

    /* ---- A5d: an instalment larger than the net ---- */
    DECLARE @netE9 DECIMAL(18,2) = (SELECT NetUsd FROM payroll.PAYSLIP WHERE PayrollRunId = @RunId AND EmployeeId = @E9);
    SELECT @a1 = SUM(Amount) FROM #L WHERE EmployeeId = @E9 AND ComponentName = N'Advance Repayment';
    SELECT @a2 = SUM(CASE WHEN Category = 'Earning' THEN Amount WHEN Category = 'Deduction' AND ComponentName <> N'Advance Repayment' THEN -Amount ELSE 0 END) FROM #L WHERE EmployeeId = @E9 AND CurrencyCode = 'USD';
    INSERT INTO @res SELECT 'A5d', 'E9 (basic 1000) repays an advance at 2000 a month', CONCAT('the instalment is capped at the net before it (', @a2, '): net 0.00, never negative; the line says what is carried to the next run'),
        CONCAT('instalment ', @a1, '; net ', @netE9, '; note: ', (SELECT TOP 1 Note FROM #L WHERE EmployeeId = @E9 AND ComponentName = N'Advance Repayment')),
        CASE WHEN @a1 = @a2 AND @netE9 = 0.00 AND EXISTS (SELECT 1 FROM #L WHERE EmployeeId = @E9 AND ComponentName = N'Advance Repayment' AND Note LIKE N'%carried%') THEN 1 ELSE 0 END;

    /* ---- A5g (part 2): USD basic 2000 + LBP allowance 27,000,000, family deduction 3000 ---- */
    DECLARE @base DECIMAL(18,2) = 2000 + @lbpUsd;
    DECLARE @nssfE DECIMAL(18,2) = ROUND(CASE WHEN @base > 2500 THEN 2500 ELSE @base END * 0.03, 2);
    DECLARE @nssfR DECIMAL(18,2) = ROUND(CASE WHEN @base > 2500 THEN 2500 ELSE @base END * 0.14 + @base * 0.085, 2);
    DECLARE @taxable DECIMAL(18,2) = (@base - @nssfE) * 12 - 3000;
    DECLARE @tax DECIMAL(18,2) = ROUND((6000 * 0.02 + 9000 * 0.04 + (@taxable - 15000) * 0.07) / 12, 2);        -- the taxable figure lies in the third bracket
    SELECT @a1 = SUM(CASE WHEN ComponentName = N'NSSF Employee Share' THEN Amount END), @a2 = SUM(CASE WHEN ComponentName = N'NSSF Employer Share' THEN Amount END),
           @a3 = SUM(CASE WHEN ComponentName = N'Income Tax' THEN Amount END) FROM #L WHERE EmployeeId = @E7;
    INSERT INTO @res SELECT 'A5g2', 'E7 USD basic 2000 + LBP allowance 27,000,000 at the run''s frozen rate, TaxFamilyDeductionAnnualUsd 3000',
        CONCAT('base ', @base, '; employee NSSF 3 % of min(base, 2500) = ', @nssfE, '; employer 8 % + 6 % on the ceilinged base and EOSI 8.5 % on the full base = ', @nssfR, '; tax on ', @taxable, ' = ', @tax),
        CONCAT('employee NSSF ', @a1, '; employer ', @a2, '; tax ', @a3), CASE WHEN @taxable BETWEEN 15000 AND 30000 AND @a1 = @nssfE AND @a2 = @nssfR AND @a3 = @tax THEN 1 ELSE 0 END;

    /* ---- A5i: what is never deducted, and what is deducted exactly ---- */
    SELECT @a1 = SUM(Amount) FROM #L WHERE EmployeeId = @E1 AND Category = 'Deduction' AND SourceType = 'Attendance';
    SELECT @a2 = SUM(Amount) FROM #L WHERE EmployeeId = @E11 AND Category = 'Deduction' AND SourceType = 'Attendance';
    DECLARE @otE1 NVARCHAR(100) = (SELECT STRING_AGG(CAST(CAST(Quantity AS INT) AS VARCHAR(10)), '+') WITHIN GROUP (ORDER BY Quantity) FROM #L WHERE EmployeeId = @E1 AND SourceType = 'Overtime' AND ComponentName = N'Overtime');
    DECLARE @unbalanced INT = (SELECT COUNT(*) FROM payroll.PAYSLIP ps JOIN hr.EMPLOYEE e ON e.EmployeeId = ps.EmployeeId AND e.FullName LIKE N'QA2 %'
                               OUTER APPLY (SELECT SUM(CASE WHEN l.Category = 'Earning' AND l.CurrencyCode = 'USD' THEN l.Amount WHEN l.Category = 'Deduction' AND l.CurrencyCode = 'USD' THEN -l.Amount ELSE 0 END) AS U,
                                                   SUM(CASE WHEN l.Category = 'Earning' AND l.CurrencyCode = 'LBP' THEN l.Amount WHEN l.Category = 'Deduction' AND l.CurrencyCode = 'LBP' THEN -l.Amount ELSE 0 END) AS B
                                            FROM payroll.PAYSLIP_LINE l WHERE l.PayslipId = ps.PayslipId) s
                               WHERE ps.PayrollRunId = @RunId AND (ps.NetUsd <> ISNULL(s.U, 0) OR ps.NetLbp <> ISNULL(s.B, 0) OR ps.NetUsd < 0 OR ps.NetLbp < 0));
    INSERT INTO @res SELECT 'A5i', 'E1''s month: rest days, a holiday, a leave day, four days with exit permissions, four Excused anomalies and ONE Deducted late arrival of 20 min; E11: leave, half days, a Deducted half-day absence',
        'E1 loses exactly 20/450 of a day (2.22) and nothing else; E11 exactly half a day (25.00); overtime paid for the approved 60 and 240 minutes; for every QA2 payslip the lines add up to the net to the cent and no net is negative',
        CONCAT('E1 attendance deductions ', ISNULL(@a1, 0), '; E11 ', ISNULL(@a2, 0), '; E1 overtime minutes ', ISNULL(@otE1, 'none'), '; payslips whose lines do not equal the net (or negative): ', @unbalanced),
        CASE WHEN @a1 = 2.22 AND @a2 = 25.00 AND @otE1 = '60+240' AND @unbalanced = 0 THEN 1 ELSE 0 END;

    /* ---- A5k: the holiday-work premium ---- */
    SELECT @a1 = SUM(Amount), @a2 = SUM(Quantity) FROM #L WHERE EmployeeId = @E2 AND ComponentName = N'Holiday Work';
    DECLARE @hwRate DECIMAL(6,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'HolidayWorkRate') AS DECIMAL(6,2)), 2.0);
    INSERT INTO @res SELECT 'A5k', 'E2 worked the evening shift (450 min) on the public holiday of the branch; HolidayWorkRate 2.0', CONCAT('line "Holiday Work" = 450 min x (50 / 450) x (', @hwRate, ' - 1) = ', CAST(ROUND(50 * (@hwRate - 1), 2) AS DECIMAL(18,2))),
        CONCAT('amount ', ISNULL(CAST(@a1 AS VARCHAR(20)), 'no line'), ', minutes ', @a2), CASE WHEN @a1 = CAST(ROUND(50 * (@hwRate - 1), 2) AS DECIMAL(18,2)) AND @a2 = 450 THEN 1 ELSE 0 END;

    /* ---- A3i: leave payout on termination, and a negative balance ---- */
    SELECT @a1 = SUM(Amount) FROM #L WHERE EmployeeId = @E6 AND ComponentName = N'Leave Balance Payout';
    SAVE TRAN qa2_negative;
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note, CreatedBy) VALUES (@E5, 1, @MChar, 'Usage', -8, DATEADD(DAY, 12, @M), N'QA2 A3i: took more than was earned', @Hr);
    DELETE FROM @gen; INSERT INTO @gen EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @RunId, @ActedByUserId = @Hr;
    SELECT @a2 = SUM(l.Amount), @n = COUNT(*) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @RunId AND ps.EmployeeId = @E5 AND l.ComponentName = N'Leave Balance Deduction' AND l.Category = 'Deduction';
    ROLLBACK TRAN qa2_negative;
    INSERT INTO @res SELECT 'A3i', 'E6 leaves on the 20th with 6.5 unused days; E5 (in a variant) leaves with a balance of -1.5', 'E6: "Leave Balance Payout" 6.5 x 50 = 325.00 in the termination month; E5 negative: a deduction line of 1.5 x 50 = 75.00',
        CONCAT('E6 payout ', ISNULL(CAST(@a1 AS VARCHAR(20)), 'no line'), '; E5 with -1.5: ', ISNULL(CAST(@a2 AS VARCHAR(20)), 'no deduction line')), CASE WHEN @a1 = 325.00 AND @a2 = 75.00 AND @n = 1 THEN 1 ELSE 0 END;

    /* ---- A5j: terminated in M-1 -> absent from M; rehired in M -> present with the new hire date ---- */
    SAVE TRAN qa2_rehire;
    UPDATE hr.EMPLOYEE SET TerminationDate = DATEADD(DAY, -1, @M) WHERE EmployeeId = @E4;
    DELETE FROM @gen; INSERT INTO @gen EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @RunId, @ActedByUserId = @Hr;
    SET @n = (SELECT COUNT(*) FROM payroll.PAYSLIP WHERE PayrollRunId = @RunId AND EmployeeId = @E4);
    UPDATE hr.EMPLOYEE SET HireDate = DATEADD(DAY, 9, @M), TerminationDate = NULL WHERE EmployeeId = @E4;                         -- rehired on the 10th
    DELETE FROM @gen; INSERT INTO @gen EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @RunId, @ActedByUserId = @Hr;
    SELECT @n2 = COUNT(*), @d = MAX(ps.HireDate) FROM payroll.PAYSLIP ps WHERE ps.PayrollRunId = @RunId AND ps.EmployeeId = @E4;
    SELECT @a1 = SUM(l.Amount) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @RunId AND ps.EmployeeId = @E4 AND l.ComponentName = N'Basic Salary';
    ROLLBACK TRAN qa2_rehire;
    SET @a2 = ROUND(1300.0 * (@DaysInM - 9) / @DaysInM, 2);
    INSERT INTO @res SELECT 'A5j', 'E4 terminated on the last day of M-1, then rehired on the 10th of M', CONCAT('no payslip in M while terminated; after the rehire one payslip with hire date ', CONVERT(CHAR(10), DATEADD(DAY, 9, @M), 23), ' and basic prorated ', @DaysInM - 9, '/', @DaysInM, ' = ', @a2),
        CONCAT('payslips while terminated=', @n, '; after rehire=', @n2, ', hire date ', CONVERT(CHAR(10), @d, 23), ', basic ', @a1), CASE WHEN @n = 0 AND @n2 = 1 AND @d = DATEADD(DAY, 9, @M) AND @a1 = @a2 THEN 1 ELSE 0 END;

    /* ---- A3j: exit permissions converted to leave at period close — both bases, and more minutes than balance ---- */
    DECLARE @px TABLE (LeaveMovementsPosted INT);
    DECLARE @epDays TABLE (WorkDate DATE);
    INSERT INTO @epDays SELECT DISTINCT ep.ExitDate FROM workflow.EXIT_PERMISSION ep JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ep.RequestInstanceId WHERE ep.EmployeeId = @E1 AND ri.[Status] = 'Approved' AND ep.ExitDate BETWEEN @M AND @MEnd;
    DECLARE @actualDays DECIMAL(6,2) = (SELECT SUM(core.fn_MinutesToLeaveDays(a.ExitLeaveMinutes)) FROM attendance.ATTENDANCE_RECORD a JOIN @epDays d ON d.WorkDate = a.WorkDate WHERE a.EmployeeId = @E1);
    DECLARE @actualMin INT = (SELECT SUM(a.ExitLeaveMinutes) FROM attendance.ATTENDANCE_RECORD a JOIN @epDays d ON d.WorkDate = a.WorkDate WHERE a.EmployeeId = @E1);
    SAVE TRAN qa2_ep_actual;
    INSERT INTO @px EXEC workflow.usp_ExitPermission_PostLeaveUsage @PeriodYearMonth = @MChar, @LeaveTypeId = 1, @PostedBy = @Hr;
    DECLARE @postedActual DECIMAL(6,2) = (SELECT -SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1 AND SourceType = 'ExitPermission');
    DELETE FROM @px; INSERT INTO @px EXEC workflow.usp_ExitPermission_PostLeaveUsage @PeriodYearMonth = @MChar, @LeaveTypeId = 1, @PostedBy = @Hr;      -- again: nothing new
    DECLARE @postedTwice DECIMAL(6,2) = (SELECT -SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1 AND SourceType = 'ExitPermission');
    ROLLBACK TRAN qa2_ep_actual;
    SAVE TRAN qa2_ep_approved;
    UPDATE core.SETTING SET SettingValue = 'Approved' WHERE SettingKey = 'ExitLeaveBasis';
    DECLARE @wd DATE; DECLARE ec CURSOR LOCAL FAST_FORWARD FOR SELECT WorkDate FROM @epDays; OPEN ec; FETCH NEXT FROM ec INTO @wd;
    WHILE @@FETCH_STATUS = 0 BEGIN EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E1, @WorkDate = @wd; FETCH NEXT FROM ec INTO @wd; END CLOSE ec; DEALLOCATE ec;
    DECLARE @approvedMin INT = (SELECT SUM(a.ExitLeaveMinutes) FROM attendance.ATTENDANCE_RECORD a JOIN @epDays d ON d.WorkDate = a.WorkDate WHERE a.EmployeeId = @E1);
    DECLARE @approvedDays DECIMAL(6,2) = (SELECT SUM(core.fn_MinutesToLeaveDays(a.ExitLeaveMinutes)) FROM attendance.ATTENDANCE_RECORD a JOIN @epDays d ON d.WorkDate = a.WorkDate WHERE a.EmployeeId = @E1);
    DELETE FROM @px; INSERT INTO @px EXEC workflow.usp_ExitPermission_PostLeaveUsage @PeriodYearMonth = @MChar, @LeaveTypeId = 1, @PostedBy = @Hr;
    DECLARE @postedApproved DECIMAL(6,2) = (SELECT -SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1 AND SourceType = 'ExitPermission');
    ROLLBACK TRAN qa2_ep_approved;
    /* more minutes than balance: E1 is left with 0.10 day */
    SAVE TRAN qa2_ep_short;
    DECLARE @balE1 DECIMAL(6,2) = (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1 AND LeaveTypeId = 1);
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note, CreatedBy) VALUES (@E1, 1, @MChar, 'Adjustment', -(@balE1 - 0.10), @M, N'QA2 A3j: almost nothing left', @Hr);
    DELETE FROM @px; INSERT INTO @px EXEC workflow.usp_ExitPermission_PostLeaveUsage @PeriodYearMonth = @MChar, @LeaveTypeId = 1, @PostedBy = @Hr;
    DECLARE @postedShort DECIMAL(6,2) = (SELECT -ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1 AND SourceType = 'ExitPermission');
    DECLARE @balAfter DECIMAL(6,2) = (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1 AND LeaveTypeId = 1);
    DELETE FROM @gen; INSERT INTO @gen EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @RunId, @ActedByUserId = @Hr;
    SELECT @a1 = SUM(l.Amount), @a2 = SUM(l.Quantity) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId
    WHERE ps.PayrollRunId = @RunId AND ps.EmployeeId = @E1 AND l.ComponentName = N'Unpaid Leave Deduction' AND l.SourceType = 'ExitPermission';
    ROLLBACK TRAN qa2_ep_short;
    INSERT INTO @res SELECT 'A3j', 'E1''s four exit-permission days are converted to leave at period close: basis Actual, basis Approved, and with only 0.10 day of balance left',
        CONCAT('Actual: the ', @actualMin, ' minutes actually used = ', @actualDays, ' day; posting twice adds nothing. Approved: the 180 approved minutes. Short balance: 0.10 posted, the balance ends at 0.00 (never negative) and the other ', @actualDays - 0.10, ' day is an unpaid deduction line of ', CAST(ROUND((@actualDays - 0.10) * 50, 2) AS DECIMAL(18,2))),
        CONCAT('Actual posted ', @postedActual, ' (after a second run ', @postedTwice, '); Approved: ', @approvedMin, ' min -> posted ', @postedApproved, ' (expected ', @approvedDays, '); short balance: posted ', @postedShort, ', balance ', @balAfter, ', deduction line ', ISNULL(CAST(@a1 AS VARCHAR(20)), 'none'), ' for ', ISNULL(CAST(@a2 AS VARCHAR(20)), '-'), ' day'),
        CASE WHEN @postedActual = @actualDays AND @postedTwice = @actualDays AND @approvedMin = 180 AND @postedApproved = @approvedDays AND @postedShort = 0.10 AND @balAfter = 0.00
                  AND @a1 = CAST(ROUND((@actualDays - 0.10) * 50, 2) AS DECIMAL(18,2)) THEN 1 ELSE 0 END;

    /* ---- lock: the supplemental, then the primary (regenerated first: the variants above touched it) ---- */
    DELETE FROM @gen; INSERT INTO @gen EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @RunId, @ActedByUserId = @Hr;
    INSERT INTO @rv EXEC payroll.usp_PayrollRun_SendToReview @PayrollRunId = @SupId, @ActedByUserId = @Hr;
    INSERT INTO @ap EXEC payroll.usp_PayrollRun_Approve @PayrollRunId = @SupId, @ActedByUserId = @Owner;
    INSERT INTO @rv EXEC payroll.usp_PayrollRun_SendToReview @PayrollRunId = @RunId, @ActedByUserId = @Hr;
    INSERT INTO @ap EXEC payroll.usp_PayrollRun_Approve @PayrollRunId = @RunId, @ActedByUserId = @Owner;

    /* ---- A5e: an adjustment approved AFTER the primary locked ---- */
    DELETE FROM @bulk; INSERT INTO @bulk EXEC payroll.usp_Adjustment_CreateBulk @ComponentTypeId = @Tips, @Amount = 15, @CurrencyCode = 'USD', @TargetPeriod = @MChar, @Reason = N'QA2 late correction', @CreatedByUserId = @Owner, @BranchId = @B1;
    DECLARE @lateN INT = (SELECT COUNT(*) FROM payroll.PAYROLL_ADJUSTMENT WHERE Reason = N'QA2 late correction');
    EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = @MChar, @CreatedByUserId = @Hr, @Notes = N'QA2 supplemental after lock', @RunType = 'Supplemental';
    DECLARE @Sup2 INT = (SELECT MAX(PayrollRunId) FROM payroll.PAYROLL_RUN WHERE Notes = N'QA2 supplemental after lock');
    DELETE FROM @gen; INSERT INTO @gen EXEC payroll.usp_PayrollRun_GenerateSupplemental @PayrollRunId = @Sup2, @ActedByUserId = @Hr;
    SELECT @n = COUNT(*), @n2 = SUM(CASE WHEN l.Note = N'QA2 late correction' THEN 0 ELSE 1 END) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @Sup2;
    DECLARE @onLocked INT = (SELECT COUNT(*) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId IN (@RunId, @SupId) AND l.Note = N'QA2 late correction');
    DECLARE @paidAgain INT = (SELECT COUNT(*) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @Sup2 AND l.Note = N'QA2 early bonus');
    INSERT INTO @res SELECT 'A5e', 'an adjustment approved after the primary was locked; then the next supplemental', CONCAT('not on the locked runs; the ', @lateN, ' new line(s) — and only they — on the next supplemental; the early bonus the first supplemental paid is not paid again'),
        CONCAT(@onLocked, ' on the locked runs; next supplemental: ', @n, ' line(s), ', @n2, ' other; early-bonus lines paid again: ', @paidAgain), CASE WHEN @lateN > 0 AND @onLocked = 0 AND @n = @lateN AND @n2 = 0 AND @paidAgain = 0 THEN 1 ELSE 0 END;

    /* ---- A1l: M is now PAID for E1 — every attendance / roster write is refused. LAST: these refusals doom the transaction. ---- */
    DECLARE @att BIGINT = (SELECT AttendanceId FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate = dbo.QA2_Date('A1b'));
    DECLARE @r1 NVARCHAR(300) = 'accepted (!)', @r2 NVARCHAR(300) = 'accepted (!)', @r3 NVARCHAR(300) = 'accepted (!)', @tIn DATETIME2 = dbo.QA2_At('A1b', '07:00', 0), @tOut DATETIME2 = dbo.QA2_At('A1b', '15:00', 0), @dl DATE = dbo.QA2_Date('A1b');
    BEGIN TRY EXEC attendance.usp_Correction_Create @AttendanceId = @att, @RequestedBy = @Hr, @NewLastOutUtc = @tOut, @Reason = N'QA2 A1l'; END TRY BEGIN CATCH SET @r1 = ERROR_MESSAGE(); END CATCH;
    /* the manual record is asked LAST: its procedure SETs XACT_ABORT ON, so its refusal is the one that leaves the transaction
       uncommittable — and the roster procedure writes a temp table before it refuses, which such a transaction cannot do */
    BEGIN TRY EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @E1, @WorkDate = @dl, @ShiftId = NULL, @IsRestDay = 1; END TRY BEGIN CATCH SET @r3 = ERROR_MESSAGE(); END CATCH;
    BEGIN TRY EXEC attendance.usp_Attendance_ManualUpsert @EmployeeId = @E1, @WorkDate = @dl, @FirstInUtc = @tIn, @LastOutUtc = @tOut, @HrNote = N'QA2 A1l'; END TRY BEGIN CATCH SET @r2 = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @res SELECT 'A1l', 'a correction, a manual record and a roster edit on a day of a period whose payroll is locked (and holds the employee''s payslip)', 'all three refused: "This period is paid — raise a payroll adjustment instead."',
        CONCAT('correction: ', @r1, ' | manual record: ', @r2, ' | roster edit: ', @r3), CASE WHEN @r1 LIKE N'This period is paid%' AND @r2 LIKE N'This period is paid%' AND @r3 LIKE N'This period is paid%' THEN 1 ELSE 0 END;

    IF @@TRANCOUNT > 0 ROLLBACK TRAN;
    INSERT INTO @notes VALUES ('QA2 payroll transaction rolled back: no run, payslip, lock, rate, setting or ledger row persisted.');
END TRY
BEGIN CATCH
    DECLARE @e NVARCHAR(700) = CONCAT('error ', ERROR_NUMBER(), ' in ', ISNULL(ERROR_PROCEDURE(), 'batch'), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE());
    IF @@TRANCOUNT > 0 ROLLBACK TRAN;
    INSERT INTO @res SELECT 'P-ERR', 'the QA2 payroll transaction ran to the end', 'no error', @e, 0;
END CATCH;

/* ---- report ---- */
DECLARE @i INT = 1, @mx INT = (SELECT MAX(Seq) FROM @notes), @txt NVARCHAR(MAX);
WHILE @i <= @mx BEGIN SELECT @txt = T FROM @notes WHERE Seq = @i; EXEC dbo.QA2_Note @Text = @txt; SET @i += 1; END
DECLARE @Id NVARCHAR(20), @Case NVARCHAR(400), @Expected NVARCHAR(700), @Actual NVARCHAR(700), @Pass BIT;
SET @i = 1; SET @mx = (SELECT MAX(Seq) FROM @res);
WHILE @i <= @mx
BEGIN
    SELECT @Id = Id, @Case = [Case], @Expected = Expected, @Actual = Actual, @Pass = Pass FROM @res WHERE Seq = @i;
    EXEC dbo.QA2_Check @Id, @Case, @Expected, @Actual, @Pass;
    SET @i += 1;
END
GO
