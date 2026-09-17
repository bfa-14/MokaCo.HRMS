namespace MokaCo.HRMS.Model.HR;

/* ---- Lookups ---- */

public class BranchCreateRequest
{
    public string Name { get; set; } = string.Empty;
}

public class BranchUpdateRequest
{
    public string Name { get; set; } = string.Empty;
    public bool IsActive { get; set; } = true;
}

public class DepartmentCreateRequest
{
    public string Name { get; set; } = string.Empty;
}

public class DepartmentUpdateRequest
{
    public string Name { get; set; } = string.Empty;
    public bool IsActive { get; set; } = true;
}

public class PositionCreateRequest
{
    public string Title { get; set; } = string.Empty;
}

public class PositionUpdateRequest
{
    public string Title { get; set; } = string.Empty;
    public bool IsActive { get; set; } = true;
}

public class ComponentTypeCreateRequest
{
    public string Name { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;   // Earning / Deduction
    public short Sign { get; set; }
    /// <summary>Omitted means active.</summary>
    public bool? IsActive { get; set; }
}

public class ComponentTypeUpdateRequest
{
    public string Name { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public short Sign { get; set; }
    /// <summary>Omitted (null) keeps the stored value, so an older screen cannot reactivate a retired type by accident.</summary>
    public bool? IsActive { get; set; }
}

/// <summary>Body of PATCH …/{id}/active on every reference-data resource — the "deactivate it instead" path.</summary>
public class SetActiveRequest
{
    public bool IsActive { get; set; }
}

/* ---- Employee ---- */

public class EmployeeCreateRequest
{
    public int? UserId { get; set; }
    public int BranchId { get; set; }
    public int DepartmentId { get; set; }
    public int PositionId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string? NationalId { get; set; }
    public string? NssfNumber { get; set; }
    public DateTime HireDate { get; set; }
    /// <summary>Optional. Blank is stored as NULL by the procedure.</summary>
    public string? Email { get; set; }
    public string? PhoneNumber { get; set; }

    /// <summary>'en' or 'ar'. Omitted means 'en' — the procedure defaults it, so an older caller still works.</summary>
    public string? PreferredLanguage { get; set; }
}

public class EmployeeUpdateRequest
{
    public int BranchId { get; set; }
    public int DepartmentId { get; set; }
    public int PositionId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string? NationalId { get; set; }
    public string? NssfNumber { get; set; }
    public DateTime HireDate { get; set; }
    public DateTime? TerminationDate { get; set; }
    /// <summary>Optional. Blank is stored as NULL by the procedure — CLEARING one is a real edit.</summary>
    public string? Email { get; set; }
    public string? PhoneNumber { get; set; }

    /// <summary>'en' or 'ar'. Omitted means 'en' — the procedure defaults it, so an older caller still works.</summary>
    public string? PreferredLanguage { get; set; }
}

/// <summary>Body of PUT /api/employees/{id}/approval-tier — the requester's tier (1/2/3).</summary>
public class ApprovalTierRequest
{
    public int ApprovalTier { get; set; }
}

/// <summary>What usp_Employee_SetApprovalTier returns — the employee's new tier standing.</summary>
public class EmployeeApprovalTier
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public int ApprovalTier { get; set; }
}

/// <summary>Body of PUT /api/employees/{id}/reports-to — the manager, or null for the top of a line.</summary>
public class ReportsToRequest
{
    public int? ReportsToEmployeeId { get; set; }
}

/// <summary>
/// What usp_Employee_SetReportsTo returns — the new manager, plus a Warning when that manager has no
/// login (line-manager approvals above this person would then skip). The proc RAISERRORs on a
/// self-reference or a loop, which the controller surfaces verbatim.
/// </summary>
public class EmployeeReportsTo
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public int? ReportsToEmployeeId { get; set; }
    public string? ReportsToName { get; set; }
    public string? Warning { get; set; }
}

/// <summary>One rung of a person's chain of command (usp_Employee_GetReportingLine), bottom-up: Lvl 0 is themselves.</summary>
public class ReportingLineEntry
{
    public int Lvl { get; set; }
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    /// <summary>False when this person has no login, so a line-manager step resolving to them would skip.</summary>
    public bool HasLogin { get; set; }
}

/// <summary>One node of the org tree (usp_Employee_GetOrgTree) — pre-sorted depth-first, with its parent and depth.</summary>
public class OrgTreeNode
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public int? ReportsToEmployeeId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public int ApprovalTier { get; set; }
    public int Depth { get; set; }
}

/* ---- Leave type ---- */

public class LeaveTypeCreateRequest
{
    public string Name { get; set; } = string.Empty;
    public bool IsPaid { get; set; }
    public bool CarryOver { get; set; }
}

public class LeaveTypeUpdateRequest
{
    public string Name { get; set; } = string.Empty;
    public bool IsPaid { get; set; }
    public bool CarryOver { get; set; }
}

/* ---- Salary component ---- */

public class SalaryComponentCreateRequest
{
    public int EmployeeId { get; set; }
    public int ComponentTypeId { get; set; }
    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
}

public class SalaryComponentUpdateRequest
{
    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
}

/* ---- Document ---- */

public class DocumentCreateRequest
{
    public int EmployeeId { get; set; }
    public string FileName { get; set; } = string.Empty;
    public string StoragePath { get; set; } = string.Empty;
    public string ContentType { get; set; } = string.Empty;
    public long SizeBytes { get; set; }
}

/* ---- Leave ledger ---- */

public class LeaveLedgerPostRequest
{
    public int EmployeeId { get; set; }
    public int LeaveTypeId { get; set; }
    public string MovementType { get; set; } = string.Empty;   // Accrual / Usage / CarryOver / Adjustment
    public decimal Days { get; set; }
    public DateTime EffectiveDate { get; set; }
    public int? LeaveRequestId { get; set; }
    public string? Note { get; set; }
}
