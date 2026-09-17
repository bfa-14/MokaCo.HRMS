namespace MokaCo.HRMS.Model.HR;

/// <summary>Maps to hr.LEAVE_TYPE. A kind of leave, its paid flag and monthly accrual policy.</summary>
public class LeaveType
{
    public int LeaveTypeId { get; set; }
    public string Name { get; set; } = string.Empty;
    public bool IsPaid { get; set; }
    public bool CarryOver { get; set; }

    /* ACCRUAL IS NOT HERE. It was AccrualPerMonth, a single rate on the type; it is now
       hr.LEAVE_ACCRUAL_TIER — one row per tenure step, read through fn_GetAnnualEntitlement.
       A per-type rate could not express "15 days, then 21 after five years", which is the actual
       rule, so the column was dropped rather than left as a second, disagreeing answer. */

    /* ---- policy, enforced in the leave-request procedures and explained by the form ----
       These are READ here so a requester can be told what a type needs BEFORE submitting.
       None of them is a client-side rule: every one is enforced in SQL as well. */

    /// <summary>Approval is REFUSED until the request carries an attachment. Enforced in usp_LeaveRequest_Decide.</summary>
    public bool RequiresCertificate { get; set; }

    /// <summary>Months of service before this type may be USED. The balance accrues from hire regardless.</summary>
    public int MinServiceMonthsToUse { get; set; }

    /// <summary>Preferred notice. Advisory only — short notice warns on the create response, never blocks.</summary>
    public int NoticePreferredDays { get; set; }

    /// <summary>A whole entitlement (maternity), not a per-request cap. Null when the type has none.</summary>
    public decimal? FixedEntitlementDays { get; set; }

    /// <summary>Granted at the approver's discretion rather than by entitlement.</summary>
    public bool IsDiscretionary { get; set; }

    /// <summary>
    /// False hides the type from new requests without deleting it. A type that is REFERENCED (ledger
    /// rows, leave requests) cannot be deleted at all — hr.usp_LeaveType_Delete refuses and says why —
    /// so this is the only way to retire one that has been used.
    /// </summary>
    public bool IsActive { get; set; } = true;
}

/// <summary>
/// One (leave type, relation) pair with the days it entitles — hr.LEAVE_RELATION_ENTITLEMENT.
///
/// A type with NO rows here needs no relation, which is exactly the test usp_LeaveRequest_Create
/// makes. So "which types ask for a relation" is answered by this data and never by a type name.
/// </summary>
public class LeaveRelationEntitlement
{
    public int LeaveTypeId { get; set; }
    public string LeaveTypeName { get; set; } = string.Empty;
    public string Relation { get; set; } = string.Empty;

    /// <summary>The most days this relation entitles. The procedure refuses a longer request.</summary>
    public decimal Days { get; set; }
}
