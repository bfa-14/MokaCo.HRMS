using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

public interface ISalaryAdvanceRepository
{
    /// <summary>
    /// Raises the advance as a request. The procedure owns every rule: the positive amount, the
    /// monthly bound, the first period's shape, that the period is still OPEN, and the one that
    /// keeps recovery legible — ONE advance per employee in flight or unsettled at a time.
    /// </summary>
    Task<SalaryAdvanceCreated?> CreateAsync(
        int employeeId, int raisedByUserId, decimal amount, string currencyCode,
        decimal monthlyDeduction, string firstDeductionPeriod, string? reason, string? title);

    /// <summary>
    /// Approves, AND SIGNS BOTH FIGURES. <paramref name="approvedAmount"/> is required — how much is
    /// actually lent. <paramref name="approvedMonthlyDeduction"/> is genuinely optional: NULL means
    /// "keep the standing schedule", which the procedure carries over and CLAMPS to the approved
    /// amount, so tightening a 300 advance to 200 cannot leave a 300/month deduction behind it.
    ///
    /// Every rule stays in the procedure — no more than requested, never above what an earlier
    /// approver allowed, monthly inside the amount, and the first deduction period still open at the
    /// final signature. The FINAL approval writes the ledger row once, guarded on CreatedAdvanceId,
    /// and a period that locked while the request waited is refused BEFORE any signature is written.
    /// </summary>
    Task<SalaryAdvanceDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, decimal approvedAmount,
        decimal? approvedMonthlyDeduction, string? comment, bool signedWithPassword);

    Task<SalaryAdvancePayload?> GetPayloadAsync(int requestInstanceId);
}

/// <summary>
/// Dapper access for salary advance requests via workflow.usp_SalaryAdvance_*.
///
/// This is now the ONLY way an advance comes into existence: payroll.usp_Advance_Create refuses and
/// points here. Rescheduling what comes off each month stays a separate, unsigned HR act — that is
/// recovery admin, not new lending, and it never changes what is owed.
/// </summary>
public class SalaryAdvanceRepository : ISalaryAdvanceRepository
{
    private readonly IDbConnectionFactory _factory;
    public SalaryAdvanceRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<SalaryAdvanceCreated?> CreateAsync(
        int employeeId, int raisedByUserId, decimal amount, string currencyCode,
        decimal monthlyDeduction, string firstDeductionPeriod, string? reason, string? title)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<SalaryAdvanceCreated>(
            "workflow.usp_SalaryAdvance_Create",
            new
            {
                EmployeeId = employeeId,
                RaisedByUserId = raisedByUserId,
                Amount = amount,
                CurrencyCode = currencyCode,
                MonthlyDeduction = monthlyDeduction,
                FirstDeductionPeriod = firstDeductionPeriod,
                Reason = reason,
                // Null lets the procedure compose the title; the form previews the same CONCAT.
                Title = title,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<SalaryAdvanceDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, decimal approvedAmount,
        decimal? approvedMonthlyDeduction, string? comment, bool signedWithPassword)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<SalaryAdvanceDecisionResult>(
            "workflow.usp_SalaryAdvance_Decide",
            new
            {
                RequestInstanceId = requestInstanceId,
                ActedByUserId = actedByUserId,
                ApprovedAmount = approvedAmount,
                // Passed through as null on purpose when the caller did not state one. The
                // procedure's default is not "zero" — it is the standing schedule clamped to the
                // approved amount, which is a decision we would get wrong if we made it here.
                ApprovedMonthlyDeduction = approvedMonthlyDeduction,
                Comment = comment,
                SignedWithPassword = signedWithPassword,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<SalaryAdvancePayload?> GetPayloadAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<SalaryAdvancePayload>(
            "workflow.usp_SalaryAdvance_GetPayload",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure);
    }
}
