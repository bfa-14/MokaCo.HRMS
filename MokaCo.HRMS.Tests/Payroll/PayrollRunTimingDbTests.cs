using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Tests.Attendance;

namespace MokaCo.HRMS.Tests.Payroll;

/// <summary>
/// Script 81 — "Supplemental and Primary can be generated at any time" — against the real procedures.
/// Every test runs INSIDE A TRANSACTION THAT IS ROLLED BACK, in months of 2099 so nothing real is in
/// the way; the procedures' clock (@AsOfDate) is injected where the rule depends on today.
///
/// The thing being protected is that AN ADJUSTMENT IS PAID ONCE whatever the order of events:
/// supplemental before the primary exists, supplemental while the primary is a draft, primary
/// generated before the supplemental.
/// </summary>
// One collection for every class that runs the payroll generator inside an open transaction: two of
// them side by side take the same locks in a different order and one is chosen as the deadlock victim.
[Collection("PayrollDb")]
public class PayrollRunTimingDbTests
{
    private sealed class Fixture : IAsyncDisposable
    {
        public SqlConnection Db { get; }
        public SqlTransaction Tx { get; }
        public int Hr { get; private set; }
        public int Owner { get; private set; }
        public int Employee { get; private set; }
        public int Adjustment { get; private set; }
        private Fixture(SqlConnection db, SqlTransaction tx) { Db = db; Tx = tx; }

        /// <summary>Null when the database has no HR/Admin or no Owner to act as: nothing to assert against.</summary>
        public static async Task<Fixture?> OpenAsync(string period)
        {
            var db = new SqlConnection(DbFactAttribute.ConnectionString);
            await db.OpenAsync();
            var f = new Fixture(db, db.BeginTransaction());

            var hr = await db.QuerySingleOrDefaultAsync<int?>(
                "SELECT TOP 1 UserId FROM security.[USER] u WHERE payroll.fn_UserHasRole(u.UserId, N'HR') = 1 OR payroll.fn_UserHasRole(u.UserId, N'Admin') = 1 ORDER BY UserId",
                transaction: f.Tx);
            var owner = await db.QuerySingleOrDefaultAsync<int?>(
                "SELECT TOP 1 UserId FROM security.[USER] u WHERE payroll.fn_UserHasRole(u.UserId, N'Owner') = 1 ORDER BY UserId",
                transaction: f.Tx);
            if (hr is null || owner is null) { await f.DisposeAsync(); return null; }
            f.Hr = hr.Value; f.Owner = owner.Value;

            // one employee with a salary and ONE signed, unconsumed adjustment targeting the period
            (f.Employee, f.Adjustment) = await db.QuerySingleAsync<(int, int)>(
                """
                INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'ZZ Script 81 Branch', 1);
                DECLARE @B INT = SCOPE_IDENTITY();
                INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, ApprovalTier, PreferredLanguage)
                VALUES (@B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId),
                        (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), N'ZZ Script 81 Test', '2024-01-01', 5, 'en');
                DECLARE @E INT = SCOPE_IDENTITY();
                INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom, EffectiveTo)
                VALUES (@E, (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE Name = N'Basic Salary'), 1300, 'USD', '2024-01-01', NULL);
                INSERT INTO payroll.PAYROLL_ADJUSTMENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, TargetPeriod, Reason, CreatedByUserId)
                VALUES (@E, (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE Name = N'Tips'), 40, 'USD', @Period, N'ZZ script 81 adjustment', @Owner);
                SELECT @E, CAST(SCOPE_IDENTITY() AS INT);
                """, new { Period = period, Owner = f.Owner }, f.Tx);
            return f;
        }

        public Task<int> CreateAsync(string period, string runType, DateTime? asOf = null) => Db.QuerySingleAsync<int>(
            "payroll.usp_PayrollRun_Create",
            new { PeriodYearMonth = period, CreatedByUserId = Hr, Notes = "ZZ script 81 test", RunType = runType, AsOfDate = asOf },
            Tx, commandType: CommandType.StoredProcedure);

