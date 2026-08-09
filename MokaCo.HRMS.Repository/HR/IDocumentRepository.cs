using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface IDocumentRepository
{
    Task<IEnumerable<Document>> GetByEmployeeAsync(int employeeId);
    Task<Document?> GetByIdAsync(int documentId);
    Task<int> CreateAsync(int employeeId, string fileName, string storagePath, string contentType, long sizeBytes);
    Task DeleteAsync(int documentId);
}
