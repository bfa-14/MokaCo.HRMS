using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
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
    /// </summary>
    [HttpGet("{signedSignatureId:int}/image")]
    public async Task<IActionResult> FrozenImage(int signedSignatureId)
    {
        var image = await _requests.GetFrozenImageByIdAsync(signedSignatureId);
        if (image?.SignatureImage is null || image.SignatureContentType is null)
            return NotFound();

        // Frozen bytes never change for a given id — cache hard, but PRIVATE: a signature is not
        // something to leave sitting in a shared proxy.
        Response.Headers.CacheControl = "private, max-age=31536000, immutable";
        return File(image.SignatureImage, image.SignatureContentType);
    }
}
