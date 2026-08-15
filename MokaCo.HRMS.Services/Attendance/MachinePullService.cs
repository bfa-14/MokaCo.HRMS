using System.Collections.Concurrent;
using System.Net.Sockets;
using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

/// <summary>
/// One lock per machine, for the whole process.
///
/// The timer and the "Pull now" button are two callers who want the same socket, and a ZK terminal
/// handles a second concurrent session by refusing it — so without this, pressing the button while
/// a cycle happens to be running would fail the cycle and blame the machine. Per DEVICE, not global:
/// four terminals should be pulled without queueing behind each other.
///
/// Registered as a SINGLETON. A per-request registry would hand every caller its own semaphore and
/// lock nothing at all, which is the failure mode this type exists to make impossible.
/// </summary>
public sealed class DevicePullLocks
{
    private readonly ConcurrentDictionary<int, SemaphoreSlim> _locks = new();

    public SemaphoreSlim For(int deviceId)
        => _locks.GetOrAdd(deviceId, _ => new SemaphoreSlim(1, 1));
}

public interface IMachinePullService
{
    /// <summary>The machines the worker should visit this cycle.</summary>
    Task<IEnumerable<PullTarget>> GetTargetsAsync();

    /// <summary>
    /// Reads one machine and lands what it has. Never throws for an unreachable or misbehaving
    /// terminal — the failure comes back on the result AND is recorded against the device, because
    /// one dead machine must not stop the others or the caller that asked.
    /// </summary>
    Task<DevicePullResult> PullAsync(int deviceId, CancellationToken ct = default);

    /// <summary>Connects, asks the machine its time, disconnects. Reads no punches and changes nothing.</summary>
    Task<DeviceTestResult> TestConnectionAsync(int deviceId, CancellationToken ct = default);

    /// <summary>
    /// Rescues everything still on the machine, and ONLY THEN erases the machine's own log. Refuses
    /// to erase anything if that rescue was not provably complete. Enrolled users and fingerprints
    /// are never touched.
    /// </summary>
    Task<MachineClearResult> ClearMachineLogAsync(int deviceId, CancellationToken ct = default);
}

/// <summary>
/// The pull half of attendance ingestion: find the machines, read them, hand what they had to the
/// same landing path as push and Excel, and record what happened on the device.
///
/// It owns NO protocol knowledge (that is ZkTecoClient) and NO landing logic (that is
/// ImportService.LandPulledAsync). What it owns is the sequencing and the failure policy, which is
/// the part that has to be identical whether a timer or a button started it — that is why the button
/// does not have its own copy of this.
/// </summary>
public class MachinePullService : IMachinePullService
{
    /// <summary>Matches the nvarchar(300) the error column holds. Truncating here beats a SQL error that loses the message entirely.</summary>
    private const int MaxErrorLength = 300;

    private readonly IDeviceService _devices;
    private readonly IImportService _import;
    private readonly DevicePullLocks _locks;

    public MachinePullService(IDeviceService devices, IImportService import, DevicePullLocks locks)
    {
        _devices = devices;
        _import = import;
        _locks = locks;
    }

    public Task<IEnumerable<PullTarget>> GetTargetsAsync() => _devices.GetPullTargetsAsync();

    public async Task<DevicePullResult> PullAsync(int deviceId, CancellationToken ct = default)
    {
        var result = new DevicePullResult();

        var device = await FindAsync(deviceId);

        if (device is null)
        {
            result.Error = "No such device.";
            return result;
        }

        if (string.IsNullOrWhiteSpace(device.PullIp))
        {
            // Not recorded against the device: this is a configuration gap, not a machine fault, and
            // writing it to LastPullError would make the Devices page accuse a terminal of being
            // unreachable when nobody has yet said where it is.
            result.Error = "This machine has no address configured. Set its IP on the device record first.";
            return result;
        }

        var gate = _locks.For(deviceId);
        await gate.WaitAsync(ct);

        try
        {
            var read = await ZkTecoClient.ReadAttendanceAsync(
                device.PullIp!, device.PullPort, device.PullCommKey, ct);

            result.Warnings.AddRange(read.Warnings);
            result.Unreadable = read.Skipped;

            if (read.Skipped > 0)
                result.Warnings.Add($"{read.Skipped} record(s) were unreadable and were skipped.");

            var landed = await _import.LandPulledAsync(
                deviceId, read.Punches.Select(p => (p.Pin, p.PunchTime, p.PunchType)));

            result.Received = landed.Received;
            result.Inserted = landed.Inserted;
            result.Duplicates = landed.Duplicates;
            result.UnresolvedPins = landed.UnresolvedPins;

            await _devices.TouchPullAsync(deviceId, null);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            // The host is shutting down. Not the machine's fault, so nothing is written against it —
            // a stopped service must not leave every terminal looking broken on the Devices page.
            throw;
        }
        catch (Exception ex)
        {
            result.Error = Describe(ex);
            await _devices.TouchPullAsync(deviceId, Truncate(result.Error));
        }
        finally
        {
            gate.Release();
        }

        return result;
    }

