using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.HR;

/// <summary>
/// The seniority dictionary.
///
/// The DELETE guard is the interesting one: the procedure refuses while anybody still holds the
/// tier, and its message NAMES who — which is the difference between "cannot delete" and an answer
/// somebody can act on. WorkflowSqlErrors carries that text out as a 400 without touching it.
///
/// A WRITE THAT SUCCEEDED MUST NOT ANSWER 404. Both setters end in a SELECT of the row they
/// touched, and the controller turns a missing row into NotFound — so a procedure that did the work
/// and simply did not select it back reported a rename that HAD happened as one that never found
/// the tier. (That is exactly what the live SetName did until it was patched to return the row.)
/// The procedures own existence — each raises its own "Tier N does not exist" / "already exists",
/// which arrives as a 400 with that sentence — so an empty result here means "written, not
/// returned", and the row is read back rather than denied.
/// </summary>
public class ApprovalTierService : IApprovalTierService
{
    private readonly IApprovalTierRepository _repo;
    public ApprovalTierService(IApprovalTierRepository repo) => _repo = repo;

    public Task<IEnumerable<ApprovalTier>> GetAllAsync() => _repo.GetAllAsync();

    public Task<ApprovalTier?> CreateAsync(int tierNo, string name, string? nameAr)
        => WorkflowSqlErrors.MapAsync(async () =>
            await _repo.CreateAsync(tierNo, name, nameAr) ?? await ReadBackAsync(tierNo));

    public Task<ApprovalTier?> SetNameAsync(int tierNo, string name, string? nameAr)
        => WorkflowSqlErrors.MapAsync(async () =>
            await _repo.SetNameAsync(tierNo, name, nameAr) ?? await ReadBackAsync(tierNo));

    /// <summary>
    /// The basic-salary band. Read back on the same terms as the rename above: a procedure that did
    /// the work and did not select the row must not be reported as a tier that does not exist.
    /// </summary>
    public Task<ApprovalTier?> SetSalaryRangeAsync(
        int tierNo, decimal? minBasicSalary, decimal? maxBasicSalary, string salaryCurrency)
        => WorkflowSqlErrors.MapAsync(async () =>
            await _repo.SetSalaryRangeAsync(tierNo, minBasicSalary, maxBasicSalary, salaryCurrency)
            ?? await ReadBackAsync(tierNo));

    /// <summary>
    /// The tier as it now stands, from the dictionary read — used only when a setter wrote without
    /// selecting anything back. Deliberately the existing GetAll rather than a new by-number
    /// procedure: the dictionary is nine rows at most, and this path should never run at all.
    /// </summary>
    private async Task<ApprovalTier?> ReadBackAsync(int tierNo)
        => (await _repo.GetAllAsync()).FirstOrDefault(t => t.TierNo == tierNo);

    public Task DeleteAsync(int tierNo)
        => WorkflowSqlErrors.MapAsync(async () =>
        {
            await _repo.DeleteAsync(tierNo);
            return true;
        });
}
