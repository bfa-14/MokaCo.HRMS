using System.Data;
using Microsoft.Data.SqlClient;

namespace MokaCo.HRMS.Repository.Common;

/// <summary>SQL Server implementation. Registered in Program.cs with the connection string.</summary>
public class SqlConnectionFactory : IDbConnectionFactory
{
    private readonly string _connectionString;
    public SqlConnectionFactory(string connectionString) => _connectionString = connectionString;
    public IDbConnection Create() => new SqlConnection(_connectionString);
}
