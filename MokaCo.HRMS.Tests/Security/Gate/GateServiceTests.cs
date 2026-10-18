using Moq;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.Security.Gate;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Security.Gate;

/// <summary>
/// The service of §3 against STRICT mocks of the repository, the state and Google: the check (a cookie
/// passes only while its person is allowed now, with the same address, under the same client ID), each
/// sign-in outcome as its status and sentence, the no-lock-out guards — on turning the gate on, on the
/// client ID, and on the admin writes that could shut out this browser — and "sign everyone out"
/// keeping the caller in.
/// </summary>
public class GateServiceTests
{
    private const int Caller = 20;
    private const string Secret = "production-jwt-secret-0123456789-abcdef";
    private const string ClientId = "123456789-abcdef.apps.googleusercontent.com";
    private const string Email = "Rana.Haddad@gmail.com";

    /// <summary>The address the procedures hold for every test person (one Gmail is enough here).</summary>
    private const string Norm = "ranahaddad@gmail.com";
    private const string OldClientId = "999-old.apps.googleusercontent.com";

    private static readonly DateTimeOffset Now = new(2026, 10, 18, 9, 0, 0, TimeSpan.Zero);
    private static readonly byte[] Key = GateCookie.DeriveKey(Secret);

    private sealed class FixedClock(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }

    private static GateSnapshot Snapshot(bool required = true, string clientId = ClientId, int days = 30, int epoch = 4,
        params (string Kind, int Id)[] allowed)
        => new(required, clientId, days, epoch, allowed.ToDictionary(a => a, _ => (string?)Norm));

    private static readonly GateSnapshot On = Snapshot(allowed: [("e", 12), ("x", 3)]);

    /// <summary>A cookie this service would accept: issued an hour ago for 30 days, epoch 4, made with <see cref="ClientId"/>.</summary>
    private static string Cookie(string kind = "e", int id = 12, int epoch = 4, int days = 30, TimeSpan? age = null,
        string? norm = Norm, string clientId = ClientId)
        => GateCookie.Issue(
            GateCookie.Create(kind, id, Email, norm, clientId, (Now - (age ?? TimeSpan.FromHours(1))).ToUnixTimeSeconds(), days, epoch), Key);

    private sealed class Harness
    {
        public Mock<IGateRepository> Repo { get; } = new(MockBehavior.Strict);
        public Mock<IGateState> State { get; } = new(MockBehavior.Strict);
        public Mock<IGoogleTokenValidator> Google { get; } = new(MockBehavior.Strict);
        public GateService Service { get; }
        public int Invalidations { get; private set; }

        public Harness(GateSnapshot? current = null, GateSnapshot? fresh = null)
        {
            State.Setup(s => s.CurrentAsync(It.IsAny<CancellationToken>())).ReturnsAsync(current ?? On);
            State.Setup(s => s.GetFreshAsync(It.IsAny<CancellationToken>())).ReturnsAsync(fresh ?? current ?? On);
            State.Setup(s => s.Invalidate()).Callback(() => Invalidations++);
            Service = new GateService(Repo.Object, State.Object, Google.Object, new JwtOptions { SecretKey = Secret }, new FixedClock(Now));
        }

        public void GoogleSays(GoogleTokenResult result)
            => Google.Setup(g => g.ValidateAsync("the-credential", ClientId, It.IsAny<CancellationToken>())).ReturnsAsync(result);

        public void SqlSays(string outcome, string? kind = null, int? personId = null, string? displayName = null, string? emailNorm = null)
            => Repo.Setup(r => r.SignInAsync(Email, "sub-1", It.IsAny<string?>(), It.IsAny<string?>()))
                .ReturnsAsync(new GateSignInRow
                {
                    Outcome = outcome, Kind = kind, PersonId = personId, DisplayName = displayName,
                    EmailNorm = emailNorm ?? (outcome == GateSignInOutcome.Allowed ? Norm : null),
                });
    }

    private static readonly GoogleTokenResult GoogleOk = GoogleTokenResult.Ok(Email, "sub-1", "Rana H.");

