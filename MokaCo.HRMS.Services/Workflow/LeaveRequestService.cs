using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Repository.Workflow;
using MokaCo.HRMS.Services.Auth;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>
/// Leave requests. Like exit permissions, the one rule this layer enforces that the database cannot
/// is WHO a request may be raised FOR. Everything else — the overlap refusal, the day count, the
/// bound on the granted figure, the once-only ledger posting — belongs to the procedures, and their
/// refusals are mapped to statuses here with the message left exactly as written.
///
/// The signature is checked the same way a plain approval checks it: the requirement is re-read from
/// the database rather than trusted from the client, so omitting the password cannot skip a signature
/// the policy demands.
/// </summary>
public class LeaveRequestService : ILeaveRequestService
{
    private readonly ILeaveRequestRepository _repo;
    private readonly IRequestRepository _requests;
    private readonly IUserRepository _users;
    private readonly IPasswordHasher _hasher;

    public LeaveRequestService(
        ILeaveRequestRepository repo,
        IRequestRepository requests,
        IUserRepository users,
        IPasswordHasher hasher)
    {
        _repo = repo;
        _requests = requests;
        _users = users;
        _hasher = hasher;
    }

    public Task<LeaveRequestCreated?> CreateAsync(LeaveRequestCreateRequest request, LeaveRequestCaller caller)
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

        // Mapped, unlike the exit-permission create: the overlap refusal is a user-fixable rule, and a
        // 500 would bury the one sentence that says which dates clash.
        // Every policy refusal the procedure raises — the service gate, the relation cap, the fixed
        // entitlement, the overlap — arrives here as a 400 with its own sentence. Those sentences
        // are the whole value ("Annual leave can be used after 12 months of service; this employee
        // will have 4 at the start date"), so nothing is rewritten or generalised on the way out.
        return WorkflowSqlErrors.MapAsync(() => _repo.CreateAsync(
            request.EmployeeId, caller.UserId, request.LeaveTypeId,
            request.FromDate, request.ToDate,
            string.IsNullOrWhiteSpace(request.Reason) ? null : request.Reason.Trim(),
            string.IsNullOrWhiteSpace(request.Title) ? null : request.Title.Trim(),
            string.IsNullOrWhiteSpace(request.RelationToEmployee) ? null : request.RelationToEmployee.Trim()));
    }

    public async Task<LeaveRequestDecideResult?> DecideAsync(int requestInstanceId, int actedByUserId, LeaveRequestDecideRequest request)
    {
        var signed = await VerifySignatureAsync(requestInstanceId, actedByUserId, request.Password);

        return await WorkflowSqlErrors.MapAsync(() => _repo.DecideAsync(
            requestInstanceId, actedByUserId, request.ApprovedDays,
            string.IsNullOrWhiteSpace(request.Comment) ? null : request.Comment.Trim(),
            signed,
            // Not gated here. Who may waive a deduction is the same question as who may approve at
            // all, and that answer belongs to the procedure — this layer would only be guessing.
            request.MakeDiscretionary));
    }

    public Task<LeaveRequestPayload?> GetPayloadAsync(int requestInstanceId)
        => _repo.GetPayloadAsync(requestInstanceId);

    public Task<IEnumerable<MyLeaveRequest>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate)
        => _repo.GetForEmployeeAsync(employeeId, fromDate, toDate);

    public Task<LeaveBalanceSummary?> GetBalanceAsync(int employeeId, int leaveTypeId)
        => _repo.GetBalanceAsync(employeeId, leaveTypeId);

    /// <summary>
    /// THE SIGNATURE, on the same terms as any other decision: the requirement is re-read from the
    /// database, an unrequested password is dropped rather than half-checked, and a wrong one is a 401
    /// raised BEFORE anything is written. Returns whether the act was signed — the only thing recorded.
    /// </summary>
    private async Task<bool> VerifySignatureAsync(int requestInstanceId, int userId, string? password)
    {
        var requirement = await _requests.GetSignatureRequirementAsync(requestInstanceId, userId);
        if (requirement?.SignatureRequired != true)
            return false;

        if (string.IsNullOrEmpty(password))
            throw new WorkflowException(
                401,
                requirement.Explanation ?? "This decision must be signed with your password.");

        var user = await _users.GetByIdAsync(userId);
        if (user is null || !_hasher.Verify(password, user.PasswordHash))
            throw new WorkflowException(401, "That password is not correct.");

        return true;
    }
}
