namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// What the separation form shows BEFORE anyone commits to a figure (first set of
/// hr.usp_Separation_GetContext).
///
/// EVERY NUMBER HERE IS PROVISIONAL and several are guesses the law may disagree with. The notice
/// tiers carry "VERIFY WITH COUNSEL" in their own note for that reason, and
/// <see cref="ProvisionalIndemnity"/> is arithmetic — months × basic × years — not a legal opinion.
/// The UI must present them as a starting point somebody checks, never as the settlement.
/// </summary>
public sealed class SeparationContextHeader
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public DateTime HireDate { get; set; }

    /// <summary>Defaults to today when the caller has not chosen one yet.</summary>
    public DateTime LastWorkingDate { get; set; }

    /// <summary>Years to the last working day, to two decimals (DATEDIFF days ÷ 365.25).</summary>
    public decimal ServiceYears { get; set; }

    /// <summary>From the tier table, by service length. 30 days if no tier matches.</summary>
    public int RequiredNoticeDays { get; set; }

    /// <summary>Days between notice being given and the last working day.</summary>
    public int NoticeGivenDays { get; set; }

    /// <summary>Required minus given, floored at zero. Above zero is the warning the form leads with.</summary>
    public int NoticeShortfallDays { get; set; }

    /// <summary>
    /// The basic pay in force on the last working day, IF one is on file. NULL is a real answer and
    /// the form must say so — without it there is no provisional indemnity to offer, and inventing a
    /// zero would read as "nothing is owed".
    /// </summary>
    public decimal? MonthlyBasic { get; set; }
    public string? BasicCurrency { get; set; }

    /// <summary>The IndemnityMonthsPerYear setting. 1 unless configured otherwise.</summary>
    public decimal IndemnityMonthsPerYear { get; set; }

    /// <summary>basic × months-per-year × years. NULL when no basic is on file. A starting figure, not a finding.</summary>
    public decimal? ProvisionalIndemnity { get; set; }

    /// <summary>The tier's own caveat, shown verbatim — every one of them says to verify with counsel.</summary>
    public string? NoticeTierNote { get; set; }
}

/// <summary>
/// One leave type the employee still has a balance in (second set). Only NON-ZERO balances come back
/// — a type they never accrued is not a line anybody needs to see.
/// </summary>
public sealed record SeparationLeaveBalance(
    int LeaveTypeId,
    string LeaveTypeName,
    bool IsPaid,
    decimal BalanceDays);

/// <summary>Both result sets of the context read.</summary>
public sealed record SeparationContext(
    SeparationContextHeader? Header,
    IReadOnlyList<SeparationLeaveBalance> LeaveBalances);

/// <summary>
/// Raise a separation.
///
/// The procedure refuses an employee who already carries a termination date, and a second separation
/// while one is in flight — both name their cause, and both are the guard against ending somebody's
/// employment twice.
/// </summary>
public sealed class SeparationCreateRequest
{
    public int EmployeeId { get; set; }

    /// <summary>Resignation / Termination / EndOfContract / Retirement. Anything else is refused by name.</summary>
    public string SeparationType { get; set; } = string.Empty;

    public DateTime NoticeGivenDate { get; set; }

    /// <summary>The last day worked. Becomes TerminationDate at final approval.</summary>
    public DateTime LastWorkingDate { get; set; }

    public string? Reason { get; set; }
    public string? Title { get; set; }
}

/// <summary>
/// What raising a separation produced — the service and notice arithmetic, FROZEN on the request at
/// submit so it cannot drift if a tier is re-tiered later.
/// </summary>
public sealed class SeparationCreated
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    public decimal ServiceYears { get; set; }
    public int RequiredNoticeDays { get; set; }
    public int NoticeGivenDays { get; set; }
    /// <summary>Above zero: notice was short. Advisory — it does not refuse the request.</summary>
    public int NoticeShortfallDays { get; set; }
}

