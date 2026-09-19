using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface ILeaveYearRepository
{
    /// <summary>
    /// Opens the leave year: grants each eligible employee their entitlement for
    /// <paramref name="year"/> — pro-rated for anyone hired within it — and either carries last
    /// year's unused days forward or expires them, by the leave type's own carry-over rule.
    ///
    /// IDEMPOTENT BY EMPLOYEE. The procedure skips anyone already opened for that year, so a second
    /// run is safe and simply reports zero employees; that is what makes it usable as a recovery
    /// path after an interrupted run.
    ///
    /// Refusals (a year out of range, a year opened out of order) arrive as RAISERROR — SqlException
    /// 50000 — and are left intact for the API to turn into a 400 with the sentence unchanged.
    /// </summary>
    Task<IEnumerable<LeaveYearOpenSummary>> OpenAsync(int year, int actedByUserId);

    /// <summary>
    /// hr.usp_LeaveCarryOver_Expire (SQL 84, D4): posts ONE 'Expiry' ledger line per employee, type and year for the
    /// carried-over days still unused once LeaveCarryOverExpiresOn has passed. Does nothing while the setting is
    /// empty or the day has not come; safe to call every night.
    /// </summary>
    Task<LeaveCarryOverExpired> ExpireCarryOverAsync();

    /// <summary>hr.usp_EmployeeBranch_ApplyDue (SQL 82, D7): a transfer recorded ahead of its date becomes the current branch on that date.</summary>
    Task<int> ApplyDueBranchTransfersAsync();
}
