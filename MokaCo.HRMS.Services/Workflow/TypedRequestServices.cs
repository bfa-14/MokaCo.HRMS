using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

public interface ITipDistributionService
{
    Task<TipDistributionCreated?> CreateAsync(TipDistributionCreateRequest request, int raisedByUserId);
    Task<TipDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, TipDecideRequest request);
    Task<TipDistributionPayload> GetPayloadAsync(int requestInstanceId);
}

public interface IShiftSwapService
{
    Task<ShiftSwapCreated?> CreateAsync(ShiftSwapCreateRequest request, int raisedByUserId);
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
/// with their wording intact, and verify the signature before any write.
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

    public Task<ShiftSwapCreated?> CreateAsync(ShiftSwapCreateRequest request, int raisedByUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.CreateAsync(
            request.EmployeeId, raisedByUserId, request.CounterpartEmployeeId,
            request.RequesterDate, request.CounterpartDate, request.CounterpartHasAgreed,
            string.IsNullOrWhiteSpace(request.Title) ? null : request.Title.Trim()));

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
