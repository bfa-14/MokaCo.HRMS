namespace MokaCo.HRMS.Model.Core;

/// <summary>
/// A public holiday (core.HOLIDAY, SQL 82). BranchId NULL = every branch.
///
/// A holiday changes what a day IS: the attendance rule writes it as Holiday (paid, never Absent), a leave
/// request does not spend a day on it, a roster copy keeps it, and working it earns the payslip line
/// "Holiday work". So writing one re-derives the attendance days it touches, and a holiday on a month that is
/// already paid is refused.
/// </summary>
public class Holiday
{
    public int HolidayId { get; set; }
    public DateTime HolidayDate { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? NameAr { get; set; }

    /// <summary>False = the day is a holiday (nobody is Absent) but it is not paid: payroll deducts it for whoever was rostered to work.</summary>
    public bool IsPaid { get; set; } = true;

    public int? BranchId { get; set; }
    public string? BranchName { get; set; }
    public DateTime CreatedAt { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? ModifiedAt { get; set; }
    public int? ModifiedBy { get; set; }
}

public class HolidayUpsertRequest
{
    /// <summary>yyyy-MM-dd. A calendar day: no time, no zone.</summary>
    public DateTime HolidayDate { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? NameAr { get; set; }
    public bool IsPaid { get; set; } = true;
    public int? BranchId { get; set; }
}
