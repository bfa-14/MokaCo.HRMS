namespace MokaCo.HRMS.Model.Security;

/// <summary>Maps to security.[USER]. A login account (may link to an employee).</summary>
public class User
{
    public int UserId { get; set; }
    public string Username { get; set; } = string.Empty;
    public string PasswordHash { get; set; } = string.Empty;
    public bool IsActive { get; set; }
    public int FailedLoginAttempts { get; set; }
    public DateTime? LockoutEnd { get; set; }
    public string? PasswordResetToken { get; set; }
    public DateTime? PasswordResetExpiry { get; set; }
    public DateTime? LastLoginAt { get; set; }
    public DateTime? PasswordChangedAt { get; set; }

    /// <summary>
    /// Renewed whenever the account's sessions are ended (a password change, a disable: QA3 SEC-5,
    /// script 105). Every access token carries the stamp it was issued under, and one whose stamp is no
    /// longer this is refused. Null until the first end — the same as a token issued without one.
    /// </summary>
    public Guid? SessionStamp { get; set; }
    public DateTime? CreatedAt { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? ModifiedAt { get; set; }
    public int? ModifiedBy { get; set; }
}
