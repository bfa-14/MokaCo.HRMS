using MokaCo.HRMS.Services.Security.Gate;

namespace MokaCo.HRMS.Tests.Security.Gate;

/// <summary>
/// G7: the exempt paths, decided from the RAW X-Original-URI and fail-closed. nginx routes on the
/// normalised path, so anything that normalisation would change — %XX, a backslash, //, a "." or ".."
/// segment — is never exempt, whatever it starts with. Case-sensitive like nginx; the query is ignored.
/// </summary>
public class GatePathsTests
{
    [Theory]
    [InlineData("/health")]
    [InlineData("/health?probe=1")]
    [InlineData("/gate/")]
    [InlineData("/gate/index.html")]
    [InlineData("/gate/gate.js")]
    [InlineData("/gate/next.js")]
    [InlineData("/gate/gate.css")]
    [InlineData("/gate/logo.png")]
    [InlineData("/gate/index.html?next=%2Femployees%3Fx%3D1")]
    [InlineData("/api/gate/check")]
    [InlineData("/api/gate/config")]
    [InlineData("/api/gate/google")]
    [InlineData("/api/gate/signout")]
    [InlineData("/iclock")]
    [InlineData("/iclock/cdata?SN=BZD5251201566&options=all&pushver=2.4.1")]
    [InlineData("/iclock/getrequest?SN=BZD5251201566")]
    [InlineData("/iclock/devicecmd")]
    [InlineData("/api/attendance/punch")]
    public void These_always_pass(string rawUri)
        => Assert.True(GatePaths.IsExempt(rawUri));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData("/")]
    [InlineData("/employees")]
    [InlineData("/index.html")]
    [InlineData("/assets/index-abc123.js")]
    [InlineData("/api/employees")]
    [InlineData("/api/auth/login")]
    [InlineData("/hubs/live")]
    [InlineData("/hubs/booking/negotiate")]
    [InlineData("/healthz")]
    [InlineData("/health/")]
    [InlineData("/health/x")]
    [InlineData("/health;x")]
    [InlineData("/gate")]
    [InlineData("/gatex/index.html")]
    [InlineData("/api/gate")]
    [InlineData("/api/gatex/check")]
    [InlineData("/iclockx")]
    [InlineData("/api/attendance")]
    [InlineData("/api/attendance/punch/")]
    [InlineData("/api/attendance/punch/x")]
    [InlineData("/api/attendance/punches")]
    public void Ordinary_paths_and_near_misses_do_not(string? rawUri)
        => Assert.False(GatePaths.IsExempt(rawUri));

    [Theory]
    // %2e / %2E — an encoded dot
    [InlineData("/gate/%2e%2e/api/employees")]
    [InlineData("/gate/%2E%2E/api/employees")]
    [InlineData("/api/gate/%2e%2e/employees")]
    [InlineData("/gate/.%2e/api/x")]
    [InlineData("/%2e/health")]
    // %2F / %2f — an encoded slash
    [InlineData("/gate%2F..%2Fapi/employees")]
    [InlineData("/gate/..%2Fapi/employees")]
    [InlineData("/api/gate%2fcheck")]
    [InlineData("/health%2F")]
    // any other %XX
    [InlineData("/health%00")]
    [InlineData("/gate/%41")]
    // //
    [InlineData("//health")]
    [InlineData("/gate//../api/employees")]
    [InlineData("/gate//x")]
    [InlineData("/api//gate/check")]
    [InlineData("//api/gate/check")]
    // /./
    [InlineData("/./health")]
    [InlineData("/gate/./index.html")]
    [InlineData("/api/gate/./check")]
    [InlineData("/gate/.")]
    // /../
    [InlineData("/gate/../api/x")]
    [InlineData("/gate/../api/employees")]
    [InlineData("/api/gate/../employees")]
    [InlineData("/api/gate/../../api/employees")]
    [InlineData("/iclock/../api/employees")]
    [InlineData("/health/..")]
    [InlineData("/gate/..")]
    // backslash
    [InlineData(@"/gate\..\api\employees")]
    [InlineData(@"/gate/..\api/employees")]
    [InlineData(@"/api/gate\..\employees")]
    [InlineData(@"\health")]
    [InlineData(@"/health\")]
    public void Encoding_and_traversal_tricks_are_never_exempt(string rawUri)
        => Assert.False(GatePaths.IsExempt(rawUri));

    [Theory]
    [InlineData("/api/employees?next=/health")]
    [InlineData("/api/employees?/api/gate/check")]
    [InlineData("/?/gate/index.html")]
    [InlineData("/employees?x=/iclock/cdata")]
    [InlineData("/api/payroll?r=/api/attendance/punch")]
    public void An_exempt_path_in_the_query_string_does_not_make_the_request_exempt(string rawUri)
        => Assert.False(GatePaths.IsExempt(rawUri));

    [Theory]
    [InlineData("/HEALTH")]
    [InlineData("/Health")]
    [InlineData("/GATE/index.html")]
    [InlineData("/Gate/index.html")]
    [InlineData("/API/GATE/check")]
    [InlineData("/api/Gate/check")]
    [InlineData("/ICLOCK/cdata")]
    [InlineData("/Api/attendance/punch")]
    [InlineData("/api/attendance/PUNCH")]
    public void Matching_is_case_sensitive(string rawUri)
        => Assert.False(GatePaths.IsExempt(rawUri));

    [Theory]
    [InlineData("health")]
    [InlineData("gate/index.html")]
    [InlineData("http://hrms.mokanco.com.lb/health")]
    [InlineData("https://hrms.mokanco.com.lb/gate/index.html")]
    [InlineData("/gate/x#y")]
    [InlineData("/gate/a b")]
    [InlineData("/gate/a\tb")]
    [InlineData("/gate/é")]
    [InlineData(" /health")]
    public void Anything_that_is_not_a_plain_absolute_path_is_not_exempt(string rawUri)
        => Assert.False(GatePaths.IsExempt(rawUri));
}
