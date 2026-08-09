using MokaCo.HRMS.Model.Core;

namespace MokaCo.HRMS.Services.Core;

public interface IDashboardService
{
    /// <summary>The signed-in user's whole home page. What they may see is decided in SQL.</summary>
    Task<Dashboard> GetAsync(int userId);
}
