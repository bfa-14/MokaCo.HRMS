/* ============================================================================
   cases/04_payroll.sql — P1..P10 against the REAL payroll procs.

   WHY A ROLLED-BACK TRANSACTION: the real database already holds an APPROVED
   primary run for 2026-08 (run 17) and payroll.PAYROLL_RUN carries a filtered
   unique index (one live primary per period), so a QA run for M cannot be created
   without cancelling real data. Everything below therefore runs inside one
   transaction that is ROLLED BACK at the end: the real run is marked Cancelled
   only inside that transaction, the QA run is created/generated/approved, the
   checks are collected in a table variable, and nothing is persisted. The
   P9 refusals (locked run, locked month) are exercised outside the transaction
   against the real locked run, because those procs refuse BEFORE writing.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @res TABLE (Seq INT IDENTITY(1,1), Id NVARCHAR(20), [Case] NVARCHAR(300), Expected NVARCHAR(600), Actual NVARCHAR(600), Pass BIT);
DECLARE @notes TABLE (Seq INT IDENTITY(1,1), T NVARCHAR(MAX));
DECLARE @HrUser INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa.hr');
DECLARE @OwnerUser INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa.owner');
DECLARE @E1User INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa.e1');
DECLARE @B INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA Branch');
DECLARE @E1 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E1');
DECLARE @E2 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E2');
DECLARE @E5 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E5');
DECLARE @E6 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E6');
DECLARE @E7 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E7');
DECLARE @E9 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E9');
DECLARE @DaysPerMonth DECIMAL(6,2) = TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'StandardWorkingDaysPerMonth') AS DECIMAL(6,2));
DECLARE @Ceiling DECIMAL(18,2) = TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'NssfCeilingUsd') AS DECIMAL(18,2));
DECLARE @RateType VARCHAR(20) = (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'PayrollRateType');
DECLARE @FamilyDed DECIMAL(18,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'TaxFamilyDeductionAnnualUsd') AS DECIMAL(18,2)), 0);
DECLARE @Tips INT = (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE Name = N'Tips');
DECLARE @exp NVARCHAR(600), @act NVARCHAR(600), @n INT, @n2 INT, @amt DECIMAL(18,2), @amt2 DECIMAL(18,2), @RunId INT, @SupId INT;
INSERT INTO @notes VALUES (CONCAT('Formulas read from payroll.usp_PayrollRun_Generate: Coverage = employed calendar days in the month / days in month; Basic and every standing component = ROUND(amount x Coverage, 2); DayRate = Basic / StandardWorkingDaysPerMonth (', @DaysPerMonth, '); HourRate = DayRate / StandardHoursPerDay; Unpaid Leave Deduction = unpaid days in period x DayRate; "Late Deduction" line = SUM(1 - DayFraction) over ALL attendance records with DayFraction < 1 that are not inside an approved leave x DayRate (no separate late-minutes or early-exit rule, no grace); Sick = year-to-date tiers (unpaid portion as "Absence Deduction"); NSSF base = Salary/Overtime/Leave/Attendance Earning-Deduction lines in primary currency; employee NSSF = SUM over rate rows of min(base, ceiling ', @Ceiling, ') x EmployeeRate; employer = same with EmployerRate (uncapped schemes on the full base); tax = progressive brackets on (base - employee NSSF) x 12 - TaxFamilyDeductionAnnualUsd (setting absent -> 0), / 12. Rates snapshotted per run from core.EXCHANGE_RATE of RateType ', @RateType, ' (setting PayrollRateType), latest EffectiveDate <= period end.'));

BEGIN TRY
    BEGIN TRAN;

    /* neutralise the real August primary and complete the real attendance so readiness passes — all uncommitted */
    UPDATE payroll.PAYROLL_RUN SET [Status] = 'Cancelled' WHERE PeriodYearMonth = '2026-08' AND RunType = 'Primary' AND [Status] <> 'Cancelled';
    DECLARE @d DATE = '2026-08-01';
    WHILE @d <= '2026-08-31' BEGIN EXEC attendance.usp_Attendance_MarkAbsentees @WorkDate = @d; SET @d = DATEADD(DAY, 1, @d); END

    DECLARE @ready TABLE (PeriodYearMonth CHAR(7), PeriodStart DATE, PeriodEnd DATE, UnprocessedPunches INT, UnresolvedPinPunches INT, OpenAnomalies INT,
                          PendingCorrections INT, RosteredDaysWithNoRecord INT, UndecidedExitVariances INT, IsReady BIT);
    INSERT INTO @ready EXEC attendance.usp_Attendance_PayrollReadiness '2026-08';
    SELECT @act = CONCAT('unprocessed=', UnprocessedPunches, ' unresolved=', UnresolvedPinPunches, ' anomalies=', OpenAnomalies, ' corrections=', PendingCorrections, ' missingDays=', RosteredDaysWithNoRecord, ' variances=', UndecidedExitVariances, ' ready=', IsReady) FROM @ready;
    INSERT INTO @res SELECT 'P0', 'attendance readiness for 2026-08 (QA anomalies/variances decided; real roster days filled inside the transaction)', 'ready=1', @act, (SELECT IsReady FROM @ready);

    /* plain EXEC: the proc itself uses INSERT-EXEC for the readiness check, and INSERT-EXEC cannot be nested */
    EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = '2026-08', @CreatedByUserId = @HrUser, @Notes = N'QA August run', @RunType = 'Primary';
    SET @RunId = (SELECT MAX(PayrollRunId) FROM payroll.PAYROLL_RUN WHERE Notes = N'QA August run' AND RunType = 'Primary');
    IF @RunId IS NULL RAISERROR('usp_PayrollRun_Create did not create the QA run', 16, 1);
    DECLARE @rate DECIMAL(18,6) = payroll.fn_RunRate(@RunId, 'LBP', 'USD');           -- what the run will actually use
    DECLARE @srcUsdLbp DECIMAL(18,4) = (SELECT TOP 1 Rate FROM core.EXCHANGE_RATE WHERE FromCurrency = 'USD' AND ToCurrency = 'LBP' AND RateType = @RateType AND EffectiveDate <= '2026-08-31' ORDER BY EffectiveDate DESC);
    DECLARE @trueRate DECIMAL(18,10) = 1.0 / @srcUsdLbp;                                 -- the rate that should have been snapshotted
    SELECT @act = CONCAT('run=', @RunId, ' stored LBP->USD rate=', @rate, ' (', r.RateType, ' from ', CONVERT(VARCHAR(10), r.SourceEffectiveDate, 23), '); source USD->LBP=', @srcUsdLbp, ' so LBP->USD should be ', @trueRate) FROM payroll.PAYROLL_RUN_RATE r WHERE r.PayrollRunId = @RunId AND r.FromCurrency = 'LBP';
    INSERT INTO @res SELECT 'P1-rate', 'the run snapshots the exchange rate of the configured PayrollRateType (setting = ' + @RateType + '; the brief says "official rate of M")', 'one LBP->USD rate row of type ' + @RateType, @act, CASE WHEN EXISTS (SELECT 1 FROM payroll.PAYROLL_RUN_RATE WHERE PayrollRunId = @RunId AND FromCurrency = 'LBP' AND RateType = @RateType) THEN 1 ELSE 0 END;
    INSERT INTO @res SELECT 'P1-rate2', 'the snapshotted LBP->USD rate keeps its precision (PAYROLL_RUN_RATE.Rate is DECIMAL(18,4): 1/90000 = 0.0000111 rounds to 0)', CONCAT('about ', @trueRate, ' (non-zero)'), CONCAT('stored ', @rate, '; 6,000,000 LBP converts to ', payroll.fn_ToPrimary(@RunId, 6000000, 'LBP'), ' USD; in the REAL approved run 17 fn_ToPrimary(17, 6000000, ''LBP'') = ', payroll.fn_ToPrimary(17, 6000000, 'LBP')), CASE WHEN @rate > 0 AND ABS(@rate - @trueRate) < 0.000001 THEN 1 ELSE 0 END;

    DECLARE @gen TABLE (PayrollRunId INT, PayslipCount INT, PayslipsWithWarnings INT);
    INSERT INTO @gen EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @RunId, @ActedByUserId = @HrUser;
    SELECT @act = CONCAT('payslips=', PayslipCount, ' warnings=', PayslipsWithWarnings) FROM @gen;
    INSERT INTO @notes VALUES ('usp_PayrollRun_Generate: ' + @act + ' (all real + QA employees; rolled back afterwards)');

    /* ---- P1: E9 (clean month) and E1 ---- */
    DECLARE @ps9 INT = (SELECT PayslipId FROM payroll.PAYSLIP WHERE PayrollRunId = @RunId AND EmployeeId = @E9);
    DECLARE @ps1 INT = (SELECT PayslipId FROM payroll.PAYSLIP WHERE PayrollRunId = @RunId AND EmployeeId = @E1);
    SELECT @amt = SUM(CASE WHEN ComponentName = N'Basic Salary' THEN Amount END), @amt2 = SUM(CASE WHEN ComponentName = N'Transport Allowance' THEN Amount END)
    FROM payroll.PAYSLIP_LINE WHERE PayslipId = @ps9 AND SourceType = 'Salary';
    INSERT INTO @res SELECT 'P1a', 'E9 full month: Basic line = component amount (3500 USD) and Transport line = 6,000,000 LBP', 'basic=3500.00 transport=6000000.00', CONCAT('basic=', @amt, ' transport=', @amt2), CASE WHEN @amt = 3500 AND @amt2 = 6000000 THEN 1 ELSE 0 END;
    SELECT @act = CONCAT('GrossUsd=', GrossUsd, ' GrossLbp=', GrossLbp, ' DeductionsUsd=', DeductionsUsd, ' DeductionsLbp=', DeductionsLbp, ' NetUsd=', NetUsd, ' NetLbp=', NetLbp, ' NetPrimary=', NetPrimary) FROM payroll.PAYSLIP WHERE PayslipId = @ps9;
    INSERT INTO @res SELECT 'P1b', 'E9 payslip carries both USD and LBP columns (gross/net in each currency)', 'GrossUsd>0 and GrossLbp=6000000', @act, CASE WHEN (SELECT GrossLbp FROM payroll.PAYSLIP WHERE PayslipId = @ps9) = 6000000 AND (SELECT GrossUsd FROM payroll.PAYSLIP WHERE PayslipId = @ps9) > 0 THEN 1 ELSE 0 END;
    /* totals = sum of lines, no hidden rounding */
    SELECT @n = COUNT(*) FROM payroll.PAYSLIP ps
    CROSS APPLY (SELECT
        SUM(IIF(l.Category='Earning' AND l.CurrencyCode='USD', l.Amount, 0)) GU, SUM(IIF(l.Category='Earning' AND l.CurrencyCode='LBP', l.Amount, 0)) GL,
        SUM(IIF(l.Category='Deduction' AND l.CurrencyCode='USD', l.Amount, 0)) DU, SUM(IIF(l.Category='Deduction' AND l.CurrencyCode='LBP', l.Amount, 0)) DL
        FROM payroll.PAYSLIP_LINE l WHERE l.PayslipId = ps.PayslipId) t
    WHERE ps.PayrollRunId = @RunId AND ps.EmployeeId IN (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName LIKE N'QA %')
      AND NOT (ps.GrossUsd = t.GU AND ps.GrossLbp = t.GL AND ps.DeductionsUsd = t.DU AND ps.DeductionsLbp = t.DL
               AND ps.NetUsd = t.GU - t.DU AND ps.NetLbp = t.GL - t.DL
               AND ps.NetPrimary = ps.NetUsd + ROUND(ps.NetLbp * @trueRate, 2));
    DECLARE @np9 NVARCHAR(200) = (SELECT CONCAT('E9 NetUsd=', NetUsd, ' NetLbp=', NetLbp, ' NetPrimary=', NetPrimary, ' (expected NetPrimary=', NetUsd + ROUND(NetLbp * @trueRate, 2), ')') FROM payroll.PAYSLIP WHERE PayslipId = @ps9);
    INSERT INTO @res SELECT 'P1c', 'every QA payslip total = sum of its lines per currency; NetPrimary = NetUsd + ROUND(NetLbp x true rate, 2) (no rounding drift, LBP not lost)', '0 payslips off', CONCAT(@n, ' payslips off; ', @np9), CASE WHEN @n = 0 THEN 1 ELSE 0 END;

    /* ---- P2: E2 hired 15 Aug ---- */
    SELECT @amt = Amount, @act = CONCAT('basic=', Amount, ' note="', Note, '"') FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @RunId AND ps.EmployeeId = @E2 AND l.ComponentName = N'Basic Salary';
    SET @amt2 = ROUND(1500 * CAST(17 AS DECIMAL(6,2)) / 31, 2);
    INSERT INTO @res SELECT 'P2', 'E2 hired 15 Aug: basic prorated by CALENDAR days employed / days in month (17/31), and the rule shown on the payslip line', CONCAT('basic=', @amt2, ' note="Prorated 0.55 of the month"'), @act, CASE WHEN @amt = @amt2 AND @act LIKE '%Prorated 0.55%' THEN 1 ELSE 0 END;

    /* ---- P3: E7 terminated 20 Aug ---- */
    SELECT @amt = Amount, @act = CONCAT('basic=', Amount, ' note="', Note, '"') FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @RunId AND ps.EmployeeId = @E7 AND l.ComponentName = N'Basic Salary';
    SET @amt2 = ROUND(1200 * CAST(20 AS DECIMAL(6,2)) / 31, 2);
    INSERT INTO @res SELECT 'P3a', 'E7 terminated 20 Aug: basic prorated the same way (20/31)', CONCAT('basic=', @amt2), @act, CASE WHEN @amt = @amt2 THEN 1 ELSE 0 END;
    SELECT @n = COUNT(*) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @RunId AND ps.EmployeeId = @E7 AND l.ComponentName = N'End-of-Service Indemnity';
    INSERT INTO @res SELECT 'P3b', 'indemnity for E7: the proc only pays indemnity from a PREPARED Separation request (workflow.SEPARATION.PreparedAt), never from TerminationDate alone', 'documented rule: 0 indemnity lines for a plain termination date', CONCAT(@n, ' indemnity line(s)'), CASE WHEN @n = 0 THEN 1 ELSE 0 END;

    /* ---- P4: unpaid leave, absences, paid leave ---- */
    SELECT @amt = SUM(Amount), @act = CONCAT('amount=', SUM(Amount), ' qty=', SUM(Quantity), ' note="', MAX(Note), '"') FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @RunId AND ps.EmployeeId = @E6 AND l.ComponentName = N'Unpaid Leave Deduction';
    SET @amt2 = ROUND(2 * CAST(1200 / @DaysPerMonth AS DECIMAL(18,4)), 2);
    INSERT INTO @res SELECT 'P4a', 'E6 two unpaid leave days deducted at the daily rate Basic/26', CONCAT('amount=', @amt2, ' qty=2'), ISNULL(@act, 'no line'), CASE WHEN @amt = @amt2 THEN 1 ELSE 0 END;
    SELECT @n = COUNT(*), @act = CONCAT(COUNT(*), ' deduction line(s): ', ISNULL(STRING_AGG(CONCAT(l.ComponentName, ' ', l.Amount, ' (', l.Note, ')'), '; '), '')) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @RunId AND ps.EmployeeId = @E5 AND l.Category = 'Deduction' AND l.SourceType IN ('Leave', 'Attendance');
    SELECT @amt = PaidLeaveDays FROM payroll.PAYSLIP WHERE PayrollRunId = @RunId AND EmployeeId = @E5;
    INSERT INTO @res SELECT 'P4b', 'E5: paid annual (3) + sick (1, inside the full-pay tier) are NOT deducted; PaidLeaveDays = 4', '0 leave/attendance deduction lines, PaidLeaveDays=4', CONCAT(@act, '; PaidLeaveDays=', @amt), CASE WHEN @n = 0 AND @amt = 4 THEN 1 ELSE 0 END;
    /* E1: absence on 7 Aug + short days; expected = shortfall of real working days only */
    DECLARE @dayRate1 DECIMAL(18,4) = CAST(3500 / @DaysPerMonth AS DECIMAL(18,4));
    DECLARE @shortE1 DECIMAL(9,4) = (SELECT SUM(1 - a.DayFraction) FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E1 AND a.WorkDate BETWEEN '2026-08-01' AND '2026-08-31' AND a.[Status] IN ('Present', 'Absent') AND a.DayFraction < 1);
    DECLARE @restE1 DECIMAL(9,4) = (SELECT ISNULL(SUM(1 - a.DayFraction), 0) FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E1 AND a.WorkDate BETWEEN '2026-08-01' AND '2026-08-31' AND a.[Status] = 'RestDay' AND a.DayFraction < 1);
    SELECT @amt = SUM(Amount), @act = CONCAT('amount=', SUM(Amount), ' qty=', SUM(Quantity), ' note="', MAX(Note), '"') FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @RunId AND ps.EmployeeId = @E1 AND l.ComponentName = N'Late Deduction';
    SET @amt2 = ROUND(CAST(@shortE1 AS DECIMAL(6,2)) * @dayRate1, 2);
    INSERT INTO @res SELECT 'P4c', 'E1: the absence (7 Aug) and the short working days are deducted at Basic/26 — and ONLY those (rest days excluded)', CONCAT('amount=', @amt2, ' (', CAST(@shortE1 AS DECIMAL(6,2)), ' days short on working days; rest-day rows would add ', CAST(@restE1 AS DECIMAL(6,2)), ')'), ISNULL(@act, 'no line'), CASE WHEN @amt = @amt2 THEN 1 ELSE 0 END;
    SELECT @amt = SUM(Amount), @act = CONCAT('amount=', SUM(Amount), ' qty=', SUM(Quantity), ' note="', MAX(Note), '"') FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @RunId AND ps.EmployeeId = @E9 AND l.ComponentName = N'Late Deduction';
    INSERT INTO @res SELECT 'P4d', 'E9 (perfect attendance on every working day, 5 rostered Sundays) has NO attendance deduction', 'no Late Deduction line', ISNULL(@act, 'no line'), CASE WHEN @amt IS NULL THEN 1 ELSE 0 END;

    /* ---- P5: late minutes / early exits / decided variance ---- */
    INSERT INTO @notes VALUES ('P5 rule: there is no setting for late or early-exit deductions; the only attendance money effect is the "Late Deduction" line = (1 - DayFraction) x DayRate per record, where DayFraction = WorkedMinutes / StandardMinutes. A 12-minute late arrival (grace 10) costs 12/510 of a day (0.02 x DayRate), an 8-minute (inside-grace) arrival costs the same 0.02, and the HR disposition of an exit variance (UnpaidAbsence / Overtime / Ignore) and the approved minutes are never read by usp_PayrollRun_Generate.');
    DECLARE @fr8 DECIMAL(5,2) = (SELECT DayFraction FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate = '2026-08-08');
    DECLARE @fr4 DECIMAL(5,2) = (SELECT DayFraction FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate = '2026-08-04');
    DECLARE @fr5 DECIMAL(5,2) = (SELECT DayFraction FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate = '2026-08-05');
    INSERT INTO @res SELECT 'P5a', 'A2 (12 min late, grace 10) is deducted by exactly the 2 minutes beyond grace; A3 (8 min, inside grace) is not deducted', '4 Aug fraction 1.00 (2 late min are not a pay shortfall) and 5 Aug fraction 1.00', CONCAT('4 Aug fraction=', @fr4, ' -> ', ROUND((1 - @fr4) * @dayRate1, 2), ' USD; 5 Aug fraction=', @fr5, ' -> ', ROUND((1 - @fr5) * @dayRate1, 2), ' USD'), CASE WHEN @fr4 = 1 AND @fr5 = 1 THEN 1 ELSE 0 END;
    INSERT INTO @res SELECT 'P5b', 'A4 decided variance (actual 45 min, HR approved 60, disposition Ignore) is settled with the DECIDED minutes', 'no deduction for 8 Aug (approved 60 >= actual 45)', CONCAT('8 Aug DayFraction=', @fr8, ' -> ', ROUND((1 - @fr8) * @dayRate1, 2), ' USD deducted regardless of the decision'), CASE WHEN @fr8 = 1 THEN 1 ELSE 0 END;

    /* ---- P6: NSSF and tax for E9, hand-computed from the settings/rates ---- */
    DECLARE @base9 DECIMAL(18,2) = (SELECT SUM(ROUND(l.Amount * CASE WHEN l.CurrencyCode = 'USD' THEN 1 ELSE @trueRate END, 2) * l.[Sign]) FROM payroll.PAYSLIP_LINE l WHERE l.PayslipId = @ps9 AND l.SourceType IN ('Salary', 'Overtime', 'Leave', 'Attendance') AND l.Category IN ('Earning', 'Deduction'));
    DECLARE @base9stored DECIMAL(18,2) = (SELECT SUM(payroll.fn_ToPrimary(@RunId, l.Amount, l.CurrencyCode) * l.[Sign]) FROM payroll.PAYSLIP_LINE l WHERE l.PayslipId = @ps9 AND l.SourceType IN ('Salary', 'Overtime', 'Leave', 'Attendance') AND l.Category IN ('Earning', 'Deduction'));
    DECLARE @nssfEmpExp DECIMAL(18,2) = ROUND((SELECT SUM(CASE WHEN r.IsCeilinged = 1 AND @base9 > ISNULL(r.CeilingAmount, @Ceiling) THEN ISNULL(r.CeilingAmount, @Ceiling) ELSE @base9 END * r.EmployeeRate) FROM hr.NSSF_RATE r WHERE r.EffectiveFrom <= '2026-08-31' AND (r.EffectiveTo IS NULL OR r.EffectiveTo >= '2026-08-01')), 2);
    DECLARE @nssfErExp DECIMAL(18,2) = ROUND((SELECT SUM(CASE WHEN r.IsCeilinged = 1 AND @base9 > ISNULL(r.CeilingAmount, @Ceiling) THEN ISNULL(r.CeilingAmount, @Ceiling) ELSE @base9 END * r.EmployerRate) FROM hr.NSSF_RATE r WHERE r.EffectiveFrom <= '2026-08-31' AND (r.EffectiveTo IS NULL OR r.EffectiveTo >= '2026-08-01')), 2);
    DECLARE @annual DECIMAL(18,2) = (@base9 - @nssfEmpExp) * 12 - @FamilyDed;
    DECLARE @taxExp DECIMAL(18,2) = ROUND((SELECT SUM((CASE WHEN @annual > ISNULL(b.MaxAnnual, @annual) THEN ISNULL(b.MaxAnnual, @annual) ELSE @annual END - b.MinAnnual) * b.Rate) FROM hr.TAX_BRACKET b WHERE b.MinAnnual < @annual AND b.EffectiveFrom <= '2026-08-31' AND (b.EffectiveTo IS NULL OR b.EffectiveTo >= '2026-08-01')) / 12, 2);
    DECLARE @nssfEmp DECIMAL(18,2) = (SELECT SUM(Amount) FROM payroll.PAYSLIP_LINE WHERE PayslipId = @ps9 AND ComponentName = N'NSSF Employee Share');
    DECLARE @nssfEr DECIMAL(18,2) = (SELECT SUM(Amount) FROM payroll.PAYSLIP_LINE WHERE PayslipId = @ps9 AND ComponentName = N'NSSF Employer Share');
    DECLARE @tax DECIMAL(18,2) = (SELECT SUM(Amount) FROM payroll.PAYSLIP_LINE WHERE PayslipId = @ps9 AND ComponentName = N'Income Tax');
    INSERT INTO @notes VALUES (CONCAT('P6 hand computation for E9: wage base (USD) = ', @base9, ' [3500 basic + 6,000,000 LBP transport at ', @rate, ' = ', ROUND(6000000 * @rate, 2), ' minus attendance deductions]; ceiling ', @Ceiling, '; employee NSSF = min(base, ceiling) x 3 % = ', @nssfEmpExp, '; employer NSSF = min(base, ceiling) x (8 % + 6 %) + base x 8.5 % = ', @nssfErExp, '; annual taxable = (base - employee NSSF) x 12 - ', @FamilyDed, ' = ', @annual, '; tax/12 = ', @taxExp, '. TaxFamilyDeductionAnnualUsd is NOT a row in core.SETTING, so the family deduction is always 0.'));
    INSERT INTO @notes VALUES (CONCAT('P6 with the run''s OWN (stored) rate the wage base is ', @base9stored, ' USD: the LBP transport allowance counts for ', ROUND(6000000 * @rate, 2), ' USD instead of ', ROUND(6000000 * @trueRate, 2), '.'));
    INSERT INTO @res SELECT 'P6a', 'E9 NSSF employee share = min(base, ceiling 2500) x 3 % (base above the ceiling -> capped)', CAST(@nssfEmpExp AS NVARCHAR(20)), CONCAT(ISNULL(CAST(@nssfEmp AS NVARCHAR(20)), 'no line'), ' (proc base ', @base9stored, ' vs hand base ', @base9, ')'), CASE WHEN @nssfEmp = @nssfEmpExp THEN 1 ELSE 0 END;
    INSERT INTO @res SELECT 'P6b', 'E9 NSSF employer share = ceilinged schemes on min(base, ceiling) + EOSI 8.5 % on the full base', CAST(@nssfErExp AS NVARCHAR(20)), ISNULL(CAST(@nssfEr AS NVARCHAR(20)), 'no line'), CASE WHEN @nssfEr = @nssfErExp THEN 1 ELSE 0 END;
    INSERT INTO @res SELECT 'P6c', 'E9 income tax = progressive brackets on annualised (base - employee NSSF), divided by 12', CAST(@taxExp AS NVARCHAR(20)), ISNULL(CAST(@tax AS NVARCHAR(20)), 'no line'), CASE WHEN @tax = @taxExp THEN 1 ELSE 0 END;
    INSERT INTO @res SELECT 'P6d', 'the family/personal tax deduction is configurable (setting TaxFamilyDeductionAnnualUsd read by the proc exists in core.SETTING)', 'setting row exists', CASE WHEN EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'TaxFamilyDeductionAnnualUsd') THEN 'exists' ELSE 'missing (proc falls back to 0; nothing on the Settings page can change it)' END, CASE WHEN EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'TaxFamilyDeductionAnnualUsd') THEN 1 ELSE 0 END;

    /* ---- P7: the committed bulk gift appears once per QA employee ---- */
    SELECT @n = COUNT(*), @n2 = COUNT(DISTINCT ps.EmployeeId) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @RunId AND l.SourceType = 'Adjustment' AND l.Note = N'QA gift August';
    DECLARE @qaEmps INT = (SELECT COUNT(*) FROM hr.EMPLOYEE WHERE FullName LIKE N'QA %' AND IsDeleted = 0 AND (TerminationDate IS NULL OR TerminationDate >= '2026-08-01'));
    INSERT INTO @res SELECT 'P7b', 'the bulk gift (created twice through the API) lands exactly once per QA employee on the payslips, including E7 (active part of the month)', CONCAT(@qaEmps, ' lines on ', @qaEmps, ' payslips'), CONCAT(@n, ' lines on ', @n2, ' payslips'), CASE WHEN @n = @qaEmps AND @n2 = @qaEmps THEN 1 ELSE 0 END;

    /* ---- P10: prepared / ready / paid ---- */
    DECLARE @st TABLE (PayslipId INT, PeriodYearMonth CHAR(7), RunType VARCHAR(12), RunStatus VARCHAR(12), NetUsd DECIMAL(18,2), NetLbp DECIMAL(18,2), NetPrimary DECIMAL(18,2), PaymentMethod VARCHAR(20), PaidAt DATETIME2, StatusCode VARCHAR(10));
    INSERT INTO @st EXEC payroll.usp_Payslip_GetMyStatus @UserId = @E1User;
    SELECT @act = CONCAT(StatusCode, ' (', PeriodYearMonth, ' ', RunStatus, ')') FROM @st;
    INSERT INTO @res SELECT 'P10b', 'after generation E1''s dashboard status is "Prepared"', 'Prepared', ISNULL(@act, 'no row'), CASE WHEN EXISTS (SELECT 1 FROM @st WHERE StatusCode = 'Prepared' AND PeriodYearMonth = '2026-08') THEN 1 ELSE 0 END;

    DECLARE @rv TABLE (PayrollRunId INT, [Status] VARCHAR(12));
    INSERT INTO @rv EXEC payroll.usp_PayrollRun_SendToReview @PayrollRunId = @RunId, @ActedByUserId = @HrUser;
    DECLARE @ap TABLE (PayrollRunId INT, [Status] VARCHAR(12), LockedAt DATETIME2);
    INSERT INTO @ap EXEC payroll.usp_PayrollRun_Approve @PayrollRunId = @RunId, @ActedByUserId = @OwnerUser;
    INSERT INTO @res SELECT 'P9b', 'HR sends the run to review and the Owner approves/locks it', 'Approved with LockedAt', (SELECT CONCAT([Status], ' locked=', CONVERT(VARCHAR(19), LockedAt, 120)) FROM @ap), CASE WHEN EXISTS (SELECT 1 FROM @ap WHERE [Status] = 'Approved') THEN 1 ELSE 0 END;
    DELETE FROM @st; INSERT INTO @st EXEC payroll.usp_Payslip_GetMyStatus @UserId = @E1User;
    SELECT @act = StatusCode FROM @st;
    INSERT INTO @res SELECT 'P10c', 'after approval E1''s status is "Ready" (salary prepared, not yet received)', 'Ready', ISNULL(@act, 'no row'), CASE WHEN @act = 'Ready' THEN 1 ELSE 0 END;
    DECLARE @pay TABLE (PayslipId INT, PaymentMethod VARCHAR(20), PaymentReference NVARCHAR(80), PaidAt DATETIME2);
    INSERT INTO @pay EXEC payroll.usp_Payslip_SetPayment @PayslipId = @ps1, @PaymentMethod = 'Bank', @PaymentReference = N'QA-TRX', @ActedByUserId = @OwnerUser;
    DELETE FROM @st; INSERT INTO @st EXEC payroll.usp_Payslip_GetMyStatus @UserId = @E1User;
    SELECT @act = CONCAT(StatusCode, ' via ', PaymentMethod) FROM @st;
    INSERT INTO @res SELECT 'P10d', 'after marking E1''s payslip paid the status flips to "Paid" (received)', 'Paid via Bank', ISNULL(@act, 'no row'), CASE WHEN EXISTS (SELECT 1 FROM @st WHERE StatusCode = 'Paid') THEN 1 ELSE 0 END;
    SELECT @n = COUNT(*) FROM payroll.PAYROLL_ADJUSTMENT WHERE Reason = N'QA gift August' AND AppliedToPayslipId IS NOT NULL;
    INSERT INTO @res SELECT 'P7c', 'locking the run consumes the gift adjustments (AppliedToPayslipId set), so they cannot be paid twice', CONCAT(@qaEmps, ' consumed'), CONCAT(@n, ' consumed'), CASE WHEN @n = @qaEmps THEN 1 ELSE 0 END;

    /* ---- P8: supplemental run pays only the new adjustments ---- */
    DECLARE @bulk TABLE (EmployeesGiven INT);
    INSERT INTO @bulk EXEC payroll.usp_Adjustment_CreateBulk @ComponentTypeId = @Tips, @Amount = 25, @CurrencyCode = 'USD', @TargetPeriod = '2026-08', @Reason = N'QA supplemental bonus', @CreatedByUserId = @OwnerUser, @BranchId = @B;
    EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = '2026-08', @CreatedByUserId = @HrUser, @Notes = N'QA supplemental', @RunType = 'Supplemental';
    SET @SupId = (SELECT MAX(PayrollRunId) FROM payroll.PAYROLL_RUN WHERE Notes = N'QA supplemental' AND RunType = 'Supplemental');
    IF @SupId IS NULL RAISERROR('usp_PayrollRun_Create did not create the QA supplemental run', 16, 1);
    DELETE FROM @gen;
    INSERT INTO @gen EXEC payroll.usp_PayrollRun_GenerateSupplemental @PayrollRunId = @SupId, @ActedByUserId = @HrUser;
    SELECT @n = COUNT(*), @n2 = SUM(CASE WHEN l.SourceType <> 'Adjustment' OR l.Note <> N'QA supplemental bonus' THEN 1 ELSE 0 END)
    FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @SupId;
    DECLARE @supSlips INT = (SELECT COUNT(*) FROM payroll.PAYSLIP WHERE PayrollRunId = @SupId);
    DECLARE @supForeign INT = (SELECT COUNT(*) FROM payroll.PAYSLIP ps JOIN hr.EMPLOYEE e ON e.EmployeeId = ps.EmployeeId WHERE ps.PayrollRunId = @SupId AND e.FullName NOT LIKE N'QA %');
    INSERT INTO @res SELECT 'P8', 'the supplemental run contains only the new supplemental adjustment lines (no basic, no statutory), one payslip per QA employee', CONCAT(@qaEmps, ' lines, 0 other lines, ', @qaEmps, ' payslips, 0 non-QA payslips'), CONCAT(@n, ' lines, ', @n2, ' other lines, ', @supSlips, ' payslips, ', @supForeign, ' non-QA payslips'), CASE WHEN @n = @qaEmps AND @n2 = 0 AND @supSlips = @qaEmps AND @supForeign = 0 THEN 1 ELSE 0 END;

    /* one run per employee/month */
    SELECT @n = COUNT(*) FROM (SELECT ps.EmployeeId FROM payroll.PAYSLIP ps JOIN payroll.PAYROLL_RUN r ON r.PayrollRunId = ps.PayrollRunId WHERE r.PeriodYearMonth = '2026-08' AND r.RunType = 'Primary' AND r.[Status] <> 'Cancelled' GROUP BY ps.EmployeeId HAVING COUNT(*) > 1) x;
    INSERT INTO @res SELECT 'P9c', 'no employee has two live primary payslips for the same month', '0', CAST(@n AS NVARCHAR(10)), CASE WHEN @n = 0 THEN 1 ELSE 0 END;

    ROLLBACK TRAN;
    INSERT INTO @notes VALUES ('Payroll transaction rolled back: no run, payslip, lock or stamp persisted.');
