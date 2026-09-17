using Moq;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;
using MokaCo.HRMS.Services.HR;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.HR;

/// <summary>
/// A NEW employee must carry a valid e-mail and a Lebanese phone number, stored normalised; an
/// EDIT is never blocked by a missing one (older staff may lack them). The messages are the ones
/// the form shows, so they are asserted verbatim.
/// </summary>
public class EmployeeContactValidationTests
{
    /* ---- the phone rule: 8 local digits or +961…, normalised to E.164 ---- */

    [Theory]
    [InlineData("03123456", "+9613123456")]
    [InlineData("03 123 456", "+9613123456")]
    [InlineData("71234567", "+96171234567")]
    [InlineData("71-234-567", "+96171234567")]
    [InlineData("01 234 567", "+9611234567")]
    [InlineData("+961 3 123 456", "+9613123456")]
    [InlineData("+96171234567", "+96171234567")]
    [InlineData("+961 03 123 456", "+9613123456")]
    [InlineData("00961 71 234 567", "+96171234567")]
    [InlineData("961 71 234 567", "+96171234567")]
    [InlineData("(03) 123-456", "+9613123456")]
    public void Lebanese_numbers_normalise_to_plus961(string input, string expected)
    {
        Assert.Equal(expected, ContactRules.NormalisePhone(input));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("12345")]            // too short
    [InlineData("0312345")]          // 7 local digits
    [InlineData("031234567")]        // 9 local digits
    [InlineData("+44 20 7946 0958")] // not Lebanese
    [InlineData("+961")]             // country code only
    [InlineData("abcdefgh")]
    public void Anything_else_is_not_a_phone(string input)
    {
        Assert.Null(ContactRules.NormalisePhone(input));
    }

    /* ---- the e-mail rule ---- */

    [Theory]
    [InlineData("hadi@mokaco.com")]
    [InlineData("first.last+tag@sub.example.org")]
    public void Valid_addresses_pass(string email) => Assert.True(ContactRules.IsValidEmail(email));

    [Theory]
    [InlineData("")]
    [InlineData("hadi")]
    [InlineData("hadi@")]
    [InlineData("@mokaco.com")]
    [InlineData("hadi mokaco@x.com")]
    [InlineData("hadi@localhost")]
    [InlineData("Hadi <hadi@mokaco.com>")]
    public void Invalid_addresses_fail(string email) => Assert.False(ContactRules.IsValidEmail(email));

    /* ---- the create path: refused in words, or saved normalised ---- */

    private static EmployeeCreateRequest Request(string? email, string? phone) => new()
    {
        BranchId = 1, DepartmentId = 1, PositionId = 1,
        FullName = "A2TEST Person", HireDate = new DateTime(2026, 1, 5),
        Email = email, PhoneNumber = phone,
    };

    [Theory]
    [InlineData(null, "03123456")]
    [InlineData("hadi@mokaco.com", null)]
    [InlineData("  ", "03123456")]
    [InlineData("hadi@mokaco.com", "")]
    public async Task Create_without_phone_or_email_is_refused(string? email, string? phone)
    {
        var repo = new Mock<IEmployeeRepository>(MockBehavior.Strict);
        var service = new EmployeeService(repo.Object);

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => service.CreateAsync(Request(email, phone), 1));

        Assert.Equal(400, ex.StatusCode);
        Assert.Equal("Phone number and e-mail are required for a new employee.", ex.Message);
    }

    [Fact]
    public async Task Create_with_a_bad_email_is_refused()
    {
        var service = new EmployeeService(new Mock<IEmployeeRepository>(MockBehavior.Strict).Object);

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => service.CreateAsync(Request("not-an-address", "03123456"), 1));

        Assert.Equal(400, ex.StatusCode);
        Assert.Equal(ContactRules.InvalidEmailMessage, ex.Message);
    }

    [Fact]
    public async Task Create_with_a_non_lebanese_phone_is_refused()
    {
        var service = new EmployeeService(new Mock<IEmployeeRepository>(MockBehavior.Strict).Object);

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => service.CreateAsync(Request("hadi@mokaco.com", "+44 20 7946 0958"), 1));

        Assert.Equal(400, ex.StatusCode);
        Assert.Equal(ContactRules.InvalidPhoneMessage, ex.Message);
    }

    [Fact]
    public async Task Create_saves_the_phone_normalised_and_the_email_trimmed()
    {
        var repo = new Mock<IEmployeeRepository>(MockBehavior.Strict);
        repo.Setup(r => r.CreateAsync(
                null, 1, 1, 1, "A2TEST Person", null, null, new DateTime(2026, 1, 5), 1,
                "hadi@mokaco.com", "+9613123456", null))
            .ReturnsAsync(42);
        var service = new EmployeeService(repo.Object);

        var id = await service.CreateAsync(Request("  hadi@mokaco.com ", "03 123 456"), 1);

        Assert.Equal(42, id);
        repo.VerifyAll();
    }

    /* ---- the update path does not block ---- */

    [Fact]
    public async Task Update_without_contact_fields_is_not_blocked()
    {
        var repo = new Mock<IEmployeeRepository>(MockBehavior.Strict);
        repo.Setup(r => r.UpdateAsync(
                5, 1, 1, 1, "Old Timer", null, null, new DateTime(2010, 3, 1), null, 1,
                null, null, null))
            .Returns(Task.CompletedTask);
        var service = new EmployeeService(repo.Object);

        await service.UpdateAsync(5, new EmployeeUpdateRequest
        {
            BranchId = 1, DepartmentId = 1, PositionId = 1, FullName = "Old Timer",
            HireDate = new DateTime(2010, 3, 1), Email = null, PhoneNumber = "",
        }, 1);

        repo.VerifyAll();
    }
}
