using Dapper;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Repository.Common;
using MokaCo.HRMS.Repository.Workflow;
using MokaCo.HRMS.Services.Workflow;
using MokaCo.HRMS.Tests.Attendance;

namespace MokaCo.HRMS.Tests.Workflow;

/// <summary>
/// QA3 unit A against the database the API uses (docs/101_qa3_workflow.sql applied): the parameters the
/// repository now sends — @ExpectedStepNo, @SignedWithPassword on the reopen, @ConfirmClose, the
/// delegate-candidates read — are ones the procedures have, and the reconciler's sweep still compiles
/// with its new overtime and exit-permission arms. The calls use a request id that does not exist, so
/// every procedure refuses before it writes anything; what is proved is that the call binds (an
/// unknown parameter would be error 8145, not the procedure's own sentence). Skipped, with the reason,
/// when the database is not reachable.
/// </summary>
public class WorkflowRepositoryContractDbTests
{
    private static RequestRepository Repo() => new(new SqlConnectionFactory(DbFactAttribute.ConnectionString));

    private static async Task<string> RefusalOf(Func<Task> call)
    {
        var ex = await Assert.ThrowsAsync<SqlException>(call);
        Assert.Equal(50000, ex.Number);
        return ex.Errors[0].Message;
    }

    [DbFact]
    public async Task Approve_binds_the_expected_step()
        => Assert.Equal("Request not found.", await RefusalOf(
            () => Repo().ApproveAsync(-1, -1, null, null, signedWithPassword: false, expectedStepNo: 2)));

    [DbFact]
    public async Task Reopen_binds_the_signature()
        => Assert.Equal("Reopening a closed request needs the General Manager and the Owner.", await RefusalOf(
            () => Repo().ReopenAsync(-1, -1, "contract check", signedWithPassword: true)));

    [DbFact]
    public async Task Move_to_version_binds_the_confirmation()
        => Assert.Equal("Request not found.", await RefusalOf(
            () => Repo().MoveToVersionAsync(-1, null, -1, "contract check", confirmClose: true)));

    [DbFact]
    public async Task Delegate_candidates_read_binds_and_maps()
    {
        Assert.Empty(await Repo().GetDelegateCandidatesAsync(-1, -1));

        await using var db = new SqlConnection(DbFactAttribute.ConnectionString);
        var columns = (await db.QueryAsync<string>(
            "SELECT name FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID('workflow.usp_Request_GetDelegateCandidates'), 0) ORDER BY column_ordinal"))
            .ToList();
        Assert.Equal(new[] { "UserId", "Username", "FullName" }, columns);
    }

    [DbFact]
    public async Task The_reconcilers_sweep_runs()
        => Assert.NotNull(await Repo().GetApprovedWithUnappliedEffectsAsync());

    [DbFact]
    public async Task A_procedure_refusal_maps_to_its_own_sentence_only()
    {
        // Through the service's mapping, as the controllers see it.
        var ex = await Assert.ThrowsAsync<WorkflowException>(() => WorkflowSqlErrors.MapAsync(
            () => Repo().MoveToVersionAsync(-1, null, -1, "contract check")));
        Assert.Equal(400, ex.StatusCode);
        Assert.Equal("Request not found.", ex.Message);
    }
}
