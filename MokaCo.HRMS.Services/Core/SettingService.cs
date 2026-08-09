using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Core;

namespace MokaCo.HRMS.Services.Core;

/// <summary>
/// Global policy values. Small surface, large blast radius: changing StandardWorkDayHours changes
/// what a full day means for everyone, and changing ExitLeaveBasis changes whether people are
/// docked for the leave they took or the leave they were granted.
/// </summary>
public class SettingService : ISettingService
{
    private readonly ISettingRepository _repo;
    public SettingService(ISettingRepository repo) => _repo = repo;

    public Task<IEnumerable<Setting>> GetAllAsync() => _repo.GetAllAsync();

    public Task<Setting?> GetAsync(string settingKey) => _repo.GetAsync(settingKey);

    public Task UpsertAsync(string settingKey, SettingUpsertRequest request, int? modifiedBy)
        => _repo.UpsertAsync(settingKey, request.SettingValue, request.DataType, request.Description, modifiedBy);
}
