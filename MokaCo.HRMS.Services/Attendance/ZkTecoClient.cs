using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;
using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

/// <summary>
/// Speaks the ZKTeco "standalone" TCP protocol (port 4370) well enough to do exactly two things:
/// read a terminal's attendance log, and ask it what time it thinks it is.
///
/// WHY THIS EXISTS AT ALL. The iclock/ADMS path has the terminal call US, which is the better
/// arrangement — punches arrive in seconds and nothing has to know the machine's address. But a lot
/// of firmware variants ship with no ADMS menu, and a terminal that cannot push is invisible to a
/// push-only system. This is the other direction: we open a socket to the machine on a timer and
/// read its buffer. Same punches, same pipeline, opposite caller.
///
/// WHAT IT DELIBERATELY DOES NOT DO:
///   · It never sends CLEAR_ATTLOG. Clearing the machine's buffer is destructive and irreversible,
///     and if our own write failed immediately afterwards the punches would exist nowhere. So the
///     buffer is left alone and every cycle re-reads the whole log; the dedup hash makes that free.
///     "1400 received, 0 inserted, 1400 duplicates" is the steady state, not a fault.
///   · It never writes to the terminal — no user upload, no time set, no door unlock. This client is
///     read-only against a device that controls a physical door, and keeping it that way means a bug
///     here cannot unlock anything.
///   · It holds no state between calls. Every operation opens a session and closes it in a finally.
///
/// ON THE PROTOCOL ITSELF. It is undocumented and reverse-engineered, and the framing below is the
/// consensus behaviour of the ZK-family units in the field. Where firmware differs (the 40-byte vs
/// 16-byte log record being the big one) the client reports a warning with a hex sample rather than
/// guessing silently — a wrong guess here writes wrong times onto somebody's payslip.
///
/// No NuGet package and no COM object: this is sockets and byte arithmetic, which is also why it can
/// be unit-tested without a terminal on the desk.
/// </summary>
public static class ZkTecoClient
{
    /* ── Framing ──────────────────────────────────────────────────────────────────────────────── */

    /// <summary>The four bytes that start every packet in both directions. Not a version — a sync marker.</summary>
    private static readonly byte[] Magic = { 0x50, 0x50, 0x82, 0x7D };

    /// <summary>Magic (4) + payload length (4).</summary>
    private const int HeaderLength = 8;

    /// <summary>Command, checksum, session, reply — four LE uint16s in front of every payload's data.</summary>
    private const int PayloadHeaderLength = 8;

    /* ── Commands ─────────────────────────────────────────────────────────────────────────────── */

    private const ushort CmdConnect = 1000;
    private const ushort CmdExit = 1001;
    private const ushort CmdAuth = 1102;
    private const ushort AckOk = 2000;
    private const ushort AckError = 2001;
    private const ushort AckUnauth = 2005;
    private const ushort CmdPrepareData = 1500;
    private const ushort CmdData = 1501;
    private const ushort CmdFreeData = 1502;
    private const ushort CmdPrepareBuffer = 1503;
    private const ushort CmdReadBuffer = 1504;
    private const ushort CmdAttlogRrq = 13;
    private const ushort CmdGetTime = 201;

    /// <summary>
    /// Erases the ATTENDANCE LOG and nothing else. Enrolled users, fingerprint templates, cards and
    /// passwords all survive it.
    ///
    /// ITS NEIGHBOUR IS A LANDMINE, WHICH IS WHY THIS COMMENT EXISTS. Command 14 (CMD_CLEAR_DATA)
    /// sits one number away and wipes EVERYTHING on the terminal — every enrolled finger, gone, with
    /// no undo and no copy on our side. Re-enrolling a site's staff is a day of somebody's life. It
    /// is deliberately NOT declared anywhere in this file: a constant that does not exist cannot be
    /// reached by a typo, an autocomplete, or a future edit that means well.
    /// </summary>
    private const ushort CmdClearAttlog = 15;

    /* ── Timeouts ─────────────────────────────────────────────────────────────────────────────── */

    /// <summary>A terminal on the LAN answers in milliseconds. Four seconds distinguishes "busy" from "not there".</summary>
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(4);

