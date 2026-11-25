using System.Data;
using System.Text.Json;
using Dapper;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Attendance;

/// <summary>
/// Dapper access for the auto-roster (docs/96_auto_roster.sql). The planning itself is pure C# in
/// the service layer; the database only hands it everything in one read and takes the reviewed
/// draft back in one transaction, so this class stays a parameter-passer.
///
/// DATES CROSS AS DateTime. Dapper 2.1 has no DateOnly handler, so a DateOnly parameter would be
/// refused and a DATE column read into one would fail; the API's DateOnly values are turned into
/// midnight DateTimes here, and the context rows are typed DateTime (the planner converts them).
/// </summary>
public class AutoRosterRepository : IAutoRosterRepository
{
    /// <summary>
    /// camelCase, dates "yyyy-MM-dd": the names the procedures' OPENJSON ... WITH paths read. Public so
    /// the JSON the procedures receive can be pinned in tests without a database.
    /// </summary>
    public static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly IDbConnectionFactory _factory;
    public AutoRosterRepository(IDbConnectionFactory factory) => _factory = factory;

    /// <summary>
    /// How far past the window the dated shift hours are read: the procedure reads the rows up to WindowTo plus the
    /// RosterMaxConsecutiveWorkDays cap, which it clamps to 1..31 - so 31 days always reach the last row it gives.
    /// </summary>
    public const int ShiftHoursDaysAfterWindow = 31;

    /// <summary>
    /// The context (usp_AutoRoster_GetContext), then the two lists script 123 adds beside it: the branch's shift
    /// leaders and every dated version of the shifts from the history's first day to past the window. Each of the
    /// two is read on its own and guarded: while script 123 is not applied it is empty, and the planner works as it
    /// did before (leaders from the rotation list only, today's shift hours).
    /// </summary>
    public async Task<AutoRosterContext> GetContextAsync(int branchId, DateOnly monthDate, int? lookbackWeeks, int? callerUserId)
    {
        var context = await ReadContextAsync(branchId, monthDate, lookbackWeeks, callerUserId);
        context.ShiftLeaders = await OrEmptyWhenMissingAsync(async () =>
            (await GetLeadersAsync(branchId, callerUserId)).Select(l => l.EmployeeId).Distinct().ToList());
        context.ShiftHours = await OrEmptyWhenMissingAsync(async () => (await GetShiftHoursAsync(
            DateOnly.FromDateTime(context.Header.HistoryFrom),
            DateOnly.FromDateTime(context.Header.WindowTo).AddDays(ShiftHoursDaysAfterWindow))).ToList());
        return context;
    }

    /// <summary>A list of a script that may not be applied yet: empty then, as before the script.</summary>
    private static async Task<List<T>> OrEmptyWhenMissingAsync<T>(Func<Task<List<T>>> read)
    {
        try
        {
            return await read();
        }
        catch (MissingScriptException)
        {
            return [];
        }
    }

