using MokaCo.HRMS.Model.Security;

namespace MokaCo.HRMS.Services.Security;

public interface IUserService
{
    Task<IEnumerable<UserListItem>> GetAllAsync();
    Task<IEnumerable<UserListItem>> GetUnlinkedAsync();
    Task<int> CreateAsync(CreateUserRequest request, int createdBy);
    Task SetActiveAsync(int userId, bool isActive, int modifiedBy);

    /// <summary>Replace-all of a user's roles. The procedure's refusals come back as WorkflowException (404 unknown user, 400 otherwise).</summary>
    Task<IEnumerable<UserRoleItem>> SetRolesAsync(int userId, IEnumerable<int> roleIds, int actedBy);

    /// <summary>
    /// Changes the caller's OWN password. <paramref name="userId"/> must come from the token — this
    /// method has no way to tell a token id from a body id, so passing an untrusted one lets anybody
    /// rewrite anybody's password.
    /// </summary>
    Task<ChangePasswordResult> ChangePasswordAsync(int userId, ChangePasswordRequest request);
}
