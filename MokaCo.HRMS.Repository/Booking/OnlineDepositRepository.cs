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

    /// <summary>The same, for a method other than the card: its name goes on the payment line ("Whish").</summary>
    Task<OnlinePaymentRecorded?> ConfirmOnlinePaymentAsync(string bookingRef, decimal amount, string currency, string gatewayOrderId, string? transactionId,
        string methodName);

    /// <summary>Stamps PaymentCheckedUtc; <paramref name="keepHold"/> pushes the hold out so the slot is not offered while the outcome is unknown.</summary>
    Task PaymentCheckedAsync(string bookingRef, bool keepHold);

    Task SetPaymentSessionAsync(string bookingRef, string sessionId);

    /// <summary>One staff e-mail per booking per kind. False when not queued (already queued, or no BookingNotifyEmail).</summary>
    Task<bool> QueuePaymentAlertAsync(int bookingId, string kind, string? detail);

    Task<IReadOnlyList<PaymentToReconcile>> ListPaymentsToReconcileAsync(int openedMinutesAgo);

    /* ---- Whish (script 118) ---- */

    /// <summary>The next Whish attempt of a booking whose payment was just started; refusals as SqlException 50000.</summary>
    Task<WhishAttemptStarted?> StartWhishAttemptAsync(string bookingRef);

    /// <summary>After a paid Whish attempt was recorded: the payer's phone on the booking, the payment line named as Whish's.</summary>
    Task SetWhishPayerAsync(string bookingRef, string externalId, string? payerPhone);

    /// <summary>The setting BookingWhishEnabled. False on a database without it.</summary>
    Task<bool> IsWhishEnabledAsync();

    /* ---- the mode a payment was opened in (script 119) ---- */

    /// <summary>Notes in which mode ("test" | "live") the booking's payment was just opened. Nothing on a database without script 119.</summary>
    Task SetPaymentModeAsync(string bookingRef, string mode);

    /// <summary>The mode the booking's payment was opened in; null when unknown (an older payment, or a database without script 119).</summary>
    Task<string?> GetPaymentModeAsync(string bookingRef);
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

    public Task<OnlinePaymentRecorded?> ConfirmOnlinePaymentAsync(string bookingRef, decimal amount, string currency, string gatewayOrderId, string? transactionId)
        => ConfirmAsync(bookingRef, amount, currency, gatewayOrderId, transactionId, methodName: null);

    public Task<OnlinePaymentRecorded?> ConfirmOnlinePaymentAsync(string bookingRef, decimal amount, string currency, string gatewayOrderId, string? transactionId,
        string methodName)
        => ConfirmAsync(bookingRef, amount, currency, gatewayOrderId, transactionId, methodName);

    private async Task<OnlinePaymentRecorded?> ConfirmAsync(string bookingRef, decimal amount, string currency, string gatewayOrderId, string? transactionId,
        string? methodName)
    {
        using var db = _factory.Create();
        var args = new DynamicParameters(new
        {
            Ref = bookingRef,
            Amount = amount,
            CurrencyCode = currency,
            GatewayOrderId = gatewayOrderId,
            TransactionId = transactionId,
        });
        // The procedure's own default is the card's name; only another method names itself.
        if (methodName is not null) args.Add("MethodName", methodName);
        return await db.QuerySingleOrDefaultAsync<OnlinePaymentRecorded>(
            "booking.usp_Booking_ConfirmOnlinePayment", args, commandType: CommandType.StoredProcedure);
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

    /* ---- Whish (script 118) ---- */

    public Task<WhishAttemptStarted?> StartWhishAttemptAsync(string bookingRef)
        => MissingScriptException.GuardAsync(Scripts.BookingWhish118, "booking.usp_Booking_StartWhishAttempt", async () =>
        {
            using var db = _factory.Create();
            return await db.QuerySingleOrDefaultAsync<WhishAttemptStarted>(
                "booking.usp_Booking_StartWhishAttempt", new { Ref = bookingRef }, commandType: CommandType.StoredProcedure);
        });

    public Task SetWhishPayerAsync(string bookingRef, string externalId, string? payerPhone)
        => MissingScriptException.GuardAsync(Scripts.BookingWhish118, "booking.usp_Booking_SetWhishPayer", async () =>
        {
            using var db = _factory.Create();
            await db.ExecuteAsync(
                "booking.usp_Booking_SetWhishPayer",
                new { Ref = bookingRef, ExternalId = externalId, Phone = payerPhone is { Length: > 30 } ? payerPhone[..30] : payerPhone },
                commandType: CommandType.StoredProcedure);
        });

    public async Task<bool> IsWhishEnabledAsync()
    {
        using var db = _factory.Create();
        // In either dialect a switch is stored ('1' or 'true'); no row = off.
        var value = await db.QuerySingleOrDefaultAsync<string?>(
            "SELECT SettingValue FROM core.SETTING WHERE SettingKey = @Key", new { Key = "BookingWhishEnabled" });
        return value?.Trim().ToLowerInvariant() is "1" or "true";
    }

    /* ---- the mode a payment was opened in (script 119) ---- */

    public async Task SetPaymentModeAsync(string bookingRef, string mode)
    {
        try
        {
            using var db = _factory.Create();
            await db.ExecuteAsync("booking.usp_Booking_SetPaymentMode", new { Ref = bookingRef, Mode = mode }, commandType: CommandType.StoredProcedure);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (MissingScriptException.IsMissingObject(ex.Number))
        {
            // Without script 119 there is one mode, the server file's: nothing to note.
        }
    }

    public async Task<string?> GetPaymentModeAsync(string bookingRef)
    {
        try
        {
            using var db = _factory.Create();
            return await db.QuerySingleOrDefaultAsync<string?>("booking.usp_Booking_GetPaymentMode", new { Ref = bookingRef }, commandType: CommandType.StoredProcedure);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (MissingScriptException.IsMissingObject(ex.Number))
        {
            return null;
        }
    }
}
