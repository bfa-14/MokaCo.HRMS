using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>The caller's identity and right to raise for others, as resolved from the token.</summary>
public record AvailabilityCaller(int UserId, int? EmployeeId, bool HasRaiseOthers);

public interface IAvailabilityService
{
    Task<AvailabilityCreated?> CreateAsync(AvailabilityCreateRequest request, AvailabilityCaller caller);
    Task<AvailabilityDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, AvailabilityDecideRequest request);
    Task<AvailabilityPayload> GetPayloadAsync(int requestInstanceId);
    Task<IEnumerable<AvailabilityConflict>> GetConflictsAsync(int requestInstanceId);
}

/// <summary>
/// Standing availability changes — a rewrite of somebody's default week from a date onwards.
///
/// As with every typed request, the ONE rule this layer enforces that the database cannot is WHO a
/// request may be raised FOR: the employee id travels in the body, and the body is the caller's to
/// write. Everything else is the procedures' — the past-date refusal, the whole-week-unavailable
/// refusal, the one-in-flight-per-employee rule, the unknown shift, and the MERGE into
/// EMPLOYEE_SHIFT_PATTERN at final approval. Each of those names its own cause, and a second check
/// here could only produce a vaguer version of the same sentence.
/// </summary>
public class AvailabilityService : IAvailabilityService
{
    private readonly IAvailabilityRepository _repo;
    private readonly IDecisionSignatureService _signature;

    public AvailabilityService(IAvailabilityRepository repo, IDecisionSignatureService signature)
    {
        _repo = repo;
        _signature = signature;
    }

    public Task<AvailabilityCreated?> CreateAsync(AvailabilityCreateRequest request, AvailabilityCaller caller)
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
            request.EmployeeId, caller.UserId, request.EffectiveFrom,
            request.Days ?? new List<AvailabilityDay>(),
            string.IsNullOrWhiteSpace(request.Reason) ? null : request.Reason.Trim(),
            string.IsNullOrWhiteSpace(request.Title) ? null : request.Title.Trim()));
    }

    /// <summary>
    /// Decides, optionally restating the days.
    ///
    /// An EMPTY list is normalised to null: "I opened the restate editor and cleared every row" is not
    /// a restatement, and sending it as one earns "The restatement has no days" instead of simply
    /// approving what was asked.
    /// </summary>
    public async Task<AvailabilityDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, AvailabilityDecideRequest request)
    {
        var signed = await _signature.VerifyAsync(requestInstanceId, actedByUserId, request.Password);
        var days = request.Days is { Count: > 0 } ? request.Days : null;
        return await WorkflowSqlErrors.MapAsync(() => _repo.DecideAsync(
            requestInstanceId, actedByUserId, days,
            string.IsNullOrWhiteSpace(request.Comment) ? null : request.Comment.Trim(),
            signed));
    }

    public Task<AvailabilityPayload> GetPayloadAsync(int requestInstanceId)
        => _repo.GetPayloadAsync(requestInstanceId);

    public Task<IEnumerable<AvailabilityConflict>> GetConflictsAsync(int requestInstanceId)
        => _repo.GetConflictsAsync(requestInstanceId);
}
