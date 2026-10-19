using Moq;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Workflow;

/// <summary>
/// QA3 WF-12: a shift swap is raised for the caller — the requester's employee id comes from the body,
/// so without REQUEST_RAISE_OTHERS it must be the caller's own, as for every other typed request.
/// </summary>
public class ShiftSwapRaiseForTests
{
    private const int Joe = 12, Rami = 10, Lina = 11, JoeUser = 6;

    private static (ShiftSwapService Service, Mock<IShiftSwapRepository> Repo) Make()
    {
        var repo = new Mock<IShiftSwapRepository>();
        repo.Setup(r => r.CreateAsync(It.IsAny<int>(), It.IsAny<int>(), It.IsAny<int>(), It.IsAny<DateTime>(), It.IsAny<DateTime>(), It.IsAny<bool>(), It.IsAny<string?>()))
            .ReturnsAsync(new ShiftSwapCreated { RequestInstanceId = 99, Status = "Pending" });
        return (new ShiftSwapService(repo.Object, Mock.Of<IDecisionSignatureService>()), repo);
    }

    private static ShiftSwapCreateRequest For(int employeeId) => new()
    {
        EmployeeId = employeeId, CounterpartEmployeeId = Lina,
        RequesterDate = new DateTime(2026, 11, 2), CounterpartDate = new DateTime(2026, 11, 3), CounterpartHasAgreed = true,
    };

    [Fact]
    public async Task Raising_a_swap_in_a_colleagues_name_without_the_permission_is_403_and_writes_nothing()
    {
        var (service, repo) = Make();

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => service.CreateAsync(For(Rami), new ShiftSwapCaller(JoeUser, Joe, HasRaiseOthers: false)));

        Assert.Equal(403, ex.StatusCode);
        repo.Verify(r => r.CreateAsync(It.IsAny<int>(), It.IsAny<int>(), It.IsAny<int>(), It.IsAny<DateTime>(), It.IsAny<DateTime>(), It.IsAny<bool>(), It.IsAny<string?>()), Times.Never());
    }

    [Fact]
    public async Task An_account_with_no_employee_cannot_raise_one_without_the_permission()
    {
        var (service, _) = Make();

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => service.CreateAsync(For(Joe), new ShiftSwapCaller(JoeUser, null, HasRaiseOthers: false)));

        Assert.Equal(403, ex.StatusCode);
    }

    [Fact]
    public async Task A_swap_for_oneself_goes_to_the_procedure_raised_by_the_caller()
    {
        var (service, repo) = Make();

        var created = await service.CreateAsync(For(Joe), new ShiftSwapCaller(JoeUser, Joe, HasRaiseOthers: false));

        Assert.Equal(99, created!.RequestInstanceId);
        repo.Verify(r => r.CreateAsync(Joe, JoeUser, Lina, new DateTime(2026, 11, 2), new DateTime(2026, 11, 3), true, null), Times.Once());
    }

    [Fact]
    public async Task REQUEST_RAISE_OTHERS_may_raise_it_in_someone_elses_name()
    {
        var (service, repo) = Make();

        await service.CreateAsync(For(Rami), new ShiftSwapCaller(UserId: 2, EmployeeId: 13, HasRaiseOthers: true));

        repo.Verify(r => r.CreateAsync(Rami, 2, Lina, It.IsAny<DateTime>(), It.IsAny<DateTime>(), true, null), Times.Once());
    }
}
