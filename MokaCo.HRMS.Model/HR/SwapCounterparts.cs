namespace MokaCo.HRMS.Model.HR;

/// <summary>One row of hr.usp_Employee_GetSwapCounterparts (QA3 WEB-2): the requester (IsRequester) or a colleague.</summary>
public class SwapCounterpartRow
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string Position { get; set; } = string.Empty;
    public string Branch { get; set; } = string.Empty;
    /// <summary>Set for a colleague who is leaving later (one who has already left is not listed).</summary>
    public DateTime? TerminationDate { get; set; }
    public bool IsRequester { get; set; }
}

/// <summary>
/// GET /api/employees/{id}/swap-counterparts — who the requester can swap a rostered day with: the active colleagues of
/// their branch in the same position. The requester comes along for the form's wording ("same role as …").
/// </summary>
public class SwapCounterparts
{
    public SwapCounterpartRow? Requester { get; set; }
    public List<SwapCounterpartRow> Counterparts { get; set; } = new();

    /// <summary>Splits the procedure's one result set: the requester row, then the colleagues in its order.</summary>
    public static SwapCounterparts From(IEnumerable<SwapCounterpartRow> rows)
    {
        var list = rows.ToList();
        return new SwapCounterparts
        {
            Requester = list.FirstOrDefault(r => r.IsRequester),
            Counterparts = list.Where(r => !r.IsRequester).ToList(),
        };
    }
}
