using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Attendance;

/// <summary>Dapper access for shift definitions via the attendance.usp_Shift_* stored procedures.</summary>
public class ShiftRepository : IShiftRepository
{
    /// <summary>"Procedure has too many arguments specified": the procedure is the one from before script 117.</summary>
    private const int TooManyArguments = 8144;

    private readonly IDbConnectionFactory _factory;
    public ShiftRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<Shift>> GetAllAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<Shift>(
            "attendance.usp_Shift_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public Task<int> CreateAsync(string name, TimeSpan startTime, TimeSpan endTime, int? graceMinutes, bool crossesMidnight, int breakMinutes, int? callerUserId)
        => Guard("attendance.usp_Shift_Create", async () =>
        {
            using var db = _factory.Create();
            return await db.ExecuteScalarAsync<int>(
                "attendance.usp_Shift_Create",
                new
                {
                    Name = name,
                    StartTime = startTime,
                    EndTime = endTime,
                    GraceMinutes = graceMinutes,
                    CrossesMidnight = crossesMidnight,
                    BreakMinutes = breakMinutes,
                    CallerUserId = callerUserId,
                },
                commandType: CommandType.StoredProcedure);
        });

    public Task UpdateAsync(int shiftId, string name, TimeSpan startTime, TimeSpan endTime, int? graceMinutes, bool crossesMidnight, int breakMinutes, bool isActive,
        DateOnly? effectiveFrom, DateOnly? effectiveTo, string? note, int? callerUserId)
        => Guard("attendance.usp_Shift_Update", async () =>
        {
            using var db = _factory.Create();
            // A change that reaches back derives every day it touches again: give it time.
            await db.ExecuteAsync(
                "attendance.usp_Shift_Update",
                new
                {
                    ShiftId = shiftId,
                    Name = name,
                    StartTime = startTime,
                    EndTime = endTime,
                    GraceMinutes = graceMinutes,
                    CrossesMidnight = crossesMidnight,
                    BreakMinutes = breakMinutes,
                    IsActive = isActive,
                    EffectiveFrom = AsDate(effectiveFrom),
                    EffectiveTo = AsDate(effectiveTo),
                    Note = note,
                    CallerUserId = callerUserId,
                },
                commandType: CommandType.StoredProcedure,
                commandTimeout: 300);
            return true;
        });

    public Task<IEnumerable<ShiftHours>> GetHoursAsync(int shiftId)
        => Guard("attendance.usp_Shift_GetHours", async () =>
        {
            using var db = _factory.Create();
            return await db.QueryAsync<ShiftHours>(
                "attendance.usp_Shift_GetHours",
                new { ShiftId = shiftId },
                commandType: CommandType.StoredProcedure);
        });

    public Task<int> DeleteHoursAsync(int shiftHoursId, int? callerUserId)
        => Guard("attendance.usp_Shift_DeleteHours", async () =>
        {
            using var db = _factory.Create();
            return await db.ExecuteScalarAsync<int>(
                "attendance.usp_Shift_DeleteHours",
                new { ShiftHoursId = shiftHoursId, CallerUserId = callerUserId },
                commandType: CommandType.StoredProcedure,
                commandTimeout: 300);
        });

    public Task<int> SyncCurrentAsync()
        => Guard("attendance.usp_Shift_SyncCurrent", async () =>
        {
            using var db = _factory.Create();
            return await db.ExecuteScalarAsync<int>(
                "attendance.usp_Shift_SyncCurrent",
                commandType: CommandType.StoredProcedure);
        });

    private static DateTime? AsDate(DateOnly? date) => date?.ToDateTime(TimeOnly.MinValue);

    /// <summary>A database that lacks script 117 answers "no such procedure" or "too many arguments": both mean the script is missing.</summary>
    private static async Task<T> Guard<T>(string procedure, Func<Task<T>> call)
    {
        try
        {
            return await MissingScriptException.GuardAsync(Scripts.ShiftHours117, procedure, call);
        }
        catch (SqlException ex) when (ex.Number == TooManyArguments)
        {
            throw new MissingScriptException(Scripts.ShiftHours117, procedure, ex.Number, ex);
        }
    }
}
