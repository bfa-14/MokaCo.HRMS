using System.Globalization;

namespace MokaCo.HRMS.Services.Core;

/// <summary>
/// Settings whose value has a FORMAT the code depends on. A value the reader cannot parse is not a typo
/// but a switched-off rule: LeaveCarryOverExpiresOn = "31/03" made the carry-over expiry expire nothing,
/// silently (QA3, LEV-6). Refused at the door with a sentence instead.
/// </summary>
public static class SettingValueRules
{
    public const string CarryOverExpiresOnKey = "LeaveCarryOverExpiresOn";

    /// <summary>
    /// The month (yyyy-MM) from which an undecided day that is not on the roster blocks payroll (script 108).
    /// attendance.fn_PayrollReadiness reads an unreadable value as "never blocks": a typo would switch the
    /// gate off without a word.
    /// </summary>
    public const string OffRosterBlocksPayrollFromKey = "OffRosterBlocksPayrollFrom";

    /// <summary>The refusal for this value of this key, or null when it is acceptable.</summary>
    public static string? Problem(string key, string? value)
    {
        if (string.Equals(key, CarryOverExpiresOnKey, StringComparison.OrdinalIgnoreCase))
            return IsMonthDay(value)
                ? null
                : "The carry-over expiry date must be MM-DD, for example 03-31 (empty means carried days never expire).";

        if (string.Equals(key, OffRosterBlocksPayrollFromKey, StringComparison.OrdinalIgnoreCase))
            return IsYearMonth(value)
                ? null
                : "The month must be yyyy-MM, for example 2026-12 (empty means such days never block payroll).";

        return null;
    }

    /// <summary>Empty, or yyyy-MM naming a real month of a year from 2000 on.</summary>
    private static bool IsYearMonth(string? value)
    {
        var text = value?.Trim() ?? string.Empty;
        if (text.Length == 0)
            return true;
        if (text.Length != 7 || text[4] != '-')
            return false;
        return int.TryParse(text.AsSpan(0, 4), NumberStyles.None, CultureInfo.InvariantCulture, out var year)
               && int.TryParse(text.AsSpan(5, 2), NumberStyles.None, CultureInfo.InvariantCulture, out var month)
               && year is >= 2000 and <= 9999 && month is >= 1 and <= 12;
    }

    /// <summary>Empty, or MM-DD naming a real day of the year; 02-29 counts (it means the last day of February).</summary>
    private static bool IsMonthDay(string? value)
    {
        var text = value?.Trim() ?? string.Empty;
        if (text.Length == 0)
            return true;
        if (text.Length != 5 || text[2] != '-')
            return false;
        if (!int.TryParse(text.AsSpan(0, 2), NumberStyles.None, CultureInfo.InvariantCulture, out var month)
            || !int.TryParse(text.AsSpan(3, 2), NumberStyles.None, CultureInfo.InvariantCulture, out var day))
            return false;
        return month is >= 1 and <= 12 && day >= 1 && day <= DateTime.DaysInMonth(2024, month);   // 2024: a leap year
    }
}