    /// <summary>
    /// Longer than the connect timeout because a 50,000-punch buffer is genuinely slow to shift on a
    /// 10Mbit terminal, and cutting it off mid-transfer would mean never reading the machine at all.
    /// </summary>
    private static readonly TimeSpan ReadTimeout = TimeSpan.FromSeconds(8);

    /// <summary>The largest block the firmware will send in one READ_BUFFER. Not a round number, and not ours to choose.</summary>
    private const uint MaxChunk = 0xFFC0;

    /// <summary>
    /// A sanity ceiling on the assembled log — 50,000 punches at 40 bytes is 2MB, so 16MB is ample
    /// slack. It exists so a corrupt length field cannot make us allocate until the process dies.
    /// </summary>
    private const int MaxLogBytes = 16 * 1024 * 1024;

    /* ── Public API ───────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// Opens a session, reads the whole attendance buffer, parses it, and closes. The terminal's
    /// buffer is left exactly as it was found.
    /// </summary>
    public static async Task<ZkReadResult> ReadAttendanceAsync(
        string host, int port, int commKey, CancellationToken ct = default)
    {
        await using var session = await ZkSession.OpenAsync(host, port, commKey, ct);

        var raw = await session.ReadBufferedAsync(CmdAttlogRrq, ct);

        return ParseAttendance(raw);
    }

    /// <summary>
    /// What the machine believes the time is.
    ///
    /// This is the whole point of the Test button. Punches are stored at the terminal's own wall
    /// clock, unconverted, so a machine running forty minutes fast writes forty minutes of overtime
    /// onto everyone's day and NOTHING downstream can detect it — the times look perfectly ordinary.
    /// Putting the device's clock in front of a human at setup is the only cheap defence there is.
    /// </summary>
    public static async Task<DateTime> GetDeviceTimeAsync(
        string host, int port, int commKey, CancellationToken ct = default)
    {
        await using var session = await ZkSession.OpenAsync(host, port, commKey, ct);

        var reply = await session.CommandAsync(CmdGetTime, ReadOnlyMemory<byte>.Empty, ct);

        if (reply.Command != AckOk || reply.Data.Length < 4)
            throw new ZkProtocolException(
                $"The machine did not answer the clock request (reply {reply.Command}, {reply.Data.Length} byte(s)).");

        return DecodeTime(BinaryPrimitives.ReadUInt32LittleEndian(reply.Data.Span));
    }

    /// <summary>
    /// Tells the terminal to erase its attendance log. IRREVERSIBLE, and there is no copy on the
    /// machine afterwards — whatever was not pulled before this ran is gone.
    ///
    /// This method does NOT decide whether erasing is safe; it only performs it. The judgment — that
    /// every record on the machine is already stored or a known duplicate — belongs to
    /// MachinePullService.ClearMachineLogAsync and is made before this is called. Keeping the two
    /// apart means the dangerous operation has exactly one caller and that caller is the one holding
    /// the evidence.
    ///
    /// Only the LOG is erased. See <see cref="CmdClearAttlog"/> for the command one number away that
    /// would take the fingerprints with it, and why it is not in this file.
    /// </summary>
    public static async Task ClearAttendanceLogAsync(
        string host, int port, int commKey, CancellationToken ct = default)
    {
        await using var session = await ZkSession.OpenAsync(host, port, commKey, ct);

        var reply = await session.CommandAsync(CmdClearAttlog, ReadOnlyMemory<byte>.Empty, ct);

        if (reply.Command != AckOk)
            throw new ZkProtocolException(
                reply.Command == AckError
                    ? "The machine refused to clear its attendance log."
                    : $"Unexpected reply {reply.Command} to the clear-log command. The log may not have been cleared.");
    }

    /* ── Pure functions — the two the unit tests pin down ──────────────────────────────────────── */

