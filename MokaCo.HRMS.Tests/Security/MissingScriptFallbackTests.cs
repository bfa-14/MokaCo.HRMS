using System.Data;
using System.Reflection;
using Dapper;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Moq;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Model.Report;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Common;
using MokaCo.HRMS.Repository.HR;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.Core;
using MokaCo.HRMS.Services.Report;
using MokaCo.HRMS.Services.Security;
using MokaCo.HRMS.Tests.Attendance;

namespace MokaCo.HRMS.Tests.Security;

/// <summary>
/// AN API DEPLOYED BEFORE docs/105_qa3_security.sql: the deploy runs the code and the SQL as separate
/// manual steps, so the new sign-in, refresh, session and scope calls can meet a database without their
/// procedures (SQL error 2812) or the SessionStamp column (207). They fall back to the behaviour from
/// before the script — sign-in never stops — and one warning per process names the file to apply.
/// </summary>
public class MissingScriptFallbackTests
{
    private const string Script = "docs/105_qa3_security.sql";
    private const string RealHash = "real-hash";
    private static readonly Guid Stamp = Guid.Parse("6f9619ff-8b86-d011-b42d-00cf4fc964ff");

    /* ---- a SqlException as the server sends it (the type has no public constructor) ---- */

    private static SqlException SqlError(int number, string message)
    {
        const BindingFlags Hidden = BindingFlags.NonPublic | BindingFlags.Public | BindingFlags.Instance;
        var errorCtor = typeof(SqlError).GetConstructor(Hidden, null,
            [typeof(int), typeof(byte), typeof(byte), typeof(string), typeof(string), typeof(string), typeof(int), typeof(Exception)], null)
            ?? throw new InvalidOperationException("Microsoft.Data.SqlClient changed: no SqlError(int, byte, byte, string, string, string, int, Exception) to build a test error.");
        var error = (SqlError)errorCtor.Invoke([number, (byte)1, (byte)16, "test", message, "", 0, null]);

        var errors = (SqlErrorCollection)Activator.CreateInstance(typeof(SqlErrorCollection), nonPublic: true)!;
        typeof(SqlErrorCollection).GetMethod("Add", Hidden, null, [typeof(SqlError)], null)!.Invoke(errors, [error]);

        var create = typeof(SqlException).GetMethod("CreateException", BindingFlags.NonPublic | BindingFlags.Static, null,
            [typeof(SqlErrorCollection), typeof(string)], null)
            ?? throw new InvalidOperationException("Microsoft.Data.SqlClient changed: no SqlException.CreateException(SqlErrorCollection, string).");
        return (SqlException)create.Invoke(null, [errors, "16.00.4000"])!;
    }

    private static MissingScriptException Missing(string procedure)
        => new(Script, procedure, MissingScriptException.ProcedureNotFound,
               SqlError(MissingScriptException.ProcedureNotFound, $"Could not find stored procedure '{procedure}'."));

    /// <summary>Keeps every line it was asked to log, with its level.</summary>
    private sealed class ListLogger<T> : ILogger<T>
    {
        public List<(LogLevel Level, string Text)> Lines { get; } = [];
        public IEnumerable<string> Warnings => Lines.Where(l => l.Level == LogLevel.Warning).Select(l => l.Text);
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
            => Lines.Add((logLevel, formatter(state, exception)));
    }

    private sealed class Harness
    {
        public readonly Mock<IUserRepository> Users = new();
        public readonly Mock<IRefreshTokenRepository> Tokens = new();
        public readonly Mock<IPasswordHasher> Hasher = new();
        public readonly Mock<IJwtTokenService> Jwt = new();
        public readonly Mock<ISessionGuard> Sessions = new();
        public readonly ListLogger<MissingScriptWarning> Log = new();
        public readonly MissingScriptWarning Warning;
        public readonly AuthService Auth;
        public readonly UserService UserAdmin;
        public User? AccessTokenFor;