    private async Task<AutoRosterContext> ReadContextAsync(int branchId, DateOnly monthDate, int? lookbackWeeks, int? callerUserId)
    {
        using var db = _factory.Create();
        using var grid = await db.QueryMultipleAsync(
            "attendance.usp_AutoRoster_GetContext",
            new { BranchId = branchId, MonthDate = AsDate(monthDate), LookbackWeeks = lookbackWeeks, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);

        // The procedure's fixed order (§3.3). Read one by one, in that order: a grid reader only moves
        // forward, and a set read into the wrong type would fail on the first column that differs.
        // The header is the only set that is never empty — without it the planner would not know what
        // "today" is, so its absence is a fault, not an empty plan.
        var context = new AutoRosterContext();
        context.Header = await grid.ReadSingleAsync<AutoRosterContextHeader>();                  // 1
        context.Settings = (await grid.ReadAsync<AutoRosterSettingRow>()).AsList();              // 2
        context.Staff = (await grid.ReadAsync<AutoRosterStaffRow>()).AsList();                   // 3
        context.StaffDays = (await grid.ReadAsync<AutoRosterStaffDayRow>()).AsList();            // 4
        context.Rows = (await grid.ReadAsync<AutoRosterRowRow>()).AsList();                      // 5
        context.Locks = (await grid.ReadAsync<AutoRosterLockRow>()).AsList();                    // 6
        context.Holidays = (await grid.ReadAsync<AutoRosterHolidayRow>()).AsList();              // 7
        context.HolidaysWorked = (await grid.ReadAsync<AutoRosterHolidaysWorkedRow>()).AsList(); // 8
        context.Leaves = (await grid.ReadAsync<AutoRosterLeaveRow>()).AsList();                  // 9
        context.Shifts = (await grid.ReadAsync<AutoRosterShiftRow>()).AsList();                  // 10
        context.Patterns = (await grid.ReadAsync<AutoRosterPatternRow>()).AsList();              // 11
        context.Rhythm = (await grid.ReadAsync<AutoRosterRhythmRow>()).AsList();                 // 12
        context.Cells = (await grid.ReadAsync<AutoRosterCellRow>()).AsList();                    // 13
        context.Staffing = (await grid.ReadAsync<AutoRosterStaffingRow>()).AsList();             // 14
        context.LastRun = (await grid.ReadAsync<AutoRosterLastRunRow>()).AsList();               // 15
        return context;
    }

    public async Task<AutoRosterCommitResult> CommitAsync(
        int branchId, DateOnly monthDate, string mode,
        IEnumerable<AutoRosterCommitCell> cells, IEnumerable<AutoRosterCommitRhythm> rhythm,
        string? paramsJson, int issueCount, int? callerUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<AutoRosterCommitResult>(
            "attendance.usp_AutoRoster_Commit",
            new
            {
                BranchId = branchId,
                MonthDate = AsDate(monthDate),
                Mode = mode,
                ChangesJson = ChangesJson(cells),
                RhythmJson = RhythmJson(rhythm),
                ParamsJson = paramsJson,
                IssueCount = issueCount,
                CallerUserId = callerUserId,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task SetPinAsync(int employeeId, DateOnly workDate, bool isPinned, int? callerUserId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_RosterCell_SetPin",
            new { EmployeeId = employeeId, WorkDate = AsDate(workDate), IsPinned = isPinned, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<RosterCellInfo>> GetCellsAsync(int branchId, DateOnly fromDate, DateOnly toDate, int? callerUserId)
    {
        using var db = _factory.Create();
        var rows = await db.QueryAsync<RosterCellInfoRow>(
            "attendance.usp_RosterCell_GetRange",
            new { BranchId = branchId, FromDate = AsDate(fromDate), ToDate = AsDate(toDate), CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
        return rows.Select(r => r.ToDto()).ToList();
    }

    /// <summary>Read as the context's staffing row (DayOfWeek is a TINYINT) and handed out as the API's DTO.</summary>
    public async Task<IEnumerable<StaffingRequirementDto>> GetStaffingAsync(int branchId, int? callerUserId)
    {
        using var db = _factory.Create();
        var rows = await db.QueryAsync<AutoRosterStaffingRow>(
            "attendance.usp_StaffingRequirement_GetByBranch",
            new { BranchId = branchId, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
        return rows.Select(r => new StaffingRequirementDto
        {
            DayOfWeek = r.DayOfWeek,
            ShiftId = r.ShiftId,
            MinOnDuty = r.MinOnDuty,
            TargetOnDuty = r.TargetOnDuty,
        }).ToList();
    }

    public async Task SaveStaffingAsync(int branchId, IEnumerable<StaffingRequirementDto> rows, int? callerUserId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_StaffingRequirement_Save",
            new { BranchId = branchId, RowsJson = JsonSerializer.Serialize(rows, JsonOptions), CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task SaveRhythmAsync(IEnumerable<RosterRhythmDto> rows, int? callerUserId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_RosterRhythm_Save",
            new { RowsJson = JsonSerializer.Serialize(rows, JsonOptions), CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
    }

    /* ---- the JSON the commit procedure reads ---- */

    /// <summary>
    /// @ChangesJson in the flat shape of §3.3 (expectedExists / expectedShiftId / expectedIsRestDay).
    /// The procedure also reads the nested "expected" object the API receives, but the flat form is
    /// the documented contract, so it is the one sent.
    /// </summary>
    public static string ChangesJson(IEnumerable<AutoRosterCommitCell> cells)
        => JsonSerializer.Serialize(cells.Select(c => new ChangeRow(
            c.EmployeeId, c.WorkDate, c.Action, c.ShiftId, c.IsRestDay,
            c.Expected?.Exists ?? false, c.Expected?.ShiftId, c.Expected?.IsRestDay,
            c.IsAuto, c.ReasonCode, c.IsPinned)), JsonOptions);

    /// <summary>
    /// @RhythmJson. The API's rhythm row has a non-nullable anchor, so a row that only changes the
    /// on-rotation flag arrives with 0001-01-01 and 0 working days. Sent as is, the procedure would
    /// refuse it ("a week of the rhythm has 6 or 5 working days"); the anchor is "not given", which
    /// the procedure takes as NULLs. A half-given anchor goes through and is refused by name.
    /// </summary>
    public static string RhythmJson(IEnumerable<AutoRosterCommitRhythm> rows)
        => JsonSerializer.Serialize(rows.Select(r =>
        {
            var anchorGiven = r.AnchorWeekStart != default || r.AnchorWorkDays != 0;
            return new RhythmRow(
                r.EmployeeId,
                anchorGiven ? r.AnchorWeekStart : null,
                anchorGiven ? r.AnchorWorkDays : null,
                r.OnRotation);
        }), JsonOptions);

    private sealed record ChangeRow(
        int EmployeeId, DateOnly WorkDate, string Action, int? ShiftId, bool IsRestDay,
        bool ExpectedExists, int? ExpectedShiftId, bool? ExpectedIsRestDay,
        bool IsAuto, string? ReasonCode, bool? IsPinned);

    private sealed record RhythmRow(int EmployeeId, DateOnly? AnchorWeekStart, int? AnchorWorkDays, bool OnRotation);

    private static DateTime AsDate(DateOnly date) => date.ToDateTime(TimeOnly.MinValue);

    public Task<RosterRotationDto> GetRotationAsync(int branchId, int? callerUserId)
        => MissingScriptException.GuardAsync(Scripts.RosterRotation116, "attendance.usp_RosterRotation_Get", async () =>
        {
            using var db = _factory.Create();
            using var multi = await db.QueryMultipleAsync(
                "attendance.usp_RosterRotation_Get",
                new { BranchId = branchId, CallerUserId = callerUserId },
                commandType: CommandType.StoredProcedure);
            var branch = await multi.ReadSingleOrDefaultAsync<RosterRotationRow>();
            var members = (await multi.ReadAsync<RosterRotationMemberRow>()).ToList();
            return new RosterRotationDto
            {
                BranchId = branchId,
                StartDate = branch is null ? null : DateOnly.FromDateTime(branch.StartDate),
                MorningShiftId = branch?.MorningShiftId,
                EveningShiftId = branch?.EveningShiftId,
                Members = members.Select(m => new RosterRotationMemberDto
                {
                    EmployeeId = m.EmployeeId, Group = m.RotationGroup, SingleRestDay = m.SingleRestDay, PairRestDay = m.PairRestDay,
                    LeadSlot = m.LeadSlot, SortOrder = m.SortOrder,
                }).ToList(),
            };
        });

    public Task<IReadOnlyList<RosterLeaderDto>> GetLeadersAsync(int branchId, int? callerUserId)
        => MissingScriptException.GuardAsync(Scripts.RosterLeaders123, "attendance.usp_AutoRoster_GetLeaders", async () =>
        {
            using var db = _factory.Create();
            var rows = await db.QueryAsync<RosterLeaderDto>(
                "attendance.usp_AutoRoster_GetLeaders",
                new { BranchId = branchId, CallerUserId = callerUserId },
                commandType: CommandType.StoredProcedure);
            return (IReadOnlyList<RosterLeaderDto>)rows.AsList();
        });

    public Task<IReadOnlyList<RosterLeaderCandidateDto>> GetLeaderCandidatesAsync(int branchId, int? callerUserId)
        => MissingScriptException.GuardAsync(Scripts.RosterLeaders123, "attendance.usp_AutoRoster_GetLeaderCandidates", async () =>
        {
            using var db = _factory.Create();
            var rows = await db.QueryAsync<RosterLeaderCandidateDto>(
                "attendance.usp_AutoRoster_GetLeaderCandidates",
                new { BranchId = branchId, CallerUserId = callerUserId },
                commandType: CommandType.StoredProcedure);
            return (IReadOnlyList<RosterLeaderCandidateDto>)rows.AsList();
        });

    public Task SaveLeadersAsync(int branchId, IEnumerable<int> employeeIds, int? callerUserId)
        => MissingScriptException.GuardAsync(Scripts.RosterLeaders123, "attendance.usp_AutoRoster_SaveLeaders", async () =>
        {
            using var db = _factory.Create();
            await db.ExecuteAsync(
                "attendance.usp_AutoRoster_SaveLeaders",
                new { BranchId = branchId, EmployeeIdsJson = JsonSerializer.Serialize(employeeIds, JsonOptions), CallerUserId = callerUserId },
                commandType: CommandType.StoredProcedure);
        });

    public Task<IReadOnlyList<AutoRosterShiftHoursRow>> GetShiftHoursAsync(DateOnly fromDate, DateOnly toDate)
        => MissingScriptException.GuardAsync(Scripts.RosterLeaders123, "attendance.usp_AutoRoster_GetShiftHours", async () =>
        {
            using var db = _factory.Create();
            var rows = await db.QueryAsync<AutoRosterShiftHoursRow>(
                "attendance.usp_AutoRoster_GetShiftHours",
                new { FromDate = AsDate(fromDate), ToDate = AsDate(toDate) },
                commandType: CommandType.StoredProcedure);
            return (IReadOnlyList<AutoRosterShiftHoursRow>)rows.AsList();
        });

    public Task SaveRotationAsync(RosterRotationDto rotation, int? callerUserId)
        => MissingScriptException.GuardAsync(Scripts.RosterRotation116, "attendance.usp_RosterRotation_Save", async () =>
        {
            using var db = _factory.Create();
            await db.ExecuteAsync(
                "attendance.usp_RosterRotation_Save",
                new
                {
                    rotation.BranchId,
                    StartDate = rotation.StartDate?.ToDateTime(TimeOnly.MinValue),
                    rotation.MorningShiftId,
                    rotation.EveningShiftId,
                    MembersJson = JsonSerializer.Serialize(rotation.Members, JsonOptions),
                    CallerUserId = callerUserId,
                },
                commandType: CommandType.StoredProcedure);
        });
}
