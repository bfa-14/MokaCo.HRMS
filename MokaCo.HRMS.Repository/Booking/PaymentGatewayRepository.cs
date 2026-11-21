using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Booking;

/// <summary>
/// Script 119, through its procedures only: the gateways' mode and (encrypted) keys, the payment log, the payments
/// page's reads and the gateway tests. Nothing here can read a key: the cipher is opened by the API alone.
/// </summary>
public interface IPaymentGatewayRepository
{
    /* ---- the gateways ---- */
    Task<GatewayStore> GetGatewaysAsync();
    Task SaveKeysAsync(string gateway, string mode, byte[] keysCipher, int? userId);
    Task DeleteKeysAsync(string gateway, string mode, int? userId);
    Task SetModeAsync(string gateway, string? mode, int? userId);
    Task<IReadOnlyList<GatewayHistoryRow>> GetHistoryAsync(int top);

    /* ---- the log ---- */
    Task AddEventAsync(PaymentEventEntry entry);

    /* ---- the payments page ---- */
    Task<IReadOnlyList<PaymentRow>> ListPaymentsAsync(DateTime fromUtc, DateTime toUtc, string? gateway, string? state, string? search, int giveUpMinutes);
    Task<PaymentDetail?> GetPaymentAsync(int bookingId, int giveUpMinutes);

    /* ---- the gateway tests ---- */
    Task<GatewayTestRow?> AddTestAsync(string testRef, string gateway, string mode, decimal amount, string currency, string? returnUrl, int? userId);
    Task<GatewayTestRow?> UpdateTestAsync(string testRef, GatewayTestChange change);
    Task<GatewayTestDetail?> GetTestAsync(string testRef);
    Task<IReadOnlyList<GatewayTestRow>> ListTestsAsync(int top);
}

/// <summary>What to change on a gateway test: only what is given. The flags stamp their time once.</summary>
public sealed record GatewayTestChange(
    string? Status = null,
    string? GatewayStatus = null,
    string? Detail = null,
    string? PayUrl = null,
    string? PayerPhone = null,
    string? TransactionId = null,
    bool Checked = false,
    bool Callback = false,
    bool Returned = false,
    bool Refunded = false);

public class PaymentGatewayRepository : IPaymentGatewayRepository
{
    private const string Script = Scripts.PaymentGateways119;

    private readonly IDbConnectionFactory _factory;
    public PaymentGatewayRepository(IDbConnectionFactory factory) => _factory = factory;

    /* ---- the gateways ---------------------------------------------------------------------- */

    public Task<GatewayStore> GetGatewaysAsync()
        => MissingScriptException.GuardAsync(Script, "booking.usp_Gateway_Get", async () =>
        {
            using var db = _factory.Create();
            using var sets = await db.QueryMultipleAsync("booking.usp_Gateway_Get", commandType: CommandType.StoredProcedure);
            var modes = (await sets.ReadAsync<GatewayModeRow>()).ToList();
            var keys = (await sets.ReadAsync<GatewayKeysRow>()).ToList();
            return new GatewayStore(modes, keys);
        });

    public Task SaveKeysAsync(string gateway, string mode, byte[] keysCipher, int? userId)
        => MissingScriptException.GuardAsync(Script, "booking.usp_Gateway_SaveKeys", async () =>
        {
            using var db = _factory.Create();
            var args = new DynamicParameters(new { Gateway = gateway, Mode = mode, UserId = userId });
            args.Add("KeysCipher", keysCipher, DbType.Binary, size: 4000);
            await db.ExecuteAsync("booking.usp_Gateway_SaveKeys", args, commandType: CommandType.StoredProcedure);
        });

    public Task DeleteKeysAsync(string gateway, string mode, int? userId)
        => MissingScriptException.GuardAsync(Script, "booking.usp_Gateway_DeleteKeys", async () =>
        {
            using var db = _factory.Create();
            await db.ExecuteAsync("booking.usp_Gateway_DeleteKeys", new { Gateway = gateway, Mode = mode, UserId = userId },
                commandType: CommandType.StoredProcedure);
        });

    public Task SetModeAsync(string gateway, string? mode, int? userId)
        => MissingScriptException.GuardAsync(Script, "booking.usp_Gateway_SetMode", async () =>
        {
            using var db = _factory.Create();
            await db.ExecuteAsync("booking.usp_Gateway_SetMode", new { Gateway = gateway, Mode = mode, UserId = userId },
                commandType: CommandType.StoredProcedure);
        });

    public Task<IReadOnlyList<GatewayHistoryRow>> GetHistoryAsync(int top)
        => MissingScriptException.GuardAsync(Script, "booking.usp_Gateway_History", async () =>
        {
            using var db = _factory.Create();
            var rows = await db.QueryAsync<GatewayHistoryRow>("booking.usp_Gateway_History", new { Top = top }, commandType: CommandType.StoredProcedure);
            return (IReadOnlyList<GatewayHistoryRow>)rows.ToList();
        });

    /* ---- the log --------------------------------------------------------------------------- */

