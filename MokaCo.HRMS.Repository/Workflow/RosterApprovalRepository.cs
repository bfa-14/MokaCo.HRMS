using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

/// <summary>
/// Dapper access for roster approvals via workflow.usp_RosterApproval_Create.
///
/// Every rule lives in the procedure — that roster rows exist for the branch-month, that the month
/// is not already approved, that no request is already open on it. Nothing here re-implements or
/// pre-empts any of them: a check duplicated in C# is a check that can disagree with the one the
/// database actually enforces, and the procedure's refusals travel up as SqlException to be mapped
/// one layer above.
/// </summary>
public class RosterApprovalRepository : IRosterApprovalRepository
{
    private readonly IDbConnectionFactory _factory;
    public RosterApprovalRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<RosterApprovalCreated?> CreateAsync(
        int employeeId, int raisedByUserId, int branchId, DateTime monthDate, string? title)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<RosterApprovalCreated>(
            "workflow.usp_RosterApproval_Create",
            new
            {
                // Both from the CALLER, never the body — see RosterApprovalCreateRequest.
                EmployeeId = employeeId,
                RaisedByUserId = raisedByUserId,
                BranchId = branchId,
                /* NORMALISED TO THE FIRST OF THE MONTH. The month is the identity of this request:
                   two callers sending 2026-03-01 and 2026-03-17 mean the same March, and without
                   this they would create two requests the "already pending" guard could not see as
                   duplicates, because it matches on the stored date. */
                MonthDate = new DateTime(monthDate.Year, monthDate.Month, 1),
                // Null/blank → the procedure composes the standard title. Never composed here.
                Title = title,
            },
            commandType: CommandType.StoredProcedure);
    }
}
