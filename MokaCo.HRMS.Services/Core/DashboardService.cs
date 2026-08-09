using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Core;

namespace MokaCo.HRMS.Services.Core;

/// <summary>
/// The dashboard (thin wrapper over the repository).
///
/// There is deliberately no logic here. Every judgement the page rests on — whether the caller is
/// managerial, which requests they may act on, what is due today — is made by the procedure against
/// the caller's own id. Re-deciding any of it in C# would create a second opinion that can drift from
/// the first, and the one that would drift is the one deciding what a person is allowed to see.
/// </summary>
public class DashboardService : IDashboardService
{
    private readonly IDashboardRepository _repo;
    public DashboardService(IDashboardRepository repo) => _repo = repo;

    public Task<Dashboard> GetAsync(int userId) => _repo.GetAsync(userId);
}
