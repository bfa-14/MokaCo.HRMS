namespace MokaCo.HRMS.Model.Core;

/// <summary>
/// Maps to core.SETTING — the SYSTEM's global key/value configuration, so a change of policy
/// needs no code deploy.
///
/// This is deliberately NOT an attendance type. Attendance was simply the first feature to need
/// configuration; payroll and workflow will add their own keys to the same table. Anything added
/// here appears on the Settings page automatically — the page renders whatever the API returns,
/// using <see cref="Description"/> as the explanation — so a new setting needs a row, not a
/// frontend change.
/// </summary>
public class Setting
{
    /// <summary>e.g. 'StandardWorkDayHours'. The primary key — settings are addressed by name, not id.</summary>
    public string SettingKey { get; set; } = string.Empty;

    /// <summary>
    /// Always stored as text; <see cref="DataType"/> says how to read it. SQL does the casting
    /// (TRY_CAST), so a value that will not parse falls back to a safe default rather than failing.
    /// </summary>
    public string SettingValue { get; set; } = string.Empty;

    /// <summary>bool / int / decimal / string — how <see cref="SettingValue"/> should be interpreted, and which control the UI renders.</summary>
    public string DataType { get; set; } = string.Empty;

    /// <summary>What this setting controls, in words. This IS the label the user reads, so it is not optional in practice.</summary>
    public string? Description { get; set; }

    public DateTime? ModifiedAt { get; set; }
    public int? ModifiedBy { get; set; }
}

/// <summary>Changes one setting. Some of these decide what people are PAID, which is why writing is owner-level.</summary>
public class SettingUpsertRequest
{
    public string SettingValue { get; set; } = string.Empty;
    public string DataType { get; set; } = "string";
    public string? Description { get; set; }
}

/// <summary>
/// The settings that change how the UI BEHAVES, readable by ANY signed-in user.
///
/// It exists because the full settings list is gated on SETTING_MANAGE, which HR deliberately does
/// not have — yet every user's screen needs to know whether the help panels are on. Without this,
/// an HR user could not read the flag governing their own page.
///
/// Only presentation-affecting, non-sensitive keys belong here. It must never become a way to read
/// the payroll policy values around the SETTING_MANAGE gate.
/// </summary>
public class UiSettings
{
    /// <summary>
    /// Show the "What is this page for?" panel at the top of each page.
    ///
    /// SYSTEM-WIDE, not per-user: there is no per-user preference store. So turning it off turns it
    /// off for everyone — including the next person who joins and has never seen these screens.
    /// Absent or unparseable means TRUE: failing open is right, because the cost of showing help
    /// nobody needed is a collapsed panel, and the cost of hiding it from somebody who needed it is
    /// that they get somebody's pay wrong.
    /// </summary>
    public bool ShowPageHelp { get; set; } = true;
}
