namespace MokaCo.HRMS.Tests;

/// <summary>
/// Every test class that talks to the database (MOKACO_TEST_CONNECTION). They seed and read shared tables
/// inside long transactions, so two of them running at once deadlock each other (QA3 DB-2: fn_IsPeriodPaid
/// against Generate, the roster trigger against the payslip shells, readiness against reprocess). One
/// collection, never run beside any other.
/// </summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class DatabaseCollection
{
    public const string Name = "Database";
}
