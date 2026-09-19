using Dapper;
using Microsoft.Data.SqlClient;

namespace MokaCo.HRMS.Tests.Attendance;

/// <summary>
/// THE WRITERS of script 77 (docs/77_attendance_tolerance_anomalies.sql): usp_Attendance_ComputeDay,
/// usp_Attendance_ManualUpsert, usp_Anomaly_Decide, usp_Anomaly_DecideAll and the readiness gate,
/// against the database the API uses. Each test seeds a throw-away branch, employee, shift, roster
/// and device INSIDE A TRANSACTION THAT IS ROLLED BACK, so nothing is left behind and no real
/// employee is touched. The shift is the brief's: 07:00–15:00, no break, tolerance from the setting.
/// Skipped, with the reason, when the database is not reachable or script 77 is not applied.
/// </summary>
public class AttendanceAnomalyTests
{
    private static readonly DateTime Day = new(2026, 8, 3);

    private sealed record Anomaly(long AnomalyId, string Type, int Minutes, DateTime? ShiftStartUtc, DateTime? ShiftEndUtc,
        DateTime? PunchInUtc, DateTime? PunchOutUtc, string? Decision, string? Note);
    private sealed record Record(long AttendanceId, string Status, int WorkedMinutes, int CoveredMinutes, decimal? DayFraction,
        int LateMinutes, int LateDeductMinutes, int EarlyExitMinutes, int EarlyDeductMinutes, int ExitActualMinutes,
        int ExitVarianceMinutes, bool IsManual, bool HasAnomaly, int UndecidedAnomalies);
    /// <summary>A class, not a record: the procedure returns more columns than these and Dapper maps by property name.</summary>
    private sealed class Readiness
    {
        public int OpenAnomalies { get; set; }
        public int UndecidedExitVariances { get; set; }
        public int UndecidedAnomalies { get; set; }
        public bool IsReady { get; set; }
    }

    /// <summary>One transaction, one throw-away employee. Disposing rolls everything back.</summary>
    private sealed class Fixture : IAsyncDisposable
    {
        public SqlConnection Db { get; }
        public SqlTransaction Tx { get; }
        public int EmployeeId { get; private set; }
        public int DeviceId { get; private set; }
        public int BranchId { get; private set; }

        private Fixture(SqlConnection db, SqlTransaction tx) { Db = db; Tx = tx; }

        public static async Task<Fixture> OpenAsync()
        {
            var db = new SqlConnection(DbFactAttribute.ConnectionString);
            await db.OpenAsync();
            var tx = db.BeginTransaction();
            var f = new Fixture(db, tx);
            var ids = await db.QuerySingleAsync<(int EmployeeId, int DeviceId, int BranchId)>(
                """
                INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'ZZ Tolerance Test Branch', 1);
                DECLARE @B INT = SCOPE_IDENTITY();
                DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
                DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId);
                INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, ApprovalTier, PreferredLanguage)
                VALUES (@B, @Dep, @Pos, N'ZZ Tolerance Test', '2024-01-01', 5, 'en');
                DECLARE @E INT = SCOPE_IDENTITY();
                INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
                VALUES (N'ZZ 07-15', '07:00', '15:00', NULL, 0, 0, 1);
                DECLARE @S INT = SCOPE_IDENTITY();
                INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
                VALUES (@E, @S, '2026-08-03', 0), (@E, @S, '2026-08-04', 0), (@E, @S, '2026-08-05', 0), (@E, @S, '2026-08-06', 0);
                INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status]) VALUES (@B, '2026-08-01', 'Approved');
                INSERT INTO attendance.DEVICE (SerialNumber, BranchId, IsActive, [Name]) VALUES ('ZZ-TEST-DEV', @B, 1, N'ZZ test');
                SELECT @E AS EmployeeId, CAST(SCOPE_IDENTITY() AS INT) AS DeviceId, @B AS BranchId;
                """, transaction: tx);
            (f.EmployeeId, f.DeviceId, f.BranchId) = ids;
            return f;
        }

        public Task PunchAsync(DateTime at, bool isOut) => Db.ExecuteAsync(
            """
            INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
            VALUES (@DeviceId, 'ZZ1', @EmployeeId, @At, @Type, 'Test', CONVERT(VARCHAR(64), NEWID()))
            """, new { DeviceId, EmployeeId, At = at, Type = (short)(isOut ? 1 : 0) }, Tx);

        public Task RemovePunchAsync(DateTime at) => Db.ExecuteAsync(
            "DELETE FROM attendance.RAW_DEVICE_LOG WHERE EmployeeId = @EmployeeId AND PunchTimeUtc = @At", new { EmployeeId, At = at }, Tx);

