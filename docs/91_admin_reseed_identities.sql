/* ============================================================================
   91_admin_reseed_identities.sql — line every identity counter up with the data it holds.

   WHY. After rows are deleted, SQL Server keeps counting from the highest number it ever
   handed out: delete employees 1..40 and the next employee is 41, not 1. That is what a
   database looks like after clearing test data.

   dbo.usp_Admin_ReseedIdentities @Execute = 0|1
     For every table with an identity column:
       * empty table       -> the next row gets the column's seed (normally 1);
       * table with rows   -> the next row gets MAX(id) + increment (no gap after the data).
     NO ROW IS CHANGED: existing rows keep their ids, only the "next number" moves.
     @Execute = 0 (default) only lists current / highest / next for every table.
     Tables already lined up are left alone. Tables counting downwards (negative increment)
     are listed and skipped.

   EXEC dbo.usp_Admin_ReseedIdentities;                  -- report
   EXEC dbo.usp_Admin_ReseedIdentities @Execute = 1;     -- apply
   Needs db_owner (DBCC CHECKIDENT). Idempotent: CREATE OR ALTER. Apply with sqlcmd -C -I -b.
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_Admin_ReseedIdentities
    @Execute BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #id (
        sch        SYSNAME COLLATE DATABASE_DEFAULT,
        tbl        SYSNAME COLLATE DATABASE_DEFAULT,
        col        SYSNAME COLLATE DATABASE_DEFAULT,
        seed       DECIMAL(38, 0),
        incr       DECIMAL(38, 0),
        last_value DECIMAL(38, 0) NULL,   -- NULL = no row was ever inserted
        max_value  DECIMAL(38, 0) NULL,   -- NULL = table is empty
        next_now   DECIMAL(38, 0) NULL,
        next_after DECIMAL(38, 0) NULL,
        action     VARCHAR(10)   NULL);

    INSERT #id (sch, tbl, col, seed, incr, last_value)
    SELECT s.name, t.name, ic.name,
           CAST(ic.seed_value AS DECIMAL(38, 0)), CAST(ic.increment_value AS DECIMAL(38, 0)),
           CAST(ic.last_value AS DECIMAL(38, 0))
    FROM sys.identity_columns ic
    JOIN sys.tables  t ON t.object_id = ic.object_id
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0;

    /* the highest id actually stored, per table */
    DECLARE @sql NVARCHAR(MAX) = (
        SELECT STRING_AGG(CAST(
                 N'UPDATE #id SET max_value = (SELECT CAST(MAX(' + QUOTENAME(col) + N') AS DECIMAL(38,0)) FROM '
               + QUOTENAME(sch) + N'.' + QUOTENAME(tbl) + N') WHERE sch = N''' + REPLACE(sch, N'''', N'''''')
               + N''' AND tbl = N''' + REPLACE(tbl, N'''', N'''''') + N''';' AS NVARCHAR(MAX)), NCHAR(10))
        FROM #id);
    IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

    UPDATE #id SET
        next_now   = CASE WHEN last_value IS NULL THEN seed ELSE last_value + incr END,
        next_after = CASE WHEN max_value  IS NULL THEN seed ELSE max_value  + incr END;

    UPDATE #id SET action =
        CASE WHEN incr <= 0             THEN 'SKIP'
             WHEN next_now = next_after THEN 'OK'
             ELSE 'RESEED' END;

    SELECT action AS Action, sch + N'.' + tbl AS [Table], col AS [Column],
           max_value AS [Highest id], next_now AS [Next id now], next_after AS [Next id after]
    FROM #id
    ORDER BY CASE action WHEN 'RESEED' THEN 1 WHEN 'SKIP' THEN 2 ELSE 3 END, sch, tbl;

    IF @Execute = 0
    BEGIN PRINT 'Report only. Re-run with @Execute = 1 to apply the RESEED lines.'; RETURN; END

    /* DBCC CHECKIDENT RESEED n: on a table that has ever held rows the next id is n + increment;
       on a table that never held a row it is n itself. Choose n so the next id is next_after. */
    SET @sql = (
        SELECT STRING_AGG(CAST(
                 N'DBCC CHECKIDENT (N''' + REPLACE(QUOTENAME(sch) + N'.' + QUOTENAME(tbl), N'''', N'''''') + N''', RESEED, '
               + CAST(CASE WHEN last_value IS NULL THEN next_after ELSE next_after - incr END AS NVARCHAR(40))
               + N') WITH NO_INFOMSGS;' AS NVARCHAR(MAX)), NCHAR(10))
        FROM #id WHERE action = 'RESEED');
    IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

    SELECT N'DONE' AS Result, COUNT(*) AS [Tables reseeded] FROM #id WHERE action = 'RESEED';
END;
GO
