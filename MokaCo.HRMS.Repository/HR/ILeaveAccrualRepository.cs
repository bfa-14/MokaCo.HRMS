using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface ILeaveAccrualRepository
{
    /// <summary>Employees active on the given date (IsDeleted = 0 and not terminated before it).</summary>
    Task<IEnumerable<ActiveEmployeeForAccrual>> GetActiveEmployeesForAccrual(DateOnly asOfDate);

    /// <summary>Leave types that accrue (AccrualPerMonth &gt; 0).</summary>
    Task<IEnumerable<AccruingLeaveType>> GetAccruingLeaveTypes();

    /// <summary>True if an Accrual movement already exists for this employee/type/period (idempotency guard).</summary>
    Task<bool> HasAccrualForPeriod(int employeeId, int leaveTypeId, string periodYearMonth);
}
