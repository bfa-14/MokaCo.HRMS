using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>The context + request → PlannerInput mapping, the settings, the setup and the saved parameters.</summary>
public class AutoRosterFactoryTests
{
    private static readonly DateOnly Dec = new(2026, 12, 1);

    private static AutoRosterRequest Valid() => new() { BranchId = 1, Month = "2026-12", Mode = "ReplanAuto" };

    [Fact]
    public void A_valid_request_has_no_problem()
        => Assert.Null(AutoRosterInputFactory.Problem(Valid()));

    [Theory]
    [InlineData("branch", "Choose a branch.")]
    [InlineData("month", "The month must look like 2026-12.")]
    [InlineData("mode", "Choose a real mode.")]
    [InlineData("numericMode", "Choose a real mode.")]
    [InlineData("rhythm", "The rhythm start must be Aligned or Staggered.")]
    [InlineData("cover", "Holiday cover cannot be negative.")]
    [InlineData("override", "A week has 6 or 5 working days.")]
    public void A_bad_request_is_named_in_one_sentence(string what, string sentence)
    {
        var r = Valid();
        switch (what)
        {
            case "branch": r.BranchId = 0; break;
            case "month": r.Month = "December"; break;
            case "mode": r.Mode = "FillEverything"; break;
            case "numericMode": r.Mode = "1"; break;
            case "rhythm": r.RhythmStart = "Random"; break;
            case "cover": r.HolidayCover.Add(new HolidayCoverDto { Date = Dec, Count = -1 }); break;
            case "override": r.RhythmOverrides.Add(new RhythmOverrideDto { EmployeeId = 1, WeekStart = Dec, WorkDays = 4 }); break;
        }

        Assert.Equal(sentence, AutoRosterInputFactory.Problem(r));
        var ex = Assert.Throws<ArgumentException>(() => AutoRosterInputFactory.Create(new RosterWorld().Context(Dec), r));
        Assert.StartsWith(sentence, ex.Message);
    }

    [Fact]
    public void Missing_or_unreadable_settings_take_the_documented_defaults()
    {
        var s = AutoRosterInputFactory.ReadSettings(
        [
            new AutoRosterSettingRow { SettingKey = "RosterMaxConsecutiveWorkDays", SettingValue = "seven" },
            new AutoRosterSettingRow { SettingKey = "RosterPairRestDays", SettingValue = null },
        ]);
        Assert.Equal(PlannerSettings.Default, s);
        Assert.Equal(RhythmStartRule.Aligned, s.RhythmStart);
        Assert.Equal(7, s.MaxConsecutiveWorkDays);
        Assert.Equal(6, s.PreferredMaxConsecutiveWorkDays);
        Assert.Equal(26, s.FairnessLookbackWeeks);
        Assert.True(s.PairRestDays);
        Assert.Equal(PatternRestRule.Preference, s.PatternRestDays);
        Assert.Equal(11, s.MinHoursBetweenShifts);
        Assert.Equal(36, s.MinWeeklyRestHours);
    }

