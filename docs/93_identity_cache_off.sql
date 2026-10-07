/* ============================================================================
   93_identity_cache_off.sql — stop identity numbers jumping by about 1000 after a restart.

   WHY. SQL Server hands out identity values from a cache (1000 at a time for INT). When the
   service stops without a clean shutdown - a VM reboot, a crash - the cached numbers are lost and
   the next row skips ahead: security.[USER] went from 16 to 1458. With the cache off every value
   is written as it is handed out; the cost is a little more log work per insert, nothing at this
   database's volume.

   Gaps that already exist stay (no row is changed); 91_admin_reseed_identities.sql lines up the
   next numbers. Applies to the database it runs in, so pass -d. Idempotent.
   Apply with sqlcmd -C -I -b -d MokaCo_HRMS.
   ============================================================================ */
SET NOCOUNT ON;

IF DB_ID() <= 4
    THROW 50000, N'93_identity_cache_off.sql: run it in the application database (sqlcmd -d MokaCo_HRMS), not in a system database.', 1;

IF EXISTS (SELECT 1 FROM sys.database_scoped_configurations
           WHERE name = N'IDENTITY_CACHE' AND CAST(value AS INT) = 1)
BEGIN
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET IDENTITY_CACHE = OFF;');
    PRINT CONCAT(DB_NAME(), N': IDENTITY_CACHE turned OFF.');
END
ELSE
    PRINT CONCAT(DB_NAME(), N': IDENTITY_CACHE already OFF.');

SELECT name AS Setting, value AS Value
FROM sys.database_scoped_configurations
WHERE name = N'IDENTITY_CACHE';
