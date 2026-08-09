using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;

namespace MokaCo.HRMS.Services.HR;

/// <summary>Department administration (thin wrapper over the repository).</summary>
public class DepartmentService : IDepartmentService
{
    private readonly IDepartmentRepository _repo;
    public DepartmentService(IDepartmentRepository repo) => _repo = repo;

    public Task<IEnumerable<Department>> GetAllAsync() => _repo.GetAllAsync();
    public Task<int> CreateAsync(string name) => _repo.CreateAsync(name);
    public Task UpdateAsync(int departmentId, string name, bool isActive) => _repo.UpdateAsync(departmentId, name, isActive);
}
