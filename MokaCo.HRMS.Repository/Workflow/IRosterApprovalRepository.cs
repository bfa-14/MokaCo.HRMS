using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Repository.Workflow;

public interface IRosterApprovalRepository
{
    /// <summary>
    /// Raises a roster approval for one branch-month: submits it into the engine and stores the
    /// payload in one transaction.
    ///
    /// REFUSES, by RAISERROR, when there is nothing to approve ("No roster rows exist for that
    /// branch and month") or when the month is already spoken for (already approved, or already
    /// pending on somebody's desk). Those sentences ARE the answer — they say which of the three it
    /// is — so they surface as SqlException 50000 and are mapped to a 400 with the text intact.
    ///
    /// There is NO matching decide: approving goes through the generic path, where the engine's
    /// ApplyApprovalEffects activates the month.
    /// </summary>
    Task<RosterApprovalCreated?> CreateAsync(
        int employeeId, int raisedByUserId, int branchId, DateTime monthDate, string? title);
}
