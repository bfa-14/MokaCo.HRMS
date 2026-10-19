using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Auth;

/// <summary>
/// The SAME visibility rule as GET /api/requests/{id}, run before a typed read of one request — its
/// payload, its conflict list, an exit permission's day: the caller holds REQUEST_VIEW_ALL, or the
/// request is about them, or they raised it, or they are (or were) an approver on one of its steps.
///
/// WHY (QA3 SEC-1): these routes carried only [Authorize], so any signed-in user could read any
/// request by id — salary advances, payroll adjustments, separation settlements, leave reasons. The
/// rule itself stays in RequestService; this filter only runs it first, so the typed routes cannot
/// drift from the detail page.
///
/// Usage: [RequestVisible] on an action whose int route value `id` is the request instance id.
/// 404 when there is no such request, 403 when it is not the caller's to see.
/// </summary>
[AttributeUsage(AttributeTargets.Method)]
public sealed class RequestVisibleAttribute : ActionFilterAttribute
{
    public override async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
    {
        if (!context.ActionArguments.TryGetValue("id", out var raw) || raw is not int id)
            throw new InvalidOperationException("[RequestVisible] needs an int route value named 'id'.");

        var services = context.HttpContext.RequestServices;
        var user = context.HttpContext.User;
        var me = await services.GetRequiredService<IWorkflowSupportService>().GetEmployeeByUserIdAsync(user.UserId());
        var caller = new RequestCaller(user.UserId(), me?.EmployeeId, user.HasPermission("REQUEST_VIEW_ALL"));

        try
        {
            if (await services.GetRequiredService<IRequestService>().GetByIdAsync(id, caller) is null)
            {
                context.Result = new NotFoundResult();
                return;
            }
        }
        catch (WorkflowException ex)
        {
            context.Result = new ObjectResult(new { error = ex.Message }) { StatusCode = ex.StatusCode };
            return;
        }

        await next();
    }
}
