using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Repository.Booking;
using MokaCo.HRMS.Services.Booking.Payments;
using Quartz;

namespace MokaCo.HRMS.Api.Jobs;

/// <summary>
/// Every OnlineDeposits:ReconcileEveryMinutes (5): settles the online deposits whose return trip
/// never arrived — the guest closed the tab on the gateway's page, lost the connection, or the
/// gateway timed out. For each Pending booking whose payment was opened at least
/// ReconcileAfterMinutes ago with no payment line, it asks the gateway (RETRIEVE_ORDER) and settles
/// through THE SAME PATH AS /verify (<see cref="IOnlineDepositService.SettleAsync"/>):
///
///   paid         → recorded and confirmed, the guest's confirmation queued, the hub told;
///   abandoned    (the gateway does not know the order, or it carries no transaction) → released once
///                the hold has run out; until then the hold is left as it is and the next run looks again;
///   failed       → released once GiveUpAfterMinutes have passed (the guest may be retrying before);
///   cannot tell  (a transaction not settled, a network error, a timeout — never abandonment) → the hold
///                is kept alive, the next run asks again, and past GiveUpAfterMinutes staff get ONE e-mail.
///
/// NO WEBHOOKS: the gateway is asked, never listened to. This is also what makes the hold-expiry
/// sweep safe (SQL 88): the sweep leaves every booking whose payment was opened to this job.
/// One booking's failure is logged and does not stop the others.
/// </summary>
[DisallowConcurrentExecution]
public class BookingPaymentReconcileJob : IJob
{
    private readonly IOnlineDepositRepository _deposits;
    private readonly IOnlineDepositService _settle;
    private readonly IBookingLivePublisher _live;
    private readonly OnlineDepositOptions _timing;
    private readonly ILogger<BookingPaymentReconcileJob> _logger;

    public BookingPaymentReconcileJob(IOnlineDepositRepository deposits, IOnlineDepositService settle, IBookingLivePublisher live,
        OnlineDepositOptions timing, ILogger<BookingPaymentReconcileJob> logger)
    {
        _deposits = deposits;
        _settle = settle;
        _live = live;
        _timing = timing;
        _logger = logger;
    }

    public async Task Execute(IJobExecutionContext context)
    {
        var due = await _deposits.ListPaymentsToReconcileAsync(_timing.ReconcileAfterMinutes);

        // Silent on the ordinary outcome, like the hold-expiry sweep: most runs have nothing to do.
        foreach (var payment in due)
        {
            if (context.CancellationToken.IsCancellationRequested)
                break;

            try
            {
                var settled = await _settle.SettleAsync(payment.BookingRef, SettleTrigger.Reconciliation, context.CancellationToken);
                if (settled.Changed)
                {
                    await _live.PublishAsync(payment.BookingRef);
                    _logger.LogInformation("Deposit reconciliation: {Ref} {Result} ({Reason}).", payment.BookingRef, settled.Result, settled.Reason);
                }
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Deposit reconciliation: {Ref} could not be settled; retried next run.", payment.BookingRef);
            }
        }
    }
}
