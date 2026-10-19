/* QA3 (unit B handoff) scenario, docs/105_qa3_security.sql after 100: the Unresolved PINs list
   (attendance.usp_RawLog_GetUnresolved) leaves out the punches HR set aside (RAW_DEVICE_LOG.DismissedUtc). Runs inside
   BEGIN TRAN ... ROLLBACK on a dev database (rows named 'QA3 ...'); RAISERRORs on a wrong result, prints
   'ok unresolved_set_aside' otherwise. sqlcmd -I -b -d <db> -i tests/qa3/security/unresolved_set_aside.sql */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
IF COL_LENGTH('attendance.RAW_DEVICE_LOG', 'DismissedUtc') IS NULL
    RAISERROR('unresolved_set_aside: apply 100_qa3_attendance.sql, then 105, first', 16, 1);
GO
BEGIN TRAN;
DECLARE @dev INT = (SELECT TOP (1) DeviceId FROM attendance.DEVICE ORDER BY DeviceId);
INSERT attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, PunchTimeUtc, PunchType, [Source], DedupHash, EmployeeId, DismissedUtc) VALUES
    (@dev, 'QA3-901', '2026-09-01T08:00:00', 0, 'Device', 'QA3-unresolved-1', NULL, NULL),
    (@dev, 'QA3-902', '2026-09-01T08:01:00', 0, 'Device', 'QA3-unresolved-2', NULL, SYSUTCDATETIME());
DECLARE @r TABLE (RawLogId BIGINT, DeviceId INT, SerialNumber NVARCHAR(100), EnrollPin NVARCHAR(50), PunchTimeUtc DATETIME2, PunchType SMALLINT,
                  [Source] NVARCHAR(20), DedupHash NVARCHAR(200), IsProcessed BIT, ImportBatchId INT, CreatedUtc DATETIME2);
INSERT @r EXEC attendance.usp_RawLog_GetUnresolved @FromDate = '2026-09-01', @ToDate = '2026-09-01';
IF NOT EXISTS (SELECT 1 FROM @r WHERE EnrollPin = 'QA3-901') OR EXISTS (SELECT 1 FROM @r WHERE EnrollPin = 'QA3-902')
    RAISERROR('unresolved_set_aside: the waiting punch must be listed and the one set aside left out', 16, 1);
ROLLBACK;
PRINT 'ok unresolved_set_aside';
