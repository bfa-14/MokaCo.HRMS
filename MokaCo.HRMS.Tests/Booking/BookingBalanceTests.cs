using Moq;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Booking;
using MokaCo.HRMS.Repository.Core;
using MokaCo.HRMS.Services.Booking;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// QA3 BKG-8: a Cancelled or No-show booking owes NOTHING. The procedures compute BalanceDue as
/// TotalAmount − PaidAmount with PaidAmount net of refunds, so a cancelled booking whose deposit was
/// refunded showed a "balance due" that GREW with every refund, and its receipt printed BALANCE DUE.
/// Every way a balance leaves the API now says 0 for those two statuses: the calendar rows, the staff
/// detail, the receipt, the guest's recap (and the live guest message, in BookingHubTests).
/// </summary>
public class BookingBalanceTests
{
    [Theory]
    [InlineData("Cancelled", 40, 0)]
    [InlineData("NoShow", 40, 0)]
    [InlineData("noshow", 12.5, 0)]
    [InlineData("Pending", 40, 40)]
    [InlineData("Confirmed", 28, 28)]
    [InlineData("Completed", 0, 0)]
    public void Only_a_booking_that_happened_or_will_happen_owes_its_balance(string status, decimal computed, decimal owed)
        => Assert.Equal(owed, BookingBalance.Owed(status, computed));

    private static BookingService Service(Mock<IBookingRepository> bookings)
        => new(bookings.Object, Mock.Of<IRoomRepository>(), Mock.Of<ISettingRepository>());

    /// <summary>The reviewer's case: total 40, deposit 8 paid then refunded — PaidAmount 0, so the procedure says 40 "due".</summary>
    private static BookingRefDetail CancelledAndRefunded() => new()
    {
        BookingId = 7, BookingRef = "MC-1A2B3C4D", Status = "Cancelled", TotalAmount = 40, DepositDue = 8,
        PaidAmount = 0, RefundedAmount = 8, BalanceDue = 40, RefundAmount = 8, RefundStatus = "Refunded", CurrencyCode = "USD",
    };

    [Fact]
    public async Task The_calendar_rows_of_a_cancelled_or_no_show_booking_owe_nothing()
    {
        var bookings = new Mock<IBookingRepository>();
        bookings.Setup(b => b.GetForRangeAsync(It.IsAny<DateTime>(), It.IsAny<DateTime>(), null, null)).ReturnsAsync(new BookingRange
        {
            Bookings =
            [
                new BookingRow { BookingId = 1, Status = "Cancelled", TotalAmount = 40, PaidAmount = 0, BalanceDue = 40 },
                new BookingRow { BookingId = 2, Status = "NoShow", TotalAmount = 40, PaidAmount = 8, BalanceDue = 32 },
                new BookingRow { BookingId = 3, Status = "Confirmed", TotalAmount = 40, PaidAmount = 8, BalanceDue = 32 },
            ],
        });

        var range = await Service(bookings).GetForRangeAsync(new DateTime(2026, 11, 1), new DateTime(2026, 11, 7), null, null);

        Assert.Equal([0m, 0m, 32m], range.Bookings.Select(b => b.BalanceDue));
    }

    [Fact]
    public async Task The_staff_detail_and_the_receipt_of_a_cancelled_booking_owe_nothing()
    {
        var bookings = new Mock<IBookingRepository>();
        bookings.Setup(b => b.GetReceiptAsync(7)).ReturnsAsync(new BookingReceipt
        {
            Header = new ReceiptHeader { BookingId = 7, BookingRef = "MC-1A2B3C4D", Status = "Cancelled", TotalAmount = 40, PaidAmount = 0, BalanceDue = 40 },
        });
        bookings.Setup(b => b.GetByRefAsync("MC-1A2B3C4D")).ReturnsAsync(CancelledAndRefunded());
        var service = Service(bookings);

        var detail = await service.GetStaffDetailAsync(7);
        var receipt = await service.GetReceiptAsync(7);

        Assert.Equal(0m, detail!.Booking.BalanceDue);
        Assert.Equal(0m, receipt.Header!.BalanceDue);
        Assert.Equal(("Refunded", 8m), (detail.Booking.RefundStatus, detail.Booking.RefundAmount));   // the refund position is untouched
    }

    [Fact]
    public async Task The_guests_recap_of_a_cancelled_booking_owes_nothing()
    {
        var bookings = new Mock<IBookingRepository>();
        bookings.Setup(b => b.GetByRefAsync("MC-1A2B3C4D")).ReturnsAsync(CancelledAndRefunded());

        var recap = await Service(bookings).GetPublicRecapAsync("MC-1A2B3C4D");

        Assert.Equal(0m, recap!.Balance);
        Assert.Equal(0m, recap.Paid);
    }

    [Fact]
    public async Task A_live_booking_keeps_its_balance()
    {
        var bookings = new Mock<IBookingRepository>();
        var row = CancelledAndRefunded();
        row.Status = "Confirmed"; row.PaidAmount = 8; row.BalanceDue = 32; row.RefundStatus = "None";
        bookings.Setup(b => b.GetByRefAsync("MC-1A2B3C4D")).ReturnsAsync(row);

        Assert.Equal(32m, (await Service(bookings).GetPublicRecapAsync("MC-1A2B3C4D"))!.Balance);
    }
}
