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
    public LeaveLedgerController(ILeaveLedgerService ledger) => _ledger = ledger;

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
        return CreatedAtAction(nameof(GetByEmployee), new { employeeId = request.EmployeeId },
            new { leaveLedgerId = id });
    }

    [HttpDelete("{id:int}")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Delete(int id)
    {
        await _ledger.DeleteAsync(id);
        return NoContent();
    }
}
