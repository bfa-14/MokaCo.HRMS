using MokaCo.HRMS.Model.Core;

namespace MokaCo.HRMS.Repository.Core;

public interface ISettingRepository
{
    Task<IEnumerable<Setting>> GetAllAsync();
    Task<Setting?> GetAsync(string settingKey);
    Task UpsertAsync(string settingKey, string settingValue, string dataType, string? description, int? modifiedBy);
}
