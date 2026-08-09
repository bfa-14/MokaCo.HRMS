using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>The caller's identity and right to raise for others, as resolved from the token.</summary>
public record ExpenseCaller(int UserId, int? EmployeeId, bool HasRaiseOthers);

public interface IExpenseService
{
    Task<ExpenseCreated?> CreateAsync(ExpenseCreateRequest request, ExpenseCaller caller);
    Task<ExpenseDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, ExpenseDecideRequest request);
    Task<ExpensePayload?> GetPayloadAsync(int requestInstanceId);
    Task<IEnumerable<MyExpense>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate);
}

/// <summary>
/// Expense reimbursements. As with every typed request, the one rule this layer enforces that the
/// database cannot is WHO a request may be raised FOR — the employee id is in the body, and the body
/// is the caller's to write.
///
/// The two refusals that matter most both belong to the procedures and travel verbatim: the missing
/// exchange rate (create) and the missing receipt (decide). Each names its own cause precisely, and
/// nothing here could word them better.
/// </summary>
public class ExpenseService : IExpenseService
{
    private readonly IExpenseRepository _repo;
    private readonly IDecisionSignatureService _signature;

    public ExpenseService(IExpenseRepository repo, IDecisionSignatureService signature)
    {
        _repo = repo;
        _signature = signature;
    }

    public Task<ExpenseCreated?> CreateAsync(ExpenseCreateRequest request, ExpenseCaller caller)
    {
        if (!caller.HasRaiseOthers)
        {
            if (caller.EmployeeId is not int self)
                throw new WorkflowException(
                    403,
                    "Your account is not linked to an employee, so you cannot raise a request for yourself.");

            if (request.EmployeeId != self)
                throw new WorkflowException(
                    403,
                    "You may only raise a request for yourself. Raising on another employee's behalf needs additional permission.");
        }

        return WorkflowSqlErrors.MapAsync(() => _repo.CreateAsync(
            request.EmployeeId, caller.UserId, request.ExpenseDate,
            request.Category?.Trim() ?? string.Empty, request.Amount,
            request.CurrencyCode?.Trim() ?? string.Empty,
            string.IsNullOrWhiteSpace(request.Description) ? null : request.Description.Trim(),
            string.IsNullOrWhiteSpace(request.Title) ? null : request.Title.Trim()));
    }

    public async Task<ExpenseDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, ExpenseDecideRequest request)
    {
        var signed = await _signature.VerifyAsync(requestInstanceId, actedByUserId, request.Password);
        return await WorkflowSqlErrors.MapAsync(() => _repo.DecideAsync(
            requestInstanceId, actedByUserId, request.ApprovedAmount,
            string.IsNullOrWhiteSpace(request.Comment) ? null : request.Comment.Trim(),
            signed));
    }

    public Task<ExpensePayload?> GetPayloadAsync(int requestInstanceId)
        => _repo.GetPayloadAsync(requestInstanceId);

    public Task<IEnumerable<MyExpense>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate)
        => _repo.GetForEmployeeAsync(employeeId, fromDate, toDate);
}
