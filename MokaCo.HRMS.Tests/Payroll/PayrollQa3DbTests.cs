using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Tests.Attendance;

namespace MokaCo.HRMS.Tests.Payroll;

/// <summary>
/// The QA3 payroll rules (docs/103_qa3_payroll.sql) against the real procedures. Every test runs INSIDE A
/// TRANSACTION THAT IS ROLLED BACK, in months of 2099 so nothing real is in the way, with the procedures'
/// clock (@AsOfDate) injected. Skipped, with the reason, when no database is reachable.
/// </summary>
// The one database collection (DatabaseCollection, QA3 DB-2): two DB test classes side by side take the same locks
// in a different order and one is chosen as the deadlock victim.
[Collection(DatabaseCollection.Name)]
public class PayrollQa3DbTests
{
    private sealed class Fixture : IAsyncDisposable
    {
        public SqlConnection Db { get; }
        public SqlTransaction Tx { get; }
        public int Hr { get; private set; }
        public int Owner { get; private set; }
        public int Branch { get; private set; }
        public int BasicType { get; private set; }
        private Fixture(SqlConnection db, SqlTransaction tx) { Db = db; Tx = tx; }

        /// <summary>Null when the database has no HR/Admin or no Owner to act as: nothing to assert against.</summary>
        public static async Task<Fixture?> OpenAsync()
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

            (f.Branch, f.BasicType) = await db.QuerySingleAsync<(int, int)>(
                """
                -- the figures these tests compute with, whatever the database is configured with (rolled back)
                UPDATE core.SETTING SET SettingValue = '26' WHERE SettingKey = 'StandardWorkingDaysPerMonth';
                UPDATE core.SETTING SET SettingValue = '1' WHERE SettingKey = 'LeavePayoutOnTermination';
                -- the salary-band trigger judges a basic against the employee's tier: no band in these tests
                UPDATE hr.APPROVAL_TIER SET MinBasicSalary = NULL, MaxBasicSalary = NULL;
                INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Payroll Branch', 1);
                SELECT CAST(SCOPE_IDENTITY() AS INT), (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE SystemCode = 'BASIC');
                """, transaction: f.Tx);
            return f;
        }

        public Task<int> EmployeeAsync(string name, string hire, decimal basic, string? termination = null) => Db.QuerySingleAsync<int>(
            """
            INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
            VALUES (@B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId),
                    (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), @Name, @Hire, @Term,
                    ISNULL((SELECT MAX(TierNo) FROM hr.APPROVAL_TIER), 5), 'en');
            DECLARE @E INT = SCOPE_IDENTITY();
            IF OBJECT_ID('hr.EMPLOYEE_BRANCH_HISTORY') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeId = @E)
                INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom) VALUES (@E, @B, @Hire);
            INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom, EffectiveTo)
            VALUES (@E, @Basic, @Amount, 'USD', @Hire, NULL);
            SELECT @E;
            """, new { B = Branch, Name = name, Hire = DateTime.Parse(hire), Term = termination is null ? (DateTime?)null : DateTime.Parse(termination), Basic = BasicType, Amount = basic }, Tx);

        public Task<int> CreateAsync(string period, string asOf) => Db.QuerySingleAsync<int>(
            "payroll.usp_PayrollRun_Create",
            new { PeriodYearMonth = period, CreatedByUserId = Hr, Notes = "QA3 payroll test", RunType = "Primary", AsOfDate = DateTime.Parse(asOf) },
            Tx, commandType: CommandType.StoredProcedure);

        public Task GenerateAsync(int run, string asOf) => Db.ExecuteAsync("payroll.usp_PayrollRun_Generate",
            new { PayrollRunId = run, ActedByUserId = Hr, AsOfDate = DateTime.Parse(asOf) }, Tx, commandType: CommandType.StoredProcedure);

        public Task ReviewAsync(int run) => Db.ExecuteAsync("payroll.usp_PayrollRun_SendToReview",
            new { PayrollRunId = run, ActedByUserId = Hr }, Tx, commandType: CommandType.StoredProcedure);

        public Task ApproveAsync(int run, string asOf, bool early = false) => Db.ExecuteAsync("payroll.usp_PayrollRun_Approve",
            new { PayrollRunId = run, ActedByUserId = Owner, AllowEarlyLock = early, AsOfDate = DateTime.Parse(asOf) },
            Tx, commandType: CommandType.StoredProcedure);

