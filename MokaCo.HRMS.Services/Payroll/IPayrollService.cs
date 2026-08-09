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

    // --- advances ---
    Task<IEnumerable<SalaryAdvance>> GetAdvancesAsync(int? employeeId, bool openOnly);
    Task<SalaryAdvanceCreated?> CreateAdvanceAsync(SalaryAdvanceCreateRequest request, int createdByUserId);
    Task<SalaryAdvanceMonthlyResult?> UpdateAdvanceMonthlyAsync(
        int salaryAdvanceId, SalaryAdvanceMonthlyRequest request, int actedByUserId);

    // --- adjustments ---
    Task<IEnumerable<PayrollAdjustment>> GetAdjustmentsAsync(string targetPeriod);
    // No CreateAdjustmentAsync: adjustments are raised as requests (IPayrollAdjustmentService), and
    // the underlying procedure refuses direct creation.
    Task<PayrollAdjustmentDeleteResult?> DeleteAdjustmentAsync(int payrollAdjustmentId, int actedByUserId);

    // --- reference ---
    Task<IEnumerable<PayrollComponentType>> GetComponentTypesAsync();
}