        public Task ComputeAsync(DateTime date) => Db.ExecuteAsync(
            "attendance.usp_Attendance_ComputeDay", new { EmployeeId, WorkDate = date.Date }, Tx, commandType: System.Data.CommandType.StoredProcedure);

        public Task ReprocessAsync(DateTime date) => Db.ExecuteAsync(
            "attendance.usp_Attendance_ReprocessDay", new { WorkDate = date.Date, EmployeeId, Quiet = true }, Tx, commandType: System.Data.CommandType.StoredProcedure);

        public Task ManualAsync(DateTime date, DateTime? firstIn, DateTime? lastOut) => Db.ExecuteAsync(
            "attendance.usp_Attendance_ManualUpsert",
            new { EmployeeId, WorkDate = date.Date, FirstInUtc = firstIn, LastOutUtc = lastOut, ExitMinutes = 0, ExitApprovedMins = 0, HrNote = "test" },
            Tx, commandType: System.Data.CommandType.StoredProcedure);

        public Task SetToleranceAsync(int minutes) => Db.ExecuteAsync(
            "UPDATE core.SETTING SET SettingValue = @V WHERE SettingKey = 'AttendanceToleranceMinutes'", new { V = minutes.ToString() }, Tx);

        public Task<Record> RecordAsync(DateTime date) => Db.QuerySingleAsync<Record>(
            """
            SELECT a.AttendanceId, a.[Status], a.WorkedMinutes, a.CoveredMinutes, a.DayFraction, a.LateMinutes, a.LateDeductMinutes,
                   a.EarlyExitMinutes, a.EarlyDeductMinutes, a.ExitActualMinutes, a.ExitVarianceMinutes, a.IsManual, a.HasAnomaly,
                   (SELECT COUNT(*) FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId AND an.Decision IS NULL) AS UndecidedAnomalies
            FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @EmployeeId AND a.WorkDate = @D
            """, new { EmployeeId, D = date.Date }, Tx);

        public async Task<List<Anomaly>> AnomaliesAsync(DateTime date) => (await Db.QueryAsync<Anomaly>(
            """
            SELECT AnomalyId, [Type], [Minutes], ShiftStartUtc, ShiftEndUtc, PunchInUtc, PunchOutUtc, Decision, Note
            FROM attendance.ATTENDANCE_ANOMALY WHERE EmployeeId = @EmployeeId AND WorkDate = @D ORDER BY [Type]
            """, new { EmployeeId, D = date.Date }, Tx)).ToList();

        public Task DecideAsync(long anomalyId, string decision, DateTime? correctedTime = null, string? note = null) => Db.ExecuteAsync(
            "attendance.usp_Anomaly_Decide",
            new { AnomalyId = anomalyId, Decision = decision, CorrectedTimeUtc = correctedTime, Note = note, DecidedByUserId = (int?)null },
            Tx, commandType: System.Data.CommandType.StoredProcedure);

        public Task<Readiness> ReadinessAsync() => Db.QuerySingleAsync<Readiness>(
            "attendance.usp_Attendance_PayrollReadiness", new { PeriodYearMonth = "2026-08" }, Tx, commandType: System.Data.CommandType.StoredProcedure);

        public async ValueTask DisposeAsync()
        {
            try { await Tx.RollbackAsync(); } catch { /* already rolled back by an aborted batch */ }
            await Db.DisposeAsync();
        }
    }

    private static async Task<Fixture> ExampleDayAsync()
    {
        var f = await Fixture.OpenAsync();
        await f.PunchAsync(Day.AddHours(7).AddMinutes(10), isOut: false);
        await f.PunchAsync(Day.AddHours(14).AddMinutes(50), isOut: true);
        await f.ComputeAsync(Day);
        return f;
    }

    /* ---- the brief: 07:00–15:00, in 07:10 / out 14:50, tolerance 10 → two anomalies, full pay until decided ---- */
    [DbFact]
    public async Task Ten_late_and_ten_early_create_two_undecided_anomalies_with_full_pay()
    {
        await using var f = await ExampleDayAsync();

        var anomalies = await f.AnomaliesAsync(Day);
        var r = await f.RecordAsync(Day);

        Assert.Equal(2, anomalies.Count);
        var early = Assert.Single(anomalies, a => a.Type == "EarlyDeparture");
        var late = Assert.Single(anomalies, a => a.Type == "LateArrival");
        Assert.Equal(10, late.Minutes);
        Assert.Equal(10, early.Minutes);
        Assert.Null(late.Decision);
        Assert.Null(early.Decision);
        Assert.Equal(Day.AddHours(7), late.ShiftStartUtc);
        Assert.Equal(Day.AddHours(15), late.ShiftEndUtc);
        Assert.Equal(Day.AddHours(7).AddMinutes(10), late.PunchInUtc);
        Assert.Equal(Day.AddHours(14).AddMinutes(50), late.PunchOutUtc);

        Assert.Equal(460, r.WorkedMinutes);
        Assert.Equal(20, r.CoveredMinutes);
        Assert.Equal(1.00m, r.DayFraction);            // covered until decided
        Assert.Equal(0, r.ExitVarianceMinutes);        // not an exit variance
        Assert.Equal(2, r.UndecidedAnomalies);
    }

