using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>The caller's identity and right to raise for others, as resolved from the token.</summary>
public record SalaryAdvanceCaller(int UserId, int? EmployeeId, bool HasRaiseOthers);

public interface ISalaryAdvanceService
{
    Task<SalaryAdvanceCreated?> CreateAsync(SalaryAdvanceCreateRequest request, SalaryAdvanceCaller caller);
    Task<SalaryAdvanceDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, SalaryAdvanceDecideRequest request);
    Task<SalaryAdvancePayload?> GetPayloadAsync(int requestInstanceId);
}

/// <summary>
/// Salary advances raised as requests.
///
/// Unlike the payroll adjustment — HR's instrument, always raised on somebody else's behalf — this
/// one is normally raised BY the person who needs the money. So the raise-for-others check earns
/// its keep here: without REQUEST_RAISE_OTHERS, the only employee id a caller may put in the body
/// is their own, and that is resolved from the token rather than trusted from the body.
///
/// Everything else is the procedures': the monthly bound, the open-month rule at both create and
/// final approval, and the one that keeps recovery legible — one advance per employee at a time.
/// Its refusal is the one people meet most, so it travels verbatim.
/// </summary>
public class SalaryAdvanceService : ISalaryAdvanceService
{
    private readonly ISalaryAdvanceRepository _repo;
    private readonly IDecisionSignatureService _signature;

    public SalaryAdvanceService(ISalaryAdvanceRepository repo, IDecisionSignatureService signature)
    {
        _repo = repo;
        _signature = signature;
    }

    public Task<SalaryAdvanceCreated?> CreateAsync(SalaryAdvanceCreateRequest request, SalaryAdvanceCaller caller)
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
            request.EmployeeId, caller.UserId, request.Amount,
            request.CurrencyCode?.Trim() ?? string.Empty,
            request.MonthlyDeduction,
            request.FirstDeductionPeriod?.Trim() ?? string.Empty,
            string.IsNullOrWhiteSpace(request.Reason) ? null : request.Reason.Trim(),
            string.IsNullOrWhiteSpace(request.Title) ? null : request.Title.Trim()));
    }

    /// <summary>
    /// Signs the decision and BOTH figures. Only the amount's shape is checked here — present, and
    /// above zero. The monthly deduction is deliberately NOT validated in C#: null is a legitimate
    /// value meaning "keep the standing schedule", and whether a stated monthly is acceptable
    /// depends on the approved amount the procedure is about to settle on. Guessing at that here
    /// would refuse figures the procedure would have accepted.
    /// </summary>
    public async Task<SalaryAdvanceDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, SalaryAdvanceDecideRequest request)
    {
        if (request.ApprovedAmount is not decimal approvedAmount)
            throw new WorkflowException(
                400,
                "State the approved amount - the figure you sign is what will be handed over.");

        if (approvedAmount <= 0)
            throw new WorkflowException(
                400,
                "The approved amount must be above zero. To grant nothing, reject the request.");

        var signed = await _signature.VerifyAsync(requestInstanceId, actedByUserId, request.Password);
        return await WorkflowSqlErrors.MapAsync(() => _repo.DecideAsync(
            requestInstanceId, actedByUserId, approvedAmount, request.ApprovedMonthlyDeduction,
            string.IsNullOrWhiteSpace(request.Comment) ? null : request.Comment.Trim(),
            signed));
    }

    public Task<SalaryAdvancePayload?> GetPayloadAsync(int requestInstanceId)
        => _repo.GetPayloadAsync(requestInstanceId);
}
