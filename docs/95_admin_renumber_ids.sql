/* ============================================================================
   95_admin_renumber_ids.sql — give the rows of ONE table ids 1, 2, 3 ... without losing anything.

   94 did this for security.[USER]; this is the same procedure for any table with an identity
   column (roles, employees, branches ...), one table per call. Identity numbers jumped after the
   clean-up, and an existing id cannot be UPDATEd, so the rows that move are copied out, deleted
   and inserted back under their new id, and every column that points at them is rewritten in the
   same transaction: all of it happens, or none of it.

   dbo.usp_Admin_RenumberIds @Table = N'schema.TABLE', @Execute = 0|1, @SkipColumns = N''
     @Execute = 0 (default) reports, changing nothing:
       - old id -> new id for every row that moves (current order kept: lowest id becomes 1);
       - every column that will be rewritten and how many rows: FK = a foreign key to the table;
         NAME = an integer column named ...<IdColumn> (e.g. ...RoleId) with no foreign key - for
         security.[USER] also ...By. READ THE NAME LINES: one that does not hold these ids goes in
         @SkipColumns as N'schema.table.column, ...';
       - procedures, views and functions that name an old id as a literal ("RoleId = 1004"), to
         check by hand: they are NOT rewritten.
     @Execute = 1, in ONE transaction:
       1. disables the triggers on the table and on every table it rewrites, and turns exactly
          those back on at the end;
       2. drops the foreign keys to the table, keeping their definitions;
       3. copies the rows that move, deletes them and inserts them back under their new id;
       4. rewrites every listed column from the old id to the new one;
       5. recreates every foreign key as it was (WITH CHECK where it was trusted), then refuses - and
          rolls everything back - if any column now points at a missing row where it did not before;
       6. sets the next id to the highest + 1.

   RUN IT WITH THE API STOPPED, AFTER A BACKUP, and on MokaCo_HRMS_Test first.
     EXEC dbo.usp_Admin_RenumberIds @Table = N'security.ROLE';                 -- report
     EXEC dbo.usp_Admin_RenumberIds @Table = N'security.ROLE', @Execute = 1;   -- apply
   Needs db_owner. Idempotent: CREATE OR ALTER; a second run finds nothing to move.
   Apply with sqlcmd -C -I -b -d <database>.
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_Admin_RenumberIds
    @Table       NVARCHAR(300),
    @Execute     BIT           = 0,
    @SkipColumns NVARCHAR(MAX) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Obj INT = OBJECT_ID(@Table, N'U');
    DECLARE @sql NVARCHAR(MAX), @qt NVARCHAR(300), @IdCol SYSNAME, @Label SYSNAME;

    /* ---- what this procedure can handle --------------------------------------------------- */
    IF @Obj IS NULL
    BEGIN RAISERROR('Table %s not found in this database (write it as schema.TABLE).', 16, 1, @Table); RETURN; END

    SET @qt = QUOTENAME(OBJECT_SCHEMA_NAME(@Obj)) + N'.' + QUOTENAME(OBJECT_NAME(@Obj));
    SET @IdCol = (SELECT name FROM sys.identity_columns WHERE object_id = @Obj);

    IF @IdCol IS NULL
    BEGIN RAISERROR('%s has no identity column; nothing to renumber.', 16, 1, @qt); RETURN; END

    IF EXISTS (SELECT 1 FROM sys.tables WHERE object_id = @Obj AND temporal_type <> 0)
    BEGIN RAISERROR('%s is system-versioned; this procedure does not handle that.', 16, 1, @qt); RETURN; END

    IF EXISTS (SELECT 1 FROM sys.foreign_key_columns c
               WHERE c.referenced_object_id = @Obj
                 AND (COL_NAME(c.referenced_object_id, c.referenced_column_id) <> @IdCol
                      OR EXISTS (SELECT 1 FROM sys.foreign_key_columns o
                                 WHERE o.constraint_object_id = c.constraint_object_id
                                   AND o.constraint_column_id > 1)))
    BEGIN RAISERROR('A foreign key points at %s through more than its identity column; renumber by hand.', 16, 1, @qt); RETURN; END

    /* a name to show beside each id in the report, when the table has one */
    SET @Label = (SELECT TOP (1) c.name FROM sys.columns c
                  WHERE c.object_id = @Obj AND c.name IN (N'Username', N'Name', N'Code', N'Title')
                  ORDER BY CASE c.name WHEN N'Username' THEN 1 WHEN N'Name' THEN 2 WHEN N'Code' THEN 3 ELSE 4 END);

    /* ---- 1. old id -> new id, for the rows that move ------------------------------------- */
    CREATE TABLE #map (FromId BIGINT NOT NULL PRIMARY KEY, ToId BIGINT NOT NULL UNIQUE);
    SET @sql = N'INSERT #map (FromId, ToId) SELECT ' + QUOTENAME(@IdCol) + N', ROW_NUMBER() OVER (ORDER BY '
             + QUOTENAME(@IdCol) + N') FROM ' + @qt + N';';
    EXEC sys.sp_executesql @sql;
    DELETE #map WHERE FromId = ToId;   -- already in place: left alone

    /* ---- 2. every column that holds one of these ids -------------------------------------- */
    CREATE TABLE #col (
        sch            SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
        tbl            SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
        col            SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
        obj            INT         NOT NULL,
        how            VARCHAR(4)  NOT NULL,   -- FK | NAME
        rows_to_change INT         NULL,
        orphans_before INT         NULL,       -- values pointing at no row, before
        orphans_after  INT         NULL);

    INSERT #col (sch, tbl, col, obj, how)
    SELECT DISTINCT OBJECT_SCHEMA_NAME(c.parent_object_id), OBJECT_NAME(c.parent_object_id),
           COL_NAME(c.parent_object_id, c.parent_column_id), c.parent_object_id, 'FK'
    FROM sys.foreign_key_columns c
    WHERE c.referenced_object_id = @Obj;

    INSERT #col (sch, tbl, col, obj, how)
    SELECT s.name, t.name, c.name, t.object_id, 'NAME'
    FROM sys.columns c
    JOIN sys.tables  t ON t.object_id = c.object_id
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND c.is_computed = 0 AND c.is_identity = 0
      AND TYPE_NAME(c.system_type_id) IN (N'int', N'bigint')
      AND (c.name LIKE N'%' + @IdCol
           OR (@Obj = OBJECT_ID(N'security.[USER]') AND (c.name LIKE N'%By' OR c.name LIKE N'%ByUser')))
      AND NOT EXISTS (SELECT 1 FROM #col x WHERE x.obj = t.object_id AND x.col = c.name);

    DELETE x FROM #col x
    WHERE x.how = 'NAME'
      AND EXISTS (SELECT 1 FROM STRING_SPLIT(@SkipColumns, N',') s
                  WHERE LTRIM(RTRIM(s.value)) = x.sch + N'.' + x.tbl + N'.' + x.col);

    SET @sql = (
        SELECT STRING_AGG(CAST(
                 N'UPDATE #col SET rows_to_change = (SELECT COUNT(*) FROM ' + QUOTENAME(sch) + N'.' + QUOTENAME(tbl)
               + N' x WHERE x.' + QUOTENAME(col) + N' IN (SELECT FromId FROM #map)),'
               + N' orphans_before = (SELECT COUNT(*) FROM ' + QUOTENAME(sch) + N'.' + QUOTENAME(tbl)
               + N' x WHERE x.' + QUOTENAME(col) + N' IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ' + @qt
               + N' r WHERE r.' + QUOTENAME(@IdCol) + N' = x.' + QUOTENAME(col) + N'))'
               + N' WHERE obj = ' + CAST(obj AS NVARCHAR(20)) + N' AND col = N''' + REPLACE(col, N'''', N'''''') + N''';'
               AS NVARCHAR(MAX)), NCHAR(10))
        FROM #col);
    IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

    /* ---- report --------------------------------------------------------------------------- */
    SET @sql = N'SELECT m.FromId AS [Old id], m.ToId AS [New id]'
             + CASE WHEN @Label IS NULL THEN N'' ELSE N', r.' + QUOTENAME(@Label) END
             + N' FROM #map m JOIN ' + @qt + N' r ON r.' + QUOTENAME(@IdCol) + N' = m.FromId ORDER BY m.ToId;';
    EXEC sys.sp_executesql @sql;

    SELECT how AS [Found by], sch + N'.' + tbl + N'.' + col AS [Column], rows_to_change AS [Rows to rewrite]
    FROM #col
    WHERE how = 'NAME' OR rows_to_change > 0
    ORDER BY CASE how WHEN 'NAME' THEN 0 ELSE 1 END, rows_to_change DESC, sch, tbl, col;

    /* code that names an old id literally is not rewritten: list it for a human */
    SELECT DISTINCT OBJECT_SCHEMA_NAME(m.object_id) + N'.' + OBJECT_NAME(m.object_id) AS [Check by hand: code naming an old id]
    FROM sys.sql_modules m
    JOIN #map p ON m.definition LIKE N'%' + @IdCol + N'%[^0-9]' + CAST(p.FromId AS NVARCHAR(20)) + N'[^0-9]%'
    WHERE p.FromId >= 100;   -- small numbers match everything; the jumped ids are the large ones

    IF NOT EXISTS (SELECT 1 FROM #map)
    BEGIN PRINT 'Every row already has its number (1..N). Nothing to do.'; RETURN; END

    IF @Execute = 0
    BEGIN
        PRINT 'Report only. Check the NAME lines, stop the API, take a backup, then run @Execute = 1.';
        RETURN;
    END

    /* ---- what will be dropped and disabled, kept to put back ------------------------------ */
    CREATE TABLE #fk (
        name           SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
        sch            SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
        tbl            SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
        col            SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
        on_delete      NVARCHAR(20) NOT NULL,
        on_update      NVARCHAR(20) NOT NULL,
        not_for_repl   BIT NOT NULL,
        is_disabled    BIT NOT NULL,
        is_not_trusted BIT NOT NULL);
    INSERT #fk
    SELECT fk.name, OBJECT_SCHEMA_NAME(fk.parent_object_id), OBJECT_NAME(fk.parent_object_id),
           COL_NAME(c.parent_object_id, c.parent_column_id),
           REPLACE(fk.delete_referential_action_desc, N'_', N' '),
           REPLACE(fk.update_referential_action_desc, N'_', N' '),
           fk.is_not_for_replication, fk.is_disabled, fk.is_not_trusted
    FROM sys.foreign_keys fk
    JOIN sys.foreign_key_columns c ON c.constraint_object_id = fk.object_id
    WHERE fk.referenced_object_id = @Obj;

    CREATE TABLE #trg (
        sch SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
        trg SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
        tbl SYSNAME COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #trg
    SELECT OBJECT_SCHEMA_NAME(tr.parent_id), tr.name, OBJECT_NAME(tr.parent_id)
    FROM sys.triggers tr
    WHERE tr.parent_class = 1 AND tr.is_disabled = 0
      AND (tr.parent_id = @Obj OR tr.parent_id IN (SELECT obj FROM #col WHERE rows_to_change > 0));

    DECLARE @cols NVARCHAR(MAX), @vals NVARCHAR(MAX);
    SELECT @cols = STRING_AGG(CAST(QUOTENAME(c.name) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY c.column_id),
           @vals = STRING_AGG(CAST(CASE WHEN c.is_identity = 1 THEN N'm.ToId' ELSE N'u.' + QUOTENAME(c.name) END
                                   AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY c.column_id)
    FROM sys.columns c
    WHERE c.object_id = @Obj
      AND c.is_computed = 0
      AND TYPE_NAME(c.system_type_id) <> N'timestamp';   -- rowversion is generated, never inserted

    BEGIN TRANSACTION;

    /* 1. triggers off */
    SET @sql = (SELECT STRING_AGG(CAST(N'DISABLE TRIGGER ' + QUOTENAME(sch) + N'.' + QUOTENAME(trg)
                                     + N' ON ' + QUOTENAME(sch) + N'.' + QUOTENAME(tbl) + N';' AS NVARCHAR(MAX)), NCHAR(10))
                FROM #trg);
    IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

    /* 2. foreign keys off */
    SET @sql = (SELECT STRING_AGG(CAST(N'ALTER TABLE ' + QUOTENAME(sch) + N'.' + QUOTENAME(tbl)
                                     + N' DROP CONSTRAINT ' + QUOTENAME(name) + N';' AS NVARCHAR(MAX)), NCHAR(10))
                FROM #fk);
    IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

    /* 3. the rows that move: out, and back in under their new id. #u is created and used in one
          batch, so it exists only there. */
    SET @sql = N'SELECT u.* INTO #u FROM ' + @qt + N' u WHERE u.' + QUOTENAME(@IdCol) + N' IN (SELECT FromId FROM #map);
DELETE FROM ' + @qt + N' WHERE ' + QUOTENAME(@IdCol) + N' IN (SELECT FromId FROM #map);
SET IDENTITY_INSERT ' + @qt + N' ON;
INSERT INTO ' + @qt + N' (' + @cols + N')
SELECT ' + @vals + N' FROM #u u JOIN #map m ON m.FromId = u.' + QUOTENAME(@IdCol) + N';
SET IDENTITY_INSERT ' + @qt + N' OFF;';
    EXEC sys.sp_executesql @sql;

    DECLARE @back BIGINT;
    SET @sql = N'SELECT @n = COUNT(*) FROM ' + @qt + N' WHERE ' + QUOTENAME(@IdCol) + N' IN (SELECT ToId FROM #map);';
    EXEC sys.sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @back OUTPUT;
    IF @back <> (SELECT COUNT(*) FROM #map)
    BEGIN
        ROLLBACK;
        RAISERROR('Not every row came back under its new id. Nothing was changed.', 16, 1);
        RETURN;
    END

    /* 4. every column that points at a moved row: old id -> new id (one statement per column, so
          an old id that equals another row's new id is read before it is written) */
    SET @sql = (SELECT STRING_AGG(CAST(N'UPDATE x SET ' + QUOTENAME(col) + N' = m.ToId FROM '
                                     + QUOTENAME(sch) + N'.' + QUOTENAME(tbl) + N' x JOIN #map m ON m.FromId = x.'
                                     + QUOTENAME(col) + N';' AS NVARCHAR(MAX)), NCHAR(10))
                FROM #col WHERE rows_to_change > 0);
    IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

    /* 5. foreign keys back as they were; a trusted one is re-checked against every row */
    SET @sql = (SELECT STRING_AGG(CAST(
                    N'ALTER TABLE ' + QUOTENAME(sch) + N'.' + QUOTENAME(tbl)
                  + CASE WHEN is_not_trusted = 1 THEN N' WITH NOCHECK' ELSE N' WITH CHECK' END
                  + N' ADD CONSTRAINT ' + QUOTENAME(name) + N' FOREIGN KEY (' + QUOTENAME(col)
                  + N') REFERENCES ' + @qt + N' (' + QUOTENAME(@IdCol) + N') ON DELETE ' + on_delete + N' ON UPDATE ' + on_update
                  + CASE WHEN not_for_repl = 1 THEN N' NOT FOR REPLICATION' ELSE N'' END + N';'
                  + CASE WHEN is_disabled = 1
                         THEN N' ALTER TABLE ' + QUOTENAME(sch) + N'.' + QUOTENAME(tbl) + N' NOCHECK CONSTRAINT ' + QUOTENAME(name) + N';'
                         ELSE N'' END
                  AS NVARCHAR(MAX)), NCHAR(10))
                FROM #fk);
    IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

    /* ...and no column may point at a missing row where it did not before */
    SET @sql = (
        SELECT STRING_AGG(CAST(
                 N'UPDATE #col SET orphans_after = (SELECT COUNT(*) FROM ' + QUOTENAME(sch) + N'.' + QUOTENAME(tbl)
               + N' x WHERE x.' + QUOTENAME(col) + N' IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ' + @qt
               + N' r WHERE r.' + QUOTENAME(@IdCol) + N' = x.' + QUOTENAME(col) + N'))'
               + N' WHERE obj = ' + CAST(obj AS NVARCHAR(20)) + N' AND col = N''' + REPLACE(col, N'''', N'''''') + N''';'
               AS NVARCHAR(MAX)), NCHAR(10))
        FROM #col);
    IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

    IF EXISTS (SELECT 1 FROM #col WHERE orphans_after > orphans_before)
    BEGIN
        -- listed BEFORE the rollback, which also undoes the orphans_after figures
        SELECT sch + N'.' + tbl + N'.' + col AS [Column], orphans_before AS [Missing before], orphans_after AS [Missing after]
        FROM #col WHERE orphans_after > orphans_before;
        ROLLBACK;
        RAISERROR('Some ids would point at no row (listed above). Nothing was changed.', 16, 1);
        RETURN;
    END

    /* 6. triggers back on, next id after the highest */
    SET @sql = (SELECT STRING_AGG(CAST(N'ENABLE TRIGGER ' + QUOTENAME(sch) + N'.' + QUOTENAME(trg)
                                     + N' ON ' + QUOTENAME(sch) + N'.' + QUOTENAME(tbl) + N';' AS NVARCHAR(MAX)), NCHAR(10))
                FROM #trg);
    IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

    DECLARE @max BIGINT;
    SET @sql = N'SELECT @m = MAX(' + QUOTENAME(@IdCol) + N') FROM ' + @qt + N';';
    EXEC sys.sp_executesql @sql, N'@m BIGINT OUTPUT', @m = @max OUTPUT;
    SET @sql = N'DBCC CHECKIDENT (N''' + REPLACE(@qt, N'''', N'''''') + N''', RESEED, '
             + CAST(@max AS NVARCHAR(20)) + N') WITH NO_INFOMSGS;';
    EXEC sys.sp_executesql @sql;

    COMMIT;

    SELECT N'DONE' AS Result,
           (SELECT COUNT(*) FROM #map) AS [Rows renumbered],
           (SELECT COUNT(*) FROM #col WHERE rows_to_change > 0) AS [Columns rewritten],
           (SELECT ISNULL(SUM(rows_to_change), 0) FROM #col) AS [Rows rewritten];
    SET @sql = N'SELECT ' + QUOTENAME(@IdCol)
             + CASE WHEN @Label IS NULL THEN N'' ELSE N', ' + QUOTENAME(@Label) END
             + N' FROM ' + @qt + N' ORDER BY ' + QUOTENAME(@IdCol) + N';';
    EXEC sys.sp_executesql @sql;
END;
GO