    [Fact]
    public void Settings_are_read_case_insensitively_and_the_preferred_maximum_stays_under_the_cap()
    {
        var s = AutoRosterInputFactory.ReadSettings(
        [
            new AutoRosterSettingRow { SettingKey = "rosterrhythmstart", SettingValue = "staggered" },
            new AutoRosterSettingRow { SettingKey = "RosterHolidayCountsAsRest", SettingValue = "1" },
            new AutoRosterSettingRow { SettingKey = "RosterMaxConsecutiveWorkDays", SettingValue = "6" },
            new AutoRosterSettingRow { SettingKey = "RosterPreferredMaxConsecutiveWorkDays", SettingValue = "9" },
            new AutoRosterSettingRow { SettingKey = "RosterFairnessLookbackWeeks", SettingValue = "13" },
            new AutoRosterSettingRow { SettingKey = "RosterPairRestDays", SettingValue = "false" },
            new AutoRosterSettingRow { SettingKey = "RosterPatternRestDays", SettingValue = "Unavailable" },
            new AutoRosterSettingRow { SettingKey = "RosterMinHoursBetweenShifts", SettingValue = "12" },
            new AutoRosterSettingRow { SettingKey = "RosterMinWeeklyRestHours", SettingValue = "24" },
        ]);
        Assert.Equal(RhythmStartRule.Staggered, s.RhythmStart);
        Assert.True(s.HolidayCountsAsRest);
        Assert.Equal(6, s.MaxConsecutiveWorkDays);
        Assert.Equal(6, s.PreferredMaxConsecutiveWorkDays);
        Assert.Equal(13, s.FairnessLookbackWeeks);
        Assert.False(s.PairRestDays);
        Assert.Equal(PatternRestRule.Unavailable, s.PatternRestDays);
        Assert.Equal(12, s.MinHoursBetweenShifts);
        Assert.Equal(24, s.MinWeeklyRestHours);

        // The drawer's choice beats the setting for one run.
        Assert.Equal(RhythmStartRule.Aligned,
            AutoRosterInputFactory.ReadSettings([new AutoRosterSettingRow { SettingKey = "RosterRhythmStart", SettingValue = "Staggered" }], "Aligned").RhythmStart);

        var dto = AutoRosterInputFactory.ToDto(s);
        Assert.Equal("Staggered", dto.RosterRhythmStart);
        Assert.Equal("Unavailable", dto.RosterPatternRestDays);
    }

    [Fact]
    public void The_input_maps_dates_holidays_leave_drafts_and_the_header()
    {
        var world = new RosterWorld { OpenRequestId = 9, Today = new DateOnly(2026, 11, 20) }.WithStaff(2);
        var christmas = new DateOnly(2026, 12, 25);
        world.Holiday(christmas, "Christmas (all)", paid: true);
        world.Holiday(christmas, "Christmas (branch)", paid: false, branch: RosterWorld.Branch);
        world.Holiday(new DateOnly(2026, 12, 8), "Elsewhere", branch: RosterWorld.OtherBranch);
        world.Leave(1, new DateOnly(2026, 12, 10), new DateOnly(2026, 12, 10), halfDay: "AM");
        world.Leave(1, new DateOnly(2026, 12, 9), new DateOnly(2026, 12, 11));

        var request = new AutoRosterRequest { BranchId = 1, Month = "2026-12", Mode = "fillempty" };
        request.DraftCells.Add(new DraftCellDto { EmployeeId = 2, WorkDate = new DateOnly(2026, 12, 3), IsRestDay = true });
        request.DraftCells.Add(new DraftCellDto { EmployeeId = 2, WorkDate = new DateOnly(2026, 12, 4) });
        request.DraftCells.Add(new DraftCellDto { EmployeeId = 2, WorkDate = new DateOnly(2026, 12, 5), ShiftId = RosterWorld.Day });
        request.DraftCells.Add(new DraftCellDto { EmployeeId = 2, WorkDate = new DateOnly(2026, 12, 5), ShiftId = RosterWorld.Evening });
        var input = AutoRosterInputFactory.Create(world.Context(Dec), request);

        Assert.Equal(RosterMode.FillEmpty, input.Mode);
        Assert.True(input.MonthLocked);
        Assert.Equal(new DateOnly(2026, 11, 20), input.Today);
        Assert.Equal((new DateOnly(2026, 11, 30), new DateOnly(2027, 1, 3)), (input.WindowFrom, input.WindowTo));

        var holiday = input.Holidays[christmas];
        Assert.Equal(("Christmas (branch)", false), (holiday.Name, holiday.IsPaid));
        Assert.False(input.Holidays.ContainsKey(new DateOnly(2026, 12, 8)));

        Assert.Equal(LeaveKind.Full, input.LeaveOn(1, new DateOnly(2026, 12, 10)));   // a full day beats a half day
        Assert.Equal(LeaveKind.None, input.LeaveOn(1, new DateOnly(2026, 12, 12)));

        Assert.Equal(CellState.Rest, input.DraftCells[new EmpDay(2, new DateOnly(2026, 12, 3))].State);
        Assert.Equal(CellState.None, input.DraftCells[new EmpDay(2, new DateOnly(2026, 12, 4))].State);
        Assert.Equal(RosterWorld.Evening, input.DraftCells[new EmpDay(2, new DateOnly(2026, 12, 5))].ShiftId);   // the last one wins
    }

