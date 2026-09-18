/* ============================================================================
   payroll_run_compare.sql — "what would this locked run pay with the FIXED procedures?"

   WHY: script 78 changed the payroll arithmetic (rest days never deducted, the LBP→USD run rate kept
   at full precision, so NSSF and tax bases include LBP allowances). A locked run is never regenerated
   (usp_PayrollRun_Generate refuses, and that refusal is the lock), so the differences for an already
   paid month are settled the other way round: HR raises them as PAYROLL_ADJUSTMENT requests and pays
   them in a Supplemental run. This script produces the list of those differences.

   HOW: everything happens inside ONE TRANSACTION THAT IS ALWAYS ROLLED BACK. Inside it the script
     1. snapshots the run's payslips and lines as they are (the OLD figures);
     2. undoes, for the regeneration only, the side effects that approving the run had on its inputs
        (expenses stamped, advances reduced, adjustments consumed) so the generator sees the same
        inputs the run saw — and sets aside inputs the run never saw (adjustments / expenses / advances
        that appeared for this period after the lock) so they are not double-counted;
     3. with OnlyFixes=1 (the default) also sets aside DATA THAT APPEARED AFTER THE LOCK — employees
        added since, termination dates set since, separations prepared since, attendance records
        processed since, tips finalized since — so what remains is the effect of the fixes alone.
        OnlyFixes=0 regenerates against the data as it stands today (informational);
     4. re-snapshots the run's exchange rates at full precision from the SAME source rows the run froze
        (same RateType, same SourceEffectiveDate) — a run created before script 78 holds 0.0000;
     5. marks the run Draft and calls payroll.usp_PayrollRun_Generate — the real, fixed generator;
     6. prints, per employee, old Net (USD / LBP / primary), new Net, the difference, and every payslip
        line that changed (Late Deduction, LBP allowance, NSSF, tax, ...) with its cause;
     7. ROLLBACK. Nothing persists: not the Draft status, not the rates, not a payslip, not an event.

   RUN:   sqlcmd -S localhost -U sa -C -I -d MokaCo_HRMS -W -s "|" \
              -v RunId=17 OnlyFixes=1 RateType=Own -i docs/payroll_run_compare.sql
          All three variables are passed with -v (a :setvar in the script would override -v, so there
          are none): RunId — the primary run to recalculate (17 = August 2026); OnlyFixes — 1 sets
          post-lock data aside (see above), 0 uses today's data; RateType — Own re-prices at the rate
          type the run itself froze, any other value (e.g. NonOfficial) prices at that type's latest
          rate as of the period end.

   NEVER: unlocks, alters or re-approves the run. If the script is interrupted, SQL Server rolls the
          open transaction back with the session. Verify with a before/after CHECKSUM_AGG of
          payroll.PAYSLIP / PAYSLIP_LINE for the run if you want proof.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;

DECLARE @RunId INT = $(RunId);
DECLARE @OnlyFixes BIT = $(OnlyFixes);
DECLARE @RateTypeOverride VARCHAR(20) = NULLIF('$(RateType)', 'Own');
DECLARE @Status VARCHAR(12), @Type VARCHAR(12), @Period CHAR(7), @Primary CHAR(3), @Start DATE, @End DATE,
        @Actor INT, @LockedAt DATETIME2;
SELECT @Status = [Status], @Type = RunType, @Period = PeriodYearMonth, @Primary = PrimaryCurrency,
       @Start = PeriodStart, @End = PeriodEnd, @Actor = CreatedByUserId, @LockedAt = ISNULL(LockedAt, GeneratedAt)
FROM payroll.PAYROLL_RUN WHERE PayrollRunId = @RunId;

IF @Status IS NULL BEGIN PRINT CONCAT('No payroll run ', @RunId, '.'); RETURN; END
IF @Type <> 'Primary' BEGIN PRINT CONCAT('Run ', @RunId, ' is a ', @Type, ' run; this comparison is for primary runs.'); RETURN; END

PRINT CONCAT('Run ', @RunId, ': ', @Type, ' ', @Period, ', status ', @Status, ', primary currency ', @Primary,
             ', locked ', CONVERT(VARCHAR(19), @LockedAt, 120), ' — comparison inside a rolled-back transaction; the run is not modified.');
PRINT CONCAT('Mode: ', CASE WHEN @OnlyFixes = 1 THEN 'OnlyFixes=1 (data that appeared after the lock is set aside)' ELSE 'OnlyFixes=0 (today''s data as it stands)' END,
             CASE WHEN @RateTypeOverride IS NULL THEN '; rate: the type the run froze' ELSE '; rate: ' + @RateTypeOverride + ' as of the period end' END);
SELECT r.FromCurrency, r.ToCurrency, r.Rate AS StoredRate, r.RateType, r.SourceEffectiveDate,
       er.Rate AS SourceRate,
       CAST(CASE WHEN er.FromCurrency = r.FromCurrency THEN er.Rate ELSE 1.0 / er.Rate END AS DECIMAL(28,12)) AS FullPrecisionRate
FROM payroll.PAYROLL_RUN_RATE r
OUTER APPLY (SELECT TOP 1 e.Rate, e.FromCurrency
             FROM core.EXCHANGE_RATE e
             WHERE ((e.FromCurrency = r.FromCurrency AND e.ToCurrency = r.ToCurrency)
                 OR (e.FromCurrency = r.ToCurrency AND e.ToCurrency = r.FromCurrency))
               AND e.RateType = r.RateType AND e.EffectiveDate = r.SourceEffectiveDate
             ORDER BY e.ExchangeRateId DESC) er
WHERE r.PayrollRunId = @RunId;

BEGIN TRY
    BEGIN TRAN;

    /* ---- 1. the OLD figures ---- */
    SELECT ps.PayslipId, ps.EmployeeId, ps.EmployeeName, ps.NetUsd, ps.NetLbp, ps.NetPrimary,
           ps.GrossUsd, ps.GrossLbp, ps.DeductionsUsd, ps.DeductionsLbp, ps.EmployerCostUsd, ps.EmployerCostLbp
    INTO #OldSlip
    FROM payroll.PAYSLIP ps WHERE ps.PayrollRunId = @RunId;

    SELECT ps.EmployeeId, l.ComponentName, l.Category, l.[Sign], l.CurrencyCode, l.SourceType, l.SourceId,
           l.Amount, l.Quantity, l.Note
    INTO #OldLine
    FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId
    WHERE ps.PayrollRunId = @RunId;

    /* ---- 2. give the generator the inputs the run saw, and only those ---- */
    /* adjustments consumed BY THIS RUN become payable again (the FK from PAYROLL_ADJUSTMENT to the
       payslip would otherwise block the generator's DELETE); adjustments that target the period but
       were consumed by another run (a supplemental) or are still pending are set aside */
    UPDATE adj SET AppliedToPayslipId = NULL
    FROM payroll.PAYROLL_ADJUSTMENT adj JOIN #OldSlip o ON o.PayslipId = adj.AppliedToPayslipId;
    DECLARE @SetAsideAdj INT;
    UPDATE adj SET TargetPeriod = '0000-00'
    FROM payroll.PAYROLL_ADJUSTMENT adj
    WHERE adj.TargetPeriod = @Period AND adj.AppliedToPayslipId IS NULL
      AND NOT EXISTS (SELECT 1 FROM #OldLine ol WHERE ol.SourceType = 'Adjustment' AND ol.SourceId = adj.PayrollAdjustmentId);
    SET @SetAsideAdj = @@ROWCOUNT;
    /* expenses this run reimbursed become reimbursable again; approved expenses it never saw are stamped */
    UPDATE er SET ReimbursedInPayrollAt = NULL
    FROM workflow.EXPENSE_REIMBURSEMENT er
    WHERE EXISTS (SELECT 1 FROM #OldLine ol WHERE ol.SourceType = 'Expense' AND ol.SourceId = er.ExpenseReimbursementId);
    DECLARE @SetAsideExp INT;
    UPDATE er SET ReimbursedInPayrollAt = SYSUTCDATETIME()
    FROM workflow.EXPENSE_REIMBURSEMENT er
    WHERE er.ReimbursedInPayrollAt IS NULL
      AND NOT EXISTS (SELECT 1 FROM #OldLine ol WHERE ol.SourceType = 'Expense' AND ol.SourceId = er.ExpenseReimbursementId);
    SET @SetAsideExp = @@ROWCOUNT;
    /* advances this run deducted get the instalment back; advances it never saw are parked */
    UPDATE a SET RemainingAmount = a.RemainingAmount + d.Deducted, IsSettled = 0
    FROM payroll.SALARY_ADVANCE a
    JOIN (SELECT SourceId, SUM(Amount) AS Deducted FROM #OldLine WHERE SourceType = 'Advance' GROUP BY SourceId) d
      ON d.SourceId = a.SalaryAdvanceId;
    DECLARE @SetAsideAdv INT;
    UPDATE a SET IsSettled = 1
    FROM payroll.SALARY_ADVANCE a
    WHERE a.IsSettled = 0 AND a.FirstDeductionPeriod <= @Period
      AND NOT EXISTS (SELECT 1 FROM #OldLine ol WHERE ol.SourceType = 'Advance' AND ol.SourceId = a.SalaryAdvanceId);
    SET @SetAsideAdv = @@ROWCOUNT;
    PRINT CONCAT('Set aside (not part of this run, so not double-counted): ', @SetAsideAdj, ' adjustment(s), ',
                 @SetAsideExp, ' expense(s), ', @SetAsideAdv, ' advance(s).');

    /* ---- 3. OnlyFixes: data that appeared after the lock is not a difference the fixes caused ---- */
    IF @OnlyFixes = 1
    BEGIN
        DECLARE @n1 INT, @n2 INT, @n3 INT, @n4 INT, @n5 INT;
        /* employees the run never had (added or hired since): pushed past the period */
        UPDATE e SET HireDate = DATEADD(DAY, 1, @End)
        FROM hr.EMPLOYEE e
        WHERE e.IsDeleted = 0 AND e.HireDate <= @End AND (e.TerminationDate IS NULL OR e.TerminationDate >= @Start)
          AND NOT EXISTS (SELECT 1 FROM #OldSlip o WHERE o.EmployeeId = e.EmployeeId);
        SET @n1 = @@ROWCOUNT;
        /* termination dates set since (the run's Basic line was not prorated for them) */
        UPDATE e SET TerminationDate = NULL
        FROM hr.EMPLOYEE e
        JOIN #OldSlip o ON o.EmployeeId = e.EmployeeId
        WHERE e.TerminationDate BETWEEN @Start AND @End
          AND EXISTS (SELECT 1 FROM #OldLine ol WHERE ol.EmployeeId = e.EmployeeId AND ol.SourceType = 'Salary'
                        AND ol.ComponentName = N'Basic Salary' AND ISNULL(ol.Note, N'') NOT LIKE N'Prorated%');
        SET @n2 = @@ROWCOUNT;
        /* separations prepared since */
        UPDATE s SET PreparedAt = NULL FROM workflow.SEPARATION s WHERE s.PreparedAt > @LockedAt;
        SET @n3 = @@ROWCOUNT;
        /* attendance records processed since (the day rule re-measured or HR corrected them later):
           moved a century back rather than deleted, because corrections and anomalies reference them */
        UPDATE a SET WorkDate = DATEADD(YEAR, -100, a.WorkDate)
        FROM attendance.ATTENDANCE_RECORD a
        WHERE a.WorkDate BETWEEN @Start AND @End AND a.ProcessedUtc > @LockedAt;
        SET @n4 = @@ROWCOUNT;
        /* tips finalized since */
        UPDATE td SET FinalizedAt = NULL FROM workflow.TIP_DISTRIBUTION td
        WHERE td.ShiftDate BETWEEN @Start AND @End AND td.FinalizedAt > @LockedAt;
        SET @n5 = @@ROWCOUNT;
        PRINT CONCAT('OnlyFixes: set aside ', @n1, ' employee(s) added since, ', @n2, ' termination date(s) set since, ',
                     @n3, ' separation(s) prepared since, ', @n4, ' attendance record(s) processed since, ',
                     @n5, ' tip distribution(s) finalized since. (Leave / overtime requests approved since are not set aside.)');
    END

    /* ---- 4. the run's own rates at full precision (or the override type as of the period end) ---- */
    IF @RateTypeOverride IS NULL
    BEGIN
        UPDATE r SET Rate = x.Rate
        FROM payroll.PAYROLL_RUN_RATE r
        CROSS APPLY (SELECT TOP 1
                            CAST(CASE WHEN e.FromCurrency = r.FromCurrency THEN e.Rate ELSE 1.0 / e.Rate END AS DECIMAL(28,12)) AS Rate
                     FROM core.EXCHANGE_RATE e
                     WHERE ((e.FromCurrency = r.FromCurrency AND e.ToCurrency = r.ToCurrency)
                         OR (e.FromCurrency = r.ToCurrency AND e.ToCurrency = r.FromCurrency))
                       AND e.RateType = r.RateType AND e.EffectiveDate = r.SourceEffectiveDate
                     ORDER BY e.ExchangeRateId DESC) x
        WHERE r.PayrollRunId = @RunId;
    END
    ELSE
    BEGIN
        UPDATE r SET Rate = x.Rate, RateType = x.RateType, SourceEffectiveDate = x.EffectiveDate
        FROM payroll.PAYROLL_RUN_RATE r
        CROSS APPLY (SELECT TOP 1
                            CAST(CASE WHEN e.FromCurrency = r.FromCurrency THEN e.Rate ELSE 1.0 / e.Rate END AS DECIMAL(28,12)) AS Rate,
                            e.RateType, e.EffectiveDate
                     FROM core.EXCHANGE_RATE e
                     WHERE ((e.FromCurrency = r.FromCurrency AND e.ToCurrency = r.ToCurrency)
                         OR (e.FromCurrency = r.ToCurrency AND e.ToCurrency = r.FromCurrency))
                       AND e.RateType = @RateTypeOverride AND e.EffectiveDate <= @End
                     ORDER BY e.EffectiveDate DESC, e.ExchangeRateId DESC) x
        WHERE r.PayrollRunId = @RunId;
    END
    SELECT 'rate used for the recalculation' AS What, FromCurrency, ToCurrency, Rate, RateType, SourceEffectiveDate
    FROM payroll.PAYROLL_RUN_RATE WHERE PayrollRunId = @RunId;

    /* ---- 5. regenerate with the fixed generator (Draft only inside this transaction) ---- */
    UPDATE payroll.PAYROLL_RUN SET [Status] = 'Draft' WHERE PayrollRunId = @RunId;
    EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @RunId, @ActedByUserId = @Actor;

    /* ---- 6. compare ---- */
    SELECT ps.PayslipId, ps.EmployeeId, ps.EmployeeName, ps.NetUsd, ps.NetLbp, ps.NetPrimary
    INTO #NewSlip
    FROM payroll.PAYSLIP ps WHERE ps.PayrollRunId = @RunId;

    SELECT ISNULL(o.EmployeeId, n.EmployeeId) AS EmployeeId,
           ISNULL(o.EmployeeName, n.EmployeeName) AS Employee,
           o.NetUsd AS OldNetUsd, n.NetUsd AS NewNetUsd, ISNULL(n.NetUsd, 0) - ISNULL(o.NetUsd, 0) AS DiffUsd,
           o.NetLbp AS OldNetLbp, n.NetLbp AS NewNetLbp, ISNULL(n.NetLbp, 0) - ISNULL(o.NetLbp, 0) AS DiffLbp,
           o.NetPrimary AS OldNetPrimary, n.NetPrimary AS NewNetPrimary,
           ISNULL(n.NetPrimary, 0) - ISNULL(o.NetPrimary, 0) AS DiffPrimary,
           CASE WHEN o.PayslipId IS NULL THEN 'NEW PAYSLIP' WHEN n.PayslipId IS NULL THEN 'PAYSLIP GONE' ELSE '' END AS Remark
    FROM #OldSlip o
    FULL OUTER JOIN #NewSlip n ON n.EmployeeId = o.EmployeeId
    ORDER BY 1;

    ;WITH newLine AS (
        SELECT ps.EmployeeId, l.ComponentName, l.Category, l.[Sign], l.CurrencyCode, l.SourceType, l.SourceId,
               l.Amount, l.Quantity, l.Note
        FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId
        WHERE ps.PayrollRunId = @RunId
    ), o AS (
        SELECT EmployeeId, ComponentName, CurrencyCode, SourceType, SUM(Amount) AS Amount, SUM(Quantity) AS Quantity, MAX(Note) AS Note
        FROM #OldLine GROUP BY EmployeeId, ComponentName, CurrencyCode, SourceType
    ), n AS (
        SELECT EmployeeId, ComponentName, CurrencyCode, SourceType, SUM(Amount) AS Amount, SUM(Quantity) AS Quantity, MAX(Note) AS Note
        FROM newLine GROUP BY EmployeeId, ComponentName, CurrencyCode, SourceType
    )
    SELECT ISNULL(o.EmployeeId, n.EmployeeId) AS EmployeeId,
           e.FullName AS Employee,
           ISNULL(o.ComponentName, n.ComponentName) AS Line,
           ISNULL(o.CurrencyCode, n.CurrencyCode) AS Ccy,
           ISNULL(o.SourceType, n.SourceType) AS Source,
           o.Amount AS OldAmount, n.Amount AS NewAmount, ISNULL(n.Amount, 0) - ISNULL(o.Amount, 0) AS Diff,
           CASE ISNULL(o.SourceType, n.SourceType)
                WHEN 'Statutory'  THEN 'LBP rate fix: statutory base now includes LBP lines'
                WHEN 'Attendance' THEN 'rest-day rule fix / attendance records'
                WHEN 'Separation' THEN 'data: separation'
                WHEN 'Salary'     THEN 'data: hire / termination / component'
                ELSE 'data: ' + ISNULL(o.SourceType, n.SourceType) END AS Cause,
           o.Note AS OldNote, n.Note AS NewNote
    FROM o
    FULL OUTER JOIN n ON n.EmployeeId = o.EmployeeId AND n.ComponentName = o.ComponentName
                     AND n.CurrencyCode = o.CurrencyCode AND n.SourceType = o.SourceType
    JOIN hr.EMPLOYEE e ON e.EmployeeId = ISNULL(o.EmployeeId, n.EmployeeId)
    WHERE ISNULL(o.Amount, -1) <> ISNULL(n.Amount, -1)
    ORDER BY 1, 3;

    SELECT 'totals' AS What,
           (SELECT SUM(NetPrimary) FROM #OldSlip) AS OldNetPrimary, (SELECT SUM(NetPrimary) FROM #NewSlip) AS NewNetPrimary,
           (SELECT SUM(NetPrimary) FROM #NewSlip) - (SELECT SUM(NetPrimary) FROM #OldSlip) AS DiffPrimary,
           (SELECT SUM(NetUsd) FROM #OldSlip) AS OldNetUsd, (SELECT SUM(NetUsd) FROM #NewSlip) AS NewNetUsd,
           (SELECT SUM(NetLbp) FROM #OldSlip) AS OldNetLbp, (SELECT SUM(NetLbp) FROM #NewSlip) AS NewNetLbp;

    /* ---- 7. nothing persists ---- */
    ROLLBACK TRAN;
    PRINT CONCAT('Rolled back: run ', @RunId, ' is unchanged (status ', @Status, ').');
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRAN;
    PRINT CONCAT('Comparison aborted and rolled back: error ', ERROR_NUMBER(), ' in ', ISNULL(ERROR_PROCEDURE(), 'batch'),
                 ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE());
END CATCH;
GO