        public Harness(User user)
        {
            Warning = new MissingScriptWarning(Log);
            Users.Setup(u => u.GetForLoginAsync("sara")).ReturnsAsync(user);
            Users.Setup(u => u.GetByIdAsync(user.UserId)).ReturnsAsync(user);
            Users.Setup(u => u.GetPermissionsAsync(It.IsAny<int>())).ReturnsAsync(Array.Empty<PermissionDto>());
            Users.Setup(u => u.ChangePasswordAsync(user.UserId, It.IsAny<string>())).ReturnsAsync(1);
            Users.Setup(u => u.SetActiveAsync(user.UserId, It.IsAny<bool>(), It.IsAny<int>())).ReturnsAsync(1);
            Hasher.Setup(h => h.Verify("pw", RealHash)).Returns(true);
            Hasher.Setup(h => h.Hash(It.IsAny<string>())).Returns("new-hash");
            Jwt.Setup(j => j.CreateAccessToken(It.IsAny<User>(), It.IsAny<IEnumerable<string>>()))
               .Callback((User u, IEnumerable<string> _) => AccessTokenFor = new User { UserId = u.UserId, SessionStamp = u.SessionStamp })
               .Returns(("access", DateTime.UtcNow.AddMinutes(15)));
            Jwt.Setup(j => j.CreateRefreshToken()).Returns(("raw", "new-token-hash"));
            Jwt.Setup(j => j.HashRefreshToken("old-raw")).Returns("old-token-hash");
            Auth = new AuthService(Users.Object, Tokens.Object, Hasher.Object, Jwt.Object, new JwtOptions(), Warning);
            UserAdmin = new UserService(Users.Object, Hasher.Object, Sessions.Object, Warning);
        }

        public Task<AuthResult> Login() => Auth.LoginAsync(new LoginRequest { Username = "sara", Password = "pw" }, "10.0.0.1");

