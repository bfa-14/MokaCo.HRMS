using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Booking;

/// <summary>
/// Online deposits (SQL 88), through the booking.usp_* procedures only. Refusals travel as
/// SqlException 50000 with a sentence the API maps to a code (BookingRefusals), like every other
/// booking procedure. Releasing a hold is NOT here: it is the existing path,
/// <see cref="IBookingRepository.ReleaseHoldAsync"/>.
/// </summary>
public interface IOnlineDepositRepository
{
    /// <summary>Validates and stamps the hold + PaymentOpenedUtc in one transaction. Refuses not found / not pending / hold expired / already paid / nothing due.</summary>
    Task<PaymentStarted?> StartPaymentAsync(string bookingRef);

    Task<PaymentState?> GetPaymentStateAsync(string bookingRef);

    /// <summary>Records the deposit and confirms. IDEMPOTENT: a second call for the same order is 'Replay' and writes nothing.</summary>
    Task<OnlinePaymentRecorded?> ConfirmOnlinePaymentAsync(string bookingRef, decimal amount, string currency, string gatewayOrderId, string? transactionId);

    /// <summary>Stamps PaymentCheckedUtc; <paramref name="keepHold"/> pushes the hold out so the slot is not offered while the outcome is unknown.</summary>
    Task PaymentCheckedAsync(string bookingRef, bool keepHold);

    Task SetPaymentSessionAsync(string bookingRef, string sessionId);

    /// <summary>One staff e-mail per booking per kind. False when not queued (already queued, or no BookingNotifyEmail).</summary>
    Task<bool> QueuePaymentAlertAsync(int bookingId, string kind, string? detail);

    Task<IReadOnlyList<PaymentToReconcile>> ListPaymentsToReconcileAsync(int openedMinutesAgo);
}

public class OnlineDepositRepository : IOnlineDepositRepository
{
    private readonly IDbConnectionFactory _factory;
    public OnlineDepositRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<PaymentStarted?> StartPaymentAsync(string bookingRef)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PaymentStarted>(
            "booking.usp_Booking_StartPayment", new { Ref = bookingRef }, commandType: CommandType.StoredProcedure);
    }

    public async Task<PaymentState?> GetPaymentStateAsync(string bookingRef)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PaymentState>(
            "booking.usp_Booking_GetPaymentState", new { Ref = bookingRef }, commandType: CommandType.StoredProcedure);
    }

    public async Task<OnlinePaymentRecorded?> ConfirmOnlinePaymentAsync(string bookingRef, decimal amount, string currency, string gatewayOrderId, string? transactionId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<OnlinePaymentRecorded>(
            "booking.usp_Booking_ConfirmOnlinePayment",
            new
            {
                Ref = bookingRef,
                Amount = amount,
                CurrencyCode = currency,
                GatewayOrderId = gatewayOrderId,
                TransactionId = transactionId,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task PaymentCheckedAsync(string bookingRef, bool keepHold)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "booking.usp_Booking_PaymentChecked", new { Ref = bookingRef, KeepHold = keepHold }, commandType: CommandType.StoredProcedure);
    }

    public async Task SetPaymentSessionAsync(string bookingRef, string sessionId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "booking.usp_Booking_SetPaymentSession", new { Ref = bookingRef, SessionId = sessionId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<bool> QueuePaymentAlertAsync(int bookingId, string kind, string? detail)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<bool>(
            "booking.usp_Booking_QueuePaymentAlert",
            new { BookingId = bookingId, Kind = kind, Detail = detail },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<PaymentToReconcile>> ListPaymentsToReconcileAsync(int openedMinutesAgo)
    {
        using var db = _factory.Create();
        var rows = await db.QueryAsync<PaymentToReconcile>(
            "booking.usp_Booking_ListPaymentsToReconcile", new { OpenedMinutesAgo = openedMinutesAgo }, commandType: CommandType.StoredProcedure);
        return rows.ToList();
    }
}
