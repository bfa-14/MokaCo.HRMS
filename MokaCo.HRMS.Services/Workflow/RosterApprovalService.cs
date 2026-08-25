using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;

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
/// </summary>
public class RosterApprovalService : IRosterApprovalService
{
    private readonly IRosterApprovalRepository _repo;
    private readonly IWorkflowSupportService _support;

    public RosterApprovalService(IRosterApprovalRepository repo, IWorkflowSupportService support)
    {
        _repo = repo;
        _support = support;
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

        return await WorkflowSqlErrors.MapAsync(() => _repo.CreateAsync(
            me.EmployeeId,
            actedByUserId,
            request.BranchId,
            request.MonthDate,
            string.IsNullOrWhiteSpace(request.Title) ? null : request.Title.Trim()));
    }
}
