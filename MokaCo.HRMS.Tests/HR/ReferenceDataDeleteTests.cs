using Microsoft.AspNetCore.Mvc;
using Moq;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Services.HR;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.HR;

/// <summary>
/// THE RULE (70_ref_data_delete_rules.sql): reference data nothing references is hard-deleted;
/// a row anything references is refused with a sentence the UI can show, and the API answers 409
/// with that sentence — never a raw FK error, never a 500.
/// </summary>
public class ReferenceDataDeleteTests
{
    private const string UsedMessage =
        "Cannot delete 'Waiter': it is used by 12 employees and 340 payslip lines. Deactivate it instead.";

    /* ---- the pure mapping: the procedure's wording decides the status ---- */

    [Fact]
    public void Used_row_refusal_maps_to_409_with_the_sentence_intact()
    {
        var ex = ReferenceDataSqlErrors.Map(UsedMessage);

        Assert.Equal(409, ex.StatusCode);
        Assert.Equal(UsedMessage, ex.Message);
    }

    [Theory]
    [InlineData("Position not found.")]
    [InlineData("Leave type not found.")]
    [InlineData("Salary component type not found.")]
    public void Unknown_row_maps_to_404(string message)
    {
        Assert.Equal(404, ReferenceDataSqlErrors.Map(message).StatusCode);
    }

    [Fact]
    public void Any_other_refusal_is_a_400()
    {
        Assert.Equal(400, ReferenceDataSqlErrors.Map("A leave type with that name already exists.").StatusCode);
    }

    /* ---- the controllers surface the status and the message, nothing else ---- */

    private static (int Status, string? Error) Unpack(IActionResult result)
    {
        var obj = Assert.IsType<ObjectResult>(result);
        var error = obj.Value?.GetType().GetProperty("error")?.GetValue(obj.Value) as string;
        return (obj.StatusCode ?? 0, error);
    }

    [Fact]
    public async Task Positions_delete_of_a_used_row_is_409()
    {
        var positions = new Mock<IPositionService>(MockBehavior.Strict);
        positions.Setup(p => p.DeleteAsync(7)).ThrowsAsync(new WorkflowException(409, UsedMessage));
        var controller = new PositionsController(positions.Object, Mock.Of<ILiveNotifier>());

        var (status, error) = Unpack(await controller.Delete(7));

        Assert.Equal(409, status);
        Assert.Equal(UsedMessage, error);
    }

    [Fact]
    public async Task Departments_delete_of_a_used_row_is_409()
    {
        var departments = new Mock<IDepartmentService>(MockBehavior.Strict);
        departments.Setup(d => d.DeleteAsync(3)).ThrowsAsync(new WorkflowException(409, UsedMessage));
        var controller = new DepartmentsController(departments.Object, Mock.Of<ILiveNotifier>());

        var (status, error) = Unpack(await controller.Delete(3));

        Assert.Equal(409, status);
        Assert.Equal(UsedMessage, error);
    }

    [Fact]
    public async Task Branches_delete_of_a_used_row_is_409()
    {
        var branches = new Mock<IBranchService>(MockBehavior.Strict);
        branches.Setup(b => b.DeleteAsync(1)).ThrowsAsync(new WorkflowException(409, UsedMessage));
        var controller = new BranchesController(branches.Object, Mock.Of<IWorkflowSupportService>(), Mock.Of<ILiveNotifier>());

        var (status, error) = Unpack(await controller.Delete(1));

        Assert.Equal(409, status);
        Assert.Equal(UsedMessage, error);
    }

    [Fact]
    public async Task ComponentTypes_delete_of_a_used_row_is_409()
    {
        var types = new Mock<IComponentTypeService>(MockBehavior.Strict);
        types.Setup(t => t.DeleteAsync(1)).ThrowsAsync(new WorkflowException(409, UsedMessage));
        var controller = new ComponentTypesController(types.Object, Mock.Of<ILiveNotifier>());

        var (status, error) = Unpack(await controller.Delete(1));

        Assert.Equal(409, status);
        Assert.Equal(UsedMessage, error);
    }

