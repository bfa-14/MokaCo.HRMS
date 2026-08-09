namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// Maps to attendance.RAW_DEVICE_LOG — the immutable, write-once landing table for raw punches
/// from ANY source (device push, Excel, manual). Nothing ever edits these rows: corrections change
/// the PROCESSED record, never what the machine actually said. This is what makes the system
/// auditable a year later.
/// </summary>
public class RawLog
{
    public long RawLogId { get; set; }
    public int DeviceId { get; set; }
    public string SerialNumber { get; set; } = string.Empty;
    public string EnrollPin { get; set; } = string.Empty;

    public DateTime PunchTimeUtc { get; set; }

    /// <summary>0 = IN, 1 = OUT.</summary>
    public short PunchType { get; set; }

    /// <summary>Device / Excel / Manual — HOW the punch arrived. Kept because it changes how much you trust it.</summary>
    public string Source { get; set; } = string.Empty;

    /// <summary>
    /// SHA-256 of device|pin|time|type. The idempotency key: it is what makes re-sending a push, or
    /// re-uploading the same spreadsheet, a no-op instead of doubling someone's hours.
    /// </summary>
    public string DedupHash { get; set; } = string.Empty;

    /// <summary>
    /// 1 once the processor has consumed this punch. THE PROCESSOR IS THE ONLY THING THAT SETS IT.
    /// Unprocessed punches inside a payroll period mean days are missing entirely, which is why
    /// payroll readiness counts them.
    /// </summary>
    public bool IsProcessed { get; set; }

    public int? ImportBatchId { get; set; }
    public DateTime CreatedUtc { get; set; }
}

/// <summary>
/// Result of inserting one raw punch. Both flags are counted by the importer rather than thrown
/// away, because they are the two things a human needs to know about a file they just uploaded.
/// </summary>
public class RawLogInsertResult
{
    public long? RawLogId { get; set; }

    /// <summary>The punch was already in the system (same DedupHash) and was ignored. NOT an error.</summary>
    public bool WasDuplicate { get; set; }

    /// <summary>
    /// The PIN belongs to nobody, so the punch was STORED with no employee attached — never dropped.
    /// It waits in the unresolved queue until HR maps the PIN, at which point it is claimed
    /// retroactively and counted.
    /// </summary>
    public bool WasUnresolved { get; set; }
}
