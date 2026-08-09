using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Repository.Attendance;

public interface IDeviceRepository
{
    Task<IEnumerable<Device>> GetAllAsync();
    Task<Device?> GetBySerialAsync(string serialNumber);
    Task<int> CreateAsync(string serialNumber, int branchId, int? departmentId);
    Task UpdateAsync(int deviceId, string serialNumber, int branchId, int? departmentId, bool isActive);
    Task TouchSyncAsync(int deviceId);

    Task<IEnumerable<EmployeeDevice>> GetEnrollmentsAsync();
    Task<EnrollmentMapResult> MapAsync(int employeeId, int deviceId, string enrollPin);
    Task UnmapAsync(int employeeDeviceId);

    /* -- device push authentication (see docs/attendance_device_apikey.sql) -- */
    Task<DeviceAuth?> GetAuthBySerialAsync(string serialNumber);
    Task SetApiKeyHashAsync(int deviceId, string apiKeyHash);
}
