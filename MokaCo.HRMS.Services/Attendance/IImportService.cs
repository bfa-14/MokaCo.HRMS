using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

public interface IImportService
{
    Task<ImportPreviewResult> PreviewAsync(Stream xlsx);
    Task<ImportResult> ImportAsync(Stream xlsx, string fileName, int? importedByUser);

    Task<IEnumerable<ImportBatch>> GetBatchesAsync();
    Task<ImportBatchDetail?> GetBatchAsync(int importBatchId);
    Task<IEnumerable<RawLog>> GetUnresolvedAsync(DateTime? fromDate, DateTime? toDate);

    Task<RawLogInsertResult> PunchAsync(int deviceId, PunchRequest request);

    /// <summary>
    /// Lands a whole ATTLOG body pushed by a ZKTeco terminal over iclock/ADMS. Same table, same
    /// dedup hash and same processor as the other two paths — see the implementation for the line
    /// format and for what happens to a line that cannot be read.
    /// </summary>
    Task<AttlogPushResult> PushAttlogAsync(int deviceId, string body);
}
