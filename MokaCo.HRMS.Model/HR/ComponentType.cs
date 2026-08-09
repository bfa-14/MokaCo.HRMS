namespace MokaCo.HRMS.Model.HR;

/// <summary>Maps to hr.COMPONENT_TYPE. A pay component catalogue entry (Category + Sign).</summary>
public class ComponentType
{
    public int ComponentTypeId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;   // Earning / Deduction
    public short Sign { get; set; }                         // +1 / -1
}
