using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

public interface IOnboardingRepository
{
    /// <summary>
    /// Raises a hire. The candidate is not an employee, so there is no employee id to pass — the
    /// procedure resolves the engine's subject from the RAISER and refuses a login with none. It also
    /// copies the checklist from the active template as it stands today.
    /// </summary>
    Task<OnboardingCreated?> CreateAsync(
        int raisedByUserId, string candidateName, int branchId, int departmentId, int positionId,
        DateTime startDate, string? nationalId, string? nssfNumber, string? taxNumber,
        string? bankAccount, string? notes, string? title);

    /// <summary>
    /// Decides. The first approval CREATES THE EMPLOYEE RECORD; the last is refused while any required
    /// checklist item is undone, with a message naming every one of them.
    /// </summary>
    Task<OnboardingDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, string? comment, bool signedWithPassword);

    /// <summary>Ticks or unticks one item and returns the WHOLE list, already in order.</summary>
    Task<IEnumerable<OnboardingTask>> SetTaskAsync(
        int requestInstanceId, string code, bool isComplete, int actedByUserId, string? note);

    /// <summary>Header AND tasks — usp_Onboarding_GetPayload returns TWO result sets.</summary>
    Task<OnboardingPayload> GetPayloadAsync(int requestInstanceId);
}

/// <summary>
/// Dapper access for onboardings via workflow.usp_Onboarding_*.
///
/// Every rule belongs to the procedures and none is repeated here: the duplicate-name guard, the
/// branch/department/position lookups, the creation of the hr.EMPLOYEE row at the hire decision, the
/// refusal of the closing signature while required items are outstanding, and the refusal to touch a
/// checklist once the request is closed. Each names its own cause, and the closing one names every
/// outstanding item — a sentence nothing in C# could improve on.
/// </summary>
public class OnboardingRepository : IOnboardingRepository
{
    private readonly IDbConnectionFactory _factory;
    public OnboardingRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<OnboardingCreated?> CreateAsync(
        int raisedByUserId, string candidateName, int branchId, int departmentId, int positionId,
        DateTime startDate, string? nationalId, string? nssfNumber, string? taxNumber,
        string? bankAccount, string? notes, string? title)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<OnboardingCreated>(
            "workflow.usp_Onboarding_Create",
            new
            {
                RaisedByUserId = raisedByUserId,
                CandidateName = candidateName,
                BranchId = branchId,
                DepartmentId = departmentId,
                PositionId = positionId,
                StartDate = startDate.Date,
                NationalId = nationalId,
                NssfNumber = nssfNumber,
                TaxNumber = taxNumber,
                BankAccount = bankAccount,
                Notes = notes,
                Title = title,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<OnboardingDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, string? comment, bool signedWithPassword)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<OnboardingDecisionResult>(
            "workflow.usp_Onboarding_Decide",
            new
            {
                RequestInstanceId = requestInstanceId,
                ActedByUserId = actedByUserId,
                Comment = comment,
                SignedWithPassword = signedWithPassword,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<OnboardingTask>> SetTaskAsync(
        int requestInstanceId, string code, bool isComplete, int actedByUserId, string? note)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<OnboardingTask>(
            "workflow.usp_Onboarding_SetTask",
            new
            {
                RequestInstanceId = requestInstanceId,
                Code = code,
                IsComplete = isComplete,
                ActedByUserId = actedByUserId,
                Note = note,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<OnboardingPayload> GetPayloadAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        using var grid = await db.QueryMultipleAsync(
            "workflow.usp_Onboarding_GetPayload",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure);

        // TWO SETS, IN THE PROCEDURE'S ORDER: header then tasks. Each must be consumed before the
        // next, so these reads cannot be reordered or deferred.
        var header = await grid.ReadSingleOrDefaultAsync<OnboardingHeader>();
        var tasks = (await grid.ReadAsync<OnboardingTask>()).ToList();

        return new OnboardingPayload(header, tasks);
    }
}
