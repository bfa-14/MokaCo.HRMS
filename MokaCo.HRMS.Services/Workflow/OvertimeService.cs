using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>The caller's identity and right to raise for others, as resolved from the token.</summary>
public record OvertimeCaller(int UserId, int? EmployeeId, bool HasRaiseOthers);

public interface IOvertimeService
{
    Task<OvertimeCreated?> CreateAsync(OvertimeCreateRequest request, OvertimeCaller caller);
    Task<OvertimeDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, OvertimeDecideRequest request);
    Task<OvertimePayload?> GetPayloadAsync(int requestInstanceId);
    Task<IEnumerable<MyOvertime>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate);
    Task<OvertimeApplyResult> ApplyToAttendanceAsync(DateTime? workDate);
}

/// <summary>
/// Overtime. Like the other typed requests, the one rule this layer enforces that the database
/// cannot is WHO a request may be raised FOR — the employee id is in the body, and the body is the
/// caller's to write. Everything else is the procedures'.
/// </summary>
public class OvertimeService : IOvertimeService
{
    private readonly IOvertimeRepository _repo;
    private readonly IDecisionSignatureService _signature;

    public OvertimeService(IOvertimeRepository repo, IDecisionSignatureService signature)
    {
        _repo = repo;
        _signature = signature;
    }

    public Task<OvertimeCreated?> CreateAsync(OvertimeCreateRequest request, OvertimeCaller caller)
    {
        // RAISING FOR SOMEONE ELSE. Without REQUEST_RAISE_OTHERS the only employee id a caller may
        // file against is their own — resolved from the token, never trusted from the body.
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

        // Mapped so the PAST-DATE refusal — the one people hit most — arrives as a 400 carrying the
        // procedure's own sentence, rather than a 500 that says nothing.
        return WorkflowSqlErrors.MapAsync(() => _repo.CreateAsync(
            request.EmployeeId, caller.UserId, request.WorkDate, request.RequestedMinutes,
            string.IsNullOrWhiteSpace(request.Reason) ? null : request.Reason.Trim(),
            string.IsNullOrWhiteSpace(request.Title) ? null : request.Title.Trim()));
    }

    /// <summary>
    /// Decides at a stated cap. THE FIGURE IS NOT CHECKED HERE: that it must be present, above zero,
    /// no more than was requested and no more than an earlier approver already allowed are all the
    /// procedure's rules, and each refusal names the specific figure at issue — "An earlier approver
    /// capped this at 60 minutes…" is a sentence no re-implementation here would improve on.
    /// </summary>
    public async Task<OvertimeDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, OvertimeDecideRequest request)
    {
        var signed = await _signature.VerifyAsync(requestInstanceId, actedByUserId, request.Password);
        return await WorkflowSqlErrors.MapAsync(() => _repo.DecideAsync(
            requestInstanceId, actedByUserId, request.ApprovedMinutes,
            string.IsNullOrWhiteSpace(request.Comment) ? null : request.Comment.Trim(),
            signed));
    }

    public Task<OvertimePayload?> GetPayloadAsync(int requestInstanceId)
        => _repo.GetPayloadAsync(requestInstanceId);

    public Task<IEnumerable<MyOvertime>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate)
        => _repo.GetForEmployeeAsync(employeeId, fromDate, toDate);

    public Task<OvertimeApplyResult> ApplyToAttendanceAsync(DateTime? workDate)
        => _repo.ApplyToAttendanceAsync(workDate);
}
