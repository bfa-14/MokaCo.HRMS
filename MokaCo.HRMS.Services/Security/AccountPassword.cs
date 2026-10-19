using MokaCo.HRMS.Repository.Common;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.Core;

namespace MokaCo.HRMS.Services.Security;

/// <summary>What checking a signed-in user's password found.</summary>
public enum PasswordVerdict
{
    Ok,
    Wrong,

    /// <summary>The account is locked (too many wrong passwords, at sign-in or here): not checked at all.</summary>
    Locked,

    /// <summary>No such account.</summary>
    Unknown,
}

/// <summary>
/// THE ACCOUNT PASSWORD, ASKED AGAIN AFTER SIGN-IN — a decision's signature, the current password of a
/// password change (QA3, item 10). Each check costs an Argon2 run, and none was counted: a borrowed
/// session could guess the account's password at that speed for as long as it lasted. A wrong one now
/// counts against the LOGIN's own lockout (usp_User_RegisterLoginFailure: 5 failures, 15 minutes), a
/// locked account is refused without checking, and a right one clears the count — without stamping
/// LastLoginAt, since a signature is not a sign-in (usp_User_ClearLoginFailures, script 105).
///
/// Static, with the repository and hasher its callers already hold, so the services that check a
/// signature need no new dependency.
///
/// WHILE SCRIPT 105 IS NOT APPLIED (the API deployed first) a right password clears the count with the
/// login's own usp_User_RegisterLoginSuccess, which also stamps LastLoginAt: better than a count left
/// to lock out someone who has just proved their password. The counting itself is the base procedure's.
/// </summary>
public static class AccountPassword
{
    public static async Task<PasswordVerdict> CheckAsync(IUserRepository users, IPasswordHasher hasher, int userId, string? password,
                                                         MissingScriptWarning? missingScript = null)
    {
        var user = await users.GetByIdAsync(userId);
        if (user is null)
            return PasswordVerdict.Unknown;

        if (user.LockoutEnd is not null && user.LockoutEnd > DateTime.UtcNow)
            return PasswordVerdict.Locked;

        if (!hasher.Verify(password ?? string.Empty, user.PasswordHash))
        {
            var failure = await users.RegisterLoginFailureAsync(userId);
            return failure?.LockoutEnd is not null && failure.LockoutEnd > DateTime.UtcNow
                ? PasswordVerdict.Locked
                : PasswordVerdict.Wrong;
        }

        if (user.FailedLoginAttempts != 0 || user.LockoutEnd is not null)
        {
            try
            {
                await users.ClearLoginFailuresAsync(userId);
            }
            catch (MissingScriptException missing)
            {
                missingScript?.FellBack(missing, "a right signature password clears the failure count with usp_User_RegisterLoginSuccess");
                await users.RegisterLoginSuccessAsync(userId);
            }
        }
        return PasswordVerdict.Ok;
    }
}
