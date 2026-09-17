using System.Text.Json;
using Dapper;
using Microsoft.Data.SqlClient;

namespace MokaCo.HRMS.Tests.Attendance;

/// <summary>
/// THE DAY RULE (docs/76_attendance_single_day_rule.sql) lives in attendance.fn_AttendanceDayRule,
/// an inline table function with no table access: every figure of an attendance day is a function
/// of the shift, the punches, the approvals and two settings. These tests hold each line of the
/// rule to its stated arithmetic, one scenario per line, against the database the API uses.
///
/// They run when a MokaCo_HRMS database is reachable (MOKACO_TEST_CONNECTION, else the API's
/// appsettings.json) and script 76 has been applied; otherwise every test is skipped with the
/// reason, so <c>dotnet test</c> stays green on a machine without SQL Server.
/// </summary>
public class AttendanceDayRuleTests
{
    /* the Morning shift of the QA fixture: 07:00–16:00, break 30, grace 10, standard 510 */
    private static readonly DateTime Day = new(2026, 8, 3);
    private static readonly DateTime ShiftStart = Day.AddHours(7);
    private static readonly DateTime ShiftEnd = Day.AddHours(16);
    private const int Break = 30, Grace = 10, Standard = 510;

    private sealed record Outcome(
        string Status, DateTime? EffectiveInUtc, DateTime? EffectiveOutUtc,
        int LateMinutes, int LateDeductMinutes, int EarlyExitMinutes, int MidDayGapMinutes,
        int ExitActualMinutes, int ExitApprovedMinutes, int ExitVarianceMinutes, int OvertimeMinutes,
        int WorkedMinutes, int CoveredMinutes, decimal? DayFraction, bool IsFullDay,
        int ShortfallMinutes, int BreakApplied, int StandardMinutes);

    private static async Task<Outcome> RuleAsync(
        DateTime? firstIn, DateTime? lastOut,
        int gapMinutes = 0, int exitApproved = 0, string? disposition = null, int overtimeApproved = 0,
        string lateBasis = "BeyondGrace", decimal fullDayThreshold = 1.00m,
        bool restDay = false, bool onLeave = false, bool holiday = false,
        DateTime? shiftStart = null, DateTime? shiftEnd = null, int? standard = null, bool noShift = false)
    {
        await using var db = new SqlConnection(DbFactAttribute.ConnectionString);
        var rows = await db.QueryAsync<Outcome>(
            """
            SELECT [Status], EffectiveInUtc, EffectiveOutUtc, LateMinutes, LateDeductMinutes, EarlyExitMinutes, MidDayGapMinutes,
                   ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes, OvertimeMinutes, WorkedMinutes, CoveredMinutes,
                   DayFraction, IsFullDay, ShortfallMinutes, BreakApplied, StandardMinutes
            FROM attendance.fn_AttendanceDayRule(@ShiftStart, @ShiftEnd, @Break, @Grace, @Standard, @FirstIn, @LastOut, @Gap,
                                                 @ExitApproved, @Disposition, @OtApproved, @LateBasis, @Threshold, @RestDay, @OnLeave, @Holiday)
            """,
            new
            {
                ShiftStart = noShift ? (DateTime?)null : shiftStart ?? ShiftStart,
                ShiftEnd = noShift ? (DateTime?)null : shiftEnd ?? ShiftEnd,
                Break, Grace,
                Standard = standard ?? Standard,
                FirstIn = firstIn, LastOut = lastOut, Gap = gapMinutes,
                ExitApproved = exitApproved, Disposition = disposition, OtApproved = overtimeApproved,
                LateBasis = lateBasis, Threshold = fullDayThreshold,
                RestDay = restDay, OnLeave = onLeave, Holiday = holiday
            });
        return Assert.Single(rows);
    }

