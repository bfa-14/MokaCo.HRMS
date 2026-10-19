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

    /// <summary>The refusal for this value of this key, or null when it is acceptable.</summary>
    public static string? Problem(string key, string? value)
    {
        if (string.Equals(key, CarryOverExpiresOnKey, StringComparison.OrdinalIgnoreCase))
            return IsMonthDay(value)
                ? null
                : "The carry-over expiry date must be MM-DD, for example 03-31 (empty means carried days never expire).";

        return null;
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
