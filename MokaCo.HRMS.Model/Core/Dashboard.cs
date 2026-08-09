namespace MokaCo.HRMS.Model.Core;

/// <summary>
/// The whole home page, in one object — the ten result sets of core.usp_Dashboard_Get.
///
/// It is an OPERATIONAL page, not an analytical one: every list here is something a person has to
/// act on today, which is why nothing on it describes the shape of the company (headcount by
/// department, who was hired last quarter). That belongs on the HR and Reports screens, where
/// somebody has gone looking for it.
///
/// WHO SEES WHAT IS DECIDED IN SQL, not here and not in the client. The procedure works out from the
/// caller's roles whether they are managerial, and simply returns NOTHING in the managerial sets when
/// they are not — so an ordinary employee's response carries no company-wide figures at all, rather
/// than carrying them and trusting the browser to hide them. <see cref="CompanySnapshot"/> being null
/// is therefore the authoritative "this user is not managerial" signal.
/// </summary>
public class Dashboard
{
    /// <summary>Requests the caller can act on RIGHT NOW — the five oldest. The headline of the page.</summary>
    public List<WaitingOnMeItem> WaitingOnMe { get; set; } = new();

    /// <summary>The caller's own still-open requests — the five newest.</summary>
    public List<MyOpenRequest> MyRequests { get; set; } = new();

    /// <summary>What has happened lately ON the caller's own requests — approvals, rejections, skips.</summary>
    public List<DashboardActivity> RecentActivity { get; set; } = new();

    /// <summary>The caller's leave balances. EMPTY when the account has no employee record behind it.</summary>
    public List<DashboardLeaveBalance> LeaveBalances { get; set; } = new();

    /// <summary>Request types with NO active approval chain — nobody can raise them. Managerial only.</summary>
    public List<CoverageGap> CoverageGaps { get; set; } = new();

    /// <summary>
    /// The company-wide counters. NULL for a non-managerial caller — and that null is what the client
    /// reads to decide whether the managerial cards exist at all.
    /// </summary>
    public CompanySnapshot? CompanySnapshot { get; set; }

    /// <summary>Rostered vs on-leave today, per active branch. Managerial only.</summary>
    public List<BranchStaffing> StaffingToday { get; set; } = new();

    /// <summary>Who is on approved leave today, by name. Managerial only.</summary>
    public List<OnLeaveToday> OnLeaveToday { get; set; } = new();

    /// <summary>Open requests grouped by type, with the oldest one's age. Managerial only.</summary>
    public List<OpenRequestsByType> WorkflowByType { get; set; } = new();

    /// <summary>This month's approved expenses, finalized tips and approved overtime. Managerial only.</summary>
    public List<MonthMoneyLine> MonthMoney { get; set; } = new();
}

/// <summary>
/// One request waiting on the caller's decision.
///
/// <see cref="TotalCount"/> repeats on every row and is the TRUE total, not the length of this list —
/// the procedure returns only the five oldest. Zero rows means zero waiting, so a caller reading
/// <c>rows[0]?.TotalCount ?? 0</c> is always right.
/// </summary>
public class WaitingOnMeItem
{
    public int TotalCount { get; set; }
    public int RequestInstanceId { get; set; }
    public string? Title { get; set; }
    public string RequestTypeCode { get; set; } = string.Empty;
    public string RequestTypeName { get; set; } = string.Empty;
    public DateTime SubmittedAt { get; set; }

    /// <summary>Whole days since it was submitted. Over 3 is the point at which the row turns amber.</summary>
    public int AgeDays { get; set; }
}

/// <summary>One of the caller's own open requests. <see cref="TotalCount"/> is the true total; see <see cref="WaitingOnMeItem"/>.</summary>
public class MyOpenRequest
{
    public int TotalCount { get; set; }
    public int RequestInstanceId { get; set; }
    public string? Title { get; set; }
    public string RequestTypeName { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    public DateTime SubmittedAt { get; set; }
}

/// <summary>A decision somebody took on one of the caller's requests.</summary>
public class DashboardActivity
{
    public int RequestInstanceId { get; set; }
    public string? Title { get; set; }

    /// <summary>Approved / Rejected / Skipped / VersionMoved.</summary>
    public string Action { get; set; } = string.Empty;

    /// <summary>Null for a step the engine skipped — nobody acted, so nobody is named.</summary>
    public string? ActedBy { get; set; }

    public DateTime ActedAt { get; set; }
}

/// <summary>The caller's standing in one leave type: what a full year grants, and what is left.</summary>
public class DashboardLeaveBalance
{
    public int LeaveTypeId { get; set; }
    public string LeaveTypeName { get; set; } = string.Empty;
    public bool IsPaid { get; set; }
    public decimal? AnnualEntitlementDays { get; set; }
    public decimal CurrentBalance { get; set; }
}

/// <summary>A request type nobody can raise, because no chain has ever been published for it.</summary>
public class CoverageGap
{
    public int RequestTypeId { get; set; }
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
}

/// <summary>The company-wide counters. Present only for a managerial caller.</summary>
public class CompanySnapshot
{
    public int ActiveEmployees { get; set; }
    public int OpenRequests { get; set; }
    public int ApprovedLast30Days { get; set; }
    public int ActiveChains { get; set; }

    /// <summary>
    /// Whether the destructive system-reset switch is currently armed. NULLABLE because the setting
    /// row may simply not exist yet, and "nobody has ever configured this" is not the same statement
    /// as "it is off" — the client shows its red strip only on a definite true.
    /// </summary>
    public bool? ResetArmed { get; set; }
}

/// <summary>
/// One branch's cover today. <see cref="RosteredToday"/> counts the ROSTER — who is scheduled — not
/// who has clocked in; the label in the UI says so, because reading it as attendance would turn a
/// normal morning into a crisis.
/// </summary>
public class BranchStaffing
{
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public int RosteredToday { get; set; }
    public int OnLeaveToday { get; set; }
}

/// <summary>One person on approved leave today, with the request that granted it.</summary>
public class OnLeaveToday
{
    public string FullName { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public string LeaveTypeName { get; set; } = string.Empty;
    public DateTime FromDate { get; set; }
    public DateTime ToDate { get; set; }
    public int RequestInstanceId { get; set; }
}

/// <summary>Open requests of one type, and how long the oldest has been waiting.</summary>
public class OpenRequestsByType
{
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public int OpenCount { get; set; }
    public int? OldestAgeDays { get; set; }
}

/// <summary>
/// One line of this month's money, per currency.
///
/// MONEY AND TIME ARE DELIBERATELY NOT THE SAME COLUMN. Expenses and tips carry an
/// <see cref="Amount"/> in a named <see cref="CurrencyCode"/>; overtime carries <see cref="Minutes"/>
/// and no currency at all, because pricing an hour is payroll's job and any figure this page invented
/// for it would be wrong. Rows where both are null are empty aggregates and mean "nothing this month".
/// </summary>
public class MonthMoneyLine
{
    public string Item { get; set; } = string.Empty;
    public string? CurrencyCode { get; set; }
    public decimal? Amount { get; set; }
    public int? Minutes { get; set; }
}
