using System.Reflection;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Routing;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Controllers;

namespace MokaCo.HRMS.Tests.Api;

/// <summary>
/// QA3 WF-11: a request's conversation and its mail answer only to someone who may see the request.
/// Before, any signed-in user could read and write any request's notes by id, have its outcome mailed
/// (and be shown the address), and read the mail server's answer.
/// </summary>
public class RequestNotesMailGateTests
{
    [Theory]
    [InlineData(nameof(RequestsController.GetNotes), "GET", "{id:int}/notes")]
    [InlineData(nameof(RequestsController.AddNote), "POST", "{id:int}/notes")]
    [InlineData(nameof(RequestsController.SendEmail), "POST", "{id:int}/send-email")]
    [InlineData(nameof(RequestsController.EmailStatus), "GET", "{id:int}/email-status")]
    public void The_notes_and_mail_of_a_request_are_behind_its_visibility_rule(string action, string verb, string template)
    {
        var method = typeof(RequestsController).GetMethod(action)!;
        var route = method.GetCustomAttributes<HttpMethodAttribute>().Single();

        Assert.Equal(template, route.Template);
        Assert.Contains(verb, route.HttpMethods);
        Assert.NotNull(method.GetCustomAttribute<RequestVisibleAttribute>());
    }

    /// <summary>Every action of the requests controller keyed by one request id answers the visibility rule somewhere: in the
    /// attribute, in the service (the reads that take a RequestCaller), or in the database (the decisions).</summary>
    [Fact]
    public void No_new_read_of_one_request_can_skip_the_rule_unnoticed()
    {
        var gatedInService = new[]
        {
            nameof(RequestsController.GetById), nameof(RequestsController.GetSteps), nameof(RequestsController.Decisions),
            nameof(RequestsController.SignatureRequirement), nameof(RequestsController.GetDraft), nameof(RequestsController.StepSignatureImage),
        };
        var reads = typeof(RequestsController).GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
            .Where(m => m.GetCustomAttributes<HttpGetAttribute>().Any(g => g.Template?.StartsWith("{id:int}") == true))
            .Where(m => m.GetCustomAttribute<RequestVisibleAttribute>() is null && !gatedInService.Contains(m.Name))
            .Select(m => m.Name)
            .ToList();

        Assert.Empty(reads);
    }
}
