using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface IDocumentService
{
    Task<IEnumerable<Document>> GetByEmployeeAsync(int employeeId);
    Task<Document?> GetByIdAsync(int documentId);
    Task<int> CreateAsync(DocumentCreateRequest request);
    Task DeleteAsync(int documentId);
}