    /* ---- EffectiveIn = max(FirstIn, ShiftStart): early arrival never counts (BUG-16) ---- */
    [DbFact]
    public async Task Early_arrival_starts_the_day_at_the_shift_start()
    {
        var r = await RuleAsync(Day.AddHours(6).AddMinutes(40), Day.AddHours(16));

        Assert.Equal(ShiftStart, r.EffectiveInUtc);
        Assert.Equal(510, r.WorkedMinutes);          // 07:00–16:00 − 30, not 06:40–16:00
        Assert.Equal(0, r.OvertimeMinutes);           // the 20 early minutes are not overtime
        Assert.Equal(0, r.LateMinutes);
        Assert.Equal(1.00m, r.DayFraction);
    }

    /* ---- an approved OVERTIME request lets pre-shift minutes count as overtime ---- */
    [DbFact]
    public async Task Early_arrival_counts_as_overtime_only_as_far_as_an_approved_request_covers_it()
    {
        var r = await RuleAsync(Day.AddHours(6), Day.AddHours(16), overtimeApproved: 30);

        Assert.Equal(510, r.WorkedMinutes);           // presence inside the shift is unchanged
        Assert.Equal(30, r.OvertimeMinutes);          // 60 early minutes, 30 approved → 30 detected
    }

    /* ---- LateMinutes: grace is a THRESHOLD (BUG-15) ---- */
    [DbFact]
    public async Task Arrival_inside_the_grace_is_not_late_and_costs_nothing()
    {
        var r = await RuleAsync(Day.AddHours(7).AddMinutes(8), Day.AddHours(16));

        Assert.Equal(0, r.LateMinutes);
        Assert.Equal(0, r.LateDeductMinutes);
        Assert.Equal(502, r.WorkedMinutes);
        Assert.Equal(8, r.CoveredMinutes);            // grace protects pay
        Assert.Equal(1.00m, r.DayFraction);
        Assert.True(r.IsFullDay);
    }

    [DbFact]
    public async Task Arrival_beyond_the_grace_is_late_by_the_whole_delay()
    {
        var r = await RuleAsync(Day.AddHours(7).AddMinutes(12), Day.AddHours(16));

        Assert.Equal(12, r.LateMinutes);              // 12, not 12 − 10
        Assert.Equal(2, r.LateDeductMinutes);         // BeyondGrace: only the minutes after the grace
        Assert.Equal(498, r.WorkedMinutes);
        Assert.Equal(10, r.CoveredMinutes);
        Assert.Equal(1.00m, r.DayFraction);           // 508 / 510 rounds to 1.00
        Assert.Equal(2, r.ShortfallMinutes);
    }

    /* ---- LateDeductMinutes follows the LateDeductionBasis setting ---- */
    [DbTheory]
    [InlineData("BeyondGrace", 2, 10, "1.00")]
    [InlineData("Full", 12, 0, "0.98")]
    [InlineData("None", 0, 12, "1.00")]
    public async Task Late_deduction_basis_decides_how_much_of_the_delay_is_deducted(string basis, int deduct, int covered, string fraction)
    {
        var r = await RuleAsync(Day.AddHours(7).AddMinutes(12), Day.AddHours(16), lateBasis: basis);

        Assert.Equal(12, r.LateMinutes);
        Assert.Equal(deduct, r.LateDeductMinutes);
        Assert.Equal(covered, r.CoveredMinutes);
        Assert.Equal(decimal.Parse(fraction, System.Globalization.CultureInfo.InvariantCulture), r.DayFraction);
    }

    /* ---- EarlyExitMinutes: leaving early IS an exit variance (BUG-12) ---- */
    [DbFact]
    public async Task Leaving_early_is_an_exit_variance()
    {
        var r = await RuleAsync(Day.AddHours(7), Day.AddHours(14).AddMinutes(45));

        Assert.Equal(75, r.EarlyExitMinutes);
        Assert.Equal(0, r.MidDayGapMinutes);
        Assert.Equal(75, r.ExitActualMinutes);
        Assert.Equal(75, r.ExitVarianceMinutes);       // nothing approved → queued
        Assert.Equal(435, r.WorkedMinutes);
        Assert.Equal(0, r.CoveredMinutes);
        Assert.Equal(0.85m, r.DayFraction);
        Assert.False(r.IsFullDay);
    }

