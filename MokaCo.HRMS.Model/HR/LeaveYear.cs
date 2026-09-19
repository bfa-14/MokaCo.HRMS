namespace MokaCo.HRMS.Model.HR;

/// <summary>
/// One leave type's line in the summary hr.usp_LeaveYear_Open returns — what opening the year
/// actually did, per type, rather than a bare "done" the caller has to take on trust.
///
/// THE YEARLY OPENING IS THE ONLY GRANTING PATH. There is no monthly accrual: entitlement is the
/// tier grid (hr.LEAVE_ACCRUAL_TIER, read through fn_GetAnnualEntitlement), and this run is what
/// turns it into ledger movements.
///
/// The figures are independent. An employee can be granted this year's entitlement AND have last
/// year's remainder carried in, or granted it and have last year's expire; which of carry-over and
/// expiry applies is the type's CarryOver flag, and that decision lives in the procedure.
/// </summary>
public class LeaveYearOpenSummary
{
    public string LeaveTypeName { get; set; } = string.Empty;

    /// <summary>Employees this run opened the year for. Already-opened ones are skipped, so a second run reports 0.</summary>
    public int EmployeesOpened { get; set; }

    /// <summary>This year's entitlement, granted.</summary>
    public decimal DaysGranted { get; set; }

    /// <summary>
    /// How many of those employees got a PART year rather than a whole one — hired partway through
    /// it, so their grant is proportional. Reported separately because it is the figure that
    /// explains a total nobody expected: a headcount times the annual entitlement will not match
    /// DaysGranted whenever this is above zero.
    /// </summary>
    public int ProratedEmployees { get; set; }

    /// <summary>Last year's unused days brought forward — types WITH carry-over.</summary>
    public decimal DaysCarriedOver { get; set; }

    /// <summary>Last year's unused days written off — types WITHOUT carry-over.</summary>
    public decimal DaysExpired { get; set; }
}

/// <summary>What one run of the carry-over expiry did (hr.usp_LeaveCarryOver_Expire). Both are 0 on an ordinary night.</summary>
public class LeaveCarryOverExpired
{
    public int EmployeesExpired { get; set; }
    public decimal DaysExpired { get; set; }
}