    public Task AddEventAsync(PaymentEventEntry entry)
        => MissingScriptException.GuardAsync(Script, "booking.usp_PaymentEvent_Add", async () =>
        {
            using var db = _factory.Create();
            await db.ExecuteAsync("booking.usp_PaymentEvent_Add", new
            {
                entry.Gateway,
                entry.EventType,
                entry.Source,
                entry.BookingRef,
                entry.TestRef,
                entry.Mode,
                entry.GatewayOrderId,
                entry.Outcome,
                GatewayStatus = Cut(entry.GatewayStatus, 80),
                Detail = Cut(entry.Detail, 400),
                entry.Amount,
                entry.CurrencyCode,
                entry.UserId,
            }, commandType: CommandType.StoredProcedure);
        });

    /* ---- the payments page ----------------------------------------------------------------- */

    public Task<IReadOnlyList<PaymentRow>> ListPaymentsAsync(DateTime fromUtc, DateTime toUtc, string? gateway, string? state, string? search, int giveUpMinutes)
        => MissingScriptException.GuardAsync(Script, "booking.usp_Payment_List", async () =>
        {
            using var db = _factory.Create();
            var rows = await db.QueryAsync<PaymentRow>("booking.usp_Payment_List",
                new { FromUtc = fromUtc, ToUtc = toUtc, Gateway = gateway, State = state, Search = Cut(search, 60), GiveUpMinutes = giveUpMinutes },
                commandType: CommandType.StoredProcedure);
            return (IReadOnlyList<PaymentRow>)rows.ToList();
        });

    public Task<PaymentDetail?> GetPaymentAsync(int bookingId, int giveUpMinutes)
        => MissingScriptException.GuardAsync(Script, "booking.usp_Payment_Get", async () =>
        {
            using var db = _factory.Create();
            using var sets = await db.QueryMultipleAsync("booking.usp_Payment_Get",
                new { BookingId = bookingId, GiveUpMinutes = giveUpMinutes }, commandType: CommandType.StoredProcedure);
            var payment = await sets.ReadSingleOrDefaultAsync<PaymentRow>();
            var events = (await sets.ReadAsync<PaymentEventRow>()).ToList();
            var lines = (await sets.ReadAsync<PaymentLineRow>()).ToList();
            return payment is null ? null : new PaymentDetail(payment, events, lines);
        });

    /* ---- the gateway tests ----------------------------------------------------------------- */

    public Task<GatewayTestRow?> AddTestAsync(string testRef, string gateway, string mode, decimal amount, string currency, string? returnUrl, int? userId)
        => MissingScriptException.GuardAsync(Script, "booking.usp_GatewayTest_Add", async () =>
        {
            using var db = _factory.Create();
            return await db.QuerySingleOrDefaultAsync<GatewayTestRow>("booking.usp_GatewayTest_Add",
                new { TestRef = testRef, Gateway = gateway, Mode = mode, Amount = amount, CurrencyCode = currency, ReturnUrl = Cut(returnUrl, 300), UserId = userId },
                commandType: CommandType.StoredProcedure);
        });

    public Task<GatewayTestRow?> UpdateTestAsync(string testRef, GatewayTestChange change)
        => MissingScriptException.GuardAsync(Script, "booking.usp_GatewayTest_Update", async () =>
        {
            using var db = _factory.Create();
            return await db.QuerySingleOrDefaultAsync<GatewayTestRow>("booking.usp_GatewayTest_Update", new
            {
                TestRef = testRef,
                change.Status,
                GatewayStatus = Cut(change.GatewayStatus, 80),
                Detail = Cut(change.Detail, 400),
                PayUrl = Cut(change.PayUrl, 600),
                PayerPhone = Cut(change.PayerPhone, 30),
                TransactionId = Cut(change.TransactionId, 60),
                change.Checked,
                change.Callback,
                change.Returned,
                change.Refunded,
            }, commandType: CommandType.StoredProcedure);
        });

    public Task<GatewayTestDetail?> GetTestAsync(string testRef)
        => MissingScriptException.GuardAsync(Script, "booking.usp_GatewayTest_Get", async () =>
        {
            using var db = _factory.Create();
            using var sets = await db.QueryMultipleAsync("booking.usp_GatewayTest_Get", new { TestRef = testRef }, commandType: CommandType.StoredProcedure);
            var test = await sets.ReadSingleOrDefaultAsync<GatewayTestRow>();
            var events = (await sets.ReadAsync<PaymentEventRow>()).ToList();
            return test is null ? null : new GatewayTestDetail(test, events);
        });

    public Task<IReadOnlyList<GatewayTestRow>> ListTestsAsync(int top)
        => MissingScriptException.GuardAsync(Script, "booking.usp_GatewayTest_List", async () =>
        {
            using var db = _factory.Create();
            var rows = await db.QueryAsync<GatewayTestRow>("booking.usp_GatewayTest_List", new { Top = top }, commandType: CommandType.StoredProcedure);
            return (IReadOnlyList<GatewayTestRow>)rows.ToList();
        });

    private static string? Cut(string? text, int length)
        => text is { } value && value.Length > length ? value[..length] : text;
}
