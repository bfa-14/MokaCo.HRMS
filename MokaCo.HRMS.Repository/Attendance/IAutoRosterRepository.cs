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
    /// Then, beside it (script 123), the branch's shift leaders and the shifts' dated hours from the history's
    /// first day to past the window: each empty while that script is not applied.
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

    /// <summary>attendance.usp_RosterRotation_Get (script 116): the branch's fixed rotation - its start date, its two shifts and the list. Unset fields are null, the list may be empty.</summary>
    Task<RosterRotationDto> GetRotationAsync(int branchId, int? callerUserId);

    /// <summary>attendance.usp_RosterRotation_Save: replaces the branch's rotation and the lines of its people.</summary>
    Task SaveRotationAsync(RosterRotationDto rotation, int? callerUserId);

    /// <summary>
    /// attendance.usp_AutoRoster_GetLeaders (script 123): the branch's shift leaders - its own list and the rotation
    /// list's Lead 1 / Lead 2 - one row per person. <see cref="Common.MissingScriptException"/> while the script is not applied.
    /// </summary>
    Task<IReadOnlyList<RosterLeaderDto>> GetLeadersAsync(int branchId, int? callerUserId);

    /// <summary>
    /// attendance.usp_AutoRoster_GetLeaderCandidates (script 123): who may be added to the branch's own list - its people
    /// today, still employed - by name.
    /// </summary>
    Task<IReadOnlyList<RosterLeaderCandidateDto>> GetLeaderCandidatesAsync(int branchId, int? callerUserId);

    /// <summary>attendance.usp_AutoRoster_SaveLeaders (script 123): replaces the branch's own list; an empty list clears it.</summary>
    Task SaveLeadersAsync(int branchId, IEnumerable<int> employeeIds, int? callerUserId);

    /// <summary>attendance.usp_AutoRoster_GetShiftHours (script 123): every dated version of every shift in force at some point of the period.</summary>
    Task<IReadOnlyList<AutoRosterShiftHoursRow>> GetShiftHoursAsync(DateOnly fromDate, DateOnly toDate);
}
