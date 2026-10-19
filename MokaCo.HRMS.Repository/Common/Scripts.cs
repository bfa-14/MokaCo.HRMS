namespace MokaCo.HRMS.Repository.Common;

/// <summary>
/// A numbered script and an object that only it creates, late in the script. Scripts are applied with
/// sqlcmd -b (it stops at the first error), so the object is there once the script has run.
/// </summary>
public sealed record ScriptMarker(string Script, string Object);

/// <summary>The numbered scripts whose absence the API survives (<see cref="MissingScriptException"/>), by the path an operator applies.</summary>
public static class Scripts
{
    /// <summary>
    /// QA3 unit G: session stamps, the checked token procedures, ending sessions, clearing login
    /// failures, the caller scope for summaries and reports.
    /// </summary>
    public const string Security105 = "docs/105_qa3_security.sql";

    /// <summary>
    /// QA3 DEPLOY GUARD: every numbered script this build of the API calls, in apply order, each with the
    /// object it is checked by. SchemaCheck looks for them at startup; while one is missing the log names
    /// it and /health says "schema":"behind" (deploy-test.sh refuses that, deploy-api.sh warns). A new
    /// numbered script whose procedures the API calls goes on this list in the same commit. Markers are
    /// procedures: OBJECT_ID shows a login only what it holds a permission on, and the API's login executes.
    /// </summary>
    public static readonly IReadOnlyList<ScriptMarker> Required =
    [
        new("docs/98_qa3_security.sql", "hr.usp_Scope_CallerSees"),
        new("docs/99_qa3_leave.sql", "hr.usp_LeaveYear_Undo"),
        new("docs/100_qa3_attendance.sql", "attendance.usp_DevicePunchQuarantine_Dismiss"),
        new("docs/101_qa3_workflow.sql", "workflow.usp_Request_GetDelegateCandidates"),
        new("docs/102_qa3_roster.sql", "attendance.usp_Roster_GetLeaveDays"),
        new("docs/104_qa3_booking.sql", "core.usp_Email_GetBookingSenders"),
        new(Security105, "hr.usp_Scope_CallerEmployees"),
        new("docs/106_qa3_webhr.sql", "hr.usp_Employee_GetSwapCounterparts"),
    ];
}
