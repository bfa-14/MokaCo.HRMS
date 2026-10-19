namespace MokaCo.HRMS.Model.HR;

/// <summary>
/// hr.usp_Scope_CallerSees (script 98): whether the signed-in user may read ONE record under the
/// branch scope of script 87.
/// </summary>
public class CallerScope
{
    /// <summary>The record exists.</summary>
    public bool Found { get; set; }

    /// <summary>EMP_VIEW_ALL, the caller's own record, or a branch they manage.</summary>
    public bool CanSee { get; set; }

    /// <summary>The record is the caller's own.</summary>
    public bool IsSelf { get; set; }
}
