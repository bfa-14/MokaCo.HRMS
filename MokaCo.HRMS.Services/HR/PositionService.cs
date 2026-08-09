using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;

namespace MokaCo.HRMS.Services.HR;

/// <summary>Position administration (thin wrapper over the repository).</summary>
public class PositionService : IPositionService
{
    private readonly IPositionRepository _repo;
    public PositionService(IPositionRepository repo) => _repo = repo;

    public Task<IEnumerable<Position>> GetAllAsync() => _repo.GetAllAsync();
    public Task<int> CreateAsync(string title) => _repo.CreateAsync(title);
    public Task UpdateAsync(int positionId, string title, bool isActive) => _repo.UpdateAsync(positionId, title, isActive);
}