        /// <summary>Script 105 is not applied: none of its procedures exist.</summary>
        public void Without105()
        {
            Tokens.Setup(t => t.IssueAsync(It.IsAny<int>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<DateTime>(), It.IsAny<string?>()))
                  .ThrowsAsync(Missing("security.usp_RefreshToken_Issue"));
            Tokens.Setup(t => t.RotateAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<DateTime>(), It.IsAny<string?>()))
                  .ThrowsAsync(Missing("security.usp_RefreshToken_RotateChecked"));
            Users.Setup(u => u.EndSessionsAsync(It.IsAny<int>())).ThrowsAsync(Missing("security.usp_User_EndSessions"));
            Users.Setup(u => u.ClearLoginFailuresAsync(It.IsAny<int>())).ThrowsAsync(Missing("security.usp_User_ClearLoginFailures"));
        }
    }

    private static User Sara(bool active = true, Guid? stamp = null, int failures = 0)
        => new() { UserId = 7, Username = "sara", PasswordHash = RealHash, IsActive = active, SessionStamp = stamp, FailedLoginAttempts = failures };

    /* ---- the repository side: which SQL errors mean "the script is not applied" ---- */

    [Theory]
    [InlineData(2812, true)]     // Could not find stored procedure
    [InlineData(207, true)]      // Invalid column name (SessionStamp)
    [InlineData(208, false)]     // Invalid object name: not something 105 adds
    [InlineData(50000, false)]   // a procedure's own RAISERROR refusal
    [InlineData(1205, false)]    // deadlock victim
    public void Only_a_missing_procedure_or_column_counts_as_a_missing_script(int number, bool missing)
        => Assert.Equal(missing, MissingScriptException.IsMissingObject(number));

    [Theory]
    [InlineData(2812)]
    [InlineData(207)]
    public async Task A_missing_procedure_or_column_comes_out_as_MissingScriptException(int number)
    {
        var sql = SqlError(number, "not found");

        var thrown = await Assert.ThrowsAsync<MissingScriptException>(() =>
            MissingScriptException.GuardAsync<int>(Scripts.Security105, "security.usp_User_EndSessions", () => throw sql));
        var thrownByVoidCall = await Assert.ThrowsAsync<MissingScriptException>(() =>
            MissingScriptException.GuardAsync(Scripts.Security105, "security.usp_User_ClearLoginFailures", () => throw sql));

        Assert.Equal(Script, thrown.Script);
        Assert.Equal("security.usp_User_EndSessions", thrown.Procedure);
        Assert.Equal(number, thrown.SqlErrorNumber);
        Assert.Same(sql, thrown.InnerException);
        Assert.Equal("security.usp_User_ClearLoginFailures", thrownByVoidCall.Procedure);
    }

    /// <summary>The two numbers as a real server and this SqlClient report them (runs with the database tests).</summary>
    [DbFact]
    public async Task A_real_server_reports_a_missing_procedure_and_column_with_the_numbers_the_guard_knows()
    {
        await using var db = new SqlConnection(DbFactAttribute.ConnectionString);

        var procedure = await Assert.ThrowsAsync<MissingScriptException>(() =>
            MissingScriptException.GuardAsync(Scripts.Security105, "security.usp_QA3_NoSuchProcedure",
                () => db.ExecuteAsync("security.usp_QA3_NoSuchProcedure", commandType: CommandType.StoredProcedure)));
        var column = await Assert.ThrowsAsync<MissingScriptException>(() =>
            MissingScriptException.GuardAsync(Scripts.Security105, "security.[USER].QA3NoSuchColumn",
                () => db.QueryAsync<int>("SELECT QA3NoSuchColumn FROM security.[USER];")));

        Assert.Equal(MissingScriptException.ProcedureNotFound, procedure.SqlErrorNumber);
        Assert.Equal(MissingScriptException.InvalidColumn, column.SqlErrorNumber);
    }

    [Fact]
    public async Task Every_other_SQL_error_and_every_answer_go_through_untouched()
    {
        var refusal = SqlError(50000, "User not found.");

        var thrown = await Assert.ThrowsAsync<SqlException>(() =>
            MissingScriptException.GuardAsync<int>(Scripts.Security105, "security.usp_User_EndSessions", () => throw refusal));

        Assert.Same(refusal, thrown);
        Assert.Equal(3, await MissingScriptException.GuardAsync(Scripts.Security105, "x", () => Task.FromResult(3)));
    }

    /* ---- sign-in and refresh ---- */

    [Fact]
    public async Task Sign_in_without_105_issues_the_token_the_old_way_and_still_succeeds()
    {
        var h = new Harness(Sara());
        h.Without105();

        var result = await h.Login();

        Assert.True(result.Success);
        Assert.Equal("raw", result.Tokens!.RefreshToken);
        h.Tokens.Verify(t => t.CreateLegacyAsync(7, "new-token-hash", It.IsAny<DateTime>(), "10.0.0.1"), Times.Once());
        h.Users.Verify(u => u.RegisterLoginSuccessAsync(7), Times.Once());
        Assert.Null(h.AccessTokenFor!.SessionStamp);      // no stamp: the account has none without the column
        var warning = Assert.Single(h.Log.Warnings);
        Assert.Contains(Script, warning);
        Assert.Contains("security.usp_RefreshToken_Issue", warning);
    }

    [Fact]
    public async Task Sign_in_falls_back_only_when_the_script_is_missing()
    {
        var h = new Harness(Sara());
        h.Tokens.Setup(t => t.IssueAsync(It.IsAny<int>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<DateTime>(), It.IsAny<string?>()))
                .ThrowsAsync(SqlError(1205, "deadlock victim"));

        await Assert.ThrowsAsync<SqlException>(h.Login);

        h.Tokens.Verify(t => t.CreateLegacyAsync(It.IsAny<int>(), It.IsAny<string>(), It.IsAny<DateTime>(), It.IsAny<string?>()), Times.Never());
        h.Users.Verify(u => u.RegisterLoginSuccessAsync(It.IsAny<int>()), Times.Never());
        Assert.Empty(h.Log.Lines);
    }

    [Fact]
    public async Task With_105_applied_the_new_procedure_is_used_and_nothing_is_logged()
    {
        var h = new Harness(Sara());
        h.Tokens.Setup(t => t.IssueAsync(7, RealHash, "new-token-hash", It.IsAny<DateTime>(), "10.0.0.1"))
                .ReturnsAsync(new IssuedRefreshToken { RefreshTokenId = 1, UserId = 7, SessionStamp = Stamp });

        var result = await h.Login();

        Assert.True(result.Success);
        Assert.Equal(Stamp, h.AccessTokenFor!.SessionStamp);
        h.Tokens.Verify(t => t.CreateLegacyAsync(It.IsAny<int>(), It.IsAny<string>(), It.IsAny<DateTime>(), It.IsAny<string?>()), Times.Never());
        Assert.Empty(h.Log.Lines);
    }

    [Fact]
    public async Task Refresh_without_105_rotates_with_the_base_procedure()
    {
        var h = new Harness(Sara());
        h.Without105();
        h.Tokens.Setup(t => t.RotateLegacyAsync("old-token-hash", "new-token-hash", It.IsAny<DateTime>(), "10.0.0.2"))
                .ReturnsAsync(new IssuedRefreshToken { RefreshTokenId = 2, UserId = 7 });

        var result = await h.Auth.RefreshAsync("old-raw", "10.0.0.2");

        Assert.True(result.Success);
        Assert.Equal("raw", result.Tokens!.RefreshToken);
        Assert.Null(h.AccessTokenFor!.SessionStamp);
        Assert.Contains("security.usp_RefreshToken_RotateChecked", Assert.Single(h.Log.Warnings));
    }

    [Fact]
    public async Task Refresh_without_105_still_refuses_an_unknown_token_and_a_disabled_account()
    {
        var unknown = new Harness(Sara());
        unknown.Without105();
        unknown.Tokens.Setup(t => t.RotateLegacyAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<DateTime>(), It.IsAny<string?>()))
                      .ReturnsAsync((IssuedRefreshToken?)null);
        var disabled = new Harness(Sara(active: false));
        disabled.Without105();
        disabled.Tokens.Setup(t => t.RotateLegacyAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<DateTime>(), It.IsAny<string?>()))
                       .ReturnsAsync(new IssuedRefreshToken { RefreshTokenId = 2, UserId = 7 });

        Assert.Equal("Invalid or expired refresh token.", (await unknown.Auth.RefreshAsync("old-raw", null)).Error);
        Assert.Equal("Account is disabled.", (await disabled.Auth.RefreshAsync("old-raw", null)).Error);
        Assert.Null(disabled.AccessTokenFor);
    }

    [Fact]
    public async Task Refresh_through_the_base_procedure_keeps_whatever_stamp_the_account_has()
    {
        // A half-applied script (the column there, the procedure not): the token carries the account's own
        // stamp rather than none, so the session check does not turn it away.
        var h = new Harness(Sara(stamp: Stamp));
        h.Without105();
        h.Tokens.Setup(t => t.RotateLegacyAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<DateTime>(), It.IsAny<string?>()))
                .ReturnsAsync(new IssuedRefreshToken { RefreshTokenId = 2, UserId = 7 });

        Assert.True((await h.Auth.RefreshAsync("old-raw", null)).Success);
        Assert.Equal(Stamp, h.AccessTokenFor!.SessionStamp);
    }

    /* ---- ending sessions, signature passwords ---- */

    [Fact]
    public async Task A_password_change_without_105_still_changes_the_password()
    {
        var h = new Harness(Sara());
        h.Without105();

        var result = await h.UserAdmin.ChangePasswordAsync(7, new ChangePasswordRequest { CurrentPassword = "pw", NewPassword = "a-new-password" });

        Assert.True(result.Success);
        h.Users.Verify(u => u.ChangePasswordAsync(7, "new-hash"), Times.Once());
        h.Sessions.Verify(s => s.Forget(7), Times.Once());
        Assert.Contains("security.usp_User_EndSessions", Assert.Single(h.Log.Warnings));
    }

    [Fact]
    public async Task A_disable_without_105_still_disables_and_the_guard_reads_the_account_again()
    {
        var h = new Harness(Sara());
        h.Without105();

        await h.UserAdmin.SetActiveAsync(7, false, modifiedBy: 1);

        h.Users.Verify(u => u.SetActiveAsync(7, false, 1), Times.Once());
        h.Sessions.Verify(s => s.Forget(7), Times.Once());     // its access tokens stop: the account reads as disabled
        Assert.Single(h.Log.Warnings);
    }

    [Fact]
    public async Task A_right_signature_password_without_105_clears_the_count_with_the_login_procedure()
    {
        var h = new Harness(Sara(failures: 3));
        h.Without105();

        var verdict = await AccountPassword.CheckAsync(h.Users.Object, h.Hasher.Object, 7, "pw", h.Warning);

        Assert.Equal(PasswordVerdict.Ok, verdict);
        h.Users.Verify(u => u.RegisterLoginSuccessAsync(7), Times.Once());
        Assert.Contains("security.usp_User_ClearLoginFailures", Assert.Single(h.Log.Warnings));
    }

    /* ---- one warning ---- */

    [Fact]
    public async Task However_many_calls_fall_back_the_warning_is_logged_once()
    {
        var h = new Harness(Sara());
        h.Without105();
        h.Tokens.Setup(t => t.RotateLegacyAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<DateTime>(), It.IsAny<string?>()))
                .ReturnsAsync(new IssuedRefreshToken { RefreshTokenId = 2, UserId = 7 });

        for (var i = 0; i < 3; i++)
            Assert.True((await h.Login()).Success);
        Assert.True((await h.Auth.RefreshAsync("old-raw", null)).Success);
        Assert.True((await h.UserAdmin.ChangePasswordAsync(7, new ChangePasswordRequest { CurrentPassword = "pw", NewPassword = "a-new-password" })).Success);

        var warning = Assert.Single(h.Log.Warnings);
        Assert.StartsWith($"DATABASE SCRIPT NOT APPLIED: {Script}", warning);
        Assert.Equal(4, h.Log.Lines.Count(l => l.Level == LogLevel.Debug));
    }

    [Fact]
    public void Each_missing_script_gets_its_own_warning()
    {
        var log = new ListLogger<MissingScriptWarning>();
        var warning = new MissingScriptWarning(log);

        warning.FellBack(new MissingScriptException("docs/105_qa3_security.sql", "a", 2812), "x");
        warning.FellBack(new MissingScriptException("docs/106_other.sql", "b", 2812), "y");
        warning.FellBack(new MissingScriptException("docs/105_qa3_security.sql", "c", 207), "z");

        Assert.Equal(2, log.Warnings.Count());
    }

    /* ---- the caller scope of the summaries, punches and reports ---- */

    private static Mock<IScopeRepository> ScopeWithout105()
    {
        var scopes = new Mock<IScopeRepository>();
        scopes.Setup(s => s.CallerEmployeesAsync(It.IsAny<int>(), It.IsAny<DateTime?>(), It.IsAny<DateTime?>()))
              .ThrowsAsync(Missing("hr.usp_Scope_CallerEmployees"));
        return scopes;
    }

    [Fact]
    public async Task Without_105_the_summaries_answer_as_before_it_and_say_so_once()
    {
        var service = new Mock<IAttendanceService>();
        service.Setup(s => s.GetSummaryAllAsync("2026-08")).ReturnsAsync(new[] { new AttendanceSummary { EmployeeId = 10 }, new AttendanceSummary { EmployeeId = 99 } });
        service.Setup(s => s.GetSummaryByBranchAsync("2026-08", null)).ReturnsAsync(new[] { new AttendanceBranchSummary { EmployeeId = 99, BranchId = 2 } });
        var log = new ListLogger<MissingScriptWarning>();
        var controller = new AttendanceController(service.Object, Mock.Of<ILiveNotifier>()) { ControllerContext = TestPrincipal.For(5) };
        controller.HttpContext.RequestServices = new ServiceCollection().AddSingleton(new MissingScriptWarning(log)).BuildServiceProvider();
        var scopes = ScopeWithout105().Object;

        var all = (IEnumerable<AttendanceSummary>)Assert.IsType<OkObjectResult>(await controller.GetSummaryAll("2026-08", scopes)).Value!;
        var split = (IEnumerable<AttendanceBranchSummary>)Assert.IsType<OkObjectResult>(await controller.GetSummaryByBranch("2026-08", null, scopes)).Value!;

        Assert.Equal(new[] { 10, 99 }, all.Select(r => r.EmployeeId));
        Assert.Single(split);
        Assert.Contains("hr.usp_Scope_CallerEmployees", Assert.Single(log.Warnings));
    }

    [Fact]
    public async Task Without_105_the_punches_and_reports_answer_as_before_it()
    {
        var day = new DateTime(2026, 8, 3);
        var import = new Mock<IImportService>();
        import.Setup(s => s.GetPunchesByDateAsync(day, null, false)).ReturnsAsync(new[] { new RawPunch { RawLogId = 1, EmployeeId = 99, BranchId = 2 } });
        var reports = new Mock<IReportService>();
        reports.Setup(r => r.GetMonthlyAttendanceAsync("2026-08", null)).ReturnsAsync(new ReportResult<MonthlyAttendanceHeader, MonthlyAttendanceRow>
        {
            Header = new MonthlyAttendanceHeader(),
            Rows = { new MonthlyAttendanceRow { EmployeeId = 99 } },
        });
        var scopes = ScopeWithout105().Object;     // and no RequestServices at all: still no failure

        var punches = (IEnumerable<RawPunch>)Assert.IsType<OkObjectResult>(
            await new AttendanceIngestionController(import.Object, Mock.Of<ILiveNotifier>()) { ControllerContext = TestPrincipal.For(5) }.GetPunches(day, null, scopes)).Value!;
        var monthly = (ReportResult<MonthlyAttendanceHeader, MonthlyAttendanceRow>)Assert.IsType<OkObjectResult>(
            await new ReportsController(reports.Object) { ControllerContext = TestPrincipal.For(5) }.MonthlyAttendance("2026-08", null, scopes)).Value!;

        Assert.Single(punches);
        Assert.Single(monthly.Rows);
    }

    [Fact]
    public async Task Any_other_failure_of_the_scope_lookup_is_not_taken_for_every_row()
    {
        var service = new Mock<IAttendanceService>();
        service.Setup(s => s.GetSummaryAllAsync("2026-08")).ReturnsAsync(new[] { new AttendanceSummary { EmployeeId = 99 } });
        var scopes = new Mock<IScopeRepository>();
        scopes.Setup(s => s.CallerEmployeesAsync(It.IsAny<int>(), It.IsAny<DateTime?>(), It.IsAny<DateTime?>()))
              .ThrowsAsync(SqlError(50000, "Unknown caller."));
        var controller = new AttendanceController(service.Object, Mock.Of<ILiveNotifier>()) { ControllerContext = TestPrincipal.For(5) };

        await Assert.ThrowsAsync<SqlException>(() => controller.GetSummaryAll("2026-08", scopes.Object));
    }
}
