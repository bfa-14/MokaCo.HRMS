namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// Maps to attendance.DEVICE. A fingerprint terminal — a PHYSICAL object, so it belongs to a
/// branch (required). Manual entry and Excel import are also represented as devices
/// (MANUAL-ENTRY, EXCEL-IMPORT), which is what lets EVERY raw punch name a device no matter
/// how it arrived. That is the whole point: three ingestion paths, one destination.
/// </summary>
public class Device
{
    public int DeviceId { get; set; }

    /// <summary>
    /// The terminal's own serial, e.g. 'ZK-1234'. This is the identity a pushing device sends —
    /// it does not know its DeviceId — so the serial is what the punch endpoint resolves on.
    /// </summary>
    public string SerialNumber { get; set; } = string.Empty;

    /// <summary>
    /// The terminal's human label — "Verdun front door". Optional, because a device is usable
    /// without one; a serial identifies the hardware to us and nothing at all to an HR user
    /// trying to work out which machine in which room stopped reporting.
    /// </summary>
    public string? Name { get; set; }

    /// <summary>Where the terminal is mounted. A punch's branch is taken from here: it records WHERE the day was worked.</summary>
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;

    public int? DepartmentId { get; set; }
    public string? DepartmentName { get; set; }

    /// <summary>0 = retired. An inactive device is rejected by the punch endpoint, so a stolen terminal stops counting.</summary>
    public bool IsActive { get; set; }

    /// <summary>Last time this terminal talked to us. A stale value is how HR notices a device has quietly died.</summary>
    public DateTime? LastSyncUtc { get; set; }

    /// <summary>
    /// Last time this terminal sent PUNCHES, which is a different fact from LastSyncUtc and the
    /// reason both exist. An ADMS terminal polls for commands every few seconds whether or not
    /// anyone has touched it, so LastSyncUtc can look perfectly healthy while the fingerprint
    /// sensor is dead. Contact answers "is it plugged in"; this answers "is it recording anyone".
    /// </summary>
    public DateTime? LastPushUtc { get; set; }

    /// <summary>
    /// The newest punch we HOLD from this terminal, whichever path carried it — pull, push or a
    /// spreadsheet.
    ///
    /// NOT THE SAME FACT AS <see cref="LastPushUtc"/>, and the difference is the whole reason this
    /// exists. LastPushUtc answers "did the machine deliver punches ITSELF", which is a diagnostic
    /// about the push link and is NULL forever on a terminal we poll. Asking it "when did anybody
    /// last punch here" therefore answered "never" on a pulled machine while punches were arriving
    /// every five minutes. This answers that question, and it is the one a screen should show.
    ///
    /// Read-only, and derived: it is MAX(PunchTimeUtc) over the device's raw log, on the PUNCH'S own
    /// timestamp rather than on when the row was written — so a machine that queued a day through a
    /// dead link reports when people actually punched, not when the backlog reached us.
    /// </summary>
    public DateTime? LastPunchUtc { get; set; }

    /// <summary>
    /// Punches recorded on this terminal today, counted on the PUNCH'S OWN timestamp rather than
    /// on when the row was written — a machine that queued a day's punches through a dead link and
    /// flushed them at 18:00 recorded them across the day, not in one spike.
    /// </summary>
    public int PunchesToday { get; set; }

    /* ── PULL: the reverse of the push above ──────────────────────────────────────────────────
       Push is the terminal calling us over iclock/ADMS; pull is us opening a TCP socket to the
       terminal and reading its log. They are alternatives, not a sequence, and a machine may have
       both switched on — the dedup hash is what makes that harmless rather than double-counting.
       A terminal that cannot push (no ADMS menu in its firmware) is reachable only this way, which
       is why these columns exist at all. ─────────────────────────────────────────────────────── */

    /// <summary>
    /// The terminal's address on the LAN — "192.168.45.12", or a hostname. Null means this machine
    /// is not pullable and the worker will not have it on its worklist.
    /// </summary>
    public string? PullIp { get; set; }

    /// <summary>The ZK standalone service port. 4370 on every unit we have met; configurable because firmware occasionally moves it.</summary>
    public int PullPort { get; set; }

    /// <summary>
    /// The terminal's own "comm key" — a device-side password for the TCP protocol, 0 when unset,
    /// which is the factory default and what most sites leave it on. It is not a secret we issue;
    /// it is one the machine already has, and we have to present it to be let in.
    /// </summary>
    public int PullCommKey { get; set; }

    /// <summary>Whether the polling worker should call this machine. Off by default: a device is registered before it is reachable.</summary>
    public bool PullEnabled { get; set; }

    /// <summary>When the worker last ATTEMPTED this machine — success or failure. Paired with <see cref="LastPullError"/> to tell the two apart.</summary>
    public DateTime? LastPullUtc { get; set; }

    /// <summary>
    /// Why the last pull failed, or null if it succeeded. Kept on the device rather than only in the
    /// log because "the machine by the kitchen has been unreachable since Tuesday" is a fact HR needs
    /// on the page, not one an administrator has to go and grep for.
    /// </summary>
    public string? LastPullError { get; set; }
}

/// <summary>
/// One row of the pull worker's worklist — attendance.usp_Device_GetPullTargets.
///
/// Deliberately NOT <see cref="Device"/>: the worker needs an address and a key and nothing else,
/// and a worklist that carried branch names and today's punch counts would invite a caller to make
/// decisions from stale copies of fields it should be reading from the device record.
/// </summary>
public class PullTarget
{
    public int DeviceId { get; set; }
    public string SerialNumber { get; set; } = string.Empty;
    public string? Name { get; set; }

