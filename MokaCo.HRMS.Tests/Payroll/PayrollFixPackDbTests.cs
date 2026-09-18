using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Tests.Attendance;

namespace MokaCo.HRMS.Tests.Payroll;

/// <summary>
/// THE WRITERS of script 78 (docs/78_payroll_rest_days_rate_precision.sql) against the database the
/// API uses: fn_RunRate / fn_ToPrimary at DECIMAL(28,12) (BUG-07), usp_PayrollRun_Create with a NULL
/// run type (BUG-18), and section D of usp_PayrollRun_Generate (BUG-06). Every test runs INSIDE A
/// TRANSACTION THAT IS ROLLED BACK: the throw-away run, employee and records never persist and no real
/// run is touched. Periods in 2099 are used so the "one live primary per period" index and the real
/// August 2026 run are never in the way. Skipped, with the reason, when the database is not reachable.
/// </summary>
public class PayrollFixPackDbTests
{
    private sealed class Fixture : IAsyncDisposable
    {
        public SqlConnection Db { get; }
        public SqlTransaction Tx { get; }
        private Fixture(SqlConnection db, SqlTransaction tx) { Db = db; Tx = tx; }

        public static async Task<Fixture> OpenAsync()
        {
            var db = new SqlConnection(DbFactAttribute.ConnectionString);
            await db.OpenAsync();
            return new Fixture(db, db.BeginTransaction());
        }

        /// <summary>Any user who may prepare a run (HR or Admin), or null when the database has none.</summary>
        public Task<int?> HrUserAsync() => Db.QuerySingleOrDefaultAsync<int?>(
            """
            SELECT TOP 1 u.UserId FROM security.[USER] u
            WHERE payroll.fn_UserHasRole(u.UserId, N'HR') = 1 OR payroll.fn_UserHasRole(u.UserId, N'Admin') = 1
            ORDER BY u.UserId
            """, transaction: Tx);

        /// <summary>
        /// A Draft run for the period with an LBP→USD rate of 1/usdToLbp stored at full precision. The
        /// divisor is cast to DECIMAL(18,4) — core.EXCHANGE_RATE.Rate's type, which is what the procedure
        /// divides by — because Dapper would otherwise send 90000 as DECIMAL(5,0) and 1.0/that has 7 decimals.
        /// </summary>
        public Task<int> RunAsync(string period, int userId, decimal usdToLbp) => Db.QuerySingleAsync<int>(
            """
            DECLARE @S DATE = CAST(@Period + '-01' AS DATE);
            INSERT INTO payroll.PAYROLL_RUN (PeriodYearMonth, PeriodStart, PeriodEnd, PrimaryCurrency, Notes, CreatedByUserId, RunType)
            VALUES (@Period, @S, EOMONTH(@S), 'USD', N'ZZ script 78 test', @User, 'Primary');
            DECLARE @R INT = SCOPE_IDENTITY();
            INSERT INTO payroll.PAYROLL_RUN_RATE (PayrollRunId, FromCurrency, ToCurrency, Rate, RateType, SourceEffectiveDate)
            VALUES (@R, 'LBP', 'USD', CAST(1.0 / CAST(@UsdToLbp AS DECIMAL(18,4)) AS DECIMAL(28,12)), 'NonOfficial', @S);
            SELECT @R;
            """, new { Period = period, User = userId, UsdToLbp = usdToLbp }, Tx);

        public async ValueTask DisposeAsync()
        {
            try { await Tx.RollbackAsync(); } catch { /* already rolled back by an aborted batch */ }
            await Db.DisposeAsync();
        }
    }

    [DbFact]
    public async Task RateColumn_IsDecimal28_12()
    {
        await using var f = await Fixture.OpenAsync();
        var (precision, scale) = await f.Db.QuerySingleAsync<(byte, byte)>(
            "SELECT c.precision, c.scale FROM sys.columns c WHERE c.object_id = OBJECT_ID('payroll.PAYROLL_RUN_RATE') AND c.name = 'Rate'",
            transaction: f.Tx);
        Assert.Equal((28, 12), (precision, scale));
    }

    /// <summary>BUG-07: 6,000,000 LBP at USD→LBP 90,000 is 66.67 USD, not 0.00.</summary>
    [DbFact]
    public async Task FnToPrimary_KeepsTheLbpRatePrecision()
    {
        await using var f = await Fixture.OpenAsync();
        var user = await f.HrUserAsync() ?? await f.Db.QuerySingleAsync<int>("SELECT TOP 1 UserId FROM security.[USER]", transaction: f.Tx);
        var run = await f.RunAsync("2099-01", user, 90000m);

        var (rate, lbp, usd) = await f.Db.QuerySingleAsync<(decimal, decimal, decimal)>(
            """
            SELECT payroll.fn_RunRate(@R, 'LBP', 'USD'), payroll.fn_ToPrimary(@R, 6000000, 'LBP'), payroll.fn_ToPrimary(@R, 100, 'USD')
            """, new { R = run }, f.Tx);

        Assert.InRange(rate, 1m / 90000m - 0.000000001m, 1m / 90000m + 0.000000001m);
        Assert.Equal(66.67m, lbp);
        Assert.Equal(100.00m, usd);
    }

