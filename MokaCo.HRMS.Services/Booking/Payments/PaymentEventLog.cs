using Microsoft.Extensions.Logging;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Booking;

namespace MokaCo.HRMS.Services.Booking.Payments;

/// <summary>
/// THE PAYMENT LOG (booking.PAYMENT_EVENT, script 119): one line per step of an online payment - opened, the
/// gateway asked and what it said, paid, released, refunded - for the Payments page.
///
/// WRITING IT NEVER BREAKS A PAYMENT. A line that cannot be written (the script is not applied yet, the database
/// hiccupped) is a warning in the server's log and nothing more: the money path does not depend on its own diary.
/// It never carries a key: only ids, amounts, the gateway's own words and ours.
/// </summary>
public interface IPaymentEventLog
{
    Task WriteAsync(PaymentEventEntry entry);
}

public sealed class PaymentEventLog : IPaymentEventLog
{
    private readonly IPaymentGatewayRepository _repository;
    private readonly ILogger<PaymentEventLog> _log;

    public PaymentEventLog(IPaymentGatewayRepository repository, ILogger<PaymentEventLog> log)
    {
        _repository = repository;
        _log = log;
    }

    public async Task WriteAsync(PaymentEventEntry entry)
    {
        try
        {
            await _repository.AddEventAsync(entry);
        }
        catch (Exception ex)
        {
            _log.LogWarning("Payment log: {Type} for {Ref} was not written ({Kind}).",
                entry.EventType, entry.BookingRef ?? entry.TestRef ?? entry.Gateway, ex.GetType().Name);
        }
    }
}

/// <summary>The words the log uses, in one place (the web app reads them back).</summary>
public static class PaymentEvents
{
    public const string Opened = "Opened";
    public const string OpenFailed = "OpenFailed";
    public const string Checked = "Checked";
    public const string Paid = "Paid";
    public const string Released = "Released";
    public const string Alerted = "Alerted";
    public const string Refunded = "Refunded";
    public const string RefundFailed = "RefundFailed";
    public const string ConnectionCheck = "ConnectionCheck";

    public const string FromWebsite = "Website";
    public const string FromReturn = "Return";
    public const string FromCallback = "Callback";
    public const string FromJob = "Job";
    public const string FromGuest = "Guest";
    public const string FromStaff = "Staff";

    public static string SourceOf(SettleTrigger trigger) => trigger switch
    {
        SettleTrigger.GatewayReturn => FromReturn,
        SettleTrigger.GatewayCallback => FromCallback,
        SettleTrigger.Reconciliation => FromJob,
        SettleTrigger.GuestRelease => FromGuest,
        SettleTrigger.StaffCheck => FromStaff,
        _ => FromWebsite,
    };
}
