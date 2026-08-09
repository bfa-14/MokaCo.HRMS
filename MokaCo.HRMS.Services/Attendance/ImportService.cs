using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ClosedXML.Excel;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

/// <summary>
/// Ingestion: the Excel importer, and the device push endpoint's landing logic.
///
/// THREE PATHS, ONE DESTINATION. A punch from a terminal, a punch from a spreadsheet and a punch HR
/// typed in all land in RAW_DEVICE_LOG and are consumed by the SAME processor. There is deliberately
/// no second pipeline: a second pipeline is a second set of rules, and eventually a second answer to
/// "how many hours did this person work".
///
/// Three promises this class keeps, because payroll depends on them:
///   1. NOTHING IS LOST. A punch on a PIN nobody is enrolled on is STORED with no employee attached
///      and parked in the unresolved queue. It is never dropped, and it is claimed retroactively the
///      moment HR maps the PIN.
///   2. NOTHING IS DOUBLED. Every punch carries a SHA-256 of (device, pin, time, type). Re-sending a
///      push, or re-uploading the same spreadsheet, is a no-op — not a doubling of someone's hours.
///   3. NOTHING IS ABORTED. One malformed row is reported with its row number; it does not take the
///      other 200 punches in the file down with it.
/// </summary>
public class ImportService : IImportService
{
    /// <summary>Every punch that arrived on a spreadsheet. Kept so you can always tell a typed hour from a measured one.</summary>
    private const string ExcelSource = "Excel";

    /// <summary>Every punch a terminal pushed itself.</summary>
    private const string DeviceSource = "Device";

    private readonly IIngestionRepository _ingestion;
    private readonly IDeviceRepository _devices;

    public ImportService(IIngestionRepository ingestion, IDeviceRepository devices)
    {
        _ingestion = ingestion;
        _devices = devices;
    }

    /// <summary>
    /// Says what an import WOULD do, writing nothing. It runs the same parse and computes the same
    /// dedup hash the real import will, and it checks those hashes against what is already stored —
    /// so what the user is shown here is exactly what they will get. A preview that guessed
    /// differently from the import would be worse than no preview at all.
    /// </summary>
    public async Task<ImportPreviewResult> PreviewAsync(Stream xlsx)
    {
        var (rows, errors) = ParseWorkbook(xlsx);

        var devicesBySerial = await GetDeviceMapAsync();
        var enrolledPins = await GetEnrolledPinsAsync();

        // Hash every row we could attribute to a real device, then ask the database which of those
        // punches it already has. This is what makes re-uploading a file predictable rather than a leap of faith.
        var hashByRow = new Dictionary<int, string>();
        foreach (var row in rows)
        {
            if (devicesBySerial.TryGetValue(row.DeviceSerial, out var deviceId))
                hashByRow[row.RowNumber] = ComputeDedupHash(deviceId, row.EnrollPin, row.PunchTimeUtc, row.PunchType);
        }

        var existingHashes = await _ingestion.GetExistingHashesAsync(hashByRow.Values.Distinct());

        var result = new ImportPreviewResult { Parsed = rows.Count, Errors = errors };
        var seenInThisFile = new HashSet<string>(StringComparer.Ordinal);

        foreach (var row in rows)
        {
            var preview = new ImportPreviewRow
            {
                RowNumber = row.RowNumber,
                EnrollPin = row.EnrollPin,
                EmployeeName = row.EmployeeName,
                PunchTimeUtc = row.PunchTimeUtc,
                PunchType = row.PunchType,
                DeviceSerial = row.DeviceSerial
            };

            if (!devicesBySerial.TryGetValue(row.DeviceSerial, out var deviceId))
            {
                // The only outcome that actually loses data: there is nowhere to attribute this punch.
                preview.UnknownDevice = true;
                preview.Reason = $"Device '{row.DeviceSerial}' is not registered, so this punch cannot be stored. Add the device first.";
                result.UnknownDevices++;
                result.Rows.Add(preview);
                continue;
            }

            var hash = hashByRow[row.RowNumber];

            // Already in the database, OR repeated earlier in this same file (the sensor fired twice).
            if (existingHashes.Contains(hash) || !seenInThisFile.Add(hash))
            {
                preview.WillBeDuplicate = true;
                preview.Reason = "This punch is already in the system and will be ignored. Nothing is overwritten.";
                result.Duplicates++;
                result.Rows.Add(preview);
                continue;
            }

            if (!enrolledPins.Contains((deviceId, row.EnrollPin)))
            {
                preview.WillBeUnresolved = true;
                preview.Reason = $"Nobody is enrolled on PIN {row.EnrollPin} for this device. The punch will be kept, not thrown away, and will wait on the Unresolved PINs page.";
                result.UnresolvedPins++;
            }

            result.WillInsert++;
            result.Rows.Add(preview);
        }

        return result;
    }

