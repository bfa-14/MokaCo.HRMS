using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Repository.Workflow;

/// <summary>Chain configuration: request types and their versioned approval-chain definitions.</summary>
public interface IDefinitionRepository
{
    Task<IEnumerable<RequestType>> GetRequestTypesAsync();

    /// <summary>
    /// The types that can actually be raised right now. Returns ONE ROW PER ACTIVE CHAIN, so a type
    /// with several tier-scoped chains appears more than once — the caller must collapse by Code.
    /// </summary>
    Task<IEnumerable<RaisableRequestType>> GetRaisableRequestTypesAsync();

    Task<int> UpsertRequestTypeAsync(string code, string name, string? description, bool isActive);

    Task<IEnumerable<WorkflowDefinition>> GetDefinitionsAsync(int? requestTypeId);
    Task<DefinitionCreated> CreateDraftAsync(int requestTypeId, string? notes, int? createdBy);
    Task AddStepAsync(int workflowDefinitionId, DefinitionAddStepRequest step);
    Task<DefinitionPublished?> PublishAsync(int workflowDefinitionId, int? publishedBy);
    Task<IEnumerable<WorkflowStep>> GetStepsAsync(int workflowDefinitionId);

    /// <summary>Deletes a DRAFT definition and its steps. RAISERRORs on anything but a Draft.</summary>
    Task DeleteDraftAsync(int workflowDefinitionId);
    Task<IEnumerable<ActiveDefinitionStep>> GetActiveAsync(string requestTypeCode, int? forEmployeeId = null);

    /// <summary>Chains a draft can be started from — any version, of any type, that has steps.</summary>
    Task<IEnumerable<DefinitionCopySource>> GetCopySourcesAsync();

    /// <summary>
    /// Copies one chain's steps into a DRAFT. RAISERRORs on a published target, and on a draft that
    /// already has steps unless replaceExisting is set.
    /// </summary>
    Task<DefinitionCopyResult?> CopyStepsFromAsync(int targetDefinitionId, int sourceDefinitionId, bool replaceExisting);

    /// <summary>Sets a DRAFT's population tier (2/3/null). RAISERRORs on a published version or bad value.</summary>
    Task<DefinitionMinTier?> SetMinTierAsync(int workflowDefinitionId, int? minRequesterTier);

    /// <summary>The decision-type catalogue (usp_DecisionType_GetAll). Inactive types are excluded unless asked for.</summary>
    Task<IEnumerable<DecisionTypeConfig>> GetDecisionTypesAsync(bool includeInactive);

    /// <summary>
    /// Restricts one step to a set of decision codes (usp_Definition_SetStepDecisions). Null or empty
    /// restores the default — every selectable type.
    /// </summary>
    Task SetStepDecisionsAsync(int workflowStepId, string? decisionCodes);
}
