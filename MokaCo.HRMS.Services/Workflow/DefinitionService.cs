using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>
/// Chain configuration (thin wrapper over the repository).
///
/// The engine enforces the hard rules itself — a step cannot be added to a published version, a
/// version cannot publish without steps — and raises a clear error when broken, which the controller
/// surfaces. So there is no C# logic to add here; the service exists to keep the layering honest.
/// </summary>
public class DefinitionService : IDefinitionService
{
    private readonly IDefinitionRepository _repo;
    public DefinitionService(IDefinitionRepository repo) => _repo = repo;

    public Task<IEnumerable<RequestType>> GetRequestTypesAsync() => _repo.GetRequestTypesAsync();

    /// <summary>
    /// ONE ROW PER TYPE. usp_RequestType_GetRaisable joins the ACTIVE definitions, and since chains
    /// became tier-scoped a type can have several active at once (everyone / management+ / executive)
    /// — so the procedure emits the same type once per chain. Left alone that renders duplicate cards
    /// on the new-request screen. Which chain a given requester actually runs is a separate question,
    /// answered per-employee by GetActiveAsync; for "what may I raise", the type is the answer.
    /// </summary>
    public async Task<IEnumerable<RaisableRequestType>> GetRaisableRequestTypesAsync()
    {
        var rows = await _repo.GetRaisableRequestTypesAsync();
        return rows
            .GroupBy(t => t.Code)
            .Select(g => g.First())
            .OrderBy(t => t.SortOrder)
            .ThenBy(t => t.MenuLabel)
            .ToList();
    }

    public Task<IEnumerable<DefinitionCopySource>> GetCopySourcesAsync() => _repo.GetCopySourcesAsync();

    /// <summary>
    /// Mapped, because EVERY refusal here is one the builder must show and act on: the draft-only
    /// rule, the self-copy, and above all "this draft already has N step(s)" — which the UI turns
    /// into the Replace confirm. A 500 would hide the one sentence the user needs.
    /// </summary>
    public Task<DefinitionCopyResult?> CopyStepsFromAsync(int targetDefinitionId, DefinitionCopyFromRequest request)
        => WorkflowSqlErrors.MapAsync(() => _repo.CopyStepsFromAsync(
            targetDefinitionId, request.SourceDefinitionId, request.ReplaceExisting));

    public Task<int> UpsertRequestTypeAsync(RequestTypeUpsertRequest request)
        => _repo.UpsertRequestTypeAsync(request.Code, request.Name, request.Description, request.IsActive);

    public Task<IEnumerable<WorkflowDefinition>> GetDefinitionsAsync(int? requestTypeId)
        => _repo.GetDefinitionsAsync(requestTypeId);

    public Task<DefinitionCreated> CreateDraftAsync(DefinitionCreateRequest request, int? createdBy)
        => _repo.CreateDraftAsync(request.RequestTypeId, request.Notes, createdBy);

    public Task AddStepAsync(int workflowDefinitionId, DefinitionAddStepRequest step)
        => WorkflowSqlErrors.MapAsync<object?>(async () =>
        {
            await _repo.AddStepAsync(workflowDefinitionId, step);
            return null;
        });

    public Task<DefinitionPublished?> PublishAsync(int workflowDefinitionId, int? publishedBy)
        => WorkflowSqlErrors.MapAsync(() => _repo.PublishAsync(workflowDefinitionId, publishedBy));

    public Task<IEnumerable<WorkflowStep>> GetStepsAsync(int workflowDefinitionId)
        => _repo.GetStepsAsync(workflowDefinitionId);

    /// <summary>Draft-only; the procedure RAISERRORs on a published version, mapped to a clean 400 with its message.</summary>
    public Task DeleteDraftAsync(int workflowDefinitionId)
        => WorkflowSqlErrors.MapAsync<object?>(async () =>
        {
            await _repo.DeleteDraftAsync(workflowDefinitionId);
            return null;
        });

    public Task<IEnumerable<ActiveDefinitionStep>> GetActiveAsync(string requestTypeCode, int? forEmployeeId = null)
        => _repo.GetActiveAsync(requestTypeCode, forEmployeeId);

    /// <summary>Draft-only; the procedure RAISERRORs on a published version, which becomes a clean 400 with the message.</summary>
    public Task<DefinitionMinTier?> SetMinTierAsync(int workflowDefinitionId, int? minRequesterTier)
        => WorkflowSqlErrors.MapAsync(() => _repo.SetMinTierAsync(workflowDefinitionId, minRequesterTier));
}
