using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface IComponentTypeRepository
{
    Task<IEnumerable<ComponentType>> GetAllAsync();
    Task<int> CreateAsync(string name, string category, short sign, bool? isActive = null);
    /// <summary>isActive null keeps the stored flag.</summary>
    Task UpdateAsync(int componentTypeId, string name, string category, short sign, bool? isActive = null);

    /// <summary>
    /// hr.usp_ComponentType_Delete: hard-deletes an UNUSED row; RAISERRORs "Cannot delete '…': it is used by
    /// … . Deactivate it instead." when anything references it (mapped to a 409 above).
    /// </summary>
    Task DeleteAsync(int componentTypeId);

    /// <summary>hr.usp_ComponentType_SetActive — the "deactivate it instead" path. RAISERRORs "… not found." (404).</summary>
    Task SetActiveAsync(int componentTypeId, bool isActive);
}