        /// <summary>Create, generate and send to review in one go.</summary>
        public async Task<int> ReviewedRunAsync(string period, string asOf)
        {
            var run = await CreateAsync(period, asOf);
            await GenerateAsync(run, asOf);
            await ReviewAsync(run);
            return run;
        }

        public Task<decimal> LinesAsync(int run, int employee, string component) => Db.QuerySingleAsync<decimal>(
            """
            SELECT ISNULL(SUM(l.Amount), 0) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId
            JOIN hr.COMPONENT_TYPE c ON c.ComponentTypeId = l.ComponentTypeId
            WHERE ps.PayrollRunId = @Run AND ps.EmployeeId = @Emp AND c.SystemCode = @Code
            """, new { Run = run, Emp = employee, Code = component }, Tx);

        /// <summary>An approved request of any type, for a payload row to hang on.</summary>
        public Task<int> ApprovedRequestAsync(int employee) => Db.QuerySingleAsync<int>(
            """
            INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status])
            VALUES ((SELECT TOP 1 RequestTypeId FROM workflow.REQUEST_TYPE ORDER BY RequestTypeId),
                    (SELECT TOP 1 WorkflowDefinitionId FROM workflow.WORKFLOW_DEFINITION ORDER BY WorkflowDefinitionId), @E, @U, 'Approved');
            SELECT CAST(SCOPE_IDENTITY() AS INT);
            """, new { E = employee, U = Hr }, Tx);

