using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;
using MokaCo.HRMS.Repository.HR;

namespace MokaCo.HRMS.Api.Auth;

/// <summary>What the route value of an [InCallerScope] action names.</summary>
public enum ScopeTarget
{
    Employee,
    Attendance,
    Document,
}

/// <summary>
/// THE BRANCH SCOPE OF SCRIPT 87 FOR READS OF ONE RECORD (QA3 SEC-2). The lists were scoped — without
/// EMP_VIEW_ALL a caller sees their own rows and the branches they manage — but the reads by id took
/// only the id, so a branch manager could open any employee by number: profile, salary, leave,
/// documents, an attendance day. This runs hr.usp_Scope_CallerSees (script 98) before the action:
/// 404 when the record does not exist, 403 when it is outside the caller's branches.
///
/// <see cref="Salary"/>: the read is someone's PAY. Beyond the branch scope it needs EMP_VIEW_ALL or
/// PAYROLL_VIEW, or the record must be the caller's own — a branch manager runs the roster, not the
/// payroll (QA3 decision).
///
/// Usage: [InCallerScope(ScopeTarget.Employee)] — the route value is `id` unless <see cref="RouteKey"/> says otherwise.
/// </summary>
[AttributeUsage(AttributeTargets.Method)]
public sealed class InCallerScopeAttribute : ActionFilterAttribute
{
    public InCallerScopeAttribute(ScopeTarget target) => Target = target;

    public ScopeTarget Target { get; }

    public string RouteKey { get; init; } = "id";

    public bool Salary { get; init; }

    public override async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
    {
        if (!context.ActionArguments.TryGetValue(RouteKey, out var raw) || raw is not (int or long))
            throw new InvalidOperationException($"[InCallerScope] needs an int route value named '{RouteKey}'.");
        var id = Convert.ToInt64(raw);

        var user = context.HttpContext.User;
        var scopes = context.HttpContext.RequestServices.GetRequiredService<IScopeRepository>();
        var scope = Target switch
        {
            ScopeTarget.Employee => await scopes.CallerSeesAsync(user.UserId(), employeeId: checked((int)id)),
            ScopeTarget.Attendance => await scopes.CallerSeesAsync(user.UserId(), attendanceId: id),
            _ => await scopes.CallerSeesAsync(user.UserId(), documentId: checked((int)id)),
        };

        if (!scope.Found)
        {
            context.Result = new NotFoundResult();
            return;
        }

        if (!scope.CanSee)
        {
            context.Result = new ObjectResult(new { error = "This record belongs to a branch you cannot see." }) { StatusCode = StatusCodes.Status403Forbidden };
            return;
        }

        if (Salary && !scope.IsSelf && !user.HasPermission("EMP_VIEW_ALL") && !user.HasPermission("PAYROLL_VIEW"))
        {
            context.Result = new ObjectResult(new { error = "Salaries are visible to HR and payroll only." }) { StatusCode = StatusCodes.Status403Forbidden };
            return;
        }

        await next();
    }
}
