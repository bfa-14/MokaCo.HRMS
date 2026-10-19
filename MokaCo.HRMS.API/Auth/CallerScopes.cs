using Microsoft.Extensions.DependencyInjection;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.Common;
using MokaCo.HRMS.Repository.HR;
using MokaCo.HRMS.Services.Core;

namespace MokaCo.HRMS.Api.Auth;

/// <summary>The caller's scope for filtering the rows of a list (QA3 ATT-16), the one way the controllers ask for it.</summary>
public static class CallerScopes
{
    /// <summary>
    /// What the signed-in caller may see between <paramref name="from"/> and <paramref name="to"/>
    /// (hr.usp_Scope_CallerEmployees, script 105).
    ///
    /// WHILE SCRIPT 105 IS NOT APPLIED (the API deployed first): every row, as these reads answered
    /// before it, and the one warning naming the script. A summary page or a report that worked before
    /// the deploy must not start failing because the SQL step was missed; the branch scope starts the
    /// moment the script is applied.
    /// </summary>
    public static async Task<CallerScopeSet> ForCallerAsync(this IScopeRepository scopes, HttpContext http, DateTime? from, DateTime? to)
    {
        try
        {
            return await scopes.CallerEmployeesAsync(http.User.UserId(), from, to);
        }
        catch (MissingScriptException missing)
        {
            http.RequestServices?.GetService<MissingScriptWarning>()
                ?.FellBack(missing, "attendance summaries, raw punches and reports are not filtered by the caller's branches");
            return CallerScopeSet.Unscoped;
        }
    }
}
