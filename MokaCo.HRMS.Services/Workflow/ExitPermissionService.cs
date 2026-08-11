using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>
/// Exit permissions. The one rule this layer enforces that the database cannot is WHO a request may
/// be raised FOR — because the id of the person a request is about is in the request body, and the
/// body is the caller's to write. Everything else is a pass-through; the SQL owns the rest.
/// </summary>
public class ExitPermissionService : IExitPermissionService
{
    private readonly IExitPermissionRepository _repo;
    private readonly IDecisionSignatureService _signature;

    public ExitPermissionService(IExitPermissionRepository repo, IDecisionSignatureService signature)
    {
        _repo = repo;
        _signature = signature;
    }

    public Task<ExitPermissionCreated?> CreateAsync(ExitPermissionCreateRequest request, ExitPermissionCaller caller)
    {
        // RAISING FOR SOMEONE ELSE. Without REQUEST_RAISE_OTHERS, the only employee id a caller may
        // file against is their own — resolved from the token, never trusted from the body. A caller
        // with no employee record cannot raise for themselves at all (there is no "self" to file as).
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

        return _repo.CreateAsync(
            request.EmployeeId, caller.UserId, request.ExitDate,
            request.FromTime, request.ToTime, request.Reason, request.ConvertToLeave, request.Title);
    }

    public Task<IEnumerable<MyExitPermission>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate)
        => _repo.GetForEmployeeAsync(employeeId, fromDate, toDate);

    public Task<ExitPermissionDetail?> GetByRequestAsync(int requestInstanceId)
        => _repo.GetByRequestAsync(requestInstanceId);

    /// <summary>
    /// THE TYPED APPROVAL — the only path that can reduce the minutes.
    ///
    /// Nothing about the figure is checked here. The procedure owns every rule (not negative, never
    /// more than what currently stands) and each refusal names the figure that is wrong; a second
    /// check in C# could only produce a vaguer version of the same sentence and would drift from it.
    ///
    /// The signature is verified FIRST, exactly as every other typed decide does it, so a wrong
    /// password is a 401 that changes nothing at all.
    /// </summary>
    public async Task<ExitPermissionDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, ExitPermissionDecideRequest request)
    {
        var signed = await _signature.VerifyAsync(requestInstanceId, actedByUserId, request.Password);

        return await WorkflowSqlErrors.MapAsync(() => _repo.DecideAsync(
            requestInstanceId,
            actedByUserId,
            request.ApprovedMinutes,
            string.IsNullOrWhiteSpace(request.Comment) ? null : request.Comment.Trim(),
            signed));
    }

    public Task<ApplyResult> ApplyToAttendanceAsync(int? exitPermissionId, DateTime? workDate)
        => _repo.ApplyToAttendanceAsync(exitPermissionId, workDate);

    public Task<IEnumerable<PendingApplication>> GetPendingApplicationAsync()
        => _repo.GetPendingApplicationAsync();

    public Task<PostLeaveResult> PostLeaveUsageAsync(PostLeaveRequest request, int? postedBy)
        => _repo.PostLeaveUsageAsync(request.PeriodYearMonth, request.LeaveTypeId, postedBy);
}
