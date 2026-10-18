using System.Globalization;
using System.Text.Json;
using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance.AutoRoster;

/// <summary>
/// GET setup: the drawer's opening state, from the same context the preview reads. Also the one
/// place that writes and reads ROSTER_AUTO_RUN.ParamsJson, so the parameters a run saved are the
/// parameters the next drawer opens with.
/// </summary>
public static class AutoRosterSetupFactory
{
    /// <summary>
    /// CAMEL CASE, as every JSON in this codebase: the web reads lastParams back as an
    /// AutoRosterRequest, and dates stay "yyyy-MM-dd".
    /// </summary>
    public static readonly JsonSerializerOptions ParamsJsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
    };

    public static AutoRosterSetup Create(AutoRosterContext context, DateOnly anyDayOfMonth)
    {
        ArgumentNullException.ThrowIfNull(context);
        var monthStart = RosterCalendar.MonthStart(anyDayOfMonth);
        var header = context.Header;

        // Everyone on rotation for this read, so even the people the drawer has taken off show the
        // type their next planned week would have.
        var request = new AutoRosterRequest
        {
            BranchId = header.BranchId,
            Month = monthStart.ToString("yyyy-MM", CultureInfo.InvariantCulture),
            Mode = nameof(RosterMode.FillEmpty),
            OffRotationEmployeeIds = [],
        };
        var input = AutoRosterInputFactory.Create(context, request);
        var rhythms = RosterPlanner.ResolveRhythms(input);
        var stored = context.Rhythm.GroupBy(r => r.EmployeeId).ToDictionary(g => g.Key, g => g.First());

        var setup = new AutoRosterSetup
        {
            BranchId = header.BranchId,
            MonthDate = monthStart,
            Settings = AutoRosterInputFactory.ToDto(input.Settings),
            MonthStatus = header.MonthStatus,
            OpenRequestId = header.OpenRequestId,
            LastParams = ParseParams(context.LastRun.OrderByDescending(r => r.RunId).FirstOrDefault()?.ParamsJson),
        };

        foreach (var s in input.Staff)
        {
            stored.TryGetValue(s.EmployeeId, out var row);
            var valid = row is { AnchorWorkDays: 5 or 6 };
            setup.Staff.Add(new AutoRosterSetupStaff
            {
                EmployeeId = s.EmployeeId,
                FullName = s.FullName,
                Position = s.Position,
                OnRotation = row?.OnRotation ?? true,
                AnchorWeekStart = valid ? RosterCalendar.WeekStart(DateOnly.FromDateTime(row!.AnchorWeekStart)) : null,
                AnchorWorkDays = valid ? row!.AnchorWorkDays : null,
                FirstWeekWorkDays = rhythms.TryGetValue(s.EmployeeId, out var r) ? r.WorkDaysIn(monthStart) : 6,
            });
        }

        setup.Staffing = context.Staffing
            .OrderBy(s => s.DayOfWeek ?? 0).ThenBy(s => s.ShiftId ?? 0)
            .Select(s => new StaffingRequirementDto
            {
                DayOfWeek = s.DayOfWeek,
                ShiftId = s.ShiftId,
                MinOnDuty = s.MinOnDuty,
                TargetOnDuty = s.TargetOnDuty,
            })
            .ToList();

        setup.ShiftCoverDetected = input.ShiftCoverDetected;
        setup.ShiftCover = input.ShiftCover
            .Where(r => input.IsActiveShift(r.ShiftId))
            .OrderBy(r => r.DayOfWeek ?? 0)
            .ThenBy(r => input.Shifts[r.ShiftId!.Value].StartTime)
            .ThenBy(r => r.ShiftId)
            .Select(r => new StaffingRequirementDto
            {
                DayOfWeek = r.DayOfWeek,
                ShiftId = r.ShiftId,
                MinOnDuty = r.MinOnDuty,
                TargetOnDuty = r.TargetOnDuty,
            })
            .ToList();

        setup.Holidays = input.Holidays.Values
            .Where(h => input.InMonth(h.Date))
            .OrderBy(h => h.Date)
            .Select(h => new AutoRosterSetupHoliday { Date = h.Date, Name = h.Name, IsPaid = h.IsPaid })
            .ToList();

        setup.Shifts = input.Shifts.Values
            .Where(s => s.IsActive)
            .OrderBy(s => s.ShiftId)
            .Select(s => new AutoRosterSetupShift { ShiftId = s.ShiftId, Name = s.Name })
            .ToList();

        return setup;
    }

    /// <summary>
    /// The request part of a run for ROSTER_AUTO_RUN.ParamsJson. The draft edits are left out: they
    /// belong to one preview, not to the branch's defaults; a commit's cells never get here either.
    /// </summary>
    public static string SerializeParams(AutoRosterRequest request)
    {
        var copy = new AutoRosterRequest
        {
            BranchId = request.BranchId,
            Month = request.Month,
            Mode = request.Mode,
            RhythmStart = request.RhythmStart,
            DefaultShiftId = request.DefaultShiftId,
            HolidayCover = request.HolidayCover,
            OffRotationEmployeeIds = request.OffRotationEmployeeIds,
            RhythmOverrides = request.RhythmOverrides,
        };
        return JsonSerializer.Serialize(copy, ParamsJsonOptions);
    }

    /// <summary>A saved ParamsJson back as a request; null when absent or unreadable (the drawer then opens on the defaults).</summary>
    public static AutoRosterRequest? ParseParams(string? json)
    {
        if (string.IsNullOrWhiteSpace(json))
            return null;
        try
        {
            return JsonSerializer.Deserialize<AutoRosterRequest>(json, ParamsJsonOptions);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
