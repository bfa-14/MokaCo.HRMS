namespace MokaCo.HRMS.Model.HR;

/// <summary>
/// One row of hr.usp_Employee_GetLoginStatus — an employee and how they sign in.
///
/// <see cref="HasLogin"/> drives the three states the screen shows (no login, linked+active,
/// linked+disabled). <see cref="Warning"/> is populated by the procedure ONLY for the case that
/// quietly breaks approvals: a branch manager who cannot approve because they have no login or a
/// disabled one. It is a ready-to-show sentence; NULL when there is nothing to say.
/// </summary>
public class EmployeeLoginStatus
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? PositionName { get; set; }
    public int? UserId { get; set; }
    public string? Username { get; set; }
    /// <summary>NULL when there is no linked account (nothing to be active).</summary>
    public bool? UserIsActive { get; set; }
    public bool HasLogin { get; set; }
    public bool IsBranchManager { get; set; }
    public string? Warning { get; set; }
}

/// <summary>
/// Result of hr.usp_Employee_LinkUser. <see cref="Warning"/> is set when the newly linked account
/// is disabled — surface it, do not swallow it.
/// </summary>
public class EmployeeUserLinkResult
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public int UserId { get; set; }
    public string Username { get; set; } = string.Empty;
    public bool UserIsActive { get; set; }
    public string? Warning { get; set; }
}

/// <summary>
/// Result of hr.usp_Employee_UnlinkUser — what breaking the link cost, so the UI could warn before
/// it happened and confirm after. <see cref="RequestsLeftWaiting"/> is how many pending requests can
/// no longer be signed by this person.
/// </summary>
public class EmployeeUserUnlinkResult
{
    public int EmployeeId { get; set; }
    public bool WasBranchManager { get; set; }
    public int RequestsLeftWaiting { get; set; }
    public string? Warning { get; set; }
}

/// <summary>Body of PUT /api/employees/{id}/user — the existing account to link this employee to.</summary>
public class LinkUserRequest
{
    public int UserId { get; set; }
}
