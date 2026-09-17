using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface IComponentTypeService
{
    Task<IEnumerable<ComponentType>> GetAllAsync();
    Task<int> CreateAsync(string name, string category, short sign, bool? isActive = null);
    Task UpdateAsync(int componentTypeId, string name, string category, short sign, bool? isActive = null);

    /// <summary>
    /// Deletes an unused row. A row anything references is refused with a
    /// <see cref="MokaCo.HRMS.Services.Workflow.WorkflowException"/> carrying 409 and the sentence
    /// to show ("Cannot delete 'X': it is used by … . Deactivate it instead."); unknown id → 404.
    /// </summary>
    Task DeleteAsync(int componentTypeId);

    /// <summary>Activates / deactivates without deleting. Unknown id → WorkflowException 404.</summary>
    Task SetActiveAsync(int componentTypeId, bool isActive);
}
