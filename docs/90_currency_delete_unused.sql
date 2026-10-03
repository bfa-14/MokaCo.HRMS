/* ============================================================================
   90_currency_delete_unused.sql — a currency can be deleted when nothing uses it.

   core.usp_Currency_Delete @CurrencyCode
     REFUSES (RAISERROR, so the API answers 409 with the sentence) when the code appears in:
       * any column that has a FOREIGN KEY to core.CURRENCY, in any table;
       * any other column whose name contains "Currency" (salary components, payroll run
         rates, rooms, bookings ... - many hold the code without a foreign key);
       * a core.SETTING value (e.g. the primary or payroll currency).
     The sentence names where it is used, e.g.
       "LBP is already used and cannot be deleted: hr.SALARY_COMPONENT.CurrencyCode (12),
        setting PrimaryCurrency."
     DELETES otherwise, in one transaction: the currency's own exchange rates
     (core.EXCHANGE_RATE, either side) and the currency itself. A rate is configuration that
     belongs to the currency, not a use of it.

   The check is read from the catalog when it runs, so a table added later is covered
   without editing this procedure. Idempotent: CREATE OR ALTER. Apply with sqlcmd -C -I -b.
   ============================================================================ */
CREATE OR ALTER PROCEDURE core.usp_Currency_Delete
    @CurrencyCode CHAR(3)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM core.CURRENCY WHERE CurrencyCode = @CurrencyCode)
    BEGIN RAISERROR('Currency %s does not exist.', 16, 1, @CurrencyCode); RETURN; END

    DECLARE @CurrencyObj INT = OBJECT_ID(N'core.CURRENCY'),
            @RateObj     INT = OBJECT_ID(N'core.EXCHANGE_RATE');

    /* every column that can hold a currency code, outside the currency's own tables */
    CREATE TABLE #col (sch SYSNAME COLLATE DATABASE_DEFAULT, tbl SYSNAME COLLATE DATABASE_DEFAULT,
                       col SYSNAME COLLATE DATABASE_DEFAULT, PRIMARY KEY (sch, tbl, col));

    INSERT #col (sch, tbl, col)                               -- (a) foreign keys to core.CURRENCY
    SELECT DISTINCT s.name, t.name, c.name
    FROM sys.foreign_key_columns fkc
    JOIN sys.tables  t ON t.object_id = fkc.parent_object_id
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fkc.referenced_object_id = @CurrencyObj
      AND fkc.parent_object_id NOT IN (@CurrencyObj, @RateObj);

    INSERT #col (sch, tbl, col)                               -- (b) "...Currency..." text columns
    SELECT s.name, t.name, c.name
    FROM sys.columns c
    JOIN sys.tables  t ON t.object_id = c.object_id
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    JOIN sys.types  ty ON ty.user_type_id = c.user_type_id
    WHERE t.is_ms_shipped = 0
      AND t.object_id NOT IN (@CurrencyObj, @RateObj)
      AND c.name LIKE N'%Currency%'
      AND ty.name IN (N'char', N'varchar', N'nchar', N'nvarchar')
      AND (c.max_length = -1 OR c.max_length >= 3)
      AND NOT EXISTS (SELECT 1 FROM #col x WHERE x.sch = s.name COLLATE DATABASE_DEFAULT
                                            AND x.tbl = t.name COLLATE DATABASE_DEFAULT
                                            AND x.col = c.name COLLATE DATABASE_DEFAULT);

    /* count the uses */
    CREATE TABLE #used (place NVARCHAR(400), n INT);
    DECLARE @sql NVARCHAR(MAX) = (
        SELECT STRING_AGG(CAST(
                 N'INSERT #used SELECT N''' + REPLACE(sch + N'.' + tbl + N'.' + col, N'''', N'''''') + N''', COUNT(*) FROM '
               + QUOTENAME(sch) + N'.' + QUOTENAME(tbl) + N' WHERE ' + QUOTENAME(col) + N' = @Code;'
               AS NVARCHAR(MAX)), NCHAR(10))
        FROM #col);
    IF @sql IS NOT NULL EXEC sys.sp_executesql @sql, N'@Code CHAR(3)', @CurrencyCode;

    INSERT #used (place, n)                                   -- (c) settings that name the currency
    SELECT N'setting ' + SettingKey, 1
    FROM core.SETTING
    WHERE LTRIM(RTRIM(SettingValue)) = @CurrencyCode;

    DECLARE @where NVARCHAR(2000) = (
        SELECT STRING_AGG(CASE WHEN place LIKE N'setting %' THEN place
                               ELSE place + N' (' + CAST(n AS NVARCHAR(12)) + N')' END, N', ')
        FROM #used WHERE n > 0);

    IF @where IS NOT NULL
    BEGIN
        DECLARE @msg NVARCHAR(2048) = @CurrencyCode + N' is already used and cannot be deleted: ' + @where + N'.';
        THROW 50000, @msg, 1;
    END

    BEGIN TRAN;
        DELETE FROM core.EXCHANGE_RATE WHERE FromCurrency = @CurrencyCode OR ToCurrency = @CurrencyCode;
        DELETE FROM core.CURRENCY      WHERE CurrencyCode = @CurrencyCode;
    COMMIT;
END;
GO
