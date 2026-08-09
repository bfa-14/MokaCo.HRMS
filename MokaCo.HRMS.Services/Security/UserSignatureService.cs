using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Security;

namespace MokaCo.HRMS.Services.Security;

/// <summary>
/// User signature images. This is the layer that decides whether an upload is ACCEPTABLE before it
/// is stored — the type and the size — because those are policy, not data access.
///
/// The content type is determined from the FILE'S OWN BYTES, not from what the browser claimed.
/// A caller can label a .exe as image/png; the magic-number sniff is what stops a non-image being
/// stored and then streamed back with an image content type. The size cap protects the database and
/// every future page that renders the thumbnail.
/// </summary>
public class UserSignatureService : IUserSignatureService
{
    /// <summary>1 MB. A signature is a small line drawing; anything larger is a photo pasted by mistake, and it would bloat every grid that shows the thumbnail.</summary>
    private const int MaxBytes = 1024 * 1024;

    private readonly IUserSignatureRepository _repo;
    public UserSignatureService(IUserSignatureRepository repo) => _repo = repo;

    public Task<IEnumerable<UserSignatureInfo>> GetAllAsync() => _repo.GetAllAsync();

    public Task<UserSignatureImage?> GetImageAsync(int userId) => _repo.GetImageAsync(userId);

    public Task<UserSignatureSaved?> UploadAsync(int userId, byte[] imageBytes, string? declaredContentType, string? fileName, int? updatedBy)
    {
        if (imageBytes.Length == 0)
            throw new SignatureValidationException("The uploaded file is empty.");

        if (imageBytes.Length > MaxBytes)
            throw new SignatureValidationException(
                $"The image is {imageBytes.Length / 1024} KB. A signature must be 1 MB or smaller — a transparent PNG of a signature is usually only a few KB.");

        // Sniff the real type from the bytes. A browser-supplied content type is a hint the caller
        // controls; the magic number is the file telling the truth about itself.
        var contentType = SniffImageType(imageBytes)
            ?? throw new SignatureValidationException(
                "That is not a PNG, JPEG, GIF or WEBP image. Save the signature as one of those and try again.");

        _ = declaredContentType; // intentionally ignored — see above.

        return _repo.UpsertAsync(userId, imageBytes, contentType, fileName, updatedBy);
    }

    public Task<int> DeleteAsync(int userId) => _repo.DeleteAsync(userId);

    /// <summary>
    /// The image content type from the file's magic number, or null if it is not one of the four
    /// allowed formats. This is what makes the type check trustworthy: it reads what the file IS.
    /// </summary>
    private static string? SniffImageType(byte[] b)
    {
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if (b.Length >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47
            && b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A)
            return "image/png";

        // JPEG: FF D8 FF
        if (b.Length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF)
            return "image/jpeg";

        // GIF: "GIF87a" or "GIF89a"
        if (b.Length >= 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38
            && (b[4] == 0x37 || b[4] == 0x39) && b[5] == 0x61)
            return "image/gif";

        // WEBP: "RIFF"...."WEBP"
        if (b.Length >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
            && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50)
            return "image/webp";

        return null;
    }
}
