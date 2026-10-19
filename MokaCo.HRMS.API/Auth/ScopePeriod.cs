using System.Globalization;

namespace MokaCo.HRMS.Api.Auth;

/// <summary>The days a 'yyyy-MM' period covers, for asking what a caller may see in it (QA3 ATT-16).</summary>
public static class ScopePeriod
{
    /// <summary>First and last day of the month; (null, null) — any day — when the text is not a month.</summary>
    public static (DateTime? From, DateTime? To) Month(string? period)
        => DateTime.TryParseExact($"{period?.Trim()}-01", "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var first)
            ? (first, first.AddMonths(1).AddDays(-1))
            : (null, null);
}