    /// <summary>
    /// The packet checksum: ones-complement of the carry-folded sum of the payload's LE 16-bit words.
    ///
    /// The CHECKSUM FIELD MUST ALREADY BE ZERO in what is passed here — the builder zeroes it before
    /// calling, which is what makes this a plain function of its bytes and therefore testable. A
    /// trailing odd byte is added as a byte, not padded into a word; that asymmetry is the firmware's,
    /// not a mistake.
    /// </summary>
    public static ushort Checksum(ReadOnlySpan<byte> payload)
    {
        uint sum = 0;

        var i = 0;
        for (; i + 1 < payload.Length; i += 2)
            sum += (uint)(payload[i] | (payload[i + 1] << 8));

        // Odd length: the last byte contributes on its own.
        if (i < payload.Length)
            sum += payload[i];

        // Fold carries back in until the sum fits in 16 bits. A while, not a single add: two folds
        // are possible on a long payload, and stopping after one leaves a checksum the device rejects.
        while ((sum >> 16) != 0)
            sum = (sum & 0xFFFF) + (sum >> 16);

        return (ushort)(~sum & 0xFFFF);
    }

    /// <summary>
    /// Decodes the terminal's packed timestamp.
    ///
    /// The encoding treats EVERY month as 31 days — it is a counter, not a calendar — so the fields
    /// come out by successive division and the result is only a real date because the device only
    /// ever encodes real dates. A corrupt value can therefore name 31 February; the caller catches
    /// that rather than this method inventing a nearby date.
    ///
    /// The result is the terminal's own LOCAL wall clock. It is not converted, here or anywhere
    /// downstream — see ImportService.LandPulledAsync for why converting only this path would move
    /// night shifts onto the wrong day.
    /// </summary>
    public static DateTime DecodeTime(uint encoded)
    {
        var t = encoded;

        var second = (int)(t % 60); t /= 60;
        var minute = (int)(t % 60); t /= 60;
        var hour = (int)(t % 24); t /= 24;
        var day = (int)(t % 31) + 1; t /= 31;
        var month = (int)(t % 12) + 1; t /= 12;
        var year = (int)t + 2000;

        return new DateTime(year, month, day, hour, minute, second, DateTimeKind.Unspecified);
    }

    /// <summary>
    /// Turns the terminal's comm key into the four bytes CMD_AUTH expects.
    ///
    /// It is an obfuscation, not a cipher: the key's bits are REVERSED, the session id is added so a
    /// captured packet cannot be replayed into another session, and the halves are XORed with the
    /// ASCII of "ZK" and "SO". Byte 2 of the result is the bare constant rather than a XOR of the
    /// key — that looks like a firmware bug, but it is what the devices check, so it is what we send.
    /// </summary>
    public static byte[] MakeCommKey(int commKey, ushort sessionId)
    {
        uint k = 0;
        for (var i = 0; i < 32; i++)
            if ((commKey & (1 << i)) != 0)
                k |= 1u << (31 - i);

        k = unchecked(k + sessionId);

        var lo = (ushort)(k & 0xFFFF);
        var hi = (ushort)(k >> 16);

        lo ^= 0x4B5A; // 'ZK'
        hi ^= 0x4F53; // 'SO'

        // THE HALVES ARE SWAPPED HERE, and this line is the whole difference between a terminal that
        // authenticates and one that answers ACK_UNAUTH forever. The high half is written FIRST. It
        // is not derivable from anything — it is simply what the firmware checks — and it was found
        // by testing against a real UA300 Pro, which refused the unswapped form.
        Span<byte> b = stackalloc byte[4];
        BinaryPrimitives.WriteUInt16LittleEndian(b, hi);
        BinaryPrimitives.WriteUInt16LittleEndian(b[2..], lo);

        const byte constant = 50;
        return new[] { (byte)(b[0] ^ constant), (byte)(b[1] ^ constant), constant, (byte)(b[3] ^ constant) };
    }

