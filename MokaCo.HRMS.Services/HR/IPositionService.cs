using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface IPositionService
{
    Task<IEnumerable<Position>> GetAllAsync();
    Task<int> CreateAsync(string title);
    Task UpdateAsync(int positionId, string title, bool isActive);

    /// <summary>
    /// Deletes an unused row. A row anything references is refused with a
    /// <see cref="MokaCo.HRMS.Services.Workflow.WorkflowException"/> carrying 409 and the sentence
    /// to show ("Cannot delete 'X': it is used by … . Deactivate it instead."); unknown id → 404.
    /// </summary>
    Task DeleteAsync(int positionId);

    /// <summary>Activates / deactivates without deleting. Unknown id → WorkflowException 404.</summary>
    Task SetActiveAsync(int positionId, bool isActive);
}
