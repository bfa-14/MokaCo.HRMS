namespace MokaCo.HRMS.Model.Security;

/// <summary>
/// A user's CURRENT signature image, metadata ONLY — never the bytes.
///
/// This is what the Users grid reads: HasSignature drives the column, and the thumbnail is fetched
/// per row from its own image URL so the browser caches it. The image bytes deliberately never
/// travel in a list payload, so a user grid never drags megabytes around.
/// </summary>
public class UserSignatureInfo
{
    public int UserId { get; set; }
    public string Username { get; set; } = string.Empty;

    /// <summary>Whether this user has a signature on file. Drives the grid column without moving any bytes.</summary>
    public bool HasSignature { get; set; }

    public string? ContentType { get; set; }
    public string? FileName { get; set; }
    public int? ByteSize { get; set; }
    public DateTime? UpdatedAt { get; set; }
    public string? UpdatedByUsername { get; set; }
}

/// <summary>
/// One signature image WITH its bytes, for streaming back as an actual image.
///
/// Fetched one at a time through its own endpoint — never selected by a list or detail read, so the
/// megabytes only move when a specific image is being rendered.
/// </summary>
public class UserSignatureImage
{
    public int UserId { get; set; }
    public byte[] ImageBytes { get; set; } = System.Array.Empty<byte>();
    public string ContentType { get; set; } = string.Empty;
    public string? FileName { get; set; }
    public int ByteSize { get; set; }
    public DateTime UpdatedAt { get; set; }
}

/// <summary>Metadata returned after an upsert. Deliberately excludes the bytes — the caller just uploaded them.</summary>
public class UserSignatureSaved
{
    public int UserId { get; set; }
    public string ContentType { get; set; } = string.Empty;
    public string? FileName { get; set; }
    public int ByteSize { get; set; }
    public DateTime UpdatedAt { get; set; }
    public int? UpdatedBy { get; set; }
}
