using System.Security.Claims;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.HR;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/employees")]
public class EmployeesController : ControllerBase
{
    private readonly IEmployeeService _employees;
    private readonly ILeaveRequestService _leave;
    private readonly IRosterService _roster;
    private readonly IOvertimeService _overtime;
    private readonly IExpenseService _expenses;
    private readonly ISalaryComponentService _salaryComponents;
    private readonly ILiveNotifier _live;

    /// <summary>
    /// The people records are what the dashboard counts and what the chains resolve approvers
    /// against, so a change here is never local to this screen.
    /// </summary>
    private Task NotifyPeopleAsync() => _live.NotifyAsync("hr", "dashboard");

    public EmployeesController(
        IEmployeeService employees,
        ILeaveRequestService leave,
        IRosterService roster,
        IOvertimeService overtime,
        IExpenseService expenses,
        ISalaryComponentService salaryComponents,
        ILiveNotifier live)
    {
        _live = live;
        _employees = employees;
        _leave = leave;
        _roster = roster;
        _overtime = overtime;
        _expenses = expenses;
        _salaryComponents = salaryComponents;
    }

    private int CurrentUserId =>
        int.Parse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub")!);

    [HttpGet]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetAll() => Ok(await _employees.GetAllAsync());

    [HttpGet("{id:int}")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetProfile(int id)
    {
        var profile = await _employees.GetProfileAsync(id);
        return profile is null ? NotFound() : Ok(profile);
    }

    [HttpPost]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Create([FromBody] EmployeeCreateRequest request)
    {
        try
        {
            var id = await _employees.CreateAsync(request, CurrentUserId);
            await NotifyPeopleAsync();
            return CreatedAtAction(nameof(GetProfile), new { id }, new { employeeId = id });
        }
        catch (WorkflowException ex)
        {
            // A taken login gets the friendly "already linked to {name}" message, not a raw 500.
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpPut("{id:int}")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Update(int id, [FromBody] EmployeeUpdateRequest request)
    {
        await _employees.UpdateAsync(id, request, CurrentUserId);
        await NotifyPeopleAsync();
        return NoContent();
    }

    /// <summary>
    /// Sets the employee's approval tier — which published chain their requests follow. Kept separate
    /// from the main edit because it is a workflow decision (management/executive get shorter chains),
    /// not a demographic field, and it has its own validation. EMP_EDIT, the same trust as any edit.
    /// </summary>
    [HttpPut("{id:int}/approval-tier")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> SetApprovalTier(int id, [FromBody] ApprovalTierRequest request)
    {
        try
        {
            var result = await _employees.SetApprovalTierAsync(id, request.ApprovalTier);
            if (result is null) return NotFound();

            // The tier picks WHICH published chain their requests run, so this changes who will be
            // asked to sign the next one.
            await _live.NotifyAsync("hr", "workflow", "dashboard");
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Sets who this employee reports to — the reporting line a LineManager chain step climbs. The
    /// procedure REFUSES a self-reference or a loop, and that message is the whole value (it names the
    /// problem), so it is surfaced verbatim rather than swallowed.
    /// </summary>
    [HttpPut("{id:int}/reports-to")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> SetReportsTo(int id, [FromBody] ReportsToRequest request)
    {
        try
        {
            var result = await _employees.SetReportsToAsync(id, request.ReportsToEmployeeId);
            if (result is null) return NotFound();

            // A LineManager step resolves up this reporting line — moving it moves who signs.
            await _live.NotifyAsync("hr", "workflow", "dashboard");
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>This employee's chain of command, bottom-up — shown under the "Reports to" field.</summary>
    [HttpGet("{id:int}/reporting-line")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetReportingLine(int id)
        => Ok(await _employees.GetReportingLineAsync(id));

    /// <summary>The whole org tree for the org-chart page, pre-sorted depth-first.</summary>
    [HttpGet("org-tree")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetOrgTree()
        => Ok(await _employees.GetOrgTreeAsync());

    /// <summary>
    /// This employee's ROSTER over a window — the day, the shift on it, and whether it is a rest
    /// day. The shift-swap form reads it to show what is actually rostered beside each date picker,
    /// so nobody proposes swapping a day they are not working (which the create procedure refuses).
    ///
    /// Backed by the existing attendance.usp_ShiftAssignment_GetByDateRange rather than a new read:
    /// it already answers exactly this question, and a second procedure would be a second answer.
    /// EMP_VIEW, like the rest of an employee's record.
    /// </summary>
    [HttpGet("{id:int}/assignments")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetAssignments(int id, [FromQuery] DateTime from, [FromQuery] DateTime to)
    {
        if (to < from)
            return BadRequest(new { error = "The end of the range is before its start." });

        return Ok(await _roster.GetAsync(from, to, id));
    }

    /// <summary>
    /// This employee's leave requests, newest first. The date bounds OVERLAP rather than contain, so
    /// a request spanning the window is included — which is what someone checking a date needs.
    /// </summary>
    [HttpGet("{id:int}/leave-requests")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetLeaveRequests(int id, [FromQuery] DateTime? from, [FromQuery] DateTime? to)
        => Ok(await _leave.GetForEmployeeAsync(id, from, to));

    /// <summary>This employee's expense claims, newest first, optionally bounded by expense date.</summary>
    [HttpGet("{id:int}/expenses")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetExpenses(int id, [FromQuery] DateTime? from, [FromQuery] DateTime? to)
        => Ok(await _expenses.GetForEmployeeAsync(id, from, to));

    /// <summary>This employee's overtime requests, newest first, optionally bounded by work date.</summary>
    [HttpGet("{id:int}/overtime")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetOvertime(int id, [FromQuery] DateTime? from, [FromQuery] DateTime? to)
        => Ok(await _overtime.GetForEmployeeAsync(id, from, to));

    /// <summary>
    /// This employee's balance for ONE leave type — the all-time ledger sum, shown beside a leave
    /// request so the requester and the approver see the same figure. 404 when the leave type does not
    /// exist; an employee with no ledger movements is a balance of zero, not a 404.
    ///
    /// WITHOUT a leaveTypeId it answers for the whole LEAVE YEAR instead (hr.vw_LEAVE_BALANCE via
    /// hr.usp_Leave_GetBalanceByYear): one row per leave type — LeaveType, Entitlement, CarriedOver,
    /// Used, Adjusted, Remaining, Year — under { employeeId, year, yearOpened, balances }. When the
    /// year was never opened for this employee, balances is EMPTY and yearOpened is false: there is
    /// no entitlement to measure against yet. `year` defaults to the current year.
    /// </summary>
    [HttpGet("{id:int}/leave-balance")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetLeaveBalance(int id, [FromQuery] int? leaveTypeId, [FromQuery] int? year)
    {
        if (leaveTypeId is null)
            return Ok(await _leave.GetBalanceByYearAsync(id, year));

        var balance = await _leave.GetBalanceAsync(id, leaveTypeId.Value);
        return balance is null ? NotFound() : Ok(balance);
    }

    [HttpDelete("{id:int}")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Delete(int id)
    {
        await _employees.SoftDeleteAsync(id, CurrentUserId);
        await NotifyPeopleAsync();
        return NoContent();
    }

    /* ---- employee <-> user account linking (USER_MANAGE: this is account administration) ---- */

    /// <summary>
    /// Every active employee with their login state — the accounts screen. onlyMissing=true returns
    /// only the ones who still need an account. Each row carries a Warning for the case that quietly
    /// breaks approvals: a branch manager who cannot sign because they have no usable login.
    /// </summary>
    [HttpGet("login-status")]
    [HasPermission("USER_MANAGE")]
    public async Task<IActionResult> LoginStatus([FromQuery] bool onlyMissing = false)
        => Ok(await _employees.GetLoginStatusAsync(onlyMissing));

    /// <summary>
    /// Links an existing account to this employee (or corrects which one). Refuses with a 400 whose
    /// message names the other employee if the account is already taken — surfaced as-is, never
    /// swallowed. A non-null Warning in the result means "linked, but the account is disabled".
    /// </summary>
    [HttpPut("{id:int}/user")]
    [HasPermission("USER_MANAGE")]
    public async Task<IActionResult> LinkUser(int id, [FromBody] LinkUserRequest request)
    {
        try
        {
            var result = await _employees.LinkUserAsync(id, request.UserId, CurrentUserId);
            if (result is null) return NotFound();

            // Giving somebody a login is what makes them able to SIGN — a branch manager without
            // one silently skips their step.
            await _live.NotifyAsync("hr", "workflow", "dashboard");
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Breaks the link. Returns what it cost — whether they managed a branch, and how many pending
    /// requests can no longer be signed by them — so the UI can report the consequence.
    /// </summary>
    [HttpDelete("{id:int}/user")]
    [HasPermission("USER_MANAGE")]
    public async Task<IActionResult> UnlinkUser(int id)
    {
        var result = await _employees.UnlinkUserAsync(id, CurrentUserId);
        // It reports how many pending requests they can no longer sign — those chains just changed.
        await _live.NotifyAsync("hr", "workflow", "dashboard");
        return Ok(result);
    }

    // ───────────────────── salary administration ─────────────────────
    //
    // THE HISTORY-PRESERVING PATH. These two are not the same thing as the older
    // POST/PUT/DELETE on /api/salary-components, which edit a row in place: a change here CLOSES
    // the standing row the day before and OPENS a new one, so a month already paid keeps saying
    // what it paid. Use these.
    //
    // The gate is EMP_VIEW/EMP_EDIT for consistency with the rest of this controller, but the real
    // authority is the procedure — it checks for the HR (or Admin) role itself and refuses with
    // "Salaries are administered by HR." That check is not repeated here, because two opinions
    // about who may change a salary is one too many.

    /// <summary>Every salary row for the employee — the standing ones and the closed history.</summary>
    [HttpGet("{id:int}/salary-components")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetSalaryComponents(int id)
        => Ok(await _salaryComponents.GetForEmployeeAsync(id));

    /// <summary>
    /// Sets what a component is worth FROM a date, closing whatever stood before it.
    ///
    /// The refusal to expect is the locked-through one — it names the earliest date that would
    /// work, so the message contains its own fix. Returned verbatim.
    /// </summary>
    [HttpPut("{id:int}/salary-components")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> SetSalaryComponent(int id, [FromBody] SalaryComponentSetRequest request)
    {
        try
        {
            var saved = await _salaryComponents.SetAsync(id, request, CurrentUserId);
            await _live.NotifyAsync("hr", "payroll", "dashboard");
            return Ok(saved);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }
}
