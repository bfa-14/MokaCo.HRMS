namespace MokaCo.HRMS.Model.Core;

/// <summary>Maps to core.CURRENCY. A currency the system understands; money is always amount + currency.</summary>
public class Currency
{
    public string CurrencyCode { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public int DecimalPlaces { get; set; }
}
