namespace MokaCo.HRMS.Model.HR;

/// <summary>
/// What hr.usp_Employee_ApplyDueTerminations did on one run (QA3 REL-4, docs/106_qa3_webhr.sql): access ends the day
/// after the termination date. Every effect is also written to hr.EMPLOYEE_TERMINATION_EFFECT, once per termination.
/// </summary>
public class TerminationSweepResult
{
    /// <summary>Leavers whose termination was applied on this run (each termination date is applied once).</summary>
    public int EmployeesApplied { get; set; }

    /// <summary>Logins switched off.</summary>
    public int UsersDisabled { get; set; }

    /// <summary>Logins left on: the last active account that can manage users (nobody could switch it back on).</summary>
    public int UsersKept { get; set; }

    /// <summary>Branches whose manager left: the post is vacant now.</summary>
    public int BranchManagersCleared { get; set; }

    /// <summary>Device PIN mappings removed, so the PIN can be enrolled for somebody else.</summary>
    public int PinMappingsRemoved { get; set; }

    /// <summary>Open requests whose current step still waits on a leaver's signature. Reported, not changed.</summary>
    public int StepsWaiting { get; set; }

    /// <summary>Open requests raised for a leaver. Reported, not changed.</summary>
    public int OpenRequests { get; set; }

    /// <summary>One line per leaver applied on this run, naming each effect; null on an ordinary night.</summary>
    public string? Summary { get; set; }
}
