using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Payroll;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Payroll;

/// <summary>
/// Dapper access for payroll via payroll.usp_* (and the attendance readiness gate).
///
/// THE PROCEDURES ARE THE AUTHORITY. They decide whether a month may become a run, whether a run may
/// be regenerated, what a payslip line is worth, and what approving does to the advances and expenses
/// behind it. This class carries parameters in and rows out, and re-derives none of it — a second
/// opinion here would be a second opinion about what people are paid.
///
/// The one query below that is not a procedure call resolves request-backed payslip lines to their
/// RequestInstanceId. It is a pure read over columns that already exist, added rather than changing
/// usp_Payslip_Get; see <see cref="GetPayslipAsync"/>.
/// </summary>
public class PayrollRepository : IPayrollRepository
{
    private readonly IDbConnectionFactory _factory;
    public PayrollRepository(IDbConnectionFactory factory) => _factory = factory;

    /// <summary>One row of the payslip-line → request resolution below.</summary>
    private sealed class LineRequestLink
    {
        public int PayslipLineId { get; set; }
        public int RequestInstanceId { get; set; }
    }

    // ───────────────────────────────── runs ─────────────────────────────────

    public async Task<IEnumerable<PayrollRunListItem>> GetRunsAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<PayrollRunListItem>(
            "payroll.usp_PayrollRun_GetList",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<PayrollRunCreated?> CreateRunAsync(
        string periodYearMonth, int createdByUserId, string? notes, string? runType)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PayrollRunCreated>(
            "payroll.usp_PayrollRun_Create",
            new
            {
                PeriodYearMonth = periodYearMonth,
                CreatedByUserId = createdByUserId,
                Notes = notes,
                // Null lets the procedure apply its own default rather than this layer asserting one.
                RunType = runType,
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// The four result sets of usp_PayrollRun_Get, READ IN ORDER AND ALL OF THEM.
    ///
    /// Dapper's GridReader is a forward-only cursor over the open stream: skipping a set shifts every
    /// set after it onto the wrong model, silently, and the page would render as blank cards rather
    /// than as an error. Header is single-or-default because a missing run is a 404, not a failure.
    /// </summary>
    public async Task<PayrollRunDetail> GetRunAsync(int payrollRunId)
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "payroll.usp_PayrollRun_Get",
            new { PayrollRunId = payrollRunId },
            commandType: CommandType.StoredProcedure);

        return new PayrollRunDetail
        {
            Header = await multi.ReadSingleOrDefaultAsync<PayrollRunHeader>(),
            Rates = (await multi.ReadAsync<PayrollRunRate>()).ToList(),
            Totals = await multi.ReadSingleOrDefaultAsync<PayrollRunTotals>(),
            Events = (await multi.ReadAsync<PayrollRunEvent>()).ToList(),
        };
    }

    public async Task<IEnumerable<PayslipListItem>> GetRunPayslipsAsync(int payrollRunId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<PayslipListItem>(
            "payroll.usp_PayrollRun_GetPayslips",
            new { PayrollRunId = payrollRunId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<PayrollRunGenerateResult?> GenerateAsync(int payrollRunId, int actedByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PayrollRunGenerateResult>(
            "payroll.usp_PayrollRun_Generate",
            new { PayrollRunId = payrollRunId, ActedByUserId = actedByUserId },
            commandType: CommandType.StoredProcedure,
            // Rebuilds every payslip and every line for the whole company in one transaction;
            // comfortably past the 30s default on a full month.
            commandTimeout: 300);
    }

    /// <summary>
    /// The OFF-CYCLE generator. A separate procedure, not a flag on the primary one: it pays
    /// approved, unconsumed adjustments and computes no statutory contributions, so the two share a
    /// name and nothing else.
    /// </summary>
    public async Task<PayrollRunGenerateResult?> GenerateSupplementalAsync(int payrollRunId, int actedByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PayrollRunGenerateResult>(
            "payroll.usp_PayrollRun_GenerateSupplemental",
            new { PayrollRunId = payrollRunId, ActedByUserId = actedByUserId },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 300);
    }

    public async Task<PayrollRunStatusResult?> SendToReviewAsync(int payrollRunId, int actedByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PayrollRunStatusResult>(
            "payroll.usp_PayrollRun_SendToReview",
            new { PayrollRunId = payrollRunId, ActedByUserId = actedByUserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<PayrollRunStatusResult?> ApproveAsync(int payrollRunId, int actedByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PayrollRunStatusResult>(
            "payroll.usp_PayrollRun_Approve",
            new { PayrollRunId = payrollRunId, ActedByUserId = actedByUserId },
            commandType: CommandType.StoredProcedure,
            // Stamps expenses, reduces advances and consumes adjustments in the same transaction.
            commandTimeout: 300);
    }

    public async Task<PayrollRunStatusResult?> CancelAsync(int payrollRunId, int actedByUserId, string? reason)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PayrollRunStatusResult>(
            "payroll.usp_PayrollRun_Cancel",
            // Passed through even when blank: the procedure's "A reason is required to cancel a
            // payroll run." names what is missing better than any guess made here.
            new { PayrollRunId = payrollRunId, ActedByUserId = actedByUserId, Reason = reason },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<PaymentSheetRow>> GetPaymentSheetAsync(int payrollRunId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<PaymentSheetRow>(
            "payroll.usp_PayrollRun_GetPaymentSheet",
            new { PayrollRunId = payrollRunId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<StatutoryReportRow>> GetStatutoryReportAsync(int payrollRunId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<StatutoryReportRow>(
            "payroll.usp_PayrollRun_GetStatutoryReport",
            new { PayrollRunId = payrollRunId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<MyPayslip>> GetMyPayslipsAsync(int userId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<MyPayslip>(
            "payroll.usp_Payslip_GetMine",
            // The USER id, not an employee id: the procedure resolves the person through
            // hr.EMPLOYEE.UserId, so nobody can read another's pay by changing a number.
            new { UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<EmployeePayslip>> GetPayslipsForEmployeeAsync(int employeeId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<EmployeePayslip>(
            "payroll.usp_Payslip_GetForEmployee",
            new { EmployeeId = employeeId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<PayslipLineLookup?> LookupLineAsync(string sourceType, int sourceId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PayslipLineLookup>(
            "payroll.usp_PayslipLine_Lookup",
            new { SourceType = sourceType, SourceId = sourceId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<PayrollReadiness?> GetReadinessAsync(string periodYearMonth)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PayrollReadiness>(
            "attendance.usp_Attendance_PayrollReadiness",
            new { PeriodYearMonth = periodYearMonth },
            commandType: CommandType.StoredProcedure);
    }

    // ─────────────────────────────── payslips ───────────────────────────────

    /// <summary>
    /// A payslip line's SourceId is the id in the SOURCE's own table — an ExpenseReimbursementId for
    /// an expense, an OvertimeRequestId for overtime — while every request page is keyed by
    /// RequestInstanceId. This maps one to the other for the lines that have a request behind them.
    ///
    /// The types listed are exactly the ones the generator writes with a typed-table id. Salary,
    /// Advance and Adjustment lines also carry a SourceId, but it points at a salary component, an
    /// advance or an adjustment — none of which is a request — so they are absent by design and
    /// resolve to null.
    /// </summary>
    private const string ResolveLineRequestsSql = @"
SELECT l.PayslipLineId, x.RequestInstanceId
FROM payroll.PAYSLIP_LINE l
CROSS APPLY (SELECT CASE l.SourceType
        WHEN 'Overtime'   THEN (SELECT o.RequestInstanceId FROM workflow.OVERTIME_REQUEST o     WHERE o.OvertimeRequestId      = l.SourceId)
        WHEN 'Tip'        THEN (SELECT t.RequestInstanceId FROM workflow.TIP_DISTRIBUTION t     WHERE t.TipDistributionId      = l.SourceId)
        WHEN 'Expense'    THEN (SELECT e.RequestInstanceId FROM workflow.EXPENSE_REIMBURSEMENT e WHERE e.ExpenseReimbursementId = l.SourceId)
        WHEN 'Separation' THEN (SELECT s.RequestInstanceId FROM workflow.SEPARATION s           WHERE s.SeparationId           = l.SourceId)
        WHEN 'Leave'      THEN (SELECT r.RequestInstanceId FROM workflow.LEAVE_REQUEST r        WHERE r.LeaveRequestId         = l.SourceId)
    END AS RequestInstanceId) x
WHERE l.PayslipId = @PayslipId AND l.SourceId IS NOT NULL AND x.RequestInstanceId IS NOT NULL;";

    public async Task<PayslipDetail> GetPayslipAsync(int payslipId)
    {
        using var db = _factory.Create();

        PayslipDetail detail;
        using (var multi = await db.QueryMultipleAsync(
            "payroll.usp_Payslip_Get",
            new { PayslipId = payslipId },
            commandType: CommandType.StoredProcedure))
        {
            detail = new PayslipDetail
            {
                Payslip = await multi.ReadSingleOrDefaultAsync<Payslip>(),
                Lines = (await multi.ReadAsync<PayslipLine>()).ToList(),
            };
        }

        if (detail.Payslip is null || detail.Lines.Count == 0)
            return detail;

        // EVERY FIGURE IS TRACEABLE. Resolved in a second read rather than by changing
        // usp_Payslip_Get, so the procedure the rest of the system relies on stays as written.
        var resolved = await db.QueryAsync<LineRequestLink>(
            ResolveLineRequestsSql, new { PayslipId = payslipId });

        var byLine = resolved.ToDictionary(r => r.PayslipLineId, r => r.RequestInstanceId);
        foreach (var line in detail.Lines)
        {
            if (byLine.TryGetValue(line.PayslipLineId, out var requestInstanceId))
                line.RequestInstanceId = requestInstanceId;
        }

        return detail;
    }

    public async Task<PayslipPaymentResult?> SetPaymentAsync(
        int payslipId, string paymentMethod, string? paymentReference, int actedByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PayslipPaymentResult>(
            "payroll.usp_Payslip_SetPayment",
            new
            {
                PayslipId = payslipId,
                PaymentMethod = paymentMethod,
                PaymentReference = paymentReference,
                ActedByUserId = actedByUserId,
            },
            commandType: CommandType.StoredProcedure);
    }

    // ────────────────────────── the caller's own salary ──────────────────────────
    // KEYED BY USER ID, WHICH THE PROCEDURE RESOLVES TO AN EMPLOYEE ITSELF. No employee id crosses
    // the wire, so there is no parameter for a caller to change in order to read somebody else's
    // pay — the question these two answer is only ever "mine".

    public async Task<MyPayslipStatus?> GetMyStatusAsync(int userId)
    {
        using var db = _factory.Create();
        // QuerySingleOrDefault, not Single: no row is the ordinary answer before the month is
        // generated, and the controller turns it into null rather than an error.
        return await db.QuerySingleOrDefaultAsync<MyPayslipStatus>(
            "payroll.usp_Payslip_GetMyStatus",
            new { UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    // ─────────────────────────────── advances ───────────────────────────────

    public async Task<IEnumerable<SalaryAdvance>> GetAdvancesAsync(int? employeeId, bool openOnly)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<SalaryAdvance>(
            "payroll.usp_Advance_GetList",
            new { EmployeeId = employeeId, OpenOnly = openOnly },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<SalaryAdvanceMonthlyResult?> UpdateAdvanceMonthlyAsync(
        int salaryAdvanceId, decimal monthlyDeduction, int actedByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<SalaryAdvanceMonthlyResult>(
            "payroll.usp_Advance_UpdateMonthly",
            new
            {
                SalaryAdvanceId = salaryAdvanceId,
                MonthlyDeduction = monthlyDeduction,
                ActedByUserId = actedByUserId,
            },
            commandType: CommandType.StoredProcedure);
    }

    // ────────────────────────────── adjustments ─────────────────────────────

    public async Task<IEnumerable<PayrollAdjustment>> GetAdjustmentsAsync(string targetPeriod)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<PayrollAdjustment>(
            "payroll.usp_Adjustment_GetForPeriod",
            new { TargetPeriod = targetPeriod },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<PayrollAdjustmentBulkResult?> CreateAdjustmentsBulkAsync(
        PayrollAdjustmentBulkRequest request, int createdByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PayrollAdjustmentBulkResult>(
            "payroll.usp_Adjustment_CreateBulk",
            new
            {
                request.ComponentTypeId,
                request.Amount,
                request.CurrencyCode,
                request.TargetPeriod,
                request.Reason,
                CreatedByUserId = createdByUserId,
                request.BranchId,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<PayrollAdjustmentDeleteResult?> DeleteAdjustmentAsync(int payrollAdjustmentId, int actedByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PayrollAdjustmentDeleteResult>(
            "payroll.usp_Adjustment_Delete",
            new { PayrollAdjustmentId = payrollAdjustmentId, ActedByUserId = actedByUserId },
            commandType: CommandType.StoredProcedure);
    }

    // ─────────────────────────────── reference ──────────────────────────────

    /// <summary>
    /// The component catalogue, with IsStanding. A plain read over hr.COMPONENT_TYPE rather than
    /// hr.usp_ComponentType_GetAll, which does not return that column — and the flag is the whole
    /// point of the list: it is what separates a component a person is assigned from one a payroll
    /// run produces.
    /// </summary>
    public async Task<IEnumerable<PayrollComponentType>> GetComponentTypesAsync()
    {
        const string sql = @"
SELECT ComponentTypeId, Name, Category, [Sign], IsStanding
FROM hr.COMPONENT_TYPE
ORDER BY Category, Name;";

        using var db = _factory.Create();
        return await db.QueryAsync<PayrollComponentType>(sql);
    }
}
