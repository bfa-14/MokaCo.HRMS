using MokaCo.HRMS.Model.Payroll;
using MokaCo.HRMS.Repository.Payroll;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.Payroll;

/// <summary>
/// Payroll — a thin layer over the procedures, and deliberately so.
///
/// THERE IS NO BUSINESS RULE IN THIS FILE. Whether a month may become a run, whether a run may be
/// regenerated, whether an advance may be rescheduled, whether an adjustment may be deleted: every
/// one of those is settled in SQL, in a transaction, against the data as it stands at that instant.
/// Re-checking any of it here would create a second opinion that can drift from the first — and the
/// one that would drift is the one deciding what people are paid.
///
/// What this layer DOES do is make sure the refusal survives the trip. Every write goes through
/// <see cref="WorkflowSqlErrors.MapAsync"/>, which turns a RAISERROR into a 400 carrying the
/// procedure's own sentence. Those sentences were written to be read by the person who hit them —
/// "Attendance for 2026-08 is not ready for payroll…", "This run is locked. A locked run is never
/// regenerated — corrections go to the next period." — and nothing here rewords, shortens or
/// pre-empts them by guessing the same rule badly first.
///
/// Blank strings are passed through for the same reason: an empty cancel reason should earn "A
/// reason is required to cancel a payroll run.", not a generic client-side complaint.
/// </summary>
public class PayrollService : IPayrollService
{
    private readonly IPayrollRepository _repo;
    public PayrollService(IPayrollRepository repo) => _repo = repo;

    // ───────────────────────────────── runs ─────────────────────────────────

    public Task<IEnumerable<PayrollRunListItem>> GetRunsAsync() => _repo.GetRunsAsync();

    /// <summary>
    /// Creates a run. The period shape, the duplicate guard, the attendance gate and the missing-rate
    /// check all live in the procedure; each has its own sentence naming what to fix.
    /// </summary>
    public Task<PayrollRunCreated?> CreateRunAsync(PayrollRunCreateRequest request, int createdByUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.CreateRunAsync(
            request.PeriodYearMonth?.Trim() ?? string.Empty,
            createdByUserId,
            string.IsNullOrWhiteSpace(request.Notes) ? null : request.Notes.Trim(),
            // Not defaulted to "Primary" here: a blank lets the PROCEDURE own the default, so there
            // is one place that decides it rather than two that can disagree.
            string.IsNullOrWhiteSpace(request.RunType) ? null : request.RunType.Trim()));

    public Task<PayrollRunDetail> GetRunAsync(int payrollRunId) => _repo.GetRunAsync(payrollRunId);

    public Task<IEnumerable<PayslipListItem>> GetRunPayslipsAsync(int payrollRunId)
        => _repo.GetRunPayslipsAsync(payrollRunId);

    /// <summary>
    /// Generates, and the RUN'S OWN TYPE decides which generator does it.
    ///
    /// The type is read from the run rather than accepted from the caller: a supplemental sent
    /// through the primary generator would rebuild the whole company's payslips into an off-cycle
    /// run, and the caller is in no position to be trusted with that distinction. One extra read
    /// buys the guarantee that the two can never be crossed.
    ///
    /// Regenerating a LOCKED run is refused by both procedures — that refusal is the lock.
    /// </summary>
    public async Task<PayrollRunGenerateResult?> GenerateAsync(int payrollRunId, int actedByUserId)
    {
        var detail = await _repo.GetRunAsync(payrollRunId);
        if (detail.Header is null)
            return null;

        return await WorkflowSqlErrors.MapAsync(() =>
            string.Equals(detail.Header.RunType, "Supplemental", StringComparison.OrdinalIgnoreCase)
                ? _repo.GenerateSupplementalAsync(payrollRunId, actedByUserId)
                : _repo.GenerateAsync(payrollRunId, actedByUserId));
    }

    public Task<PayrollRunStatusResult?> SendToReviewAsync(int payrollRunId, int actedByUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.SendToReviewAsync(payrollRunId, actedByUserId));

    /// <summary>
    /// Approves and locks. Pressing it twice is safe because the SECOND call is refused — "This run
    /// is already closed." — before any of the side effects run, so advance balances cannot be
    /// reduced twice. That is the procedure's guarantee, not a guard added here.
    /// </summary>
    public Task<PayrollRunStatusResult?> ApproveAsync(int payrollRunId, int actedByUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.ApproveAsync(payrollRunId, actedByUserId));

    public Task<PayrollRunStatusResult?> CancelAsync(int payrollRunId, int actedByUserId, PayrollRunCancelRequest request)
        => WorkflowSqlErrors.MapAsync(() => _repo.CancelAsync(
            payrollRunId,
            actedByUserId,
            // Not defaulted or rejected here: an approved run refuses cancellation whatever the
            // reason says, and a blank reason on a draft earns the procedure's own message.
            string.IsNullOrWhiteSpace(request.Reason) ? null : request.Reason.Trim()));