    /// <summary>
    /// BUG-18: an explicit NULL @RunType is a PRIMARY run. With a live primary for the period the
    /// primary path refuses with "already exists"; the supplemental path would have answered with a
    /// different sentence ("A supplemental follows an approved primary…" / "No approved, unconsumed
    /// adjustments…"), which is exactly how the bug showed.
    /// </summary>
    [DbFact]
    public async Task Create_WithNullRunType_TakesThePrimaryPath()
    {
        await using var f = await Fixture.OpenAsync();
        var user = await f.HrUserAsync();
        if (user is null) return; // no HR/Admin user to act as: nothing to assert against
        await f.RunAsync("2099-02", user.Value, 90000m);

        var ex = await Assert.ThrowsAsync<SqlException>(() => f.Db.ExecuteAsync(
            "payroll.usp_PayrollRun_Create",
            new { PeriodYearMonth = "2099-02", CreatedByUserId = user.Value, Notes = (string?)null, RunType = (string?)null },
            f.Tx, commandType: CommandType.StoredProcedure));

        Assert.Contains("A primary run for 2099-02 already exists", ex.Message);
    }

    /// <summary>
    /// BUG-06: section D deducts only worked / absent days on a rostered shift. A RestDay row with the
    /// legacy DayFraction 0, a Leave row, a Holiday row with DayFraction 0 and a short day with no
    /// rostered shift cost nothing; a half day and an absence on rostered shifts cost 1.5 days.
    /// </summary>
    [DbFact]
    public async Task Generate_DeductsOnlyWorkedOrAbsentDaysOnARosteredShift()
    {
        await using var f = await Fixture.OpenAsync();
        var user = await f.HrUserAsync() ?? await f.Db.QuerySingleAsync<int>("SELECT TOP 1 UserId FROM security.[USER]", transaction: f.Tx);

        var emp = await f.Db.QuerySingleAsync<int>(
            """
            INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'ZZ Script 78 Branch', 1);
            DECLARE @B INT = SCOPE_IDENTITY();
            DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
            DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId);
            INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, ApprovalTier, PreferredLanguage)
            VALUES (@B, @Dep, @Pos, N'ZZ Script 78 Test', '2024-01-01', 5, 'en');
            DECLARE @E INT = SCOPE_IDENTITY();
            INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom, EffectiveTo)
            VALUES (@E, (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE Name = N'Basic Salary'), 1300, 'USD', '2024-01-01', NULL);  -- inside the tier's salary range
            INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
            VALUES (N'ZZ 78 07-15', '07:00', '15:00', NULL, 0, 0, 1);
            DECLARE @S INT = SCOPE_IDENTITY();
            INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status]) VALUES (@B, '2099-03-01', 'Approved');
            INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES
                (@E, @S,   '2099-03-02', 0),   -- half day worked          -> 0.5 short
                (@E, NULL, '2099-03-03', 1),   -- rest day, legacy fraction 0 -> never
                (@E, @S,   '2099-03-04', 0),   -- leave, fraction NULL      -> never
                (@E, @S,   '2099-03-06', 0),   -- holiday, fraction 0       -> never
                (@E, @S,   '2099-03-07', 0);   -- absent                    -> 1.0 short
                                               -- 2099-03-05: no assignment at all -> never
            INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], DayFraction, StandardMinutes, WorkedMinutes, [Source]) VALUES
                (@E, '2099-03-02', 'Present', 0.50, 480, 240, 'Manual'),
                (@E, '2099-03-03', 'RestDay', 0.00, 0,   0,   'Manual'),
                (@E, '2099-03-04', 'Leave',   NULL, 480, 0,   'Manual'),
                (@E, '2099-03-05', 'Present', 0.25, 480, 120, 'Manual'),
                (@E, '2099-03-06', 'Holiday', 0.00, 480, 0,   'Manual'),
                (@E, '2099-03-07', 'Absent',  0.00, 480, 0,   'Manual');
            SELECT @E;
            """, transaction: f.Tx);

        var run = await f.RunAsync("2099-03", user, 90000m);
        await f.Db.ExecuteAsync("payroll.usp_PayrollRun_Generate", new { PayrollRunId = run, ActedByUserId = user },
            f.Tx, commandType: CommandType.StoredProcedure);

        var days = await f.Db.QuerySingleAsync<decimal>(
            "SELECT ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'StandardWorkingDaysPerMonth') AS DECIMAL(6,2)), 26)",
            transaction: f.Tx);
        var line = await f.Db.QuerySingleOrDefaultAsync<(decimal Amount, decimal Quantity, string Note)>(
            """
            SELECT l.Amount, l.Quantity, l.Note
            FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId
            WHERE ps.PayrollRunId = @R AND ps.EmployeeId = @E AND l.ComponentName = N'Late Deduction'
            """, new { R = run, E = emp }, f.Tx);

        var dayRate = decimal.Round(1300m / days, 4);
        Assert.Equal(1.50m, line.Quantity);
        Assert.Equal("1.5 day(s) short across 2 date(s)", line.Note);
        Assert.Equal(decimal.Round(1.5m * dayRate, 2), line.Amount);
    }
}