    /* ---- MidDayGapMinutes = max(0, Σ gaps − Break) ---- */
    [DbFact]
    public async Task A_mid_day_gap_beyond_the_break_is_an_exit()
    {
        // out 10:00, in 11:15 (gap 75), out 16:00
        var r = await RuleAsync(Day.AddHours(7), Day.AddHours(16), gapMinutes: 75);

        Assert.Equal(45, r.MidDayGapMinutes);          // 75 − 30 absorbed by the break
        Assert.Equal(45, r.ExitActualMinutes);
        Assert.Equal(45, r.ExitVarianceMinutes);
        Assert.Equal(465, r.WorkedMinutes);            // 540 − 30 − 45
        Assert.Equal(0.91m, r.DayFraction);
    }

    /* ---- an approved permission protects pay and never reduces the worked time (BUG-11, BUG-13) ---- */
    [DbFact]
    public async Task An_approved_permission_covers_the_early_exit_without_reducing_the_worked_time()
    {
        var r = await RuleAsync(Day.AddHours(7), Day.AddHours(15).AddMinutes(5), exitApproved: 60);

        Assert.Equal(55, r.EarlyExitMinutes);
        Assert.Equal(55, r.ExitActualMinutes);
        Assert.Equal(60, r.ExitApprovedMinutes);
        Assert.Equal(-5, r.ExitVarianceMinutes);       // approved ≥ actual → nothing to queue
        Assert.Equal(455, r.WorkedMinutes);            // (15:05 − 07:00) − 30, not 455 − 60
        Assert.Equal(55, r.CoveredMinutes);            // min(actual, approved)
        Assert.Equal(1.00m, r.DayFraction);
    }

    [DbFact]
    public async Task An_approval_larger_than_the_gap_covers_only_the_gap()
    {
        var r = await RuleAsync(Day.AddHours(7), Day.AddHours(16), gapMinutes: 75, exitApproved: 60);

        Assert.Equal(45, r.ExitActualMinutes);
        Assert.Equal(-15, r.ExitVarianceMinutes);
        Assert.Equal(45, r.CoveredMinutes);
        Assert.Equal(465, r.WorkedMinutes);
        Assert.Equal(1.00m, r.DayFraction);
    }

    /* ---- HR's disposition: Ignore / Overtime cover the variance, UnpaidAbsence adds nothing (BUG-14) ---- */
    [DbTheory]
    [InlineData("Ignore", 75, "1.00")]
    [InlineData("Overtime", 75, "1.00")]
    [InlineData("UnpaidAbsence", 0, "0.85")]
    [InlineData(null, 0, "0.85")]
    public async Task The_disposition_decides_whether_an_undecided_variance_is_paid(string? disposition, int covered, string fraction)
    {
        var r = await RuleAsync(Day.AddHours(7), Day.AddHours(14).AddMinutes(45), disposition: disposition);

        Assert.Equal(75, r.ExitVarianceMinutes);       // the variance itself is a fact, not a decision
        Assert.Equal(435, r.WorkedMinutes);
        Assert.Equal(covered, r.CoveredMinutes);
        Assert.Equal(decimal.Parse(fraction, System.Globalization.CultureInfo.InvariantCulture), r.DayFraction);
    }

    /* ---- OvertimeMinutes = max(0, LastOut − ShiftEnd): post-shift only ---- */
    [DbFact]
    public async Task Staying_after_the_shift_is_overtime_and_does_not_inflate_the_worked_day()
    {
        var r = await RuleAsync(Day.AddHours(7), Day.AddHours(17));

        Assert.Equal(60, r.OvertimeMinutes);
        Assert.Equal(510, r.WorkedMinutes);
        Assert.Equal(ShiftEnd, r.EffectiveOutUtc);
        Assert.Equal(1.00m, r.DayFraction);
    }

