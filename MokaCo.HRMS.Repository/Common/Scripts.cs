namespace MokaCo.HRMS.Repository.Common;

/// <summary>The numbered scripts whose absence the API survives (<see cref="MissingScriptException"/>), by the path an operator applies.</summary>
public static class Scripts
{
    /// <summary>
    /// QA3 unit G: session stamps, the checked token procedures, ending sessions, clearing login
    /// failures, the caller scope for summaries and reports.
    /// </summary>
    public const string Security105 = "docs/105_qa3_security.sql";
}