    [DbFact]
    public async Task Nine_minutes_late_creates_nothing()
    {
        await using var f = await Fixture.OpenAsync();
        await f.PunchAsync(Day.AddHours(7).AddMinutes(9), isOut: false);
        await f.PunchAsync(Day.AddHours(15), isOut: true);
        await f.ComputeAsync(Day);

        Assert.Empty(await f.AnomaliesAsync(Day));
        var r = await f.RecordAsync(Day);
        Assert.Equal(0, r.LateMinutes);
        Assert.Equal(1.00m, r.DayFraction);
    }

    [DbFact]
    public async Task Deduct_on_both_takes_twenty_minutes_off_the_day_and_survives_a_reprocess()
    {
        await using var f = await ExampleDayAsync();
        foreach (var a in await f.AnomaliesAsync(Day)) await f.DecideAsync(a.AnomalyId, "Deduct", note: "test deduct");

        var r = await f.RecordAsync(Day);
        Assert.Equal(10, r.LateDeductMinutes);
        Assert.Equal(10, r.EarlyDeductMinutes);
        Assert.Equal(0, r.CoveredMinutes);
        Assert.Equal(0.96m, r.DayFraction);            // 460 / 480
        Assert.All(await f.AnomaliesAsync(Day), a => Assert.Equal("Deducted", a.Decision));

        await f.ReprocessAsync(Day);                    // re-processing never wipes a decision
        r = await f.RecordAsync(Day);
        Assert.Equal(0.96m, r.DayFraction);
        Assert.All(await f.AnomaliesAsync(Day), a => Assert.Equal("Deducted", a.Decision));
        Assert.Equal(0, r.UndecidedAnomalies);
    }

    [DbFact]
    public async Task Excuse_keeps_full_pay()
    {
        await using var f = await ExampleDayAsync();
        foreach (var a in await f.AnomaliesAsync(Day)) await f.DecideAsync(a.AnomalyId, "Excuse");

        var r = await f.RecordAsync(Day);
        Assert.Equal(20, r.CoveredMinutes);
        Assert.Equal(1.00m, r.DayFraction);
        Assert.All(await f.AnomaliesAsync(Day), a => Assert.Equal("Excused", a.Decision));
    }

    [DbFact]
    public async Task A_decision_can_be_changed_until_the_day_is_corrected()
    {
        await using var f = await ExampleDayAsync();
        var late = (await f.AnomaliesAsync(Day)).Single(a => a.Type == "LateArrival");
        await f.DecideAsync(late.AnomalyId, "Excuse");
        await f.DecideAsync(late.AnomalyId, "Deduct");

        var r = await f.RecordAsync(Day);
        Assert.Equal(10, r.LateDeductMinutes);
        Assert.Equal(0, r.EarlyDeductMinutes);         // the other anomaly is still undecided → covered
        Assert.Equal(0.98m, r.DayFraction);            // 470 / 480
    }

    [DbFact]
    public async Task Raising_the_tolerance_to_fifteen_and_reprocessing_leaves_nothing_for_that_day()
    {
        await using var f = await ExampleDayAsync();
        Assert.Equal(2, (await f.AnomaliesAsync(Day)).Count);

        await f.SetToleranceAsync(15);
        await f.ReprocessAsync(Day);

        Assert.Empty(await f.AnomaliesAsync(Day));
        var r = await f.RecordAsync(Day);
        Assert.Equal(0, r.LateMinutes);
        Assert.Equal(0, r.EarlyExitMinutes);
        Assert.Equal(20, r.CoveredMinutes);            // on time: the minutes are simply covered
        Assert.Equal(1.00m, r.DayFraction);
    }

