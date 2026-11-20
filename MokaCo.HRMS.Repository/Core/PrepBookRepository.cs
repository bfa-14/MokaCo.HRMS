using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Core;

public interface IPrepBookRepository
{
    /// <summary>The book on file, or null when none was uploaded yet. Its JSON is left out when <paramref name="ifNoneMatch"/> is its tag.</summary>
    Task<PrepBookRow?> GetAsync(string? ifNoneMatch);

    /// <summary>A scanned guide page ('page') or label ('label'), or null.</summary>
    Task<byte[]?> GetScanAsync(string kind, int number);

    /// <summary>Replaces the whole book and its scans in one transaction.</summary>
    Task ReplaceAsync(PrepBookPackage package, int uploadedByUserId);
}

/// <summary>Dapper access for core.usp_PrepBook_* (script 115). Every call is guarded for a database without it.</summary>
public class PrepBookRepository : IPrepBookRepository
{
    private readonly IDbConnectionFactory _factory;
    public PrepBookRepository(IDbConnectionFactory factory) => _factory = factory;

    private static Task<T> Guard<T>(string procedure, Func<Task<T>> call)
        => MissingScriptException.GuardAsync(Scripts.RecipeBook115, procedure, call);

    public Task<PrepBookRow?> GetAsync(string? ifNoneMatch)
        => Guard("core.usp_PrepBook_Get", async () =>
        {
            using var db = _factory.Create();
            return await db.QuerySingleOrDefaultAsync<PrepBookRow>(
                "core.usp_PrepBook_Get", new { IfNoneMatch = ifNoneMatch }, commandType: CommandType.StoredProcedure);
        });

    public Task<byte[]?> GetScanAsync(string kind, int number)
        => Guard("core.usp_PrepBook_GetScan", async () =>
        {
            using var db = _factory.Create();
            return await db.QuerySingleOrDefaultAsync<byte[]?>(
                "core.usp_PrepBook_GetScan", new { Kind = kind, Number = number }, commandType: CommandType.StoredProcedure);
        });

    /// <summary>
    /// ONE TRANSACTION: the book row and every scan, or nothing. A reader between two of these statements would
    /// otherwise meet the new recipes with the old scans (or none), and a failure half-way would leave a book whose
    /// "show the guide page" button answers 404.
    /// </summary>
    public Task ReplaceAsync(PrepBookPackage package, int uploadedByUserId)
        => Guard("core.usp_PrepBook_Replace", async () =>
        {
            using var db = _factory.Create();
            db.Open();
            using var tx = db.BeginTransaction();
            await db.ExecuteAsync(
                "core.usp_PrepBook_Replace",
                new { package.Json, package.ETag, package.RecipeCount, UploadedByUserId = uploadedByUserId },
                tx, commandTimeout: 120, commandType: CommandType.StoredProcedure);
            foreach (var scan in package.Scans)
            {
                var p = new DynamicParameters();
                p.Add("Kind", scan.Kind);
                p.Add("Number", scan.Number);
                p.Add("Bytes", scan.Bytes, DbType.Binary, size: -1);
                await db.ExecuteAsync("core.usp_PrepBook_PutScan", p, tx, commandTimeout: 120, commandType: CommandType.StoredProcedure);
            }
            tx.Commit();
            return true;
        });
}