        public async ValueTask DisposeAsync()
        {
            try { await Tx.RollbackAsync(); } catch { /* already rolled back by an aborted batch */ }
            await Db.DisposeAsync();
        }
    }

    /// <summary>
    /// PAY-5 / REL-3: a day recorded after the run was generated makes it stale — Approve refuses and names
    /// what changed; after a regenerate it locks.
    /// </summary>
    [DbFact]
    public async Task Approve_RefusesARunWhoseInputsChanged_UntilItIsRegenerated()
    {
        await using var f = await Fixture.OpenAsync();
        if (f is null) return;
        var emp = await f.EmployeeAsync("QA3 Stale", "2024-01-01", 1300);
        var run = await f.ReviewedRunAsync("2099-05", "2099-06-02");

        await f.Db.ExecuteAsync(
            """
            INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], DayFraction, StandardMinutes, WorkedMinutes, [Source])
            VALUES (@E, '2099-05-20', 'Present', 1, 480, 480, 'Manual')
            """, new { E = emp }, f.Tx);

        var stale = await f.Db.QueryAsync<string>(
            "SELECT Source FROM payroll.fn_RunStaleness(@R) WHERE EmployeeId = @E", new { R = run, E = emp }, f.Tx);
        Assert.Contains("Attendance", stale);
        var refusal = await Assert.ThrowsAsync<SqlException>(() => f.ApproveAsync(run, "2099-06-02"));
        Assert.Contains("This run is out of date", refusal.Message);
        Assert.Contains("QA3 Stale: Attendance", refusal.Message);

        await f.GenerateAsync(run, "2099-06-02");
        await f.ApproveAsync(run, "2099-06-02");
        Assert.Equal("Approved", await f.Db.QuerySingleAsync<string>("SELECT [Status] FROM payroll.PAYROLL_RUN WHERE PayrollRunId = @R", new { R = run }, f.Tx));
    }

    /// <summary>PAY-3: a primary is locked once its last day is over; before that only as the Owner's explicit early lock.</summary>
    [DbFact]
    public async Task Approve_BeforeTheLastDayIsOver_NeedsTheOwnersEarlyLock()
    {
        await using var f = await Fixture.OpenAsync();
        if (f is null) return;
        await f.EmployeeAsync("QA3 Early", "2024-01-01", 1300);
        var run = await f.ReviewedRunAsync("2099-05", "2099-05-31");

        var refusal = await Assert.ThrowsAsync<SqlException>(() => f.ApproveAsync(run, "2099-05-31"));
        Assert.Contains("EARLY LOCK", refusal.Message);
        Assert.Contains("can be locked from 2099-06-01", refusal.Message);

        await f.ApproveAsync(run, "2099-05-31", early: true);
        var (status, early) = await f.Db.QuerySingleAsync<(string, bool?)>(
            "SELECT [Status], LockedEarly FROM payroll.PAYROLL_RUN WHERE PayrollRunId = @R", new { R = run }, f.Tx);
        Assert.Equal("Approved", status);
        Assert.True(early);
    }

    /// <summary>PAY-11: the run is claimed once — a second approval changes nothing (an advance is reduced once).</summary>
    [DbFact]
    public async Task Approve_Twice_TheSecondChangesNothing()
    {
        await using var f = await Fixture.OpenAsync();
        if (f is null) return;
        var emp = await f.EmployeeAsync("QA3 Twice", "2024-01-01", 1300);
        await f.Db.ExecuteAsync(
            """
            INSERT INTO payroll.SALARY_ADVANCE (EmployeeId, Amount, CurrencyCode, AdvanceDate, MonthlyDeduction, RemainingAmount, FirstDeductionPeriod, Reason, CreatedByUserId)
            VALUES (@E, 600, 'USD', '2099-05-02', 300, 600, '2099-05', N'QA3 advance', @U)
            """, new { E = emp, U = f.Hr }, f.Tx);
        var run = await f.ReviewedRunAsync("2099-05", "2099-06-02");
        await f.ApproveAsync(run, "2099-06-02");

        var again = await Assert.ThrowsAsync<SqlException>(() => f.ApproveAsync(run, "2099-06-02"));
        Assert.Contains("already approved", again.Message);
        Assert.Equal(300m, await f.Db.QuerySingleAsync<decimal>(
            "SELECT RemainingAmount FROM payroll.SALARY_ADVANCE WHERE EmployeeId = @E", new { E = emp }, f.Tx));
    }

    /// <summary>PAY-4: Generate asks the readiness gate again — an undecided anomaly recorded after Create refuses it.</summary>
    [DbFact]
    public async Task Generate_ChecksReadinessAgain()
    {
        await using var f = await Fixture.OpenAsync();
        if (f is null) return;
        var emp = await f.EmployeeAsync("QA3 Ready", "2024-01-01", 1300);
        var run = await f.CreateAsync("2099-05", "2099-05-02");
        await f.Db.ExecuteAsync(
            """
            INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], DayFraction, StandardMinutes, WorkedMinutes, [Source], HasAnomaly)
            VALUES (@E, '2099-05-10', 'Present', 0.5, 480, 240, 'Manual', 0);
            INSERT INTO attendance.ATTENDANCE_ANOMALY (AttendanceId, EmployeeId, WorkDate, [Type])
            VALUES (CAST(SCOPE_IDENTITY() AS BIGINT), @E, '2099-05-10', 'LateArrival');
            """, new { E = emp }, f.Tx);

        var refusal = await Assert.ThrowsAsync<SqlException>(() => f.GenerateAsync(run, "2099-06-02"));
        Assert.Contains("undecided anomal", refusal.Message);
    }

    /// <summary>
    /// PAY-4 with script 100 (unit B): readiness counts the punches still WAITING for an owner — the ones HR set
    /// aside no longer block payroll. Without script 100 (no DismissedUtc) only the first half is asserted.
    /// </summary>
    [DbFact]
    public async Task Readiness_CountsOnlyThePunchesStillWaitingForAnOwner()
    {
        await using var f = await Fixture.OpenAsync();
        if (f is null) return;
        var device = await f.Db.QuerySingleOrDefaultAsync<int?>("SELECT TOP 1 DeviceId FROM attendance.DEVICE ORDER BY DeviceId", transaction: f.Tx);
        if (device is null) return;   // no device in this database to stamp a punch with
        await f.Db.ExecuteAsync(
            """
            INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
            VALUES (@D, 'QA3-NOBODY', NULL, '2099-05-10T06:00:00', 0, 'Device', CONCAT('QA3-', NEWID()));
            """, new { D = device }, f.Tx);
        const string count = "SELECT UnresolvedPinPunches FROM attendance.fn_PayrollReadiness('2099-05', '2099-06-02')";
        Assert.Equal(1, await f.Db.QuerySingleAsync<int>(count, transaction: f.Tx));

        if (await f.Db.QuerySingleAsync<int?>("SELECT COL_LENGTH('attendance.RAW_DEVICE_LOG', 'DismissedUtc')", transaction: f.Tx) is null)
            return;
        await f.Db.ExecuteAsync(
            "EXEC (N'UPDATE attendance.RAW_DEVICE_LOG SET DismissedUtc = SYSUTCDATETIME() WHERE EnrollPin = ''QA3-NOBODY''')",
            transaction: f.Tx);
        Assert.Equal(0, await f.Db.QuerySingleAsync<int>(count, transaction: f.Tx));
    }

    /// <summary>
    /// REL-15: "unpaid absence days — this is the deduction" is the payslip's own short-days figure. Two days absent
    /// and three days of approved leave: 2, as the payslip deducts — the summaries' "Absent − leave usage" read 0.
    /// </summary>
    [DbFact]
    public async Task TheUnpaidAbsenceFigure_IsTheShortDaysThePayslipDeducts()
    {
        await using var f = await Fixture.OpenAsync();
        if (f is null) return;
        var emp = await f.EmployeeAsync("QA3 Absent", "2024-01-01", 2600);
        var rid = await f.ApprovedRequestAsync(emp);
        await f.Db.ExecuteAsync(
            """
            DECLARE @Shift INT = (SELECT MIN(ShiftId) FROM attendance.SHIFT);
            DECLARE @Paid INT = (SELECT TOP 1 LeaveTypeId FROM hr.LEAVE_TYPE WHERE IsPaid = 1 ORDER BY LeaveTypeId);
            INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
            SELECT @E, @Shift, d, 0 FROM (VALUES ('2099-05-10'), ('2099-05-11'), ('2099-05-12'), ('2099-05-13'), ('2099-05-14')) v(d);
            INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status], ApprovedAt) VALUES (@B, '2099-05-01', 'Approved', SYSUTCDATETIME());
            INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], DayFraction, StandardMinutes, WorkedMinutes, [Source])
            VALUES (@E, '2099-05-10', 'Absent', 0, 480, 0, 'Manual'), (@E, '2099-05-11', 'Absent', 0, 480, 0, 'Manual'),
                   (@E, '2099-05-12', 'Leave', 1, 480, 0, 'Manual'), (@E, '2099-05-13', 'Leave', 1, 480, 0, 'Manual'),
                   (@E, '2099-05-14', 'Leave', 1, 480, 0, 'Manual');
            INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, ApprovedToDate, PaidSnapshot)
            VALUES (@R, @E, @Paid, '2099-05-12', '2099-05-14', 3, 3, '2099-05-14', 1);
            """, new { E = emp, R = rid, B = f.Branch }, f.Tx);

        var row = await f.Db.QuerySingleAsync(
            "attendance.usp_Attendance_UnpaidAbsenceDays",
            new { PeriodYearMonth = "2099-05", EmployeeId = emp, AsOfDate = new DateTime(2099, 6, 2) },
            f.Tx, commandType: CommandType.StoredProcedure);
        decimal figure = row.UnpaidAbsenceDays;
        Assert.Equal(2m, figure);

        var may = await f.CreateAsync("2099-05", "2099-06-02");
        await f.GenerateAsync(may, "2099-06-02");
        Assert.Equal(figure, await f.Db.QuerySingleAsync<decimal>(
            "SELECT l.Quantity FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId JOIN hr.COMPONENT_TYPE c ON c.ComponentTypeId = l.ComponentTypeId WHERE ps.PayrollRunId = @R AND ps.EmployeeId = @E AND c.SystemCode = 'LATE'",
            new { R = may, E = emp }, f.Tx));
    }

    /// <summary>PAY-6: a raise added WITHOUT closing the old row still pays each row only its own days.</summary>
    [DbFact]
    public async Task Generate_ALaterRowSupersedesTheStandingOne()
    {
        await using var f = await Fixture.OpenAsync();
        if (f is null) return;
        var emp = await f.EmployeeAsync("QA3 Raise", "2024-01-01", 1500);
        await f.Db.ExecuteAsync(
            "INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom) VALUES (@E, @T, 1800, 'USD', '2099-05-16')",
            new { E = emp, T = f.BasicType }, f.Tx);
        var run = await f.CreateAsync("2099-05", "2099-06-02");
        await f.GenerateAsync(run, "2099-06-02");

        Assert.Equal(decimal.Round(1500m * 15 / 31, 2) + decimal.Round(1800m * 16 / 31, 2), await f.LinesAsync(run, emp, "BASIC"));
    }

    /// <summary>REL-1: nothing after the termination date costs anything — basic 2600 to the 15th, absences recorded after it.</summary>
    [DbFact]
    public async Task Generate_DeductsNothingAfterTheTerminationDate()
    {
        await using var f = await Fixture.OpenAsync();
        if (f is null) return;
        var emp = await f.EmployeeAsync("QA3 Leaver", "2024-01-01", 2600, termination: "2099-05-15");
        await f.Db.ExecuteAsync(
            """
            INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
            VALUES (N'QA3 07-15', '07:00', '15:00', NULL, 0, 0, 1);
            DECLARE @S INT = SCOPE_IDENTITY();
            INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status]) VALUES (@B, '2099-05-01', 'Approved');
            DECLARE @d DATE = '2099-05-16';
            WHILE @d <= '2099-05-31'
            BEGIN
                INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E, @S, @d, 0);
                INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], DayFraction, StandardMinutes, WorkedMinutes, [Source])
                VALUES (@E, @d, 'Absent', 0, 480, 0, 'Manual');
                SET @d = DATEADD(DAY, 1, @d);
            END
            """, new { E = emp, B = f.Branch }, f.Tx);
        var run = await f.CreateAsync("2099-05", "2099-06-02");
        await f.GenerateAsync(run, "2099-06-02");

        Assert.Equal(decimal.Round(2600m * 15 / 31, 2), await f.LinesAsync(run, emp, "BASIC"));
        Assert.Equal(0m, await f.LinesAsync(run, emp, "LATE"));
        Assert.True(await f.Db.QuerySingleAsync<decimal>(
            "SELECT NetUsd FROM payroll.PAYSLIP WHERE PayrollRunId = @R AND EmployeeId = @E", new { R = run, E = emp }, f.Tx) > 0);
    }

    /// <summary>
    /// PAY-2: a separation prepared after the leaving month was locked is paid by the next open primary
    /// (a settlement-only payslip), stamped when that run is approved, and never paid again.
    /// </summary>
    [DbFact]
    public async Task ASettlementPreparedAfterTheLock_IsPaidByTheNextPrimary_Once()
    {
        await using var f = await Fixture.OpenAsync();
        if (f is null) return;
        var emp = await f.EmployeeAsync("QA3 Settled", "2024-01-01", 1300);
        var april = await f.ReviewedRunAsync("2099-04", "2099-05-02");
        await f.ApproveAsync(april, "2099-05-02");

        var rid = await f.ApprovedRequestAsync(emp);
        var sep = await f.Db.QuerySingleAsync<int>(
            """
            UPDATE hr.EMPLOYEE SET TerminationDate = '2099-04-25' WHERE EmployeeId = @E;
            INSERT INTO workflow.SEPARATION (RequestInstanceId, EmployeeId, LastWorkingDate, CurrencyCode, IndemnityAmount, ServiceYears, PreparedAt)
            VALUES (@R, @E, '2099-04-25', 'USD', 4000, 75.3, SYSUTCDATETIME());
            SELECT CAST(SCOPE_IDENTITY() AS INT);
            """, new { E = emp, R = rid }, f.Tx);

        var may = await f.ReviewedRunAsync("2099-05", "2099-06-02");
        Assert.Equal(4000m, await f.LinesAsync(may, emp, "INDEMNITY"));
        Assert.Equal(0m, await f.LinesAsync(may, emp, "BASIC"));            // settlement only: nothing of May is paid
        await f.ApproveAsync(may, "2099-06-02");
        Assert.NotNull(await f.Db.QuerySingleAsync<int?>("SELECT PaidInPayslipId FROM workflow.SEPARATION WHERE SeparationId = @S", new { S = sep }, f.Tx));

        var june = await f.CreateAsync("2099-06", "2099-07-02");
        await f.GenerateAsync(june, "2099-07-02");
        Assert.Equal(0m, await f.LinesAsync(june, emp, "INDEMNITY"));
    }

    /// <summary>
    /// LEV-8 / REL-14: when the separation settlement pays the unused leave, the termination payout is not paid as
    /// well, and the lock settles the balance in the ledger — so a later employment of the same person starts at 0.
    /// </summary>
    [DbFact]
    public async Task ASeparationThatPaysTheLeave_SettlesTheBalance_AndNoPayoutIsAdded()
    {
        await using var f = await Fixture.OpenAsync();
        if (f is null) return;
        var leaveType = await f.Db.QuerySingleOrDefaultAsync<int?>(
            "SELECT TOP 1 lt.LeaveTypeId FROM hr.LEAVE_TYPE lt WHERE lt.IsPaid = 1 AND EXISTS (SELECT 1 FROM hr.LEAVE_ACCRUAL_TIER t WHERE t.LeaveTypeId = lt.LeaveTypeId) ORDER BY lt.LeaveTypeId",
            transaction: f.Tx);
        if (leaveType is null) return;   // no accruing paid leave type in this database
        var emp = await f.EmployeeAsync("QA3 Separated", "2024-01-01", 2600, termination: "2099-04-20");
        var rid = await f.ApprovedRequestAsync(emp);
        await f.Db.ExecuteAsync(
            """
            INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note)
            VALUES (@E, @T, '2099-01', 'Adjustment', 4, '2099-01-01', N'QA3 opening');
            INSERT INTO workflow.SEPARATION (RequestInstanceId, EmployeeId, LastWorkingDate, CurrencyCode, UnusedLeaveDays, UnusedLeaveAmount, PreparedAt)
            VALUES (@R, @E, '2099-04-20', 'USD', 4, 400, SYSUTCDATETIME());
            """, new { E = emp, T = leaveType, R = rid }, f.Tx);

        var april = await f.ReviewedRunAsync("2099-04", "2099-05-02");
        Assert.Equal(400m, await f.LinesAsync(april, emp, "UNUSED_LEAVE"));
        Assert.Equal(0m, await f.LinesAsync(april, emp, "LEAVE_PAYOUT"));
        await f.ApproveAsync(april, "2099-05-02");
        Assert.Equal(0m, await f.Db.QuerySingleAsync<decimal>(
            "SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E", new { E = emp }, f.Tx));
    }

    /// <summary>
    /// REL-14 / LEV-8: the leave balance paid on termination is settled in the ledger at the lock, so moving
    /// the termination date into the next month never pays it again; usage dated after the termination does
    /// not count.
    /// </summary>
    [DbFact]
    public async Task ALeavePayout_IsSettledInTheLedger_AndNeverPaidTwice()
    {
        await using var f = await Fixture.OpenAsync();
        if (f is null) return;
        var emp = await f.EmployeeAsync("QA3 Payout", "2024-01-01", 2600, termination: "2099-04-30");
        var leaveType = await f.Db.QuerySingleOrDefaultAsync<int?>(
            "SELECT TOP 1 lt.LeaveTypeId FROM hr.LEAVE_TYPE lt WHERE lt.IsPaid = 1 AND EXISTS (SELECT 1 FROM hr.LEAVE_ACCRUAL_TIER t WHERE t.LeaveTypeId = lt.LeaveTypeId) ORDER BY lt.LeaveTypeId",
            transaction: f.Tx);
        if (leaveType is null) return;   // no accruing paid leave type in this database
        await f.Db.ExecuteAsync(
            """
            INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note)
            VALUES (@E, @T, '2099-01', 'Adjustment', 6, '2099-01-01', N'QA3 opening'),
                   (@E, @T, '2099-05', 'Usage', -2, '2099-05-03', N'QA3 usage after leaving');
            """, new { E = emp, T = leaveType }, f.Tx);

        var april = await f.ReviewedRunAsync("2099-04", "2099-05-02");
        Assert.Equal(600m, await f.LinesAsync(april, emp, "LEAVE_PAYOUT"));        // 6 days x 2600/26; the May usage does not count
        await f.ApproveAsync(april, "2099-05-02");
        Assert.Equal(-6m, await f.Db.QuerySingleAsync<decimal>(
            "SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E AND SourceType = 'TerminationPayout'", new { E = emp }, f.Tx));

        await f.Db.ExecuteAsync("UPDATE hr.EMPLOYEE SET TerminationDate = '2099-05-05' WHERE EmployeeId = @E", new { E = emp }, f.Tx);
        var may = await f.CreateAsync("2099-05", "2099-06-02");
        await f.GenerateAsync(may, "2099-06-02");
        Assert.Equal(0m, await f.LinesAsync(may, emp, "LEAVE_PAYOUT"));
        Assert.Equal(0m, await f.LinesAsync(may, emp, "LEAVE_DEDUCTION"));
    }

    /// <summary>
    /// Item 2 / CON-9: an LBP→USD rate of 1/89,500 survives the column and the procedure (it was stored 0.0000),
    /// and a Draft run re-reads it at Generate (REL-11): 6,000,000 LBP = 67.04 USD.
    /// </summary>
    [DbFact]
    public async Task AnLbpRateOf1Over89500_SurvivesAndPricesTheRun()
    {
        await using var f = await Fixture.OpenAsync();
        if (f is null) return;
        await f.Db.ExecuteAsync("UPDATE core.SETTING SET SettingValue = 'QA3' WHERE SettingKey = 'PayrollRateType'", transaction: f.Tx);
        var id = await f.Db.QuerySingleAsync<int>("core.usp_ExchangeRate_Add",
            new { FromCurrency = "LBP", ToCurrency = "USD", RateType = "QA3", EffectiveDate = new DateTime(2099, 1, 1), Rate = 1m / 89500m },
            f.Tx, commandType: CommandType.StoredProcedure);
        Assert.Equal(0.000011173184m, await f.Db.QuerySingleAsync<decimal>(
            "SELECT Rate FROM core.EXCHANGE_RATE WHERE ExchangeRateId = @Id", new { Id = id }, f.Tx));

        var zero = await Assert.ThrowsAsync<SqlException>(() => f.Db.ExecuteAsync("core.usp_ExchangeRate_Add",
            new { FromCurrency = "LBP", ToCurrency = "USD", RateType = "QA3", EffectiveDate = new DateTime(2099, 2, 1), Rate = 0m },
            f.Tx, commandType: CommandType.StoredProcedure));
        Assert.Contains("above zero", zero.Message);

        var emp = await f.EmployeeAsync("QA3 Lbp", "2024-01-01", 1300);
        await f.Db.ExecuteAsync(
            "INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom) VALUES (@E, (SELECT TOP 1 ComponentTypeId FROM hr.COMPONENT_TYPE WHERE IsStanding = 1 AND SystemCode IS NULL ORDER BY ComponentTypeId), 6000000, 'LBP', '2024-01-01')",
            new { E = emp }, f.Tx);
        var run = await f.CreateAsync("2099-03", "2099-04-02");
        await f.GenerateAsync(run, "2099-04-02");
        Assert.Equal(67.04m, await f.Db.QuerySingleAsync<decimal>("SELECT payroll.fn_ToPrimary(@R, 6000000, 'LBP')", new { R = run }, f.Tx));
    }

    /// <summary>PAY-10: a system component type cannot be renamed or deactivated; payroll finds it by its code.</summary>
    [DbFact]
    public async Task ASystemComponentType_CannotBeRenamedOrDeactivated()
    {
        await using var f = await Fixture.OpenAsync();
        if (f is null) return;
        var overtime = await f.Db.QuerySingleAsync<int>("SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE SystemCode = 'OVERTIME'", transaction: f.Tx);

        var rename = await Assert.ThrowsAsync<SqlException>(() => f.Db.ExecuteAsync("hr.usp_ComponentType_Update",
            new { ComponentTypeId = overtime, Name = "Overtime pay", Category = "Earning", Sign = (short)1 }, f.Tx, commandType: CommandType.StoredProcedure));
        Assert.Contains("is a system component type", rename.Message);
        var deactivate = await Assert.ThrowsAsync<SqlException>(() => f.Db.ExecuteAsync("hr.usp_ComponentType_SetActive",
            new { ComponentTypeId = overtime, IsActive = false }, f.Tx, commandType: CommandType.StoredProcedure));
        Assert.Contains("cannot be deactivated", deactivate.Message);
    }

    /// <summary>PAY-9: publishing a new NSSF version closes the previous one the day before it starts; an earlier one is refused.</summary>
    [DbFact]
    public async Task ANewNssfVersion_ClosesThePreviousOne()
    {
        await using var f = await Fixture.OpenAsync();
        if (f is null) return;
        var scheme = await f.Db.QuerySingleOrDefaultAsync<string?>(
            "SELECT TOP 1 CASE WHEN COL_LENGTH('hr.NSSF_RATE','Scheme') IS NOT NULL THEN 'Scheme' ELSE 'SchemeName' END", transaction: f.Tx);
        var previous = await f.Db.QuerySingleAsync<int>(
            $"INSERT INTO hr.NSSF_RATE ({scheme}, EmployeeRate, EmployerRate, IsCeilinged, CeilingAmount, EffectiveFrom) VALUES (N'QA3 scheme', 0.03, 0.08, 1, 2500, '2099-01-01'); SELECT CAST(SCOPE_IDENTITY() AS INT);",
            transaction: f.Tx);
        await f.Db.ExecuteAsync(
            $"INSERT INTO hr.NSSF_RATE ({scheme}, EmployeeRate, EmployerRate, IsCeilinged, CeilingAmount, EffectiveFrom) VALUES (N'QA3 scheme', 0.03, 0.08, 1, 3000, '2099-03-16')",
            transaction: f.Tx);
        Assert.Equal(new DateTime(2099, 3, 15), await f.Db.QuerySingleAsync<DateTime>(
            "SELECT EffectiveTo FROM hr.NSSF_RATE WHERE NssfRateId = @Id", new { Id = previous }, f.Tx));

        var older = await Assert.ThrowsAsync<SqlException>(() => f.Db.ExecuteAsync(
            $"INSERT INTO hr.NSSF_RATE ({scheme}, EmployeeRate, EmployerRate, IsCeilinged, CeilingAmount, EffectiveFrom) VALUES (N'QA3 scheme', 0.03, 0.08, 1, 2000, '2099-02-01')",
            transaction: f.Tx));
        Assert.Contains("A new version must start after the latest one", older.Message);
    }

    /// <summary>
    /// LEV-16 / LEV-13 / PAY-13: sick days are numbered day by day across the year by the leave type's id, so a
    /// leave crossing a month end costs each month its own days (15 full + 15 half for under two whole years).
    /// </summary>
    [DbFact]
    public async Task SickPay_IsCountedDayByDay_AcrossAMonthEnd()
    {
        await using var f = await Fixture.OpenAsync();
        if (f is null) return;
        var emp = await f.EmployeeAsync("QA3 Sick", "2098-01-15", 2600);
        var sick = await f.Db.QuerySingleAsync<int>(
            """
            INSERT INTO hr.LEAVE_TYPE (Name, IsPaid, CarryOver, IsActive) VALUES (N'QA3 tiered sick', 1, 0, 1);
            DECLARE @T INT = SCOPE_IDENTITY();
            INSERT INTO hr.LEAVE_PAY_TIER (LeaveTypeId, MinServiceYears, FullPayDays, HalfPayDays) VALUES (@T, 0, 15, 15), (@T, 2, 30, 30);
            SELECT @T;
            """, transaction: f.Tx);
        var rid = await f.ApprovedRequestAsync(emp);
        // 2099-01-20 .. 2099-02-08: 20 counted days (no roster: every day counts) - days 16..20 fall in February
        await f.Db.ExecuteAsync(
            """
            INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved)
            VALUES (@R, @E, @T, '2099-01-20', '2099-02-08', 20, 20)
            """, new { R = rid, E = emp, T = sick }, f.Tx);

        var jan = await f.CreateAsync("2099-01", "2099-02-15");
        await f.GenerateAsync(jan, "2099-02-15");
        Assert.Equal(0m, await f.LinesAsync(jan, emp, "ABSENCE"));               // January: days 1-12, full pay
        var feb = await f.CreateAsync("2099-02", "2099-03-02");
        await f.GenerateAsync(feb, "2099-03-02");
        Assert.Equal(250m, await f.LinesAsync(feb, emp, "ABSENCE"));            // February: days 16-20 at half pay = 2.5 days x 100
    }
}
