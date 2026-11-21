using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Workflow;
using Moq;

namespace MokaCo.HRMS.Tests.Attendance;

/// <summary>
/// Script 117: a shift's hours are dated. The service passes the dates and who asked to the procedure (which owns
/// the rules: paid days, the days derived again) and refuses what cannot be a period before the database is asked.
/// </summary>
public class ShiftServiceTests
{
    private const int Caller = 42;

    private static ShiftUpdateRequest Hours(DateOnly? from = null, DateOnly? to = null, string? note = null) => new()
    {
        Name = "AM Shift", StartTime = new TimeSpan(8, 0, 0), EndTime = new TimeSpan(16, 0, 0), BreakMinutes = 30, IsActive = true,
        EffectiveFrom = from, EffectiveTo = to, Note = note,
    };

    [Fact]
    public async Task New_hours_go_to_the_procedure_with_their_dates_note_and_who_asked()
    {
        var repo = new Mock<IShiftRepository>(MockBehavior.Strict);
        repo.Setup(r => r.UpdateAsync(5, "AM Shift", new TimeSpan(8, 0, 0), new TimeSpan(16, 0, 0), null, false, 30, true,
                new DateOnly(2026, 12, 1), new DateOnly(2026, 12, 31), "Winter hours", Caller))
            .Returns(Task.CompletedTask);

        await new ShiftService(repo.Object).UpdateAsync(5, Hours(new DateOnly(2026, 12, 1), new DateOnly(2026, 12, 31), "  Winter hours "), Caller);

        repo.VerifyAll();
    }

    [Fact]
    public async Task Without_dates_the_procedure_decides_from_when()
    {
        var repo = new Mock<IShiftRepository>(MockBehavior.Strict);
        repo.Setup(r => r.UpdateAsync(5, "AM Shift", new TimeSpan(8, 0, 0), new TimeSpan(16, 0, 0), null, false, 30, true, null, null, null, Caller))
            .Returns(Task.CompletedTask);

        await new ShiftService(repo.Object).UpdateAsync(5, Hours(note: "   "), Caller);

        repo.VerifyAll();
    }

    [Fact]
    public async Task A_period_that_ends_before_it_starts_or_has_no_start_is_refused_before_the_database()
    {
        var service = new ShiftService(new Mock<IShiftRepository>(MockBehavior.Strict).Object);

        var backwards = await Assert.ThrowsAsync<WorkflowException>(() => service.UpdateAsync(5, Hours(new DateOnly(2026, 12, 10), new DateOnly(2026, 12, 9)), Caller));
        Assert.Equal(400, backwards.StatusCode);
        Assert.Contains("before their first day", backwards.Message);

        var noStart = await Assert.ThrowsAsync<WorkflowException>(() => service.UpdateAsync(5, Hours(to: new DateOnly(2026, 12, 9)), Caller));
        Assert.Equal(400, noStart.StatusCode);

        var longNote = await Assert.ThrowsAsync<WorkflowException>(() => service.UpdateAsync(5, Hours(note: new string('x', 201)), Caller));
        Assert.Equal(400, longNote.StatusCode);
    }

    [Fact]
    public async Task Taking_a_change_back_says_how_many_days_were_derived_again()
    {
        var repo = new Mock<IShiftRepository>(MockBehavior.Strict);
        repo.Setup(r => r.DeleteHoursAsync(9, Caller)).ReturnsAsync(12);

        var result = await new ShiftService(repo.Object).DeleteHoursAsync(9, Caller);

        Assert.Equal(12, result.DaysRederived);
    }
}
