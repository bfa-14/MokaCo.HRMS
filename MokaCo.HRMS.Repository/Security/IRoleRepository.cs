using MokaCo.HRMS.Model.Security;

namespace MokaCo.HRMS.Repository.Security;

public interface IRoleRepository
{
    Task<IEnumerable<Role>> GetAllAsync();
    Task<Role?> GetByIdAsync(int roleId);
    Task<int> CreateAsync(string name, int? createdBy);
    Task UpdateAsync(int roleId, string name, int modifiedBy);
    Task<IEnumerable<int>> GetPermissionIdsAsync(int roleId);
    Task SetPermissionsAsync(int roleId, IEnumerable<int> permissionIds, int? assignedBy);

    /// <summary>Roles the chain builder may offer as an approver or deputy, each with its active-member count.</summary>
    Task<IEnumerable<ApproverRole>> GetApproversAsync();

    /// <summary>Every approver role with its rejection behaviour and the database's plain-language reading of it.</summary>
    Task<IEnumerable<RoleRejectionBehaviour>> GetRejectionBehaviourAsync();

    /// <summary>Sets whether a rejection by this role ends the request, and returns the role's new standing.</summary>
    Task<RoleRejectionBehaviour?> SetRejectionBehaviourAsync(int roleId, bool rejectionEndsRequest);

    /// <summary>Every role with its approver-usage and signature flags and active-member count.</summary>
    Task<IEnumerable<RoleSignatureRequirement>> GetSignatureRequirementsAsync();

    /// <summary>Sets whether a role may be chosen as an approver. The procedure REFUSES to switch it off while a published chain uses it (SqlException).</summary>
    Task<RoleSignatureRequirement?> SetApproverUsageAsync(int roleId, bool usableAsApprover);

    /// <summary>Sets whether decisions by this role must be password-signed, and returns the role's new standing.</summary>
    Task<RoleSignatureRequirement?> SetSignatureRequirementAsync(int roleId, bool requiresSignaturePassword);
}
