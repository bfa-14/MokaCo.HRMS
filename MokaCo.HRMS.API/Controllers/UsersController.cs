using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Services.Security;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/users")]
public class UsersController : ControllerBase
{
    private readonly IUserService _users;
    private readonly IUserSignatureService _signatures;

    private readonly ILiveNotifier _live;

    public UsersController(
        IUserService users, IUserSignatureService signatures, ILiveNotifier live)
    {
        _users = users;
        _signatures = signatures;
        _live = live;
    }

    private int CurrentUserId =>
        int.Parse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub")!);

    [HttpGet]
    [HasPermission("USER_MANAGE")]
    public async Task<IActionResult> GetAll() => Ok(await _users.GetAllAsync());

    /// <summary>Accounts not yet linked to any employee — feeds the employee-accounts link picker.</summary>
    [HttpGet("unlinked")]
    [HasPermission("USER_MANAGE")]
    public async Task<IActionResult> GetUnlinked() => Ok(await _users.GetUnlinkedAsync());

    [HttpPost]
    [HasPermission("USER_MANAGE")]
    public async Task<IActionResult> Create([FromBody] CreateUserRequest request)
    {
        var id = await _users.CreateAsync(request, CurrentUserId);
        await _live.NotifyAsync("workflow", "dashboard");
        return CreatedAtAction(nameof(GetAll), new { id }, new { userId = id });
    }

    [HttpPost("{id:int}/active")]
    [HasPermission("USER_MANAGE")]
    public async Task<IActionResult> SetActive(int id, [FromQuery] bool isActive)
    {
        await _users.SetActiveAsync(id, isActive, CurrentUserId);
        // Deactivating an account removes a signer: fn_CanUserActOnStep only counts ACTIVE users,
        // so steps waiting on them, and any deputy cover, change the moment this lands.
        await _live.NotifyAsync("workflow", "dashboard");
        return NoContent();
    }

    /* ---- signature images ---- */

    /// <summary>
    /// Who has a signature, with metadata but NO bytes — the flag that drives the grid column.
    /// USER_MANAGE, because this is part of administering users; the image itself is a separate,
    /// per-row fetch.
    /// </summary>
    [HttpGet("signatures")]
    [HasPermission("USER_MANAGE")]
    public async Task<IActionResult> GetSignatures() => Ok(await _signatures.GetAllAsync());

    /// <summary>
    /// Streams one user's CURRENT signature image with its stored content type. Only authenticated
    /// (not USER_MANAGE): a signature is shown on documents that any signed-in user may see, so
    /// seeing the image cannot need more than a login.
    /// </summary>
    [HttpGet("{userId:int}/signature/image")]
    [Authorize]
    public async Task<IActionResult> GetSignatureImage(int userId)
    {
        var image = await _signatures.GetImageAsync(userId);
        if (image is null)
            return NotFound();

        // THE LIVE IMAGE, SO IT MUST NOT BE CACHED — the same defect as /api/me/signature/image had.
        // This is addressed by USER ID, not by content: the id is stable while the bytes behind it
        // are replaced whenever that person uploads a new signature. The old comment here claimed
        // the bytes were immutable, which is true only of the FROZEN images under /api/signatures.
        Response.Headers.CacheControl = "private, no-cache";
        return File(image.ImageBytes, image.ContentType, image.FileName);
    }

    /// <summary>
    /// Uploads (or replaces) a user's signature. multipart/form-data. SIGNATURE_MANAGE — an
    /// owner-level trust, because whoever can do this can make somebody's mark appear on an audit
    /// trail. The type is validated from the file's own bytes and the size is capped in the service.
    /// </summary>
    [HttpPost("{userId:int}/signature")]
    [HasPermission("SIGNATURE_MANAGE")]
    public async Task<IActionResult> UploadSignature(int userId, IFormFile file)
    {
        if (file is null || file.Length == 0)
            return BadRequest(new { error = "No file was uploaded." });

        using var stream = new MemoryStream();
        await file.CopyToAsync(stream);

        try
        {
            var saved = await _signatures.UploadAsync(
                userId, stream.ToArray(), file.ContentType, file.FileName, CurrentUserId);
            await _live.NotifyAsync("workflow");
            return Ok(saved);
        }
        catch (SignatureValidationException ex)
        {
            // A bad upload is the user's mistake to fix, not a server fault — 400 with a readable why.
            return BadRequest(new { error = ex.Message });
        }
    }

    [HttpDelete("{userId:int}/signature")]
    [HasPermission("SIGNATURE_MANAGE")]
    public async Task<IActionResult> DeleteSignature(int userId)
    {
        await _signatures.DeleteAsync(userId);
        await _live.NotifyAsync("workflow");
        return NoContent();
    }
}
