/* ============================================================================
   94_admin_renumber_users.sql — give the users ids 1, 2, 3 ... without losing anything.

   WHY. Identity numbers jumped: after the 3 Oct clean-up security.[USER] holds 16 and 1458..1464.
   91 only moves the NEXT number, and an existing id cannot be UPDATEd. A plain "copy out, TRUNCATE,
   insert back" fails twice over: TRUNCATE is refused on a table other tables point at, and the
   rows inserted back get new ids that the roles, the employee link and the requests no longer
   match. This does the same copy-out / insert-back, and rewrites every column that points at a
   user in the same transaction: all of it happens, or none of it.

   dbo.usp_Admin_RenumberUsers @Execute = 0|1, @SkipColumns = N''
     @Execute = 0 (default) reports, changing nothing:
       - old id -> new id for every user that moves (current order kept: lowest id becomes 1);
       - every column that will be rewritten and how many rows: FK = a foreign key to
         security.[USER]; NAME = an integer column named ...UserId / ...By with no foreign key.
         READ THE NAME LINES: one that does not hold user ids goes in @SkipColumns as
         N'schema.table.column, ...'.
     @Execute = 1, in ONE transaction:
       1. disables the triggers on security.[USER] and on every table it rewrites (no mail, no side
          effects), and turns exactly those back on at the end;
       2. drops the foreign keys to security.[USER], keeping their definitions;
       3. copies the users that move, deletes them and inserts them back under their new id;
       4. rewrites every listed column from the old id to the new one;
       5. recreates every foreign key as it was (WITH CHECK where it was trusted), then refuses -
          and rolls everything back - if any column now points at a missing user where it did not
          before;
       6. sets the next user id to the highest + 1.
     Each user keeps everything but the number. Signed-in sessions end: users sign in again.

   RUN IT WITH THE API STOPPED (sudo systemctl stop mokaco-api), AFTER A BACKUP, and on
   MokaCo_HRMS_Test first (deploy/test-env/apply-sql-test.sh).
     EXEC dbo.usp_Admin_RenumberUsers;                    -- report
     EXEC dbo.usp_Admin_RenumberUsers @Execute = 1;       -- apply
   Needs db_owner. Idempotent: CREATE OR ALTER; a second run finds nobody to move.
   Apply with sqlcmd -C -I -b -d <database>.
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_Admin_RenumberUsers
    @Execute     BIT           = 0,
    @SkipColumns NVARCHAR(MAX) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Users INT = OBJECT_ID(N'security.[USER]');
    DECLARE @sql NVARCHAR(MAX);

    /* ---- what this procedure can handle --------------------------------------------------- */
    IF @Users IS NULL
    BEGIN RAISERROR('security.[USER] not found in this database.', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = @Users AND name = N'UserId')
    BEGIN RAISERROR('security.[USER].UserId is not the identity column; renumber by hand.', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM sys.tables WHERE object_id = @Users AND temporal_type <> 0)
    BEGIN RAISERROR('security.[USER] is system-versioned; this procedure does not handle that.', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM sys.foreign_key_columns c
               WHERE c.referenced_object_id = @Users
                 AND (COL_NAME(c.referenced_object_id, c.referenced_column_id) <> N'UserId'
                      OR EXISTS (SELECT 1 FROM sys.foreign_key_columns o
                                 WHERE o.constraint_object_id = c.constraint_object_id
                                   AND o.constraint_column_id > 1)))
    BEGIN RAISERROR('A foreign key points at security.[USER] through more than UserId; renumber by hand.', 16, 1); RETURN; END

    /* ---- 1. old id -> new id, for the users that move ------------------------------------- */
    CREATE TABLE #map (FromId INT NOT NULL PRIMARY KEY, ToId INT NOT NULL UNIQUE);
    INSERT #map (FromId, ToId)
    SELECT UserId, CAST(ROW_NUMBER() OVER (ORDER BY UserId) AS INT) FROM security.[USER];
    DELETE #map WHERE FromId = ToId;   -- already in place: left alone

    /* ---- 2. every column that holds a user id --------------------------------------------- */
    CREATE TABLE #col (
        sch            SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
        tbl            SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
        col            SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
        obj            INT         NOT NULL,
        how            VARCHAR(4)  NOT NULL,   -- FK | NAME
        rows_to_change INT         NULL,
        orphans_before INT         NULL,       -- values pointing at no user, before
        orphans_after  INT         NULL);

    INSERT #col (sch, tbl, col, obj, how)
    SELECT DISTINCT OBJECT_SCHEMA_NAME(c.parent_object_id), OBJECT_NAME(c.parent_object_id),
           COL_NAME(c.parent_object_id, c.parent_column_id), c.parent_object_id, 'FK'
    FROM sys.foreign_key_columns c
    WHERE c.referenced_object_id = @Users;

    INSERT #col (sch, tbl, col, obj, how)
    SELECT s.name, t.name, c.name, t.object_id, 'NAME'
    FROM sys.columns c
    JOIN sys.tables  t ON t.object_id = c.object_id
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND c.is_computed = 0 AND c.is_identity = 0
      AND TYPE_NAME(c.system_type_id) IN (N'int', N'bigint')
      AND (c.name LIKE N'%UserId' OR c.name LIKE N'%By' OR c.name LIKE N'%ByUser')
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
               + N' x WHERE x.' + QUOTENAME(col) + N' IS NOT NULL AND NOT EXISTS (SELECT 1 FROM security.[USER] u WHERE u.UserId = x.'
               + QUOTENAME(col) + N'))'
               + N' WHERE obj = ' + CAST(obj AS NVARCHAR(20)) + N' AND col = N''' + REPLACE(col, N'''', N'''''') + N''';'
               AS NVARCHAR(MAX)), NCHAR(10))
        FROM #col);
    IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

    /* ---- report --------------------------------------------------------------------------- */
    SELECT m.FromId AS [Old id], m.ToId AS [New id], u.Username
    FROM #map m
    JOIN security.[USER] u ON u.UserId = m.FromId
    ORDER BY m.ToId;

    SELECT how AS [Found by], sch + N'.' + tbl + N'.' + col AS [Column], rows_to_change AS [Rows to rewrite]
    FROM #col
    WHERE how = 'NAME' OR rows_to_change > 0
    ORDER BY CASE how WHEN 'NAME' THEN 0 ELSE 1 END, rows_to_change DESC, sch, tbl, col;

    IF NOT EXISTS (SELECT 1 FROM #map)
    BEGIN PRINT 'Every user already has its number (1..N). Nothing to do.'; RETURN; END

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
    WHERE fk.referenced_object_id = @Users;

    CREATE TABLE #trg (
        sch SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
        trg SYSNAME COLLATE DATABASE_DEFAULT NOT NULL,
        tbl SYSNAME COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #trg
    SELECT OBJECT_SCHEMA_NAME(tr.parent_id), tr.name, OBJECT_NAME(tr.parent_id)
    FROM sys.triggers tr
    WHERE tr.parent_class = 1 AND tr.is_disabled = 0
      AND (tr.parent_id = @Users OR tr.parent_id IN (SELECT obj FROM #col WHERE rows_to_change > 0));

    DECLARE @cols NVARCHAR(MAX), @vals NVARCHAR(MAX);
    SELECT @cols = STRING_AGG(CAST(QUOTENAME(c.name) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY c.column_id),
           @vals = STRING_AGG(CAST(CASE WHEN c.is_identity = 1 THEN N'm.ToId' ELSE N'u.' + QUOTENAME(c.name) END
                                   AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY c.column_id)
    FROM sys.columns c
    WHERE c.object_id = @Users
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

    /* 3. the users that move: out, and back in under their new id */
    SELECT u.* INTO #u FROM security.[USER] u WHERE u.UserId IN (SELECT FromId FROM #map);
    DELETE FROM security.[USER] WHERE UserId IN (SELECT FromId FROM #map);

    SET @sql = N'SET IDENTITY_INSERT security.[USER] ON;
INSERT INTO security.[USER] (' + @cols + N')
SELECT ' + @vals + N' FROM #u u JOIN #map m ON m.FromId = u.UserId;
SET IDENTITY_INSERT security.[USER] OFF;';
    EXEC sys.sp_executesql @sql;

    IF (SELECT COUNT(*) FROM security.[USER] WHERE UserId IN (SELECT ToId FROM #map)) <> (SELECT COUNT(*) FROM #map)
    BEGIN
        ROLLBACK;
        RAISERROR('Not every user came back under its new id. Nothing was changed.', 16, 1);
        RETURN;
    END

    /* 4. every column that points at a user: old id -> new id (one statement per column, so an
          old id that equals another user's new id is read before it is written) */
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
                  + N') REFERENCES security.[USER] (UserId) ON DELETE ' + on_delete + N' ON UPDATE ' + on_update
                  + CASE WHEN not_for_repl = 1 THEN N' NOT FOR REPLICATION' ELSE N'' END + N';'
                  + CASE WHEN is_disabled = 1
                         THEN N' ALTER TABLE ' + QUOTENAME(sch) + N'.' + QUOTENAME(tbl) + N' NOCHECK CONSTRAINT ' + QUOTENAME(name) + N';'
                         ELSE N'' END
                  AS NVARCHAR(MAX)), NCHAR(10))
                FROM #fk);
    IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

    /* ...and no column may point at a missing user where it did not before */
    SET @sql = (
        SELECT STRING_AGG(CAST(
                 N'UPDATE #col SET orphans_after = (SELECT COUNT(*) FROM ' + QUOTENAME(sch) + N'.' + QUOTENAME(tbl)
               + N' x WHERE x.' + QUOTENAME(col) + N' IS NOT NULL AND NOT EXISTS (SELECT 1 FROM security.[USER] u WHERE u.UserId = x.'
               + QUOTENAME(col) + N'))'
               + N' WHERE obj = ' + CAST(obj AS NVARCHAR(20)) + N' AND col = N''' + REPLACE(col, N'''', N'''''') + N''';'
               AS NVARCHAR(MAX)), NCHAR(10))
        FROM #col);
    IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

    IF EXISTS (SELECT 1 FROM #col WHERE orphans_after > orphans_before)
    BEGIN
        -- listed BEFORE the rollback, which also undoes the orphans_after figures
        SELECT sch + N'.' + tbl + N'.' + col AS [Column], orphans_before AS [Missing users before], orphans_after AS [Missing users after]
        FROM #col WHERE orphans_after > orphans_before;
        ROLLBACK;
        RAISERROR('Some ids would point at no user (listed above). Nothing was changed.', 16, 1);
        RETURN;
    END

    /* 6. triggers back on, next id after the highest */
    SET @sql = (SELECT STRING_AGG(CAST(N'ENABLE TRIGGER ' + QUOTENAME(sch) + N'.' + QUOTENAME(trg)
                                     + N' ON ' + QUOTENAME(sch) + N'.' + QUOTENAME(tbl) + N';' AS NVARCHAR(MAX)), NCHAR(10))
                FROM #trg);
    IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

    SET @sql = N'DBCC CHECKIDENT (N''security.[USER]'', RESEED, '
             + CAST((SELECT MAX(UserId) FROM security.[USER]) AS NVARCHAR(20)) + N') WITH NO_INFOMSGS;';
    EXEC sys.sp_executesql @sql;

    COMMIT;

    SELECT N'DONE' AS Result,
           (SELECT COUNT(*) FROM #map) AS [Users renumbered],
           (SELECT COUNT(*) FROM #col WHERE rows_to_change > 0) AS [Columns rewritten],
           (SELECT ISNULL(SUM(rows_to_change), 0) FROM #col) AS [Rows rewritten];
    SELECT UserId, Username FROM security.[USER] ORDER BY UserId;
END;
GO
