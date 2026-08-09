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
    /// Signs the decision. The signature is verified exactly as the other typed decides do — the
    /// step says whether one is required, and the password is checked against the caller's own hash.
    /// </summary>
    public async Task<PayrollAdjustmentDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, PayrollAdjustmentDecideRequest request)
    {
        var signed = await _signature.VerifyAsync(requestInstanceId, actedByUserId, request.Password);
        return await WorkflowSqlErrors.MapAsync(() => _repo.DecideAsync(
            requestInstanceId, actedByUserId,
            string.IsNullOrWhiteSpace(request.Comment) ? null : request.Comment.Trim(),
            signed));
    }

    public Task<PayrollAdjustmentPayload?> GetPayloadAsync(int requestInstanceId)
        => _repo.GetPayloadAsync(requestInstanceId);
}
