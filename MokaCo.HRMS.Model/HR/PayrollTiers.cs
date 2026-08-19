namespace MokaCo.HRMS.Model.HR;

/// <summary>
/// Maps to hr.TAX_BRACKET. One slice of annual income and the rate it is taxed at.
///
/// A bracket describes POLICY, not a transaction: nothing here recomputes a payslip, and a run
/// already generated keeps the figures it was generated with.
/// </summary>
public class TaxBracket
{
    public int TaxBracketId { get; set; }
    /// <summary>The floor of the slice, annual.</summary>
    public decimal MinAnnual { get; set; }
    /// <summary>The ceiling, annual. NULL is the open top tier — "and above".</summary>
    public decimal? MaxAnnual { get; set; }
    /// <summary>0..1. A FRACTION on the wire and in the table; the screen shows percent.</summary>
    public decimal Rate { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public DateTime EffectiveFrom { get; set; }
    /// <summary>NULL = still in force.</summary>
    public DateTime? EffectiveTo { get; set; }
    public string? Note { get; set; }
}

/// <summary>
/// Maps to hr.NSSF_RATE. One scheme version: its two contribution rates and its own salary ceiling.
///
/// VERSIONED, NOT OVERWRITTEN. Rates change by decree, so a change is a new row with a later
/// EffectiveFrom — leaving the old one intact, so re-running an old month still computes what it
/// computed at the time. That is what the UI's "New version" action creates, and it is why the
/// procedures offer no delete.
/// </summary>
public class NssfRate
{
    public int NssfRateId { get; set; }
    /// <summary>The scheme's name, as the NSSF states it.</summary>
    public string Scheme { get; set; } = string.Empty;
    /// <summary>0..1. The employee's share.</summary>
    public decimal EmployeeRate { get; set; }
    /// <summary>0..1. The employer's share.</summary>
    public decimal EmployerRate { get; set; }
    /// <summary>Whether contributions stop above a salary ceiling at all.</summary>
    public bool IsCeilinged { get; set; }
    /// <summary>
    /// This scheme's OWN ceiling. NULL on a ceilinged scheme means "use the global NssfCeilingUsd
    /// setting", which is what every scheme did before per-scheme ceilings existed — so leaving it
    /// empty is the no-change answer and existing payroll behaviour is untouched.
    /// </summary>
    public decimal? CeilingAmount { get; set; }
    public DateTime EffectiveFrom { get; set; }
    /// <summary>NULL = still in force.</summary>
    public DateTime? EffectiveTo { get; set; }
    public string? Note { get; set; }
}

/// <summary>
/// Maps to hr.APPROVAL_TIER. The seniority dictionary — which named tier a number stands for.
///
/// The tier picks WHICH published chain a person's requests follow, so these names are read on the
/// employee form, the org chart and the employee list. They were a hard-coded three-item map in the
/// frontend until this table existed.
/// </summary>
public class ApprovalTier
{
    public int TierNo { get; set; }
    public string Name { get; set; } = string.Empty;
    /// <summary>The Arabic name. NULL falls back to <see cref="Name"/> on screen.</summary>
    public string? NameAr { get; set; }

    /* ── THE BASIC-SALARY BAND FOR THIS TIER ──
       Policy, not a payslip figure: it says what a basic salary at this rank may be, and a DB
       TRIGGER on the salary-component write refuses one outside it. That refusal is where the band
       actually bites, which is why these are surfaced to the UI — a rule the user can only discover
       by being refused is a rule the form should have shown them first. */

    /// <summary>The floor. NULL = no lower bound for this tier.</summary>
    public decimal? MinBasicSalary { get; set; }

    /// <summary>The ceiling. NULL = no upper bound — "and above".</summary>
    public decimal? MaxBasicSalary { get; set; }

    /// <summary>
    /// Which currency the two figures are stated in. NULL when the tier has no band at all; a band
    /// compared against a basic in another currency is meaningless, so the trigger owns that check
    /// and nothing here converts anything.
    /// </summary>
    public string? SalaryCurrency { get; set; }
}

/// <summary>POST/PUT /api/payroll/tax-brackets. The id travels in the route, never the body.</summary>
public class TaxBracketUpsertRequest
{
    public decimal MinAnnual { get; set; }
    public decimal? MaxAnnual { get; set; }
    public decimal Rate { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public string? Note { get; set; }
}

/// <summary>POST/PUT /api/payroll/nssf-rates.</summary>
public class NssfRateUpsertRequest
{
    public string Scheme { get; set; } = string.Empty;
    public decimal EmployeeRate { get; set; }
    public decimal EmployerRate { get; set; }
    public bool IsCeilinged { get; set; }
    public decimal? CeilingAmount { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public string? Note { get; set; }
}

/// <summary>POST /api/hr/approval-tiers.</summary>
public class ApprovalTierCreateRequest
{
    public int TierNo { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? NameAr { get; set; }
}

/// <summary>PUT /api/hr/approval-tiers/{tierNo} — the number is the route, so only the names.</summary>
public class ApprovalTierNameRequest
{
    public string Name { get; set; } = string.Empty;
    public string? NameAr { get; set; }
}

/// <summary>
/// PUT /api/hr/approval-tiers/{tierNo}/salary-range — the number is the route, so only the band.
///
/// SEPARATE FROM THE RENAME on purpose. Renaming is EMP_EDIT, a labelling act; setting the band is
/// PAYROLL_RUN, because it decides what anybody at that rank may be paid. One endpoint carrying
/// both would have to demand the higher trust for the lesser act.
///
/// EITHER BOUND MAY BE NULL, and null means "no bound", not "leave alone" — an open-ended tier is a
/// real setting. Sending both null clears the band.
/// </summary>
public class ApprovalTierSalaryRangeRequest
{
    public decimal? MinBasicSalary { get; set; }
    public decimal? MaxBasicSalary { get; set; }

    /// <summary>Which currency the bounds are stated in. The procedure refuses an unknown one.</summary>
    public string SalaryCurrency { get; set; } = string.Empty;
}
