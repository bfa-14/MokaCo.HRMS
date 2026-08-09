using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Repository.Workflow;

public interface ITipDistributionRepository
{
    /// <summary>
    /// Raises a tip distribution. Participant ids are joined with commas for the procedure, which
    /// splits, de-duplicates and validates them against the branch itself.
    /// </summary>
    Task<TipDistributionCreated?> CreateAsync(
        int raisedByUserId, int branchId, DateTime shiftDate,
        IEnumerable<TipAmount> amounts, IEnumerable<int> participantIds, string? title);

    /// <summary>
    /// Approves; at final approval the procedure stamps FinalizedAt so payroll can consume the lines.
    ///
    /// `lines` RESTATES THE WHOLE SPLIT and is a full replacement set — null means "as calculated".
    /// The procedure validates it against the pool before the engine is called and rewrites the lines
    /// only after every refusal has passed, so a rejected redistribution leaves the old split intact.
    /// </summary>
    Task<TipDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId,
        IEnumerable<TipLineInput>? lines, string? comment, bool signedWithPassword);

    /// <summary>Header, per-currency amounts AND lines — usp_TipDistribution_GetPayload returns THREE result sets.</summary>
    Task<TipDistributionPayload> GetPayloadAsync(int requestInstanceId);
}

public interface IShiftSwapRepository
{
    Task<ShiftSwapCreated?> CreateAsync(
        int employeeId, int raisedByUserId, int counterpartEmployeeId,
        DateTime requesterDate, DateTime counterpartDate, bool counterpartHasAgreed, string? title);

    /// <summary>Approves; at final approval the procedure REWRITES THE ROSTER and stamps AppliedAt.</summary>
    Task<TypedDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, string? comment, bool signedWithPassword);

    Task<ShiftSwapPayload?> GetPayloadAsync(int requestInstanceId);
}
