namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// One currency's share of the pooled tips.
///
/// Serialized to the procedure's @AmountsJson, whose OPENJSON reads $.currencyCode / $.amount — so
/// the camelCase serialization in the repository is REQUIRED, not cosmetic. Rename either side and
/// the values arrive as NULL, which the procedure reports as "The amounts could not be read".
/// </summary>
public sealed record TipAmount(string CurrencyCode, decimal Amount);

/// <summary>
/// What raising a tip distribution produced.
///
/// NO PER-PERSON FIGURES: the split is now per currency, so a single pair of numbers could not
/// describe it. The form computes and shows the preview; the procedure stores the lines.
/// </summary>
public sealed class TipDistributionCreated
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }

    /// <summary>
    /// ADVISORY, a comma-separated name list: participants with no attendance record that day. It
    /// does not mean they did not work — the day may simply be unprocessed — so it is shown to the
    /// approver as something to confirm, never as a refusal. Null/empty when everyone has a record.
    /// </summary>
    public string? NoAttendanceWarning { get; set; }
}

/// <summary>The header (first result set of usp_TipDistribution_GetPayload).</summary>
public sealed record TipDistributionHeader(
    int TipDistributionId,
    int BranchId,
    string BranchName,
    DateTime ShiftDate,
    DateTime? FinalizedAt);

/// <summary>
/// One participant's share OF ONE CURRENCY (third result set). With two currencies and three people
/// there are six lines, and each currency's lines sum exactly to that currency's pool.
/// </summary>
public sealed record TipDistributionLine(
    int EmployeeId,
    string FullName,
    string CurrencyCode,
    decimal Amount);

/// <summary>All three result sets together — the shape the detail panel renders.</summary>
public sealed record TipDistributionPayload(
    TipDistributionHeader? Header,
    IReadOnlyList<TipAmount> Amounts,
    IReadOnlyList<TipDistributionLine> Lines);

/// <summary>
/// One line of a RESTATED split: this person gets this much of this currency.
///
/// CAMEL CASE IS LOAD-BEARING, exactly as it is for <see cref="TipAmount"/> — the procedure's
/// OPENJSON reads $.employeeId / $.currencyCode / $.amount, and PascalCase would parse to NULLs.
/// </summary>
public sealed record TipLineInput(int EmployeeId, string CurrencyCode, decimal Amount);

/// <summary>
/// A decision on a tip distribution, optionally RESTATING the whole split.
///
/// <see cref="LinesJson"/> is a FULL REPLACEMENT SET, never a patch: everybody who is to be paid must
/// appear in it, because anyone omitted is dropped from the distribution rather than left as they
/// were. Null means "approve as calculated" — the ordinary case, and the one that must stay a single
/// click.
///
/// The name says Json because that is the procedure parameter it becomes; it travels the wire as an
/// array and is serialized in the repository, so callers never hand-build JSON.
/// </summary>
public sealed class TipDecideRequest
{
    public List<TipLineInput>? LinesJson { get; set; }

    /// <summary>
    /// REQUIRED BY THE ENGINE WHEN THE SPLIT CHANGES — a restated distribution is a change of
    /// substance and has to say why. Left to the procedure to enforce, so its sentence is the one the
    /// approver reads.
    /// </summary>
    public string? Comment { get; set; }

    /// <summary>Verified against the stored Argon2id hash BEFORE anything is written. Never logged or echoed.</summary>
    public string? Password { get; set; }
}

/// <summary>
/// What a tip decision returned: the engine's result, plus whether the split was rewritten.
///
/// <see cref="LinesRestated"/> is what tells a caller its cached payload is stale — the lines it is
/// showing are no longer the lines that were finalized.
/// </summary>
public sealed class TipDecisionResult : TypedDecisionResult
{
    public bool LinesRestated { get; set; }
}

/// <summary>
/// Raise a tip distribution.
///
/// There is NO employeeId: the procedure resolves the requester from the token's user. There is no
/// single total either — <see cref="Amounts"/> carries one entry per currency, and the procedure
/// refuses an empty list, a non-positive amount, an unknown currency and a duplicate one, each with
/// its own sentence.
/// </summary>
public sealed class TipDistributionCreateRequest
{
    public int BranchId { get; set; }
    public DateTime ShiftDate { get; set; }
    public List<TipAmount> Amounts { get; set; } = new();

    /// <summary>Joined with commas for the procedure's @ParticipantIds. Duplicates are dropped there, not here.</summary>
    public int[] ParticipantIds { get; set; } = Array.Empty<int>();

    /// <summary>Optional override. Left blank the PROCEDURE composes the title, so the format lives in one place.</summary>
    public string? Title { get; set; }
}
