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
}
