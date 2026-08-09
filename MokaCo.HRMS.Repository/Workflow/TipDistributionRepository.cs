using System.Data;
using System.Text.Json;
using Dapper;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

/// <summary>
/// Dapper access for tip distributions. Every rule belongs to workflow.usp_TipDistribution_*: the
/// positive amounts, the known and non-duplicated currencies, the participants all belonging to the
/// chosen branch, and the per-currency split whose last participant absorbs each remainder.
/// </summary>
public class TipDistributionRepository : ITipDistributionRepository
{
    private readonly IDbConnectionFactory _factory;
    public TipDistributionRepository(IDbConnectionFactory factory) => _factory = factory;

    /// <summary>
    /// CAMEL CASE IS LOAD-BEARING. The procedures' OPENJSON reads $.currencyCode / $.amount on the
    /// pool and $.employeeId / $.currencyCode / $.amount on a restated split, so PascalCase property
    /// names would parse to NULLs and be refused with "The amounts could not be read" / "The
    /// redistribution could not be read". Declared once here rather than inline, so BOTH payloads
    /// serialize identically.
    /// </summary>
    private static readonly JsonSerializerOptions AmountsJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    /// <summary>
    /// The AMOUNTS result set names its column <c>TotalAmount</c>, not <c>Amount</c>.
    ///
    /// This row type exists so Dapper has a property that actually matches it. Reading that set
    /// straight into <see cref="TipAmount"/> compiles and runs and quietly returns 0.00 for every
    /// currency — there is simply nothing for TotalAmount to bind to. Read here, projected below.
    /// </summary>
    private sealed record TipAmountRow(string CurrencyCode, decimal TotalAmount);

    public async Task<TipDistributionCreated?> CreateAsync(
        int raisedByUserId, int branchId, DateTime shiftDate,
        IEnumerable<TipAmount> amounts, IEnumerable<int> participantIds, string? title)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<TipDistributionCreated>(
            "workflow.usp_TipDistribution_Create",
            new
            {
                RaisedByUserId = raisedByUserId,
                BranchId = branchId,
                ShiftDate = shiftDate.Date,
                // One object per currency. The procedure validates the list; an empty array simply
                // produces "At least one currency amount is required."
                AmountsJson = JsonSerializer.Serialize(amounts, AmountsJson),
                // The procedure does its own STRING_SPLIT, so the only job here is the join.
                ParticipantIds = string.Join(",", participantIds),
                Title = title,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<TipDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId,
        IEnumerable<TipLineInput>? lines, string? comment, bool signedWithPassword)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<TipDecisionResult>(
            "workflow.usp_TipDistribution_Decide",
            new
            {
                RequestInstanceId = requestInstanceId,
                ActedByUserId = actedByUserId,
                // NULL, not "[]", when nothing is being restated. The procedure branches on NULL-or-
                // blank to mean "approve as calculated"; an empty array would instead take the
                // redistribution path and be refused with "The redistribution has no lines."
                LinesJson = lines is null ? null : JsonSerializer.Serialize(lines, AmountsJson),
                Comment = comment,
                SignedWithPassword = signedWithPassword,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<TipDistributionPayload> GetPayloadAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        using var grid = await db.QueryMultipleAsync(
            "workflow.usp_TipDistribution_GetPayload",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure);

        // THREE SETS, IN THE PROCEDURE'S ORDER: header, amounts, lines. Each grid must be consumed
        // before the next, so these reads cannot be reordered or deferred.
        var header = await grid.ReadSingleOrDefaultAsync<TipDistributionHeader>();
        var amounts = (await grid.ReadAsync<TipAmountRow>())
            .Select(a => new TipAmount(a.CurrencyCode, a.TotalAmount))
            .ToList();
        var lines = (await grid.ReadAsync<TipDistributionLine>()).ToList();

        return new TipDistributionPayload(header, amounts, lines);
    }
}
