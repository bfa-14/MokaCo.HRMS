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
    private readonly ISessionGuard _sessions;

    public UserService(IUserRepository users, IPasswordHasher hasher, ISessionGuard sessions)
    {
        _users = users; _hasher = hasher; _sessions = sessions;
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

    /// <summary>
    /// Disabling ENDS THE ACCOUNT'S SESSIONS (QA3 SEC-5): its refresh tokens are revoked — before, they
    /// worked again the moment the account was re-enabled — and its access tokens stop at the next
    /// request. Enabling ends nothing: the person signs in again.
    /// </summary>
    public async Task SetActiveAsync(int userId, bool isActive, int modifiedBy)
    {
        var rows = await _users.SetActiveAsync(userId, isActive, modifiedBy);
        if (rows == 1 && !isActive)
            await EndSessionsAsync(userId);
    }

    /// <summary>security.usp_User_EndSessions, then this process stops trusting its cached reading of the account.</summary>
    private async Task EndSessionsAsync(int userId)
    {
        await _users.EndSessionsAsync(userId);
        _sessions.Forget(userId);
    }

    /// <summary>
    /// Self-service password change. The order is deliberate: the current password is verified
    /// FIRST, so a caller who cannot prove who they are learns nothing about the policy and writes
    /// nothing. The new hash is produced by the same <see cref="IPasswordHasher"/> that hashed the
    /// password at creation and that verifies it at login — one implementation, so a password set
    /// here logs in exactly like one set anywhere else, and a later change of Argon2 cost applies to
    /// all three at once.
    ///
    /// A CHANGED PASSWORD ENDS EVERY SESSION OF THE ACCOUNT (QA3 SEC-5), this one included: the refresh
    /// tokens are revoked and the access tokens stop at the next request, so whoever held the account
    /// with the old password — the usual reason to change it — is out. (Before, nothing was revoked: a
    /// stolen refresh token kept rotating for ever.) The person signs in again with the new password.
    /// </summary>
    public async Task<ChangePasswordResult> ChangePasswordAsync(int userId, ChangePasswordRequest request)
    {
        // The current password counts against the login lockout, and a locked account is refused
        // (QA3, item 10): otherwise this form guesses passwords for whoever holds the session.
        switch (await AccountPassword.CheckAsync(_users, _hasher, userId, request.CurrentPassword))
        {
            case PasswordVerdict.Ok:
                break;
            case PasswordVerdict.Locked:
                return ChangePasswordResult.Fail(AuthService.Locked);
            default:
                return ChangePasswordResult.Fail("The current password is incorrect.");
        }

        var policyError = ValidateNewPassword(request.NewPassword);
        if (policyError is not null)
            return ChangePasswordResult.Fail(policyError);

        var hash = _hasher.Hash(request.NewPassword);
        var rows = await _users.ChangePasswordAsync(userId, hash);
        if (rows != 1)
            return ChangePasswordResult.Fail("The password could not be changed. Please try again.");

        await EndSessionsAsync(userId);
        return ChangePasswordResult.Ok();
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
