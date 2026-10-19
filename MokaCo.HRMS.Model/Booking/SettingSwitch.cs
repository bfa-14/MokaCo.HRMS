namespace MokaCo.HRMS.Model.Booking;

/// <summary>
/// How a booking SWITCH in core.SETTING is read (BookingWebsiteEnabled, BookingDepositRequired).
///
/// TWO DIALECTS ARE STORED. Some rows hold '1'/'0', others 'true'/'false', and the Settings page keeps
/// the dialect a row already has but writes 'true'/'false' to a row that has none (SystemSettingRow).
/// A reader that knows only one dialect silently inverts the other: BookingDepositRequired = 'true'
/// read as off, BookingWebsiteEnabled = 'false' read as ON — the pause switch that did not pause.
/// Both readers here accept 1 / true / yes / on and 0 / false / no / off, in any case (QA3), the same
/// words the database's booking.fn_SettingIsOn accepts (docs/104_qa3_booking.sql).
/// </summary>
public static class SettingSwitch
{
    private static readonly string[] OnWords = ["1", "true", "yes", "on"];
    private static readonly string[] OffWords = ["0", "false", "no", "off"];

    /// <summary>True only for an explicit ON word. A missing, empty or unknown value is OFF.</summary>
    public static bool IsOn(string? value)
        => value is not null && OnWords.Contains(value.Trim(), StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// True only for an explicit OFF word — for a switch whose ABSENCE means on (BookingWebsiteEnabled:
    /// a missing row keeps online booking open, as it always has).
    /// </summary>
    public static bool IsOff(string? value)
        => value is not null && OffWords.Contains(value.Trim(), StringComparer.OrdinalIgnoreCase);
}
