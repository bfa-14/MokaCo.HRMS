using System.Security.Claims;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace MokaCo.HRMS.Tests;

/// <summary>A controller context whose caller is the given user id — what User.UserId() and the NameIdentifier claim read.</summary>
public static class TestPrincipal
{
    public static ControllerContext For(int userId)
    {
        var identity = new ClaimsIdentity(new[] { new Claim(ClaimTypes.NameIdentifier, userId.ToString()) }, "test");
        return new ControllerContext
        {
            HttpContext = new DefaultHttpContext { User = new ClaimsPrincipal(identity) },
        };
    }
}
