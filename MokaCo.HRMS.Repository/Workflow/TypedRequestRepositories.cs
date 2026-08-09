using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

/// <summary>
/// Dapper access for shift swaps. The consent tick, the same-role rule, the future-dates rule, the
/// "both actually have a shift" checks and the open-swap collision all live in the procedure — and
/// so does the roster rewrite at final approval.
/// </summary>
public class ShiftSwapRepository : IShiftSwapRepository
{
    private readonly IDbConnectionFactory _factory;
    public ShiftSwapRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<ShiftSwapCreated?> CreateAsync(
        int employeeId, int raisedByUserId, int counterpartEmployeeId,
        DateTime requesterDate, DateTime counterpartDate, bool counterpartHasAgreed, string? title)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ShiftSwapCreated>(
            "workflow.usp_ShiftSwap_Create",
            new
            {
                EmployeeId = employeeId,
                RaisedByUserId = raisedByUserId,
                CounterpartEmployeeId = counterpartEmployeeId,
                RequesterDate = requesterDate.Date,
                CounterpartDate = counterpartDate.Date,
                // Passed through as sent. The procedure refuses a false with the sentence the user
                // needs to read; it is not silently corrected here.
                CounterpartHasAgreed = counterpartHasAgreed,
                Title = title,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<TypedDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, string? comment, bool signedWithPassword)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<TypedDecisionResult>(
            "workflow.usp_ShiftSwap_Decide",
            new
            {
                RequestInstanceId = requestInstanceId,
                ActedByUserId = actedByUserId,
                Comment = comment,
                SignedWithPassword = signedWithPassword,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<ShiftSwapPayload?> GetPayloadAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ShiftSwapPayload>(
            "workflow.usp_ShiftSwap_GetPayload",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure);
    }
}
