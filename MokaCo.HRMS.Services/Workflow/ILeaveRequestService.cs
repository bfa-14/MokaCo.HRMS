using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>The caller's identity and right to raise for others, as resolved from the token.</summary>
public record LeaveRequestCaller(int UserId, int? EmployeeId, bool HasRaiseOthers);

public interface ILeaveRequestService
{
    /// <summary>
    /// Raises a leave request, enforcing WHO it may be raised FOR — the same rule as exit permissions,
    /// and for the same reason: the employee id is in the body, and the body is the caller's to write.
    ///
    /// The DATE OVERLAP refusal comes from the procedure and names the clashing dates. It is mapped to
    /// a 400 with its message intact, because that message is the entire value: "these dates overlap
    /// an existing leave request from … to … (Pending)" tells the user what to do next.
    /// </summary>
    Task<LeaveRequestCreated?> CreateAsync(LeaveRequestCreateRequest request, LeaveRequestCaller caller);

    /// <summary>
    /// Approves, optionally granting fewer days. The signature is verified FIRST, so a wrong password
    /// changes nothing at all — and who may approve stays the database's decision, surfaced verbatim.
    ///
    /// MakeDiscretionary rides along untouched: it asks for the leave to be granted without deducting
    /// it, and the result reports whether that is what happened.
    /// </summary>
    Task<LeaveRequestDecideResult?> DecideAsync(int requestInstanceId, int actedByUserId, LeaveRequestDecideRequest request);

    Task<LeaveRequestPayload?> GetPayloadAsync(int requestInstanceId);
    Task<IEnumerable<MyLeaveRequest>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate);
    Task<LeaveBalanceSummary?> GetBalanceAsync(int employeeId, int leaveTypeId);
}
