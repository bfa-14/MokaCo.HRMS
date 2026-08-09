using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;

namespace MokaCo.HRMS.Services.HR;

/// <summary>
/// Monthly leave-accrual logic. Reads the accrual rate from hr.LEAVE_TYPE (never hard-coded),
/// pro-rates mid-month joiners, and is idempotent per (employee, leave type, period).
/// </summary>
public class LeaveAccrualService : ILeaveAccrualService
{
    private readonly ILeaveAccrualRepository _accrual;
    private readonly ILeaveLedgerRepository _ledger;

    public LeaveAccrualService(ILeaveAccrualRepository accrual, ILeaveLedgerRepository ledger)
    {
        _accrual = accrual;
        _ledger = ledger;
    }

    public async Task<AccrualRunResult> RunMonthlyAccrual(int year, int month, int? createdBy = null)
    {
        var effectiveDate = new DateOnly(year, month, 1);
        var period = $"{year:D4}-{month:D2}";
        var daysInMonth = DateTime.DaysInMonth(year, month);
        var monthEnd = new DateOnly(year, month, daysInMonth);
        var effectiveDateTime = effectiveDate.ToDateTime(TimeOnly.MinValue);

        var leaveTypes = (await _accrual.GetAccruingLeaveTypes()).ToList();
        var employees = (await _accrual.GetActiveEmployeesForAccrual(effectiveDate)).ToList();

        var posted = 0;
        var skipped = 0;

        foreach (var employee in employees)
        {
            var hire = DateOnly.FromDateTime(employee.HireDate);

            foreach (var type in leaveTypes)
            {
                // Hired after this accrual month → nothing to accrue.
                if (hire > monthEnd)
                {
                    skipped++;
                    continue;
                }

                // Idempotency: never post a second accrual for the same period.
                if (await _accrual.HasAccrualForPeriod(employee.EmployeeId, type.LeaveTypeId, period))
                {
                    skipped++;
                    continue;
                }

                var amount = ComputeAmount(type.AccrualPerMonth, hire, year, month, monthEnd, daysInMonth);
                if (amount <= 0)
                {
                    skipped++;
                    continue;
                }

                await _ledger.PostMovementAsync(
                    employee.EmployeeId,
                    type.LeaveTypeId,
                    "Accrual",
                    amount,
                    effectiveDateTime,
                    leaveRequestId: null,
                    note: $"Auto accrual {year:D4}-{month:D2}",
                    createdBy: createdBy);
                posted++;
            }
        }

        return new AccrualRunResult { Posted = posted, Skipped = skipped };
    }

    /// <summary>
    /// Full rate when hired before the accrual month; pro-rated by remaining days when hired
    /// within the month (inclusive of the hire day and the last day).
    /// </summary>
    private static decimal ComputeAmount(
        decimal accrualPerMonth, DateOnly hire, int year, int month, DateOnly monthEnd, int daysInMonth)
    {
        var hiredThisMonth = hire.Year == year && hire.Month == month;
        if (!hiredThisMonth)
        {
            return accrualPerMonth;
        }

        var daysFromHireToMonthEnd = monthEnd.DayNumber - hire.DayNumber; // e.g. hired on last day → 0
        var factor = (decimal)(daysFromHireToMonthEnd + 1) / daysInMonth;
        return Math.Round(accrualPerMonth * factor, 2, MidpointRounding.AwayFromZero);
    }
}
