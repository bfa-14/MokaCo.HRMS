using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Services.Core;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// The drink recipes (the "Recipes" page): the book, the scanned guide pages and labels behind it, and its upload.
///
/// THE GUIDE IS CONFIDENTIAL, so this controller is the ONLY way its content leaves the server: it is not in the
/// source code and not in the website's files. Reading needs PREP_BOOK_VIEW, uploading PREP_BOOK_MANAGE (script 115,
/// Role permissions > Recipes). Answers are <c>private</c> - never kept by a shared cache - and the scans are fetched
/// by the page with the caller's token (an &lt;img src&gt; cannot send one), so a copied image address is useless to
/// somebody who is not signed in.
///
/// DELIBERATELY SILENT (no live notification): a new book is seen the next time the page is opened, and nobody is
/// watching a recipe change.
/// </summary>
[ApiController]
[Route("api/prep-book")]
public class PrepBookController : ControllerBase
{
    private readonly IPrepBookService _book;
    public PrepBookController(IPrepBookService book) => _book = book;

    /// <summary>
    /// The whole book: every recipe, with its thumbnail. 204 while no book has been uploaded; 304 when the caller's
    /// copy is still the current one.
    /// </summary>
    [HttpGet]
    [HasPermission("PREP_BOOK_VIEW")]
    public async Task<IActionResult> Get()
    {
        var theirs = Request.Headers.IfNoneMatch.ToString().Trim('"');
        var row = await _book.GetAsync(theirs.Length is > 0 and <= 40 ? theirs : null);
        if (row is null) return NoContent();

        // Kept by the caller's own browser, but checked with the server each time: a newly uploaded book is seen on
        // the next visit, and an unchanged one costs a 304 instead of the whole download.
        Response.Headers.CacheControl = "private, no-cache";
        Response.Headers.ETag = $"\"{row.ETag}\"";
        if (row.Json is null) return StatusCode(StatusCodes.Status304NotModified);
        return Content(row.Json, "application/json; charset=utf-8");
    }

    /// <summary>The book on file: how many recipes and scans, uploaded when and by whom. 204 when there is none.</summary>
    [HttpGet("info")]
    [HasPermission("PREP_BOOK_MANAGE")]
    public async Task<IActionResult> Info()
    {
        var info = await _book.GetInfoAsync();
        return info is null ? NoContent() : Ok(info);
    }

    /// <summary>A scanned page of the Drink Preparation Guide.</summary>
    [HttpGet("pages/{page:int}")]
    [HasPermission("PREP_BOOK_VIEW")]
    public Task<IActionResult> GuidePage(int page) => Scan("page", page);

    /// <summary>A scanned MC MIX label.</summary>
    [HttpGet("labels/{label:int}")]
    [HasPermission("PREP_BOOK_VIEW")]
    public Task<IActionResult> Label(int label) => Scan("label", label);

    /// <summary>
    /// Uploads the recipe book (one .zip: recipes.json + the scans) and REPLACES the one on file. The service checks
    /// every file by its own bytes and refuses with a sentence that says what is wrong; nothing is replaced unless
    /// the whole book is good.
    /// </summary>
    [HttpPost("upload")]
    [HasPermission("PREP_BOOK_MANAGE")]
    [RequestSizeLimit(PrepBookPackageReader.MaxZipBytes + 1024 * 1024)]
    [RequestFormLimits(MultipartBodyLengthLimit = PrepBookPackageReader.MaxZipBytes + 1024 * 1024)]
    public async Task<IActionResult> Upload(IFormFile? file)
    {
        if (file is null || file.Length == 0)
            return BadRequest(new { error = "Choose the recipe book (.zip)." });
        try
        {
            await using var stream = file.OpenReadStream();
            return Ok(await _book.ReplaceAsync(stream, User.UserId()));
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    private async Task<IActionResult> Scan(string kind, int number)
    {
        var bytes = await _book.GetScanAsync(kind, number);
        if (bytes is null) return NotFound();
        // A scan changes only when a new book is uploaded; an hour-old copy in the caller's own browser is fine.
        Response.Headers.CacheControl = "private, max-age=3600";
        return File(bytes, "image/jpeg");
    }
}
