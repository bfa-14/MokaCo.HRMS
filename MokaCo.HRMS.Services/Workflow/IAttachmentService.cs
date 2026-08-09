using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>
/// Request attachments, behind the SAME visibility rule as the request detail: only someone who may
/// see a request may list, add, fetch or remove its files. Every method takes the caller so it can
/// enforce that before touching a byte.
/// </summary>
public interface IAttachmentService
{
    /// <summary>The request's attachments (metadata only), if the caller may see the request.</summary>
    Task<IEnumerable<Attachment>> GetForRequestAsync(int requestInstanceId, RequestCaller caller);

    /// <summary>Attaches a file to a request (or one of its steps), if the caller may see the request. Returns the new id.</summary>
    Task<int> AddAsync(int requestInstanceId, int? stepNo, RequestCaller caller, string fileName, string contentType, byte[] fileBytes, string? caption);

    /// <summary>One file WITH its bytes, if the caller may see the request it belongs to. Null when there is no such attachment.</summary>
    Task<AttachmentFile?> GetFileAsync(int attachmentId, RequestCaller caller);

    /// <summary>Removes an attachment, if the caller may see its request. The database refuses once the request is closed, verbatim.</summary>
    Task DeleteAsync(int attachmentId, RequestCaller caller);
}
