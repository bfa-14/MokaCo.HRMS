using MokaCo.HRMS.Model.Security;

namespace MokaCo.HRMS.Services.Security;

public interface IUserService
{
    Task<IEnumerable<UserListItem>> GetAllAsync();
    Task<IEnumerable<UserListItem>> GetUnlinkedAsync();
    Task<int> CreateAsync(CreateUserRequest request, int createdBy);
    Task SetActiveAsync(int userId, bool isActive, int modifiedBy);
}
