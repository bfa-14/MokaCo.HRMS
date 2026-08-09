using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Services.Auth;

namespace MokaCo.HRMS.Services.Security;

/// <summary>Admin user management (no public registration). Hashes the password here.</summary>
public class UserService : IUserService
{
    private readonly IUserRepository _users;
    private readonly IPasswordHasher _hasher;

    public UserService(IUserRepository users, IPasswordHasher hasher)
    {
        _users = users; _hasher = hasher;
    }

    public Task<IEnumerable<UserListItem>> GetAllAsync() => _users.GetAllAsync();

    public Task<IEnumerable<UserListItem>> GetUnlinkedAsync() => _users.GetUnlinkedAsync();

    public async Task<int> CreateAsync(CreateUserRequest request, int createdBy)
    {
        var hash = _hasher.Hash(request.Password);
        var userId = await _users.CreateAsync(request.Username, hash, request.IsActive, createdBy);
        foreach (var roleId in request.RoleIds)
            await _users.AssignRoleAsync(userId, roleId, createdBy);
        return userId;
    }

    public Task SetActiveAsync(int userId, bool isActive, int modifiedBy)
        => _users.SetActiveAsync(userId, isActive, modifiedBy).ContinueWith(_ => { });
}
