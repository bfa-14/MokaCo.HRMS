namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// One file attached to a request — its METADATA only, never the bytes
/// (workflow.usp_Attachment_GetForRequest).
///
/// An attachment belongs either to the REQUEST (the requester's supporting document, StepNo null) or
/// to a DECISION (proof an approver pinned to a step, StepNo set). <see cref="AttachedTo"/> spells
/// that out so the UI does not have to infer it from a null. The bytes are fetched one file at a time
/// from the file endpoint, so a request with several documents never drags them all into one list.
/// </summary>
public class Attachment
{
    public int AttachmentId { get; set; }
    public int RequestInstanceId { get; set; }

    /// <summary>Null when the file belongs to the request itself; a step number when it is proof for that decision.</summary>
    public int? StepNo { get; set; }

    /// <summary>'Request' or 'Decision' — which of the two an attachment is, spelled out for the UI.</summary>
    public string AttachedTo { get; set; } = string.Empty;

    public string? StepName { get; set; }

    public int UploadedByUserId { get; set; }
    public string? UploadedByUsername { get; set; }

    public string FileName { get; set; } = string.Empty;
    public string ContentType { get; set; } = string.Empty;
    public long ByteSize { get; set; }
    public string? Caption { get; set; }
    public DateTime UploadedAt { get; set; }
}

/// <summary>
/// One attachment WITH its bytes (workflow.usp_Attachment_GetFile) — the payload the file endpoint
/// streams back. The stored <see cref="ContentType"/> is what the response is served as; the file
/// extension is never trusted for that.
/// </summary>
public class AttachmentFile
{
    public int AttachmentId { get; set; }
    public int RequestInstanceId { get; set; }
    public int? StepNo { get; set; }
    public string FileName { get; set; } = string.Empty;
    public string ContentType { get; set; } = string.Empty;
    public long ByteSize { get; set; }
    public byte[] FileBytes { get; set; } = Array.Empty<byte>();
}
