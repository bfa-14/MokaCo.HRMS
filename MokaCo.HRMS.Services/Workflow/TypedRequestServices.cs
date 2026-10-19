using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

public interface ITipDistributionService
{
    Task<TipDistributionCreated?> CreateAsync(TipDistributionCreateRequest request, int raisedByUserId);
    Task<TipDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, TipDecideRequest request);
    Task<TipDistributionPayload> GetPayloadAsync(int requestInstanceId);
}

/// <summary>The caller's identity and right to raise for others, as resolved from the token.</summary>
public record ShiftSwapCaller(int UserId, int? EmployeeId, bool HasRaiseOthers);

public interface IShiftSwapService
{
    Task<ShiftSwapCreated?> CreateAsync(ShiftSwapCreateRequest request, ShiftSwapCaller caller);
    Task<TypedDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, TypedDecideRequest request);
    Task<ShiftSwapPayload?> GetPayloadAsync(int requestInstanceId);
}

/// <summary>
/// Tip distributions.
///
/// NOTE WHAT IS NOT HERE: there is no raise-for-others rule, because a tip distribution is not
/// raised FOR anybody — the procedure resolves the requester from the token's own user and refuses
/// a login with no employee record. The participants are a separate list, validated by the
/// procedure against the branch. So this layer only maps SQL refusals to statuses and verifies the
/// signature; it decides nothing.
/// </summary>
public class TipDistributionService : ITipDistributionService
{
    private readonly ITipDistributionRepository _repo;
    private readonly IDecisionSignatureService _signature;

    public TipDistributionService(ITipDistributionRepository repo, IDecisionSignatureService signature)
    {
        _repo = repo;
        _signature = signature;
    }

    public Task<TipDistributionCreated?> CreateAsync(TipDistributionCreateRequest request, int raisedByUserId)
        // Every refusal — an empty or non-positive amount, an unknown or duplicated currency, a
        // participant from another branch (named), no employee record — arrives as a 400 carrying
        // the procedure's own sentence.
        => WorkflowSqlErrors.MapAsync(() => _repo.CreateAsync(
            raisedByUserId, request.BranchId, request.ShiftDate,
            request.Amounts ?? new List<TipAmount>(), request.ParticipantIds ?? Array.Empty<int>(),
            string.IsNullOrWhiteSpace(request.Title) ? null : request.Title.Trim()));

    /// <summary>
    /// Decides, optionally restating the split.
    ///
    /// NOTHING ABOUT THE REDISTRIBUTION IS CHECKED HERE. Every rule — the shares summing exactly to
    /// each pooled currency, the currencies not changing, the participants belonging to the branch,
    /// the step actually allowing an adjustment — belongs to the procedure, and each refusal carries a
    /// sentence naming the specific figure that is wrong. A second check in C# could only produce a
    /// vaguer version of the same message, and would drift from it the moment either changed.
    ///
    /// An EMPTY list is normalised to null: "I opened the redistribute panel and removed every row"
    /// is not a distribution, and treating it as one earns a confusing refusal instead of simply
    /// approving as calculated.
    /// </summary>
    public async Task<TipDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, TipDecideRequest request)
    {
        var signed = await _signature.VerifyAsync(requestInstanceId, actedByUserId, request.Password);
        var lines = request.LinesJson is { Count: > 0 } ? request.LinesJson : null;
        return await WorkflowSqlErrors.MapAsync(() => _repo.DecideAsync(
            requestInstanceId, actedByUserId, lines,
            string.IsNullOrWhiteSpace(request.Comment) ? null : request.Comment.Trim(),
            signed));
    }

    public Task<TipDistributionPayload> GetPayloadAsync(int requestInstanceId)
        => _repo.GetPayloadAsync(requestInstanceId);
}

/// <summary>
/// Shift swaps. As above, a pass-through with two jobs: map the procedure's refusals to statuses
/// with their wording intact, and verify the signature before any write — plus the one rule the
/// database cannot know, WHO the swap may be raised FOR (QA3 WF-12): the requester's employee id is in
/// the body, so without REQUEST_RAISE_OTHERS it must be the caller's own, as for every other typed
/// request. (Before, anybody could put a colleague's shift up for swap in the colleague's name.)
///
/// The consent tick is NOT re-checked here. The procedure refuses a false one, and its sentence
/// ("A swap needs the counterpart's agreement first…") is better than anything this layer would
/// invent — a second check would only create a second, quieter message.
/// </summary>
public class ShiftSwapService : IShiftSwapService
{
    private readonly IShiftSwapRepository _repo;
    private readonly IDecisionSignatureService _signature;

    public ShiftSwapService(IShiftSwapRepository repo, IDecisionSignatureService signature)
    {
        _repo = repo;
        _signature = signature;
    }

    public Task<ShiftSwapCreated?> CreateAsync(ShiftSwapCreateRequest request, ShiftSwapCaller caller)
    {
        // RAISING FOR SOMEONE ELSE. Without REQUEST_RAISE_OTHERS the only employee id a caller may
        // file against is their own — resolved from the token, never trusted from the body. The
        // counterpart is the OTHER party of the swap and is the procedure's to check (same role,
        // consent, both rostered).
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
            request.EmployeeId, caller.UserId, request.CounterpartEmployeeId,
            request.RequesterDate, request.CounterpartDate, request.CounterpartHasAgreed,
            string.IsNullOrWhiteSpace(request.Title) ? null : request.Title.Trim()));
    }

    public async Task<TypedDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, TypedDecideRequest request)
    {
        var signed = await _signature.VerifyAsync(requestInstanceId, actedByUserId, request.Password);
        return await WorkflowSqlErrors.MapAsync(() => _repo.DecideAsync(
            requestInstanceId, actedByUserId,
            string.IsNullOrWhiteSpace(request.Comment) ? null : request.Comment.Trim(),
            signed));
    }

    public Task<ShiftSwapPayload?> GetPayloadAsync(int requestInstanceId)
        => _repo.GetPayloadAsync(requestInstanceId);
}
