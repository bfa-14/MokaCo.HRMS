using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Repository.Workflow;
using MokaCo.HRMS.Services.Auth;

namespace MokaCo.HRMS.Services.Workflow;

public interface IDecisionSignatureService
{
    /// <summary>
    /// Verifies the password where the step or the caller's role demands a signature, and reports
    /// whether the act was signed. Throws a 401 WorkflowException when a required password is
    /// missing or wrong — BEFORE anything is written.
    /// </summary>
    Task<bool> VerifyAsync(int requestInstanceId, int userId, string? password);
}

/// <summary>
/// THE SIGNATURE, in one place.
///
/// Every typed decide endpoint asks the same question — must this caller password-sign here, and
/// did they? — and each one that answers it privately is another copy that can drift. The rule
/// itself never changes:
///
///   the requirement is RE-READ FROM THE DATABASE rather than trusted from the client, so a caller
///   who simply omits the password cannot skip a signature the policy demands; an unrequested
///   password is DROPPED rather than half-checked, because an unrequested signature is not one; and
///   a wrong password is a 401 raised before any write, so a mistyped one costs nothing but the
///   attempt. The password itself is never stored, logged or echoed back.
/// </summary>
public class DecisionSignatureService : IDecisionSignatureService
{
    private readonly IRequestRepository _requests;
    private readonly IUserRepository _users;
    private readonly IPasswordHasher _hasher;

    public DecisionSignatureService(IRequestRepository requests, IUserRepository users, IPasswordHasher hasher)
    {
        _requests = requests;
        _users = users;
        _hasher = hasher;
    }

    public async Task<bool> VerifyAsync(int requestInstanceId, int userId, string? password)
    {
        var requirement = await _requests.GetSignatureRequirementAsync(requestInstanceId, userId);
        if (requirement?.SignatureRequired != true)
            return false;

        if (string.IsNullOrEmpty(password))
            throw new WorkflowException(
                401,
                requirement.Explanation ?? "This decision must be signed with your password.");

        var user = await _users.GetByIdAsync(userId);
        if (user is null || !_hasher.Verify(password, user.PasswordHash))
            throw new WorkflowException(401, "That password is not correct.");

        return true;
    }
}