END TRY
BEGIN CATCH
    DECLARE @err NVARCHAR(600) = CONCAT('error ', ERROR_NUMBER(), ' in ', ISNULL(ERROR_PROCEDURE(), 'batch'), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE());
    IF @@TRANCOUNT > 0 ROLLBACK TRAN;
    INSERT INTO @res SELECT 'P-ERR', 'the payroll transaction ran to the end', 'no error', @err, 0;
END CATCH;

/* ---- P9 refusals, exercised outside the transaction against the real locked run (the procs refuse before writing) ---- */
DECLARE @realRun INT = (SELECT TOP 1 PayrollRunId FROM payroll.PAYROLL_RUN WHERE PeriodYearMonth = '2026-08' AND RunType = 'Primary' AND [Status] = 'Approved' ORDER BY PayrollRunId DESC);
BEGIN TRY
    DECLARE @g TABLE (PayrollRunId INT, PayslipCount INT, PayslipsWithWarnings INT);
    INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @realRun, @ActedByUserId = @HrUser;
    INSERT INTO @res SELECT 'P9d', 'regenerating an APPROVED (locked) run is refused', 'refused with "This run is locked..."', 'generate succeeded (!)', 0;
END TRY
BEGIN CATCH
    INSERT INTO @res SELECT 'P9d', 'regenerating an APPROVED (locked) run is refused', 'refused with "This run is locked..."', ERROR_MESSAGE(), CASE WHEN ERROR_MESSAGE() LIKE '%locked%' THEN 1 ELSE 0 END;
