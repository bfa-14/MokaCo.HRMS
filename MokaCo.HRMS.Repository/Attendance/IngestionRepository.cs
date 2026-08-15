using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Attendance;

/// <summary>
/// Dapper access for raw punch ingestion and Excel import batches, via attendance.usp_RawLog_* and
/// attendance.usp_ImportBatch_*.
/// </summary>
public class IngestionRepository : IIngestionRepository
{
    private readonly IDbConnectionFactory _factory;
    public IngestionRepository(IDbConnectionFactory factory) => _factory = factory;

    /// <summary>
    /// Lands ONE punch. Idempotent on DedupHash: a punch already in the system is reported as a
    /// duplicate rather than inserted twice, which is what makes re-uploading a file harmless.
    /// A punch on an unknown PIN is still STORED (with no employee) and reported as unresolved —
    /// it is never dropped.
    /// </summary>
    public async Task<RawLogInsertResult> InsertRawLogAsync(int deviceId, string enrollPin, DateTime punchTimeUtc, short punchType, string source, string dedupHash, int? importBatchId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<RawLogInsertResult>(
            "attendance.usp_RawLog_Insert",
            new
            {
                DeviceId = deviceId,
                EnrollPin = enrollPin,
                PunchTimeUtc = punchTimeUtc,
                PunchType = punchType,
                Source = source,
                DedupHash = dedupHash,
                ImportBatchId = importBatchId
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Of the supplied dedup hashes, which are already stored. The import preview uses this to mark
    /// rows as "already in the system, will be skipped" WITHOUT writing anything — so the preview and
    /// the import it previews cannot disagree.
    /// </summary>
    public async Task<HashSet<string>> GetExistingHashesAsync(IEnumerable<string> dedupHashes)
    {
        var hashes = dedupHashes as IList<string> ?? dedupHashes.ToList();
        if (hashes.Count == 0)
            return new HashSet<string>(StringComparer.Ordinal);

        using var db = _factory.Create();
        var found = await db.QueryAsync<string>(
            "attendance.usp_RawLog_GetExistingHashes",
            new { Hashes = string.Join(',', hashes) },
            commandType: CommandType.StoredProcedure);

        return found.ToHashSet(StringComparer.Ordinal);
    }

    /// <summary>Opens a batch and stores the file as JSON. That JSON is an AUDIT COPY and is never processed.</summary>
    public async Task<int> CreateBatchAsync(string fileName, string rawJson, int? importedByUser)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "attendance.usp_ImportBatch_Create",
            new { FileName = fileName, RawJson = rawJson, ImportedByUser = importedByUser },
            commandType: CommandType.StoredProcedure);
    }

    public async Task SetBatchResultAsync(int importBatchId, int parsedRows, string status, string? note)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_ImportBatch_SetResult",
            new { ImportBatchId = importBatchId, ParsedRows = parsedRows, Status = status, Note = note },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<ImportBatch>> GetBatchesAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<ImportBatch>(
            "attendance.usp_ImportBatch_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<ImportBatchDetail?> GetBatchWithJsonAsync(int importBatchId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ImportBatchDetail>(
            "attendance.usp_ImportBatch_GetJson",
            new { ImportBatchId = importBatchId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Punches whose PIN belongs to nobody. They are waiting, not lost.</summary>
    public async Task<IEnumerable<RawLog>> GetUnresolvedAsync(DateTime? fromDate, DateTime? toDate)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<RawLog>(
            "attendance.usp_RawLog_GetUnresolved",
            new { FromDate = fromDate, ToDate = toDate },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Every punch recorded on one DAY, resolved to people, machines and branches for reading.
    ///
    /// Scoped to a single date by design rather than taking a range: this backs a screen somebody
    /// opens to ask "did today's punches arrive", and an unbounded range over a table that grows by
    /// every punch of every employee forever is a page that works in testing and times out in year
    /// two. That is also why the date has no default.
    /// </summary>
    public async Task<IEnumerable<RawPunch>> GetPunchesByDateAsync(DateTime date, int? deviceId, bool unresolvedOnly)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<RawPunch>(
            "attendance.usp_RawLog_GetByDate",
            new { Date = date.Date, DeviceId = deviceId, UnresolvedOnly = unresolvedOnly },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>The raw punches behind one employee-day — what the machine ACTUALLY said, before any processing.</summary>
    public async Task<IEnumerable<RawLog>> GetByEmployeeDayAsync(int employeeId, DateTime workDate)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<RawLog>(
            "attendance.usp_RawLog_GetByEmployeeDay",
            new { EmployeeId = employeeId, WorkDate = workDate },
            commandType: CommandType.StoredProcedure);
    }
}
