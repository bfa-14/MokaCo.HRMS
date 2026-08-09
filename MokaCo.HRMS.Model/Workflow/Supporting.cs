namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// The employee record behind the signed-in user (hr.usp_Employee_GetByUserId).
///
/// Every self-service screen needs this: "my requests", "my leave" and "my attendance" all key off
/// EmployeeId, but the token carries a UserId. An admin account with no employee record returns
/// nothing — treated as "this user has no self-service", never an error.
/// </summary>
public class MyEmployee
{
    public int EmployeeId { get; set; }
    public int? UserId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public int DepartmentId { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
    public int PositionId { get; set; }
    public string PositionName { get; set; } = string.Empty;
    public DateTime HireDate { get; set; }
    public DateTime? TerminationDate { get; set; }

    /// <summary>Whether this person manages their own branch — the UI uses it to explain why step 1 skips on their own requests.</summary>
    public bool IsBranchManager { get; set; }
}

/// <summary>
/// A branch with its manager (hr.usp_Branch_GetAllWithManager). The branch-manager post is what a
/// 'BranchManager' approval step resolves through, so gaps here are the single most likely reason a
/// chain appears not to work.
/// </summary>
public class BranchWithManager
{
    public int BranchId { get; set; }
    public string Name { get; set; } = string.Empty;
    public bool IsActive { get; set; }
    public int? ManagerEmployeeId { get; set; }
    public string? ManagerName { get; set; }
    public int? ManagerUserId { get; set; }

    /// <summary>A manager is assigned but has no user account, so they cannot approve anything yet. A hard warning.</summary>
    public bool ManagerHasNoLogin { get; set; }
}

/// <summary>Result of assigning a branch manager, carrying the same warning if the new manager has no login.</summary>
public class BranchManagerSet
{
    public int BranchId { get; set; }
    public string Name { get; set; } = string.Empty;
    public int? ManagerEmployeeId { get; set; }
    public string? ManagerName { get; set; }
    public int? ManagerUserId { get; set; }
    public bool ManagerHasNoLogin { get; set; }

    /// <summary>A ready-to-show sentence when the assigned manager cannot yet approve. NULL when all is well.</summary>
    public string? Warning { get; set; }
}

/// <summary>Assigns (or clears) a branch's manager. A null manager id clears the post.</summary>
public class SetBranchManagerRequest
{
    public int? ManagerEmployeeId { get; set; }
}
