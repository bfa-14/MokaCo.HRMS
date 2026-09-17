using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface IPositionRepository
{
    Task<IEnumerable<Position>> GetAllAsync();
    Task<int> CreateAsync(string title);
    Task UpdateAsync(int positionId, string title, bool isActive);

    /// <summary>
    /// hr.usp_Position_Delete: hard-deletes an UNUSED row; RAISERRORs "Cannot delete '…': it is used by
    /// … . Deactivate it instead." when anything references it (mapped to a 409 above).
    /// </summary>
    Task DeleteAsync(int positionId);

    /// <summary>hr.usp_Position_SetActive — the "deactivate it instead" path. RAISERRORs "… not found." (404).</summary>
    Task SetActiveAsync(int positionId, bool isActive);
}
