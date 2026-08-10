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
    /// Punches recorded on this terminal today, counted on the PUNCH'S OWN timestamp rather than
    /// on when the row was written — a machine that queued a day's punches through a dead link and
    /// flushed them at 18:00 recorded them across the day, not in one spike.
    /// </summary>
    public int PunchesToday { get; set; }
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
