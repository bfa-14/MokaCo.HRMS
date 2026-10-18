using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Moq;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Services.Security.Gate;

namespace MokaCo.HRMS.Tests.Security.Gate;

/// <summary>
/// The 20-second cache every gate check reads: one database read per 20 seconds, Invalidate after an
/// admin write, the last good reading kept (with a warning) when a read fails, CLOSED before the first
/// good read, and GetFreshAsync for the turn-on guard — which throws rather than decide on old data.
/// </summary>
public class GateStateTests
{
    private sealed class ManualClock : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = new(2026, 10, 18, 9, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
        public void Advance(TimeSpan by) => Now += by;
    }

    /// <summary>Keeps the levels it was asked to log — enough to see that a failed read warns.</summary>
    private sealed class ListLogger<T> : ILogger<T>
    {
        public List<LogLevel> Levels { get; } = [];
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
            => Levels.Add(logLevel);
    }

    private sealed class Harness
    {
        public Mock<IGateRepository> Repo { get; } = new(MockBehavior.Strict);
        public ManualClock Clock { get; } = new();
        public ListLogger<GateState> Log { get; } = new();
        public GateState State { get; }
        public int Reads { get; private set; }

        public Harness()
        {
            var services = new ServiceCollection().AddScoped(_ => Repo.Object).BuildServiceProvider();
            State = new GateState(services.GetRequiredService<IServiceScopeFactory>(), Log, Clock);
        }

        public void Answers(GateStateData data)
            => Repo.Setup(r => r.GetStateAsync()).Callback(() => Reads++).ReturnsAsync(data);

        /// <summary>Every read waits for <paramref name="answer"/>: a database that has not answered yet.</summary>
        public void AnswersWhen(Task<GateStateData> answer)
            => Repo.Setup(r => r.GetStateAsync()).Returns(() => { Reads++; return answer; });

        public void Fails()
            => Repo.Setup(r => r.GetStateAsync()).Callback(() => Reads++).ThrowsAsync(new TimeoutException("SQL Server did not answer."));
    }

    private static GateStateData Data(bool required = true, string clientId = "123-abc.apps.googleusercontent.com", int days = 30, int epoch = 1,
        params (string Kind, int Id)[] allowed)
        => new()
        {
            State = new GateStateRow { Required = required, ClientId = clientId, Days = days, Epoch = epoch },
            Allowed = allowed.Select(a => new GateAllowedRow { Kind = a.Kind, PersonId = a.Id, EmailNorm = Norm(a.Kind, a.Id) }).ToList(),
        };

    /// <summary>The stored address of a test person, as the procedure would give it.</summary>
    private static string Norm(string kind, int id) => $"{kind.Trim().ToLowerInvariant()}{id}@gmail.com";

    [Fact]
    public async Task Before_the_first_good_read_the_gate_is_closed()
    {
        var h = new Harness();
        h.Fails();

        var snapshot = await h.State.CurrentAsync();

        Assert.Same(GateSnapshot.Closed, snapshot);
        Assert.True(snapshot.Required);
        Assert.Empty(snapshot.Allowed);
        Assert.Contains(LogLevel.Warning, h.Log.Levels);
    }

    [Fact]
    public async Task A_reading_is_shared_for_twenty_seconds()
    {
        var h = new Harness();
        h.Answers(Data(allowed: ("e", 12)));

        var first = await h.State.CurrentAsync();
        h.Clock.Advance(TimeSpan.FromSeconds(19));
        var second = await h.State.CurrentAsync();

        Assert.Same(first, second);
        Assert.Equal(1, h.Reads);

        h.Clock.Advance(TimeSpan.FromSeconds(1));
        await h.State.CurrentAsync();
        Assert.Equal(2, h.Reads);
    }

    /// <summary>
    /// All twenty are waiting before the database answers — the only way the lock and the second look
    /// under it are what keep it to one read (an answer that is already there would let each caller
    /// find the cache filled by the one before).
    /// </summary>
    [Fact]
    public async Task Concurrent_callers_on_a_cold_cache_share_one_read()
    {
        var h = new Harness();
        var database = new TaskCompletionSource<GateStateData>(TaskCreationOptions.RunContinuationsAsynchronously);
        h.AnswersWhen(database.Task);

        var callers = Enumerable.Range(0, 20).Select(_ => h.State.CurrentAsync()).ToList();
        Assert.All(callers, c => Assert.False(c.IsCompleted));

        database.SetResult(Data(allowed: ("e", 12)));
        var snapshots = await Task.WhenAll(callers);

        Assert.Equal(1, h.Reads);
        Assert.All(snapshots, s => Assert.Same(snapshots[0], s));
    }

    [Fact]
    public async Task Invalidate_makes_the_next_check_read_again()
    {
        var h = new Harness();
        h.Answers(Data(allowed: ("e", 12)));
        await h.State.CurrentAsync();

        h.Answers(Data(allowed: ("e", 13)));
        h.State.Invalidate();
        var after = await h.State.CurrentAsync();

        Assert.Equal(2, h.Reads);
        Assert.True(after.Allows("e", 13, Norm("e", 13)));
        Assert.False(after.Allows("e", 12, Norm("e", 12)));
    }

