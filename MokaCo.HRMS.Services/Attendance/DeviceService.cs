using System.Security.Cryptography;
using System.Text;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

/// <summary>
/// Terminals, PIN enrollment, and the credential a terminal pushes punches with.
///
/// The enrollment half is a translation table, not a permission check: an employee needs one row
/// per device they may punch on, because a PIN is unique only within a single device.
///
/// The credential half exists because a fingerprint reader has no user and no JWT. See
/// <see cref="AuthenticateAsync"/>.
/// </summary>
public class DeviceService : IDeviceService
{
    private readonly IDeviceRepository _repo;
    public DeviceService(IDeviceRepository repo) => _repo = repo;

    public Task<IEnumerable<Device>> GetAllAsync() => _repo.GetAllAsync();

    public Task<Device?> GetBySerialAsync(string serialNumber) => _repo.GetBySerialAsync(serialNumber);

    public Task<int> CreateAsync(DeviceCreateRequest request)
        => _repo.CreateAsync(request.SerialNumber, request.BranchId, request.DepartmentId);

    public Task UpdateAsync(int deviceId, DeviceUpdateRequest request)
        => _repo.UpdateAsync(deviceId, request.SerialNumber, request.BranchId, request.DepartmentId, request.IsActive);

    public Task<IEnumerable<EmployeeDevice>> GetEnrollmentsAsync() => _repo.GetEnrollmentsAsync();

    /// <summary>
    /// Maps a PIN to a person AND retro-claims the punches that were already waiting on it. The
    /// count that comes back is the point: HR needs to see that the fix recovered 14 punches, not
    /// just that a row was written.
    /// </summary>
    public Task<EnrollmentMapResult> MapAsync(EnrollmentMapRequest request)
        => _repo.MapAsync(request.EmployeeId, request.DeviceId, request.EnrollPin);

    public Task UnmapAsync(int employeeDeviceId) => _repo.UnmapAsync(employeeDeviceId);

    /// <summary>
    /// Issues a fresh API key for a terminal and returns the PLAINTEXT — the only moment it exists.
    /// Only the hash is persisted, so this value cannot be recovered later; a lost key is re-issued.
    /// Issuing also revokes the previous key, because the stored hash is overwritten.
    /// </summary>
    public async Task<DeviceApiKeyResult?> IssueApiKeyAsync(int deviceId, string serialNumber)
    {
        var apiKey = GenerateApiKey();
        await _repo.SetApiKeyHashAsync(deviceId, Hash(apiKey));

        return new DeviceApiKeyResult
        {
            DeviceId = deviceId,
            SerialNumber = serialNumber,
            ApiKey = apiKey
        };
    }

    /// <summary>
    /// Authenticates a pushing terminal from its serial + key. Returns null on ANY failure — unknown
    /// serial, no key ever issued, retired device, or wrong key — because the caller must not be able
    /// to tell those cases apart by probing the punch endpoint.
    ///
    /// The comparison is fixed-time: a plain string equality on a secret leaks its prefix to anyone
    /// patient enough to measure the response.
    /// </summary>
    public async Task<Device?> AuthenticateAsync(string serialNumber, string apiKey)
    {
        if (string.IsNullOrWhiteSpace(serialNumber) || string.IsNullOrWhiteSpace(apiKey))
            return null;

        var auth = await _repo.GetAuthBySerialAsync(serialNumber);

        // Unknown device, a device nobody ever issued a key for, or one that has been retired.
        if (auth is null || !auth.IsActive || string.IsNullOrEmpty(auth.ApiKeyHash))
            return null;

        if (!FixedTimeEquals(Hash(apiKey), auth.ApiKeyHash))
            return null;

        var device = await _repo.GetBySerialAsync(serialNumber);

        // The terminal proved it is alive, so record that — a stale LastSyncUtc is how a dead
        // device gets noticed before payroll does.
        if (device is not null)
            await _repo.TouchSyncAsync(device.DeviceId);

        return device;
    }

    /// <summary>256 bits from a cryptographic RNG, URL-safe. Long enough that guessing it is not a strategy.</summary>
    private static string GenerateApiKey()
    {
        var bytes = RandomNumberGenerator.GetBytes(32);
        return Convert.ToBase64String(bytes)
            .Replace("+", "-")
            .Replace("/", "_")
            .TrimEnd('=');
    }

    private static string Hash(string value)
        => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    /// <summary>Length-independent, content-fixed-time comparison — never short-circuits on the first differing byte.</summary>
    private static bool FixedTimeEquals(string a, string b)
        => CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(a),
            Encoding.UTF8.GetBytes(b));
}
