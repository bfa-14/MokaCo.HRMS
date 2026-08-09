using MokaCo.HRMS.Model.Security;

namespace MokaCo.HRMS.Repository.Security;

public interface IUserSignatureRepository
{
    /// <summary>Who has a signature, with metadata — NO bytes.</summary>
    Task<IEnumerable<UserSignatureInfo>> GetAllAsync();

    /// <summary>One image WITH its bytes, for streaming. Null when the user has none.</summary>
    Task<UserSignatureImage?> GetImageAsync(int userId);

    Task<UserSignatureSaved?> UpsertAsync(int userId, byte[] imageBytes, string contentType, string? fileName, int? updatedBy);

    Task<int> DeleteAsync(int userId);
}