        public Task GenerateAsync(int run, bool supplemental, DateTime? asOf = null) => supplemental
            ? Db.ExecuteAsync("payroll.usp_PayrollRun_GenerateSupplemental", new { PayrollRunId = run, ActedByUserId = Hr }, Tx, commandType: CommandType.StoredProcedure)
            : Db.ExecuteAsync("payroll.usp_PayrollRun_Generate", new { PayrollRunId = run, ActedByUserId = Hr, AsOfDate = asOf }, Tx, commandType: CommandType.StoredProcedure);

        public Task ReviewAsync(int run) => Db.ExecuteAsync("payroll.usp_PayrollRun_SendToReview",
            new { PayrollRunId = run, ActedByUserId = Hr }, Tx, commandType: CommandType.StoredProcedure);

        public Task ApproveAsync(int run) => Db.ExecuteAsync("payroll.usp_PayrollRun_Approve",
            new { PayrollRunId = run, ActedByUserId = Owner }, Tx, commandType: CommandType.StoredProcedure);

        /// <summary>How many payslip lines of the run pay the fixture's adjustment.</summary>
        public Task<int> AdjustmentLinesAsync(int run) => Db.QuerySingleAsync<int>(
            """
            SELECT COUNT(*) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId
            WHERE ps.PayrollRunId = @Run AND l.SourceType = 'Adjustment' AND l.SourceId = @Adj
            """, new { Run = run, Adj = Adjustment }, Tx);

        /// <summary>The run whose payslip consumed the adjustment, or null while it is unconsumed.</summary>
        public Task<int?> ConsumedByRunAsync() => Db.QuerySingleOrDefaultAsync<int?>(
            """
            SELECT ps.PayrollRunId FROM payroll.PAYROLL_ADJUSTMENT a
            JOIN payroll.PAYSLIP ps ON ps.PayslipId = a.AppliedToPayslipId WHERE a.PayrollAdjustmentId = @Adj
            """, new { Adj = Adjustment }, Tx);

        public async ValueTask DisposeAsync()
        {
            try { await Tx.RollbackAsync(); } catch { /* already rolled back by an aborted batch */ }
            await Db.DisposeAsync();
        }
    }

    private static readonly DateTime MidMonth = new(2099, 5, 12);

    /// <summary>
    /// A supplemental is created with NO primary for the period (the old refusal: "A supplemental follows
    /// an approved primary… not locked yet"). While it is open the primary's generate leaves its
    /// adjustment alone; once approved the adjustment is CONSUMED, and a later primary regenerate
    /// still does not pay it.
    /// </summary>
    [DbFact]
    public async Task Supplemental_BeforeAnyPrimary_PaysTheAdjustment_AndThePrimaryNeverPaysItAgain()
    {
        await using var f = await Fixture.OpenAsync("2099-05");
        if (f is null) return;

        var supplemental = await f.CreateAsync("2099-05", "Supplemental");
        await f.GenerateAsync(supplemental, supplemental: true);
        Assert.Equal(1, await f.AdjustmentLinesAsync(supplemental));

        // the primary, created on a day INSIDE its period, while the supplemental is still a draft
        var primary = await f.CreateAsync("2099-05", "Primary", MidMonth);
        await f.GenerateAsync(primary, supplemental: false, MidMonth);
        Assert.Equal(0, await f.AdjustmentLinesAsync(primary));

        await f.ReviewAsync(supplemental);
        await f.ApproveAsync(supplemental);
        Assert.Equal(supplemental, await f.ConsumedByRunAsync());

        await f.GenerateAsync(primary, supplemental: false, MidMonth);      // the "later Primary regenerate"
        Assert.Equal(0, await f.AdjustmentLinesAsync(primary));

        await f.ReviewAsync(primary);
        await f.ApproveAsync(primary);                                      // and it locks without touching the flag
        Assert.Equal(supplemental, await f.ConsumedByRunAsync());
    }

