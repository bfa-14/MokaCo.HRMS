namespace MokaCo.HRMS.Services.Security;

/// <summary>
/// Outcome of a self-service password change. Shaped like <see cref="AuthResult"/> — the failure
/// is a MESSAGE the user is meant to read and act on ("the current password is incorrect", "too
/// short"), not an exception, because none of them are faults. There is nothing to return on
/// success: the caller keeps the token they already hold.
/// </summary>
public class ChangePasswordResult
{
    public bool Success { get; set; }
    public string? Error { get; set; }

    public static ChangePasswordResult Fail(string error) => new() { Success = false, Error = error };
    public static ChangePasswordResult Ok() => new() { Success = true };
}
