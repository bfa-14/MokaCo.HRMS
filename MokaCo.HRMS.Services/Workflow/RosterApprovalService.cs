using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;
using MokaCo.HRMS.Services.Attendance;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>
/// Roster approvals — a branch's whole month of roster, signed off as one request.
///
/// THIS LAYER ENFORCES EXACTLY ONE THING the database cannot: that the caller has an employee
/// record to file the request against. Everything else — roster rows existing for the branch-month,
/// the month not already being approved or already pending — belongs to the procedure, and its
/// refusals are mapped to statuses here with the message left exactly as written.
///
/// There is no Decide. Approving a roster month runs through workflow.usp_Request_Approve, whose
/// ApplyApprovalEffects activates the month; a typed decide would be a second path to the same
/// effect, and the typed-409 guard that comes with one would only block the path that works.
///
/// QA3: the procedure also refuses a submitter who neither manages the branch nor holds EMP_VIEW_ALL, and routes the
/// branch-manager step to the ROSTER's branch (WF-7). When every step skipped itself and the request is approved at
/// once, the month is derived again from the approved roster right here (ROS-2) — the same thing the generic approve
/// does after the last signature.
/// </summary>
public class RosterApprovalService : IRosterApprovalService
{
    private readonly IRosterApprovalRepository _repo;
    private readonly IWorkflowSupportService _support;
    private readonly IRosterService _roster;

    public RosterApprovalService(IRosterApprovalRepository repo, IWorkflowSupportService support, IRosterService roster)
    {
        _repo = repo;
        _support = support;
        _roster = roster;
    }

    public async Task<RosterApprovalCreated?> CreateAsync(RosterApprovalCreateRequest request, int actedByUserId)
    {
        /* WHOSE REQUEST IT IS, resolved from the token rather than accepted from the body. A roster
           month has no natural subject employee, so the raiser is it — which also means an account
           with no employee record has nobody to file as. Refused in words here, because the
           alternative is the procedure failing on a foreign key and reporting a 500 for what is
           really a setup problem somebody can fix. */
        var me = await _support.GetEmployeeByUserIdAsync(actedByUserId);
        if (me is null)
            throw new WorkflowException(
                403,
                "Your account is not linked to an employee, so you cannot raise a roster approval.");

        var created = await WorkflowSqlErrors.MapAsync(() => _repo.CreateAsync(
            me.EmployeeId,
            actedByUserId,
            request.BranchId,
            request.MonthDate,
            string.IsNullOrWhiteSpace(request.Title) ? null : request.Title.Trim()));

        // QA3 (ROS-2): approved at submission (every step skipped) — the month is active now, so its days are derived
        // again from it. Never throws: a failure is logged and left to the nightly safety net.
        if (created is not null && string.Equals(created.Status, "Approved", StringComparison.OrdinalIgnoreCase))
            await _roster.RederiveApprovedRequestAsync(created.RequestInstanceId);

        return created;
    }
}
