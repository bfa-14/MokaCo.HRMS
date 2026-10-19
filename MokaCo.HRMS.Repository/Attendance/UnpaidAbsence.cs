using System.Data;
using Dapper;

namespace MokaCo.HRMS.Repository.Attendance;

/// <summary>
/// "UNPAID ABSENCE DAYS — THIS IS THE DEDUCTION" (QA3 REL-15).
///
/// The monthly attendance summaries (one employee, all employees) and the monthly attendance report print
/// that figure, and their procedures computed it as "Absent days − leave usage from the ledger". Since script
/// 76 a day of approved leave is Status 'Leave', not 'Absent', so the subtraction took the leave off twice:
/// two absences beside three days of leave read 0 while the payslip deducted two days. Those procedures are
/// stale repo copies of newer live ones (contract review CON-7), so they are not redefined; the API replaces
/// the one figure with attendance.usp_Attendance_UnpaidAbsenceDays (script 103), which reads the same
/// function as the payslip's "day(s) short" line — payroll.fn_ShortDays — over the period's completed days.
/// An employee the procedure does not list has nothing short: 0.
/// </summary>
public static class UnpaidAbsence
{
    public const string Procedure = "attendance.usp_Attendance_UnpaidAbsenceDays";

    private sealed class Row
    {
        public int EmployeeId { get; set; }
        public decimal UnpaidAbsenceDays { get; set; }
    }

    /// <summary>The figure per employee for the period (one employee when <paramref name="employeeId"/> is set).</summary>
    public static async Task<IReadOnlyDictionary<int, decimal>> ReadAsync(IDbConnection db, string periodYearMonth, int? employeeId = null)
    {
        var rows = await db.QueryAsync<Row>(
            Procedure,
            new { PeriodYearMonth = periodYearMonth, EmployeeId = employeeId },
            commandType: CommandType.StoredProcedure);
        return rows.ToDictionary(r => r.EmployeeId, r => r.UnpaidAbsenceDays);
    }

    /// <summary>Writes the figure onto each row; a row whose employee is not in <paramref name="days"/> gets 0.</summary>
    public static void Apply<T>(IEnumerable<T> rows, IReadOnlyDictionary<int, decimal> days, Func<T, int> employeeOf, Action<T, decimal> set)
    {
        foreach (var row in rows)
            set(row, days.TryGetValue(employeeOf(row), out var value) ? value : 0m);
    }
}
