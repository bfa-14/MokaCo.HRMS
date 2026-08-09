using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

public interface IPayrollAdjustmentRepository
{
    /// <summary>
    /// Raises the correction as a request. The target period is checked HERE and again at the final
    /// approval, because a period can lock while the request is in flight; the create refusal names
    /// the period and says to target the next open one.
    /// </summary>
    Task<PayrollAdjustmentCreated?> CreateAsync(
        int employeeId, int raisedByUserId, int componentTypeId, decimal amount,
        string currencyCode, string targetPeriod, int? correctsRunId, string? reason, string? title);

    /// <summary>
    /// Approves or rejects. NO FIGURE IS PASSED — the type has no CanAdjust step, so a signature can
    /// only agree with the claim or refuse it.
    ///
    /// The FINAL approval is what writes the payroll ledger row, once: the procedure guards on
    /// CreatedAdjustmentId, so a repeated approval cannot double-insert. If the target period locked
    /// while the request waited, the procedure refuses BEFORE any signature is written, so the
    /// request stays exactly where it was and can be rejected and re-raised.
    /// </summary>
    Task<PayrollAdjustmentDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, string? comment, bool signedWithPassword);

    Task<PayrollAdjustmentPayload?> GetPayloadAsync(int requestInstanceId);
}

/// <summary>
/// Dapper access for payroll adjustment requests via workflow.usp_PayrollAdjustment_*.
///
/// Every rule belongs to the procedures: the reason requirement, the positive-amount rule, the
/// locked-period check at BOTH ends, the "corrected run must be locked" rule, and the single-write
/// guard on the ledger row. Nothing is re-derived here — this is the one path by which an adjustment
/// can now come into existence, and a second opinion about it would be a second opinion about money.
/// </summary>
public class PayrollAdjustmentRepository : IPayrollAdjustmentRepository
{
    private readonly IDbConnectionFactory _factory;
    public PayrollAdjustmentRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<PayrollAdjustmentCreated?> CreateAsync(
        int employeeId, int raisedByUserId, int componentTypeId, decimal amount,
        string currencyCode, string targetPeriod, int? correctsRunId, string? reason, string? title)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PayrollAdjustmentCreated>(
            "workflow.usp_PayrollAdjustment_Create",
            new
            {
                EmployeeId = employeeId,
                RaisedByUserId = raisedByUserId,
                ComponentTypeId = componentTypeId,
                Amount = amount,
                CurrencyCode = currencyCode,
                TargetPeriod = targetPeriod,
                CorrectsRunId = correctsRunId,
                // Passed through blank so the procedure's own "A reason is required — an unexplained
                // adjustment is indistinguishable from an error." is what the user reads.
                Reason = reason,
                // Null lets the procedure compose the title; the form previews the same CONCAT.
                Title = title,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<PayrollAdjustmentDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, string? comment, bool signedWithPassword)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PayrollAdjustmentDecisionResult>(
            "workflow.usp_PayrollAdjustment_Decide",
            new
            {
                RequestInstanceId = requestInstanceId,
                ActedByUserId = actedByUserId,
                Comment = comment,
                SignedWithPassword = signedWithPassword,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<PayrollAdjustmentPayload?> GetPayloadAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PayrollAdjustmentPayload>(
            "workflow.usp_PayrollAdjustment_GetPayload",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure);
    }
}
