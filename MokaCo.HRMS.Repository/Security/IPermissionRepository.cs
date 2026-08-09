using MokaCo.HRMS.Model.Security;

namespace MokaCo.HRMS.Repository.Security;

public interface IPermissionRepository
{
    Task<IEnumerable<Permission>> GetAllAsync();
}
