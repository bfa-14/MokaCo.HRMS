using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Repository.Attendance;

public interface IDeviceRepository
{
    Task<IEnumerable<Device>> GetAllAsync();
    Task<Device?> GetBySerialAsync(string serialNumber);
    Task<int> CreateAsync(string serialNumber, string? name, int branchId, int? departmentId,
        string? pullIp, int pullPort, int pullCommKey, bool pullEnabled);

    Task UpdateAsync(int deviceId, string serialNumber, string? name, int branchId, int? departmentId, bool isActive,
        string? pullIp, int pullPort, int pullCommKey, bool pullEnabled);

    /// <summary>"This terminal is alive." Contact of any kind — including a bare command poll.</summary>
    Task TouchSyncAsync(int deviceId);

    /// <summary>"This terminal is alive AND recording." Stamps contact too, since a push proves both.</summary>
    Task TouchPushAsync(int deviceId);

    /* -- pull: the SERVER calling the terminal (see 10_device_pull.sql) -- */

    /// <summary>The polling worker's worklist: active machines with pulling switched on and an address to call.</summary>
    Task<IEnumerable<PullTarget>> GetPullTargetsAsync();

    /// <summary>
    /// Records the outcome of ONE pull attempt; a null error means success. Success also stamps
    /// LastSyncUtc, because a machine we just read from is self-evidently alive — and a pulled
    /// machine never calls us the way a pushing one does, so nothing else would ever set it.
    /// </summary>
    Task TouchPullAsync(int deviceId, string? error);

    Task<IEnumerable<EmployeeDevice>> GetEnrollmentsAsync();
    Task<EnrollmentMapResult> MapAsync(int employeeId, int deviceId, string enrollPin);
    Task UnmapAsync(int employeeDeviceId);

    /* -- device push authentication (see docs/attendance_device_apikey.sql) -- */
    Task<DeviceAuth?> GetAuthBySerialAsync(string serialNumber);
    Task SetApiKeyHashAsync(int deviceId, string apiKeyHash);
}
