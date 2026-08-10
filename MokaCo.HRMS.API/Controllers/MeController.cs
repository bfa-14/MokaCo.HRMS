using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Services.Payroll;
using MokaCo.HRMS.Services.Security;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>The signed-in user's own context. Every self-service screen keys off it.</summary>
/*
 * DELIBERATELY SILENT — see the note on AuthController. Changing your own password changes nothing
 * anybody is looking at, and a signature image is FROZEN onto each decision at the moment it is
 * signed, so replacing yours cannot alter a chain already on screen. It applies to your next
 * signature, which you have not made yet.
 */
[ApiController]
[Route("api/me")]
[Authorize]
public class MeController : ControllerBase
{
    private readonly IWorkflowSupportService _support;
    private readonly IUserSignatureService _signatures;
    private readonly IPayrollService _payroll;
    private readonly IUserService _users;

    public MeController(
        IWorkflowSupportService support, IUserSignatureService signatures, IPayrollService payroll,
        IUserService users)
    {
        _support = support;
        _signatures = signatures;
        _payroll = payroll;
        _users = users;
    }

    /// <summary>
    /// Changes the caller's own password. Authentication only — NO permission, because everybody has
    /// a password and gating this would leave most people unable to change theirs.
    ///
    /// THE ACCOUNT IS THE TOKEN'S, AND ONLY THE TOKEN'S. There is no id in the route and none in the
    /// body: <see cref="ChangePasswordRequest"/> carries the two passwords and nothing else, so the
    /// worst a caller can do by editing the request is change their own password. This is the whole
    /// reason it lives on /api/me rather than as a variant of /api/users/{id} — an id parameter here
    /// would need an authorisation rule to defend it, and the rule that does not exist cannot be got
    /// wrong.
    ///
    /// A wrong current password is a 400 with the reason, not a 401: the caller IS authenticated —
    /// their token is perfectly good — they have simply mistyped a field. Answering 401 would send
    /// the client's refresh-and-retry path down a road that cannot help, and on a second failure it
    /// would log them out for a typo.
    /// </summary>
    [HttpPost("change-password")]
    public async Task<IActionResult> ChangePassword([FromBody] ChangePasswordRequest request)
    {
        var result = await _users.ChangePasswordAsync(User.UserId(), request);
        return result.Success ? NoContent() : BadRequest(new { error = result.Error });
    }

    /// <summary>
    /// The caller's OWN payslips. Authentication only — NO payroll permission.
    ///
    /// That is the whole point: everybody is paid, so everybody must be able to read what they were
    /// paid, and gating this on PAYROLL_RUN would mean only the people who run payroll could ever
    /// see a payslip. The scoping is not done by a permission but by the procedure, which resolves
    /// the employee through hr.EMPLOYEE.UserId from the TOKEN — there is no id in the URL to change,
    /// so there is nothing to tamper with.
    ///
    /// APPROVED runs only, and an account not linked to an employee simply gets an empty list.
    /// </summary>
    [HttpGet("payslips")]
    public async Task<IActionResult> Payslips()
        => Ok(await _payroll.GetMyPayslipsAsync(User.UserId()));

    /// <summary>
    /// The employee record behind the token. An admin account with no employee record is NOT an
    /// error — it means "this user has no self-service", so a 204 is returned rather than a 404 or a
    /// 500. The frontend reads that as "hide the raise/mine screens", not "something broke".
    /// </summary>
    [HttpGet("employee")]
    public async Task<IActionResult> Employee()
    {
        var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
        return me is null ? NoContent() : Ok(me);
    }

    /* ---- my own signature image ----
       Deliberately NOT behind SIGNATURE_MANAGE. That permission is an owner-level trust because it
       lets someone put ANOTHER person's mark on an audit trail; putting your own mark on file is
       ordinary self-service, and requiring an admin for it would leave most people unable to sign. */

    /// <summary>
    /// Whether the caller has a signature image on file, with its metadata but NO bytes. Drives the
    /// "Your signature" panel and the sign dialog, which must know whether to show an image or a
    /// quiet line — never a broken one.
    /// </summary>
    [HttpGet("signature")]
    public async Task<IActionResult> MySignature()
    {
        var me = User.UserId();
        var all = await _signatures.GetAllAsync();
        var mine = all.FirstOrDefault(s => s.UserId == me);
        return mine is null ? NoContent() : Ok(mine);
    }

    /// <summary>
    /// Streams the caller's own signature image with its stored content type, so a plain &lt;img&gt;
    /// renders it. 404 when there is none — the caller treats that as "no image on file", which is a
    /// normal state and never blocks signing.
    /// </summary>
    [HttpGet("signature/image")]
    public async Task<IActionResult> MySignatureImage()
    {
        var image = await _signatures.GetImageAsync(User.UserId());
        if (image is null)
            return NotFound();

        // THE LIVE IMAGE, SO IT MUST NOT BE CACHED. This URL is fixed while the bytes behind it are
        // not: upload a new signature and the same address answers with different content. It was
        // max-age=86400, which meant the browser kept serving the OLD picture for a day after a
        // replacement — the upload had plainly worked and the page plainly disagreed.
        //
        // no-cache still permits storing; it forbids REUSING without revalidating, which is the
        // distinction that matters. The frozen images at /api/signatures/{id}/image are the opposite
        // case — one id, one set of bytes, forever — and rightly keep their long immutable cache.
        // Private either way: a signature is not something to leave in a shared proxy.
        Response.Headers.CacheControl = "private, no-cache";
        return File(image.ImageBytes, image.ContentType, image.FileName);
    }

    /// <summary>
    /// Uploads or replaces the caller's own signature image. multipart/form-data. The service checks
    /// the type from the file's OWN BYTES and caps the size, so a renamed executable is refused on
    /// what it is rather than what it claims to be.
    /// </summary>
    [HttpPost("signature")]
    public async Task<IActionResult> UploadMySignature(IFormFile file)
    {
        if (file is null || file.Length == 0)
            return BadRequest(new { error = "No file was uploaded." });

        var me = User.UserId();
        using var stream = new MemoryStream();
        await file.CopyToAsync(stream);

        try
        {
            return Ok(await _signatures.UploadAsync(me, stream.ToArray(), file.ContentType, file.FileName, me));
        }
        catch (SignatureValidationException ex)
        {
            // The user's own mistake to fix, not a server fault — 400 with a readable why.
            return BadRequest(new { error = ex.Message });
        }
    }

    /// <summary>Removes the caller's signature image. Signing still works without one.</summary>
    [HttpDelete("signature")]
    public async Task<IActionResult> DeleteMySignature()
    {
        await _signatures.DeleteAsync(User.UserId());
        return NoContent();
    }
}
