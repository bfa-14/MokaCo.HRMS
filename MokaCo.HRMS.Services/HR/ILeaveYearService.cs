using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface ILeaveYearService
{
    /// <summary>
    /// Opens the leave year — the ONLY path by which entitlement reaches the ledger. Safe to run
    /// twice: employees already opened for the year are skipped by the procedure.
    ///
    /// Refusals arrive as SqlException 50000 and are left for the API to turn into a 400 with the
    /// message intact, on the same terms as every other procedure refusal in HR.
    /// </summary>
    Task<IEnumerable<LeaveYearOpenSummary>> OpenAsync(int year, int actedByUserId);

    /// <summary>Nightly (D4): carried-over days still unused after the configured date expire — one ledger line each, once.</summary>
    Task<LeaveCarryOverExpired> ExpireCarryOverAsync();

    /// <summary>Nightly (D7): branch transfers whose effective date has arrived become the employee's current branch.</summary>
    Task<int> ApplyDueBranchTransfersAsync();
}
