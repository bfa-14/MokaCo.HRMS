namespace MokaCo.HRMS.Model.HR;

/// <summary>Maps to hr.[POSITION]. A job title assigned to employees.</summary>
public class Position
{
    public int PositionId { get; set; }
    public string Title { get; set; } = string.Empty;
    public bool IsActive { get; set; }
}