    /// <summary>Never null in practice — the proc filters PullIp IS NOT NULL — but typed honestly for the column.</summary>
    public string? PullIp { get; set; }

    public int PullPort { get; set; }
    public int PullCommKey { get; set; }
    public DateTime? LastPullUtc { get; set; }

    /// <summary>What to call this machine in a log line or a notification: its label if it has one, else the serial.</summary>
    public string Label => string.IsNullOrWhiteSpace(Name) ? SerialNumber : Name!;
}

/// <summary>
/// One punch as it came off a terminal's own log — the terminal's PIN, the terminal's clock, the
/// terminal's direction code. Nothing is converted on the way in; see LandPulledAsync for why.
/// </summary>
public record PulledPunch(string Pin, DateTime PunchTime, short PunchType);

/// <summary>
/// What a "Test" button gets back: did we reach the machine, and what time does it think it is.
///
/// The clock is the point. Punches are stored at the terminal's own wall-clock time, so a machine
/// running forty minutes fast silently writes forty minutes of overtime onto everybody's day — and
/// nothing downstream can detect it. Showing the device's time next to the server's is the only
/// moment anybody is likely to notice.
/// </summary>
public class DeviceTestResult
{
    public bool Ok { get; set; }
    public DateTime? DeviceTime { get; set; }
    public string? Error { get; set; }
}

/// <summary>The outcome of one pull attempt against one machine, for the "Pull now" button and the worker's log line.</summary>
public class DevicePullResult
{
    public int Received { get; set; }
    public int Inserted { get; set; }
    public int Duplicates { get; set; }
    public int UnresolvedPins { get; set; }
    public string? Error { get; set; }

    /// <summary>
    /// Records that came off the machine but could not be read — a corrupt timestamp, a record with
    /// no PIN on it. Normally zero and normally ignorable, because the punches around them landed.
    ///
    /// It matters for exactly one thing: it is the veto on erasing the machine's log. Clearing is
    /// irreversible, so it is allowed only when every record on the terminal is provably either
    /// stored or a known duplicate — and a record we could not read is neither.
    /// </summary>
    public int Unreadable { get; set; }

    /// <summary>
    /// Things that went right but not cleanly — a legacy record layout, records dropped as corrupt.
    /// Carried on the result rather than logged inside the client because only the caller knows which
    /// machine this was, and a warning that does not name the machine cannot be acted on.
    /// </summary>
    public List<string> Warnings { get; } = new();
}

/// <summary>
/// The outcome of "clear this machine's log": what was rescued first, and whether the erase then
/// happened.
///
/// The two halves are reported separately because the interesting failure is the middle one — the
/// pull worked, the erase was REFUSED, and the machine still holds everything. A caller that only
/// looked at an ok/error flag would show that as a plain failure, when what actually happened is
/// that the safety net did its job.
/// </summary>
public class MachineClearResult
{
    /// <summary>The rescue pull that ran first. Always populated, even when the clear was refused.</summary>
    public DevicePullResult PulledBeforeClear { get; set; } = new();

    /// <summary>True only if the terminal acknowledged the erase. False means the machine is untouched.</summary>
    public bool Cleared { get; set; }

    /// <summary>Why nothing was erased. Null when <see cref="Cleared"/> is true.</summary>
    public string? Error { get; set; }
}

/// <summary>
/// Maps to attendance.EMPLOYEE_DEVICE. A TRANSLATION table, not a restriction: a device knows
/// people only by an enrollment PIN, and a PIN is unique only WITHIN one device. An employee who
/// punches at two branches therefore needs ONE ROW PER DEVICE — otherwise their punches at the
/// second branch arrive with nobody attached and sit in the unresolved queue.
/// </summary>
public class EmployeeDevice
{
    public int EmployeeDeviceId { get; set; }
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public int DeviceId { get; set; }
    public string SerialNumber { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;

    /// <summary>The device's own id for this person, e.g. '1001'. A STRING, never a number — leading zeros are significant.</summary>
    public string EnrollPin { get; set; } = string.Empty;
}

/// <summary>
/// Result of mapping a PIN to an employee. Mapping is retroactive: punches that already arrived
/// on that (device, PIN) with nobody attached are claimed on the spot, which is why this number
/// exists — it tells HR the fix actually recovered something instead of silently doing nothing.
/// </summary>
public class EnrollmentMapResult
{
    public int OrphanPunchesResolved { get; set; }
}

/// <summary>
/// The credentials the punch endpoint checks. A terminal has no user and no JWT, so it
/// authenticates as ITSELF with a per-device API key.
///
/// WHY THIS EXISTS: an unauthenticated punch endpoint means anyone who can reach the network can
/// forge attendance — and forged attendance is forged pay. Added by
/// docs/attendance_device_apikey.sql, which is separate from the schema contract precisely because
/// the contract does not own this column.
/// </summary>
public class DeviceAuth
{
    public int DeviceId { get; set; }
    public string SerialNumber { get; set; } = string.Empty;

    /// <summary>A retired terminal is refused even with a valid key — this is the kill switch for a stolen device.</summary>
    public bool IsActive { get; set; }

    /// <summary>SHA-256 of the key, hex. The plaintext key is shown to the administrator ONCE, at issue, and is never stored.</summary>
    public string? ApiKeyHash { get; set; }
}

/// <summary>
/// A freshly issued device key. <see cref="ApiKey"/> is the ONLY time the plaintext exists — it is
/// hashed on the way into the database, so a lost key is re-issued, never recovered.
/// </summary>
public class DeviceApiKeyResult
{
    public int DeviceId { get; set; }
    public string SerialNumber { get; set; } = string.Empty;
    public string ApiKey { get; set; } = string.Empty;
}
