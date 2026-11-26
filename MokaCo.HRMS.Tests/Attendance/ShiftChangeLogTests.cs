using Dapper;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Tests.Attendance;

/// <summary>
/// Script 122 (docs/122_shift_change_log.sql) with the API's own way of saying who is calling
/// (<see cref="SessionCaller"/>, which ShiftRepository runs before every shift write): the change log written by the
/// triggers names that person, and usp_Shift_GetChanges reads back into <see cref="ShiftChange"/> newest first.
/// Everything happens INSIDE A TRANSACTION THAT IS ROLLED BACK. Skipped when no database is reachable.
/// </summary>
[Collection(DatabaseCollection.Name)]
public class ShiftChangeLogTests
{
    private sealed class Fixture : IAsyncDisposable
    {
        public SqlConnection Db { get; }
        public SqlTransaction Tx { get; private set; } = null!;
        public int UserId { get; private set; }

        private Fixture(SqlConnection db) => Db = db;

        /// <summary>The caller is put on the session BEFORE the transaction starts, exactly as the repository does it.</summary>
        public static async Task<Fixture> OpenAsync(bool withCaller = true)
        {
            var f = new Fixture(new SqlConnection(DbFactAttribute.ConnectionString));
            await f.Db.OpenAsync();
            f.UserId = await f.Db.ExecuteScalarAsync<int>("SELECT TOP 1 UserId FROM security.[USER] ORDER BY UserId");
            await SessionCaller.SetAsync(f.Db, withCaller ? f.UserId : null);
            f.Tx = f.Db.BeginTransaction();
            return f;
        }

        public Task<int> CreateShiftAsync(string name) => Db.ExecuteScalarAsync<int>(
            "attendance.usp_Shift_Create",
            new { Name = name, StartTime = new TimeSpan(8, 0, 0), EndTime = new TimeSpan(16, 0, 0), GraceMinutes = (int?)null,
                  CrossesMidnight = false, BreakMinutes = 30, CallerUserId = (int?)null },
            Tx, commandType: System.Data.CommandType.StoredProcedure);

        /// <summary>usp_Shift_Update the way ShiftRepository.UpdateAsync calls it: the change's dates on the session first.</summary>
        public async Task UpdateAsync(int shiftId, string name, TimeSpan start, TimeSpan end, bool isActive, DateOnly? from = null, DateOnly? to = null)
        {
            await ShiftRepository.SetHoursPeriodAsync(Db, from, to, Tx);
            await Db.ExecuteAsync(
                "attendance.usp_Shift_Update",
                new { ShiftId = shiftId, Name = name, StartTime = start, EndTime = end, GraceMinutes = (int?)null, CrossesMidnight = false,
                      BreakMinutes = 30, IsActive = isActive, EffectiveFrom = AsDate(from), EffectiveTo = AsDate(to), Note = "ZZ test",
                      CallerUserId = (int?)null },
                Tx, commandType: System.Data.CommandType.StoredProcedure, commandTimeout: 300);
        }

        private static DateTime? AsDate(DateOnly? d) => d?.ToDateTime(TimeOnly.MinValue);

        public async Task<List<ShiftChange>> ChangesAsync(int shiftId) => (await Db.QueryAsync<ShiftChange>(
            "attendance.usp_Shift_GetChanges", new { ShiftId = shiftId }, Tx, commandType: System.Data.CommandType.StoredProcedure)).ToList();

        public async ValueTask DisposeAsync()
        {
            try { await Tx.RollbackAsync(); } catch (InvalidOperationException) { /* already finished */ }
            await Db.DisposeAsync();
        }
    }