END CATCH;
BEGIN TRY
    DECLARE @CtBasic INT = (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE Name = N'Basic Salary');
    DECLARE @sc TABLE (a SQL_VARIANT NULL, b SQL_VARIANT NULL, c SQL_VARIANT NULL, d SQL_VARIANT NULL, e SQL_VARIANT NULL, f SQL_VARIANT NULL, g SQL_VARIANT NULL, h SQL_VARIANT NULL, i SQL_VARIANT NULL, j SQL_VARIANT NULL);
    EXEC hr.usp_SalaryComponent_Set @EmployeeId = @E1, @ComponentTypeId = @CtBasic, @Amount = 3600, @CurrencyCode = 'USD', @EffectiveFrom = '2026-08-15', @ActedByUserId = @HrUser;
    INSERT INTO @res SELECT 'P9e', 'a salary change starting inside a locked month is refused (closed period cannot be modified)', 'refused with "Payroll is locked through that date..."', 'accepted (!)', 0;
END TRY
BEGIN CATCH
    INSERT INTO @res SELECT 'P9e', 'a salary change starting inside a locked month is refused (closed period cannot be modified)', 'refused with "Payroll is locked through that date..."', ERROR_MESSAGE(), CASE WHEN ERROR_MESSAGE() LIKE '%locked%' THEN 1 ELSE 0 END;
