using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

public interface IDefinitionService
{
    Task<IEnumerable<RequestType>> GetRequestTypesAsync();

    /// <summary>
    /// What the signed-in user may actually raise: active types with a published chain, ONE ROW PER
    /// TYPE. The procedure returns one row per active chain and a type may have several (tier-scoped
    /// populations), so the duplicates are collapsed here rather than left for every caller to trip on.
    /// </summary>
    Task<IEnumerable<RaisableRequestType>> GetRaisableRequestTypesAsync();

    Task<int> UpsertRequestTypeAsync(RequestTypeUpsertRequest request);

    Task<IEnumerable<WorkflowDefinition>> GetDefinitionsAsync(int? requestTypeId);
    Task<DefinitionCreated> CreateDraftAsync(DefinitionCreateRequest request, int? createdBy);
    Task AddStepAsync(int workflowDefinitionId, DefinitionAddStepRequest step);
    Task<DefinitionPublished?> PublishAsync(int workflowDefinitionId, int? publishedBy);
    Task<IEnumerable<WorkflowStep>> GetStepsAsync(int workflowDefinitionId);

    /// <summary>Deletes a DRAFT definition and its steps. A published version is refused with the procedure's message.</summary>
    Task DeleteDraftAsync(int workflowDefinitionId);
    Task<IEnumerable<ActiveDefinitionStep>> GetActiveAsync(string requestTypeCode, int? forEmployeeId = null);

    /// <summary>Chains a draft can be started from — any version, of any type, that has steps.</summary>
    Task<IEnumerable<DefinitionCopySource>> GetCopySourcesAsync();

    /// <summary>Copies one chain's steps into a DRAFT. Refusals carry the procedure's own wording.</summary>
    Task<DefinitionCopyResult?> CopyStepsFromAsync(int targetDefinitionId, DefinitionCopyFromRequest request);

    /// <summary>Sets a DRAFT's population tier. Draft-only — a published version is refused with the procedure's message.</summary>
    Task<DefinitionMinTier?> SetMinTierAsync(int workflowDefinitionId, int? minRequesterTier);
}