    [Fact]
    public void Rows_and_leave_after_the_window_are_read_up_to_the_cap_and_the_staff_dates_decide_employment()
    {
        // December's window ends Sun 3 Jan; with the cap at 7 the following month is read to Sun 10 Jan.
        var world = new RosterWorld().WithStaff(2);
        world.Add(3, termination: new DateOnly(2027, 1, 5));
        foreach (var e in new[] { 1, 2, 3 })
            foreach (var d in RosterCalendar.Days(new DateOnly(2027, 1, 4), new DateOnly(2027, 1, 12)))
                world.Work(e, d);
        world.Leave(2, new DateOnly(2027, 1, 6), new DateOnly(2027, 1, 20));
        var input = AutoRosterInputFactory.Create(world.Context(Dec), world.Request(Dec));

        Assert.Equal(new DateOnly(2027, 1, 10), input.HorizonTo);
        Assert.True(input.WorksOutsideWindow(1, new DateOnly(2027, 1, 10)));
        Assert.Null(input.RowOf(1, new DateOnly(2027, 1, 11)));
        Assert.Equal(LeaveKind.Full, input.LeaveOn(2, new DateOnly(2027, 1, 10)));
        Assert.Equal(LeaveKind.None, input.LeaveOn(2, new DateOnly(2027, 1, 11)));   // past the horizon: not expanded
        Assert.False(input.WorksOutsideWindow(2, new DateOnly(2027, 1, 6)));          // a full-day leave breaks a run

        // The employed days stop at the window; after it the hire and termination dates decide.
        Assert.True(input.WorksOutsideWindow(3, new DateOnly(2027, 1, 5)));
        Assert.False(input.WorksOutsideWindow(3, new DateOnly(2027, 1, 6)));
    }

    [Fact]
    public void Setup_lists_the_staff_with_their_first_week_type_and_only_active_shifts_and_month_holidays()
    {
        var world = new RosterWorld().WithStaff(3);
        world.Anchor(1, new DateOnly(2026, 11, 23), 6);              // → the 30 Nov week is a 5-day week
        world.Anchor(3, new DateOnly(2026, 11, 30), 6, onRotation: false);
        world.Holiday(new DateOnly(2026, 12, 25), "Christmas");
        world.Holiday(new DateOnly(2027, 1, 1), "New Year");         // in the window, not in the month
        world.Min(2);
        world.Min(3, dayOfWeek: 6, shiftId: RosterWorld.Evening, target: 4);

        var context = world.Context(Dec);
        context.LastRun.Add(new AutoRosterLastRunRow
        {
            RunId = 5,
            MonthDate = new DateTime(2026, 11, 1),
            Mode = "FillEmpty",
            ParamsJson = AutoRosterSetupFactory.SerializeParams(new AutoRosterRequest
            {
                BranchId = 1, Month = "2026-11", Mode = "FillEmpty", DefaultShiftId = RosterWorld.Morning,
                HolidayCover = [new HolidayCoverDto { Date = new DateOnly(2026, 11, 22), Count = 2 }],
            }),
        });

        var setup = AutoRosterSetupFactory.Create(context, Dec);

        Assert.Equal(Dec, setup.MonthDate);
        Assert.Equal(new[] { 1, 2, 3 }, setup.Staff.Select(s => s.EmployeeId));
        Assert.Equal(5, setup.Staff[0].FirstWeekWorkDays);
        Assert.Equal(new DateOnly(2026, 11, 23), setup.Staff[0].AnchorWeekStart);
        Assert.Equal(6, setup.Staff[1].FirstWeekWorkDays);   // no anchor: Aligned starts on 6
        Assert.Null(setup.Staff[1].AnchorWeekStart);
        Assert.False(setup.Staff[2].OnRotation);
        Assert.Equal(6, setup.Staff[2].FirstWeekWorkDays);

        Assert.Equal(new[] { new DateOnly(2026, 12, 25) }, setup.Holidays.Select(h => h.Date));
        Assert.DoesNotContain(setup.Shifts, s => s.ShiftId == RosterWorld.Retired);
        Assert.Equal(2, setup.Staffing.Count);
        Assert.Equal(7, setup.Settings.RosterMaxConsecutiveWorkDays);

        Assert.NotNull(setup.LastParams);
        Assert.Equal(RosterWorld.Morning, setup.LastParams!.DefaultShiftId);
        Assert.Equal(new DateOnly(2026, 11, 22), setup.LastParams.HolidayCover.Single().Date);
    }

