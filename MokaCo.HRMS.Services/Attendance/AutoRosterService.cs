using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.Attendance;

/// <summary>
/// The auto-roster around the pure planner (Services/Attendance/AutoRoster): read the context, plan
/// or validate, and save through the one procedure. The planner never touches the database and the
/// database never plans; this class is the seam between them.
///
/// Every call to a procedure goes through <see cref="WorkflowSqlErrors.MapAsync{T}"/> — the reads
/// included, unlike RosterService: the context read refuses a branch the caller does not manage, and
/// that has to arrive as a 403 with its sentence, not as a 500.
/// </summary>
public class AutoRosterService : IAutoRosterService
{
    private readonly IAutoRosterRepository _repo;
    public AutoRosterService(IAutoRosterRepository repo) => _repo = repo;

    public async Task<AutoRosterSetup> GetSetupAsync(int branchId, string? month, int? callerUserId)
    {
        if (branchId <= 0)
            throw new WorkflowException(400, "Choose a branch.");
        if (!RosterCalendar.TryParseMonth(month, out var monthStart))
            throw new WorkflowException(400, "The month must look like 2026-12.");

        var context = await ContextAsync(branchId, monthStart, callerUserId);
        return AutoRosterSetupFactory.Create(context, monthStart);
    }

    public async Task<AutoRosterPreview> PreviewAsync(AutoRosterRequest request, int? callerUserId)
        => RosterPlanner.Preview(await InputAsync(request, callerUserId));

    /// <summary>
    /// What is written is exactly the submitted cells — the server does not re-plan over the
    /// manager's edits. But it does not trust them either: the context is read again NOW, the cells
    /// are laid over the rows as they stand, and the §2.7 rules run on the result (the same validator
    /// as the preview, so the two cannot disagree about what is an error). The procedure then checks
    /// each cell's expected row under lock, which covers anything that moves after this read.
    /// </summary>
    public async Task<AutoRosterCommitResult> CommitAsync(AutoRosterCommitRequest request, int? callerUserId)
    {
        var input = await InputAsync(request, callerUserId);
        var issues = RosterPlanValidator.ValidateSubmission(input, request.Cells, request.Rhythm);
        if (RosterPlanValidator.HasErrors(issues))
            throw new AutoRosterRefusedException(RefusalSentence(issues), issues);

        // The mode as parsed, so the run row says "ReplanAuto" however the client spelled it.
        return await WorkflowSqlErrors.MapAsync(() => _repo.CommitAsync(
            input.BranchId, input.MonthStart, input.Mode.ToString(), request.Cells, request.Rhythm,
            AutoRosterSetupFactory.SerializeParams(request), issues.Count, callerUserId));
    }

    public async Task<IEnumerable<RosterCellInfo>> GetCellsAsync(int branchId, DateOnly from, DateOnly to, int? callerUserId)
    {
        if (branchId <= 0)
            throw new WorkflowException(400, "Choose a branch.");
        if (from > to)
            throw new WorkflowException(400, "'from' must be on or before 'to'.");

        return await WorkflowSqlErrors.MapAsync(() => _repo.GetCellsAsync(branchId, from, to, callerUserId));
    }

    public async Task SetPinAsync(RosterPinRequest request, int? callerUserId)
    {
        if (request is null || request.EmployeeId <= 0)
            throw new WorkflowException(400, "Choose the employee and the day.");

        await WorkflowSqlErrors.MapAsync(async () =>
        {
            await _repo.SetPinAsync(request.EmployeeId, request.WorkDate, request.IsPinned, callerUserId);
            return true;
        });
    }

    public async Task<IEnumerable<StaffingRequirementDto>> GetStaffingAsync(int branchId, int? callerUserId)
    {
        if (branchId <= 0)
            throw new WorkflowException(400, "Choose a branch.");

        return await WorkflowSqlErrors.MapAsync(() => _repo.GetStaffingAsync(branchId, callerUserId));
    }

    /// <summary>Replaces the branch's whole set — an empty list clears it. The procedure owns every rule.</summary>
    public async Task SaveStaffingAsync(int branchId, IEnumerable<StaffingRequirementDto> rows, int? callerUserId)
    {
        if (branchId <= 0)
            throw new WorkflowException(400, "Choose a branch.");
        if (rows is null)
            throw new WorkflowException(400, "Send the staffing rows (an empty list clears them).");

        var list = rows.ToList();
        await WorkflowSqlErrors.MapAsync(async () =>
        {
            await _repo.SaveStaffingAsync(branchId, list, callerUserId);
            return true;
        });
    }

    public async Task SaveRhythmAsync(IEnumerable<RosterRhythmDto> rows, int? callerUserId)
    {
        if (rows is null)
            throw new WorkflowException(400, "Send the rhythm rows.");

        var list = rows.ToList();
        await WorkflowSqlErrors.MapAsync(async () =>
        {
            await _repo.SaveRhythmAsync(list, callerUserId);
            return true;
        });
    }

    /* ---- the shared read ---- */

    /// <summary>
    /// The request checked, then the context read and folded into the planner's input. The check comes
    /// first so a typo never costs the database round trip — the context read is the heaviest call
    /// the auto-roster makes.
    /// </summary>
    private async Task<PlannerInput> InputAsync(AutoRosterRequest request, int? callerUserId)
    {
        Normalize(request);
        if (AutoRosterInputFactory.Problem(request) is { } problem)
            throw new WorkflowException(400, problem);

        RosterCalendar.TryParseMonth(request.Month, out var monthStart);
        var context = await ContextAsync(request.BranchId, monthStart, callerUserId);
        return AutoRosterInputFactory.Create(context, request);
    }

    /// <summary>Lookback NULL: the procedure uses the RosterFairnessLookbackWeeks setting.</summary>
    private Task<AutoRosterContext> ContextAsync(int branchId, DateOnly monthStart, int? callerUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.GetContextAsync(branchId, monthStart, null, callerUserId));

    /// <summary>
    /// A JSON body may say "draftCells": null where the model has an empty list; the planner reads the
    /// lists without asking. OffRotationEmployeeIds is left alone: there, null MEANS "as stored".
    /// </summary>
    private static void Normalize(AutoRosterRequest? request)
    {
        if (request is null)
            return;
        request.HolidayCover ??= [];
        request.RhythmOverrides ??= [];
        request.DraftCells ??= [];
        if (request is AutoRosterCommitRequest commit)
        {
            commit.Cells ??= [];
            commit.Rhythm ??= [];
        }
    }

    /// <summary>One sentence for the 400; the issues travel beside it for the cells.</summary>
    private static string RefusalSentence(IReadOnlyList<AutoRosterIssue> issues)
    {
        var errors = issues.Where(i => i.Severity == RosterPlanValidator.Error).ToList();
        return errors.Count == 1
            ? $"The draft was not saved. {errors[0].Message}"
            : $"The draft was not saved: {errors.Count} errors. The first: {errors[0].Message}";
    }
}
