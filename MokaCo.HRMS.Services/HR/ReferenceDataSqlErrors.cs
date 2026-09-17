using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.HR;

/// <summary>
/// Turns the refusals the reference-data procedures raise (hr.usp_*_Delete / _SetActive, from
/// 70_ref_data_delete_rules.sql) into HTTP statuses, message intact.
///
///   "Cannot delete 'Waiter': it is used by 12 employees and 340 payslip lines. Deactivate it
///    instead."                                            → 409 Conflict (the row is in use)
///   "Position not found."                                 → 404
///   anything else the procedure raises                    → 400
///
/// The sentence IS the answer — it names what references the row — so nothing here rewrites it.
/// </summary>
public static class ReferenceDataSqlErrors
{
    public static async Task<T> MapAsync<T>(Func<Task<T>> call)
    {
        try
        {
            return await call();
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            throw Map(ex.Message);
        }
    }

    public static async Task MapAsync(Func<Task> call)
    {
        try
        {
            await call();
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            throw Map(ex.Message);
        }
    }

    /// <summary>The pure mapping, so the status rules can be tested without a database.</summary>
    public static WorkflowException Map(string message)
    {
        if (message.StartsWith("Cannot delete", StringComparison.OrdinalIgnoreCase))
            return new WorkflowException(409, message);
        if (message.EndsWith("not found.", StringComparison.OrdinalIgnoreCase))
            return new WorkflowException(404, message);
        return new WorkflowException(400, message);
    }
}
