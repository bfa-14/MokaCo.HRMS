/* ============================================================================
   deploy/compare-schema.sql - READ-ONLY: compare the schema of two databases on the same SQL Server.

   Used after a production update to see that production now has what was tested:
     REF    = the database that was tested   (default MokaCo_HRMS_Test)
     TARGET = the database to check          (default MokaCo_HRMS)

   /opt/mssql-tools18/bin/sqlcmd -S 127.0.0.1 -U sa -C -I -b -W \
       -v REF=MokaCo_HRMS_Test TARGET=MokaCo_HRMS -i ~/src/MokaCo.HRMS/deploy/compare-schema.sql
   (both names are required: sqlcmd refuses the script without them)

   Compares, in the application schemas (attendance, booking, core, hr, payroll, report, security, workflow):
     - procedures, functions, views and triggers: present on each side, and the same text (SHA-256 of the
       definition with spaces and line ends removed, so a re-indent is not a difference);
     - tables and their columns (type, length, precision, scale, nullability, computed);
     - indexes (by name), and the permission codes of security.PERMISSION.
   Writes nothing. The last line says how many differences were found; each is listed above it with the side
   that has it. A difference is not necessarily wrong (test may hold a fix not yet sent to production, or the
   other way round), but after an update the objects of the scripts just applied must not appear.
   ============================================================================ */
SET NOCOUNT ON;

IF DB_ID(N'$(REF)') IS NULL OR DB_ID(N'$(TARGET)') IS NULL
BEGIN RAISERROR('compare-schema.sql: database $(REF) or $(TARGET) not found on this server.', 16, 1); RETURN; END

IF OBJECT_ID('tempdb..#obj') IS NOT NULL DROP TABLE #obj;
IF OBJECT_ID('tempdb..#col') IS NOT NULL DROP TABLE #col;
IF OBJECT_ID('tempdb..#idx') IS NOT NULL DROP TABLE #idx;
IF OBJECT_ID('tempdb..#perm') IS NOT NULL DROP TABLE #perm;
CREATE TABLE #obj (Side CHAR(1), SchemaName SYSNAME, ObjectName SYSNAME, TypeDesc NVARCHAR(60), DefHash VARBINARY(32));
CREATE TABLE #col (Side CHAR(1), TableName NVARCHAR(300), ColumnName SYSNAME, Shape NVARCHAR(200));
CREATE TABLE #idx (Side CHAR(1), TableName NVARCHAR(300), IndexName SYSNAME, Shape NVARCHAR(400));
CREATE TABLE #perm (Side CHAR(1), Code NVARCHAR(100));

