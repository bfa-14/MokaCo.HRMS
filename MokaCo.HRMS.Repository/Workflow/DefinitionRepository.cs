using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

/// <summary>
/// Dapper access for chain configuration via workflow.usp_RequestType_* and usp_Definition_*.
///
/// A chain is DATA: these procedures read and write WORKFLOW_DEFINITION / WORKFLOW_STEP rows. The
/// repository never decides an approval path — it only moves the configuration in and out.
/// </summary>
public class DefinitionRepository : IDefinitionRepository
{
    private readonly IDbConnectionFactory _factory;
    public DefinitionRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<RequestType>> GetRequestTypesAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<RequestType>(
            "workflow.usp_RequestType_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<RaisableRequestType>> GetRaisableRequestTypesAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<RaisableRequestType>(
            "workflow.usp_RequestType_GetRaisable",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<DefinitionCopySource>> GetCopySourcesAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<DefinitionCopySource>(
            "workflow.usp_Definition_GetCopySources",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<DefinitionCopyResult?> CopyStepsFromAsync(int targetDefinitionId, int sourceDefinitionId, bool replaceExisting)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<DefinitionCopyResult>(
            "workflow.usp_Definition_CopyStepsFrom",
            new
            {
                TargetDefinitionId = targetDefinitionId,
                SourceDefinitionId = sourceDefinitionId,
                ReplaceExisting = replaceExisting,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> UpsertRequestTypeAsync(string code, string name, string? description, bool isActive)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "workflow.usp_RequestType_Upsert",
            new { Code = code, Name = name, Description = description, IsActive = isActive },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<WorkflowDefinition>> GetDefinitionsAsync(int? requestTypeId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<WorkflowDefinition>(
            "workflow.usp_Definition_GetAll",
            new { RequestTypeId = requestTypeId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<DefinitionCreated> CreateDraftAsync(int requestTypeId, string? notes, int? createdBy)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<DefinitionCreated>(
            "workflow.usp_Definition_CreateDraft",
            new { RequestTypeId = requestTypeId, Notes = notes, CreatedBy = createdBy },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>The procedure refuses this on anything but a Draft — that SQL error is what stops a live chain being edited.</summary>
    public async Task AddStepAsync(int workflowDefinitionId, DefinitionAddStepRequest step)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "workflow.usp_Definition_AddStep",
            new
            {
                WorkflowDefinitionId = workflowDefinitionId,
                step.StepNo,
                step.Name,
                step.ApproverType,
                step.ApproverRoleId,
                step.ApproverUserId,
                FallbackRoleId = step.DeputyRoleId,
                step.IsMandatory,
                step.CanAdjust,
                step.RequiresComment,
                step.RequiresSignature,
                // EscalationLevels is NOT NULL in the column, and a passed NULL would OVERRIDE the
                // proc's default (a stored-proc default only applies when the parameter is omitted, and
                // Dapper always sends it) — so any non-LineManager step would throw. Always send a real
                // value: 1 for the types that ignore it, the chosen level for a LineManager step.
                EscalationLevels =
                    step.ApproverType == "LineManager" ? (step.EscalationLevels ?? 1) : 1,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<DefinitionPublished?> PublishAsync(int workflowDefinitionId, int? publishedBy)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<DefinitionPublished>(
            "workflow.usp_Definition_Publish",
            new { WorkflowDefinitionId = workflowDefinitionId, PublishedBy = publishedBy },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<WorkflowStep>> GetStepsAsync(int workflowDefinitionId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<WorkflowStep>(
            "workflow.usp_Definition_GetSteps",
            new { WorkflowDefinitionId = workflowDefinitionId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Deletes a DRAFT and its steps. The procedure REFUSES anything but a Draft (SqlException), which the service maps to a clean 400.</summary>
    public async Task DeleteDraftAsync(int workflowDefinitionId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "workflow.usp_Definition_DeleteDraft",
            new { WorkflowDefinitionId = workflowDefinitionId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>One row per step of the currently-published chain — what a requester is shown before submitting.</summary>
    public async Task<IEnumerable<ActiveDefinitionStep>> GetActiveAsync(string requestTypeCode, int? forEmployeeId = null)
    {
        using var db = _factory.Create();
        // With a ForEmployeeId the procedure resolves to the single chain that requester's tier runs —
        // the SAME resolution the submit uses, so the preview matches what will actually happen.
        return await db.QueryAsync<ActiveDefinitionStep>(
            "workflow.usp_Definition_GetActive",
            new { RequestTypeCode = requestTypeCode, ForEmployeeId = forEmployeeId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Sets a DRAFT's population tier. The procedure RAISERRORs on a published version or a bad value.</summary>
    public async Task<DefinitionMinTier?> SetMinTierAsync(int workflowDefinitionId, int? minRequesterTier)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<DefinitionMinTier>(
            "workflow.usp_Definition_SetMinTier",
            new { WorkflowDefinitionId = workflowDefinitionId, MinRequesterTier = minRequesterTier },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// The decision-type catalogue every decision dropdown is built from. Inactive types are excluded
    /// by default — a retired type must not reappear in a menu, but a setup screen still needs to see
    /// it to bring it back.
    /// </summary>
    public async Task<IEnumerable<DecisionTypeConfig>> GetDecisionTypesAsync(bool includeInactive)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<DecisionTypeConfig>(
            "workflow.usp_DecisionType_GetAll",
            new { IncludeInactive = includeInactive },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Restricts ONE step to a chosen set of decision codes. An empty or null list restores the
    /// default (every selectable type), which is why it travels as a comma-separated string:
    /// "nothing configured" and "an empty list" have to mean the same thing.
    /// </summary>
    public async Task SetStepDecisionsAsync(int workflowStepId, string? decisionCodes)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "workflow.usp_Definition_SetStepDecisions",
            new { WorkflowStepId = workflowStepId, DecisionCodes = decisionCodes },
            commandType: CommandType.StoredProcedure);
    }
}
