namespace MokaCo.HRMS.Model.HR;

/// <summary>Outcome of a monthly leave-accrual run.</summary>
public class AccrualRunResult
{
    /// <summary>Accrual movements actually posted this run.</summary>
    public int Posted { get; set; }

    /// <summary>(employee, leave type) pairs skipped (already accrued, or not yet hired).</summary>
    public int Skipped { get; set; }
}

/// <summary>Minimal active-employee row used by the accrual run.</summary>
public class ActiveEmployeeForAccrual
{
    public int EmployeeId { get; set; }
    public DateTime HireDate { get; set; }
}

/// <summary>A leave type that accrues (AccrualPerMonth &gt; 0).</summary>
public class AccruingLeaveType
{
    public int LeaveTypeId { get; set; }
    public decimal AccrualPerMonth { get; set; }
}
