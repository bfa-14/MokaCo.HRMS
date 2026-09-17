using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface IDepartmentService
{
    Task<IEnumerable<Department>> GetAllAsync();
    Task<int> CreateAsync(string name);
    Task UpdateAsync(int departmentId, string name, bool isActive);

    /// <summary>
    /// Deletes an unused row. A row anything references is refused with a
    /// <see cref="MokaCo.HRMS.Services.Workflow.WorkflowException"/> carrying 409 and the sentence
    /// to show ("Cannot delete 'X': it is used by … . Deactivate it instead."); unknown id → 404.
    /// </summary>
    Task DeleteAsync(int departmentId);

    /// <summary>Activates / deactivates without deleting. Unknown id → WorkflowException 404.</summary>
    Task SetActiveAsync(int departmentId, bool isActive);
}
