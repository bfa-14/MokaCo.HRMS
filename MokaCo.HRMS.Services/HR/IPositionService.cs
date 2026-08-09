using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface IPositionService
{
    Task<IEnumerable<Position>> GetAllAsync();
    Task<int> CreateAsync(string title);
    Task UpdateAsync(int positionId, string title, bool isActive);
}