    /// <summary>Mapped because the procedure refuses a run that is not approved, and says why.</summary>
    public Task<IEnumerable<PaymentSheetRow>> GetPaymentSheetAsync(int payrollRunId)
        => WorkflowSqlErrors.MapAsync(() => _repo.GetPaymentSheetAsync(payrollRunId));

    public Task<PayrollReadiness?> GetReadinessAsync(string periodYearMonth)
        => _repo.GetReadinessAsync(periodYearMonth);

    /// <summary>
    /// The statutory sheet. Not mapped through the SQL-error translator because it raises nothing —
    /// it is a pure read, and a run with no payslips honestly returns no rows.
    /// </summary>
    public Task<IEnumerable<StatutoryReportRow>> GetStatutoryReportAsync(int payrollRunId)
        => _repo.GetStatutoryReportAsync(payrollRunId);

    // ── payslips, read from the other side ───────────────────────────────────

    public Task<IEnumerable<MyPayslip>> GetMyPayslipsAsync(int userId)
        => _repo.GetMyPayslipsAsync(userId);

    public Task<MyPayslipStatus?> GetMyStatusAsync(int userId)
        => _repo.GetMyStatusAsync(userId);

    public Task<IEnumerable<EmployeePayslip>> GetPayslipsForEmployeeAsync(int employeeId)
        => _repo.GetPayslipsForEmployeeAsync(employeeId);

    public Task<PayslipLineLookup?> LookupLineAsync(string sourceType, int sourceId)
        => _repo.LookupLineAsync(sourceType, sourceId);

    // ─────────────────────────────── payslips ───────────────────────────────

    public Task<PayslipDetail> GetPayslipAsync(int payslipId) => _repo.GetPayslipAsync(payslipId);

    public Task<PayslipPaymentResult?> SetPaymentAsync(int payslipId, PayslipPaymentRequest request, int actedByUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.SetPaymentAsync(
            payslipId,
            request.PaymentMethod?.Trim() ?? string.Empty,
            string.IsNullOrWhiteSpace(request.PaymentReference) ? null : request.PaymentReference.Trim(),
            actedByUserId));

    // ─────────────────────────────── advances ───────────────────────────────

    public Task<IEnumerable<SalaryAdvance>> GetAdvancesAsync(int? employeeId, bool openOnly)
        => _repo.GetAdvancesAsync(employeeId, openOnly);

    /// <summary>
    /// Reschedules recovery. A settled advance refuses — there is nothing left to schedule.
    ///
    /// Deliberately still an unsigned HR act while CREATING an advance now needs two signatures:
    /// this changes the pace of recovery, never what is owed, and making somebody who is already
    /// short of money wait for a chain to reduce their monthly deduction would be the wrong trade.
    /// </summary>
    public Task<SalaryAdvanceMonthlyResult?> UpdateAdvanceMonthlyAsync(
        int salaryAdvanceId, SalaryAdvanceMonthlyRequest request, int actedByUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.UpdateAdvanceMonthlyAsync(
            salaryAdvanceId, request.MonthlyDeduction, actedByUserId));

    // ────────────────────────────── adjustments ─────────────────────────────

    public Task<IEnumerable<PayrollAdjustment>> GetAdjustmentsAsync(string targetPeriod)
        => _repo.GetAdjustmentsAsync(targetPeriod);

    /// <summary>
    /// One adjustment for every active employee.
    ///
    /// Nothing is validated here. The procedure refuses a non-positive amount, an empty reason, an
    /// unknown component and an unknown currency in its own words, and MapAsync turns each of those
    /// into a 400 with the sentence intact — which is the same bargain every other write on this
    /// service makes.
    /// </summary>
    public Task<PayrollAdjustmentBulkResult?> CreateAdjustmentsBulkAsync(
        PayrollAdjustmentBulkRequest request, int createdByUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.CreateAdjustmentsBulkAsync(request, createdByUserId));

    /// <summary>
    /// Deletes — or rather, relays the refusal. A consumed row is history; an unconsumed row that a
    /// request authorised is the residue of signatures. Both say what to do instead.
    /// </summary>
    public Task<PayrollAdjustmentDeleteResult?> DeleteAdjustmentAsync(int payrollAdjustmentId, int actedByUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.DeleteAdjustmentAsync(payrollAdjustmentId, actedByUserId));

    // ─────────────────────────────── reference ──────────────────────────────

    public Task<IEnumerable<PayrollComponentType>> GetComponentTypesAsync() => _repo.GetComponentTypesAsync();
}
