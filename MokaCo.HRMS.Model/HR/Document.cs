namespace MokaCo.HRMS.Model.HR;

/// <summary>Maps to hr.DOCUMENT. Metadata for an employee file attachment (the file lives on storage).</summary>
public class Document
{
    public int DocumentId { get; set; }
    public int EmployeeId { get; set; }
    public string FileName { get; set; } = string.Empty;
    public string StoragePath { get; set; } = string.Empty;
    public string ContentType { get; set; } = string.Empty;
    public long SizeBytes { get; set; }
    public DateTime UploadedUtc { get; set; }
}
