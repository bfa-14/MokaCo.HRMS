/* ============================================================================
   cases/06_crosscutting.sql — X2 (QUOTED_IDENTIFIER vs filtered indexes) and the
   database-side evidence for R3 (approval effects) on the real August roster.
   ============================================================================ */
SET NOCOUNT ON;
DECLARE @act NVARCHAR(600), @pass BIT, @t NVARCHAR(1000), @n INT;

/* X2: modules compiled with QUOTED_IDENTIFIER OFF that write to a table carrying a filtered index */
;WITH filtered AS (
    SELECT DISTINCT OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) AS tbl FROM sys.indexes i WHERE i.has_filter = 1),
mods AS (
    SELECT s.name + '.' + o.name AS obj, m.definition
    FROM sys.sql_modules m JOIN sys.objects o ON o.object_id = m.object_id JOIN sys.schemas s ON s.schema_id = o.schema_id
    WHERE m.uses_quoted_identifier = 0)
SELECT @n = COUNT(*), @act = ISNULL(STRING_AGG(CONCAT(mods.obj, ' writes ', f.tbl), '; '), 'none')
FROM mods CROSS JOIN filtered f
WHERE mods.definition LIKE '%' + f.tbl + '%'
  AND (mods.definition LIKE '%INSERT%' + f.tbl + '%' OR mods.definition LIKE '%UPDATE%' + f.tbl + '%' OR mods.definition LIKE '%DELETE%' + f.tbl + '%' OR mods.definition LIKE '%MERGE%' + f.tbl + '%');
SET @pass = CASE WHEN @n = 0 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'X2a', 'no module with uses_quoted_identifier = 0 does DML on a table with a filtered index (hr.EMPLOYEE, booking.BOOKING, core.EMAIL_OUTBOX, ...)', 'none', @act, @pass;
SET @t = (SELECT 'X2: modules compiled with QUOTED_IDENTIFIER OFF (all of them): ' + ISNULL(STRING_AGG(s.name + '.' + o.name, ', '), 'none')
          FROM sys.sql_modules m JOIN sys.objects o ON o.object_id = m.object_id JOIN sys.schemas s ON s.schema_id = o.schema_id WHERE m.uses_quoted_identifier = 0);
EXEC dbo.QA_Note @t;
SET @t = (SELECT 'X2: filtered indexes present: ' + STRING_AGG(CONCAT(OBJECT_SCHEMA_NAME(i.object_id), '.', OBJECT_NAME(i.object_id), '.', i.name), ', ') FROM sys.indexes i WHERE i.has_filter = 1);
EXEC dbo.QA_Note @t;

/* R3 evidence on REAL data: an approved roster-approval request whose effect was never applied */
SELECT @n = COUNT(*), @act = ISNULL(STRING_AGG(CONCAT('request ', ri.RequestInstanceId, ' approved ', CONVERT(VARCHAR(16), ri.ClosedAt, 120), ' branch ', ra.BranchId, ' month ', CONVERT(VARCHAR(7), ra.MonthDate, 120), ' AppliedAt=', ISNULL(CONVERT(VARCHAR(16), ra.AppliedAt, 120), 'NULL')), '; '), 'none')
FROM workflow.ROSTER_APPROVAL ra JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
JOIN hr.BRANCH b ON b.BranchId = ra.BranchId
WHERE ri.[Status] = 'Approved' AND ra.AppliedAt IS NULL AND b.Name <> N'QA Branch';
SET @act = CONCAT(@n, ' approved-but-unapplied: ', @act); SET @pass = CASE WHEN @n = 0 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'R3h', 'real data: every APPROVED roster-approval request has had its effect applied (AppliedAt set, month Approved)', '0 approved-but-unapplied', @act, @pass;
GO
