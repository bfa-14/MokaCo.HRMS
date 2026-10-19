using Microsoft.Extensions.Logging;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;

namespace MokaCo.HRMS.Services.HR;

/// <summary>
/// The yearly leave opening.
///
/// A THIN LAYER ON PURPOSE. There is no policy to enforce here that the procedure does not already
/// own — eligibility, the entitlement figure, pro-rating a part year, carry-over versus expiry, and
/// the already-opened skip are all its decisions. Re-deciding any of them in C# would create a
/// second opinion that can drift from the one the database acts on, so this forwards and no more.
/// </summary>
public class LeaveYearService : ILeaveYearService
{
    private readonly ILeaveYearRepository _repo;
    private readonly ILogger<LeaveYearService> _logger;

    public LeaveYearService(ILeaveYearRepository repo, ILogger<LeaveYearService> logger)
    {
        _repo = repo;
        _logger = logger;
    }

    public Task<IEnumerable<LeaveYearOpenSummary>> OpenAsync(int year, int actedByUserId)
        => _repo.OpenAsync(year, actedByUserId);

    public Task<LeaveYearUndoSummary> UndoAsync(int year, int? employeeId, int actedByUserId)
        => _repo.UndoAsync(year, employeeId, actedByUserId);

    /// <summary>
    /// The nightly expiry. QA3 (LEV-6): a LeaveCarryOverExpiresOn that is not an MM-DD date expires nothing -- it used to
    /// do so in silence, which looked exactly like "nobody had days left". The procedure now says why, and this is where
    /// the job's log hears about it.
    /// </summary>
    public async Task<LeaveCarryOverExpired> ExpireCarryOverAsync()
    {
        var result = await _repo.ExpireCarryOverAsync();
        if (!string.IsNullOrWhiteSpace(result.SettingProblem))
            _logger.LogWarning("Carry-over expiry skipped: {Problem} Fix the setting on Settings > Leave.", result.SettingProblem);
        return result;
    }

    public Task<int> ApplyDueBranchTransfersAsync() => _repo.ApplyDueBranchTransfersAsync();
}
