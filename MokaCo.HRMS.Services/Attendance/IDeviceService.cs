using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

public interface IDeviceService
{
    Task<IEnumerable<Device>> GetAllAsync();
    Task<Device?> GetBySerialAsync(string serialNumber);
    Task<int> CreateAsync(DeviceCreateRequest request);
    Task UpdateAsync(int deviceId, DeviceUpdateRequest request);

    Task<IEnumerable<EmployeeDevice>> GetEnrollmentsAsync();
    Task<EnrollmentMapResult> MapAsync(EnrollmentMapRequest request);
    Task UnmapAsync(int employeeDeviceId);

    /* -- ADMS push (see docs/attendance_iclock_adms.sql) -- */

    /// <summary>
    /// Resolves a terminal from the serial it puts in its own URL, and says whether it is allowed
    /// to talk to us at all. Returns null for BOTH "never heard of it" and "retired", because the
    /// caller must not turn the endpoint into a way of enumerating our terminals.
    /// </summary>
    Task<Device?> AuthoriseBySerialAsync(string serialNumber);

    Task TouchSyncAsync(int deviceId);
    Task TouchPushAsync(int deviceId);

    /* -- device push authentication -- */
    Task<DeviceApiKeyResult?> IssueApiKeyAsync(int deviceId, string serialNumber);
    Task<Device?> AuthenticateAsync(string serialNumber, string apiKey);
}
