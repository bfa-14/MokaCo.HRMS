using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Attendance;

/// <summary>
/// Dapper access for terminals and PIN enrollment via the attendance.usp_Device_* and
/// attendance.usp_EmployeeDevice_* stored procedures.
/// </summary>
public class DeviceRepository : IDeviceRepository
{
    private readonly IDbConnectionFactory _factory;
    public DeviceRepository(IDbConnectionFactory factory) => _factory = factory;

    /// <summary>
    /// Every terminal, with its heartbeats. The columns map by name, so LastPunchUtc — added by
    /// 11_device_last_punch.sql — needs no mapping code here; it does mean an API running against a
    /// database that predates that script reads the property back as null rather than failing, which
    /// is the right way round: the grid shows "No punches yet" instead of the page erroring.
    /// </summary>
    public async Task<IEnumerable<Device>> GetAllAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<Device>(
            "attendance.usp_Device_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>A pushing terminal identifies itself by SERIAL — it does not know its DeviceId — so the push path resolves through here.</summary>
    public async Task<Device?> GetBySerialAsync(string serialNumber)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<Device>(
            "attendance.usp_Device_GetBySerial",
            new { SerialNumber = serialNumber },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(string serialNumber, string? name, int branchId, int? departmentId,
        string? pullIp, int pullPort, int pullCommKey, bool pullEnabled)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "attendance.usp_Device_Create",
            new
            {
                SerialNumber = serialNumber,
                Name = name,
                BranchId = branchId,
                DepartmentId = departmentId,
                PullIp = pullIp,
                PullPort = pullPort,
                PullCommKey = pullCommKey,
                PullEnabled = pullEnabled
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task UpdateAsync(int deviceId, string serialNumber, string? name, int branchId, int? departmentId, bool isActive,
        string? pullIp, int pullPort, int pullCommKey, bool pullEnabled)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_Device_Update",
            new
            {
                DeviceId = deviceId,
                SerialNumber = serialNumber,
                Name = name,
                BranchId = branchId,
                DepartmentId = departmentId,
                IsActive = isActive,
                PullIp = pullIp,
                PullPort = pullPort,
                PullCommKey = pullCommKey,
                PullEnabled = pullEnabled
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>The pull worker's worklist. Ordered by the proc, so a cycle always visits machines in the same order.</summary>
    public async Task<IEnumerable<PullTarget>> GetPullTargetsAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<PullTarget>(
            "attendance.usp_Device_GetPullTargets",
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// The pull heartbeat: when we last tried this machine and what happened. The error is capped at
    /// the column's 300 characters by the caller — a socket exception's full text can run to
    /// paragraphs, and the first sentence is the one that says which machine and why.
    /// </summary>
    public async Task TouchPullAsync(int deviceId, string? error)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_Device_TouchPull",
            new { DeviceId = deviceId, Error = error },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Stamps "this terminal is alive". A stale LastSyncUtc is how HR notices a device has quietly stopped reporting.</summary>
    public async Task TouchSyncAsync(int deviceId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_Device_TouchSync",
            new { DeviceId = deviceId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Stamps "punches just arrived" — and contact along with it, because a terminal that is
    /// pushing is self-evidently reachable. The two are separate columns because the reverse does
    /// NOT hold: an ADMS terminal polls for commands every few seconds whether or not anyone has
    /// touched the sensor, so contact alone can look healthy while nothing is being recorded.
    /// </summary>
    public async Task TouchPushAsync(int deviceId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_Device_TouchPush",
            new { DeviceId = deviceId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<EmployeeDevice>> GetEnrollmentsAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<EmployeeDevice>(
            "attendance.usp_EmployeeDevice_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Maps a PIN to a person. The procedure ALSO retro-claims punches that already arrived on that
    /// (device, PIN) with nobody attached, and returns how many — so a fix never silently does nothing.
    /// </summary>
    public async Task<EnrollmentMapResult> MapAsync(int employeeId, int deviceId, string enrollPin)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<EnrollmentMapResult>(
            "attendance.usp_EmployeeDevice_Map",
            new { EmployeeId = employeeId, DeviceId = deviceId, EnrollPin = enrollPin },
            commandType: CommandType.StoredProcedure);
    }

    public async Task UnmapAsync(int employeeDeviceId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_EmployeeDevice_Unmap",
            new { EmployeeDeviceId = employeeDeviceId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Fetches what the punch endpoint needs to authenticate a terminal: the stored key HASH and
    /// whether the device is still active. Only the hash is ever read back — the plaintext key does
    /// not exist anywhere in the database.
    /// </summary>
    public async Task<DeviceAuth?> GetAuthBySerialAsync(string serialNumber)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<DeviceAuth>(
            "attendance.usp_Device_GetAuth",
            new { SerialNumber = serialNumber },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Stores the HASH of a newly issued key. Issuing a new key silently invalidates the old one — that is the revocation path.</summary>
    public async Task SetApiKeyHashAsync(int deviceId, string apiKeyHash)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_Device_SetApiKey",
            new { DeviceId = deviceId, ApiKeyHash = apiKeyHash },
            commandType: CommandType.StoredProcedure);
    }
}
