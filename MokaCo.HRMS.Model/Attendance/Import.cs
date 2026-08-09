namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// Maps to attendance.ATTENDANCE_IMPORT_BATCH. One row per spreadsheet uploaded from a device.
/// The original file is kept as JSON for AUDIT ONLY — it answers "what did the file actually say"
/// six months from now, when someone disputes a payslip. It is NEVER re-processed: the punches were
/// shredded into RAW_DEVICE_LOG at upload time, and that is the only pipeline.
/// </summary>
public class ImportBatch
{
    public int ImportBatchId { get; set; }
    public string FileName { get; set; } = string.Empty;

    /// <summary>Punch rows parsed out of the file (not necessarily inserted — duplicates are parsed but ignored).</summary>
    public int RowCount { get; set; }

    /// <summary>Received / Parsed / Failed.</summary>
    public string Status { get; set; } = string.Empty;

    public int? ImportedByUser { get; set; }
    public string? ImportedByUsername { get; set; }
    public DateTime ImportedUtc { get; set; }

    /// <summary>Short human summary, e.g. '2 unknown PINs'.</summary>
    public string? Note { get; set; }
}

/// <summary>An import batch INCLUDING the audit copy of the file. Separate from the list model because the JSON can be large.</summary>
public class ImportBatchDetail : ImportBatch
{
    public string RawJson { get; set; } = string.Empty;
}

/// <summary>
/// One punch as it was read out of the spreadsheet, before any decision was taken about it.
/// EmployeeName is captured for the audit copy and for the preview grid, but is NEVER used to
/// match a person — devices export names inconsistently and a typo must not move someone's hours
/// onto someone else's payslip. Matching is (DeviceSerial + EnrollPin), always.
/// </summary>
public class ImportPunchRow
{
    /// <summary>1-based row number in the worksheet, so an error can name the row the user has to go and look at.</summary>
    public int RowNumber { get; set; }

    public string EnrollPin { get; set; } = string.Empty;
    public string? EmployeeName { get; set; }
    public DateTime PunchTimeUtc { get; set; }

    /// <summary>0 = IN, 1 = OUT. Normalised here from whatever dialect the device used ("IN"/"Check Out"/0/1).</summary>
    public short PunchType { get; set; }

    public string DeviceSerial { get; set; } = string.Empty;
}

/// <summary>
/// A row the parser could not make sense of. It is REPORTED, not fatal: one malformed line must
/// never abort an import and cost the other 200 punches in the file.
/// </summary>
public class ImportRowError
{
    public int RowNumber { get; set; }
    public string Message { get; set; } = string.Empty;
}

/// <summary>
/// What the preview step predicts WITHOUT WRITING ANYTHING. It is the same parse and the same
/// dedup hash the real import will use, so what the user is shown here is what they will get —
/// that is the entire value of the preview.
/// </summary>
public class ImportPreviewRow : ImportPunchRow
{
    /// <summary>The punch is already in the system and will be skipped. Not an error — re-uploading a file is a safe thing to do.</summary>
    public bool WillBeDuplicate { get; set; }

    /// <summary>Nobody is enrolled on this PIN. The punch will still be STORED and parked in the unresolved queue, never thrown away.</summary>
    public bool WillBeUnresolved { get; set; }

    /// <summary>The serial is not a registered device, so this punch CANNOT be stored — there is nowhere to attribute it. Add the device first.</summary>
    public bool UnknownDevice { get; set; }

    /// <summary>Plain-language explanation of whatever flag is set, written for an HR user rather than a developer.</summary>
    public string? Reason { get; set; }
}

/// <summary>The result of previewing a file: what WOULD happen, with nothing written to the database.</summary>
public class ImportPreviewResult
{
    public int Parsed { get; set; }
    public int WillInsert { get; set; }
    public int Duplicates { get; set; }
    public int UnresolvedPins { get; set; }
    public int UnknownDevices { get; set; }
    public List<ImportPreviewRow> Rows { get; set; } = new();
    public List<ImportRowError> Errors { get; set; } = new();
}

/// <summary>
/// The result of an actual import — deliberately a summary a human can ACT on, not a row count.
/// Duplicates and unresolved PINs are outcomes, not failures: importing the same file twice is
/// safe by design, and a punch on an unknown PIN is kept rather than lost.
/// </summary>
public class ImportResult
{
    public int ImportBatchId { get; set; }

    /// <summary>Punch rows successfully read out of the sheet.</summary>
    public int Parsed { get; set; }

    /// <summary>New raw punches actually written.</summary>
    public int Inserted { get; set; }

    /// <summary>Punches already in the system, ignored. Re-uploading the same file makes this equal to Parsed and Inserted zero.</summary>
    public int Duplicates { get; set; }

    /// <summary>Punches stored with no employee attached, waiting on the Unresolved PINs page.</summary>
    public int UnresolvedPins { get; set; }

    /// <summary>Punches whose device serial is not registered. These could NOT be stored — the only outcome here that actually loses data, which is why it is surfaced separately.</summary>
    public int UnknownDevices { get; set; }

    public List<ImportRowError> Errors { get; set; } = new();
}
