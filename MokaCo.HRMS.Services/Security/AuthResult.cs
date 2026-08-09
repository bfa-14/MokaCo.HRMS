using MokaCo.HRMS.Model.Security;

namespace MokaCo.HRMS.Services.Security;

/// <summary>Outcome of a login/refresh attempt.</summary>
public class AuthResult
{
    public bool Success { get; set; }
    public string? Error { get; set; }
    public TokenResponse? Tokens { get; set; }

    public static AuthResult Fail(string error) => new() { Success = false, Error = error };
    public static AuthResult Ok(TokenResponse tokens) => new() { Success = true, Tokens = tokens };
}