    [DbFact]
    public async Task Every_change_names_the_caller_the_api_put_on_the_session_newest_first()
    {
        await using var f = await Fixture.OpenAsync();
        // No @CallerUserId anywhere: who made the change comes from the session alone.
        var shiftId = await f.CreateShiftAsync("ZZ Log 08-16");
        await f.UpdateAsync(shiftId, "ZZ Log Morning", new TimeSpan(8, 0, 0), new TimeSpan(16, 0, 0), isActive: false);
        await f.UpdateAsync(shiftId, "ZZ Log Morning", new TimeSpan(9, 0, 0), new TimeSpan(17, 0, 0), isActive: false, from: new DateOnly(2026, 12, 1));

        var log = await f.ChangesAsync(shiftId);

        Assert.Equal(["HoursChanged", "Deactivated", "Renamed", "Created"], log.Select(c => c.Action));
        Assert.All(log, c => Assert.Equal(f.UserId, c.ChangedByUserId));
        Assert.All(log, c => Assert.False(string.IsNullOrEmpty(c.ChangedBy)));

        var hours = log[0];
        Assert.Equal(new DateTime(2026, 12, 1), hours.EffectiveFrom);
        Assert.Null(hours.EffectiveTo);
        Assert.Equal((new TimeSpan(8, 0, 0), new TimeSpan(16, 0, 0)), (hours.OldStartTime, hours.OldEndTime));
        Assert.Equal((new TimeSpan(9, 0, 0), new TimeSpan(17, 0, 0)), (hours.NewStartTime, hours.NewEndTime));
        Assert.Equal((30, 30), (hours.OldBreakMinutes, hours.NewBreakMinutes));
        Assert.Equal("ZZ test", hours.Note);

        var renamed = log[2];
        Assert.Equal(("ZZ Log 08-16", "ZZ Log Morning"), (renamed.OldName, renamed.NewName));
        Assert.Null(renamed.EffectiveFrom);

        var created = log[3];
        Assert.Equal("ZZ Log 08-16", created.NewName);
        Assert.Null(created.OldStartTime);
        Assert.Equal(new TimeSpan(8, 0, 0), created.NewStartTime);
    }

    [DbFact]
    public async Task A_caller_set_to_nobody_leaves_no_name_behind_on_the_session()
    {
        await using var f = await Fixture.OpenAsync();
        Assert.Equal(f.UserId, await f.Db.ExecuteScalarAsync<int?>("SELECT TRY_CONVERT(INT, SESSION_CONTEXT(N'UserId'))", transaction: f.Tx));

        // The repository always writes the value, NULL included, so an earlier caller never carries over.
        await SessionCaller.SetAsync(f.Db, null, f.Tx);
        Assert.Null(await f.Db.ExecuteScalarAsync<int?>("SELECT TRY_CONVERT(INT, SESSION_CONTEXT(N'UserId'))", transaction: f.Tx));

        var shiftId = await f.CreateShiftAsync("ZZ Log nobody");
        await f.UpdateAsync(shiftId, "ZZ Log nobody (old)", new TimeSpan(8, 0, 0), new TimeSpan(16, 0, 0), isActive: true);
        var renamed = (await f.ChangesAsync(shiftId)).First(c => c.Action == ShiftChange.Actions.Renamed);
        Assert.Null(renamed.ChangedByUserId);
        Assert.Null(renamed.ChangedBy);
    }

