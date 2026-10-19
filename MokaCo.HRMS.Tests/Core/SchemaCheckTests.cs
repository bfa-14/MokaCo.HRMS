using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Moq;
using MokaCo.HRMS.Repository.Common;
using MokaCo.HRMS.Services.Core;
using MokaCo.HRMS.Tests.Attendance;

namespace MokaCo.HRMS.Tests.Core;

/// <summary>
/// QA3 DEPLOY GUARD: the API names the numbered scripts it calls that the database lacks, once per change
/// (the deploy scripts read that line), says "behind" on /health until they are applied, looks again at
/// most every 30 seconds, stops looking once all are there, and never throws. The marker list itself is
/// held to the scripts: each marker is created by its script and by no other.
/// </summary>
[Collection(DatabaseCollection.Name)]
public class SchemaCheckTests
{
    private sealed class ManualClock : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = new(2026, 10, 19, 9, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
        public void Advance(TimeSpan by) => Now += by;
    }

    private sealed class ListLogger<T> : ILogger<T>
    {
        public List<(LogLevel Level, string Message)> Lines { get; } = [];
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
            => Lines.Add((logLevel, formatter(state, exception)));
    }

    private static readonly ScriptMarker A = new("docs/98_a.sql", "hr.usp_A"), B = new("docs/99_b.sql", "hr.usp_B");

    private sealed class Harness
    {
        public Mock<ISchemaRepository> Repo { get; } = new(MockBehavior.Strict);
        public ManualClock Clock { get; } = new();
        public ListLogger<SchemaCheck> Log { get; } = new();
        public SchemaCheck Check { get; }
        public int Reads { get; private set; }

        public Harness()
        {
            var services = new ServiceCollection().AddScoped(_ => Repo.Object).BuildServiceProvider();
            Check = new SchemaCheck(services.GetRequiredService<IServiceScopeFactory>(), Log, Clock, [A, B]);
        }

        public void Missing(params ScriptMarker[] missing)
            => Repo.Setup(r => r.MissingAsync(It.IsAny<IReadOnlyList<ScriptMarker>>()))
                   .Callback(() => Reads++).ReturnsAsync(missing);

        public void Fails()
            => Repo.Setup(r => r.MissingAsync(It.IsAny<IReadOnlyList<ScriptMarker>>()))
                   .Callback(() => Reads++).ThrowsAsync(new TimeoutException("SQL Server did not answer."));

        public int Count(LogLevel level) => Log.Lines.Count(l => l.Level == level);
    }

    [Fact]
    public async Task All_scripts_applied_reads_ok_once_and_never_asks_again()
    {
        var h = new Harness();
        h.Missing();

        var first = await h.Check.CurrentAsync();
        h.Clock.Advance(TimeSpan.FromHours(5));
        var later = await h.Check.CurrentAsync();

        Assert.Equal(SchemaReading.Ok, first.Status);
        Assert.Empty(first.MissingScripts);
        Assert.Same(first, later);
        Assert.Equal(1, h.Reads);
        Assert.Equal(1, h.Count(LogLevel.Information));
        Assert.Equal(0, h.Count(LogLevel.Critical));
    }

    [Fact]
    public async Task A_missing_script_is_named_in_one_critical_line_and_reads_behind()
    {
        var h = new Harness();
        h.Missing(B);

        var reading = await h.Check.CurrentAsync();

        Assert.Equal(SchemaReading.Behind, reading.Status);
        Assert.False(reading.IsOk);
        Assert.Equal(["docs/99_b.sql"], reading.MissingScripts);
        var line = Assert.Single(h.Log.Lines, l => l.Level == LogLevel.Critical).Message;
        Assert.StartsWith("DATABASE SCRIPTS NOT APPLIED: docs/99_b.sql.", line);
    }

    [Fact]
    public async Task Behind_asks_again_after_30_seconds_not_before_and_logs_only_changes()
    {
        var h = new Harness();
        h.Missing(A, B);

        await h.Check.CurrentAsync();
        h.Clock.Advance(TimeSpan.FromSeconds(29));
        await h.Check.CurrentAsync();
        Assert.Equal(1, h.Reads);

        h.Clock.Advance(TimeSpan.FromSeconds(2));
        await h.Check.CurrentAsync();
        Assert.Equal(2, h.Reads);
        Assert.Equal(1, h.Count(LogLevel.Critical));            // the same two missing: no second line

        h.Missing(B);                                           // 98 applied meanwhile
        h.Clock.Advance(TimeSpan.FromSeconds(31));
        var one = await h.Check.CurrentAsync();
        Assert.Equal(["docs/99_b.sql"], one.MissingScripts);
        Assert.Equal(2, h.Count(LogLevel.Critical));

        h.Missing();                                            // and 99: no restart needed
        h.Clock.Advance(TimeSpan.FromSeconds(31));
        var ok = await h.Check.CurrentAsync();
        Assert.True(ok.IsOk);
        Assert.Equal(1, h.Count(LogLevel.Information));
    }

