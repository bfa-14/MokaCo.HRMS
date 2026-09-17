namespace MokaCo.HRMS.Model.HR;

/// <summary>
/// Annual-leave entitlement by tenure — hr.LEAVE_ACCRUAL_TIER. "From MinServiceYears of service, the
/// entitlement is AnnualDays a year": 0 → 15, 5 → 21.
///
/// A TIER IS A FLOOR, not a band: the row with the highest MinServiceYears at or below the
/// employee's tenure is the one that applies, so tiers never need an upper bound and adding one in
/// the middle cannot leave a gap.
/// </summary>
public class LeaveAccrualTier
{
    public int LeaveTypeId { get; set; }
    public int MinServiceYears { get; set; }
    public decimal AnnualDays { get; set; }
}

/// <summary>
/// Sick pay by tenure — hr.LEAVE_PAY_TIER. How many days at full pay and how many at half, from
/// MinServiceYears of service. Same floor rule as the accrual tiers.
/// </summary>
public class LeavePayTier
{
    public int LeaveTypeId { get; set; }
    public int MinServiceYears { get; set; }
    public int FullPayDays { get; set; }
    public int HalfPayDays { get; set; }
}

/// <summary>
/// THE WHOLE LEAVE POLICY in one read (hr.usp_LeavePolicy_GetAll, four result sets).
///
/// One call rather than four because the page is meaningless in pieces: which grids to show for a
/// type is decided by whether that type HAS tiers or relations, so a partial answer would render a
/// screen that then rearranges itself.
/// </summary>
public class LeavePolicy
{
    public IEnumerable<LeaveType> Types { get; set; } = Array.Empty<LeaveType>();
    public IEnumerable<LeaveAccrualTier> AccrualTiers { get; set; } = Array.Empty<LeaveAccrualTier>();
    public IEnumerable<LeavePayTier> PayTiers { get; set; } = Array.Empty<LeavePayTier>();
    public IEnumerable<LeaveRelationEntitlement> Relations { get; set; } = Array.Empty<LeaveRelationEntitlement>();
}

/* ---- write requests ---- */

/// <summary>
/// Creates or updates a leave type (hr.usp_LeaveType_Upsert).
///
/// EVERY POLICY FIELD IS NULLABLE, and null means LEAVE IT ALONE on an update. That is not
/// decoration: the older leave-types screen sends only the four original fields, and if null meant
/// "the procedure's default" instead, saving a name change there would quietly clear
/// RequiresCertificate, the service gate and the notice period. On a CREATE there is nothing to
/// preserve, so null falls through to the procedure's own defaults.
/// </summary>
public class LeaveTypeUpsertRequest
{
    public string Name { get; set; } = string.Empty;
    public bool IsPaid { get; set; }
    public bool CarryOver { get; set; }

    public bool? RequiresCertificate { get; set; }
    public int? MinServiceMonthsToUse { get; set; }
    public int? NoticePreferredDays { get; set; }

    /// <summary>
    /// Null is AMBIGUOUS here in a way the others are not — it is both "leave alone" and the real
    /// value "this type has no fixed entitlement". <see cref="ClearFixedEntitlement"/> disambiguates.
    /// </summary>
    public decimal? FixedEntitlementDays { get; set; }

    /// <summary>Set to clear FixedEntitlementDays back to null, which a null field alone cannot express.</summary>
    public bool ClearFixedEntitlement { get; set; }

    public bool? IsDiscretionary { get; set; }

    /// <summary>Null keeps the stored value (create: active).</summary>
    public bool? IsActive { get; set; }
}

/// <summary>One accrual tier. The leave type comes from the route, never the body.</summary>
public class LeaveAccrualTierRequest
{
    public int MinServiceYears { get; set; }
    public decimal AnnualDays { get; set; }
}

/// <summary>One sick-pay tier. The leave type comes from the route, never the body.</summary>
public class LeavePayTierRequest
{
    public int MinServiceYears { get; set; }
    public int FullPayDays { get; set; }
    public int HalfPayDays { get; set; }
}

/// <summary>One relation entitlement. The leave type comes from the route, never the body.</summary>
public class LeaveRelationRequest
{
    public string Relation { get; set; } = string.Empty;
    public decimal Days { get; set; }
}
