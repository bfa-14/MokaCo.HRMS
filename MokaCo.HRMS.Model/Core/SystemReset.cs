namespace MokaCo.HRMS.Model.Core;

/// <summary>
/// One line of the "what survived" summary a reset returns — "Users: 9", "Published chains: 4".
///
/// It is the point of the whole feature, not a receipt: the fear before pressing the button is
/// "what else will this take with it", and the answer is only convincing as counts of the things
/// that are still there. Rendered as a table, never collapsed into a sentence.
/// </summary>
public class SystemResetSummaryRow
{
    /// <summary>
    /// What was kept — 'Users', 'Roles', 'Employees (kept)'. NAMED FOR THE PROCEDURE'S COLUMN,
    /// which is Item. It was Kept here, so Dapper matched nothing and every name came back empty
    /// while the counts beside them were right — the table read as rows of anonymous numbers.
    /// </summary>
    public string Item { get; set; } = string.Empty;
    public int Rows { get; set; }
}

/// <summary>
/// The reset request. The phrase is passed through UNCHECKED — the procedure compares it, so there
/// is exactly one definition of "exact", and a client that skips its own check still cannot get past
/// the database.
/// </summary>
public class SystemResetRequest
{
    public string Confirm { get; set; } = string.Empty;
}
