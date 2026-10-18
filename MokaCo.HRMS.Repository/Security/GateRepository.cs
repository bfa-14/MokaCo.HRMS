using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Security;

/// <summary>
/// Dapper access for the Google sign-in gate (docs/97_google_signin_gate.sql). Every rule — who is
/// allowed, what a refusal says, the lock-out guard on blocking — lives in the procedures; this class
/// only passes parameters and reads the result sets in their fixed order.
/// </summary>
public class GateRepository : IGateRepository
{
    private readonly IDbConnectionFactory _factory;
    public GateRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<GateStateData> GetStateAsync()
    {
        using var db = _factory.Create();
        using var grid = await db.QueryMultipleAsync(
            "security.usp_Gate_GetState",
            commandType: CommandType.StoredProcedure);

        return new GateStateData
        {
            State = await grid.ReadSingleAsync<GateStateRow>(),
            Allowed = (await grid.ReadAsync<GateAllowedRow>()).AsList(),
        };
    }

    public async Task<GateSignInRow> SignInAsync(string email, string? googleSub, string? ip, string? userAgent)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<GateSignInRow>(
            "security.usp_Gate_SignIn",
            new { Email = email, GoogleSub = googleSub, Ip = ip, UserAgent = userAgent },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<GateAdminData> GetAdminAsync(int? callerUserId)
    {
        using var db = _factory.Create();
        using var grid = await db.QueryMultipleAsync(
            "security.usp_Gate_GetAdmin",
            new { CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);

        // The procedure's fixed order (§2). A grid reader only moves forward.
        return new GateAdminData
        {
            Settings = await grid.ReadSingleAsync<GateAdminSettings>(),        // 1
            People = (await grid.ReadAsync<GatePersonRow>()).AsList(),         // 2
            Extras = (await grid.ReadAsync<GateExtraEmailRow>()).AsList(),     // 3
            Recent = (await grid.ReadAsync<GateSignInLogRow>()).AsList(),      // 4
        };
    }

    public async Task SaveSettingsAsync(bool required, string? clientId, int days, int? callerUserId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "security.usp_Gate_SaveSettings",
            new { Required = required, ClientId = clientId, Days = days, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task SetBlockedAsync(int employeeId, bool blocked, int? callerUserId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "security.usp_Gate_SetBlocked",
            new { EmployeeId = employeeId, Blocked = blocked, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> SaveExtraEmailAsync(int? gateExtraEmailId, string? email, string? note, bool isActive, int? callerUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<int>(
            "security.usp_Gate_ExtraEmail_Save",
            new { GateExtraEmailId = gateExtraEmailId, Email = email, Note = note, IsActive = isActive, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteExtraEmailAsync(int gateExtraEmailId, int? callerUserId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "security.usp_Gate_ExtraEmail_Delete",
            new { GateExtraEmailId = gateExtraEmailId, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> SignOutEveryoneAsync(int? callerUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<int>(
            "security.usp_Gate_SignOutEveryone",
            new { CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
    }
}
