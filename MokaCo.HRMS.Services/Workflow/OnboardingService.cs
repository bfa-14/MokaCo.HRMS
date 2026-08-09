using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

public interface IOnboardingService
{
    Task<OnboardingCreated?> CreateAsync(OnboardingCreateRequest request, int raisedByUserId);
    Task<OnboardingDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, OnboardingDecideRequest request);

    /// <summary>
    /// Ticks or unticks one item. <paramref name="mayEdit"/> is the caller's right to touch this
    /// checklist, decided by the CONTROLLER — see the note on the implementation.
    /// </summary>
    Task<IEnumerable<OnboardingTask>> SetTaskAsync(
        int requestInstanceId, string code, OnboardingSetTaskRequest request, int actedByUserId, bool mayEdit);

    Task<OnboardingPayload> GetPayloadAsync(int requestInstanceId);
}

/// <summary>
/// New-hire onboarding — a hire decision and the paperwork that has to follow it.
///
/// THERE IS NO RAISE-FOR-OTHERS RULE HERE, and its absence is deliberate rather than an omission:
/// every other typed request carries an employee id in the body, which is why those services police
/// who it may name. An onboarding names a CANDIDATE, who is nobody in the system yet, so there is no
/// existing person to raise it "for" and nothing for that rule to protect. The procedure takes the
/// requester from the token and refuses a login with no employee record behind it.
///
/// Everything else is the procedures': the duplicate-in-flight guard, the creation of the employee
/// record at the hire decision, and the refusal of the closing signature while required items are
/// outstanding.
/// </summary>
public class OnboardingService : IOnboardingService
{
    private readonly IOnboardingRepository _repo;
    private readonly IDecisionSignatureService _signature;

    public OnboardingService(IOnboardingRepository repo, IDecisionSignatureService signature)
    {
        _repo = repo;
        _signature = signature;
    }

    public Task<OnboardingCreated?> CreateAsync(OnboardingCreateRequest request, int raisedByUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.CreateAsync(
            raisedByUserId,
            request.CandidateName?.Trim() ?? string.Empty,
            request.BranchId, request.DepartmentId, request.PositionId, request.StartDate,
            Clean(request.NationalId), Clean(request.NssfNumber), Clean(request.TaxNumber),
            Clean(request.BankAccount), Clean(request.Notes), Clean(request.Title)));

    public async Task<OnboardingDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, OnboardingDecideRequest request)
    {
        var signed = await _signature.VerifyAsync(requestInstanceId, actedByUserId, request.Password);
        return await WorkflowSqlErrors.MapAsync(() => _repo.DecideAsync(
            requestInstanceId, actedByUserId, Clean(request.Comment), signed));
    }

    /// <summary>
    /// Ticks or unticks one item.
    /// </summary>
    /// <remarks>
    /// THE CLOSED-REQUEST RULE IS NOT CHECKED HERE. The procedure refuses it with "This onboarding is
    /// closed; its checklist is now history." — which says something a status code cannot, so it is
    /// left to say it. What IS decided outside the procedure is WHO may tick: the database knows the
    /// approval chain but not that HR may do the paperwork regardless of whose step it is, and that
    /// judgement needs the caller's permissions, which only the controller holds.
    /// </remarks>
    public Task<IEnumerable<OnboardingTask>> SetTaskAsync(
        int requestInstanceId, string code, OnboardingSetTaskRequest request, int actedByUserId, bool mayEdit)
    {
        if (!mayEdit)
            throw new WorkflowException(
                403,
                "Only the approver at the current step, or HR, may tick items on this checklist.");

        return WorkflowSqlErrors.MapAsync(() => _repo.SetTaskAsync(
            requestInstanceId, code, request.IsComplete, actedByUserId, Clean(request.Note)));
    }

    public Task<OnboardingPayload> GetPayloadAsync(int requestInstanceId)
        => _repo.GetPayloadAsync(requestInstanceId);

    /// <summary>Blank and whitespace both mean "not given" — the procedures' NULL, not an empty string.</summary>
    private static string? Clean(string? value)
        => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}
