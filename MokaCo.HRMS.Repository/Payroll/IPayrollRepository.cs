using MokaCo.HRMS.Model.Payroll;

namespace MokaCo.HRMS.Repository.Payroll;

/// <summary>
/// Dapper access to the payroll schema. Every method is one stored procedure, and every RULE those
/// procedures enforce is left to them: the attendance gate, the lock on an approved run, the bound
/// on a monthly deduction, the refusal to delete a consumed adjustment. Nothing is re-checked here.
/// </summary>
public interface IPayrollRepository
{
    // --- runs ---
    Task<IEnumerable<PayrollRunListItem>> GetRunsAsync();

    /// <summary>
    /// Creates a run for a period. Refuses when a live run already exists for it, when attendance is
    /// not ready, or when a currency in play has no rate on file — each with its own sentence.
    /// </summary>
    Task<PayrollRunCreated?> CreateRunAsync(string periodYearMonth, int createdByUserId, string? notes);

    /// <summary>The run page in one round trip: header, frozen rates, totals, history.</summary>
    Task<PayrollRunDetail> GetRunAsync(int payrollRunId);

    Task<IEnumerable<PayslipListItem>> GetRunPayslipsAsync(int payrollRunId);

    /// <summary>
    /// Rebuilds every payslip in the run from the data as it stands. Destructive and repeatable while
    /// Draft or Review; a locked run refuses, and that refusal is the point.
    /// </summary>
    Task<PayrollRunGenerateResult?> GenerateAsync(int payrollRunId, int actedByUserId);

    Task<PayrollRunStatusResult?> SendToReviewAsync(int payrollRunId, int actedByUserId);

    /// <summary>
    /// THE LOCK. One transaction stamps the run, marks expenses reimbursed, reduces advance balances
    /// and consumes adjustments — and refuses outright on a run that is already closed, which is what
    /// makes it safe to press twice.
    /// </summary>
    Task<PayrollRunStatusResult?> ApproveAsync(int payrollRunId, int actedByUserId);

    Task<PayrollRunStatusResult?> CancelAsync(int payrollRunId, int actedByUserId, string? reason);

    /// <summary>Approved runs only — the procedure refuses a draft, because a draft still changes.</summary>
    Task<IEnumerable<PaymentSheetRow>> GetPaymentSheetAsync(int payrollRunId);

    /// <summary>The attendance gate for a period, read on its own so the panel can explain a refusal first.</summary>
    Task<PayrollReadiness?> GetReadinessAsync(string periodYearMonth);

    // --- payslips ---
    /// <summary>
    /// The payslip and its lines, with each request-backed line's RequestInstanceId resolved so the
    /// document can link every figure to the request that produced it.
    /// </summary>
    Task<PayslipDetail> GetPayslipAsync(int payslipId);

    Task<PayslipPaymentResult?> SetPaymentAsync(
        int payslipId, string paymentMethod, string? paymentReference, int actedByUserId);

    // --- advances ---
    Task<IEnumerable<SalaryAdvance>> GetAdvancesAsync(int? employeeId, bool openOnly);
    Task<SalaryAdvanceCreated?> CreateAdvanceAsync(
        int employeeId, decimal amount, string currencyCode, DateTime advanceDate,
        decimal monthlyDeduction, string firstDeductionPeriod, string? reason, int createdByUserId);
    Task<SalaryAdvanceMonthlyResult?> UpdateAdvanceMonthlyAsync(
        int salaryAdvanceId, decimal monthlyDeduction, int actedByUserId);

    // --- adjustments ---
    Task<IEnumerable<PayrollAdjustment>> GetAdjustmentsAsync(string targetPeriod);

    // Creation lives in IPayrollAdjustmentRepository (workflow.usp_PayrollAdjustment_Create): the
    // row is written by the final approval of a request, and payroll.usp_Adjustment_Create refuses.

    Task<PayrollAdjustmentDeleteResult?> DeleteAdjustmentAsync(int payrollAdjustmentId, int actedByUserId);

    // --- reference ---
    /// <summary>The component catalogue the adjustment form picks from, IsStanding included.</summary>
    Task<IEnumerable<PayrollComponentType>> GetComponentTypesAsync();
}
