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

    public async Task<AutoRosterContext> GetContextAsync(int branchId, DateOnly monthDate, int? lookbackWeeks, int? callerUserId)
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
}