    /// <summary>
    /// A change for a period: usp_Shift_SetHours writes the period's hours BEFORE the "back to the hours before"
    /// version on the day after it, so the trigger takes the period's last day from the session (ShiftRepository puts
    /// the request's dates there), not from the versions recorded at that moment.
    /// </summary>
    [DbFact]
    public async Task A_change_for_a_period_is_logged_with_the_last_day_the_person_chose()
    {
        await using var f = await Fixture.OpenAsync();
        var morning = (new TimeSpan(8, 0, 0), new TimeSpan(16, 0, 0));
        var summer = (new TimeSpan(10, 0, 0), new TimeSpan(18, 0, 0));
        var ramadan = (new TimeSpan(9, 0, 0), new TimeSpan(17, 0, 0));

        // No later change recorded: the period still ends on the day typed (not open-ended).
        var alone = await f.CreateShiftAsync("ZZ Log period alone");
        await f.UpdateAsync(alone, "ZZ Log period alone", ramadan.Item1, ramadan.Item2, true, new DateOnly(2026, 12, 1), new DateOnly(2026, 12, 31));
        var aloneLog = await f.ChangesAsync(alone);
        var aloneRow = aloneLog.Single(c => c.EffectiveFrom == new DateTime(2026, 12, 1));
        Assert.Equal(new DateTime(2026, 12, 31), aloneRow.EffectiveTo);
        Assert.Equal((morning.Item1, ramadan.Item1), (aloneRow.OldStartTime, aloneRow.NewStartTime));
        var aloneBack = aloneLog.Single(c => c.EffectiveFrom == new DateTime(2027, 1, 1));
        Assert.Null(aloneBack.EffectiveTo);
        Assert.Equal((ramadan.Item1, morning.Item1), (aloneBack.OldStartTime, aloneBack.NewStartTime));

        // Summer hours already recorded from 1 Mar 2027: the period does not run on until the day before them.
        var shiftId = await f.CreateShiftAsync("ZZ Log period");
        await f.UpdateAsync(shiftId, "ZZ Log period", summer.Item1, summer.Item2, true, new DateOnly(2027, 3, 1));
        await f.UpdateAsync(shiftId, "ZZ Log period", ramadan.Item1, ramadan.Item2, true, new DateOnly(2026, 12, 1), new DateOnly(2026, 12, 31));
        var log = await f.ChangesAsync(shiftId);
        Assert.Null(log.Single(c => c.EffectiveFrom == new DateTime(2027, 3, 1)).EffectiveTo);
        var period = log.Single(c => c.EffectiveFrom == new DateTime(2026, 12, 1));
        Assert.Equal(new DateTime(2026, 12, 31), period.EffectiveTo);
        var back = log.Single(c => c.EffectiveFrom == new DateTime(2027, 1, 1));
        Assert.Equal(new DateTime(2027, 2, 28), back.EffectiveTo);

        // The same period entered again with an earlier end overwrites the version: its row ends on the new last day.
        await f.UpdateAsync(shiftId, "ZZ Log period", new TimeSpan(9, 30, 0), new TimeSpan(17, 30, 0), true, new DateOnly(2026, 12, 1), new DateOnly(2026, 12, 15));
        var again = (await f.ChangesAsync(shiftId)).First(c => c.EffectiveFrom == new DateTime(2026, 12, 1));
        Assert.Equal((ramadan.Item1, new TimeSpan(9, 30, 0)), (again.OldStartTime, again.NewStartTime));
        Assert.Equal(new DateTime(2026, 12, 15), again.EffectiveTo);

        // No first day given: the hours start today (usp_Shift_Update's rule) and end on the day typed.
        var today = await f.Db.ExecuteScalarAsync<DateTime>(
            "SELECT CAST(CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE) AS DATETIME)", transaction: f.Tx);
        var fresh = await f.CreateShiftAsync("ZZ Log period today");
        await f.UpdateAsync(fresh, "ZZ Log period today", ramadan.Item1, ramadan.Item2, true, null, DateOnly.FromDateTime(today.AddDays(9)));
        var todayRow = (await f.ChangesAsync(fresh)).Single(c => c.Action == ShiftChange.Actions.HoursChanged && c.EffectiveFrom == today);
        Assert.Equal(today.AddDays(9), todayRow.EffectiveTo);
    }

    [DbFact]
    public async Task The_nightly_sync_and_a_save_that_changes_nothing_write_nothing()
    {
        await using var f = await Fixture.OpenAsync();
        var shiftId = await f.CreateShiftAsync("ZZ Log quiet");
        await f.Db.ExecuteAsync("attendance.usp_Shift_SyncCurrent", new { Quiet = true }, f.Tx, commandType: System.Data.CommandType.StoredProcedure);
        await f.UpdateAsync(shiftId, "ZZ Log quiet", new TimeSpan(8, 0, 0), new TimeSpan(16, 0, 0), isActive: true);

        Assert.Equal(["Created"], (await f.ChangesAsync(shiftId)).Select(c => c.Action));
    }
}