    /// <summary>
    /// The other order: the primary was generated FIRST and carries the adjustment; a supplemental is
    /// then prepared for the same money. The stale primary cannot be locked — it says so — and a
    /// regenerate drops the line.
    /// </summary>
    [DbFact]
    public async Task Primary_GeneratedBeforeTheSupplemental_MustBeRegeneratedBeforeItLocks()
    {
        await using var f = await Fixture.OpenAsync("2099-05");
        if (f is null) return;

        var primary = await f.CreateAsync("2099-05", "Primary", MidMonth);
        await f.GenerateAsync(primary, supplemental: false, MidMonth);
        Assert.Equal(1, await f.AdjustmentLinesAsync(primary));

        var supplemental = await f.CreateAsync("2099-05", "Supplemental");   // primary still Draft: allowed now
        await f.GenerateAsync(supplemental, supplemental: true);
        Assert.Equal(1, await f.AdjustmentLinesAsync(supplemental));

        await f.ReviewAsync(primary);
        var refusal = await Assert.ThrowsAsync<SqlException>(() => f.ApproveAsync(primary));
        Assert.Contains("adjustment(s) that a supplemental run pays", refusal.Message);

        await f.GenerateAsync(primary, supplemental: false, MidMonth);
        Assert.Equal(0, await f.AdjustmentLinesAsync(primary));
    }

    /// <summary>Kept rules: one open supplemental at a time, and a supplemental needs something to pay.</summary>
    [DbFact]
    public async Task Supplemental_StillNeedsSomethingToPay_AndOnlyOneMayBeOpen()
    {
        await using var f = await Fixture.OpenAsync("2099-05");
        if (f is null) return;

        var nothing = await Assert.ThrowsAsync<SqlException>(() => f.CreateAsync("2099-06", "Supplemental"));
        Assert.Contains("No approved, unpaid adjustments target 2099-06", nothing.Message);

        await f.CreateAsync("2099-05", "Supplemental");
        var second = await Assert.ThrowsAsync<SqlException>(() => f.CreateAsync("2099-05", "Supplemental"));
        Assert.Contains("An open supplemental for this period already exists", second.Message);
    }

    /// <summary>A primary may be created on any day OF its period — from the 1st on, not before; and only one.</summary>
    [DbFact]
    public async Task Primary_IsRefusedBeforeItsPeriodStarts_AndAllowedFromTheFirstDay()
    {
        await using var f = await Fixture.OpenAsync("2099-05");
        if (f is null) return;

        var early = await Assert.ThrowsAsync<SqlException>(() => f.CreateAsync("2099-05", "Primary", new DateTime(2099, 4, 30)));
        Assert.Contains("The period 2099-05 has not started yet", early.Message);
        Assert.Contains("2099-05-01", early.Message);

        var run = await f.CreateAsync("2099-05", "Primary", new DateTime(2099, 5, 1));
        Assert.True(run > 0);

        var twice = await Assert.ThrowsAsync<SqlException>(() => f.CreateAsync("2099-05", "Primary", MidMonth));
        Assert.Contains("A primary run for 2099-05 already exists", twice.Message);
    }

    /// <summary>
    /// The readiness gates look only at the days that have happened. An open anomaly on the 20th does
    /// not make the month unready on the 12th — and does at the end of the month. PeriodEnd stays the
    /// month's end either way (the INSERT-EXEC shape callers rely on), and the create refusal names
    /// the day it looked up to.
    /// </summary>
    [DbFact]
    public async Task Readiness_LooksOnlyAtDaysUpToToday()
    {
        await using var f = await Fixture.OpenAsync("2099-05");
        if (f is null) return;

        await f.Db.ExecuteAsync(
            """
            INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], DayFraction, StandardMinutes, WorkedMinutes, [Source], HasAnomaly)
            VALUES (@E, '2099-05-20', 'Present', 1, 480, 480, 'Manual', 1);
            """, new { E = f.Employee }, f.Tx);

        var mid = await f.Db.QuerySingleAsync("attendance.usp_Attendance_PayrollReadiness",
            new { PeriodYearMonth = "2099-05", AsOfDate = MidMonth }, f.Tx, commandType: CommandType.StoredProcedure);
        var end = await f.Db.QuerySingleAsync("attendance.usp_Attendance_PayrollReadiness",
            new { PeriodYearMonth = "2099-05", AsOfDate = new DateTime(2099, 6, 3) }, f.Tx, commandType: CommandType.StoredProcedure);

        Assert.Equal(0, (int)mid.OpenAnomalies);
        Assert.True((bool)mid.IsReady);
        Assert.Equal(new DateTime(2099, 5, 31), (DateTime)mid.PeriodEnd);
        Assert.Equal(1, (int)end.OpenAnomalies);
        Assert.False((bool)end.IsReady);

        Assert.True(await f.CreateAsync("2099-05", "Primary", MidMonth) > 0);   // mid-month: ready, so it is created
    }
}
