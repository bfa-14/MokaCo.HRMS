using System.Security.Claims;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Services.HR;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/leave-ledger")]
public class LeaveLedgerController : ControllerBase
{
    private readonly ILeaveLedgerService _ledger;
    private readonly ILiveNotifier _live;

    public LeaveLedgerController(ILeaveLedgerService ledger, ILiveNotifier live)
    {
        _ledger = ledger;
        _live = live;
    }

    private int CurrentUserId =>
        int.Parse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub")!);

    [HttpGet("by-employee/{employeeId:int}")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetByEmployee(int employeeId, [FromQuery] string? period)
        => Ok(await _ledger.GetByEmployeeAsync(employeeId, period));

    [HttpGet("balance/{employeeId:int}")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetBalance(int employeeId, [FromQuery] string? period)
        => Ok(await _ledger.GetBalanceAsync(employeeId, period));

    [HttpPost]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> PostMovement([FromBody] LeaveLedgerPostRequest request)
    {
        var id = await _ledger.PostMovementAsync(request, CurrentUserId);
        // Leave balances are a dashboard tile and a figure every leave decision is judged against.
        await _live.NotifyAsync("hr", "dashboard");
        return CreatedAtAction(nameof(GetByEmployee), new { employeeId = request.EmployeeId },
            new { leaveLedgerId = id });
    }

    [HttpDelete("{id:int}")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Delete(int id)
    {
        await _ledger.DeleteAsync(id);
        await _live.NotifyAsync("hr", "dashboard");
        return NoContent();
    }
}