    /* ---- the check ---- */

    [Fact]
    public async Task Off_lets_everyone_through_cookie_or_not()
    {
        var h = new Harness(Snapshot(required: false));

        Assert.True(await h.Service.IsAllowedAsync(null));
        Assert.True(await h.Service.IsAllowedAsync("garbage"));
    }

    [Fact]
    public async Task On_a_valid_cookie_of_an_allowed_person_passes()
    {
        var h = new Harness();

        Assert.True(await h.Service.IsAllowedAsync(Cookie("e", 12)));
        Assert.True(await h.Service.IsAllowedAsync(Cookie("x", 3)));
    }

    [Fact]
    public async Task On_a_valid_cookie_whose_person_is_no_longer_allowed_is_refused()
    {
        var h = new Harness();

        Assert.False(await h.Service.IsAllowedAsync(Cookie("e", 13)));
        Assert.False(await h.Service.IsAllowedAsync(Cookie("x", 12)));
    }

    [Fact]
    public async Task On_no_cookie_an_old_epoch_or_a_foreign_key_is_refused()
    {
        var h = new Harness();
        var foreign = GateCookie.Issue(GateCookie.Create("e", 12, Email, Norm, ClientId, Now.ToUnixTimeSeconds(), 30, 4), GateCookie.DeriveKey("test-api-secret"));

        Assert.False(await h.Service.IsAllowedAsync(null));
        Assert.False(await h.Service.IsAllowedAsync(Cookie(epoch: 3)));
        Assert.False(await h.Service.IsAllowedAsync(foreign));
        Assert.False(await h.Service.IsAllowedAsync(Cookie(age: TimeSpan.FromDays(31))));
    }

    [Fact]
    public async Task On_a_cookie_for_an_address_its_person_no_longer_has_is_refused()
    {
        // The admin gave extra address 3 to the new accountant, or HR corrected employee 12's Gmail.
        var h = new Harness();

        Assert.False(await h.Service.IsAllowedAsync(Cookie("x", 3, norm: "old.accountant@gmail.com")));
        Assert.False(await h.Service.IsAllowedAsync(Cookie("e", 12, norm: null)));
        Assert.True(await h.Service.IsAllowedAsync(Cookie("x", 3)));
    }

    [Fact]
    public async Task On_a_cookie_made_with_another_client_id_is_refused()
        => Assert.False(await new Harness().Service.IsAllowedAsync(Cookie(clientId: OldClientId)));

    [Fact]
    public async Task Closed_refuses_every_cookie()
    {
        var h = new Harness(GateSnapshot.Closed);
        Assert.False(await h.Service.IsAllowedAsync(Cookie(epoch: 0)));
    }

    /* ---- config ---- */

    [Fact]
    public async Task Config_says_signed_in_with_the_email_when_the_cookie_passes()
    {
        var h = new Harness();

        var config = await h.Service.GetConfigAsync(Cookie());

        Assert.True(config.Required);
        Assert.Equal(ClientId, config.ClientId);
        Assert.Equal(30, config.Days);
        Assert.True(config.SignedIn);
        Assert.Equal(Email, config.Email);
        Assert.Null(config.Name);
    }

    [Fact]
    public async Task Config_without_a_client_id_says_null_and_not_signed_in()
    {
        var h = new Harness(Snapshot(required: false, clientId: ""));

        var config = await h.Service.GetConfigAsync(null);

        Assert.False(config.Required);
        Assert.Null(config.ClientId);
        Assert.False(config.SignedIn);
        Assert.Null(config.Email);
    }

    [Fact]
    public async Task Config_does_not_call_a_blocked_persons_cookie_signed_in()
        => Assert.False((await new Harness().Service.GetConfigAsync(Cookie("e", 13))).SignedIn);

    /* ---- sign-in ---- */

    [Fact]
    public async Task Without_a_client_id_sign_in_is_503_not_set_up_and_google_is_not_asked()
    {
        var h = new Harness(Snapshot(clientId: ""));

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => h.Service.SignInAsync("the-credential", "1.2.3.4", "ua"));

