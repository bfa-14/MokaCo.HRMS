using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;

namespace MokaCo.HRMS.Services.HR;

/// <summary>Component-type administration (thin wrapper over the repository).</summary>
public class ComponentTypeService : IComponentTypeService
{
    private readonly IComponentTypeRepository _repo;
    public ComponentTypeService(IComponentTypeRepository repo) => _repo = repo;

    public Task<IEnumerable<ComponentType>> GetAllAsync() => _repo.GetAllAsync();
    public Task<int> CreateAsync(string name, string category, short sign) => _repo.CreateAsync(name, category, sign);
    public Task UpdateAsync(int componentTypeId, string name, string category, short sign)
        => _repo.UpdateAsync(componentTypeId, name, category, sign);
}