    /// <summary>
    /// Imports a spreadsheet exported from a fingerprint terminal.
    ///
    /// The whole parsed file is stored as JSON first, as an AUDIT COPY — it answers "what did the
    /// file actually say" six months from now, when a payslip is disputed. It is NEVER re-processed:
    /// the punches are shredded into RAW_DEVICE_LOG here and that is the only pipeline.
    /// </summary>
    public async Task<ImportResult> ImportAsync(Stream xlsx, string fileName, int? importedByUser)
    {
        var (rows, errors) = ParseWorkbook(xlsx);

        // The audit copy: what the file said, before we made any decision about it.
        var rawJson = JsonSerializer.Serialize(rows);
        var batchId = await _ingestion.CreateBatchAsync(fileName, rawJson, importedByUser);

        var devicesBySerial = await GetDeviceMapAsync();

        var result = new ImportResult
        {
            ImportBatchId = batchId,
            Parsed = rows.Count,
            Errors = errors
        };

        foreach (var row in rows)
        {
            if (!devicesBySerial.TryGetValue(row.DeviceSerial, out var deviceId))
            {
                // Reported rather than swallowed: this punch could NOT be stored, and somebody has to know.
                result.UnknownDevices++;
                result.Errors.Add(new ImportRowError
                {
                    RowNumber = row.RowNumber,
                    Message = $"Device '{row.DeviceSerial}' is not registered. This punch was not imported. Add the device and upload the file again — nothing will be duplicated."
                });
                continue;
            }

            var hash = ComputeDedupHash(deviceId, row.EnrollPin, row.PunchTimeUtc, row.PunchType);

            var inserted = await _ingestion.InsertRawLogAsync(
                deviceId, row.EnrollPin, row.PunchTimeUtc, row.PunchType, ExcelSource, hash, batchId);

            if (inserted.WasDuplicate)
            {
                result.Duplicates++;
                continue;
            }

            result.Inserted++;

            // Stored, but nobody is enrolled on that PIN. The punch is waiting, not lost.
            if (inserted.WasUnresolved)
                result.UnresolvedPins++;
        }

        var status = result.Parsed == 0 && errors.Count > 0 ? "Failed" : "Parsed";
        await _ingestion.SetBatchResultAsync(batchId, result.Parsed, status, BuildNote(result));

        return result;
    }

    public Task<IEnumerable<ImportBatch>> GetBatchesAsync() => _ingestion.GetBatchesAsync();

    public Task<ImportBatchDetail?> GetBatchAsync(int importBatchId) => _ingestion.GetBatchWithJsonAsync(importBatchId);

    public Task<IEnumerable<RawLog>> GetUnresolvedAsync(DateTime? fromDate, DateTime? toDate)
        => _ingestion.GetUnresolvedAsync(fromDate, toDate);

    /// <summary>
    /// Lands a single punch pushed by a terminal. Same table, same dedup hash and same processor as
    /// the Excel path — a pushed punch and an imported punch are the same kind of fact.
    /// The device has already been authenticated by the time we get here.
    /// </summary>
    public Task<RawLogInsertResult> PunchAsync(int deviceId, PunchRequest request)
    {
        var hash = ComputeDedupHash(deviceId, request.EnrollPin, request.PunchTimeUtc, request.PunchType);

        return _ingestion.InsertRawLogAsync(
            deviceId, request.EnrollPin, request.PunchTimeUtc, request.PunchType, DeviceSource, hash, null);
    }