    [Fact]
    public async Task A_failed_check_reads_unknown_warns_and_is_retried_later()
    {
        var h = new Harness();
        h.Fails();

        var reading = await h.Check.CurrentAsync();
        await h.Check.CurrentAsync();

        Assert.Equal(SchemaReading.Unknown, reading.Status);
        Assert.Equal(1, h.Reads);
        Assert.Equal(1, h.Count(LogLevel.Warning));

        h.Missing();
        h.Clock.Advance(SchemaCheck.RecheckAfter);
        Assert.True((await h.Check.CurrentAsync()).IsOk);
    }

    /* ---- the list itself, against the scripts in docs/ ---- */

    private static string Docs()
    {
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d is not null; d = d.Parent)
            if (Directory.Exists(Path.Combine(d.FullName, "docs")) && File.Exists(Path.Combine(d.FullName, "MokaCo.HRMS.slnx")))
                return Path.Combine(d.FullName, "docs");
        throw new DirectoryNotFoundException("The repository's docs/ folder was not found above " + AppContext.BaseDirectory);
    }

    private static Regex Creates(string obj)
    {
        var parts = obj.Split('.');
        return new Regex($@"CREATE\s+(OR\s+ALTER\s+)?(PROCEDURE|PROC|FUNCTION|TABLE|VIEW)\s+\[?{Regex.Escape(parts[0])}\]?\.\[?{Regex.Escape(parts[1])}\]?(?![A-Za-z0-9_])",
            RegexOptions.IgnoreCase);
    }

    [Fact]
    public void Every_required_script_exists_in_apply_order_and_alone_creates_its_marker()
    {
        var docs = Docs();
        var all = Directory.GetFiles(docs, "*.sql");
        var numbers = new List<int>();

        foreach (var marker in Scripts.Required)
        {
            var file = Path.Combine(Path.GetDirectoryName(docs)!, marker.Script);
            Assert.True(File.Exists(file), $"{marker.Script} is on Scripts.Required but not in docs/.");
            numbers.Add(int.Parse(Path.GetFileName(file).Split('_')[0]));

            var creates = Creates(marker.Object);
            Assert.True(creates.IsMatch(File.ReadAllText(file)), $"{marker.Script} does not create {marker.Object}.");
            var others = all.Where(f => Path.GetFileName(f) != Path.GetFileName(file) && creates.IsMatch(File.ReadAllText(f)))
                            .Select(Path.GetFileName).ToList();
            Assert.True(others.Count == 0, $"{marker.Object} is also created by {string.Join(", ", others)}: it cannot tell whether {marker.Script} ran.");
        }

        Assert.Equal(numbers.OrderBy(n => n), numbers);
        Assert.Equal(numbers.Count, numbers.Distinct().Count());
    }

    [Fact]
    public void Every_QA3_script_in_docs_is_on_the_list()
    {
        var listed = Scripts.Required.Select(m => Path.GetFileName(m.Script)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var qa3 = Directory.GetFiles(Docs(), "*_qa3_*.sql").Select(Path.GetFileName).ToList();

        Assert.NotEmpty(qa3);
        Assert.All(qa3, f => Assert.True(listed.Contains(f!), $"docs/{f} is not on Scripts.Required: the deploy guard would not notice it missing."));
    }

    /* ---- the repository, against a real database when there is one ---- */

    private sealed class Factory(string cs) : IDbConnectionFactory
    {
        public System.Data.IDbConnection Create() => new SqlConnection(cs);
    }

    [DbFact]
    public async Task The_repository_finds_what_exists_and_misses_what_does_not()
    {
        var repo = new SchemaRepository(new Factory(DbFactAttribute.ConnectionString));
        var there = new ScriptMarker("docs/core.sql", "hr.EMPLOYEE");
        var absent = new ScriptMarker("docs/999_never.sql", "dbo.usp_QA3_NoSuchProcedure");

        var missing = await repo.MissingAsync([there, absent]);

        Assert.Equal([absent], missing);
    }
}
