namespace MokaCo.HRMS.Model.Security;

/*
 * GOOGLE SIGN-IN GATE — docs/GOOGLE_SIGNIN_GATE.md is the specification.
 *
 * Two families of types live here:
 *   - the rows of the security.usp_Gate_* procedures (§2), named exactly like their columns. DATE and
 *     DATETIME2 columns are DateTime, because that is what Dapper maps them to; the DATETIME2 ones are
 *     UTC (SYSUTCDATETIME), like every other audit time the API returns;
 *   - the API's JSON (§3): the requests the two controllers bind and the answers they send.
 * A person is a Kind and an id: 'e' + EmployeeId, or 'x' + GateExtraEmailId for an extra address.
 */

/* ======================================================================================
 * Procedure rows
 * ==================================================================================== */

/// <summary>usp_Gate_GetState RS1 (and the first four columns of usp_Gate_GetAdmin RS1). Days is already clamped to 1..365 by the procedure.</summary>
public class GateStateRow
{
    public bool Required { get; set; }
    public string ClientId { get; set; } = string.Empty;
    public int Days { get; set; }
    public int Epoch { get; set; }
}

/// <summary>usp_Gate_GetState RS2: one person who may open the HRMS right now.</summary>
public class GateAllowedRow
{
    /// <summary>"e" (employee) or "x" (extra address).</summary>
    public string Kind { get; set; } = string.Empty;
    public int PersonId { get; set; }

    /// <summary>
    /// Their normalised email as it is stored NOW — the same text usp_Gate_SignIn gave them, so a cookie
    /// passes only while the person still has the address it was made for.
    /// </summary>
    public string? EmailNorm { get; set; }
}

/// <summary>usp_Gate_GetState: the settings row and everyone allowed now, read together.</summary>
public class GateStateData
{
    public GateStateRow State { get; set; } = new();
    public List<GateAllowedRow> Allowed { get; set; } = [];
}

/// <summary>The outcomes usp_Gate_SignIn writes to the log and returns. Only <see cref="Allowed"/> gets a cookie.</summary>
public static class GateSignInOutcome
{
    public const string Allowed = "Allowed";
    public const string NotFound = "NotFound";
    public const string Blocked = "Blocked";
    public const string NoUser = "NoUser";
    public const string Left = "Left";
}

/// <summary>usp_Gate_SignIn's one row. Kind, PersonId, DisplayName and EmailNorm are set only for <see cref="GateSignInOutcome.Allowed"/>.</summary>
public class GateSignInRow
{
    public string Outcome { get; set; } = string.Empty;
    public string? Kind { get; set; }
    public int? PersonId { get; set; }
    public string? DisplayName { get; set; }

    /// <summary>The person's stored address, normalised (what usp_Gate_GetState gives them): it goes into the cookie.</summary>
    public string? EmailNorm { get; set; }
}

/// <summary>usp_Gate_GetAdmin RS1. ModifiedAt is when GoogleSignInRequired last changed.</summary>
public class GateAdminSettings
{
    public bool Required { get; set; }
    public string ClientId { get; set; } = string.Empty;
    public int Days { get; set; }
    public int Epoch { get; set; }
    public DateTime? ModifiedAt { get; set; }
}

/// <summary>
/// usp_Gate_GetAdmin RS2: every employee that is not deleted, with what the gate makes of them.
/// Status is one of Allowed, Blocked, NoEmail, NoUser, UserDisabled, Left.
/// </summary>
public class GatePersonRow
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string? BranchName { get; set; }
    public string? Email { get; set; }
    public int? UserId { get; set; }
    public string? Username { get; set; }
    public bool? UserIsActive { get; set; }
    public DateTime? TerminationDate { get; set; }
    public bool IsBlocked { get; set; }
    public string Status { get; set; } = string.Empty;
    public DateTime? LastSignInAt { get; set; }
}

/// <summary>usp_Gate_GetAdmin RS3: an address on the extra list (owner, accountant — people who are not employees).</summary>
public class GateExtraEmailRow
{
    public int GateExtraEmailId { get; set; }
    public string Email { get; set; } = string.Empty;
    public string? Note { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime? LastSignInAt { get; set; }
}

/// <summary>usp_Gate_GetAdmin RS4: one sign-in attempt, newest first. Email is the address as Google gave it.</summary>
public class GateSignInLogRow
{
    public long GateSignInLogId { get; set; }
    public DateTime AttemptedAt { get; set; }
    public string Email { get; set; } = string.Empty;
    public string Outcome { get; set; } = string.Empty;
    public int? EmployeeId { get; set; }
    public string? FullName { get; set; }
    public string? Ip { get; set; }
}

/// <summary>usp_Gate_GetAdmin: the four result sets in their order.</summary>
public class GateAdminData
{
    public GateAdminSettings Settings { get; set; } = new();
    public List<GatePersonRow> People { get; set; } = [];
    public List<GateExtraEmailRow> Extras { get; set; } = [];
    public List<GateSignInLogRow> Recent { get; set; } = [];
}

/* ======================================================================================
 * API: the gate (api/gate, anonymous)
 * ==================================================================================== */

/// <summary>POST api/gate/google: the ID token Google Identity Services handed the gate page.</summary>
public class GateGoogleSignInRequest
{
    public string? Credential { get; set; }
}

/// <summary>GET api/gate/config: what the gate page needs before it draws Google's button.</summary>
public class GateConfig
{
    public bool Required { get; set; }

    /// <summary>Null when it is not set: the page then says sign-in is not set up yet.</summary>
    public string? ClientId { get; set; }

    public int Days { get; set; }

    /// <summary>This browser holds a gate cookie that is valid now, of a person who is allowed now.</summary>
    public bool SignedIn { get; set; }

    public string? Email { get; set; }
    public string? Name { get; set; }
}

/* ======================================================================================
 * API: the admin side (api/access, ACCESS_MANAGE)
 * ==================================================================================== */

/// <summary>PUT api/access/settings.</summary>
public class GateSettingsRequest
{
    public bool Required { get; set; }
    public string? ClientId { get; set; }
    public int Days { get; set; } = 30;
}

/// <summary>PUT api/access/people/{employeeId}/blocked.</summary>
public class GateBlockedRequest
{
    public bool Blocked { get; set; }
}

/// <summary>POST api/access/extras (IsActive is not sent and stays true) and PUT api/access/extras/{id}.</summary>
public class GateExtraEmailRequest
{
    public string? Email { get; set; }
    public string? Note { get; set; }
    public bool IsActive { get; set; } = true;
}

/// <summary>Who this browser is signed in as with Google, judged against a fresh reading of the settings.</summary>
public class GateCaller
{
    public bool Verified { get; set; }
    public string? Email { get; set; }
    public string? Name { get; set; }
}

/// <summary>GET api/access: the whole Settings → Google sign-in tab in one answer.</summary>
public class GateAccessView
{
    public GateAdminSettings Settings { get; set; } = new();
    public GateCaller Caller { get; set; } = new();
    public List<GatePersonRow> People { get; set; } = [];
    public List<GateExtraEmailRow> Extras { get; set; } = [];
    public List<GateSignInLogRow> Recent { get; set; } = [];
}
