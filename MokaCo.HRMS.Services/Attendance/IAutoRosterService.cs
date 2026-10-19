using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.Attendance;

/// <summary>
/// The auto-roster (docs/AUTO_ROSTER.md): the drawer's setup, a preview that writes nothing, and the
/// one atomic save. Every refusal is a <see cref="WorkflowException"/> carrying its status — 400 for
/// a request that cannot be planned, the procedures' own sentences mapped by WorkflowSqlErrors —
/// and a draft that breaks a rule is an <see cref="AutoRosterRefusedException"/> with the issues.
/// </summary>
public interface IAutoRosterService
{
    /// <summary>What the drawer opens with. <paramref name="month"/> is "yyyy-MM".</summary>
    Task<AutoRosterSetup> GetSetupAsync(int branchId, string? month, int? callerUserId);

    /// <summary>Plans the branch-month and returns the draft. Reads only: nothing is saved.</summary>
    Task<AutoRosterPreview> PreviewAsync(AutoRosterRequest request, int? callerUserId);

    /// <summary>
    /// Saves the submitted cells and rhythm. They are first validated against the roster as it stands
    /// now; any error-level issue refuses the whole save before the procedure is called.
    /// </summary>
    Task<AutoRosterCommitResult> CommitAsync(AutoRosterCommitRequest request, int? callerUserId);

    Task<IEnumerable<RosterCellInfo>> GetCellsAsync(int branchId, DateOnly from, DateOnly to, int? callerUserId);
    Task SetPinAsync(RosterPinRequest request, int? callerUserId);
    Task<IEnumerable<StaffingRequirementDto>> GetStaffingAsync(int branchId, int? callerUserId);
    Task SaveStaffingAsync(int branchId, IEnumerable<StaffingRequirementDto> rows, int? callerUserId);
    Task SaveRhythmAsync(IEnumerable<RosterRhythmDto> rows, int? callerUserId);
}

/// <summary>
/// A commit refused by the validator (§2.7): a 400 whose body also carries the issues, so the preview
/// card can mark the cells instead of showing one sentence. Every issue is returned, not only the
/// errors — it is the same list a preview of the submitted draft would show.
/// </summary>
public sealed class AutoRosterRefusedException : WorkflowException
{
    public IReadOnlyList<AutoRosterIssue> Issues { get; }

    public AutoRosterRefusedException(string message, IReadOnlyList<AutoRosterIssue> issues) : base(400, message)
        => Issues = issues;
}
