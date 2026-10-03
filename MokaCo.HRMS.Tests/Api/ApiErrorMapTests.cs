using MokaCo.HRMS.Api.Errors;
using MokaCo.HRMS.Services.Security;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Api;

/// <summary>
/// BUG-03: a database error used to leave as a 500 quoting the constraint and the stack. The table
/// that replaces it is pure, so every row is pinned here without a database or a request.
/// </summary>
public class ApiErrorMapTests
{
    private const string Trace = "0af7651916cd43dd8448eb211c80319c";

    [Theory]
    [InlineData("Attendance for August 2026 is not ready for payroll. Open the readiness check and clear the counts.", 400)]
    [InlineData("The end time must be after the start time.", 400)]
    [InlineData("A primary run for August 2026 already exists. Cancel it first if it must be redone.", 409)]
    [InlineData("That time was just taken — pick another slot.", 409)]
    [InlineData("Waiting for approval — request #59.", 409)]
    [InlineData("This payroll run is locked.", 409)]
    [InlineData("This period is paid — raise a payroll adjustment instead.", 409)]
    [InlineData("LBP is already used and cannot be deleted: hr.SALARY_COMPONENT.CurrencyCode (12), setting PrimaryCurrency.", 409)]
    [InlineData("Currency XYZ does not exist.", 400)]
    public void A_procedure_refusal_keeps_its_sentence_and_is_a_400_or_a_409(string raised, int status)
    {
        var error = ApiErrorMap.ForSql(50000, raised, Trace);

        Assert.Equal(status, error.Status);
        Assert.Equal(raised, error.Message);
        Assert.False(error.IsServerFault);
    }

    [Theory]
    [InlineData(547, 400, ApiErrorMap.NotAllowed, false)]
    [InlineData(2627, 409, ApiErrorMap.AlreadyExists, false)]
    [InlineData(2601, 409, ApiErrorMap.AlreadyExists, false)]
    [InlineData(-2, 503, ApiErrorMap.DatabaseTimeout, true)]
    [InlineData(1205, 503, ApiErrorMap.DatabaseBusy, true)]
    public void An_engine_error_is_replaced_by_a_sentence_without_the_engine_text(int number, int status, string message, bool fault)
    {
        const string engineText =
            "The INSERT statement conflicted with the FOREIGN KEY constraint \"FK__SHIFT_ASS__Emplo__5D95E53A\". " +
            "The conflict occurred in database \"MokaCo_HRMS\", table \"hr.EMPLOYEE\", column 'EmployeeId'.";

        var error = ApiErrorMap.ForSql(number, engineText, Trace);

        Assert.Equal(status, error.Status);
        Assert.Equal(message, error.Message);
        Assert.Equal(fault, error.IsServerFault);
        Assert.DoesNotContain("FK__", error.Message);
        Assert.DoesNotContain("MokaCo_HRMS", error.Message);
    }

    [Fact]
    public void An_unknown_sql_error_is_a_500_that_carries_the_reference_and_nothing_else()
    {
        var error = ApiErrorMap.ForSql(208, "Invalid object name 'hr.EMPLOYE'.", Trace);

        Assert.Equal(500, error.Status);
        Assert.Equal($"Something went wrong. Reference {Trace}", error.Message);
        Assert.True(error.IsServerFault);
    }

    [Fact]
    public void Exceptions_that_already_carry_a_status_pass_through_unchanged()
    {
        var workflow = ApiErrorMap.Classify(new WorkflowException(403, "You are not the approver for this step."), Trace);
        Assert.Equal((403, "You are not the approver for this step.", false), (workflow.Status, workflow.Message, workflow.IsServerFault));

        var signature = ApiErrorMap.Classify(new SignatureValidationException("The signature must be a PNG or JPEG."), Trace);
        Assert.Equal((400, "The signature must be a PNG or JPEG."), (signature.Status, signature.Message));
    }

    [Fact]
    public void A_bug_never_shows_its_own_message()
    {
        var error = ApiErrorMap.Classify(new InvalidOperationException("Sequence contains no elements at RosterRepository.cs:line 88"), Trace);

        Assert.Equal(500, error.Status);
        Assert.True(error.IsServerFault);
        Assert.DoesNotContain("Sequence", error.Message);
        Assert.Contains(Trace, error.Message);
    }

    [Fact]
    public void A_timeout_without_its_sql_exception_is_still_a_503()
    {
        var error = ApiErrorMap.Classify(new TimeoutException(), Trace);

        Assert.Equal((503, ApiErrorMap.DatabaseTimeout), (error.Status, error.Message));
    }
}