    /* ---- Status: approved leave wins whatever the punches say (BUG-08, BUG-09) ---- */
    [DbFact]
    public async Task A_leave_day_with_a_punch_is_leave_with_no_fraction_and_no_variance()
    {
        var r = await RuleAsync(Day.AddHours(7), Day.AddHours(9), onLeave: true);

        Assert.Equal("Leave", r.Status);
        Assert.Null(r.DayFraction);
        Assert.False(r.IsFullDay);
        Assert.Equal(0, r.ExitActualMinutes);
        Assert.Equal(0, r.ExitVarianceMinutes);
        Assert.Equal(0, r.LateMinutes);
        Assert.Equal(0, r.ShortfallMinutes);
    }

    /* ---- Status: a rostered rest day is RestDay with no fraction (BUG-06 partner) ---- */
    [DbFact]
    public async Task A_rest_day_is_never_measured_even_when_punched()
    {
        var r = await RuleAsync(Day.AddHours(8), Day.AddHours(12), restDay: true, noShift: true, standard: 0);

        Assert.Equal("RestDay", r.Status);
        Assert.Null(r.DayFraction);
        Assert.Equal(0, r.StandardMinutes);
        Assert.Equal(0, r.ExitVarianceMinutes);
        Assert.Equal(0, r.OvertimeMinutes);
    }

    [DbFact]
    public async Task A_rest_day_without_punches_is_rest_day_not_absent()
    {
        var r = await RuleAsync(null, null, restDay: true, noShift: true, standard: 0);

        Assert.Equal("RestDay", r.Status);
        Assert.Null(r.DayFraction);
    }

    [DbFact]
    public async Task A_public_holiday_is_holiday_with_no_fraction()
    {
        var r = await RuleAsync(null, null, holiday: true);

        Assert.Equal("Holiday", r.Status);
        Assert.Null(r.DayFraction);
    }

    /* ---- Status: Present / Absent as today ---- */
    [DbFact]
    public async Task No_punches_on_a_working_day_is_absent_with_fraction_zero()
    {
        var r = await RuleAsync(null, null);

        Assert.Equal("Absent", r.Status);
        Assert.Equal(0.00m, r.DayFraction);
        Assert.Equal(0, r.WorkedMinutes);
        Assert.Equal(0, r.ExitVarianceMinutes);
        Assert.Equal(510, r.ShortfallMinutes);
        Assert.Equal(0, r.BreakApplied);
    }

    [DbFact]
    public async Task An_in_punch_without_an_out_is_present_with_nothing_worked_and_no_early_exit()
    {
        var r = await RuleAsync(Day.AddHours(7), null);

        Assert.Equal("Present", r.Status);
        Assert.Equal(0, r.WorkedMinutes);
        Assert.Equal(0, r.EarlyExitMinutes);          // no out-punch: an anomaly, not a variance
        Assert.Equal(0.00m, r.DayFraction);
    }

    /* ---- an overnight shift: the end is on the next day ---- */
    [DbFact]
    public async Task An_overnight_shift_is_measured_across_midnight()
    {
        var start = Day.AddHours(16);
        var end = Day.AddDays(1).AddHours(1);
        var r = await RuleAsync(Day.AddHours(16).AddMinutes(5), Day.AddDays(1).AddHours(1).AddMinutes(10), shiftStart: start, shiftEnd: end);

        Assert.Equal(0, r.LateMinutes);               // 5 inside the grace
        Assert.Equal(505, r.WorkedMinutes);           // 16:05–01:00 − 30
        Assert.Equal(5, r.CoveredMinutes);
        Assert.Equal(1.00m, r.DayFraction);
        Assert.Equal(10, r.OvertimeMinutes);
        Assert.Equal(0, r.EarlyExitMinutes);
    }

