using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Attendance;

/// <summary>
/// Dapper access for corrections via attendance.usp_Correction_*. A correction captures the OLD and
/// the NEW values of a processed day; approving it applies the new ones and recomputes the day. The
/// raw punches are never touched, so "what the machine said" survives alongside "what HR decided".
/// </summary>
public class CorrectionRepository : ICorrectionRepository
{
    private readonly IDbConnectionFactory _factory;
    public CorrectionRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<int> CreateAsync(long attendanceId, int requestedBy, DateTime? newFirstInUtc, DateTime? newLastOutUtc, int? newExitMinutes, string? newStatus, string reason)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "attendance.usp_Correction_Create",
            new
            {
                AttendanceId = attendanceId,
                RequestedBy = requestedBy,
                NewFirstInUtc = newFirstInUtc,
                NewLastOutUtc = newLastOutUtc,
                NewExitMinutes = newExitMinutes,
                NewStatus = newStatus,
                Reason = reason
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Applies the new values, recomputes the day against the rostered shift, clears the anomaly and
    /// marks the record manual — which is what stops the next processor run from undoing the decision.
    /// </summary>
    public async Task<CorrectionApplyResult?> ApproveAsync(int correctionId, int approvedBy)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<CorrectionApplyResult>(
            "attendance.usp_Correction_Approve",
            new { CorrectionId = correctionId, ApprovedBy = approvedBy },
            commandType: CommandType.StoredProcedure);
    }

    public async Task RejectAsync(int correctionId, int approvedBy)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_Correction_Reject",
            new { CorrectionId = correctionId, ApprovedBy = approvedBy },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>The approval queue. A pending correction means the day's figures are about to change, so it blocks payroll.</summary>
    public async Task<IEnumerable<Correction>> GetPendingAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<Correction>(
            "attendance.usp_Correction_GetPending",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<Correction>> GetByRecordAsync(long attendanceId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<Correction>(
            "attendance.usp_Correction_GetByRecord",
            new { AttendanceId = attendanceId },
            commandType: CommandType.StoredProcedure);
    }
}
