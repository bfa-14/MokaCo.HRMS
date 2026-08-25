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
/// One raw punch, resolved for READING — attendance.usp_RawLog_GetByDate.
///
/// WHY THIS IS NOT <see cref="RawLog"/>. That type is the storage row: it names the device by id
/// and serial and the person not at all, because at the moment of INSERT that is genuinely all that
/// is known. This one is for a human looking at a screen and asking "did my punch arrive" — so it
/// carries the person's name, the machine's label and the branch, joined at read time.
///
/// It also drops something on purpose: the dedup hash. That is an implementation detail of
/// idempotency, it means nothing to a reader, and 64 characters of hex per row pushes the columns
/// somebody actually came for off the edge of the screen.
/// </summary>
public class RawPunch
{
    public long RawLogId { get; set; }

    /// <summary>The TERMINAL'S own wall clock, stored unconverted. See ImportService for why no path converts it.</summary>
    public DateTime PunchTimeUtc { get; set; }

    /// <summary>0 = IN, 1 = OUT. Anything else is a key the processor does not model — kept, never guessed at.</summary>
    public short PunchType { get; set; }

    /// <summary>Pull / Device / Excel / Manual — HOW the punch arrived.</summary>
    public string Source { get; set; } = string.Empty;

    /// <summary>True once the processor has consumed it into an employee-day. False is normal for a punch made today.</summary>
    public bool IsProcessed { get; set; }

    /// <summary>The device's own id for the person. A STRING — '0042' and '42' are different PINs.</summary>
    public string EnrollPin { get; set; } = string.Empty;

    public int? EmployeeId { get; set; }

    /// <summary>
    /// Null means the PIN is not mapped to anybody. NOT an error and NOT lost — the punch is stored
    /// and waiting on the Unresolved PINs page, and mapping the PIN claims it retroactively.
    /// </summary>
    public string? FullName { get; set; }

    public int DeviceId { get; set; }
    public string SerialNumber { get; set; } = string.Empty;

    /// <summary>The machine's human label, or null when nobody has named it — fall back to the serial.</summary>
    public string? DeviceName { get; set; }

    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;

    /// <summary>
    /// When the row was WRITTEN, as opposed to when the punch happened. The two diverge by design on
    /// a pulled machine — a punch at 09:00 read by the 09:05 cycle lands at 09:05 — and that gap is
    /// exactly what separates "the machine did not record it" from "we have not collected it yet".
    /// </summary>
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