    [Fact]
    public async Task A_write_that_lands_during_a_read_is_not_hidden_by_it()
    {
        var h = new Harness();
        // The admin's write (and its Invalidate) happens while this read is on its way back.
        h.Repo.Setup(r => r.GetStateAsync()).Callback(() => h.State.Invalidate()).ReturnsAsync(Data(allowed: ("e", 12)));
        await h.State.CurrentAsync();

        h.Answers(Data(allowed: ("e", 13)));
        var next = await h.State.CurrentAsync();

        Assert.True(next.Allows("e", 13, Norm("e", 13)));
    }

    [Fact]
    public async Task A_failed_read_keeps_the_last_good_reading_and_warns()
    {
        var h = new Harness();
        h.Answers(Data(required: true, epoch: 7, allowed: ("x", 3)));
        var good = await h.State.CurrentAsync();

        h.Clock.Advance(TimeSpan.FromSeconds(21));
        h.Fails();
        var kept = await h.State.CurrentAsync();

        Assert.Same(good, kept);
        Assert.Equal(7, kept.Epoch);
        Assert.Contains(LogLevel.Warning, h.Log.Levels);
    }

    [Fact]
    public async Task After_a_failure_the_database_is_tried_again_after_five_seconds_not_on_every_request()
    {
        var h = new Harness();
        h.Fails();

        await h.State.CurrentAsync();
        h.Clock.Advance(TimeSpan.FromSeconds(4));
        await h.State.CurrentAsync();
        await h.State.CurrentAsync();
        Assert.Equal(1, h.Reads);

        h.Clock.Advance(TimeSpan.FromSeconds(1));
        h.Answers(Data(required: false));
        var recovered = await h.State.CurrentAsync();

        Assert.Equal(2, h.Reads);
        Assert.False(recovered.Required);
    }

    [Fact]
    public async Task GetFresh_bypasses_the_cache_and_refreshes_it()
    {
        var h = new Harness();
        h.Answers(Data(epoch: 1));
        await h.State.CurrentAsync();

        h.Answers(Data(epoch: 2));
        var fresh = await h.State.GetFreshAsync();
        var cached = await h.State.CurrentAsync();

        Assert.Equal(2, h.Reads);
        Assert.Equal(2, fresh.Epoch);
        Assert.Same(fresh, cached);
    }

    [Fact]
    public async Task GetFresh_throws_when_the_database_fails_and_the_cache_keeps_its_reading()
    {
        var h = new Harness();
        h.Answers(Data(epoch: 1));
        var good = await h.State.CurrentAsync();

        h.Fails();
        await Assert.ThrowsAsync<TimeoutException>(() => h.State.GetFreshAsync());

        Assert.Same(good, await h.State.CurrentAsync());
    }

    [Fact]
    public void The_snapshot_is_read_tidily()
    {
        var snapshot = GateSnapshot.From(Data(clientId: "  123-abc.apps.googleusercontent.com ", days: 0, allowed: [("E ", 12), ("x", 3)]));

        Assert.Equal("123-abc.apps.googleusercontent.com", snapshot.ClientId);
        Assert.Equal(1, snapshot.Days);
        Assert.True(snapshot.Allows("e", 12, Norm("e", 12)));
        Assert.True(snapshot.Allows("x", 3, Norm("x", 3)));
        Assert.False(snapshot.Allows("x", 12, Norm("e", 12)));
        Assert.False(snapshot.Allows("e", 3, Norm("x", 3)));
    }

    [Fact]
    public void A_person_is_allowed_only_with_the_address_stored_now()
    {
        var snapshot = GateSnapshot.From(Data(allowed: ("x", 3)));

        Assert.True(snapshot.Allows("x", 3, "x3@gmail.com"));
        Assert.False(snapshot.Allows("x", 3, "someone.else@gmail.com"));   // the row was given another address
        Assert.False(snapshot.Allows("x", 3, "X3@gmail.com"));             // both sides are the procedure's own text
        Assert.False(snapshot.Allows("x", 3, null));                        // a cookie made before addresses were kept
    }

    [Fact]
    public void Without_addresses_from_the_procedure_the_person_alone_decides()
    {
        // usp_Gate_GetState before it returned EmailNorm, and usp_Gate_SignIn likewise: nothing to compare.
        var data = Data(allowed: ("e", 12));
        data.Allowed[0].EmailNorm = null;
        var snapshot = GateSnapshot.From(data);

        Assert.True(snapshot.Allows("e", 12, null));
        Assert.False(snapshot.Allows("e", 12, "e12@gmail.com"));
    }

    [Fact]
    public void A_cookie_is_admitted_only_under_the_client_id_in_force()
    {
        const string clientId = "123-abc.apps.googleusercontent.com";
        var snapshot = GateSnapshot.From(Data(clientId: clientId, allowed: ("e", 12)));
        GateCookiePayload Cookie(string? aud, string? norm = "e12@gmail.com") => new("e", 12, "E12@gmail.com", norm, aud, 0, 1, 1);

        Assert.True(snapshot.Admits(Cookie(clientId)));
        Assert.False(snapshot.Admits(Cookie("999-old.apps.googleusercontent.com")));
        Assert.False(snapshot.Admits(Cookie(null)));
        Assert.False(snapshot.Admits(Cookie(clientId, norm: "e12.old@gmail.com")));
        Assert.False(GateSnapshot.Closed.Admits(Cookie(string.Empty)));
    }
}
