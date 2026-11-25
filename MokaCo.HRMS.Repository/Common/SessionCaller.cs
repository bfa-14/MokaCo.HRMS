using System.Data;
using System.Data.Common;
using Dapper;

namespace MokaCo.HRMS.Repository.Common;

/// <summary>
/// WHO IS CALLING, FOR A TRIGGER THAT LOGS. A trigger cannot see the procedure's @CallerUserId, so the caller is put
/// on the database session first: SESSION_CONTEXT(N'UserId'), which script 122's shift change log reads.
///
/// The connection is OPENED here and must stay open for the call that writes: Dapper closes a connection it opened
/// itself after each command, and the pool resets the session when the connection is reused, which would lose the
/// value between the two calls. It is always written - NULL included - so no value can be carried over from an
/// earlier use of the session.
/// </summary>
public static class SessionCaller
{
    /// <summary>The session key the database's triggers read.</summary>
    public const string UserIdKey = "UserId";

    public static Task SetAsync(IDbConnection db, int? callerUserId, IDbTransaction? transaction = null)
        => SetValueAsync(db, UserIdKey, callerUserId, transaction);

    /// <summary>Any other value a trigger reads from the session, on the same terms: the connection opened and left
    /// open, the value written even when it is NULL.</summary>
    public static async Task SetValueAsync<T>(IDbConnection db, string key, T value, IDbTransaction? transaction = null)
    {
        if (db.State != ConnectionState.Open)
        {
            if (db is DbConnection connection) await connection.OpenAsync();
            else db.Open();
        }

        await db.ExecuteAsync(
            "sys.sp_set_session_context",
            new { key, value },
            transaction,
            commandType: CommandType.StoredProcedure);
    }
}
