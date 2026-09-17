using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.HR;

namespace MokaCo.HRMS.Services.Security;

/// <summary>Admin user management (no public registration). Hashes the password here.</summary>
public class UserService : IUserService
{
    private readonly IUserRepository _users;
    private readonly IPasswordHasher _hasher;

    public UserService(IUserRepository users, IPasswordHasher hasher)
    {
        _users = users; _hasher = hasher;
    }

    public Task<IEnumerable<UserListItem>> GetAllAsync() => _users.GetAllAsync();

    public Task<IEnumerable<UserListItem>> GetUnlinkedAsync() => _users.GetUnlinkedAsync();

    public async Task<int> CreateAsync(CreateUserRequest request, int createdBy)
    {
        var hash = _hasher.Hash(request.Password);
        var userId = await _users.CreateAsync(request.Username, hash, request.IsActive, createdBy);
        foreach (var roleId in request.RoleIds)
            await _users.AssignRoleAsync(userId, roleId, createdBy);
        return userId;
    }

    public Task SetActiveAsync(int userId, bool isActive, int modifiedBy)
        => _users.SetActiveAsync(userId, isActive, modifiedBy).ContinueWith(_ => { });

    /// <summary>
    /// Self-service password change. The order is deliberate: the current password is verified
    /// FIRST, so a caller who cannot prove who they are learns nothing about the policy and writes
    /// nothing. The new hash is produced by the same <see cref="IPasswordHasher"/> that hashed the
    /// password at creation and that verifies it at login — one implementation, so a password set
    /// here logs in exactly like one set anywhere else, and a later change of Argon2 cost applies to
    /// all three at once.
    ///
    /// Nothing is revoked on success. The access token is a signed JWT that says who the caller is
    /// and what they may do; it makes no claim about their password, so changing the password cannot
    /// make it untrue. Forcing a re-login would only be meaningful if the token were derived from
    /// the password — it is not — so the user stays where they are.
    /// </summary>
    public async Task<ChangePasswordResult> ChangePasswordAsync(int userId, ChangePasswordRequest request)
    {
        var user = await _users.GetByIdAsync(userId);
        if (user is null)
            return ChangePasswordResult.Fail("The current password is incorrect.");

        if (!_hasher.Verify(request.CurrentPassword ?? string.Empty, user.PasswordHash))
            return ChangePasswordResult.Fail("The current password is incorrect.");

        var policyError = ValidateNewPassword(request.NewPassword);
        if (policyError is not null)
            return ChangePasswordResult.Fail(policyError);

        var hash = _hasher.Hash(request.NewPassword);
        var rows = await _users.ChangePasswordAsync(userId, hash);

        return rows == 1
            ? ChangePasswordResult.Ok()
            : ChangePasswordResult.Fail("The password could not be changed. Please try again.");
    }

    /// <summary>The new-password policy, in one place. Null means it passes.</summary>
    private static string? ValidateNewPassword(string? password)
        => string.IsNullOrEmpty(password) || password.Length < MinPasswordLength
            ? $"Your new password must be at least {MinPasswordLength} characters."
            : null;

    /// <summary>
    /// The shortest password this system will accept. Admin user creation currently enforces NO
    /// minimum at all (only "not blank", from the RequiredRule on the client) — this is the first
    /// length rule in the codebase, so it is stated here rather than copied from somewhere.
    /// </summary>
    public const int MinPasswordLength = 8;

    /// <summary>"User not found." → 404; "Role #9 does not exist." / the last-Admin guard → 400, wording intact.</summary>
    public Task<IEnumerable<UserRoleItem>> SetRolesAsync(int userId, IEnumerable<int> roleIds, int actedBy)
        => ReferenceDataSqlErrors.MapAsync(() => _users.SetRolesAsync(userId, roleIds, actedBy));
}
