using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

public interface ISeparationRepository
{
    /// <summary>
    /// Everything the form needs before anyone commits to a figure — service, notice, a provisional
    /// indemnity where a basic is on file, and the leave still on the ledger. Reads nothing and
    /// changes nothing; the dates are hypotheses the caller is trying out.
    /// </summary>
    Task<SeparationContext> GetContextAsync(int employeeId, DateTime? lastWorkingDate, DateTime? noticeGivenDate);

    Task<SeparationCreated?> CreateAsync(
        int employeeId, int raisedByUserId, string separationType,
        DateTime noticeGivenDate, DateTime lastWorkingDate, string? reason, string? title);

    /// <summary>Saves the preparer's figures. Refused once the request is closed, and on any negative amount.</summary>
    Task<SeparationSettlement?> SetSettlementAsync(
        int requestInstanceId, int actedByUserId, SeparationSettlementRequest settlement);

    /// <summary>
    /// Decides. The FINAL sign-off is refused while the settlement is unprepared; once it passes, the
    /// termination date is written and the leave balance is paid out and zeroed — both idempotent.
    /// </summary>
    Task<SeparationDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, string? comment, bool signedWithPassword);

    Task<SeparationPayload?> GetPayloadAsync(int requestInstanceId);
}

/// <summary>
/// Dapper access for separations via hr.usp_Separation_GetContext and workflow.usp_Separation_*.
///
/// Nothing here re-derives a figure. The service arithmetic, the notice tier, the provisional
/// indemnity, the settlement total, the refusal of an unprepared sign-off, and the two irreversible
/// effects at final approval all belong to the procedures — and the effects in particular must stay
/// there, because they are guarded on their own AppliedAt/LeaveClearedAt stamps and a caller that
/// tried to help would be the thing that ran them twice.
/// </summary>
public class SeparationRepository : ISeparationRepository
{
    private readonly IDbConnectionFactory _factory;
    public SeparationRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<SeparationContext> GetContextAsync(int employeeId, DateTime? lastWorkingDate, DateTime? noticeGivenDate)
    {
        using var db = _factory.Create();
        using var grid = await db.QueryMultipleAsync(
            "hr.usp_Separation_GetContext",
            new
            {
                EmployeeId = employeeId,
                LastWorkingDate = lastWorkingDate?.Date,
                NoticeGivenDate = noticeGivenDate?.Date,
            },
            commandType: CommandType.StoredProcedure);

        // TWO SETS, IN THE PROCEDURE'S ORDER: header then the leave balances. Each must be consumed
        // before the next, so these reads cannot be reordered or deferred.
        var header = await grid.ReadSingleOrDefaultAsync<SeparationContextHeader>();
        var balances = (await grid.ReadAsync<SeparationLeaveBalance>()).ToList();

        return new SeparationContext(header, balances);
    }

    public async Task<SeparationCreated?> CreateAsync(
        int employeeId, int raisedByUserId, string separationType,
        DateTime noticeGivenDate, DateTime lastWorkingDate, string? reason, string? title)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<SeparationCreated>(
            "workflow.usp_Separation_Create",
            new
            {
                EmployeeId = employeeId,
                RaisedByUserId = raisedByUserId,
                SeparationType = separationType,
                NoticeGivenDate = noticeGivenDate.Date,
                LastWorkingDate = lastWorkingDate.Date,
                Reason = reason,
                Title = title,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<SeparationSettlement?> SetSettlementAsync(
        int requestInstanceId, int actedByUserId, SeparationSettlementRequest settlement)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<SeparationSettlement>(
            "workflow.usp_Separation_SetSettlement",
            new
            {
                RequestInstanceId = requestInstanceId,
                ActedByUserId = actedByUserId,
                settlement.CurrencyCode,
                settlement.UnusedLeaveDays,
                settlement.UnusedLeaveAmount,
                settlement.IndemnityAmount,
                settlement.NoticePayAmount,
                settlement.OtherDues,
                settlement.Deductions,
                settlement.SettlementNote,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<SeparationDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, string? comment, bool signedWithPassword)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<SeparationDecisionResult>(
            "workflow.usp_Separation_Decide",
            new
            {
                RequestInstanceId = requestInstanceId,
                ActedByUserId = actedByUserId,
                Comment = comment,
                SignedWithPassword = signedWithPassword,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<SeparationPayload?> GetPayloadAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<SeparationPayload>(
            "workflow.usp_Separation_GetPayload",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure);
    }
}
