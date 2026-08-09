using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>The caller's identity and right to raise for others, as resolved from the token.</summary>
public record SeparationCaller(int UserId, int? EmployeeId, bool HasRaiseOthers);

public interface ISeparationService
{
    Task<SeparationContext> GetContextAsync(int employeeId, DateTime? lastWorkingDate, DateTime? noticeGivenDate);
    Task<SeparationCreated?> CreateAsync(SeparationCreateRequest request, SeparationCaller caller);

    /// <summary>
    /// Saves the preparer's figures. <paramref name="mayEdit"/> is the caller's right to prepare this
    /// settlement, decided by the CONTROLLER — see the note on the implementation.
    /// </summary>
    Task<SeparationSettlement?> SetSettlementAsync(
        int requestInstanceId, int actedByUserId, SeparationSettlementRequest request, bool mayEdit);

    Task<SeparationDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, SeparationDecideRequest request);
    Task<SeparationPayload?> GetPayloadAsync(int requestInstanceId);
}

/// <summary>
/// Separations — resignation, termination, end of contract, retirement.
///
/// As with every typed request the one rule this layer enforces that the database cannot is WHO a
/// request may be raised FOR: the employee id travels in the body. Everything else belongs to the
/// procedures, and here that includes the two things that make this type different from all the
/// others — the refusal of a final sign-off on an unprepared settlement, and the pair of irreversible
/// effects that follow a successful one. Neither is touched here, because both are guarded by their
/// own stamps in SQL and a "helpful" second implementation is precisely what would run them twice.
/// </summary>
public class SeparationService : ISeparationService
{
    private readonly ISeparationRepository _repo;
    private readonly IDecisionSignatureService _signature;

    public SeparationService(ISeparationRepository repo, IDecisionSignatureService signature)
    {
        _repo = repo;
        _signature = signature;
    }

    public Task<SeparationContext> GetContextAsync(int employeeId, DateTime? lastWorkingDate, DateTime? noticeGivenDate)
        => _repo.GetContextAsync(employeeId, lastWorkingDate, noticeGivenDate);

    public Task<SeparationCreated?> CreateAsync(SeparationCreateRequest request, SeparationCaller caller)
    {
        if (!caller.HasRaiseOthers)
        {
            if (caller.EmployeeId is not int self)
                throw new WorkflowException(
                    403,
                    "Your account is not linked to an employee, so you cannot raise a request for yourself.");

            // A resignation IS raised for yourself; a termination is not. The distinction is the
            // permission, not the separation type — somebody without raise-for-others may resign and
            // nothing more.
            if (request.EmployeeId != self)
                throw new WorkflowException(
                    403,
                    "You may only raise a request for yourself. Raising on another employee's behalf needs additional permission.");
        }

        return WorkflowSqlErrors.MapAsync(() => _repo.CreateAsync(
            request.EmployeeId, caller.UserId,
            request.SeparationType?.Trim() ?? string.Empty,
            request.NoticeGivenDate, request.LastWorkingDate,
            Clean(request.Reason), Clean(request.Title)));
    }

    /// <summary>
    /// Saves the preparer's figures.
    /// </summary>
    /// <remarks>
    /// THE CLOSED-REQUEST RULE AND THE NEGATIVE-AMOUNT RULE ARE NOT CHECKED HERE — the procedure
    /// refuses both with sentences that say what to do ("Use Deductions for amounts withheld"), and a
    /// duplicate check would only produce a vaguer one. What IS decided outside the procedure is WHO
    /// may prepare: the database knows the approval chain but not that HR may do the paperwork
    /// whatever step it is on, and that judgement needs the caller's permissions.
    /// </remarks>
    public Task<SeparationSettlement?> SetSettlementAsync(
        int requestInstanceId, int actedByUserId, SeparationSettlementRequest request, bool mayEdit)
    {
        if (!mayEdit)
            throw new WorkflowException(
                403,
                "Only the approver at the current step, or HR, may prepare this settlement.");

        return WorkflowSqlErrors.MapAsync(() => _repo.SetSettlementAsync(
            requestInstanceId, actedByUserId,
            new SeparationSettlementRequest
            {
                CurrencyCode = request.CurrencyCode?.Trim().ToUpperInvariant() ?? string.Empty,
                UnusedLeaveDays = request.UnusedLeaveDays,
                UnusedLeaveAmount = request.UnusedLeaveAmount,
                IndemnityAmount = request.IndemnityAmount,
                NoticePayAmount = request.NoticePayAmount,
                OtherDues = request.OtherDues,
                Deductions = request.Deductions,
                SettlementNote = Clean(request.SettlementNote),
            }));
    }

    public async Task<SeparationDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, SeparationDecideRequest request)
    {
        var signed = await _signature.VerifyAsync(requestInstanceId, actedByUserId, request.Password);
        return await WorkflowSqlErrors.MapAsync(() => _repo.DecideAsync(
            requestInstanceId, actedByUserId, Clean(request.Comment), signed));
    }

    public Task<SeparationPayload?> GetPayloadAsync(int requestInstanceId)
        => _repo.GetPayloadAsync(requestInstanceId);

    /// <summary>Blank and whitespace both mean "not given" — the procedures' NULL, not an empty string.</summary>
    private static string? Clean(string? value)
        => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}
