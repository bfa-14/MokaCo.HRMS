using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

/// <summary>
/// Dapper access for request attachments via workflow.usp_Attachment_*.
///
/// Metadata and bytes are kept apart on purpose: the list procedure never returns bytes, and only the
/// file procedure does, so a request with several documents never drags them all into one response.
/// </summary>
public class AttachmentRepository : IAttachmentRepository
{
    private readonly IDbConnectionFactory _factory;
    public AttachmentRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<Attachment>> GetForRequestAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<Attachment>(
            "workflow.usp_Attachment_GetForRequest",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<AttachmentFile?> GetFileAsync(int attachmentId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<AttachmentFile>(
            "workflow.usp_Attachment_GetFile",
            new { AttachmentId = attachmentId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>The procedure SELECTs the new AttachmentId back as a scalar.</summary>
    public async Task<int> AddAsync(int requestInstanceId, int? stepNo, int uploadedByUserId, string fileName, string contentType, byte[] fileBytes, string? caption)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "workflow.usp_Attachment_Add",
            new
            {
                RequestInstanceId = requestInstanceId,
                StepNo = stepNo,
                UploadedByUserId = uploadedByUserId,
                FileName = fileName,
                ContentType = contentType,
                FileBytes = fileBytes,
                Caption = caption,
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>The procedure raises if the request is closed, and otherwise SELECTs @@ROWCOUNT as a scalar.</summary>
    public async Task<int> DeleteAsync(int attachmentId, int actedByUserId)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "workflow.usp_Attachment_Delete",
            new { AttachmentId = attachmentId, ActedByUserId = actedByUserId },
            commandType: CommandType.StoredProcedure);
    }
}