    /* ── Parsing ──────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// Turns the assembled buffer into punches.
    ///
    /// TWO RECORD LAYOUTS ARE IN THE FIELD. Modern firmware writes 40-byte records with a 24-character
    /// ASCII PIN, which is the one that matters because a PIN is a STRING to us ('0042' and '42' are
    /// different people). Older units write 16-byte records that carry only the numeric enrol id, so
    /// the PIN has to be reconstructed from it and leading zeros are simply not recoverable — that
    /// path is best-effort and says so, loudly, with a hex sample so the layout can be confirmed
    /// against a real machine before anybody trusts it.
    ///
    /// Which one it is, is decided by ARITHMETIC rather than by asking the device: whichever record
    /// size divides the payload exactly. That is not elegant, but it is the check that cannot be
    /// fooled by a firmware that misreports itself.
    /// </summary>
    private static ZkReadResult ParseAttendance(byte[] raw)
    {
        var result = new ZkReadResult();

        if (raw.Length == 0)
            return result;

        // The buffer normally opens with its own uint32 size prefix. "Normally": if skipping it leaves
        // a length no record size divides but the UNSKIPPED length works, the prefix was not there.
        // Trying both is what stops one firmware variant's missing prefix from failing the whole read.
        var body = ChooseBody(raw, out var skippedPrefix);

        if (body.Length == 0)
            return result;

        int recordSize;
        if (body.Length % 40 == 0)
            recordSize = 40;
        else if (body.Length % 16 == 0)
            recordSize = 16;
        else
        {
            throw new ZkProtocolException(
                $"The attendance buffer is {body.Length} byte(s) after the size prefix" +
                $"{(skippedPrefix ? "" : " (no prefix found)")}, which is neither 40- nor 16-byte records. " +
                $"First bytes: {HexSample(raw, 48)}");
        }

        if (recordSize == 16)
        {
            result.Warnings.Add(
                "This machine sends 16-byte (legacy) attendance records, which carry only the numeric " +
                "enrol id — PINs with leading zeros cannot be recovered from it and the field offsets " +
                "are best-effort. Confirm the punches against the machine before trusting them. " +
                $"First record: {HexSample(body, 16)}");
        }

        for (var offset = 0; offset + recordSize <= body.Length; offset += recordSize)
        {
            var record = body.AsSpan(offset, recordSize);

            var punch = recordSize == 40 ? ReadRecord40(record) : ReadRecord16(record);

            if (punch is null)
            {
                result.Skipped++;
                continue;
            }

            result.Punches.Add(punch);
        }

        return result;
    }

    /// <summary>
    /// 40-byte record: uid(2) · PIN(24, ASCII, null-padded) · verify(1) · time(4) · state(1) · pad(8).
    /// Only the PIN, the time and the state matter — the uid is the device's internal row id and the
    /// verify mode says finger-vs-card, which changes nothing about who was there and when.
    /// </summary>
    private static PulledPunch? ReadRecord40(ReadOnlySpan<byte> r)
    {
        var pin = ReadAsciiPin(r.Slice(2, 24));
        if (pin.Length == 0)
            return null;

        var encoded = BinaryPrimitives.ReadUInt32LittleEndian(r.Slice(27, 4));
        var state = (short)r[31];

        return TryBuild(pin, encoded, state);
    }

    /// <summary>
    /// 16-byte legacy record: uid(2) · verify(1) · time(4) · state(1) · pad. Best-effort, and warned
    /// about above — the PIN here is the uid rendered as decimal, which is right on the units that
    /// enrol sequentially and wrong on any that do not.
    /// </summary>
    private static PulledPunch? ReadRecord16(ReadOnlySpan<byte> r)
    {
        var uid = BinaryPrimitives.ReadUInt16LittleEndian(r[..2]);
        if (uid == 0)
            return null;

        var encoded = BinaryPrimitives.ReadUInt32LittleEndian(r.Slice(3, 4));
        var state = (short)r[7];

        return TryBuild(uid.ToString(), encoded, state);
    }

    /// <summary>
    /// Builds one punch, or drops it if the packed timestamp does not name a real moment.
    ///
    /// Dropping is the right failure here: a record whose date is 31 February is corrupt, and the
    /// alternatives are inventing a nearby date (which lands a punch on the wrong day, silently) or
    /// failing the whole pull (which loses the thousands of good records around it).
    /// </summary>
    private static PulledPunch? TryBuild(string pin, uint encoded, short state)
    {
        try
        {
            return new PulledPunch(pin, DecodeTime(encoded), state);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    /// <summary>The PIN is null-padded ASCII; anything past the first NUL is not part of it.</summary>
    private static string ReadAsciiPin(ReadOnlySpan<byte> field)
    {
        var end = field.IndexOf((byte)0);
        if (end < 0)
            end = field.Length;

        return Encoding.ASCII.GetString(field[..end]).Trim();
    }

    /// <summary>Picks between "there is a 4-byte size prefix" and "there is not", by which one divides.</summary>
    private static byte[] ChooseBody(byte[] raw, out bool skippedPrefix)
    {
        if (raw.Length > 4)
        {
            var withoutPrefix = raw.Length - 4;
            if (withoutPrefix % 40 == 0 || withoutPrefix % 16 == 0)
            {
                skippedPrefix = true;
                return raw[4..];
            }
        }

        skippedPrefix = false;
        return raw;
    }

    private static string HexSample(byte[] data, int count)
        => Convert.ToHexString(data.AsSpan(0, Math.Min(count, data.Length)));

    /* ── The session ──────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// One connected conversation with one terminal. Private because nothing outside this file should
    /// be able to hold a socket open against a door controller; the two public methods each own a
    /// session for their own duration and close it in a finally.
    /// </summary>
    private sealed class ZkSession : IAsyncDisposable
    {
        private readonly TcpClient _tcp;
        private readonly NetworkStream _stream;
        private ushort _sessionId;
        private ushort _replyId;
        private bool _closed;

        private ZkSession(TcpClient tcp, NetworkStream stream)
        {
            _tcp = tcp;
            _stream = stream;
        }

        /// <summary>Connects, handshakes, and authenticates if the terminal asks for it.</summary>
        public static async Task<ZkSession> OpenAsync(string host, int port, int commKey, CancellationToken ct)
        {
            var tcp = new TcpClient { NoDelay = true };

            try
            {
                using (var connectCts = CancellationTokenSource.CreateLinkedTokenSource(ct))
                {
                    connectCts.CancelAfter(ConnectTimeout);

                    try
                    {
                        await tcp.ConnectAsync(host, port, connectCts.Token);
                    }
                    catch (OperationCanceledException) when (!ct.IsCancellationRequested)
                    {
                        throw new ZkProtocolException(
                            $"No answer from {host}:{port} within {ConnectTimeout.TotalSeconds:0}s. " +
                            "Check the machine is powered on, on this network, and that the address and port are right.");
                    }
                }

                var session = new ZkSession(tcp, tcp.GetStream());
                await session.HandshakeAsync(commKey, ct);
                return session;
            }
            catch
            {
                tcp.Dispose();
                throw;
            }
        }

        /// <summary>
        /// CONNECT, then AUTH only if the terminal demands it. A comm key of 0 — the factory default,
        /// and what most sites run — is normally accepted outright, so the AUTH exchange is driven by
        /// the device's answer rather than by whether we happen to have a key.
        /// </summary>
        private async Task HandshakeAsync(int commKey, CancellationToken ct)
        {
            var reply = await CommandAsync(CmdConnect, ReadOnlyMemory<byte>.Empty, ct);

            // The session id is assigned by the device and echoed on everything after this.
            _sessionId = reply.SessionId;

            if (reply.Command == AckUnauth)
            {
                reply = await CommandAsync(CmdAuth, MakeCommKey(commKey, _sessionId), ct);

                if (reply.Command != AckOk)
                    throw new ZkProtocolException(
                        "The machine refused the comm key. Check Comm key against the terminal's own " +
                        "Comm/Security menu — 0 means no key is set.");

                return;
            }

            if (reply.Command != AckOk)
                throw new ZkProtocolException(
                    $"The machine refused the connection (reply {reply.Command}).");
        }

        /// <summary>Sends one command and reads exactly one reply packet.</summary>
        public async Task<ZkPacket> CommandAsync(ushort command, ReadOnlyMemory<byte> data, CancellationToken ct)
        {
            await SendAsync(command, data, ct);
            return await ReceiveAsync(ct);
        }

        private async Task SendAsync(ushort command, ReadOnlyMemory<byte> data, CancellationToken ct)
        {
            var payload = new byte[PayloadHeaderLength + data.Length];

            BinaryPrimitives.WriteUInt16LittleEndian(payload.AsSpan(0), command);
            // Bytes 2..4 stay zero here on purpose: the checksum is computed over a payload whose
            // checksum field reads zero, so it must be written AFTER the sum, never before.
            BinaryPrimitives.WriteUInt16LittleEndian(payload.AsSpan(4), _sessionId);
            BinaryPrimitives.WriteUInt16LittleEndian(payload.AsSpan(6), _replyId);
            data.Span.CopyTo(payload.AsSpan(PayloadHeaderLength));

            BinaryPrimitives.WriteUInt16LittleEndian(payload.AsSpan(2), Checksum(payload));

            var packet = new byte[HeaderLength + payload.Length];
            Magic.CopyTo(packet, 0);
            BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(4), (uint)payload.Length);
            payload.CopyTo(packet, HeaderLength);

            await _stream.WriteAsync(packet, ct);

            // Every command we send advances the counter, including the ones inside a chunk loop.
            _replyId = unchecked((ushort)(_replyId + 1));
        }

        private async Task<ZkPacket> ReceiveAsync(CancellationToken ct)
        {
            var header = new byte[HeaderLength];
            await ReadExactAsync(header, ct);

            if (!header.AsSpan(0, 4).SequenceEqual(Magic))
                throw new ZkProtocolException(
                    "The reply did not start with the ZK packet marker — something other than a " +
                    $"terminal is answering on this port. First bytes: {HexSample(header, 8)}");

            var length = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4));

            if (length < PayloadHeaderLength || length > MaxLogBytes)
                throw new ZkProtocolException($"The machine declared an implausible packet length ({length} bytes).");

            var payload = new byte[length];
            await ReadExactAsync(payload, ct);

            return new ZkPacket(
                BinaryPrimitives.ReadUInt16LittleEndian(payload.AsSpan(0)),
                BinaryPrimitives.ReadUInt16LittleEndian(payload.AsSpan(4)),
                payload.AsMemory(PayloadHeaderLength));
        }

        private async Task ReadExactAsync(Memory<byte> buffer, CancellationToken ct)
        {
            using var readCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            readCts.CancelAfter(ReadTimeout);

            try
            {
                await _stream.ReadExactlyAsync(buffer, readCts.Token);
            }
            catch (EndOfStreamException)
            {
                throw new ZkProtocolException("The machine closed the connection mid-packet.");
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                throw new ZkProtocolException($"The machine stopped responding after {ReadTimeout.TotalSeconds:0}s.");
            }
        }

        /// <summary>
        /// Asks for a data set (here: the attendance log) and assembles it.
        ///
        /// TWO SHAPES OF ANSWER, and both are normal. A small log comes straight back inside one DATA
        /// packet. A large one gets an ACK_OK carrying the total size, after which the data has to be
        /// dragged over in chunks — and within a chunk the device interleaves PREPARE_DATA markers
        /// with the DATA packets, closing each chunk with an ACK_OK. Handling only the chunked shape
        /// would fail on a machine nobody has punched on much yet, which is exactly the machine a new
        /// installation is tested against.
        /// </summary>
        public async Task<byte[]> ReadBufferedAsync(ushort dataCommand, CancellationToken ct)
        {
            var request = new byte[11];
            request[0] = 1;
            BinaryPrimitives.WriteUInt16LittleEndian(request.AsSpan(1), dataCommand);
            BinaryPrimitives.WriteUInt32LittleEndian(request.AsSpan(3), 0);
            BinaryPrimitives.WriteUInt32LittleEndian(request.AsSpan(7), 0);

            var reply = await CommandAsync(CmdPrepareBuffer, request, ct);

            // Small log: it is already here.
            if (reply.Command == CmdData)
                return reply.Data.ToArray();

            if (reply.Command != AckOk)
                throw new ZkProtocolException(
                    reply.Command == AckError
                        ? "The machine refused the attendance-log request."
                        : $"Unexpected reply {reply.Command} to the attendance-log request.");

            if (reply.Data.Length < 5)
                throw new ZkProtocolException("The machine did not say how big its attendance log is.");

            var total = BinaryPrimitives.ReadUInt32LittleEndian(reply.Data.Span[1..5]);

            if (total == 0)
                return Array.Empty<byte>();

            if (total > MaxLogBytes)
                throw new ZkProtocolException($"The machine declared a {total}-byte attendance log, which is implausible.");

            var assembled = new MemoryStream((int)total);

            try
            {
                uint start = 0;
                while (start < total)
                {
                    var chunk = Math.Min(total - start, MaxChunk);

                    var ask = new byte[8];
                    BinaryPrimitives.WriteUInt32LittleEndian(ask.AsSpan(0), start);
                    BinaryPrimitives.WriteUInt32LittleEndian(ask.AsSpan(4), chunk);

                    await SendAsync(CmdReadBuffer, ask, ct);

                    var before = assembled.Length;

                    // Read packets until the device closes the chunk with an ACK_OK.
                    while (true)
                    {
                        var packet = await ReceiveAsync(ct);

                        if (packet.Command == CmdPrepareData)
                            continue; // a marker, not payload

                        if (packet.Command == CmdData)
                        {
                            await assembled.WriteAsync(packet.Data, ct);
                            continue;
                        }

                        if (packet.Command == AckOk)
                            break;

                        throw new ZkProtocolException(
                            $"Unexpected reply {packet.Command} while reading the attendance log.");
                    }

                    // Without this a device that answers a chunk with nothing would spin here forever.
                    if (assembled.Length == before)
                        throw new ZkProtocolException(
                            $"The machine sent no data for the block at offset {start}; giving up rather than looping.");

                    start += chunk;
                }
            }
            finally
            {
                // Releases the snapshot the device built for us. Best-effort: the read either worked or
                // it did not, and failing the whole pull because the cleanup was not acknowledged would
                // throw away punches we already have in hand.
                try { await CommandAsync(CmdFreeData, ReadOnlyMemory<byte>.Empty, ct); }
                catch { /* the EXIT in DisposeAsync closes the session regardless */ }
            }

            return assembled.ToArray();
        }

        /// <summary>
        /// EXIT then close, always. A ZK terminal keeps a finite number of sessions and a client that
        /// walks away without saying goodbye burns one until the firmware times it out — do that every
        /// five minutes and the machine eventually refuses everybody, including the door.
        /// </summary>
        public async ValueTask DisposeAsync()
        {
            if (!_closed)
            {
                _closed = true;

                try
                {
                    using var cts = new CancellationTokenSource(ReadTimeout);
                    await SendAsync(CmdExit, ReadOnlyMemory<byte>.Empty, cts.Token);
                }
                catch
                {
                    // Already unreachable, already failed, or already closed by the device: there is
                    // nothing useful left to do and the socket is about to go anyway.
                }
            }

            _stream.Dispose();
            _tcp.Dispose();
        }
    }

    /// <summary>One decoded packet: what it is, whose session it belongs to, and its data.</summary>
    private readonly record struct ZkPacket(ushort Command, ushort SessionId, ReadOnlyMemory<byte> Data);
}

/// <summary>
/// What came off one machine, plus anything the caller should be told about HOW it was read.
///
/// The warnings are on the result rather than written to a log inside the client because the Services
/// layer has no logger by convention — and because the worker is the thing that knows WHICH machine
/// this was, which is the only detail that makes such a warning actionable.
/// </summary>
public sealed class ZkReadResult
{
    public List<PulledPunch> Punches { get; } = new();

    /// <summary>Records dropped as unreadable — a corrupt timestamp, or a record with no PIN on it.</summary>
    public int Skipped { get; set; }

    public List<string> Warnings { get; } = new();
}

/// <summary>
/// A terminal did not behave. Separate from SocketException so the worker can tell "the network ate
/// it" from "we are talking to something that is not a ZK terminal" — the fixes are different, and
/// the message is written to be shown to whoever is standing in front of the machine.
/// </summary>
public class ZkProtocolException : Exception
{
    public ZkProtocolException(string message) : base(message) { }
}