        Assert.Equal((503, "Google sign-in is not set up yet. Ask the administrator."), (ex.StatusCode, ex.Message));
    }

    [Theory]
    [InlineData(GoogleTokenStatus.Invalid, 400, "Google could not confirm this sign-in — try again.")]
    [InlineData(GoogleTokenStatus.Unverified, 403, "This Google account's email is not verified.")]
    [InlineData(GoogleTokenStatus.Unreachable, 503, "Google could not be reached — try again in a minute.")]
    public async Task What_Google_says_becomes_a_status_and_a_sentence_and_nothing_is_logged(GoogleTokenStatus status, int code, string sentence)
    {
        var h = new Harness();
        h.GoogleSays(new GoogleTokenResult(status));

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => h.Service.SignInAsync("the-credential", "1.2.3.4", "ua"));

        Assert.Equal((code, sentence), (ex.StatusCode, ex.Message));
        h.Repo.VerifyNoOtherCalls();
    }

    [Theory]
    [InlineData(GateSignInOutcome.NotFound, "Rana.Haddad@gmail.com is not on the HRMS list. Ask the administrator to put this Gmail on your employee record.")]
    [InlineData(GateSignInOutcome.Blocked, "Google sign-in is switched off for Rana.Haddad@gmail.com. Ask the administrator.")]
    [InlineData(GateSignInOutcome.NoUser, "Rana.Haddad@gmail.com belongs to an employee without an active HRMS login. Ask the administrator.")]
    [InlineData(GateSignInOutcome.Left, "Rana.Haddad@gmail.com belongs to an employee who has left.")]
    public async Task Each_refused_outcome_is_a_403_naming_the_email(string outcome, string sentence)
    {
        var h = new Harness();
        h.GoogleSays(GoogleOk);
        h.SqlSays(outcome);

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => h.Service.SignInAsync("the-credential", "1.2.3.4", "ua"));

        Assert.Equal((403, sentence), (ex.StatusCode, ex.Message));
        Assert.Equal(0, h.Invalidations);
    }

    [Fact]
    public async Task Allowed_gets_a_cookie_valid_now_for_the_procedures_person()
    {
        var h = new Harness();
        h.GoogleSays(GoogleOk);
        h.SqlSays(GateSignInOutcome.Allowed, "e", 12, "Rana Haddad");

        var result = await h.Service.SignInAsync("the-credential", "1.2.3.4", "Mozilla/5.0");

        Assert.Equal(Email, result.Email);
        Assert.Equal("Rana Haddad", result.Name);
        Assert.Equal(30, result.Days);
        Assert.True(GateCookie.TryRead(result.CookieValue, Key, Now.ToUnixTimeSeconds(), 30, 4, out var payload));
        Assert.Equal(("e", 12, Email), (payload.Kind, payload.PersonId, payload.Email));
        Assert.Equal((Norm, ClientId), (payload.EmailNorm, payload.ClientId));
        Assert.Equal(Now.ToUnixTimeSeconds() + 30 * 86400, payload.ExpiresAt);
        Assert.Equal(0, h.Invalidations);
        Assert.True(await h.Service.IsAllowedAsync(result.CookieValue));
    }

    [Fact]
    public async Task Allowed_but_not_yet_in_the_cached_list_reads_the_list_again()
    {
        var h = new Harness();
        h.GoogleSays(GoogleOk);
        h.SqlSays(GateSignInOutcome.Allowed, "x", 9, "Owner");

        await h.Service.SignInAsync("the-credential", null, null);

        Assert.Equal(1, h.Invalidations);
    }

    [Fact]
    public async Task Allowed_with_an_address_the_cached_list_does_not_have_yet_reads_the_list_again()
    {
        // HR corrected the Gmail a second ago; the cache still holds the old one.
        var h = new Harness();
        h.GoogleSays(GoogleOk);
        h.SqlSays(GateSignInOutcome.Allowed, "e", 12, "Rana Haddad", emailNorm: "rana.new@gmail.com");

        await h.Service.SignInAsync("the-credential", null, null);

        Assert.Equal(1, h.Invalidations);
    }

    [Fact]
    public async Task Sign_in_works_with_the_gate_off_for_Test_Google_sign_in()
    {
        var h = new Harness(Snapshot(required: false, allowed: ("e", 12)));
        h.GoogleSays(GoogleOk);
        h.SqlSays(GateSignInOutcome.Allowed, "e", 12, "Rana Haddad");

        var result = await h.Service.SignInAsync("the-credential", null, null);

        Assert.NotEmpty(result.CookieValue);
    }

    [Fact]
    public async Task The_log_gets_the_sub_ip_and_user_agent_cut_to_their_columns()
    {
        var h = new Harness();
        h.GoogleSays(GoogleOk);
        string? ip = null, agent = null;
        h.Repo.Setup(r => r.SignInAsync(Email, "sub-1", It.IsAny<string?>(), It.IsAny<string?>()))
            .Callback<string, string?, string?, string?>((_, _, i, a) => (ip, agent) = (i, a))
            .ReturnsAsync(new GateSignInRow { Outcome = GateSignInOutcome.NotFound });

        await Assert.ThrowsAsync<WorkflowException>(() => h.Service.SignInAsync("the-credential", new string('1', 60), new string('M', 400)));

        Assert.Equal(45, ip!.Length);
        Assert.Equal(300, agent!.Length);
    }

    [Fact]
    public async Task An_outcome_the_service_does_not_know_never_gets_a_cookie()
    {
        var h = new Harness();
        h.GoogleSays(GoogleOk);
        h.SqlSays("Maybe", "e", 12);

        await Assert.ThrowsAsync<InvalidOperationException>(() => h.Service.SignInAsync("the-credential", null, null));
    }

    /* ---- the turn-on guard ---- */

    private static GateSettingsRequest TurnOn(string? clientId = ClientId, int days = 30) => new() { Required = true, ClientId = clientId, Days = days };

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public async Task Turning_on_without_a_client_id_is_a_400_before_anything_else(string? clientId)
    {
        var h = new Harness();

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => h.Service.SaveSettingsAsync(TurnOn(clientId), Cookie(), Caller));

        Assert.Equal((400, "Enter the Google client ID before turning Google sign-in on."), (ex.StatusCode, ex.Message));
        h.State.Verify(s => s.GetFreshAsync(It.IsAny<CancellationToken>()), Times.Never);
        h.Repo.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Turning_on_from_a_browser_that_has_not_signed_in_with_Google_is_a_409()
    {
        var h = new Harness();

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => h.Service.SaveSettingsAsync(TurnOn(), null, Caller));

        Assert.Equal(409, ex.StatusCode);
        Assert.Equal("Sign in with Google in this browser first (Test Google sign-in), so turning this on can't lock you out.", ex.Message);
        h.Repo.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Turning_on_with_a_cookie_of_a_person_no_longer_allowed_is_a_409_judged_on_a_fresh_reading()
    {
        // The cache still lists employee 12; the fresh reading (they were blocked a second ago) does not.
        var h = new Harness(current: On, fresh: Snapshot(allowed: ("x", 3)));

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => h.Service.SaveSettingsAsync(TurnOn(), Cookie("e", 12), Caller));

        Assert.Equal(409, ex.StatusCode);
        h.State.Verify(s => s.GetFreshAsync(It.IsAny<CancellationToken>()), Times.Once);
        h.Repo.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Turning_on_with_fewer_days_than_the_callers_cookie_has_lived_is_a_409()
    {
        var h = new Harness();

        var ex = await Assert.ThrowsAsync<WorkflowException>(() =>
            h.Service.SaveSettingsAsync(TurnOn(days: 2), Cookie(age: TimeSpan.FromDays(3)), Caller));

        Assert.Equal(409, ex.StatusCode);
        h.Repo.VerifyNoOtherCalls();
    }

    [Theory]
    [InlineData(0)]
    [InlineData(366)]
    public async Task Turning_on_with_days_out_of_range_is_the_procedures_400(int days)
    {
        var h = new Harness();

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => h.Service.SaveSettingsAsync(TurnOn(days: days), Cookie(), Caller));

        Assert.Equal((400, "Keep a Google sign-in between 1 and 365 days."), (ex.StatusCode, ex.Message));
    }

    [Fact]
    public async Task Turning_on_from_a_verified_browser_saves_and_invalidates()
    {
        var h = new Harness();
        h.Repo.Setup(r => r.SaveSettingsAsync(true, ClientId, 30, Caller)).Returns(Task.CompletedTask);

        await h.Service.SaveSettingsAsync(TurnOn(clientId: "  " + ClientId + " "), Cookie(), Caller);

        h.Repo.Verify(r => r.SaveSettingsAsync(true, ClientId, 30, Caller), Times.Once);
        Assert.Equal(1, h.Invalidations);
    }

    [Fact]
    public async Task A_new_client_id_with_the_switch_on_is_a_409_and_nothing_is_saved()
    {
        var h = new Harness();

        var ex = await Assert.ThrowsAsync<WorkflowException>(() =>
            h.Service.SaveSettingsAsync(TurnOn(clientId: "777-typo.apps.googleusercontent.com"), Cookie(), Caller));

        Assert.Equal((409, "Turn Google sign-in off to change the client ID."), (ex.StatusCode, ex.Message));
        h.Repo.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Turning_on_with_a_client_id_not_saved_yet_is_a_409()
    {
        var h = new Harness(Snapshot(required: false, allowed: [("e", 12)]));

        var ex = await Assert.ThrowsAsync<WorkflowException>(() =>
            h.Service.SaveSettingsAsync(TurnOn(clientId: "777-new.apps.googleusercontent.com"), Cookie(), Caller));

        Assert.Equal((409, "Save the new client ID first, then test Google sign-in with it."), (ex.StatusCode, ex.Message));
        h.Repo.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Turning_on_after_a_new_client_id_needs_a_sign_in_made_with_it()
    {
        // The ID was changed with the switch off; this browser's cookie was made with the old one.
        var h = new Harness(Snapshot(required: false, allowed: [("e", 12)]));

        var ex = await Assert.ThrowsAsync<WorkflowException>(() =>
            h.Service.SaveSettingsAsync(TurnOn(), Cookie(clientId: OldClientId), Caller));

        Assert.Equal((409, GateService.VerifyFirst), (ex.StatusCode, ex.Message));
        h.Repo.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Saving_with_the_switch_on_and_the_same_client_id_is_fine()
    {
        var h = new Harness();
        h.Repo.Setup(r => r.SaveSettingsAsync(true, ClientId, 14, Caller)).Returns(Task.CompletedTask);

        await h.Service.SaveSettingsAsync(TurnOn(days: 14), Cookie(), Caller);

        h.Repo.Verify(r => r.SaveSettingsAsync(true, ClientId, 14, Caller), Times.Once);
    }

    [Fact]
    public async Task A_new_client_id_with_the_switch_off_is_saved_without_a_cookie()
    {
        var h = new Harness(Snapshot(required: false));
        h.Repo.Setup(r => r.SaveSettingsAsync(false, "777-new.apps.googleusercontent.com", 30, Caller)).Returns(Task.CompletedTask);

        await h.Service.SaveSettingsAsync(
            new GateSettingsRequest { Required = false, ClientId = "777-new.apps.googleusercontent.com", Days = 30 }, null, Caller);

        Assert.Equal(1, h.Invalidations);
    }

    [Fact]
    public async Task Turning_off_needs_no_cookie()
    {
        var h = new Harness();
        h.Repo.Setup(r => r.SaveSettingsAsync(false, "", 30, Caller)).Returns(Task.CompletedTask);

        await h.Service.SaveSettingsAsync(new GateSettingsRequest { Required = false, ClientId = null, Days = 30 }, null, Caller);

        h.State.Verify(s => s.GetFreshAsync(It.IsAny<CancellationToken>()), Times.Never);
        Assert.Equal(1, h.Invalidations);
    }

    /// <summary>The procedures' refusals keep their sentence and arrive as 400s (WorkflowSqlErrors).</summary>
    [Theory]
    [InlineData("That is not a Google client ID — it ends with .apps.googleusercontent.com.")]
    [InlineData("You can't block yourself — you would lose access.")]
    [InlineData("Employee not found.")]
    [InlineData("Enter a full Google email address.")]
    [InlineData("This Gmail is already on the list.")]
    [InlineData("That address is not on the list.")]
    public void The_procedures_sentences_are_400s(string sentence)
        => Assert.Equal((400, sentence), (WorkflowSqlErrors.MapMessage(sentence).StatusCode, WorkflowSqlErrors.MapMessage(sentence).Message));

    /* ---- the other admin writes ---- */

    [Fact]
    public async Task Blocking_saves_and_invalidates()
    {
        var h = new Harness();
        h.Repo.Setup(r => r.SetBlockedAsync(12, true, Caller)).Returns(Task.CompletedTask);

        await h.Service.SetBlockedAsync(12, true, null, Caller);

        Assert.Equal(1, h.Invalidations);
    }

    [Fact]
    public async Task Blocking_the_employee_this_browser_passes_as_is_a_409()
    {
        // Their HRMS login may be another employee's (or none): the procedure's own check cannot see this.
        var h = new Harness();

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => h.Service.SetBlockedAsync(12, true, Cookie("e", 12), Caller));

        Assert.Equal((409, "You can't block yourself — you would lose access."), (ex.StatusCode, ex.Message));
        h.State.Verify(s => s.GetFreshAsync(It.IsAny<CancellationToken>()), Times.Once);
        h.Repo.VerifyNoOtherCalls();
        Assert.Equal(0, h.Invalidations);
    }

    [Fact]
    public async Task Blocking_someone_else_unblocking_yourself_or_blocking_with_the_gate_off_goes_through()
    {
        var h = new Harness();
        h.Repo.Setup(r => r.SetBlockedAsync(It.IsAny<int>(), It.IsAny<bool>(), Caller)).Returns(Task.CompletedTask);
        var off = new Harness(Snapshot(required: false, allowed: [("e", 12)]));
        off.Repo.Setup(r => r.SetBlockedAsync(12, true, Caller)).Returns(Task.CompletedTask);

        await h.Service.SetBlockedAsync(13, true, Cookie("e", 12), Caller);
        await h.Service.SetBlockedAsync(12, false, Cookie("e", 12), Caller);
        await h.Service.SetBlockedAsync(3, true, Cookie("x", 3), Caller);     // an employee id, not the extra address
        await off.Service.SetBlockedAsync(12, true, Cookie("e", 12), Caller);

        Assert.Equal(3, h.Invalidations);
        Assert.Equal(1, off.Invalidations);
    }

    [Fact]
    public async Task A_new_extra_address_is_active_trimmed_and_invalidates()
    {
        var h = new Harness();
        h.Repo.Setup(r => r.SaveExtraEmailAsync(null, "owner@gmail.com", null, true, Caller)).ReturnsAsync(5);

        var id = await h.Service.AddExtraEmailAsync(new GateExtraEmailRequest { Email = " owner@gmail.com ", Note = "  ", IsActive = false }, Caller);

        Assert.Equal(5, id);
        Assert.Equal(1, h.Invalidations);
    }

    [Fact]
    public async Task Editing_and_removing_an_extra_address_invalidates()
    {
        var h = new Harness();
        h.Repo.Setup(r => r.SaveExtraEmailAsync(5, "owner@gmail.com", "Owner", false, Caller)).ReturnsAsync(5);
        h.Repo.Setup(r => r.DeleteExtraEmailAsync(5, Caller)).Returns(Task.CompletedTask);

        await h.Service.UpdateExtraEmailAsync(5, new GateExtraEmailRequest { Email = "owner@gmail.com", Note = "Owner", IsActive = false }, Cookie("x", 3), Caller);
        await h.Service.DeleteExtraEmailAsync(5, Cookie("x", 3), Caller);

        Assert.Equal(2, h.Invalidations);
    }

    /// <summary>The owner and the accountant pass through their extra address: switching it off, giving it another Gmail or removing it would shut them out.</summary>
    public static TheoryData<string?, bool, string> OwnAddressEdits() => new()
    {
        { "ranahaddad@gmail.com", false, "You can't switch off the address you signed in with — you would lose access." },
        { "new.accountant@gmail.com", true, "You can't change the address you signed in with — you would lose access." },
        { "", true, "You can't change the address you signed in with — you would lose access." },
        { null, true, "You can't change the address you signed in with — you would lose access." },
    };

    [Theory]
    [MemberData(nameof(OwnAddressEdits))]
    public async Task Switching_off_or_readdressing_the_extra_address_this_browser_passes_with_is_a_409(string? email, bool active, string sentence)
    {
        var h = new Harness();

        var ex = await Assert.ThrowsAsync<WorkflowException>(() =>
            h.Service.UpdateExtraEmailAsync(3, new GateExtraEmailRequest { Email = email, Note = "Owner", IsActive = active }, Cookie("x", 3), Caller));

        Assert.Equal((409, sentence), (ex.StatusCode, ex.Message));
        h.State.Verify(s => s.GetFreshAsync(It.IsAny<CancellationToken>()), Times.Once);
        h.Repo.VerifyNoOtherCalls();
        Assert.Equal(0, h.Invalidations);
    }

    [Fact]
    public async Task Removing_the_extra_address_this_browser_passes_with_is_a_409()
    {
        var h = new Harness();

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => h.Service.DeleteExtraEmailAsync(3, Cookie("x", 3), Caller));

        Assert.Equal((409, "You can't remove the address you signed in with — you would lose access."), (ex.StatusCode, ex.Message));
        h.Repo.VerifyNoOtherCalls();
    }

    [Theory]
    [InlineData("ranahaddad@gmail.com")]
    [InlineData(" Rana.Haddad+hrms@GoogleMail.com ")]   // the same Google account, spelled another way
    public async Task The_note_or_the_spelling_of_your_own_address_can_change(string email)
    {
        var h = new Harness();
        h.Repo.Setup(r => r.SaveExtraEmailAsync(3, email.Trim(), "Owner (Moka)", true, Caller)).ReturnsAsync(3);

        await h.Service.UpdateExtraEmailAsync(3, new GateExtraEmailRequest { Email = email, Note = "Owner (Moka)", IsActive = true }, Cookie("x", 3), Caller);

        Assert.Equal(1, h.Invalidations);
    }

    [Fact]
    public async Task Without_the_gate_on_or_a_cookie_for_that_address_the_extra_address_changes_freely()
    {
        var off = new Harness(Snapshot(required: false, allowed: [("x", 3)]));
        off.Repo.Setup(r => r.SaveExtraEmailAsync(3, "someone@gmail.com", null, false, Caller)).ReturnsAsync(3);
        off.Repo.Setup(r => r.DeleteExtraEmailAsync(3, Caller)).Returns(Task.CompletedTask);
        var on = new Harness();
        on.Repo.Setup(r => r.SaveExtraEmailAsync(3, "someone@gmail.com", null, false, Caller)).ReturnsAsync(3);
        on.Repo.Setup(r => r.DeleteExtraEmailAsync(3, Caller)).Returns(Task.CompletedTask);
        var request = new GateExtraEmailRequest { Email = "someone@gmail.com", IsActive = false };

        await off.Service.UpdateExtraEmailAsync(3, request, Cookie("x", 3), Caller);
        await off.Service.DeleteExtraEmailAsync(3, Cookie("x", 3), Caller);
        await on.Service.UpdateExtraEmailAsync(3, request, Cookie("e", 12), Caller);       // this browser is employee 12
        await on.Service.UpdateExtraEmailAsync(3, request, null, Caller);                  // nobody in this browser
        await on.Service.DeleteExtraEmailAsync(3, Cookie("x", 3, epoch: 3), Caller);      // a cookie that no longer passes

        Assert.Equal(2, off.Invalidations);
        Assert.Equal(3, on.Invalidations);
    }

    /* ---- sign everyone out ---- */

    [Fact]
    public async Task Sign_everyone_out_reissues_the_callers_cookie_with_the_new_epoch()
    {
        var h = new Harness();
        h.Repo.Setup(r => r.SignOutEveryoneAsync(Caller)).ReturnsAsync(5);

        var result = await h.Service.SignOutEveryoneAsync(Cookie("e", 12, epoch: 4), Caller);

        Assert.Equal(5, result.Epoch);
        Assert.Equal(1, h.Invalidations);
        var now = Now.ToUnixTimeSeconds();
        Assert.True(GateCookie.TryRead(result.CookieValue, Key, now, 30, 5, out var payload));
        Assert.Equal(("e", 12, Norm, ClientId), (payload.Kind, payload.PersonId, payload.EmailNorm, payload.ClientId));
        Assert.False(GateCookie.TryRead(result.CookieValue, Key, now, 30, 4, out _));
    }

    [Fact]
    public async Task Sign_everyone_out_gives_no_cookie_to_a_caller_who_had_none_valid()
    {
        var h = new Harness();
        h.Repo.Setup(r => r.SignOutEveryoneAsync(Caller)).ReturnsAsync(5);

        Assert.Null((await h.Service.SignOutEveryoneAsync(null, Caller)).CookieValue);
        Assert.Null((await h.Service.SignOutEveryoneAsync(Cookie("e", 13), Caller)).CookieValue);
    }

    /* ---- the admin view ---- */

    private static GateAdminData AdminData() => new()
    {
        Settings = new GateAdminSettings { Required = true, ClientId = ClientId, Days = 30, Epoch = 4 },
        People = [new GatePersonRow { EmployeeId = 12, FullName = "Rana Haddad", Status = "Allowed" }],
        Extras =
        [
            new GateExtraEmailRow { GateExtraEmailId = 3, Email = "owner@gmail.com", Note = "Owner", IsActive = true },
            new GateExtraEmailRow { GateExtraEmailId = 4, Email = "accounts@gmail.com", Note = " ", IsActive = true },
        ],
    };

    [Theory]
    [InlineData("e", 12, "Rana Haddad")]
    [InlineData("x", 3, "Owner")]
    [InlineData("x", 4, "accounts@gmail.com")]
    public async Task The_admin_view_names_the_verified_caller(string kind, int id, string name)
    {
        var h = new Harness(fresh: Snapshot(allowed: [("e", 12), ("x", 3), ("x", 4)]));
        h.Repo.Setup(r => r.GetAdminAsync(Caller)).ReturnsAsync(AdminData());

        var view = await h.Service.GetAdminAsync(Cookie(kind, id), Caller);

        Assert.True(view.Caller.Verified);
        Assert.Equal(Email, view.Caller.Email);
        Assert.Equal(name, view.Caller.Name);
        Assert.Single(view.People);
        Assert.Equal(2, view.Extras.Count);
    }

    [Fact]
    public async Task The_admin_view_says_not_verified_without_a_valid_cookie()
    {
        var h = new Harness();
        h.Repo.Setup(r => r.GetAdminAsync(Caller)).ReturnsAsync(AdminData());

        var view = await h.Service.GetAdminAsync(Cookie(epoch: 3), Caller);

        Assert.False(view.Caller.Verified);
        Assert.Null(view.Caller.Email);
        Assert.Null(view.Caller.Name);
        h.State.Verify(s => s.GetFreshAsync(It.IsAny<CancellationToken>()), Times.Once);
    }
}
