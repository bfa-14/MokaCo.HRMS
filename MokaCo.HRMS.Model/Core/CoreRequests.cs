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

/// <summary>
/// PUT /api/exchange-rates/{id}.
///
/// THE PAIR AND THE TYPE ARE NOT EDITABLE. A rate row IS the answer to "what was Official USD→LBP
/// on this date"; letting the pair or the type move would not correct the row, it would silently
/// reassign it to a different question and leave the original unanswered. Only the figure and the
/// date it takes effect can change — anything else is a new row.
///
/// EffectiveDate null means "leave the date as it is", which is the common edit: a rate mistyped.
/// </summary>
public class ExchangeRateUpdateRequest
{
    public decimal Rate { get; set; }
    public DateTime? EffectiveDate { get; set; }
}
