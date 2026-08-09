using MokaCo.HRMS.Model.Core;

namespace MokaCo.HRMS.Services.Core;

public interface ISettingService
{
    Task<IEnumerable<Setting>> GetAllAsync();
    Task<Setting?> GetAsync(string settingKey);
    Task UpsertAsync(string settingKey, SettingUpsertRequest request, int? modifiedBy);
}
