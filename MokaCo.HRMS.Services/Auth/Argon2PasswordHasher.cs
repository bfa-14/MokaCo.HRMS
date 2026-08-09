using System.Security.Cryptography;
using System.Text;
using Konscious.Security.Cryptography;

namespace MokaCo.HRMS.Services.Auth;

/// <summary>
/// Argon2id password hashing. Stored format:  argon2id$v=19$m=..,t=..,p=..$salt$hash
/// all base64. Parameters are tuned so one hash takes ~250-500ms on the server;
/// adjust MemorySizeKb after load-testing.
/// </summary>
public class Argon2PasswordHasher : IPasswordHasher
{
    // Tunable parameters (start here, then load-test)
    private const int MemorySizeKb = 19 * 1024; // ~19 MB
    private const int Iterations   = 2;
    private const int Parallelism  = 1;
    private const int SaltSize     = 16;
    private const int HashSize     = 32;

    public string Hash(string password)
    {
        var salt = RandomNumberGenerator.GetBytes(SaltSize);
        var hash = Compute(password, salt);
        return $"argon2id$v=19$m={MemorySizeKb},t={Iterations},p={Parallelism}$" +
               $"{Convert.ToBase64String(salt)}${Convert.ToBase64String(hash)}";
    }

    public bool Verify(string password, string storedHash)
    {
        try
        {
            var parts = storedHash.Split('$');
            // [0]=argon2id [1]=v=19 [2]=m=..,t=..,p=.. [3]=salt [4]=hash
            if (parts.Length != 5 || parts[0] != "argon2id") return false;

            var prm = parts[2].Split(',');
            int mem = int.Parse(prm[0].Substring(2));
            int itr = int.Parse(prm[1].Substring(2));
            int par = int.Parse(prm[2].Substring(2));

            var salt = Convert.FromBase64String(parts[3]);
            var expected = Convert.FromBase64String(parts[4]);
            var actual = Compute(password, salt, mem, itr, par, expected.Length);

            return CryptographicOperations.FixedTimeEquals(actual, expected);
        }
        catch { return false; }
    }

    private static byte[] Compute(string password, byte[] salt,
        int mem = MemorySizeKb, int itr = Iterations, int par = Parallelism, int size = HashSize)
    {
        using var argon = new Argon2id(Encoding.UTF8.GetBytes(password))
        {
            Salt = salt,
            MemorySize = mem,
            Iterations = itr,
            DegreeOfParallelism = par
        };
        return argon.GetBytes(size);
    }
}
