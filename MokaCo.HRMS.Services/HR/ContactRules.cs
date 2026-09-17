using System.Net.Mail;
using System.Text.RegularExpressions;

namespace MokaCo.HRMS.Services.HR;

/// <summary>
/// The contact-field rules for an employee record, in one place so the create path, the update
/// path and the tests agree.
///
/// PHONE: the Lebanese rule the booking modal expects — a local number of 8 digits (03 123 456,
/// 71 234 567, 01 234 567) or the international form +961 / 00961 followed by the national number
/// (with or without its leading 0). Spaces, dashes, dots and brackets are formatting and ignored.
/// Stored NORMALISED as E.164: "+961" + national number without the leading 0, e.g. +9613123456,
/// +96171234567 — so two spellings of one phone cannot become two different values.
///
/// E-MAIL: a syntactically valid address (System.Net.Mail's parser), trimmed. Not lower-cased: the
/// local part is case-sensitive by RFC and this is the address the SYSTEM sends to.
/// </summary>
public static partial class ContactRules
{
    public const string RequiredMessage = "Phone number and e-mail are required for a new employee.";
    public const string InvalidEmailMessage = "Enter a valid e-mail address.";
    public const string InvalidPhoneMessage =
        "Enter a Lebanese phone number: 8 digits (e.g. 03 123 456) or +961 followed by the number.";

    /// <summary>
    /// Returns the E.164 form ("+961…") for a valid Lebanese number, or null when the input is
    /// blank or not a Lebanese number.
    /// </summary>
    public static string? NormalisePhone(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;

        // keep digits and a leading '+' only
        var trimmed = raw.Trim();
        var plus = trimmed.StartsWith('+');
        var digits = DigitsOnly().Replace(trimmed, "");
        if (digits.Length == 0) return null;

        string national;
        if (plus)
        {
            if (!digits.StartsWith("961")) return null;
            national = digits[3..];
        }
        else if (digits.StartsWith("00961"))
        {
            national = digits[5..];
        }
        else if (digits.Length == 8)
        {
            // local dialling: 8 digits
            national = digits;
        }
        else if (digits.StartsWith("961") && digits.Length is 10 or 11)
        {
            // "961 3 123 456" typed without the plus
            national = digits[3..];
        }
        else
        {
            return null;
        }

        // the national number is 7 digits (after dropping a local leading 0) or 8 digits (7x/8x mobiles)
        if (national.Length == 8 && national[0] == '0') national = national[1..];
        if (national.Length is not (7 or 8)) return null;
        if (national[0] == '0') return null;

        return "+961" + national;
    }

    /// <summary>True for a syntactically valid single address. Blank is not valid.</summary>
    public static bool IsValidEmail(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return false;
        var value = raw.Trim();
        if (value.Contains(' ') || !value.Contains('@')) return false;
        try
        {
            var parsed = new MailAddress(value);
            // MailAddress accepts "Name <a@b>"; only the bare address is an e-mail here.
            return string.Equals(parsed.Address, value, StringComparison.Ordinal)
                && parsed.Host.Contains('.');
        }
        catch (FormatException)
        {
            return false;
        }
    }

    [GeneratedRegex(@"[^0-9]")]
    private static partial Regex DigitsOnly();
}
