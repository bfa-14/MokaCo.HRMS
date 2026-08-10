using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>The caller's identity and right to raise for others, as resolved from the token.</summary>
public record PayrollAdjustmentCaller(int UserId, int? EmployeeId, bool HasRaiseOthers);

public interface IPayrollAdjustmentService
{
    Task<PayrollAdjustmentCreated?> CreateAsync(PayrollAdjustmentCreateRequest request, PayrollAdjustmentCaller caller);
    Task<PayrollAdjustmentDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, PayrollAdjustmentDecideRequest request);
    Task<PayrollAdjustmentPayload?> GetPayloadAsync(int requestInstanceId);
}

/// <summary>
/// Payroll adjustment requests — a correction with a chain behind it.
///
/// As with every typed request, the one rule this layer enforces that the database cannot is WHO a
/// request may be raised FOR: the employee id travels in the body, and the body is the caller's to
/// write. In practice HR raises these on other people's behalf, which is the whole point of the type,
/// so the check almost always passes through REQUEST_RAISE_OTHERS — but it stays, because without it
/// anyone able to raise for themselves could write another person's name into the body.
///
/// Everything else is the procedures': the reason, the positive amount, the locked-period refusals at
/// BOTH create and final approval, and the single write of the ledger row. The refusal that matters
/// most here is the one nobody can plan around — "The 2026-09 run locked while this request waited.
/// Reject it and raise it again for the next open period." — and it reaches the user verbatim.
/// </summary>
public class PayrollAdjustmentService : IPayrollAdjustmentService
{
    private readonly IPayrollAdjustmentRepository _repo;
    private readonly IDecisionSignatureService _signature;

    public PayrollAdjustmentService(IPayrollAdjustmentRepository repo, IDecisionSignatureService signature)
    {
        _repo = repo;
        _signature = signature;
    }

    public Task<PayrollAdjustmentCreated?> CreateAsync(PayrollAdjustmentCreateRequest request, PayrollAdjustmentCaller caller)
    {
        if (!caller.HasRaiseOthers)
        {
            if (caller.EmployeeId is not int self)
                throw new WorkflowException(
                    403,
                    "Your account is not linked to an employee, so you cannot raise a request for yourself.");

            if (request.EmployeeId != self)
                throw new WorkflowException(
                    403,
                    "You may only raise a request for yourself. Raising on another employee's behalf needs additional permission.");
        }

        return WorkflowSqlErrors.MapAsync(() => _repo.CreateAsync(
            request.EmployeeId, caller.UserId, request.ComponentTypeId, request.Amount,
            request.CurrencyCode?.Trim() ?? string.Empty,
            request.TargetPeriod?.Trim() ?? string.Empty,
            request.CorrectsRunId,
            string.IsNullOrWhiteSpace(request.Reason) ? null : request.Reason.Trim(),
            string.IsNullOrWhiteSpace(request.Title) ? null : request.Title.Trim()));
    }

    /// <summary>
    /// Signs the decision, INCLUDING THE FIGURE. The signature is verified exactly as the other
    /// typed decides do — the step says whether one is required, and the password is checked
    /// against the caller's own hash.
    ///
    /// ONLY THE SHAPE IS CHECKED HERE: that a figure arrived at all, and that it is above zero.
    /// Both of those are facts about the request body, knowable without reading a single row. The
    /// two rules that matter — no more than was requested, and no more than an earlier approver
    /// allowed — need the request's own history and stay in the procedure, whose refusals travel
    /// back verbatim. Duplicating them here would create a second authority on what a person is
    /// owed, and the day the two disagree is the day nobody can say which was right.
    /// </summary>
    public async Task<PayrollAdjustmentDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, PayrollAdjustmentDecideRequest request)
    {
        // Null and zero are different mistakes: one is a client that forgot the field, the other is
        // somebody trying to approve nothing. The procedure says the same two things; saying them
        // here as well costs one comparison and saves a round trip.
        if (request.ApprovedAmount is not decimal approvedAmount)
            throw new WorkflowException(
                400,
                "State the approved amount - the figure you sign is what the payslip will carry.");

        if (approvedAmount <= 0)
            throw new WorkflowException(
                400,
                "The approved amount must be above zero. To grant nothing, reject the request.");

        var signed = await _signature.VerifyAsync(requestInstanceId, actedByUserId, request.Password);
        return await WorkflowSqlErrors.MapAsync(() => _repo.DecideAsync(
            requestInstanceId, actedByUserId, approvedAmount,
            string.IsNullOrWhiteSpace(request.Comment) ? null : request.Comment.Trim(),
            signed));
    }

    public Task<PayrollAdjustmentPayload?> GetPayloadAsync(int requestInstanceId)
        => _repo.GetPayloadAsync(requestInstanceId);
}
