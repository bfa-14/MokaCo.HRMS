using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Repository.Attendance;

/// <summary>
/// The auto-roster's procedures (docs/96_auto_roster.sql, spec docs/AUTO_ROSTER.md §3.3). The caller
/// is always the last parameter: every procedure scopes the branch itself (EMP_VIEW_ALL, or the
/// branch's manager) and refuses with a sentence, which the service maps to a status.
/// </summary>
public interface IAutoRosterRepository
{
    /// <summary>
    /// attendance.usp_AutoRoster_GetContext — everything the planner reads, as the 15 result sets in
    /// their fixed order. <paramref name="lookbackWeeks"/> NULL = the RosterFairnessLookbackWeeks setting.
    /// </summary>
    Task<AutoRosterContext> GetContextAsync(int branchId, DateOnly monthDate, int? lookbackWeeks, int? callerUserId);

    /// <summary>
    /// attendance.usp_AutoRoster_Commit — the reviewed cells and the rhythm in one transaction. Each
    /// cell carries the row it expected; the procedure refuses the whole save when one has moved.
    /// <paramref name="paramsJson"/> is the drawer's request as the branch's "last used" parameters.
    /// </summary>
    Task<AutoRosterCommitResult> CommitAsync(
        int branchId, DateOnly monthDate, string mode,
        IEnumerable<AutoRosterCommitCell> cells, IEnumerable<AutoRosterCommitRhythm> rhythm,
        string? paramsJson, int issueCount, int? callerUserId);

    /// <summary>attendance.usp_RosterCell_SetPin — "keep when regenerating". Writes no roster row.</summary>
    Task SetPinAsync(int employeeId, DateOnly workDate, bool isPinned, int? callerUserId);

    /// <summary>attendance.usp_RosterCell_GetRange — pin and auto markers of the saved days of a branch.</summary>
    Task<IEnumerable<RosterCellInfo>> GetCellsAsync(int branchId, DateOnly fromDate, DateOnly toDate, int? callerUserId);

    Task<IEnumerable<StaffingRequirementDto>> GetStaffingAsync(int branchId, int? callerUserId);

    /// <summary>attendance.usp_StaffingRequirement_Save — REPLACES the branch's rows; an empty list clears them.</summary>
    Task SaveStaffingAsync(int branchId, IEnumerable<StaffingRequirementDto> rows, int? callerUserId);

    /// <summary>attendance.usp_RosterRhythm_Save — on rotation, and optionally a new 6/5 anchor, per employee.</summary>
    Task SaveRhythmAsync(IEnumerable<RosterRhythmDto> rows, int? callerUserId);
}
