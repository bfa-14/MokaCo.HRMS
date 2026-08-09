using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Security;

/// <summary>
/// Dapper access for user signature images via the security.usp_UserSignature_* procedures.
///
/// The bytes are handled carefully: <see cref="GetAllAsync"/> reads only metadata, so a user grid
/// never moves image data; the bytes are read only by <see cref="GetImageAsync"/>, one image at a
/// time. Dapper maps a byte[] straight to the VARBINARY(MAX) parameter on upsert.
/// </summary>
public class UserSignatureRepository : IUserSignatureRepository
{
    private readonly IDbConnectionFactory _factory;
    public UserSignatureRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<UserSignatureInfo>> GetAllAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<UserSignatureInfo>(
            "security.usp_UserSignature_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<UserSignatureImage?> GetImageAsync(int userId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<UserSignatureImage>(
            "security.usp_UserSignature_GetImage",
            new { UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>The procedure itself rejects a wrong content type or empty bytes; those come back as a SQL error.</summary>
    public async Task<UserSignatureSaved?> UpsertAsync(int userId, byte[] imageBytes, string contentType, string? fileName, int? updatedBy)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<UserSignatureSaved>(
            "security.usp_UserSignature_Upsert",
            new
            {
                UserId = userId,
                ImageBytes = imageBytes,
                ContentType = contentType,
                FileName = fileName,
                UpdatedBy = updatedBy,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> DeleteAsync(int userId)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "security.usp_UserSignature_Delete",
            new { UserId = userId },
            commandType: CommandType.StoredProcedure);
    }
}