    /* ---- FullDayThreshold as today ---- */
    [DbTheory]
    [InlineData("1.00", false)]
    [InlineData("0.90", true)]
    public async Task IsFullDay_follows_the_full_day_threshold(string threshold, bool full)
    {
        var r = await RuleAsync(Day.AddHours(7), Day.AddHours(16), gapMinutes: 75,
            fullDayThreshold: decimal.Parse(threshold, System.Globalization.CultureInfo.InvariantCulture));

        Assert.Equal(0.91m, r.DayFraction);
        Assert.Equal(full, r.IsFullDay);
    }

    /* ---- no rostered shift: the default standard day, no late / early-exit rule ---- */
    [DbFact]
    public async Task Without_a_shift_the_day_is_measured_against_the_default_standard()
    {
        var r = await RuleAsync(Day.AddHours(9).AddMinutes(30), Day.AddHours(18), noShift: true, standard: 540);

        Assert.Equal("Present", r.Status);
        Assert.Equal(0, r.LateMinutes);
        Assert.Equal(0, r.EarlyExitMinutes);
        Assert.Equal(480, r.WorkedMinutes);           // 8h30 − 30
        Assert.Equal(0.89m, r.DayFraction);
    }
}

/// <summary>
/// A fact that runs only when the MokaCo_HRMS database with script 76 is reachable; otherwise it is
/// skipped with the reason. The connection string comes from MOKACO_TEST_CONNECTION, else from the
/// API project's appsettings.json (found by walking up from the test assembly).
/// </summary>
public sealed class DbFactAttribute : FactAttribute
{
    public DbFactAttribute()
    {
        if (SkipReason is not null) Skip = SkipReason;
    }

    private static readonly Lazy<(string? Connection, string? Reason)> Probe = new(ProbeDatabase);

    public static string ConnectionString => Probe.Value.Connection ?? throw new InvalidOperationException(Probe.Value.Reason);
    public static string? SkipReason => Probe.Value.Reason;

    private static (string?, string?) ProbeDatabase()
    {
        var cs = Environment.GetEnvironmentVariable("MOKACO_TEST_CONNECTION");
        if (string.IsNullOrWhiteSpace(cs))
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            string? file = null;
            for (var d = dir; d is not null && file is null; d = d.Parent)
            {
                var candidate = Path.Combine(d.FullName, "MokaCo.HRMS.API", "appsettings.json");
                if (File.Exists(candidate)) file = candidate;
            }
            if (file is null) return (null, "No MOKACO_TEST_CONNECTION and no MokaCo.HRMS.API/appsettings.json found.");

            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(file));
                cs = doc.RootElement.GetProperty("ConnectionStrings").GetProperty("MokaCo").GetString();
            }
            catch (Exception ex)
            {
                return (null, $"Could not read ConnectionStrings:MokaCo from {file}: {ex.Message}");
            }
        }
        if (string.IsNullOrWhiteSpace(cs)) return (null, "Empty connection string.");

        try
        {
            var b = new SqlConnectionStringBuilder(cs) { ConnectTimeout = 3 };
            using var db = new SqlConnection(b.ConnectionString);
            db.Open();
            var exists = db.ExecuteScalar<int?>("SELECT OBJECT_ID('attendance.fn_AttendanceDayRule')");
            return exists is null
                ? (null, "attendance.fn_AttendanceDayRule is missing: apply docs/76_attendance_single_day_rule.sql.")
                : (b.ConnectionString, null);
        }
        catch (Exception ex)
        {
            return (null, $"Database not reachable: {ex.Message}");
        }
    }
}

public sealed class DbTheoryAttribute : TheoryAttribute
{
    public DbTheoryAttribute()
    {
        if (DbFactAttribute.SkipReason is not null) Skip = DbFactAttribute.SkipReason;
    }
}
