namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// A KIND of request the workflow engine can run — 'Exit permission', later 'Leave', and so on.
/// Maps to workflow.REQUEST_TYPE. The Code (e.g. 'EXIT_PERMISSION') is the stable handle the rest
/// of the system refers to; the Name is what people read.
/// </summary>
public class RequestType
{
    public int RequestTypeId { get; set; }
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; }
}

/// <summary>
/// A request type a user can ACTUALLY RAISE right now (usp_RequestType_GetRaisable): active, and
/// with a published chain. A type with no published chain is excluded on purpose — offering it would
/// produce a form that fails at submit, after the person had filled it in.
///
/// NOTE the shape of the source data: the procedure JOINs the active definitions, and a type may
/// have SEVERAL active at once (one per requester-tier population). It therefore returns one row per
/// active chain, and the service collapses them to one row per type — see GetRaisableRequestTypesAsync.
/// </summary>
public class RaisableRequestType
{
    public int RequestTypeId { get; set; }
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;

    /// <summary>The shorter label for a menu or a card. Falls back to Name in the procedure.</summary>
    public string MenuLabel { get; set; } = string.Empty;

    public string? Description { get; set; }

    /// <summary>Presentation kept WITH the type — adding a type should not mean editing the frontend.</summary>
    public string? Icon { get; set; }
    public int SortOrder { get; set; }
}

/// <summary>Creates or updates a request type. Addressed by Code — the same code upserts the same type.</summary>
public class RequestTypeUpsertRequest
{
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; } = true;
}
