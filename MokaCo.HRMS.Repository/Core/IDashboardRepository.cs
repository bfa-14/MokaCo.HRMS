using MokaCo.HRMS.Model.Core;

namespace MokaCo.HRMS.Repository.Core;

public interface IDashboardRepository
{
    /// <summary>The signed-in user's whole home page, in one round trip.</summary>
    Task<Dashboard> GetAsync(int userId);
}