END CATCH;
BEGIN TRY
    EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = '2026-08', @CreatedByUserId = @HrUser, @Notes = N'QA duplicate primary', @RunType = 'Primary';
    INSERT INTO @res SELECT 'P9f', 're-running the primary for a month that has a live primary: REFUSES (never replaces)', 'refused with "A primary run for 2026-08 already exists..."', 'created (!)', 0;
END TRY
BEGIN CATCH
    INSERT INTO @res SELECT 'P9f', 're-running the primary for a month that has a live primary: REFUSES (never replaces)', 'refused with "A primary run for 2026-08 already exists..."', ERROR_MESSAGE(), CASE WHEN ERROR_MESSAGE() LIKE '%already exists%' THEN 1 ELSE 0 END;
END CATCH;

/* ---- report ---- */
DECLARE @i INT = 1, @m INT = (SELECT MAX(Seq) FROM @notes), @t NVARCHAR(MAX);
WHILE @i <= @m BEGIN SELECT @t = T FROM @notes WHERE Seq = @i; EXEC dbo.QA_Note @Text = @t; SET @i += 1; END
DECLARE @Id NVARCHAR(20), @Case NVARCHAR(300), @Expected NVARCHAR(600), @Actual NVARCHAR(600), @Pass BIT;
SET @i = 1; SET @m = (SELECT MAX(Seq) FROM @res);
WHILE @i <= @m
BEGIN
    SELECT @Id = Id, @Case = [Case], @Expected = Expected, @Actual = Actual, @Pass = Pass FROM @res WHERE Seq = @i;
    EXEC dbo.QA_Check @Id, @Case, @Expected, @Actual, @Pass;
    SET @i += 1;
END
GO
