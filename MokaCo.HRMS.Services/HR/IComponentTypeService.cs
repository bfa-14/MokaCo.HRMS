using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface IComponentTypeService
{
    Task<IEnumerable<ComponentType>> GetAllAsync();
    Task<int> CreateAsync(string name, string category, short sign);
    Task UpdateAsync(int componentTypeId, string name, string category, short sign);
}
