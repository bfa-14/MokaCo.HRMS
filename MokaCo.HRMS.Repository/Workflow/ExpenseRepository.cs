using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

public interface IExpenseRepository
{
    /// <summary>
    /// Raises an expense. Converts to USD with the latest exchange rate and FREEZES it on the row, so
    /// the routing decided later cannot move when rates do. The chain is raised in full — nothing is
    /// skipped here, because only a decision knows the granted amount that settles the routing. With
    /// NO rate on file for the currency the procedure REFUSES — that message names its cause and must
    /// reach the user unchanged.
    /// </summary>
    Task<ExpenseCreated?> CreateAsync(
        int employeeId, int raisedByUserId, DateTime expenseDate, string category,
        decimal amount, string currencyCode, string? description, string? title);

    /// <summary>
    /// Approves, optionally granting less. REFUSES without a receipt attached — the procedure counts
    /// attachments itself, so the rule cannot be bypassed by a caller that forgot to check.
    ///
    /// THE GRANTED FIGURE ROUTES THE REQUEST: at or under the threshold the procedure skips the
    /// remaining steps and closes it Approved; above it, the Owner step stands. The result says which
    /// happened, so nothing has to infer it.
    /// </summary>
    Task<ExpenseDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, decimal? approvedAmount,
        string? comment, bool signedWithPassword);

    Task<ExpensePayload?> GetPayloadAsync(int requestInstanceId);
    Task<IEnumerable<MyExpense>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate);
}

/// <summary>
/// Dapper access for expense reimbursements via workflow.usp_Expense_*.
///
/// Every rule is the procedures': the currency conversion and its missing-rate refusal, the USD
/// threshold that decides whether the Owner signs, the receipt requirement at approval, and the
/// bound on what may be granted. None of it is repeated or pre-empted here.
/// </summary>
public class ExpenseRepository : IExpenseRepository
{
    private readonly IDbConnectionFactory _factory;
    public ExpenseRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<ExpenseCreated?> CreateAsync(
        int employeeId, int raisedByUserId, DateTime expenseDate, string category,
        decimal amount, string currencyCode, string? description, string? title)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ExpenseCreated>(
            "workflow.usp_Expense_Create",
            new
            {
                EmployeeId = employeeId,
                RaisedByUserId = raisedByUserId,
                ExpenseDate = expenseDate.Date,
                Category = category,
                Amount = amount,
                CurrencyCode = currencyCode,
                Description = description,
                Title = title,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<ExpenseDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, decimal? approvedAmount,
        string? comment, bool signedWithPassword)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ExpenseDecisionResult>(
            "workflow.usp_Expense_Decide",
            new
            {
                RequestInstanceId = requestInstanceId,
                ActedByUserId = actedByUserId,
                // Null is the procedure's "as requested" default — passed through, never resolved here.
                ApprovedAmount = approvedAmount,
                Comment = comment,
                SignedWithPassword = signedWithPassword,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<ExpensePayload?> GetPayloadAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ExpensePayload>(
            "workflow.usp_Expense_GetPayload",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<MyExpense>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<MyExpense>(
            "workflow.usp_Expense_GetForEmployee",
            new { EmployeeId = employeeId, FromDate = fromDate, ToDate = toDate },
            commandType: CommandType.StoredProcedure);
    }
}
