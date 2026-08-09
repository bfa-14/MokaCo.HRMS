using MokaCo.HRMS.Model.Core;

namespace MokaCo.HRMS.Repository.Core;

public interface ISystemRepository
{
    /// <summary>
    /// Deletes every request, attendance record and employee (core.usp_System_ResetTestData) and
    /// returns what SURVIVED — users, roles, chains, branches, leave policy, shifts.
    ///
    /// THREE THINGS THE PROCEDURE OWNS, and this layer must not duplicate or pre-empt:
    ///   the arming flag (core.SETTING 'AllowSystemReset'), the exact confirmation phrase, and
    ///   disarming itself afterwards. Both refusals RETURN before the transaction opens, so a
    ///   refused call changes nothing at all.
    /// </summary>
    Task<IEnumerable<SystemResetSummaryRow>> ResetTestDataAsync(string confirm, int actedByUserId);
}
