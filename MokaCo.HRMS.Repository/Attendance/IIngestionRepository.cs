using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Repository.Attendance;

/// <summary>
/// The single landing path for raw punches, whatever their source. Device push, Excel import and
/// manual entry all come through here — there is deliberately no second pipeline.
/// </summary>
public interface IIngestionRepository
{
    Task<RawLogInsertResult> InsertRawLogAsync(int deviceId, string enrollPin, DateTime punchTimeUtc, short punchType, string source, string dedupHash, int? importBatchId);

    /// <summary>Which of these punches the system already has. Read-only — it is what lets the import preview tell the truth.</summary>
    Task<HashSet<string>> GetExistingHashesAsync(IEnumerable<string> dedupHashes);

    Task<int> CreateBatchAsync(string fileName, string rawJson, int? importedByUser);
    Task SetBatchResultAsync(int importBatchId, int parsedRows, string status, string? note);
    Task<IEnumerable<ImportBatch>> GetBatchesAsync();
    Task<ImportBatchDetail?> GetBatchWithJsonAsync(int importBatchId);

    Task<IEnumerable<RawLog>> GetUnresolvedAsync(DateTime? fromDate, DateTime? toDate);
    Task<IEnumerable<RawLog>> GetByEmployeeDayAsync(int employeeId, DateTime workDate);
}
