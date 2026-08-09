using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface IComponentTypeRepository
{
    Task<IEnumerable<ComponentType>> GetAllAsync();
    Task<int> CreateAsync(string name, string category, short sign);
    Task UpdateAsync(int componentTypeId, string name, string category, short sign);
}
