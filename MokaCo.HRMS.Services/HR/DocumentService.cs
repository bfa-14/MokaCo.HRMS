using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;

namespace MokaCo.HRMS.Services.HR;

/// <summary>Employee-document administration (thin wrapper over the repository).</summary>
public class DocumentService : IDocumentService
{
    private readonly IDocumentRepository _repo;
    public DocumentService(IDocumentRepository repo) => _repo = repo;

    public Task<IEnumerable<Document>> GetByEmployeeAsync(int employeeId)
        => _repo.GetByEmployeeAsync(employeeId);

    public Task<Document?> GetByIdAsync(int documentId)
        => _repo.GetByIdAsync(documentId);

    public Task<int> CreateAsync(DocumentCreateRequest request)
        => _repo.CreateAsync(
            request.EmployeeId, request.FileName, request.StoragePath,
            request.ContentType, request.SizeBytes);

    public Task DeleteAsync(int documentId) => _repo.DeleteAsync(documentId);
}
