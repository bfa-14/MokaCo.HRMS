using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Core;

namespace MokaCo.HRMS.Services.Core;

/// <summary>
/// A pass-through, and deliberately nothing more: every rule about whether this request may be
/// mailed lives in the procedure, beside the status and the address it reads. Re-checking any of it
/// here would be a second opinion that can disagree with the first.
/// </summary>
public class EmailService : IEmailService
{
    private readonly IEmailRepository _repo;
    public EmailService(IEmailRepository repo) => _repo = repo;

    public Task<QueuedEmail?> QueueForRequestAsync(int requestInstanceId, int? queuedByUserId)
        => _repo.QueueForRequestAsync(requestInstanceId, queuedByUserId);

    public Task<IEnumerable<RequestEmailStatus>> GetStatusForRequestAsync(int requestInstanceId)
        => _repo.GetStatusForRequestAsync(requestInstanceId);
}
