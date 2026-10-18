namespace MokaCo.HRMS.Services.Security.Gate;

/// <summary>
/// security.fn_GateNormalizeEmail in C#, line for line: NULL or blank → null; trimmed of spaces and
/// lower-cased; split at the LAST @ (none → returned as it is); for gmail.com and googlemail.com the
/// part before the @ loses its +tag and its dots, and the domain becomes gmail.com.
///
/// USED FOR ONE DECISION ONLY: whether an edit to the extra address this browser signed in with would
/// give it another address, and so lock the caller out. The gate itself never compares with this —
/// it compares the procedures' own text (GateSnapshot.Allows). Where SQL Server's collation would fold
/// something this does not (full-width letters), the answer is "changed", which only refuses the edit.
/// </summary>
public static class GateEmail
{
    public static string? Normalize(string? email)
    {
        var e = email?.Trim(' ').ToLowerInvariant();
        if (string.IsNullOrEmpty(e))
            return null;

        var at = e.LastIndexOf('@');
        if (at < 0)
            return e;

        var local = e[..at];
        var domain = e[(at + 1)..];
        if (domain is "gmail.com" or "googlemail.com")
        {
            var plus = local.IndexOf('+');
            if (plus >= 0)
                local = local[..plus];
            local = local.Replace(".", string.Empty);
            domain = "gmail.com";
        }

        return $"{local}@{domain}";
    }
}
