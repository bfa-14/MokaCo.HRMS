namespace MokaCo.HRMS.Services.Security.Gate;

/// <summary>
/// The paths that always pass the gate (docs/GOOGLE_SIGNIN_GATE.md G7): /health, the gate page's own
/// files under /gate/, the sign-in endpoints under /api/gate/, the terminals' /iclock and the
/// device-key punch endpoint.
///
/// DECIDED FROM THE RAW URI, AND FAIL-CLOSED. nginx asks with X-Original-URI = $request_uri, the
/// request line exactly as the browser sent it. nginx itself routes on the NORMALISED path — dots
/// resolved, %XX decoded, slashes merged — so /gate/../api/employees is routed to the API while its raw
/// text still starts with /gate/. Rather than re-implement nginx's normalisation here and hope the two
/// agree, a path that would need any of it is never exempt: one with a %, a backslash, a //, or a "."
/// or ".." segment. Such a path simply goes through the gate like any other; nothing legitimate is
/// ever spelled that way. Matching is case-sensitive, as nginx's locations are.
///
/// Only the path is judged. The query string is ignored — /api/employees?next=/health is not /health —
/// and the terminals' /iclock/cdata?SN=… stays exempt.
/// </summary>
public static class GatePaths
{
    public static bool IsExempt(string? rawUri)
    {
        if (string.IsNullOrEmpty(rawUri))
            return false;

        var query = rawUri.IndexOf('?');
        var path = query < 0 ? rawUri : rawUri[..query];
        if (!IsPlain(path))
            return false;

        return path == "/health"
            || path == "/api/attendance/punch"
            || path == "/iclock" || path.StartsWith("/iclock/", StringComparison.Ordinal)
            || path.StartsWith("/gate/", StringComparison.Ordinal)
            || path.StartsWith("/api/gate/", StringComparison.Ordinal);
    }

    /// <summary>An absolute path that nginx would route exactly as written: printable ASCII, no %, \ or #, no empty, "." or ".." segment.</summary>
    private static bool IsPlain(string path)
    {
        if (path.Length == 0 || path[0] != '/')
            return false;

        foreach (var c in path)
            if (c is '%' or '\\' or '#' || c <= ' ' || c > '~')
                return false;

        if (path.Contains("//", StringComparison.Ordinal))
            return false;

        foreach (var segment in path.Split('/'))
            if (segment is "." or "..")
                return false;

        return true;
    }
}
