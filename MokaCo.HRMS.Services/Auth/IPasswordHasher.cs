namespace MokaCo.HRMS.Services.Auth;

public interface IPasswordHasher
{
    string Hash(string password);
    bool Verify(string password, string storedHash);
}
