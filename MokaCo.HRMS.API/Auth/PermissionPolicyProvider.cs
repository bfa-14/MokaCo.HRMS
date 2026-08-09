using Microsoft.AspNetCore.Authorization;
using Microsoft.Extensions.Options;

namespace MokaCo.HRMS.Api.Auth;

/// <summary>
/// Creates an authorization policy on the fly for any "perm:CODE" name, requiring a
/// matching "perm" claim. Lets you write [HasPermission("X")] without registering
/// every permission by hand.
/// </summary>
public class PermissionPolicyProvider : IAuthorizationPolicyProvider
{
    private readonly DefaultAuthorizationPolicyProvider _fallback;
    public PermissionPolicyProvider(IOptions<AuthorizationOptions> options)
        => _fallback = new DefaultAuthorizationPolicyProvider(options);

    public Task<AuthorizationPolicy> GetDefaultPolicyAsync() => _fallback.GetDefaultPolicyAsync();
    public Task<AuthorizationPolicy?> GetFallbackPolicyAsync() => _fallback.GetFallbackPolicyAsync();

    public Task<AuthorizationPolicy?> GetPolicyAsync(string policyName)
    {
        if (policyName.StartsWith(HasPermissionAttribute.Prefix, StringComparison.OrdinalIgnoreCase))
        {
            var code = policyName.Substring(HasPermissionAttribute.Prefix.Length);
            var policy = new AuthorizationPolicyBuilder()
                .RequireAuthenticatedUser()
                .RequireClaim("perm", code)
                .Build();
            return Task.FromResult<AuthorizationPolicy?>(policy);
        }
        return _fallback.GetPolicyAsync(policyName);
    }
}
