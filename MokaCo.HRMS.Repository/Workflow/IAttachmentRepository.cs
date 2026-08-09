using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Repository.Workflow;

/// <summary>
/// Dapper access for request attachments via workflow.usp_Attachment_*.
///
/// The repository moves files in and out; it never decides WHO may see them — that visibility rule is
/// the same one the request detail enforces, and it lives in the service.
/// </summary>
public interface IAttachmentRepository
{
    /// <summary>Everything attached to a request — METADATA only, never the bytes.</summary>
    Task<IEnumerable<Attachment>> GetForRequestAsync(int requestInstanceId);

    /// <summary>One file WITH its bytes, to stream back. Null when there is no such attachment.</summary>
    Task<AttachmentFile?> GetFileAsync(int attachmentId);

    /// <summary>Stores a file and returns its new id. The procedure raises on empty bytes or a bad step.</summary>
    Task<int> AddAsync(int requestInstanceId, int? stepNo, int uploadedByUserId, string fileName, string contentType, byte[] fileBytes, string? caption);

    /// <summary>Removes an attachment, returning how many rows went. The procedure raises once the request is closed.</summary>
    Task<int> DeleteAsync(int attachmentId, int actedByUserId);
}
