using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

public interface IRosterApprovalService
{
    /// <summary>
    /// Raises a roster approval for one branch-month.
    ///
    /// The caller's own employee record becomes the request's subject — a roster month is about a
    /// branch, but the header still needs somebody to be filed against, and the only defensible
    /// answer is whoever put it up. An account with no employee record therefore cannot raise one,
    /// and gets a 403 saying so rather than a foreign-key failure.
    ///
    /// The procedure's refusals ("No roster rows exist for that branch and month", already
    /// approved, already pending) come back as 400s with their sentences intact.
    /// </summary>
    Task<RosterApprovalCreated?> CreateAsync(RosterApprovalCreateRequest request, int actedByUserId);
}