    [Fact]
    public async Task LeaveTypes_delete_of_a_used_row_is_409()
    {
        var types = new Mock<ILeaveTypeService>(MockBehavior.Strict);
        types.Setup(t => t.DeleteAsync(1)).ThrowsAsync(new WorkflowException(409, UsedMessage));
        var controller = new LeaveTypesController(types.Object, Mock.Of<ILiveNotifier>());

        var (status, error) = Unpack(await controller.Delete(1));

        Assert.Equal(409, status);
        Assert.Equal(UsedMessage, error);
    }

    [Fact]
    public async Task Unused_row_is_deleted_with_204()
    {
        var positions = new Mock<IPositionService>(MockBehavior.Strict);
        positions.Setup(p => p.DeleteAsync(9)).Returns(Task.CompletedTask);
        var controller = new PositionsController(positions.Object, Mock.Of<ILiveNotifier>());

        Assert.IsType<NoContentResult>(await controller.Delete(9));
        positions.Verify(p => p.DeleteAsync(9), Times.Once);
    }

    [Fact]
    public async Task Deactivate_instead_goes_through_SetActive()
    {
        var positions = new Mock<IPositionService>(MockBehavior.Strict);
        positions.Setup(p => p.SetActiveAsync(9, false)).Returns(Task.CompletedTask);
        var controller = new PositionsController(positions.Object, Mock.Of<ILiveNotifier>());

        Assert.IsType<NoContentResult>(await controller.SetActive(9, new SetActiveRequest { IsActive = false }));
        positions.Verify(p => p.SetActiveAsync(9, false), Times.Once);
    }
}

/// <summary>The leave request form of an employee reads the leave types: REQUEST_RAISE_SELF is enough, as is EMP_VIEW.</summary>
public class LeaveTypesReadTests
{
    private static MokaCo.HRMS.Api.Controllers.LeaveTypesController Controller(params string[] perms)
    {
        var types = new Moq.Mock<MokaCo.HRMS.Services.HR.ILeaveTypeService>();
        types.Setup(t => t.GetAllAsync()).ReturnsAsync(new List<MokaCo.HRMS.Model.HR.LeaveType>());
        types.Setup(t => t.GetRelationEntitlementsAsync()).ReturnsAsync(new List<MokaCo.HRMS.Model.HR.LeaveRelationEntitlement>());
        var claims = perms.Select(p => new System.Security.Claims.Claim("perm", p)).Append(new System.Security.Claims.Claim("sub", "5"));
        return new MokaCo.HRMS.Api.Controllers.LeaveTypesController(types.Object, Moq.Mock.Of<MokaCo.HRMS.Api.Hubs.ILiveNotifier>())
        {
            ControllerContext = new Microsoft.AspNetCore.Mvc.ControllerContext
            {
                HttpContext = new Microsoft.AspNetCore.Http.DefaultHttpContext
                { User = new System.Security.Claims.ClaimsPrincipal(new System.Security.Claims.ClaimsIdentity(claims, "test")) },
            },
        };
    }

    [Theory]
    [InlineData("REQUEST_RAISE_SELF")]
    [InlineData("EMP_VIEW")]
    public async Task Either_code_reads_the_leave_types(string perm)
    {
        Assert.IsType<Microsoft.AspNetCore.Mvc.OkObjectResult>(await Controller(perm).GetAll());
        Assert.IsType<Microsoft.AspNetCore.Mvc.OkObjectResult>(await Controller(perm).GetRelationEntitlements());
    }

    [Fact]
    public async Task Neither_code_is_refused()
        => Assert.IsType<Microsoft.AspNetCore.Mvc.ForbidResult>(await Controller("BOOKING_VIEW").GetAll());
}
