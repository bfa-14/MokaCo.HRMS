namespace MokaCo.HRMS.Model.Security;

/// <summary>Login credentials from the client.</summary>
public class LoginRequest
{
    public string Username { get; set; } = string.Empty;
    public string Password { get; set; } = string.Empty;
}

/// <summary>A raw refresh token sent by the client to refresh or logout.</summary>
public class RefreshRequest
{
    public string RefreshToken { get; set; } = string.Empty;
}

/// <summary>Access token + refresh token issued to the client.</summary>
public class TokenResponse
{
    public string AccessToken { get; set; } = string.Empty;
    public string RefreshToken { get; set; } = string.Empty;
    public DateTime AccessTokenExpiresAt { get; set; }
}

/// <summary>The current user's identity + permissions (GET /auth/me).</summary>
public class CurrentUser
{
    public int UserId { get; set; }
    public string Username { get; set; } = string.Empty;
    public List<string> Roles { get; set; } = new();
    public List<string> Permissions { get; set; } = new();
}

/// <summary>Admin creates a user (no public registration).</summary>
public class CreateUserRequest
{
    public string Username { get; set; } = string.Empty;
    public string Password { get; set; } = string.Empty;
    public bool IsActive { get; set; } = true;
    public List<int> RoleIds { get; set; } = new();
}
/// <summary>
/// Body of POST /api/me/change-password. Note what is NOT here: a user id. The account being
/// changed is read from the token, so this body can only ever describe the caller's own password.
/// </summary>
public class ChangePasswordRequest
{
    public string CurrentPassword { get; set; } = string.Empty;
    public string NewPassword { get; set; } = string.Empty;
}

/// <summary>
/// Body of PUT /api/users/{id}/roles — the user's WHOLE role set (replace-all). A role missing from
/// the list is removed; the procedure refuses to take the last active Admin's role away.
/// </summary>
public class SetUserRolesRequest
{
    public List<int> RoleIds { get; set; } = new();
}

public class RoleRequest
{
    public string Name { get; set; } = string.Empty;
}

/// <summary>Body of PUT /api/roles/{id}/rejection-behaviour — the single flag being set.</summary>
public class RejectionBehaviourRequest
{
    public bool RejectionEndsRequest { get; set; }
}

/// <summary>Body of PUT /api/roles/{id}/approver-usage — whether the role may appear in chains.</summary>
public class ApproverUsageRequest
{
    public bool UsableAsApprover { get; set; }
}

/// <summary>Body of PUT /api/roles/{id}/signature-requirement — whether decisions by the role are password-signed.</summary>
public class SignatureRequirementRequest
{
    public bool RequiresSignaturePassword { get; set; }
}
