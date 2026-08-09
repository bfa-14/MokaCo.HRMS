namespace MokaCo.HRMS.Model.Security;

/// <summary>
/// A role the chain builder may offer as an approver or deputy (security.usp_Role_GetApprovers).
///
/// ActiveMemberCount comes back alongside because a role with nobody in it is a step that can never
/// be signed — the builder warns before such a chain is published, not after a request is stuck
/// behind it.
/// </summary>
public class ApproverRole
{
    public int RoleId { get; set; }
    public string Name { get; set; } = string.Empty;
    public bool IsSystem { get; set; }
    public bool UsableAsApprover { get; set; }
    public int ActiveMemberCount { get; set; }
}
