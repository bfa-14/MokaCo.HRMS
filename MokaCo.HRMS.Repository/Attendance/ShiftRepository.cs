using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Attendance;

/// <summary>Dapper access for shift definitions via the attendance.usp_Shift_* stored procedures.</summary>
public class ShiftRepository : IShiftRepository
{
    private readonly IDbConnectionFactory _factory;
    public ShiftRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<Shift>> GetAllAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<Shift>(
            "attendance.usp_Shift_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(string name, TimeSpan startTime, TimeSpan endTime, int? graceMinutes, bool crossesMidnight, int breakMinutes)
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
                BreakMinutes = breakMinutes
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task UpdateAsync(int shiftId, string name, TimeSpan startTime, TimeSpan endTime, int? graceMinutes, bool crossesMidnight, int breakMinutes, bool isActive)
    {
        using var db = _factory.Create();
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
                IsActive = isActive
            },
            commandType: CommandType.StoredProcedure);
    }
}
