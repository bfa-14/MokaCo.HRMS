namespace MokaCo.HRMS.Model.Core;

/// <summary>Insert or update a currency (upsert on the CHAR(3) code).</summary>
public class CurrencyUpsertRequest
{
    public string CurrencyCode { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public int DecimalPlaces { get; set; }
}

/// <summary>Add a new exchange-rate row.</summary>
public class ExchangeRateCreateRequest
{
    public string FromCurrency { get; set; } = string.Empty;
    public string ToCurrency { get; set; } = string.Empty;
    public string RateType { get; set; } = string.Empty;
    public DateTime EffectiveDate { get; set; }
    public decimal Rate { get; set; }
}
