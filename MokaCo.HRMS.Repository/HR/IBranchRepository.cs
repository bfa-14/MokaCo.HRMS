using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface IBranchRepository
{
    Task<IEnumerable<Branch>> GetAllAsync();
    Task<int> CreateAsync(string name);
    Task UpdateAsync(int branchId, string name, bool isActive);

    /// <summary>
    /// hr.usp_Branch_Delete: hard-deletes an UNUSED row; RAISERRORs "Cannot delete '…': it is used by
    /// … . Deactivate it instead." when anything references it (mapped to a 409 above).
    /// </summary>
    Task DeleteAsync(int branchId);

    /// <summary>hr.usp_Branch_SetActive — the "deactivate it instead" path. RAISERRORs "… not found." (404).</summary>
    Task SetActiveAsync(int branchId, bool isActive);
}