/// <summary>
/// The preparer's figures. Every amount is in <see cref="CurrencyCode"/>, and NONE may be negative —
/// money withheld goes in <see cref="Deductions"/>, which is subtracted. The procedure says exactly
/// that when it refuses.
/// </summary>
public sealed class SeparationSettlementRequest
{
    public string CurrencyCode { get; set; } = string.Empty;
    public decimal UnusedLeaveDays { get; set; }
    public decimal UnusedLeaveAmount { get; set; }
    public decimal IndemnityAmount { get; set; }
    public decimal NoticePayAmount { get; set; }
    public decimal OtherDues { get; set; }
    public decimal Deductions { get; set; }
    public string? SettlementNote { get; set; }
}

/// <summary>The settlement as stored, with the total the procedure computes so the client never has to agree with it.</summary>
public sealed class SeparationSettlement
{
    public string? CurrencyCode { get; set; }
    public decimal? UnusedLeaveDays { get; set; }
    public decimal? UnusedLeaveAmount { get; set; }
    public decimal? IndemnityAmount { get; set; }
    public decimal? NoticePayAmount { get; set; }
    public decimal? OtherDues { get; set; }
    public decimal? Deductions { get; set; }

    /// <summary>leave + indemnity + notice pay + other − deductions.</summary>
    public decimal SettlementTotal { get; set; }

    public DateTime? PreparedAt { get; set; }
}

/// <summary>
/// What a separation decision returned.
///
/// AT FINAL APPROVAL TWO IRREVERSIBLE THINGS HAPPEN, both idempotent and neither undoable from the
/// app: the employee's TerminationDate is set to the last working day, and every remaining leave
/// balance is zeroed out of the ledger with a paid-out adjustment. <see cref="AppliedAt"/> is how a
/// caller learns it has happened, and the dialog that leads to it must say so before it is signed.
/// </summary>
public sealed class SeparationDecisionResult : TypedDecisionResult
{
    public decimal SettlementTotal { get; set; }

    /// <summary>Set once the termination has been applied. Null on any earlier step.</summary>
    public DateTime? AppliedAt { get; set; }
}

/// <summary>The separation payload — one row, everything the panel and the printed document need.</summary>
public sealed class SeparationPayload
{
    public int SeparationId { get; set; }
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public string PositionTitle { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public DateTime HireDate { get; set; }

    public string SeparationType { get; set; } = string.Empty;
    public DateTime NoticeGivenDate { get; set; }
    public DateTime LastWorkingDate { get; set; }

    public decimal ServiceYears { get; set; }
    public int RequiredNoticeDays { get; set; }
    public int NoticeGivenDays { get; set; }
    public int NoticeShortfallDays { get; set; }

    public string? Reason { get; set; }

    /* The settlement. All null until somebody prepares it. */
    public string? CurrencyCode { get; set; }
    public decimal? UnusedLeaveDays { get; set; }
    public decimal? UnusedLeaveAmount { get; set; }
    public decimal? IndemnityAmount { get; set; }
    public decimal? NoticePayAmount { get; set; }
    public decimal? OtherDues { get; set; }
    public decimal? Deductions { get; set; }
    public decimal SettlementTotal { get; set; }
    public string? SettlementNote { get; set; }

    public DateTime? PreparedAt { get; set; }
    public string? PreparedBy { get; set; }

    /// <summary>When the termination was actually written to the employee record.</summary>
    public DateTime? AppliedAt { get; set; }
    /// <summary>When the leave balance was paid out and zeroed.</summary>
    public DateTime? LeaveClearedAt { get; set; }

    /// <summary>False blocks the FINAL sign-off — the procedure refuses it with its own sentence.</summary>
    public bool SettlementPrepared { get; set; }
}

/// <summary>A decision on a separation. No figure to adjust — the settlement is prepared separately.</summary>
public sealed class SeparationDecideRequest
{
    public string? Comment { get; set; }
    /// <summary>Verified against the stored Argon2id hash BEFORE anything is written. Never logged or echoed.</summary>
    public string? Password { get; set; }
}
