namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// The pre-flight check for a payroll run. Payroll reads attendance, so if attendance is
/// incomplete, pay is WRONG — and wrong quietly, which is worse. Each counter below is a specific
/// way the month can still be lying to you. The API should BLOCK the payroll run while
/// <see cref="IsReady"/> is false.
/// </summary>
public class PayrollReadiness
{
    public string PeriodYearMonth { get; set; } = string.Empty;
    public DateTime PeriodStart { get; set; }
    public DateTime PeriodEnd { get; set; }

    /// <summary>Punches sitting in the raw log that nobody has processed — the days they belong to are missing entirely.</summary>
    public int UnprocessedPunches { get; set; }

    /// <summary>Punches on a PIN nobody is enrolled on. That person's days are missing, and they will notice on payday.</summary>
    public int UnresolvedPinPunches { get; set; }

    /// <summary>Days the machine could not read confidently (usually a missing punch-out) — the hours on them are not trustworthy.</summary>
    public int OpenAnomalies { get; set; }

    /// <summary>Corrections awaiting approval. The figures are about to change, so paying now pays the old ones.</summary>
    public int PendingCorrections { get; set; }

    /// <summary>Employee-days that were rostered but produced no record at all — nothing to pay or deduct against.</summary>
    public int RosteredDaysWithNoRecord { get; set; }

    /// <summary>Exit variances HR has not ruled on. Until someone says unpaid / offset / ignore, payroll does not know what to do with the time.</summary>
    public int UndecidedExitVariances { get; set; }

    /// <summary>Late arrivals, early departures and missing punches HR has not decided (script 77). Until each is excused, deducted or corrected, payroll does not know what the day is worth.</summary>
    public int UndecidedAnomalies { get; set; }

    /// <summary>True only when every counter is zero. Anything else means the month is not safe to pay.</summary>
    public bool IsReady { get; set; }
}

/// <summary>
/// The monthly numbers payroll turns into pay lines, for one employee. The rules for what to DO
/// with them live in payroll, not here — this class only states what happened.
/// </summary>
public class AttendanceSummary
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string PeriodYearMonth { get; set; } = string.Empty;

    /// <summary>Feeds the late-deduction line.</summary>
    public int TotalLateMinutes { get; set; }

    /// <summary>DETECTED overtime. NOT automatically payable — pay only what an approved overtime request authorises.</summary>
    public int TotalOvertimeMinutes { get; set; }

    public int TotalWorkedMinutes { get; set; }
    public int TotalShortfallMinutes { get; set; }

    /// <summary>FRACTIONAL days actually worked — someone who left two hours early contributes 0.75, not 1.</summary>
    public decimal DaysWorked { get; set; }

    public int FullDaysWorked { get; set; }
    public int PartialDays { get; set; }
    public int PresentDays { get; set; }
    public int AbsentDays { get; set; }
    public int RestDays { get; set; }
    public int LeaveDays { get; set; }

    public int ExitActualMinutes { get; set; }
    public int ExitApprovedMinutes { get; set; }
    public int ExitLeaveMinutes { get; set; }

    /// <summary>Leave days to draw from the balance for short exits (default: from the ACTUAL minutes taken).</summary>
    public decimal ExitLeaveDays { get; set; }

    /// <summary>Variance HR ruled 'UnpaidAbsence' — payroll deducts this.</summary>
    public int ExitUnpaidMinutes { get; set; }

    /// <summary>Variance HR ruled 'Overtime' — offset against time already worked, so it costs nothing extra.</summary>
    public int ExitOffsetMinutes { get; set; }

    public decimal ApprovedLeaveDays { get; set; }

    /// <summary>Absences NOT covered by approved leave. This is the deduction.</summary>
    public decimal UnpaidAbsenceDays { get; set; }
}

/// <summary>Per-branch split of a month, for staff who work across several sites.</summary>
public class AttendanceBranchSummary
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public int? BranchId { get; set; }
    public string? BranchName { get; set; }
    public int Days { get; set; }
    public decimal DaysWorked { get; set; }
    public int WorkedMinutes { get; set; }
    public int OvertimeMinutes { get; set; }
}

/// <summary>How many employee-days the processor built. Zero is normal when there is nothing new to consume.</summary>
public class ProcessResult
{
    public int EmployeeDaysProcessed { get; set; }
}

/// <summary>How many rostered-but-punchless days were written as Absent/RestDay.</summary>
public class MarkAbsenteesResult
{
    public int AbsenteesMarked { get; set; }
}

/// <summary>How many Absent days were reclassified as approved Leave, so they are not deducted twice.</summary>
public class MarkLeaveDaysResult
{
    public int DaysMarkedAsLeave { get; set; }
}
