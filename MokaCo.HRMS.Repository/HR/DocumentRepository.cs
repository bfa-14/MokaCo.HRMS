using System.Data;
using Dapper;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>Dapper access for employee documents via the hr.usp_Document_* stored procedures.</summary>
public class DocumentRepository : IDocumentRepository
{
    private readonly IDbConnectionFactory _factory;
    public DocumentRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<Document>> GetByEmployeeAsync(int employeeId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<Document>(
            "hr.usp_Document_GetByEmployee",
            new { EmployeeId = employeeId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<Document?> GetByIdAsync(int documentId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<Document>(
            "hr.usp_Document_GetById",
            new { DocumentId = documentId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(int employeeId, string fileName, string storagePath, string contentType, long sizeBytes)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "hr.usp_Document_Create",
            new
            {
                EmployeeId = employeeId,
                FileName = fileName,
                StoragePath = storagePath,
                ContentType = contentType,
                SizeBytes = sizeBytes
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int documentId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_Document_Delete",
            new { DocumentId = documentId },
            commandType: CommandType.StoredProcedure);
    }
}
