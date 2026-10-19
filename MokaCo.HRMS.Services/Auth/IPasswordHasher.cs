namespace MokaCo.HRMS.Services.Auth;

public interface IPasswordHasher
{
    string Hash(string password);
    bool Verify(string password, string storedHash);

    /// <summary>
    /// A well-formed hash with this hasher's current cost that no password matches. Verifying against
    /// it costs what a real verification costs, so a refusal for an account that does not exist takes
    /// as long as one for a wrong password (QA3 SEC-6: no timing oracle for which usernames exist).
    /// </summary>
    string DecoyHash { get; }
}