    /* A decision answers a FACT (script 83, QA2 A1j / A1k). The same punches reprocessed keep it; a punch that
       CHANGED after the decision — the machine re-sends the day, HR corrects a time — withdraws it with a note,
       and HR decides the anomaly as it now stands. (Until script 83 the decision survived a changed punch.) */
    [DbFact]
    public async Task Reprocessing_the_same_punches_keeps_the_decision()
    {
        await using var f = await ExampleDayAsync();
        var late = (await f.AnomaliesAsync(Day)).Single(a => a.Type == "LateArrival");
        await f.DecideAsync(late.AnomalyId, "Deduct");

        await f.ReprocessAsync(Day);

        var again = (await f.AnomaliesAsync(Day)).Single(a => a.Type == "LateArrival");
        Assert.Equal(late.AnomalyId, again.AnomalyId);
        Assert.Equal("Deducted", again.Decision);
        Assert.Equal(late.Minutes, (await f.RecordAsync(Day)).LateDeductMinutes);
    }

    [DbFact]
    public async Task A_punch_that_changes_after_the_decision_withdraws_it()
    {
        await using var f = await ExampleDayAsync();
        var late = (await f.AnomaliesAsync(Day)).Single(a => a.Type == "LateArrival");
        await f.DecideAsync(late.AnomalyId, "Deduct");

        // the machine re-sends the day with the arrival two minutes later
        await f.RemovePunchAsync(Day.AddHours(7).AddMinutes(10));
        await f.PunchAsync(Day.AddHours(7).AddMinutes(12), isOut: false);
        await f.ReprocessAsync(Day);

        var again = (await f.AnomaliesAsync(Day)).Single(a => a.Type == "LateArrival");
        Assert.Equal(late.AnomalyId, again.AnomalyId);  // the same row
        Assert.Equal(12, again.Minutes);
        Assert.Null(again.Decision);                    // decided about 07:10; the punch is 07:12 now
        Assert.Equal(Day.AddHours(7).AddMinutes(12), again.PunchInUtc);
        var r = await f.RecordAsync(Day);
        Assert.Equal(0, r.LateDeductMinutes);           // nothing is deducted on a withdrawn decision
    }

    /* ---- manually entered attendance follows the same rule ---- */
    [DbFact]
    public async Task A_manual_entry_is_measured_by_the_same_rule_and_its_anomalies_can_be_deducted()
    {
        await using var f = await Fixture.OpenAsync();
        var day = Day.AddDays(1);
        await f.ManualAsync(day, day.AddHours(7).AddMinutes(10), day.AddHours(14).AddMinutes(50));

        var anomalies = await f.AnomaliesAsync(day);
        Assert.Equal(2, anomalies.Count);
        var r = await f.RecordAsync(day);
        Assert.True(r.IsManual);
        Assert.Equal(460, r.WorkedMinutes);
        Assert.Equal(1.00m, r.DayFraction);

        foreach (var a in anomalies) await f.DecideAsync(a.AnomalyId, "Deduct");
        r = await f.RecordAsync(day);
        Assert.True(r.IsManual);
        Assert.Equal(0.96m, r.DayFraction);

        await f.ManualAsync(day, day.AddHours(7).AddMinutes(9), day.AddHours(15));   // HR re-enters the day on time
        Assert.Empty(await f.AnomaliesAsync(day));
        Assert.Equal(1.00m, (await f.RecordAsync(day)).DayFraction);
    }

    /* ---- Correct: the corrected punch is stored through the manual path and the day recomputed ---- */
    [DbFact]
    public async Task Correct_stores_the_punch_through_the_manual_path()
    {
        await using var f = await ExampleDayAsync();
        var early = (await f.AnomaliesAsync(Day)).Single(a => a.Type == "EarlyDeparture");
        await f.DecideAsync(early.AnomalyId, "Correct", correctedTime: Day.AddHours(15), note: "left at 15:00, forgot to punch");

        var r = await f.RecordAsync(Day);
        Assert.True(r.IsManual);
        Assert.Equal(470, r.WorkedMinutes);            // 07:10–15:00
        Assert.Equal(0, r.EarlyExitMinutes);
        Assert.Equal(10, r.LateMinutes);               // the late arrival is still there to decide
        Assert.Equal(1.00m, r.DayFraction);
        var anomalies = await f.AnomaliesAsync(Day);
        Assert.Equal("Corrected", anomalies.Single(a => a.Type == "EarlyDeparture").Decision);
        Assert.Null(anomalies.Single(a => a.Type == "LateArrival").Decision);

        await f.ReprocessAsync(Day);                    // a manual day is never re-derived from the punches
        Assert.True((await f.RecordAsync(Day)).IsManual);
        Assert.Equal(470, (await f.RecordAsync(Day)).WorkedMinutes);
    }

