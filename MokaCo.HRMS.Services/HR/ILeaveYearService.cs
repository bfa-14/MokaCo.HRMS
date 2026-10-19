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

    /// <summary>
    /// QA3 (LEV-9): takes back the opening of the CURRENT year for one employee, or everybody, so it can be opened again.
    /// Refusals arrive as SqlException 50000 with the sentence to show.
    /// </summary>
    Task<LeaveYearUndoSummary> UndoAsync(int year, int? employeeId, int actedByUserId);

    /// <summary>
    /// Nightly (D4): carried-over days still unused after the configured date expire; QA3 (LEV-6) a later posting is
    /// corrected by a delta until the expiry month is paid. Logs a warning when the setting is not an MM-DD date.
    /// </summary>
    Task<LeaveCarryOverExpired> ExpireCarryOverAsync();

    /// <summary>Nightly (D7): branch transfers whose effective date has arrived become the employee's current branch.</summary>
    Task<int> ApplyDueBranchTransfersAsync();
}