    /* ------------------------------------------------------------------ *
     * Parsing. Real terminals are inconsistent, so the parser is tolerant *
     * about FORMAT and utterly strict about IDENTITY.                     *
     * ------------------------------------------------------------------ */

    /// <summary>
    /// Reads the FIRST worksheet — anything else in the workbook (a README, a summary tab) is ignored.
    /// A row that cannot be understood becomes an error carrying its row number and the import
    /// carries on; losing 200 good punches to one bad line is not an acceptable trade.
    /// </summary>
    private static (List<ImportPunchRow> Rows, List<ImportRowError> Errors) ParseWorkbook(Stream xlsx)
    {
        var rows = new List<ImportPunchRow>();
        var errors = new List<ImportRowError>();

        using var workbook = new XLWorkbook(xlsx);
        var sheet = workbook.Worksheet(1);

        var lastRow = sheet.LastRowUsed();
        if (lastRow is null)
        {
            errors.Add(new ImportRowError { RowNumber = 0, Message = "The first worksheet is empty." });
            return (rows, errors);
        }

        var columns = MapHeaders(sheet);

        foreach (var required in new[] { "enrollpin", "punchdatetime", "punchtype", "deviceserial" })
        {
            if (!columns.ContainsKey(required))
            {
                errors.Add(new ImportRowError
                {
                    RowNumber = 1,
                    Message = $"The sheet has no '{required}' column. Expected columns: EnrollPin, EmployeeName, PunchDateTime, PunchType, DeviceSerial."
                });
                return (rows, errors);
            }
        }

        for (var rowNumber = 2; rowNumber <= lastRow.RowNumber(); rowNumber++)
        {
            var row = sheet.Row(rowNumber);
            if (row.IsEmpty())
                continue;

            try
            {
                var pin = ReadPin(row.Cell(columns["enrollpin"]));
                if (string.IsNullOrWhiteSpace(pin))
                {
                    errors.Add(new ImportRowError { RowNumber = rowNumber, Message = "EnrollPin is empty — there is no way to tell whose punch this is." });
                    continue;
                }

                var serial = row.Cell(columns["deviceserial"]).GetString().Trim();
                if (string.IsNullOrWhiteSpace(serial))
                {
                    errors.Add(new ImportRowError { RowNumber = rowNumber, Message = "DeviceSerial is empty — a punch must say which terminal recorded it." });
                    continue;
                }

                rows.Add(new ImportPunchRow
                {
                    RowNumber = rowNumber,
                    EnrollPin = pin,
                    // Read for the audit copy and the preview grid ONLY. It is never used to match a
                    // person: devices export names inconsistently, and a typo must not move somebody's
                    // hours onto a colleague's payslip.
                    EmployeeName = columns.TryGetValue("employeename", out var nameCol)
                        ? row.Cell(nameCol).GetString().Trim()
                        : null,
                    PunchTimeUtc = ReadDateTime(row.Cell(columns["punchdatetime"])),
                    PunchType = ReadPunchType(row.Cell(columns["punchtype"])),
                    DeviceSerial = serial
                });
            }
            catch (FormatException ex)
            {
                errors.Add(new ImportRowError { RowNumber = rowNumber, Message = ex.Message });
            }
        }

        return (rows, errors);
    }

    /// <summary>Header names are matched case- and space-insensitively, because 'Enroll Pin' and 'ENROLLPIN' are the same column to a human.</summary>
    private static Dictionary<string, int> MapHeaders(IXLWorksheet sheet)
    {
        var columns = new Dictionary<string, int>(StringComparer.Ordinal);

        foreach (var cell in sheet.Row(1).CellsUsed())
        {
            var key = cell.GetString().Trim().Replace(" ", string.Empty).ToLowerInvariant();
            if (key.Length > 0 && !columns.ContainsKey(key))
                columns[key] = cell.Address.ColumnNumber;
        }

        return columns;
    }

