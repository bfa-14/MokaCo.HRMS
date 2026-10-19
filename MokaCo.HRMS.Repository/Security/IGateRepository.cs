using MokaCo.HRMS.Model.Security;

namespace MokaCo.HRMS.Repository.Security;

/// <summary>
/// The Google sign-in gate's procedures (docs/97_google_signin_gate.sql, spec docs/GOOGLE_SIGNIN_GATE.md
/// §2). The caller is the last parameter of every admin procedure; refusals are RAISERROR sentences,
/// which the service maps to a status.
/// </summary>
public interface IGateRepository
{
    /// <summary>security.usp_Gate_GetState — the four settings and everyone allowed right now.</summary>
    Task<GateStateData> GetStateAsync();

    /// <summary>
    /// security.usp_Gate_SignIn — decides the outcome for a verified Google email, writes one log row
    /// and prunes the log. Called whether the gate is on or off ("Test Google sign-in").
    /// </summary>
    Task<GateSignInRow> SignInAsync(string email, string? googleSub, string? ip, string? userAgent);

    /// <summary>security.usp_Gate_GetAdmin — settings, people, extra addresses and the recent log, in that order.</summary>
    Task<GateAdminData> GetAdminAsync(int? callerUserId);

    /// <summary>security.usp_Gate_SaveSettings — the switch, the client ID and the days. No result set.</summary>
    Task SaveSettingsAsync(bool required, string? clientId, int days, int? callerUserId);

    /// <summary>security.usp_Gate_SetBlocked — refuses blocking the caller's own employee.</summary>
    Task SetBlockedAsync(int employeeId, bool blocked, int? callerUserId);

    /// <summary>security.usp_Gate_ExtraEmail_Save — inserts when the id is NULL, else updates. Returns the row's id.</summary>
    Task<int> SaveExtraEmailAsync(int? gateExtraEmailId, string? email, string? note, bool isActive, int? callerUserId);

    /// <summary>security.usp_Gate_ExtraEmail_Delete.</summary>
    Task DeleteExtraEmailAsync(int gateExtraEmailId, int? callerUserId);

    /// <summary>security.usp_Gate_SignOutEveryone — moves the epoch on by one and returns the new one.</summary>
    Task<int> SignOutEveryoneAsync(int? callerUserId);
}
