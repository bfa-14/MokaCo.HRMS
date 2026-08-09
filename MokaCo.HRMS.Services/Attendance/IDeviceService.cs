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

    /* -- device push authentication -- */
    Task<DeviceApiKeyResult?> IssueApiKeyAsync(int deviceId, string serialNumber);
    Task<Device?> AuthenticateAsync(string serialNumber, string apiKey);
}
