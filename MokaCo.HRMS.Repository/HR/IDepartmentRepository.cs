using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface IDepartmentRepository
{
    Task<IEnumerable<Department>> GetAllAsync();
    Task<int> CreateAsync(string name);
    Task UpdateAsync(int departmentId, string name, bool isActive);

    /// <summary>
    /// hr.usp_Department_Delete: hard-deletes an UNUSED row; RAISERRORs "Cannot delete '…': it is used by
    /// … . Deactivate it instead." when anything references it (mapped to a 409 above).
    /// </summary>
    Task DeleteAsync(int departmentId);

    /// <summary>hr.usp_Department_SetActive — the "deactivate it instead" path. RAISERRORs "… not found." (404).</summary>
    Task SetActiveAsync(int departmentId, bool isActive);
}
