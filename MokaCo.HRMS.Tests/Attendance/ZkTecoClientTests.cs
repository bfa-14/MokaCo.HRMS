using MokaCo.HRMS.Services.Attendance;

namespace MokaCo.HRMS.Tests.Attendance;

/// <summary>
/// The two pure functions in the ZK protocol client, pinned down.
///
/// They are worth testing precisely because they cannot be checked by eye and both fail SILENTLY.
/// A checksum whose carry fold is wrong produces a packet the terminal ignores, so the machine looks
/// unreachable rather than misprogrammed. A time decoder that is off produces punches at plausible
/// but wrong times, which is worse: nothing downstream can tell, and the error reaches a payslip.
///
/// Everything else in the client needs a terminal on the other end of a socket; these two do not,
/// which is why they were separated out as static methods in the first place.
/// </summary>
public class ZkTecoClientTests
{
    /* ── Checksum ─────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// A real CONNECT payload: command 1000 (0x03E8) with a zeroed checksum field, session 0, reply 0.
    /// Sum is 0x03E8, no carry, so the answer is its ones-complement — the packet that opens every
    /// session, and the one to check first if a terminal will not talk at all.
    /// </summary>
    [Fact]
    public void Checksum_ConnectPacket()
    {
        byte[] payload = { 0xE8, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

        Assert.Equal(0xFC17, ZkTecoClient.Checksum(payload));
    }

    /// <summary>
    /// THE CARRY FOLD, which is the part that is easy to get wrong. 0xFFFF + 0xFFFF = 0x1FFFE, which
    /// must fold to 0xFFFE + 1 = 0xFFFF and complement to 0. An implementation that truncated to 16
    /// bits instead of folding would answer 0x0001 here.
    /// </summary>
    [Fact]
    public void Checksum_FoldsCarry()
    {
        byte[] payload = { 0xFF, 0xFF, 0xFF, 0xFF };

        Assert.Equal(0x0000, ZkTecoClient.Checksum(payload));
    }

    /// <summary>
    /// An odd-length payload. The trailing byte is added AS A BYTE, not padded up into a word — so
    /// 0x0001 + 0x02 = 3, complementing to 0xFFFC. Padding it would give 0xFDFE and a rejected packet.
    /// </summary>
    [Fact]
    public void Checksum_TrailingOddByteIsAddedAsAByte()
    {
        byte[] payload = { 0x01, 0x00, 0x02 };

        Assert.Equal(0xFFFC, ZkTecoClient.Checksum(payload));
    }

    /* ── Time decode ──────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// The epoch: 0 is midnight on 1 January 2000. It anchors the whole scheme — an off-by-one in the
    /// day or month term (they are stored zero-based and read back +1) shows up here first.
    /// </summary>
    [Fact]
    public void DecodeTime_Epoch()
    {
        Assert.Equal(new DateTime(2000, 1, 1, 0, 0, 0), ZkTecoClient.DecodeTime(0));
    }

    /// <summary>
    /// A punch in the middle of an ordinary afternoon, computed by hand from the encoding:
    /// ((((2026-2000)*12 + 7)*31 + 12)*24 + 14)*3600 + 35*60 + 20 = 855,498,920.
    /// </summary>
    [Fact]
    public void DecodeTime_OrdinaryAfternoon()
    {
        Assert.Equal(new DateTime(2026, 8, 13, 14, 35, 20), ZkTecoClient.DecodeTime(855_498_920));
    }

    /// <summary>
    /// The last second of a year — every field at its maximum at once, which is where a decoder that
    /// divides in the wrong order rolls one term into the next and lands on 1 January.
    /// </summary>
    [Fact]
    public void DecodeTime_LastSecondOfAYear()
    {
        Assert.Equal(new DateTime(2024, 12, 31, 23, 59, 59), ZkTecoClient.DecodeTime(803_519_999));
    }

    /// <summary>
    /// The decoded time is the terminal's OWN wall clock and carries no zone. Unspecified is the
    /// contract the whole ingestion pipeline relies on: the push and Excel paths store what the
    /// device or the spreadsheet said, and a Utc kind here would invite somebody to "helpfully"
    /// convert this path alone and move every night shift onto the wrong day.
    /// </summary>
    [Fact]
    public void DecodeTime_CarriesNoTimeZone()
    {
        Assert.Equal(DateTimeKind.Unspecified, ZkTecoClient.DecodeTime(855_498_920).Kind);
    }
}