    [Fact]
    public void Saved_parameters_are_camel_case_without_draft_cells_and_unreadable_ones_are_ignored()
    {
        var commit = new AutoRosterCommitRequest
        {
            BranchId = 1, Month = "2026-12", Mode = "ReplanAll", RhythmStart = "Staggered",
            OffRotationEmployeeIds = [4],
            DraftCells = [new DraftCellDto { EmployeeId = 1, WorkDate = Dec, IsRestDay = true }],
            Cells = [new AutoRosterCommitCell { EmployeeId = 1, WorkDate = Dec }],
        };

        var json = AutoRosterSetupFactory.SerializeParams(commit);
        Assert.Contains("\"rhythmStart\":\"Staggered\"", json);
        Assert.Contains("\"offRotationEmployeeIds\":[4]", json);
        Assert.DoesNotContain("\"cells\"", json);
        Assert.Contains("\"draftCells\":[]", json);

        var back = AutoRosterSetupFactory.ParseParams(json);
        Assert.Equal(("ReplanAll", "Staggered"), (back!.Mode, back.RhythmStart));
        Assert.Null(AutoRosterSetupFactory.ParseParams("{not json"));
        Assert.Null(AutoRosterSetupFactory.ParseParams(null));
    }

    [Fact]
    public void The_cell_info_row_maps_its_date_for_the_api()
    {
        var dto = new RosterCellInfoRow { EmployeeId = 3, WorkDate = new DateTime(2026, 12, 9), IsPinned = true, IsAuto = false, ReasonCode = "REST_PAIR" }.ToDto();
        Assert.Equal((3, new DateOnly(2026, 12, 9), true, false, "REST_PAIR"), (dto.EmployeeId, dto.WorkDate, dto.IsPinned, dto.IsAuto, dto.ReasonCode));
    }

    [Theory]
    [InlineData("work", 1, null, "insert")]
    [InlineData("work", 1, 1, "unchanged")]
    [InlineData("work", 2, 1, "update")]
    [InlineData("rest", null, null, "insert")]
    [InlineData("none", null, null, "unchanged")]
    [InlineData("none", null, 1, "delete")]
    public void The_diff_compares_the_desired_state_with_the_row(string state, int? shift, int? currentShift, string change)
    {
        var cell = new GridCell
        {
            EmployeeId = 1,
            Date = Dec,
            InMonth = true,
            Employed = true,
            InBranch = true,
            Current = currentShift is { } s ? new RosterRow(s, false) : null,
            State = state switch { "work" => CellState.Work, "rest" => CellState.Rest, _ => CellState.None },
            ShiftId = shift,
        };
        Assert.Equal(change, RosterPlanner.ChangeOf(cell));

        cell.IsFact = true;
        Assert.Equal("kept", RosterPlanner.ChangeOf(cell));
    }
}