    /// <summary>
    /// A PIN is TEXT, never a number. Excel will happily hand back 1001 as a double, and '0042' as
    /// 42 — and '0042' and '42' are different people to the device. So a numeric cell is rendered
    /// back to its integer string, and anything else is taken verbatim.
    /// </summary>
    private static string ReadPin(IXLCell cell)
    {
        if (cell.DataType == XLDataType.Number)
            return ((long)Math.Round(cell.GetDouble())).ToString(CultureInfo.InvariantCulture);

        return cell.GetString().Trim();
    }

    /// <summary>Accepts a real Excel date cell OR the text 'yyyy-MM-dd HH:mm:ss' — devices export both.</summary>
    private static DateTime ReadDateTime(IXLCell cell)
    {
        if (cell.DataType == XLDataType.DateTime)
            return cell.GetDateTime();

        var text = cell.GetString().Trim();
        if (string.IsNullOrWhiteSpace(text))
            throw new FormatException("PunchDateTime is empty.");

        if (DateTime.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed))
            return parsed;

        throw new FormatException($"'{text}' is not a date and time. Expected 'yyyy-MM-dd HH:mm:ss'.");
    }

    /// <summary>
    /// Normalises whatever dialect the terminal speaks into 0 = IN, 1 = OUT. Real devices export
    /// 'IN'/'OUT', 'In'/'Out', 'Check In'/'Check Out', or a bare 0/1, and none of them think they are
    /// being unusual.
    /// </summary>
    private static short ReadPunchType(IXLCell cell)
    {
        if (cell.DataType == XLDataType.Number)
        {
            var number = (int)Math.Round(cell.GetDouble());
            if (number is 0 or 1)
                return (short)number;

            throw new FormatException($"PunchType '{number}' is not recognised. Use IN/OUT, or 0 for IN and 1 for OUT.");
        }

        var text = cell.GetString().Trim().Replace(" ", string.Empty).ToLowerInvariant();

        return text switch
        {
            "in" or "checkin" or "clockin" or "0" => (short)0,
            "out" or "checkout" or "clockout" or "1" => (short)1,
            _ => throw new FormatException($"PunchType '{cell.GetString().Trim()}' is not recognised. Use IN/OUT, or 0 for IN and 1 for OUT.")
        };
    }

    /* ------------------------------------------------------------------ */

    /// <summary>
    /// The idempotency key: SHA-256 over (device, pin, time, type). Two punches are THE SAME punch if
    /// and only if all four match — which is what makes re-uploading a file safe, and what makes a
    /// genuine double-tap a minute later still count as two events for the processor to reason about.
    /// </summary>
    private static string ComputeDedupHash(int deviceId, string enrollPin, DateTime punchTimeUtc, short punchType)
    {
        var payload = $"{deviceId}|{enrollPin}|{punchTimeUtc:O}|{punchType}";
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(payload)));
    }

    /// <summary>Serial → id, so a file of 400 rows resolves its devices once instead of 400 times.</summary>
    private async Task<Dictionary<string, int>> GetDeviceMapAsync()
    {
        var devices = await _devices.GetAllAsync();
        return devices.ToDictionary(d => d.SerialNumber, d => d.DeviceId, StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>Which (device, PIN) pairs actually belong to somebody. A PIN is only unique WITHIN a device, so the device is half of the key.</summary>
    private async Task<HashSet<(int DeviceId, string EnrollPin)>> GetEnrolledPinsAsync()
    {
        var enrollments = await _devices.GetEnrollmentsAsync();
        return enrollments.Select(e => (e.DeviceId, e.EnrollPin)).ToHashSet();
    }

    /// <summary>A one-line summary stored on the batch, so the import history is readable without opening anything.</summary>
    private static string BuildNote(ImportResult result)
    {
        var parts = new List<string> { $"{result.Inserted} imported" };

        if (result.Duplicates > 0) parts.Add($"{result.Duplicates} duplicate(s) ignored");
        if (result.UnresolvedPins > 0) parts.Add($"{result.UnresolvedPins} on unknown PIN(s)");
        if (result.UnknownDevices > 0) parts.Add($"{result.UnknownDevices} on unregistered device(s)");
        if (result.Errors.Count > 0) parts.Add($"{result.Errors.Count} row error(s)");

        return string.Join(", ", parts);
    }
}
