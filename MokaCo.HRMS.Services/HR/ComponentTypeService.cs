using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;

namespace MokaCo.HRMS.Services.HR;

/// <summary>Component-type administration (thin wrapper over the repository).</summary>
public class ComponentTypeService : IComponentTypeService
{
    private readonly IComponentTypeRepository _repo;
    public ComponentTypeService(IComponentTypeRepository repo) => _repo = repo;

    public Task<IEnumerable<ComponentType>> GetAllAsync() => _repo.GetAllAsync();
    public Task<int> CreateAsync(string name, string category, short sign, bool? isActive = null)
        => _repo.CreateAsync(name, category, sign, isActive);
    /// <summary>Mapped: a system type refuses a rename, a new category or sign, or deactivation (QA3 PAY-10).</summary>
    public Task UpdateAsync(int componentTypeId, string name, string category, short sign, bool? isActive = null)
        => ReferenceDataSqlErrors.MapAsync(() => _repo.UpdateAsync(componentTypeId, name, category, sign, isActive));

    public Task DeleteAsync(int componentTypeId)
        => ReferenceDataSqlErrors.MapAsync(() => _repo.DeleteAsync(componentTypeId));

    public Task SetActiveAsync(int componentTypeId, bool isActive)
        => ReferenceDataSqlErrors.MapAsync(() => _repo.SetActiveAsync(componentTypeId, isActive));
}
