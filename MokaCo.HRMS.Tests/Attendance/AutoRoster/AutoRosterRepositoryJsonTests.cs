using System.Text.Json;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>
/// The JSON the auto-roster procedures receive, pinned without a database. The procedures read it with
/// OPENJSON ... WITH ('$.employeeId', '$.workDate', ...): a property spelled differently is not an
/// error there, it is a silent NULL — a rest day saved as "no shift and not a rest day", or an
/// expected row nobody checks. So the names are asserted one by one.
/// </summary>
public class AutoRosterRepositoryJsonTests
{
    private static JsonElement Single(string json)
    {
        using var doc = JsonDocument.Parse(json);
        Assert.Equal(JsonValueKind.Array, doc.RootElement.ValueKind);
        Assert.Equal(1, doc.RootElement.GetArrayLength());
        return doc.RootElement[0].Clone();
    }

    private static string[] Names(JsonElement element) => element.EnumerateObject().Select(p => p.Name).Order().ToArray();

    [Fact]
    public void Changes_are_the_flat_shape_of_the_commit_procedure()
    {
        var json = AutoRosterRepository.ChangesJson([new AutoRosterCommitCell
        {
            EmployeeId = 12,
            WorkDate = new DateOnly(2026, 12, 5),
            Action = "upsert",
            ShiftId = 3,
            IsRestDay = false,
            Expected = new RosterCellExpected { Exists = true, ShiftId = null, IsRestDay = true },
            IsAuto = true,
            ReasonCode = "REST_LEVEL",
            IsPinned = true,
        }]);

        var cell = Single(json);
        Assert.Equal(
            new[] { "action", "employeeId", "expectedExists", "expectedIsRestDay", "expectedShiftId", "isAuto", "isPinned",
                    "isRestDay", "reasonCode", "shiftId", "workDate" },
            Names(cell));
        Assert.Equal(12, cell.GetProperty("employeeId").GetInt32());
        Assert.Equal("2026-12-05", cell.GetProperty("workDate").GetString());
        Assert.Equal("upsert", cell.GetProperty("action").GetString());
        Assert.Equal(3, cell.GetProperty("shiftId").GetInt32());
        Assert.False(cell.GetProperty("isRestDay").GetBoolean());
        Assert.True(cell.GetProperty("expectedExists").GetBoolean());
        Assert.Equal(JsonValueKind.Null, cell.GetProperty("expectedShiftId").ValueKind);
        Assert.True(cell.GetProperty("expectedIsRestDay").GetBoolean());
        Assert.True(cell.GetProperty("isAuto").GetBoolean());
        Assert.Equal("REST_LEVEL", cell.GetProperty("reasonCode").GetString());
        Assert.True(cell.GetProperty("isPinned").GetBoolean());
    }

    /// <summary>isPinned null = "leave the pin as it is" in the procedure; it must arrive as null, not false.</summary>
    [Fact]
    public void A_delete_with_no_pin_change_sends_null_for_the_pin()
    {
        var cell = Single(AutoRosterRepository.ChangesJson([new AutoRosterCommitCell
        {
            EmployeeId = 4,
            WorkDate = new DateOnly(2026, 12, 25),
            Action = "delete",
            Expected = new RosterCellExpected { Exists = true, ShiftId = 1, IsRestDay = false },
            IsAuto = true,
            ReasonCode = "HOLIDAY_OFF",
        }]));

        Assert.Equal("delete", cell.GetProperty("action").GetString());
        Assert.Equal(JsonValueKind.Null, cell.GetProperty("isPinned").ValueKind);
        Assert.Equal(1, cell.GetProperty("expectedShiftId").GetInt32());
        Assert.False(cell.GetProperty("expectedIsRestDay").GetBoolean());
    }

    [Fact]
    public void A_rhythm_row_carries_its_anchor_as_a_monday_and_its_working_days()
    {
        var row = Single(AutoRosterRepository.RhythmJson([new AutoRosterCommitRhythm
        {
            EmployeeId = 7, AnchorWeekStart = new DateOnly(2026, 11, 30), AnchorWorkDays = 5, OnRotation = true,
        }]));

        Assert.Equal(new[] { "anchorWeekStart", "anchorWorkDays", "employeeId", "onRotation" }, Names(row));
        Assert.Equal("2026-11-30", row.GetProperty("anchorWeekStart").GetString());
        Assert.Equal(5, row.GetProperty("anchorWorkDays").GetInt32());
        Assert.True(row.GetProperty("onRotation").GetBoolean());
    }

    /// <summary>
    /// Taking someone off rotation without an anchor: the model's defaults (0001-01-01, 0) are "not
    /// given", which the procedure reads as NULLs — sent as they are, it would refuse the 0-day week.
    /// </summary>
    [Fact]
    public void A_rhythm_row_without_an_anchor_sends_nulls()
    {
        var row = Single(AutoRosterRepository.RhythmJson([new AutoRosterCommitRhythm { EmployeeId = 7, OnRotation = false }]));

        Assert.Equal(JsonValueKind.Null, row.GetProperty("anchorWeekStart").ValueKind);
        Assert.Equal(JsonValueKind.Null, row.GetProperty("anchorWorkDays").ValueKind);
        Assert.False(row.GetProperty("onRotation").GetBoolean());
    }

    [Fact]
    public void Staffing_and_rhythm_rows_use_the_names_their_procedures_read()
    {
        var staffing = Single(JsonSerializer.Serialize(
            new[] { new StaffingRequirementDto { DayOfWeek = 6, ShiftId = null, MinOnDuty = 3, TargetOnDuty = 4 } },
            AutoRosterRepository.JsonOptions));
        Assert.Equal(new[] { "dayOfWeek", "minOnDuty", "shiftId", "targetOnDuty" }, Names(staffing));
        Assert.Equal(6, staffing.GetProperty("dayOfWeek").GetInt32());

        var rhythm = Single(JsonSerializer.Serialize(
            new[] { new RosterRhythmDto { EmployeeId = 7, OnRotation = true, AnchorWeekStart = new DateOnly(2026, 12, 7), AnchorWorkDays = 6 } },
            AutoRosterRepository.JsonOptions));
        Assert.Equal(new[] { "anchorWeekStart", "anchorWorkDays", "employeeId", "onRotation" }, Names(rhythm));
        Assert.Equal("2026-12-07", rhythm.GetProperty("anchorWeekStart").GetString());
    }
}
