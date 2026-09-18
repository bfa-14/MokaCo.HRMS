using MokaCo.HRMS.Model.Payroll;
using MokaCo.HRMS.Repository.Payroll;
using MokaCo.HRMS.Services.Payroll;
using MokaCo.HRMS.Services.Workflow;
using Moq;

namespace MokaCo.HRMS.Tests.Payroll;

/// <summary>
/// BUG-18 (script 78): a run created without runType is a PRIMARY run, in every layer.
///
/// Before the fix the service passed NULL through, and the procedure's IF @RunType = 'Primary' is
/// false for NULL, so the run silently took the supplemental path. The DTO now defaults to
/// "Primary", the service normalises blank to "Primary" and refuses anything else with a 400, and
/// the procedure applies ISNULL(@RunType, 'Primary') as well (covered by
/// <see cref="PayrollFixPackDbTests.Create_WithNullRunType_TakesThePrimaryPath"/>).
/// </summary>
public class PayrollRunTypeDefaultTests
{
    private static (PayrollService Service, Mock<IPayrollRepository> Repo) Build()
    {
        var repo = new Mock<IPayrollRepository>(MockBehavior.Strict);
        repo.Setup(r => r.CreateRunAsync(It.IsAny<string>(), It.IsAny<int>(), It.IsAny<string?>(), It.IsAny<string?>()))
            .ReturnsAsync(new PayrollRunCreated { PayrollRunId = 1, PeriodYearMonth = "2026-09", Status = "Draft", PrimaryCurrency = "USD" });
        return (new PayrollService(repo.Object), repo);
    }

    [Fact]
    public void Dto_DefaultsToPrimary()
    {
        Assert.Equal("Primary", new PayrollRunCreateRequest().RunType);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public async Task Blank_RunType_ReachesTheProcedureAsPrimary(string? runType)
    {
        var (svc, repo) = Build();
        await svc.CreateRunAsync(new PayrollRunCreateRequest { PeriodYearMonth = "2026-09", RunType = runType }, 7);
        repo.Verify(r => r.CreateRunAsync("2026-09", 7, null, "Primary"), Times.Once);
    }

    [Theory]
    [InlineData("Supplemental", "Supplemental")]
    [InlineData("supplemental", "Supplemental")]
    [InlineData(" primary ", "Primary")]
    public async Task Known_RunType_IsNormalised(string given, string expected)
    {
        var (svc, repo) = Build();
        await svc.CreateRunAsync(new PayrollRunCreateRequest { PeriodYearMonth = "2026-09", RunType = given }, 7);
        repo.Verify(r => r.CreateRunAsync("2026-09", 7, null, expected), Times.Once);
    }

    [Theory]
    [InlineData("Bonus")]
    [InlineData("Primary;DROP")]
    public async Task Unknown_RunType_IsA400_BeforeTheProcedureIsCalled(string given)
    {
        var (svc, repo) = Build();
        // The service throws before it returns a Task (the controller's try block turns that into a 400);
        // ThrowsAsync catches a synchronous throw from the lambda as well.
        var ex = await Assert.ThrowsAsync<WorkflowException>(() =>
            svc.CreateRunAsync(new PayrollRunCreateRequest { PeriodYearMonth = "2026-09", RunType = given }, 7));
        Assert.Equal(400, ex.StatusCode);
        Assert.Equal("RunType is Primary or Supplemental.", ex.Message);
        repo.Verify(r => r.CreateRunAsync(It.IsAny<string>(), It.IsAny<int>(), It.IsAny<string?>(), It.IsAny<string?>()), Times.Never);
    }
}
