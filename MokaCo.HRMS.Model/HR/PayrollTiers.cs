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
