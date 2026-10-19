namespace MokaCo.HRMS.Model.HR;

/// <summary>
/// What one caller may see for a period (hr.usp_Scope_CallerEmployees, script 105, QA3 ATT-16) — script
/// 87's branch scope, for the reads whose procedures cannot take it themselves (their repo copies are
/// older than production, CON-7): the API filters their rows with this.
/// </summary>
public sealed class CallerScopeSet
{
    /// <summary>EMP_VIEW_ALL (or the system): every row.</summary>
    public bool SeesAll { get; init; }

    /// <summary>The caller's own employee, or null for a login with none.</summary>
    public int? CallerEmployeeId { get; init; }

    /// <summary>The branches the caller manages.</summary>
    public IReadOnlySet<int> ManagedBranchIds { get; init; } = new HashSet<int>();

    /// <summary>
    /// The employees the caller may see in the period: themselves, those whose branch today they manage,
    /// and those with an attendance day in the period filed to a branch they manage.
    /// </summary>
    public IReadOnlySet<int> EmployeeIds { get; init; } = new HashSet<int>();

    /// <summary>
    /// Every row: what these reads answered before script 105, and what they answer while it is not
    /// applied (the API deployed first; see CallerScopes in the API).
    /// </summary>
    public static CallerScopeSet Unscoped { get; } = new() { SeesAll = true };

    /// <summary>Built from the procedure's (Kind, Id) rows: A = everyone, S = own employee, B = managed branch, E = visible employee.</summary>
    public static CallerScopeSet From(IEnumerable<(string Kind, int? Id)> rows)
    {
        var list = rows.ToList();
        return new CallerScopeSet
        {
            SeesAll = list.Any(r => r.Kind == "A"),
            CallerEmployeeId = list.Where(r => r.Kind == "S").Select(r => r.Id).FirstOrDefault(),
            ManagedBranchIds = list.Where(r => r.Kind == "B" && r.Id is not null).Select(r => r.Id!.Value).ToHashSet(),
            EmployeeIds = list.Where(r => r.Kind == "E" && r.Id is not null).Select(r => r.Id!.Value).ToHashSet(),
        };
    }

    /// <summary>A row about one employee for the period (a monthly summary, a report line).</summary>
    public bool SeesEmployee(int employeeId) => SeesAll || EmployeeIds.Contains(employeeId);

    /// <summary>
    /// A row filed to a branch (the per-branch split of a month): the branch's manager sees it, and so
    /// does the employee it is about. A row with no branch falls back to the employee rule.
    /// </summary>
    public bool SeesBranchRow(int employeeId, int? branchId)
        => SeesAll
           || employeeId == CallerEmployeeId
           || (branchId is int branch ? ManagedBranchIds.Contains(branch) : EmployeeIds.Contains(employeeId));

    /// <summary>
    /// A raw punch: by the employee it belongs to; a punch on a PIN mapped to nobody, by the terminal's
    /// branch (the only thing known about it).
    /// </summary>
    public bool SeesPunch(int? employeeId, int deviceBranchId)
        => SeesAll || (employeeId is int employee ? EmployeeIds.Contains(employee) : ManagedBranchIds.Contains(deviceBranchId));
}
