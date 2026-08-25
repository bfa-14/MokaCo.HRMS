using MokaCo.HRMS.Model.Payroll;

namespace MokaCo.HRMS.Services.Payroll;

/// <summary>
/// Payroll. Every method that can be refused is wrapped so the procedure's own sentence reaches the
/// user unchanged — see <see cref="PayrollService"/> for why nothing is validated ahead of it.
/// </summary>
public interface IPayrollService
{
    // --- runs ---
    Task<IEnumerable<PayrollRunListItem>> GetRunsAsync();
    Task<PayrollRunCreated?> CreateRunAsync(PayrollRunCreateRequest request, int createdByUserId);
    Task<PayrollRunDetail> GetRunAsync(int payrollRunId);
    Task<IEnumerable<PayslipListItem>> GetRunPayslipsAsync(int payrollRunId);
    Task<PayrollRunGenerateResult?> GenerateAsync(int payrollRunId, int actedByUserId);
    Task<PayrollRunStatusResult?> SendToReviewAsync(int payrollRunId, int actedByUserId);
    Task<PayrollRunStatusResult?> ApproveAsync(int payrollRunId, int actedByUserId);
    Task<PayrollRunStatusResult?> CancelAsync(int payrollRunId, int actedByUserId, PayrollRunCancelRequest request);
    Task<IEnumerable<PaymentSheetRow>> GetPaymentSheetAsync(int payrollRunId);
    Task<PayrollReadiness?> GetReadinessAsync(string periodYearMonth);

    // --- payslips ---
    Task<PayslipDetail> GetPayslipAsync(int payslipId);
    Task<PayslipPaymentResult?> SetPaymentAsync(int payslipId, PayslipPaymentRequest request, int actedByUserId);

    Task<IEnumerable<StatutoryReportRow>> GetStatutoryReportAsync(int payrollRunId);

    // --- payslips, read from the other side ---
    Task<IEnumerable<MyPayslip>> GetMyPayslipsAsync(int userId);

    /// <summary>
    /// The caller's salary standing for the current period — null when the month has not been
    /// generated, which is an answer rather than a failure.
    /// </summary>
    Task<MyPayslipStatus?> GetMyStatusAsync(int userId);
    Task<IEnumerable<EmployeePayslip>> GetPayslipsForEmployeeAsync(int employeeId);
    Task<PayslipLineLookup?> LookupLineAsync(string sourceType, int sourceId);

    // --- advances ---
    Task<IEnumerable<SalaryAdvance>> GetAdvancesAsync(int? employeeId, bool openOnly);
    // No CreateAdvanceAsync: advances are raised as requests (ISalaryAdvanceService).
    Task<SalaryAdvanceMonthlyResult?> UpdateAdvanceMonthlyAsync(
        int salaryAdvanceId, SalaryAdvanceMonthlyRequest request, int actedByUserId);

    // --- adjustments ---
    Task<IEnumerable<PayrollAdjustment>> GetAdjustmentsAsync(string targetPeriod);
    // No CreateAdjustmentAsync for ONE employee: a single adjustment is raised as a request
    // (IPayrollAdjustmentService), and the underlying procedure refuses direct creation.

    /// <summary>One adjustment for every active employee. PAYROLL_APPROVE, and its own procedure.</summary>
    Task<PayrollAdjustmentBulkResult?> CreateAdjustmentsBulkAsync(
        PayrollAdjustmentBulkRequest request, int createdByUserId);

    Task<PayrollAdjustmentDeleteResult?> DeleteAdjustmentAsync(int payrollAdjustmentId, int actedByUserId);

    // --- reference ---
    Task<IEnumerable<PayrollComponentType>> GetComponentTypesAsync();
}