    public async Task<DeviceTestResult> TestConnectionAsync(int deviceId, CancellationToken ct = default)
    {
        var device = await FindAsync(deviceId);

        if (device is null)
            return new DeviceTestResult { Ok = false, Error = "No such device." };

        if (string.IsNullOrWhiteSpace(device.PullIp))
            return new DeviceTestResult { Ok = false, Error = "This machine has no address configured." };

        // Through the same gate as a real pull: a test that opened a second session while a pull was
        // in flight would break the pull and then report the machine as healthy.
        var gate = _locks.For(deviceId);
        await gate.WaitAsync(ct);

        try
        {
            var time = await ZkTecoClient.GetDeviceTimeAsync(
                device.PullIp!, device.PullPort, device.PullCommKey, ct);

            return new DeviceTestResult { Ok = true, DeviceTime = time };
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            // A failed TEST is not recorded against the device. It is a question somebody asked while
            // standing at the machine, not a scheduled attempt, and letting it overwrite LastPullError
            // would rewrite the pull history every time somebody pressed a button.
            return new DeviceTestResult { Ok = false, Error = Describe(ex) };
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>
    /// Rescue, verify, then erase — in that order, and the order is the whole feature.
    ///
    /// THE INVARIANT: the machine's log is erased only when every record on it is provably either
    /// stored or a known duplicate. Clearing is irreversible and the terminal keeps no copy, so
    /// "probably fine" is not good enough; anything we could not read is a punch that would cease to
    /// exist. The refusal path is therefore the important one, and it leaves the machine untouched.
    ///
    /// A LEGACY-LAYOUT READ ALSO BLOCKS IT. Those 16-byte records carry only the numeric enrol id,
    /// so the PIN is reconstructed and leading zeros are unrecoverable — records we admit we may
    /// have mis-attributed. Erasing the only correct copy of something we parsed on a best-effort
    /// basis is exactly the irreversible mistake this guard exists to prevent. (The brief names the
    /// unreadable count; this is the same principle applied to the other way a read can be wrong.)
    ///
    /// It runs under the SAME per-device lock as a pull, so the background worker cannot be halfway
    /// through reading the machine while its buffer is erased underneath it.
    /// </summary>
    public async Task<MachineClearResult> ClearMachineLogAsync(int deviceId, CancellationToken ct = default)
    {
        var result = new MachineClearResult();

        var device = await FindAsync(deviceId);

        if (device is null)
        {
            result.Error = "No such device.";
            return result;
        }

        if (string.IsNullOrWhiteSpace(device.PullIp))
        {
            result.Error = "This machine has no address configured, so its log cannot be read or cleared.";
            return result;
        }

        // The rescue. PullAsync takes the lock itself and never throws for a machine fault, so the
        // failure arrives on the result — and this method's own lock is taken afterwards, not around
        // it, because a SemaphoreSlim(1,1) is not re-entrant and would deadlock against itself.
        var pulled = await PullAsync(deviceId, ct);
        result.PulledBeforeClear = pulled;

        if (pulled.Error is not null)
        {
            result.Error =
                $"Could not read the machine, so nothing was deleted: {pulled.Error}";
            return result;
        }

        if (pulled.Unreadable > 0)
        {
            result.Error =
                $"{pulled.Unreadable} unreadable line(s) — refusing to clear; nothing was deleted. " +
                "Those punches exist only on the machine, and clearing cannot be undone.";
            return result;
        }

        if (pulled.Warnings.Any(w => w.Contains("legacy", StringComparison.OrdinalIgnoreCase)))
        {
            result.Error =
                "This machine sends legacy records whose PINs cannot be read exactly — refusing to " +
                "clear; nothing was deleted. Confirm the punches landed against the right people first.";
            return result;
        }

        var gate = _locks.For(deviceId);
        await gate.WaitAsync(ct);

        try
        {
            await ZkTecoClient.ClearAttendanceLogAsync(
                device.PullIp!, device.PullPort, device.PullCommKey, ct);

            result.Cleared = true;

            await _devices.TouchPullAsync(deviceId, null);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            // The rescue already succeeded, so the punches are safe either way; what failed is the
            // erase. Say so precisely — "nothing was deleted" is the fact the user needs.
            result.Error = $"The punches were read successfully, but the machine refused to clear its log: {Describe(ex)}";
        }
        finally
        {
            gate.Release();
        }

        return result;
    }

    /// <summary>
    /// The device record, read through the ordinary list rather than the pull worklist — so "Pull now"
    /// works on a machine that is configured but NOT yet on the schedule, which is exactly the state
    /// a machine is in while somebody is setting it up and pressing the button to see if it works.
    /// </summary>
    private async Task<Device?> FindAsync(int deviceId)
    {
        var all = await _devices.GetAllAsync();
        return all.FirstOrDefault(d => d.DeviceId == deviceId);
    }

    /// <summary>
    /// Turns an exception into something worth showing a person standing at the terminal. The socket
    /// cases get named because they are the common ones and they have different fixes: refused means
    /// wrong port or the service is off, timed out means wrong address or a firewall.
    /// </summary>
    private static string Describe(Exception ex) => ex switch
    {
        ZkProtocolException zk => zk.Message,

        SocketException { SocketErrorCode: SocketError.ConnectionRefused } =>
            "The machine refused the connection — the address is right but nothing is listening on that port. " +
            "Check the port (4370 normally) and that the terminal's network/comm option is switched on.",

        SocketException { SocketErrorCode: SocketError.TimedOut or SocketError.HostUnreachable or SocketError.NetworkUnreachable } =>
            "Could not reach the machine. Check it is powered on and that the server is on the same network.",

        SocketException se => $"Network error talking to the machine: {se.SocketErrorCode}.",

        _ => ex.Message
    };

    private static string Truncate(string value)
        => value.Length <= MaxErrorLength ? value : value[..MaxErrorLength];
}
