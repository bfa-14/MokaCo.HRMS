namespace MokaCo.HRMS.Model.Report;

/// <summary>
/// A printable report: a HEADER block and the DETAIL rows, together.
///
/// Every report procedure returns TWO result sets — a one-row header (title, period, branch,
/// generated-at) and the rows — because a printout is a document, not a grid: it needs a title
/// block that names what it is and when it was run, independent of the data underneath. Binding
/// them into one object is what forces the caller to read BOTH: read only the first and the report
/// has a title and no data; read only the second and it is an anonymous table nobody can date.
/// </summary>
public class ReportResult<THeader, TRow>
{
    public THeader Header { get; set; } = default!;
    public List<TRow> Rows { get; set; } = new();
}
