using MokaCo.HRMS.Model.Security;

namespace MokaCo.HRMS.Services.Security;

/// <summary>Thrown when an uploaded signature is the wrong type or too large. Carries a message fit to show the user.</summary>
public class SignatureValidationException : Exception
{
    public SignatureValidationException(string message) : base(message) { }
}

public interface IUserSignatureService
{
    Task<IEnumerable<UserSignatureInfo>> GetAllAsync();
    Task<UserSignatureImage?> GetImageAsync(int userId);

    /// <summary>Validates the bytes (type + size) before storing. Throws <see cref="SignatureValidationException"/> on a bad upload.</summary>
    Task<UserSignatureSaved?> UploadAsync(int userId, byte[] imageBytes, string? declaredContentType, string? fileName, int? updatedBy);

    Task<int> DeleteAsync(int userId);
}
