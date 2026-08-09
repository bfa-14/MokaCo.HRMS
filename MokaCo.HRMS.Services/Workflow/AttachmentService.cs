using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>
/// Request attachments, gated by the SAME visibility rule as the request detail.
///
/// Rather than duplicate that rule, this leans on <see cref="IRequestService.GetByIdAsync"/>: it
/// already grants access exactly when the caller holds REQUEST_VIEW_ALL, is the employee, raised the
/// request, or is an approver on it — and throws 403 otherwise. Every attachment operation resolves
/// the owning request and runs that same gate before touching a file.
/// </summary>
public class AttachmentService : IAttachmentService
{
    private readonly IAttachmentRepository _repo;
    private readonly IRequestService _requests;

    public AttachmentService(IAttachmentRepository repo, IRequestService requests)
    {
        _repo = repo;
        _requests = requests;
    }

    public async Task<IEnumerable<Attachment>> GetForRequestAsync(int requestInstanceId, RequestCaller caller)
    {
        await EnsureCanSeeAsync(requestInstanceId, caller);
        return await _repo.GetForRequestAsync(requestInstanceId);
    }

    /// <summary>
    /// The visibility gate runs first; the procedure's own guards (empty bytes, a step that is not on
    /// this request) are then mapped so they reach the client as clean 400s rather than 500s.
    /// </summary>
    public async Task<int> AddAsync(int requestInstanceId, int? stepNo, RequestCaller caller, string fileName, string contentType, byte[] fileBytes, string? caption)
    {
        await EnsureCanSeeAsync(requestInstanceId, caller);
        return await WorkflowSqlErrors.MapAsync(
            () => _repo.AddAsync(requestInstanceId, stepNo, caller.UserId, fileName, contentType, fileBytes, caption));
    }

    public async Task<AttachmentFile?> GetFileAsync(int attachmentId, RequestCaller caller)
    {
        var file = await _repo.GetFileAsync(attachmentId);
        if (file is null)
            return null;

        await EnsureCanSeeAsync(file.RequestInstanceId, caller);
        return file;
    }

    public async Task DeleteAsync(int attachmentId, RequestCaller caller)
    {
        var file = await _repo.GetFileAsync(attachmentId);
        if (file is null)
            throw new WorkflowException(404, "Attachment not found.");

        await EnsureCanSeeAsync(file.RequestInstanceId, caller);

        // The closed-request refusal is human-readable and must reach the client verbatim.
        await WorkflowSqlErrors.MapAsync(() => _repo.DeleteAsync(attachmentId, caller.UserId));
    }

    /// <summary>Throws 403 if the caller may not see the request, 404 if there is no such request.</summary>
    private async Task EnsureCanSeeAsync(int requestInstanceId, RequestCaller caller)
    {
        var detail = await _requests.GetByIdAsync(requestInstanceId, caller); // throws 403 if not visible
        if (detail is null)
            throw new WorkflowException(404, "Request not found.");
    }
}
