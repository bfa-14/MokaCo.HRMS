using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Authorization;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Services.HR;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// The approval-tier dictionary — which named rank each tier number stands for.
///
/// THE READ IS OPEN TO ANY SIGNED-IN USER, and deliberately so: a tier name is a LABEL, printed on
/// the employee list, the org chart and anyone's own profile. Gating it would leave those screens
/// showing "Tier 2" to most of the company while a handful of administrators saw "Management" —
/// the same data, worse. Writing the dictionary is EMP_EDIT, the same trust as editing the people
/// it describes.
/// </summary>
[ApiController]
[Route("api/hr/approval-tiers")]
[Authorize]
public class ApprovalTiersController : ControllerBase
{
    private readonly IApprovalTierService _tiers;
    private readonly ILiveNotifier _live;

    public ApprovalTiersController(IApprovalTierService tiers, ILiveNotifier live)
    {
        _tiers = tiers;
        _live = live;
    }

    /// <summary>The dictionary. Any authenticated user — see the note on the class.</summary>
    [HttpGet]
    public async Task<IActionResult> GetAll() => Ok(await _tiers.GetAllAsync());

    [HttpPost]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Create([FromBody] ApprovalTierCreateRequest request)
    {
        try
        {
            var created = await _tiers.CreateAsync(request.TierNo, request.Name, request.NameAr);
            // Every screen that prints a tier name reads this list.
            await _live.NotifyAsync("hr", "workflow");
            return Ok(created);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>Renames a tier. The NUMBER is identity and never moves — only its names change.</summary>
    [HttpPut("{tierNo:int}")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> SetName(int tierNo, [FromBody] ApprovalTierNameRequest request)
    {
        try
        {
            var updated = await _tiers.SetNameAsync(tierNo, request.Name, request.NameAr);
            // ONLY when the tier is genuinely not in the dictionary. A rename the procedure
            // PERFORMED but did not select back is not this case — the service reads it back, so a
            // successful write can never leave here as a 404. And a number that does not exist
            // never reaches this line: the procedure raises "Tier N does not exist", which comes
            // out of the catch below as a 400 carrying that sentence.
            if (updated is null) return NotFound();

            await _live.NotifyAsync("hr", "workflow");
            return Ok(updated);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Sets the BASIC-SALARY BAND for a tier — what a basic salary at this rank may be.
    ///
    /// PAYROLL_RUN, not EMP_EDIT. Renaming a tier is labelling; this decides what anybody at that
    /// rank may be paid, and a database trigger enforces it on every salary-component write. Whoever
    /// runs payroll is who may move the band.
    ///
    /// Either bound may be null — "no bound" is a real setting, and both null clears the band. The
    /// procedure refuses a min above a max and an unknown currency by name; those sentences travel
    /// back as 400s untouched.
    /// </summary>
    [HttpPut("{tierNo:int}/salary-range")]
    [HasPermission("PAYROLL_RUN")]
    public async Task<IActionResult> SetSalaryRange(
        int tierNo, [FromBody] ApprovalTierSalaryRangeRequest request)
    {
        try
        {
            var updated = await _tiers.SetSalaryRangeAsync(
                tierNo, request.MinBasicSalary, request.MaxBasicSalary, request.SalaryCurrency);
            // As with the rename: a tier the procedure does not know raises its own sentence and
            // leaves through the catch, so a null here really is "no such tier".
            if (updated is null) return NotFound();

            // The band is read by the salary form's hint and enforced on every pay write.
            await _live.NotifyAsync("hr", "payroll", "workflow");
            return Ok(updated);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Removes a tier. The procedure REFUSES while anyone still holds it and names who, so the
    /// refusal travels back verbatim — "cannot delete" alone would leave the user nothing to do.
    /// </summary>
    [HttpDelete("{tierNo:int}")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Delete(int tierNo)
    {
        try
        {
            await _tiers.DeleteAsync(tierNo);
            await _live.NotifyAsync("hr", "workflow");
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }
}
