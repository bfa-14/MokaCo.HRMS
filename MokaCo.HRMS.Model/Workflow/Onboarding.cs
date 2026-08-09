namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// Raise an onboarding — a hire, from the decision to the paperwork.
///
/// THERE IS NO EmployeeId. The candidate is not an employee yet; that record is created BY this
/// request, when the hire decision is approved. The engine still needs a subject, so the procedure
/// uses the RAISER's employee record — which is why a login with no employee behind it is refused.
/// </summary>
public sealed class OnboardingCreateRequest
{
    public string CandidateName { get; set; } = string.Empty;

    public int BranchId { get; set; }
    public int DepartmentId { get; set; }
    public int PositionId { get; set; }

    /// <summary>The first day. Becomes HireDate on the employee record the approval creates.</summary>
    public DateTime StartDate { get; set; }

    /* The paperwork figures, all optional at submit: they are usually collected DURING onboarding,
       which is what the checklist tracks. NationalId and NssfNumber are carried onto the employee
       record when it is created; the other two are held here for HR to work from. */
    public string? NationalId { get; set; }
    public string? NssfNumber { get; set; }
    public string? TaxNumber { get; set; }
    public string? BankAccount { get; set; }

    public string? Notes { get; set; }

    /// <summary>Optional override. Left blank the PROCEDURE composes the title, so its format lives in one place.</summary>
    public string? Title { get; set; }
}

/// <summary>
/// What raising an onboarding produced.
///
/// <see cref="TaskCount"/> is the checklist COPIED FROM THE TEMPLATE as it stood at submit — a
/// snapshot, not a link. Editing the template later does not reach back into requests already in
/// flight, which is what stops a hire's requirements changing under the person doing the work.
/// </summary>
public sealed class OnboardingCreated
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    public int OnboardingId { get; set; }
    public int TaskCount { get; set; }
}

/// <summary>
/// One checklist item.
///
/// NOTE ON <see cref="SortOrder"/>: usp_Onboarding_GetPayload returns it, usp_Onboarding_SetTask does
/// NOT — that procedure orders its rows by it but does not select it, so on a set-task response the
/// value is 0 on every row. Both lists arrive ALREADY IN ORDER, so callers must render them in array
/// order and never sort by this field, or a checklist would collapse into template order after a tick.
/// </summary>
public sealed class OnboardingTask
{
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;

    /// <summary>The last approval is REFUSED while any required item is undone.</summary>
    public bool IsRequired { get; set; }

    public int SortOrder { get; set; }

    /// <summary>Null while undone. Ticking stamps it; unticking clears it back to null.</summary>
    public DateTime? CompletedAt { get; set; }

    /// <summary>Who ticked it. Null while undone.</summary>
    public string? CompletedBy { get; set; }

    public string? Note { get; set; }
}

/// <summary>The onboarding header (first result set of usp_Onboarding_GetPayload).</summary>
public sealed class OnboardingHeader
{
    public int OnboardingId { get; set; }
    public string CandidateName { get; set; } = string.Empty;
    public DateTime StartDate { get; set; }

    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public int DepartmentId { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
    public int PositionId { get; set; }
    public string PositionTitle { get; set; } = string.Empty;

    public string? NationalId { get; set; }
    public string? NssfNumber { get; set; }
    public string? TaxNumber { get; set; }
    public string? BankAccount { get; set; }
    public string? Notes { get; set; }

    /// <summary>The employee this hire created. Null until the hire decision is approved.</summary>
    public int? CreatedEmployeeId { get; set; }
    public DateTime? EmployeeCreatedAt { get; set; }

    public int TaskCount { get; set; }
    public int TasksDone { get; set; }

    /// <summary>Required items still undone. While this is above zero the LAST approval is refused.</summary>
    public int OutstandingRequired { get; set; }
}

/// <summary>Both result sets together — the shape the checklist panel renders.</summary>
public sealed record OnboardingPayload(
    OnboardingHeader? Header,
    IReadOnlyList<OnboardingTask> Tasks);

/// <summary>A decision on an onboarding. No figure to adjust — the checklist is the substance.</summary>
public sealed class OnboardingDecideRequest
{
    public string? Comment { get; set; }

    /// <summary>Verified against the stored Argon2id hash BEFORE anything is written. Never logged or echoed.</summary>
    public string? Password { get; set; }
}

/// <summary>
/// What an onboarding decision returned.
///
/// TWO THINGS HAPPEN HERE THAT HAPPEN NOWHERE ELSE. The first approval CREATES THE EMPLOYEE RECORD —
/// <see cref="CreatedEmployeeId"/> is how a caller learns the person now exists — and the LAST
/// approval is refused outright while any required checklist item is undone, with a message naming
/// every one of them. <see cref="OutstandingRequired"/> is that count after this decision.
/// </summary>
public sealed class OnboardingDecisionResult : TypedDecisionResult
{
    public int? CreatedEmployeeId { get; set; }
    public int OutstandingRequired { get; set; }
}

/// <summary>Tick or untick one checklist item. Refused once the request is closed.</summary>
public sealed class OnboardingSetTaskRequest
{
    public bool IsComplete { get; set; }
    public string? Note { get; set; }
}
