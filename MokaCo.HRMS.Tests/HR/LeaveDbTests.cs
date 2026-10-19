using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Model.Report;
using MokaCo.HRMS.Tests.Attendance;

namespace MokaCo.HRMS.Tests.HR;

/// <summary>
/// The leave procedures of docs/99_qa3_leave.sql as the API reads them (QA3 unit D): the ledger read says which row may be
/// deleted and the delete refuses the others with a sentence (LEV-9); the leave balance report's rows add up with
/// Adjusted (LEV-14); the per-year card defaults to Beirut's year; the expiry reports a setting that is not MM-DD (LEV-6);
/// the re-pricing contract returns no result set (safe inside INSERT..EXEC, units B and C call it). Every test runs INSIDE
/// A TRANSACTION THAT IS ROLLED BACK; seeded rows start with 'QA3 ' and dates are in 2097. Skipped without a database.
/// </summary>
[Collection("LeaveDb")]
public class LeaveDbTests
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

        /// <summary>A QA3 employee and a QA3 leave type with one row of every kind in the ledger.</summary>
        public Task<(int Employee, int Type)> SeedAsync() => Db.QuerySingleAsync<(int, int)>(
            """
            INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Leave Db Branch', 1);
            DECLARE @B INT = SCOPE_IDENTITY();
            INSERT INTO hr.LEAVE_TYPE (Name, IsPaid, AccrualPerMonth, CarryOver, RequiresCertificate, MinServiceMonthsToUse, NoticePreferredDays, FixedEntitlementDays, IsDiscretionary, IsActive)
            VALUES (N'QA3 Db Annual', 1, 0, 1, 0, 0, 0, NULL, 0, 1);
            DECLARE @A INT = SCOPE_IDENTITY();
            INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
            VALUES (@B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId),
                    N'QA3 Leave Db E1', '2020-01-01', NULL, 5, 'en');
            DECLARE @E INT = SCOPE_IDENTITY();
            INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note, SourceType, SourceRef)
            VALUES (@E, @A, '2097-01', 'Accrual',    15,   '2097-01-01', N'Annual entitlement 2097.', 'LeaveYear', 2097),
                   (@E, @A, '2097-01', 'CarryOver',   4,   '2097-01-01', N'Carried over from 2096.', 'LeaveYear', 2097),
                   (@E, @A, '2097-02', 'Adjustment',  1.5, '2097-02-10', N'QA3 manual correction', NULL, NULL),
                   (@E, @A, '2097-03', 'Usage',      -2,   '2097-03-10', N'QA3 manual usage', NULL, NULL),
                   (@E, @A, '2097-03', 'Expiry',     -1,   '2097-03-31', N'QA3 expiry', NULL, NULL);
            SELECT @E, @A;
            """, transaction: Tx);

        public async ValueTask DisposeAsync()
        {
            try { await Tx.RollbackAsync(); } catch { /* already rolled back by an aborted batch */ }
            await Db.DisposeAsync();
        }
    }

    [DbFact]
    public async Task The_ledger_read_offers_the_delete_only_on_a_manual_adjustment_and_the_delete_refuses_the_rest()
    {
        await using var f = await Fixture.OpenAsync();
        var (employee, _) = await f.SeedAsync();

        var rows = (await f.Db.QueryAsync<LeaveLedgerEntry>("hr.usp_LeaveLedger_GetByEmployee",
            new { EmployeeId = employee }, f.Tx, commandType: CommandType.StoredProcedure)).ToList();

        var deletable = Assert.Single(rows, r => r.CanDelete);
        Assert.Equal("Adjustment", deletable.MovementType);
        Assert.Equal("LeaveYear", rows.First(r => r.MovementType == "Accrual").SourceType);

        var opening = rows.First(r => r.MovementType == "Accrual").LeaveLedgerId;
        var ex = await Assert.ThrowsAsync<SqlException>(() => f.Db.ExecuteAsync("hr.usp_LeaveLedger_Delete",
            new { LeaveLedgerId = opening }, f.Tx, commandType: CommandType.StoredProcedure));
        Assert.Equal(50000, ex.Number);
        Assert.StartsWith("This movement was written when the leave year was opened", ex.Message);
    }

    [DbFact]
    public async Task The_leave_balance_report_rows_add_up_with_the_adjustments()
    {
        await using var f = await Fixture.OpenAsync();
        var (employee, type) = await f.SeedAsync();

        using var grid = await f.Db.QueryMultipleAsync("report.usp_Report_LeaveBalance",
            new { AsOfYearMonth = "2097-12", EmployeeId = employee, BranchId = (int?)null }, f.Tx, commandType: CommandType.StoredProcedure);
        await grid.ReadSingleAsync<LeaveBalanceHeader>();
        var row = Assert.Single(await grid.ReadAsync<LeaveBalanceRow>(), r => r.LeaveType == "QA3 Db Annual");

        Assert.Equal(0.5m, row.Adjusted);                       // +1.5 correction, -1 expiry
        Assert.Equal(row.Accrued + row.CarriedOver - row.Used + row.Adjusted, row.Remaining);
        Assert.Equal(17.5m, row.Remaining);
        Assert.True(type > 0);
    }

    [DbFact]
    public async Task The_balance_by_month_rows_carry_adjusted_and_add_up()
    {
        await using var f = await Fixture.OpenAsync();
        var (employee, _) = await f.SeedAsync();

        var rows = (await f.Db.QueryAsync<LeaveBalance>("hr.usp_LeaveBalance_Get",
            new { EmployeeId = employee, PeriodYearMonth = (string?)null }, f.Tx, commandType: CommandType.StoredProcedure)).ToList();

        Assert.Contains(rows, r => r.Adjusted != 0);
        Assert.All(rows, r => Assert.Equal(r.Accrued + r.CarriedOver - r.Used + r.Adjusted, r.Remaining));
    }

    [DbFact]
    public async Task The_per_year_balance_defaults_to_the_year_in_Beirut()
    {
        await using var f = await Fixture.OpenAsync();
        var beirutYear = await f.Db.QuerySingleAsync<int>(
            "SELECT YEAR(CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE))", transaction: f.Tx);

        using var grid = await f.Db.QueryMultipleAsync("hr.usp_Leave_GetBalanceByYear",
            new { EmployeeId = -1, Year = (int?)null }, f.Tx, commandType: CommandType.StoredProcedure);
        var header = await grid.ReadSingleAsync<(bool YearOpened, int Year)>();

        Assert.Equal(beirutYear, header.Year);
        Assert.False(header.YearOpened);
    }

    [DbFact]
    public async Task The_expiry_says_why_it_expired_nothing_when_the_setting_is_not_MMDD()
    {
        await using var f = await Fixture.OpenAsync();
        var p = new DynamicParameters();
        p.Add("AsOfDate", new DateTime(2097, 12, 31));
        p.Add("ExpiresOn", "13-45");
        p.Add("Problem", dbType: DbType.String, size: 300, direction: ParameterDirection.Output);

        var result = await f.Db.QuerySingleAsync<LeaveCarryOverExpired>("hr.usp_LeaveCarryOver_Expire", p, f.Tx,
            commandType: CommandType.StoredProcedure);

        Assert.Equal(0, result.EmployeesExpired);
        Assert.Contains("\"13-45\" is not a MM-DD date", p.Get<string?>("Problem"));
    }

    [DbFact]
    public async Task Repricing_returns_no_result_set_so_it_can_run_inside_INSERT_EXEC()
    {
        await using var f = await Fixture.OpenAsync();
        var (employee, _) = await f.SeedAsync();

        var captured = await f.Db.QuerySingleAsync<int>(
            """
            DECLARE @t TABLE (AnyColumn SQL_VARIANT);
            INSERT INTO @t EXEC hr.usp_LeaveLedger_Reprice @EmployeeId = @E, @FromDate = '2097-01-01', @ToDate = '2097-12-31';
            SELECT COUNT(*) FROM @t;
            """, new { E = employee }, f.Tx);

        Assert.Equal(0, captured);
    }
}
