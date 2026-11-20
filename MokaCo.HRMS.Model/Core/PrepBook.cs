namespace MokaCo.HRMS.Model.Core;

/// <summary>The stored recipe book (core.usp_PrepBook_Get, script 115). <see cref="Json"/> is null when the caller's
/// copy is still the current one.</summary>
public class PrepBookRow
{
    public string ETag { get; set; } = string.Empty;
    public int RecipeCount { get; set; }
    public DateTime UploadedAtUtc { get; set; }
    public string? UploadedBy { get; set; }
    public int ScanCount { get; set; }
    public string? Json { get; set; }
}

/// <summary>What the Recipes page shows about the book on file: how big it is and who uploaded it when.</summary>
public class PrepBookInfo
{
    public string ETag { get; set; } = string.Empty;
    public int RecipeCount { get; set; }
    public int ScanCount { get; set; }
    public DateTime UploadedAtUtc { get; set; }
    public string? UploadedBy { get; set; }
}

/// <summary>A scanned guide page ('page') or MIX label ('label').</summary>
public class PrepBookScan
{
    public string Kind { get; set; } = string.Empty;
    public int Number { get; set; }
    public byte[] Bytes { get; set; } = [];
}

/// <summary>An uploaded recipe book, checked and ready to store.</summary>
public class PrepBookPackage
{
    /// <summary>The book as the page reads it: the recipes, each drink's thumbnail inside as a data URI.</summary>
    public string Json { get; set; } = string.Empty;
    public string ETag { get; set; } = string.Empty;
    public int RecipeCount { get; set; }
    public List<PrepBookScan> Scans { get; set; } = [];
}
