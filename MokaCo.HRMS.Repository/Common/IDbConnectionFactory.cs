using System.Data;

namespace MokaCo.HRMS.Repository.Common;

/// <summary>Creates open-able ADO.NET connections. The connection string lives in the API layer.</summary>
public interface IDbConnectionFactory
{
    IDbConnection Create();
}
