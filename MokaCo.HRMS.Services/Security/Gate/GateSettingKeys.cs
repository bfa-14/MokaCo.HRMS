using System.Text.RegularExpressions;

namespace MokaCo.HRMS.Services.Security.Gate;

/// <summary>
/// The gate's four rows in core.SETTING (Section "Security"). They are written ONLY through
/// PUT api/access/settings and usp_Gate_SignOutEveryone, which carry the no-lock-out guard; the
/// generic PUT api/settings/{key} refuses them (docs/GOOGLE_SIGNIN_GATE.md G5).
/// </summary>
public static partial class GateSettingKeys
{
    public const string Required = "GoogleSignInRequired";
    public const string ClientId = "GoogleClientId";
    public const string Days = "GoogleSignInDays";
    public const string Epoch = "GoogleSignInEpoch";

    public static readonly IReadOnlyList<string> All = [Required, ClientId, Days, Epoch];

    /// <summary>
    /// A setting key as every row has one: English letters, digits, '.', '_' or '-', at most 60 — the
    /// width of core.usp_Setting_Upsert's VARCHAR(60) @SettingKey. \z, not $: $ also matches before a
    /// final newline.
    /// </summary>
    public static bool IsPlainKey(string? key) => key is not null && PlainKey().IsMatch(key);

    /// <summary>
    /// Could this key reach one of the four rows? SQL Server does not see the key C# sees: it arrives in
    /// a VARCHAR(60), so a look-alike letter (İ, ĩ, ō, full-width Ｇ) best-fits to its plain letter,
    /// anything past 60 characters is cut off, trailing spaces do not count, and the collation ignores
    /// case. So a key that is not plain (<see cref="IsPlainKey"/>) counts as one of them, and a plain one
    /// is compared ignoring case.
    /// </summary>
    public static bool IsGateKey(string? key)
    {
        if (string.IsNullOrEmpty(key))
            return false;

        return !IsPlainKey(key) || All.Any(gateKey => string.Equals(gateKey, key, StringComparison.OrdinalIgnoreCase));
    }

    [GeneratedRegex(@"^[A-Za-z0-9_.-]{1,60}\z")]
    private static partial Regex PlainKey();
}