    /* ---- the existing kind: a missing punch is a MissingPunch anomaly that can only be corrected ---- */
    [DbFact]
    public async Task A_missing_out_punch_is_a_MissingPunch_anomaly_that_only_a_correction_resolves()
    {
        await using var f = await Fixture.OpenAsync();
        var day = Day.AddDays(2);
        await f.PunchAsync(day.AddHours(7), isOut: false);
        await f.ComputeAsync(day);

        var missing = Assert.Single(await f.AnomaliesAsync(day));
        Assert.Equal("MissingPunch", missing.Type);
        Assert.Equal(0, missing.Minutes);
        Assert.Null(missing.PunchOutUtc);
        Assert.True((await f.RecordAsync(day)).HasAnomaly);

        var refused = await Assert.ThrowsAsync<SqlException>(() => f.DecideAsync(missing.AnomalyId, "Excuse"));
        Assert.Contains("missing punch", refused.Message, StringComparison.OrdinalIgnoreCase);

        await f.DecideAsync(missing.AnomalyId, "Correct", correctedTime: day.AddHours(15));
        var r = await f.RecordAsync(day);
        Assert.True(r.IsManual);
        Assert.False(r.HasAnomaly);
        Assert.Equal(480, r.WorkedMinutes);
        Assert.Equal(1.00m, r.DayFraction);
        Assert.Equal("Corrected", Assert.Single(await f.AnomaliesAsync(day)).Decision);
    }

    /* ---- payroll readiness counts the undecided rows and refuses while any remain ---- */
    [DbFact]
    public async Task Undecided_anomalies_block_payroll_readiness_until_decided()
    {
        await using var f = await Fixture.OpenAsync();
        var before = await f.ReadinessAsync();
        await f.PunchAsync(Day.AddHours(7).AddMinutes(10), isOut: false);
        await f.PunchAsync(Day.AddHours(14).AddMinutes(50), isOut: true);
        await f.ComputeAsync(Day);

        var open = await f.ReadinessAsync();
        Assert.Equal(before.UndecidedAnomalies + 2, open.UndecidedAnomalies);
        Assert.False(open.IsReady);

        foreach (var a in await f.AnomaliesAsync(Day)) await f.DecideAsync(a.AnomalyId, "Excuse");
        var after = await f.ReadinessAsync();
        Assert.Equal(before.UndecidedAnomalies, after.UndecidedAnomalies);
    }

    /* ---- decide-all: the undecided rows of the month, one branch, missing punches skipped ---- */
    [DbFact]
    public async Task Decide_all_excuses_the_branch_month_and_skips_missing_punches()
    {
        await using var f = await ExampleDayAsync();
        await f.PunchAsync(Day.AddDays(3).AddHours(7).AddMinutes(20), isOut: false);
        await f.PunchAsync(Day.AddDays(3).AddHours(15), isOut: true);
        await f.ComputeAsync(Day.AddDays(3));
        await f.PunchAsync(Day.AddDays(2).AddHours(7), isOut: false);       // in only → MissingPunch
        await f.ComputeAsync(Day.AddDays(2));

        var othersBefore = await f.Db.ExecuteScalarAsync<int>(
            "SELECT COUNT(*) FROM attendance.ATTENDANCE_ANOMALY WHERE Decision IS NULL AND EmployeeId <> @E", new { E = f.EmployeeId }, f.Tx);

        var result = await f.Db.QuerySingleAsync<(int Decided, int Skipped, int DaysRecomputed)>(
            "attendance.usp_Anomaly_DecideAll",
            new { PeriodYearMonth = "2026-08", Decision = "Excuse", BranchId = f.BranchId, Note = "month end", DecidedByUserId = (int?)null },
            f.Tx, commandType: System.Data.CommandType.StoredProcedure);

        Assert.Equal(3, result.Decided);                // 2 on the 3rd, 1 on the 6th
        Assert.Equal(1, result.Skipped);                // the missing punch on the 5th
        Assert.Equal(2, result.DaysRecomputed);
        Assert.All(await f.AnomaliesAsync(Day), a => Assert.Equal("Excused", a.Decision));
        Assert.Null(Assert.Single(await f.AnomaliesAsync(Day.AddDays(2))).Decision);
        var othersAfter = await f.Db.ExecuteScalarAsync<int>(
            "SELECT COUNT(*) FROM attendance.ATTENDANCE_ANOMALY WHERE Decision IS NULL AND EmployeeId <> @E", new { E = f.EmployeeId }, f.Tx);
        Assert.Equal(othersBefore, othersAfter);        // other branches untouched
    }
}
