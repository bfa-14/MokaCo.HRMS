using System.Data;
using System.Text.Json;
using Dapper;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

public interface IAvailabilityRepository
{
    /// <summary>
    /// Raises a standing availability change. Every refusal is the procedure's — a past effective
    /// date, a whole week marked unavailable, an employee who already has one waiting, an unknown
    /// shift — and each names its own cause, so none of them is re-checked or reworded here.
    /// </summary>
    Task<AvailabilityCreated?> CreateAsync(
        int employeeId, int raisedByUserId, DateTime effectiveFrom,
        IEnumerable<AvailabilityDay> days, string? reason, string? title);

    /// <summary>
    /// Decides, optionally restating the days. Null days = approve as asked. At final approval the
    /// procedure MERGEs the days into the weekly pattern exactly once, guarded on AppliedAt.
    /// </summary>
    Task<AvailabilityDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId,
        IEnumerable<AvailabilityDay>? days, string? comment, bool signedWithPassword);

    /// <summary>Header AND days — usp_Availability_GetPayload returns TWO result sets.</summary>
    Task<AvailabilityPayload> GetPayloadAsync(int requestInstanceId);

    /// <summary>Rostered days that contradict the change. Advisory: approving does not rewrite them.</summary>
    Task<IEnumerable<AvailabilityConflict>> GetConflictsAsync(int requestInstanceId);
}

/// <summary>
/// Dapper access for availability changes via workflow.usp_Availability_*.
///
/// The one thing this layer genuinely owns is the JSON: the days go to @DaysJson, and the procedures'
/// OPENJSON reads camelCase keys. Everything else — the validity of the dates, the one-in-flight
/// rule, the shift lookup, and the MERGE into the weekly pattern at final approval — belongs to the
/// procedures and is neither repeated nor pre-empted here.
/// </summary>
public class AvailabilityRepository : IAvailabilityRepository
{
    private readonly IDbConnectionFactory _factory;
    public AvailabilityRepository(IDbConnectionFactory factory) => _factory = factory;

    /// <summary>
    /// CAMEL CASE IS LOAD-BEARING. Both procedures read $.dayOfWeek / $.isAvailable / $.shiftId, so
    /// PascalCase names would parse to NULLs and be refused with "The days could not be read" — a
    /// message that would send somebody looking at their input rather than at this line. Declared
    /// once so create and decide cannot drift apart.
    /// </summary>
    private static readonly JsonSerializerOptions DaysJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    public async Task<AvailabilityCreated?> CreateAsync(
        int employeeId, int raisedByUserId, DateTime effectiveFrom,
        IEnumerable<AvailabilityDay> days, string? reason, string? title)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<AvailabilityCreated>(
            "workflow.usp_Availability_Create",
            new
            {
                EmployeeId = employeeId,
                RaisedByUserId = raisedByUserId,
                EffectiveFrom = effectiveFrom.Date,
                DaysJson = JsonSerializer.Serialize(days, DaysJson),
                Reason = reason,
                Title = title,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<AvailabilityDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId,
        IEnumerable<AvailabilityDay>? days, string? comment, bool signedWithPassword)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<AvailabilityDecisionResult>(
            "workflow.usp_Availability_Decide",
            new
            {
                RequestInstanceId = requestInstanceId,
                ActedByUserId = actedByUserId,
                // NULL, not "[]", when nothing is being restated: the procedure branches on
                // NULL-or-blank to mean "approve as asked", and an empty array would instead take the
                // restatement path and be refused with "The restatement has no days."
                DaysJson = days is null ? null : JsonSerializer.Serialize(days, DaysJson),
                Comment = comment,
                SignedWithPassword = signedWithPassword,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<AvailabilityPayload> GetPayloadAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        using var grid = await db.QueryMultipleAsync(
            "workflow.usp_Availability_GetPayload",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure);

        // TWO SETS, IN THE PROCEDURE'S ORDER: header then days. Each must be consumed before the
        // next, so these reads cannot be reordered or deferred.
        var header = await grid.ReadSingleOrDefaultAsync<AvailabilityHeader>();
        var days = (await grid.ReadAsync<AvailabilityPayloadDay>()).ToList();

        return new AvailabilityPayload(header, days);
    }

    public async Task<IEnumerable<AvailabilityConflict>> GetConflictsAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<AvailabilityConflict>(
            "workflow.usp_Availability_GetConflicts",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure);
    }
}
