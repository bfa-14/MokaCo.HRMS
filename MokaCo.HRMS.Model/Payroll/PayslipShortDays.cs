namespace MokaCo.HRMS.Model.Payroll;

/// <summary>
/// GET /api/payroll/payslips/{id}/short-days (script 109): the days behind the payslip's "N day(s) short" line, by the
/// same rule as the line, as attendance stands now.
/// </summary>
public class PayslipShortDays
{
    /// <summary>False when the database lacks script 109: the page then shows the line without its days.</summary>
    public bool Available { get; set; } = true;
    public DateTime? CountedFrom { get; set; }
    public DateTime? CountedUpTo { get; set; }
    /// <summary>What the payslip line deducts, in days (null = the payslip has no short-days line).</summary>
    public decimal? LineQuantity { get; set; }
    /// <summary>The days listed, added up. Differs from LineQuantity only when attendance changed after the run was generated.</summary>
    public decimal TotalMissingDays { get; set; }
    public List<PayslipShortDay> Days { get; set; } = [];
}

public class PayslipShortDay
{
    public DateTime WorkDate { get; set; }
    public string Status { get; set; } = string.Empty;
    public DateTime? FirstInUtc { get; set; }
    public DateTime? LastOutUtc { get; set; }
    public int WorkedMinutes { get; set; }
    public int StandardMinutes { get; set; }
    public int ShortfallMinutes { get; set; }
    public int LateMinutes { get; set; }
    public decimal? DayFraction { get; set; }
    /// <summary>The part of a day this date deducts (1 = a whole day not worked).</summary>
    public decimal MissingDays { get; set; }
    public DateTime? CountedFrom { get; set; }
    public DateTime? CountedUpTo { get; set; }
    public decimal? LineQuantity { get; set; }
}
