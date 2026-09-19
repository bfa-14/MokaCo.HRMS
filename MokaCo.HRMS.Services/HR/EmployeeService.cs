using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.HR;

/// <summary>Employee administration (thin wrapper over the repository).</summary>
public class EmployeeService : IEmployeeService
{
    private readonly IEmployeeRepository _repo;
    public EmployeeService(IEmployeeRepository repo) => _repo = repo;

    public Task<IEnumerable<EmployeeListItem>> GetAllAsync() => _repo.GetAllAsync();

    public Task<EmployeeProfile?> GetProfileAsync(int employeeId) => _repo.GetProfileAsync(employeeId);

    /// <summary>
    /// A NEW employee must have a phone number and an e-mail (71_employee_contact_required.sql
    /// enforces the presence; the format rules live in <see cref="ContactRules"/>). Refused here as a
    /// WorkflowException 400 so the message is the one the form shows, and the phone is stored
    /// NORMALISED (+961…) so one number cannot exist under two spellings.
    /// </summary>
    public Task<int> CreateAsync(EmployeeCreateRequest request, int? createdBy)
    {
        if (string.IsNullOrWhiteSpace(request.Email) || string.IsNullOrWhiteSpace(request.PhoneNumber))
            throw new WorkflowException(400, ContactRules.RequiredMessage);
        if (!ContactRules.IsValidEmail(request.Email))
            throw new WorkflowException(400, ContactRules.InvalidEmailMessage);
        var phone = ContactRules.NormalisePhone(request.PhoneNumber)
            ?? throw new WorkflowException(400, ContactRules.InvalidPhoneMessage);

        // The @UserId is passed straight through — a new employee can be linked at creation. If the
        // account is already taken, the procedure raises the same friendly message as LinkUser
        // (naming the other employee); MapAsync turns it into a 400 with that message intact.
        return WorkflowSqlErrors.MapAsync(() => _repo.CreateAsync(
            request.UserId, request.BranchId, request.DepartmentId, request.PositionId,
            request.FullName, request.NationalId, request.NssfNumber, request.HireDate, createdBy,
            request.Email.Trim(), phone, request.PreferredLanguage));
    }

    public Task UpdateAsync(int employeeId, EmployeeUpdateRequest request, int? modifiedBy)
        => _repo.UpdateAsync(
            employeeId, request.BranchId, request.DepartmentId, request.PositionId,
            request.FullName, request.NationalId, request.NssfNumber, request.HireDate,
            request.TerminationDate, modifiedBy,
            // An edit is NOT blocked by a missing or legacy contact value (older staff may lack them);
            // a phone that parses is stored normalised, one that does not is kept as typed.
            string.IsNullOrWhiteSpace(request.Email) ? null : request.Email.Trim(),
            string.IsNullOrWhiteSpace(request.PhoneNumber)
                ? null
                : ContactRules.NormalisePhone(request.PhoneNumber) ?? request.PhoneNumber.Trim(),
            request.PreferredLanguage,
            request.BranchEffectiveFrom);

    public Task<IEnumerable<EmployeeBranchHistoryRow>> GetBranchHistoryAsync(int employeeId) => _repo.GetBranchHistoryAsync(employeeId);

    public Task CancelFutureTransferAsync(int employeeBranchHistoryId, int? actedByUserId) => _repo.CancelFutureTransferAsync(employeeBranchHistoryId, actedByUserId);

    public Task SoftDeleteAsync(int employeeId, int? modifiedBy) => _repo.SoftDeleteAsync(employeeId, modifiedBy);

    // ---- employee <-> user account linking ----

    public Task<IEnumerable<EmployeeLoginStatus>> GetLoginStatusAsync(bool onlyMissing)
        => _repo.GetLoginStatusAsync(onlyMissing);

    /// <summary>
    /// Links an account. The procedure refuses (RAISERROR) when the account already belongs to
    /// someone else, naming them; WorkflowSqlErrors turns that into a 400 with the message intact,
    /// so the reason reaches the user unchanged.
    /// </summary>
    public Task<EmployeeUserLinkResult?> LinkUserAsync(int employeeId, int userId, int? actedBy)
        => WorkflowSqlErrors.MapAsync(() => _repo.LinkUserAsync(employeeId, userId, actedBy));

    public Task<EmployeeUserUnlinkResult> UnlinkUserAsync(int employeeId, int? actedBy)
        => _repo.UnlinkUserAsync(employeeId, actedBy);

    /// <summary>The procedure validates the range and RAISERRORs otherwise; that becomes a clean 400 with the message.</summary>
    public Task<EmployeeApprovalTier?> SetApprovalTierAsync(int employeeId, int approvalTier)
        => WorkflowSqlErrors.MapAsync(() => _repo.SetApprovalTierAsync(employeeId, approvalTier));

    /// <summary>A self-reference or a loop RAISERRORs, becoming a clean 400 with the reason the admin needs.</summary>
    public Task<EmployeeReportsTo?> SetReportsToAsync(int employeeId, int? reportsToEmployeeId)
        => WorkflowSqlErrors.MapAsync(() => _repo.SetReportsToAsync(employeeId, reportsToEmployeeId));

    public Task<IEnumerable<ReportingLineEntry>> GetReportingLineAsync(int employeeId)
        => _repo.GetReportingLineAsync(employeeId);

    public Task<IEnumerable<OrgTreeNode>> GetOrgTreeAsync()
        => _repo.GetOrgTreeAsync();

    public Task<int> GetOrgMaxDepthAsync()
        => _repo.GetOrgMaxDepthAsync();
}
