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
    public LeaveYearService(ILeaveYearRepository repo) => _repo = repo;

    public Task<IEnumerable<LeaveYearOpenSummary>> OpenAsync(int year, int actedByUserId)
        => _repo.OpenAsync(year, actedByUserId);
}
