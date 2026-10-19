using Dapper;

namespace MokaCo.HRMS.Repository.Common;

/// <summary>Which numbered scripts are not applied to this database (<see cref="Scripts.Required"/>).</summary>
public interface ISchemaRepository
{
    /// <summary>The markers whose object does not exist in this database, in the order given.</summary>
    Task<IReadOnlyList<ScriptMarker>> MissingAsync(IReadOnlyList<ScriptMarker> markers);
}

/// <summary>
/// Plain OBJECT_ID reads, not a procedure: the check must work on a database that has none of the
/// scripts it looks for.
/// </summary>
public class SchemaRepository : ISchemaRepository
{
    private readonly IDbConnectionFactory _factory;
    public SchemaRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IReadOnlyList<ScriptMarker>> MissingAsync(IReadOnlyList<ScriptMarker> markers)
    {
        using var db = _factory.Create();
        var missing = new List<ScriptMarker>();
        foreach (var marker in markers)
            if (await db.ExecuteScalarAsync<int?>("SELECT OBJECT_ID(@Name);", new { Name = marker.Object }) is null)
                missing.Add(marker);
        return missing;
    }
}
