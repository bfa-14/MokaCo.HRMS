using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Repository.Common;
using MokaCo.HRMS.Services.Attendance.AutoRoster;
using MokaCo.HRMS.Services.Core;
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
    private readonly MissingScriptWarning? _missingScript;

    public AutoRosterService(IAutoRosterRepository repo, MissingScriptWarning? missingScript = null)
    {
        _repo = repo;
        _missingScript = missingScript;
    }

    public async Task<AutoRosterSetup> GetSetupAsync(int branchId, string? month, int? callerUserId)
    {
        if (branchId <= 0)
            throw new WorkflowException(400, "Choose a branch.");
        if (!RosterCalendar.TryParseMonth(month, out var monthStart))
            throw new WorkflowException(400, "The month must look like 2026-12.");

        var context = await ContextAsync(branchId, monthStart, callerUserId);
        var setup = AutoRosterSetupFactory.Create(context, monthStart);
        setup.Rotation = await GetRotationAsync(branchId, callerUserId);
        return setup;
    }

    public async Task<RosterRotationDto> GetRotationAsync(int branchId, int? callerUserId)
    {
        if (branchId <= 0)
            throw new WorkflowException(400, "Choose a branch.");
        return await WorkflowSqlErrors.MapAsync(() => _repo.GetRotationAsync(branchId, callerUserId));
    }

    /// <summary>The procedure owns every rule (a Monday, two active shifts, one L1 and one L2 at most, people of this branch).</summary>
    public async Task SaveRotationAsync(RosterRotationDto rotation, int? callerUserId)
    {
        if (rotation is null || rotation.BranchId <= 0)
            throw new WorkflowException(400, "Choose a branch.");
        rotation.Members ??= [];
        // The order of the list as sent is the order of the rotation: numbered here, so a client cannot send two people the same place.
        for (var i = 0; i < rotation.Members.Count; i++)
            rotation.Members[i].SortOrder = i + 1;

        await WorkflowSqlErrors.MapAsync(async () =>
        {
            await _repo.SaveRotationAsync(rotation, callerUserId);
            return true;
        });
    }

    /// <summary>
    /// What the leaders' read and save say while script 123 is not applied (the planner then keeps only the rotation's
    /// leads apart). A manager reads it in the drawer, so it is plain words; the script's name goes to the server's log.
    /// </summary>
    public const string LeadersNotAvailable =
        "The shift leaders list is not available yet. Ask your administrator to finish the update.";

    /// <summary>
    /// The same answer as a code beside the sentence, so the web can say it in the reader's language: a 503 alone could
    /// also be the database being too slow to answer.
    /// </summary>
    public const string LeadersNotAvailableCode = "leaders_not_ready";

    /// <summary>
    /// The code beside a save refused because somebody on the list is not one of the branch's people today (or has left
    /// the company): the web says it in the reader's language, with the person's name the sentence starts with.
    /// </summary>
    public const string LeaderNotInBranchCode = "leader_not_in_branch";

    /// <summary>How usp_AutoRoster_SaveLeaders ends that refusal; the person's name comes before it.</summary>
    private const string NotInBranchEnding = " is not in this branch: only its own people can be its shift leaders.";

    /// <summary>The person a leaders refusal names as not being in the branch; null for any other sentence.</summary>
    public static string? LeaderNotInBranch(string? message)
        => message is { Length: > 0 } && message.EndsWith(NotInBranchEnding, StringComparison.Ordinal)
               && message.Length > NotInBranchEnding.Length
            ? message[..^NotInBranchEnding.Length]
            : null;

    public async Task<RosterLeadersDto> GetLeadersAsync(int branchId, int? callerUserId)
    {
        if (branchId <= 0)
            throw new WorkflowException(400, "Choose a branch.");

        var rows = await LeadersCallAsync(() => _repo.GetLeadersAsync(branchId, callerUserId));
        var candidates = await LeadersCallAsync(() => _repo.GetLeaderCandidatesAsync(branchId, callerUserId));
        return new RosterLeadersDto
        {
            BranchId = branchId,
            EmployeeIds = rows.Where(r => r.IsStored).Select(r => r.EmployeeId).ToList(),
            Leaders = rows.ToList(),
            Candidates = (candidates ?? []).ToList(),
        };
    }

    /// <summary>The procedure owns the rules (people of this branch, the branch's scope); the list is sent once per person.</summary>
    public async Task SaveLeadersAsync(RosterLeadersDto leaders, int? callerUserId)
    {
        if (leaders is null || leaders.BranchId <= 0)
            throw new WorkflowException(400, "Choose a branch.");
        var ids = (leaders.EmployeeIds ?? []).Distinct().ToList();
        if (ids.Any(id => id <= 0))
            throw new WorkflowException(400, "Every line of the shift leaders list needs its employee.");

        await LeadersCallAsync(async () =>
        {
            await _repo.SaveLeadersAsync(leaders.BranchId, ids, callerUserId);
            return true;
        });
    }

    /// <summary>
    /// A leaders call: the procedures' sentences as their status, a missing script 123 as a 503 in plain words, and the
    /// one warning in the server's log that names the script to apply.
    /// </summary>
    private async Task<T> LeadersCallAsync<T>(Func<Task<T>> call)
    {
        try
        {
            return await WorkflowSqlErrors.MapAsync(call);
        }
        catch (MissingScriptException missing)
        {
            _missingScript?.FellBack(missing,
                "the shift leaders list answers 503 and the planner keeps only the rotation list's Lead 1 / Lead 2 apart");
            throw new WorkflowException(503, LeadersNotAvailable);
        }
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

        // The fixed rotation is read as STORED (never from the request): the preview and the commit that follows
        // it then plan and check by the same list. The other method reads it too: its Lead 1 and Lead 2 are the
        // branch's shift leaders, kept on different shifts whichever method plans.
        var rotation = await GetRotationAsync(request.BranchId, callerUserId);
        if (AutoRosterInputFactory.IsRotation(request)
            && AutoRosterInputFactory.RotationProblem(rotation, context) is { } rotationProblem)
            throw new WorkflowException(400, rotationProblem);
        return AutoRosterInputFactory.Create(context, request, rotation);
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
