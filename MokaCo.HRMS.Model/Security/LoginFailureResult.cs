namespace MokaCo.HRMS.Model.Security;

/// <summary>Returned by usp_User_RegisterLoginFailure: new attempt count + lockout.</summary>
public class LoginFailureResult
{
    public int FailedLoginAttempts { get; set; }
    public DateTime? LockoutEnd { get; set; }
}
