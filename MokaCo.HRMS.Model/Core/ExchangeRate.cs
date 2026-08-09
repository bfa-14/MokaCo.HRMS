namespace MokaCo.HRMS.Model.Core;

/// <summary>Maps to core.EXCHANGE_RATE. A time-stamped rate for a currency pair + rate type.</summary>
public class ExchangeRate
{
    public int ExchangeRateId { get; set; }
    public string FromCurrency { get; set; } = string.Empty;
    public string ToCurrency { get; set; } = string.Empty;
    public string RateType { get; set; } = string.Empty;
    public DateTime EffectiveDate { get; set; }
    public decimal Rate { get; set; }
}
