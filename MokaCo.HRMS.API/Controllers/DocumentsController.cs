using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Configuration;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Services.HR;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/documents")]
public class DocumentsController : ControllerBase
{
    private readonly IDocumentService _documents;
    private readonly string _root;
    private readonly ILiveNotifier _live;

    public DocumentsController(
        IDocumentService documents,
        IWebHostEnvironment env,
        IConfiguration config,
        ILiveNotifier live)
    {
        _documents = documents;
        _live = live;
        // Where uploaded files are stored on the server. Configurable via
        // "Storage:DocumentsPath"; defaults to <ContentRoot>/App_Data/documents.
        var configured = config["Storage:DocumentsPath"];
        _root = string.IsNullOrWhiteSpace(configured)
            ? Path.Combine(env.ContentRootPath, "App_Data", "documents")
            : configured;
    }

    [HttpGet("by-employee/{employeeId:int}")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetByEmployee(int employeeId)
        => Ok(await _documents.GetByEmployeeAsync(employeeId));

    /// <summary>
    /// Records a document that lives SOMEWHERE ELSE — a contract in a shared drive, a scan in another
    /// system. Metadata only: no bytes are transferred and none are stored here.
    ///
    /// Distinct from /upload on purpose, and the difference matters for the download route: an
    /// uploaded file has a path under our own storage root, while StoragePath here is whatever the
    /// caller says it is, so /download cannot serve it and does not try.
    /// </summary>
    [HttpPost]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Create([FromBody] DocumentCreateRequest request)
    {
        if (request is null || request.EmployeeId <= 0)
            return BadRequest(new { error = "Say which employee this document belongs to." });
        if (string.IsNullOrWhiteSpace(request.FileName))
            return BadRequest(new { error = "A document needs a name." });
        if (string.IsNullOrWhiteSpace(request.StoragePath))
            return BadRequest(new { error = "A document recorded here needs the location it actually lives at." });

        var documentId = await _documents.CreateAsync(request);
        await _live.NotifyAsync("hr");
        return Ok(new { documentId });
    }

    /// <summary>
    /// Uploads a file for an employee. The file is written to server storage and
    /// only its path is kept in the DB; ContentType and SizeBytes are derived from
    /// the uploaded file (never supplied by the client).
    /// </summary>
    [HttpPost("upload")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Upload([FromQuery] int employeeId, IFormFile file)
    {
        if (file is null || file.Length == 0)
            return BadRequest(new { error = "No file was uploaded." });

        var employeeDir = Path.Combine(_root, employeeId.ToString());
        Directory.CreateDirectory(employeeDir);

        // Store under a unique name to avoid collisions; keep the original extension.
        var extension = Path.GetExtension(file.FileName);
        var storedName = $"{Guid.NewGuid():N}{extension}";
        var fullPath = Path.Combine(employeeDir, storedName);

        await using (var stream = System.IO.File.Create(fullPath))
        {
            await file.CopyToAsync(stream);
        }

        var relativePath = $"{employeeId}/{storedName}";
        var contentType = string.IsNullOrWhiteSpace(file.ContentType)
            ? "application/octet-stream"
            : file.ContentType;

        var id = await _documents.CreateAsync(new DocumentCreateRequest
        {
            EmployeeId = employeeId,
            FileName = file.FileName,
            StoragePath = relativePath,
            ContentType = contentType,
            SizeBytes = file.Length,
        });

        await _live.NotifyAsync("hr");
        return CreatedAtAction(nameof(GetByEmployee), new { employeeId },
            new { documentId = id });
    }

    /// <summary>Streams the stored file back with its original name and content type.</summary>
    [HttpGet("{id:int}/download")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> Download(int id)
    {
        var doc = await _documents.GetByIdAsync(id);
        if (doc is null)
            return NotFound();

        var fullPath = Path.Combine(_root, doc.StoragePath);
        if (!System.IO.File.Exists(fullPath))
            return NotFound(new { error = "The file is missing on the server." });

        var bytes = await System.IO.File.ReadAllBytesAsync(fullPath);
        var contentType = string.IsNullOrWhiteSpace(doc.ContentType)
            ? "application/octet-stream"
            : doc.ContentType;
        return File(bytes, contentType, doc.FileName);
    }

    [HttpDelete("{id:int}")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Delete(int id)
    {
        await _documents.DeleteAsync(id);
        await _live.NotifyAsync("hr");
        return NoContent();
    }
}
