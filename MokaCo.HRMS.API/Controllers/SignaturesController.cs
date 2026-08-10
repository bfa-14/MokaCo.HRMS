using System.Security.Cryptography;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Net.Http.Headers;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Frozen signature images, addressed by their signature-log id — the id a step in the approval
/// chain already carries as SignedSignatureId. The chain renders one &lt;img&gt; per signed step
/// pointing here, so the bytes are fetched ONE AT A TIME and never travel in the step list.
/// </summary>
[ApiController]
[Route("api/signatures")]
[Authorize]
public class SignaturesController : ControllerBase
{
    private readonly IRequestService _requests;
    public SignaturesController(IRequestService requests) => _requests = requests;

    /// <summary>
    /// Streams one FROZEN signature image with its stored content type, so a plain &lt;img&gt;
    /// renders it. The frozen copy is the one taken at signing — never the signer's current image —
    /// so an approval on the record never restyles itself when someone changes their signature later.
    ///
    /// Only [Authorize], not a per-request visibility rule: a signature is a mark shown on approval
    /// documents that any signed-in user may see, the same footing as a user's own signature image.
    /// 404 when the id has no image — the chain treats that as "no picture", which is normal.
    ///
    /// THE CACHING HERE USED TO BE WRONG, AND IT PUT THE WRONG PERSON'S MARK ON APPROVALS.
    ///
    /// It sent "max-age=31536000, immutable" on the reasoning that frozen bytes never change for a
    /// given id. The bytes don't — but the ID is not permanent. core.usp_System_ResetTestData ends
    /// with DBCC CHECKIDENT('workflow.WORKFLOW_SIGNATURE', RESEED, 0), so after any reset the
    /// numbering starts again and signature #51 becomes a DIFFERENT person's signature. `immutable`
    /// tells the browser never to revalidate, so it kept serving the previous occupant of that id
    /// for up to a year — while the name beside it, ordinary JSON, was correct and current. The
    /// result was a chain that showed one person's name over another person's mark.
    ///
    /// So the bytes are now validated rather than trusted. The ETag is derived from the CONTENT, so
    /// it survives renumbering: an unchanged image still costs a 304 and no body, and a recycled id
    /// whose content differs gets a new tag and fresh bytes. "no-cache" here means "store it, but
    /// ask before using it" — not "do not store".
    /// </summary>
    [HttpGet("{signedSignatureId:int}/image")]
    public async Task<IActionResult> FrozenImage(int signedSignatureId)
    {
        var image = await _requests.GetFrozenImageByIdAsync(signedSignatureId);
        if (image?.SignatureImage is null || image.SignatureContentType is null)
            return NotFound();

        // PRIVATE: a signature is not something to leave sitting in a shared proxy.
        Response.Headers.CacheControl = "private, no-cache";
        var etag = new EntityTagHeaderValue(ContentETag(image.SignatureImage));
        // lastModified null on purpose: the content hash is the whole validator. A date here would
        // invite If-Modified-Since, and a reseeded id can carry an OLDER date than the bytes it
        // replaced — the very confusion this is meant to end.
        return File(image.SignatureImage, image.SignatureContentType, null, etag);
    }

    /// <summary>
    /// A strong ETag over the bytes themselves.
    ///
    /// Content-derived on purpose: it is the only identity that survives an identity reseed, which
    /// is exactly the event that broke the previous scheme.
    /// </summary>
    internal static string ContentETag(byte[] bytes)
        => $"\"{Convert.ToHexString(SHA256.HashData(bytes), 0, 16)}\"";
}