DECLARE @sides TABLE (Side CHAR(1), Db SYSNAME);
INSERT INTO @sides VALUES ('R', N'$(REF)'), ('T', N'$(TARGET)');
DECLARE @side CHAR(1), @db SYSNAME, @sql NVARCHAR(MAX);
DECLARE s CURSOR LOCAL FAST_FORWARD FOR SELECT Side, Db FROM @sides;
OPEN s; FETCH NEXT FROM s INTO @side, @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
    USE ' + QUOTENAME(@db) + N';
    INSERT INTO #obj
    SELECT @side, s.name, o.name, o.type_desc,
           HASHBYTES(''SHA2_256'', REPLACE(REPLACE(REPLACE(REPLACE(CAST(m.definition AS NVARCHAR(MAX)), N'' '', N''''), CHAR(9), N''''), CHAR(13), N''''), CHAR(10), N''''))
    FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id
    LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id
    WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''V'', ''TR'', ''U'')
      AND s.name IN (''attendance'', ''booking'', ''core'', ''hr'', ''payroll'', ''report'', ''security'', ''workflow'');
    INSERT INTO #col
    SELECT @side, s.name + ''.'' + t.name, c.name,
           CONCAT(ty.name, ''('', c.max_length, '','', c.precision, '','', c.scale, '')'',
                  CASE WHEN c.is_nullable = 1 THEN '' null'' ELSE '' not null'' END,
                  CASE WHEN c.is_computed = 1 THEN '' computed'' ELSE '''' END)
    FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
    JOIN sys.columns c ON c.object_id = t.object_id
    JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE s.name IN (''attendance'', ''booking'', ''core'', ''hr'', ''payroll'', ''report'', ''security'', ''workflow'');
    INSERT INTO #idx
    SELECT @side, s.name + ''.'' + t.name,
           -- a key whose name SQL Server made up (PK__TABLE__1A2B...) differs on every database: named by its columns
           CASE WHEN kc.is_system_named = 1 THEN CONCAT(CASE WHEN i.is_primary_key = 1 THEN ''PK'' ELSE ''UQ'' END, '' ('', k.cols, '')'')
                ELSE i.name END,
           CONCAT(i.type_desc, CASE WHEN i.is_unique = 1 THEN '' unique'' ELSE '''' END, '' ('', k.cols, '')'',
                  CASE WHEN i.has_filter = 1 THEN '' where '' + i.filter_definition ELSE '''' END)
    FROM sys.indexes i JOIN sys.tables t ON t.object_id = i.object_id JOIN sys.schemas s ON s.schema_id = t.schema_id
    LEFT JOIN sys.key_constraints kc ON kc.parent_object_id = i.object_id AND kc.unique_index_id = i.index_id
    CROSS APPLY (SELECT STRING_AGG(c.name, '','') WITHIN GROUP (ORDER BY ic.key_ordinal, ic.index_column_id) AS cols
                 FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id) k
    WHERE i.name IS NOT NULL
      AND s.name IN (''attendance'', ''booking'', ''core'', ''hr'', ''payroll'', ''report'', ''security'', ''workflow'');
    IF OBJECT_ID(''security.PERMISSION'') IS NOT NULL
        INSERT INTO #perm SELECT @side, Code FROM security.PERMISSION;';
    EXEC sp_executesql @sql, N'@side CHAR(1)', @side = @side;
    FETCH NEXT FROM s INTO @side, @db;
END
CLOSE s; DEALLOCATE s;

DECLARE @diff TABLE (Kind NVARCHAR(60), Name NVARCHAR(400), Difference NVARCHAR(600));

INSERT INTO @diff
SELECT LOWER(REPLACE(COALESCE(r.TypeDesc, t.TypeDesc), '_', ' ')), COALESCE(r.SchemaName, t.SchemaName) + '.' + COALESCE(r.ObjectName, t.ObjectName),
       CASE WHEN t.ObjectName IS NULL THEN N'only in $(REF)'
            WHEN r.ObjectName IS NULL THEN N'only in $(TARGET)'
            ELSE N'different text' END
FROM (SELECT * FROM #obj WHERE Side = 'R') r
FULL JOIN (SELECT * FROM #obj WHERE Side = 'T') t ON t.SchemaName = r.SchemaName AND t.ObjectName = r.ObjectName
WHERE r.ObjectName IS NULL OR t.ObjectName IS NULL OR (r.TypeDesc <> 'USER_TABLE' AND ISNULL(r.DefHash, 0x) <> ISNULL(t.DefHash, 0x));

INSERT INTO @diff
SELECT N'column', COALESCE(r.TableName, t.TableName) + '.' + COALESCE(r.ColumnName, t.ColumnName),
       CASE WHEN t.ColumnName IS NULL THEN N'only in $(REF): ' + r.Shape
            WHEN r.ColumnName IS NULL THEN N'only in $(TARGET): ' + t.Shape
            ELSE N'$(REF) ' + r.Shape + N' / $(TARGET) ' + t.Shape END
FROM (SELECT * FROM #col WHERE Side = 'R') r
FULL JOIN (SELECT * FROM #col WHERE Side = 'T') t ON t.TableName = r.TableName AND t.ColumnName = r.ColumnName
WHERE (r.ColumnName IS NULL OR t.ColumnName IS NULL OR r.Shape <> t.Shape)
  -- a table only on one side is already listed above, once
  AND EXISTS (SELECT 1 FROM #col x WHERE x.Side = 'R' AND x.TableName = COALESCE(r.TableName, t.TableName))
  AND EXISTS (SELECT 1 FROM #col x WHERE x.Side = 'T' AND x.TableName = COALESCE(r.TableName, t.TableName));

INSERT INTO @diff
SELECT N'index', COALESCE(r.TableName, t.TableName) + '.' + COALESCE(r.IndexName, t.IndexName),
       CASE WHEN t.IndexName IS NULL THEN N'only in $(REF)'
            WHEN r.IndexName IS NULL THEN N'only in $(TARGET)'
            ELSE N'$(REF) ' + r.Shape + N' / $(TARGET) ' + t.Shape END
FROM (SELECT * FROM #idx WHERE Side = 'R') r
FULL JOIN (SELECT * FROM #idx WHERE Side = 'T') t ON t.TableName = r.TableName AND t.IndexName = r.IndexName
WHERE (r.IndexName IS NULL OR t.IndexName IS NULL OR r.Shape <> t.Shape)
  AND EXISTS (SELECT 1 FROM #idx x WHERE x.Side = 'R' AND x.TableName = COALESCE(r.TableName, t.TableName))
  AND EXISTS (SELECT 1 FROM #idx x WHERE x.Side = 'T' AND x.TableName = COALESCE(r.TableName, t.TableName));

INSERT INTO @diff
SELECT N'permission code', COALESCE(r.Code, t.Code), CASE WHEN t.Code IS NULL THEN N'only in $(REF)' ELSE N'only in $(TARGET)' END
FROM (SELECT * FROM #perm WHERE Side = 'R') r
FULL JOIN (SELECT * FROM #perm WHERE Side = 'T') t ON t.Code = r.Code
WHERE r.Code IS NULL OR t.Code IS NULL;

SELECT Kind, Name, Difference FROM @diff ORDER BY Kind, Name;

DECLARE @n INT = (SELECT COUNT(*) FROM @diff);
DECLARE @o INT = (SELECT COUNT(*) FROM #obj WHERE Side = 'T');
PRINT CONCAT('compare-schema: $(TARGET) against $(REF): ', @o, ' objects compared, ', @n, ' difference(s)',
             CASE WHEN @n = 0 THEN ' - the schemas match.' ELSE ' - listed above.' END);
