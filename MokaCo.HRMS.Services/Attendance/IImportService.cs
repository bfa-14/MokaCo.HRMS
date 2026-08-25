using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

public interface IImportService
{
    Task<ImportPreviewResult> PreviewAsync(Stream xlsx);
    Task<ImportResult> ImportAsync(Stream xlsx, string fileName, int? importedByUser);

    Task<IEnumerable<ImportBatch>> GetBatchesAsync();
    Task<ImportBatchDetail?> GetBatchAsync(int importBatchId);
    Task<IEnumerable<RawLog>> GetUnresolvedAsync(DateTime? fromDate, DateTime? toDate);

    /// <summary>
    /// Every punch on one day, resolved to people and machines. What the attendance screens read to
    /// answer "did my punch arrive, and has it become attendance yet" without anybody opening SQL.
    /// </summary>
    Task<IEnumerable<RawPunch>> GetPunchesByDateAsync(DateTime date, int? deviceId, bool unresolvedOnly);

    Task<RawLogInsertResult> PunchAsync(int deviceId, PunchRequest request);

    /// <summary>
    /// Lands a whole ATTLOG body pushed by a ZKTeco terminal over iclock/ADMS. Same table, same
    /// dedup hash and same processor as the other two paths — see the implementation for the line
    /// format and for what happens to a line that cannot be read.
    /// </summary>
    Task<AttlogPushResult> PushAttlogAsync(int deviceId, string body);

    /// <summary>
    /// Lands punches the SERVER read off a terminal over TCP (see ZkTecoClient). Same table, same
    /// dedup hash and same unresolved-PIN behaviour as <see cref="PushAttlogAsync"/> — the only
    /// difference is who placed the call. That is what lets one machine be pulled AND pushed without
    /// any risk of counting a punch twice.
    /// </summary>
    Task<AttlogPushResult> LandPulledAsync(
        int deviceId, IEnumerable<(string Pin, DateTime PunchTime, short PunchType)> punches);
}
