namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// What one ADMS push did. The terminal is told only "OK" — it has no screen to show any of this
/// and no ability to act on it — so these counts exist for the LOG and for the caller deciding
/// whether anything actually changed (and therefore whether to signal live subscribers).
///
/// The four outcomes are the same four the Excel importer reports, deliberately: a punch that
/// arrived over the wire and a punch that arrived on a spreadsheet are the same kind of fact, and
/// anyone reading the logs should not have to learn a second vocabulary for them.
/// </summary>
public class AttlogPushResult
{
    /// <summary>Non-blank lines in the body — what the terminal claims it sent.</summary>
    public int Received { get; set; }

    /// <summary>Punches that landed in RAW_DEVICE_LOG for the first time.</summary>
    public int Inserted { get; set; }

    /// <summary>
    /// Already in the system, ignored. The NORMAL case on an unstable link, not an error: a
    /// terminal that does not get its "OK" re-sends the whole batch, sometimes for days.
    /// </summary>
    public int Duplicates { get; set; }

    /// <summary>Stored, but on a PIN nobody is enrolled on — waiting in the unresolved queue, not lost.</summary>
    public int UnresolvedPins { get; set; }

    /// <summary>
    /// Stored with a direction our processor does not understand (a ZKTeco status other than
    /// 0=in / 1=out — break and overtime keys use 2..5). The punch is KEPT with the terminal's own
    /// status value; the day it belongs to surfaces as an anomaly for a human to resolve, which is
    /// better than guessing a direction and inventing worked time.
    /// </summary>
    public int UnknownDirection { get; set; }

    /// <summary>
    /// Lines that could not be read as a punch at all. See the note in ImportService.PushAttlogAsync:
    /// these ARE dropped, which is the one place this pipeline breaks its "nothing is lost" promise,
    /// and they are logged in full for exactly that reason.
    /// </summary>
    public int Unparsed { get; set; }

    /// <summary>The offending lines, verbatim and capped, so a firmware quirk can be diagnosed from the log alone.</summary>
    public List<string> UnparsedLines { get; set; } = new();

    /// <summary>Did this push change anything? The live signal is worth sending only if so.</summary>
    public bool ChangedAnything => Inserted > 0;
}
