using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Net.Http.Headers;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Files pinned to a request — the requester's supporting documents, and the proof an approver
/// attaches to a decision. Everything here sits behind the SAME visibility rule as the request
/// itself: the service resolves the owning request and refuses anyone who may not see it, surfaced
/// here as a 403.
///
/// The routes straddle two bases on purpose — a file is LISTED and ADDED under its request
/// (/api/requests/{id}/attachments), but FETCHED and REMOVED by its own id (/api/attachments/{id}),
/// because those callers hold only the attachment id.
/// </summary>
[ApiController]
[Authorize]
public class AttachmentsController : ControllerBase
{
    private readonly IAttachmentService _attachments;
    private readonly IWorkflowSupportService _support;

    public AttachmentsController(IAttachmentService attachments, IWorkflowSupportService support)
    {
        _attachments = attachments;
        _support = support;
    }

    /// <summary>What may be attached: documents and the common image formats, capped at 5 MB.</summary>
    private const long MaxFileBytes = 5 * 1024 * 1024;
    private static readonly HashSet<string> AllowedContentTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "application/pdf", "image/png", "image/jpeg", "image/webp",
    };

    /// <summary>Everything attached to a request — metadata only. Visible to anyone who may see the request.</summary>
    [HttpGet("api/requests/{id:int}/attachments")]
    public async Task<IActionResult> GetForRequest(int id)
    {
        try
        {
            return Ok(await _attachments.GetForRequestAsync(id, await BuildCallerAsync()));
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Attaches a file to a request, or to one of its steps when stepNo is given. Type and size are
    /// enforced HERE, before the bytes ever reach the database. Only someone who may see the request
    /// may attach to it — the service enforces that.
    /// </summary>
    [HttpPost("api/requests/{id:int}/attachments")]
    public async Task<IActionResult> Add(int id, IFormFile file, [FromForm] int? stepNo, [FromForm] string? caption)
    {
        if (file is null || file.Length == 0
            || file.Length > MaxFileBytes
            || !AllowedContentTypes.Contains(file.ContentType))
        {
            return BadRequest(new { error = "Only PDF, PNG, JPEG or WEBP files up to 5 MB are allowed." });
        }

        byte[] bytes;
        using (var ms = new MemoryStream())
        {
            await file.CopyToAsync(ms);
            bytes = ms.ToArray();
        }

        try
        {
            var attachmentId = await _attachments.AddAsync(
                id, stepNo, await BuildCallerAsync(), file.FileName, file.ContentType, bytes, caption);
            return Ok(new { attachmentId });
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Streams one file back, served as the STORED content type — never a guess from the extension.
    /// Behind the same visibility rule as its request.
    /// </summary>
    [HttpGet("api/attachments/{attachmentId:int}/file")]
    public async Task<IActionResult> GetFile(int attachmentId)
    {
        try
        {
            var file = await _attachments.GetFileAsync(attachmentId, await BuildCallerAsync());
            if (file is null)
                return NotFound();

            // The same defect the signature endpoints had: this URL is keyed by AttachmentId, and
            // workflow.REQUEST_ATTACHMENT is reseeded by core.usp_System_ResetTestData — so after a
            // reset, attachment #7 is a different file. A time-based cache with no validator would
            // hand back the previous occupant for a day, which on a document somebody APPROVED
            // against is the same class of wrong as the wrong signature. Validate on content.
            Response.Headers.CacheControl = "private, no-cache";
            var etag = new EntityTagHeaderValue(SignaturesController.ContentETag(file.FileBytes));
            return File(file.FileBytes, file.ContentType, file.FileName, null, etag);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>Removes an attachment. The database refuses once the request is closed, and that reaches the client verbatim.</summary>
    [HttpDelete("api/attachments/{attachmentId:int}")]
    public async Task<IActionResult> Delete(int attachmentId)
    {
        try
        {
            await _attachments.DeleteAsync(attachmentId, await BuildCallerAsync());
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>The caller's identity and rights, resolved from the token — the same shape the request endpoints build.</summary>
    private async Task<RequestCaller> BuildCallerAsync()
    {
        var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
        return new RequestCaller(User.UserId(), me?.EmployeeId, User.HasPermission("REQUEST_VIEW_ALL"));
    }
}
