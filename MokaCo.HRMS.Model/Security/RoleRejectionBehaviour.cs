namespace MokaCo.HRMS.Model.Security;

/// <summary>
/// One approver role's rejection behaviour (security.usp_Role_GetRejectionBehaviour).
///
/// The question this answers: when someone holding this role REJECTS a request, does the request
/// stop there, or does the rejection travel on as advice for the next approver to weigh? Advice is
/// the default — a single "no" partway up a chain is usually a recommendation, not a verdict — and a
/// role is switched to "ends the request" only where its "no" should be final.
///
/// A CAVEAT the engine enforces regardless of this flag: the FINAL step always ends the request. A
/// rejection with nobody left to overrule it is a verdict whatever the role's setting says.
/// </summary>
public class RoleRejectionBehaviour
{
    public int RoleId { get; set; }
    public string Name { get; set; } = string.Empty;
    public bool IsSystem { get; set; }
    public bool UsableAsApprover { get; set; }

    /// <summary>True = a rejection by this role stops the request; false (the default) = it is advice.</summary>
    public bool RejectionEndsRequest { get; set; }

    /// <summary>The database's own plain-language reading of the flag — shown verbatim, never re-worded.</summary>
    public string Meaning { get; set; } = string.Empty;
}

/// <summary>
/// A role's approver-usage and signature flags together (security.usp_Role_GetSignatureRequirements).
///
/// Two of the three "workflow behaviour" settings shown per role on the Roles page:
///   - <see cref="UsableAsApprover"/>: may this role appear in an approval chain at all;
///   - <see cref="RequiresSignaturePassword"/>: must people in it re-enter their password to decide.
/// The third — rejection behaviour — is a separate read (<see cref="RoleRejectionBehaviour"/>),
/// because the database returns it only for roles that actually approve.
/// </summary>
public class RoleSignatureRequirement
{
    public int RoleId { get; set; }
    public string Name { get; set; } = string.Empty;
    public bool IsSystem { get; set; }
    public bool UsableAsApprover { get; set; }

    /// <summary>True = decisions by this role must be password-signed; confirms identity, never changes who may approve.</summary>
    public bool RequiresSignaturePassword { get; set; }

    /// <summary>Active members — context for both flags (a role with none can neither approve nor sign anything).</summary>
    public int ActiveMemberCount { get; set; }
}
