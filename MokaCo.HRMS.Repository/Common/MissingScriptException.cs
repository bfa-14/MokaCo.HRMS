using Microsoft.Data.SqlClient;

namespace MokaCo.HRMS.Repository.Common;

/// <summary>
/// A procedure that a numbered script adds is not in this database yet: the API was deployed before
/// the script was applied (the deploy runs the code and the SQL as separate manual steps). Thrown only
/// around calls that have an older way to fall back to, so the caller can carry on as it did before
/// the script instead of failing: a missing script must never lock everyone out.
/// </summary>
public sealed class MissingScriptException : Exception
{
    /// <summary>SQL Server: "Could not find stored procedure".</summary>
    public const int ProcedureNotFound = 2812;

    /// <summary>SQL Server: "Invalid column name" (a column the script adds).</summary>
    public const int InvalidColumn = 207;

    /// <summary>The script that adds what is missing, as the operator should read it: docs/NNN_....sql.</summary>
    public string Script { get; }

    /// <summary>The procedure that was called.</summary>
    public string Procedure { get; }

    /// <summary>The SQL Server error number that said so (<see cref="ProcedureNotFound"/> or <see cref="InvalidColumn"/>).</summary>
    public int SqlErrorNumber { get; }

    public MissingScriptException(string script, string procedure, int sqlErrorNumber, Exception? inner = null)
        : base($"{script} is not applied to this database: {procedure} failed with SQL error {sqlErrorNumber}.", inner)
    {
        Script = script;
        Procedure = procedure;
        SqlErrorNumber = sqlErrorNumber;
    }

    /// <summary>Whether a SQL error number means "this procedure or column does not exist here".</summary>
    public static bool IsMissingObject(int sqlErrorNumber) => sqlErrorNumber is ProcedureNotFound or InvalidColumn;

    /// <summary>
    /// Runs one call to <paramref name="procedure"/> of <paramref name="script"/>. "Not found" (2812, 207)
    /// comes out as a <see cref="MissingScriptException"/>; every other error, and every answer, as it was.
    /// </summary>
    public static async Task<T> GuardAsync<T>(string script, string procedure, Func<Task<T>> call)
    {
        try
        {
            return await call();
        }
        catch (SqlException ex) when (IsMissingObject(ex.Number))
        {
            throw new MissingScriptException(script, procedure, ex.Number, ex);
        }
    }

    /// <inheritdoc cref="GuardAsync{T}(string, string, Func{Task{T}})"/>
    public static Task GuardAsync(string script, string procedure, Func<Task> call)
        => GuardAsync(script, procedure, async () => { await call(); return true; });
}
