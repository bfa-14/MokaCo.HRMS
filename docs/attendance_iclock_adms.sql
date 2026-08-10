/* ============================================================================
   ATTENDANCE - ZKTeco iclock/ADMS PUSH RECEIVER  -  RE-RUNNABLE
   SQL Server 2025  -  database MokaCo_HRMS
   ----------------------------------------------------------------------------
   Run AFTER docs/attendance_full_v3.sql and docs/attendance_device_apikey.sql.
   RE-RUN IT any time you re-run attendance_full_v3.sql, because that script DROPS
   AND RECREATES attendance.DEVICE, which takes these columns with it.

   Deploy with:  sqlcmd -S localhost -d MokaCo_HRMS -E -C -I -i docs\attendance_iclock_adms.sql

   WHY THIS EXISTS
     The UA300 Pro cannot be taught to send a JWT, or a custom header, or JSON. What it
     CAN do is the vendor's own "cloud server" protocol: plain-text GET/POST to a fixed
     set of paths under /iclock, identifying itself with nothing but ?SN=<serial> in the
     query string. So the serial IS the identity, and the allowlist below is what turns
     that into an authorisation decision instead of an open door.

   WHAT IT CHANGES, AND WHY EACH PIECE
     1. DEVICE.Name        - the terminal's human label ("Verdun front door"). A serial
                             like BRM9243900022 tells an HR user nothing about which
                             machine in which room has gone quiet.
     2. DEVICE.LastPushUtc - LAST TIME PUNCHES ARRIVED, which is NOT the same fact as
                             LastSyncUtc (last contact of any kind). A terminal polls
                             /iclock/getrequest every few seconds even when nobody has
                             touched it, so LastSyncUtc alone can look perfectly healthy
                             while the fingerprint sensor is dead. Two columns, two
                             questions: "is it plugged in" and "is it recording anyone".
     3. PunchesToday       - so the Devices card can say "14 punches today" rather than
                             leaving a human to infer health from a timestamp.

   WHAT IT DELIBERATELY DOES NOT DO
     It does not add a table. attendance.DEVICE already IS the device registry - serial,
     branch, active flag, per-device API key - and a second one would mean two answers to
     "is this terminal allowed to send us pay data".
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

USE MokaCo_HRMS;
GO

/* -- 1. the two new columns ----------------------------------------------- */
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('attendance.DEVICE') AND name = 'Name')
BEGIN
    ALTER TABLE attendance.DEVICE
        ADD [Name] NVARCHAR(100) NULL;   -- "Verdun front door". NULL = never labelled; the UI falls back to the serial.
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('attendance.DEVICE') AND name = 'LastPushUtc')
BEGIN
    ALTER TABLE attendance.DEVICE
        ADD LastPushUtc DATETIME2 NULL;  -- last time PUNCHES arrived. NULL = the machine has never sent one.
END
GO

/* -- 2. reading devices ---------------------------------------------------- */
/* PunchesToday is counted on the punch's OWN timestamp, not on when the row was written.
   That is the number a human means: a terminal that queued 40 punches through a dead link
   and flushed them at 18:00 recorded them across the day, and saying "40 punches today"
   at the moment of the flush would be a spike that never happened.

   The date compared against is the SERVER'S LOCAL date (SYSDATETIME, not SYSUTCDATETIME),
   because the terminal stamps punches in ITS OWN local wall-clock time and we store that
   verbatim - see the note on usp_Device_TouchPush below. Comparing a local wall-clock
   column against a UTC "today" would silently drop the first hours of every morning. */
CREATE OR ALTER PROCEDURE attendance.usp_Device_GetAll
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.DeviceId, d.SerialNumber, d.[Name], d.BranchId, b.[Name] AS BranchName,
           d.DepartmentId, dp.[Name] AS DepartmentName, d.IsActive,
           d.LastSyncUtc, d.LastPushUtc,
           PunchesToday = (
               SELECT COUNT(*)
               FROM attendance.RAW_DEVICE_LOG r
               WHERE r.DeviceId = d.DeviceId
                 AND CAST(r.PunchTimeUtc AS DATE) = CAST(SYSDATETIME() AS DATE))
    FROM attendance.DEVICE d
    JOIN hr.BRANCH b           ON b.BranchId = d.BranchId
    LEFT JOIN hr.DEPARTMENT dp ON dp.DepartmentId = d.DepartmentId
    ORDER BY b.[Name], d.SerialNumber;
END;
GO

/* The push endpoint sends a SERIAL, not an id - resolve it here.
   IsActive is returned rather than filtered on, so the API can tell "retired" from
   "never heard of" and log the difference. Those two are the same to an attacker and
   very different to whoever is trying to work out why a shop has gone quiet. */
CREATE OR ALTER PROCEDURE attendance.usp_Device_GetBySerial
    @SerialNumber VARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DeviceId, SerialNumber, [Name], BranchId, DepartmentId, IsActive,
           LastSyncUtc, LastPushUtc
    FROM attendance.DEVICE
    WHERE SerialNumber = @SerialNumber;
END;
GO

/* -- 3. writing devices (now carrying the label) --------------------------- */
/* @Name is defaulted so any caller written before this script still compiles and runs. */
CREATE OR ALTER PROCEDURE attendance.usp_Device_Create
    @SerialNumber VARCHAR(60),
    @BranchId     INT,
    @DepartmentId INT = NULL,
    @Name         NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO attendance.DEVICE (SerialNumber, BranchId, DepartmentId, [Name])
    VALUES (@SerialNumber, @BranchId, @DepartmentId, NULLIF(LTRIM(RTRIM(@Name)), N''));

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS DeviceId;
END;
GO

CREATE OR ALTER PROCEDURE attendance.usp_Device_Update
    @DeviceId     INT,
    @SerialNumber VARCHAR(60),
    @BranchId     INT,
    @DepartmentId INT = NULL,
    @IsActive     BIT,
    @Name         NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE attendance.DEVICE
    SET SerialNumber = @SerialNumber,
        BranchId     = @BranchId,
        DepartmentId = @DepartmentId,
        IsActive     = @IsActive,
        [Name]       = NULLIF(LTRIM(RTRIM(@Name)), N'')
    WHERE DeviceId = @DeviceId;
END;
GO

/* -- 4. "punches just arrived" -------------------------------------------- */
/* A push is also contact, so this stamps BOTH columns: a device that is pushing is
   self-evidently alive, and leaving LastSyncUtc behind would make a busy terminal look
   offline. The reverse is not true, which is why usp_Device_TouchSync still exists on
   its own - a poll proves the network, not the sensor.

   A NOTE ON THE CLOCK, because it is load-bearing and easy to get wrong later:
   RAW_DEVICE_LOG.PunchTimeUtc is named Utc but is treated as LOCAL WALL-CLOCK TIME
   everywhere that matters - usp_Attendance_ProcessRawLogs groups by CAST(PunchTimeUtc AS
   DATE) and compares it against SHIFT.StartTime, which is a local time of day. The Excel
   import path already stores the spreadsheet's printed time verbatim. So the ADMS
   receiver stores what the terminal sent, unconverted, and the three ingestion paths keep
   agreeing with each other. Converting only this one path to true UTC would shift every
   pushed punch by the UTC offset and quietly move night shifts onto the wrong day. */
CREATE OR ALTER PROCEDURE attendance.usp_Device_TouchPush
    @DeviceId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE attendance.DEVICE
    SET LastSyncUtc = SYSUTCDATETIME(),
        LastPushUtc = SYSUTCDATETIME()
    WHERE DeviceId = @DeviceId;
END;
GO

/* -- 5. the optional shared key ------------------------------------------- */
/* SECOND factor, not the first. The allowlist (serial must exist and be active) always
   applies. This adds "...and the URL carries the agreed key", for firmware whose Server
   Address field tolerates a path or query suffix.

   EMPTY MEANS OFF, and that is a deliberate default rather than an oversight: shipping it
   switched ON with a guessable value would be worse than shipping it off, and shipping it
   ON with a real value would lock out the device before anyone had configured it. Set a
   value here only once you have confirmed the terminal actually sends it - the API logs
   which check admitted each request, so you can tell.

   It is a URL parameter, so it is a BEARER secret in a query string: it lands in access
   logs and proxy logs. It is worth having as a cheap second gate over TLS; it is not worth
   mistaking for authentication. */
IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'IclockSharedKey')
BEGIN
    INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, [Description])
    VALUES ('IclockSharedKey', N'', 'string',
            N'Optional shared key the fingerprint terminal must append to its cloud-server URL as &key=... . Empty = disabled, and the device allowlist stands alone.');
END
GO

/* -- 6. seed the terminal --------------------------------------------------
   SET @Serial TO THE SERIAL PRINTED ON THE BACK OF THE MACHINE (it is also on the
   terminal itself under Menu > System Info > Device Info). The serial is the whole
   identity in this protocol, so a wrong value here means every push is refused 403.

   Nothing below runs unless you change @Serial from the placeholder - a device seeded
   under a made-up serial is an allowlist entry that admits nobody and confuses everybody.
   You can equally add it through the UI: Attendance > Devices > Add device. */
DECLARE @Serial   VARCHAR(60)    = 'REPLACE-WITH-REAL-SERIAL';
DECLARE @Label    NVARCHAR(100)  = N'UA300 Pro';
DECLARE @BranchId INT            = (SELECT MIN(BranchId) FROM hr.BRANCH WHERE IsActive = 1);

IF @Serial = 'REPLACE-WITH-REAL-SERIAL'
    PRINT 'Device seed SKIPPED: set @Serial to the terminal''s real serial number first (or add it on Attendance > Devices).';
ELSE IF EXISTS (SELECT 1 FROM attendance.DEVICE WHERE SerialNumber = @Serial)
    PRINT 'Device seed skipped: that serial is already registered.';
ELSE
BEGIN
    INSERT INTO attendance.DEVICE (SerialNumber, [Name], BranchId, IsActive)
    VALUES (@Serial, @Label, @BranchId, 1);
    PRINT 'Device seeded. It can now push; no API key is needed for the /iclock path.';
END
GO

/* -- verify: what the receiver will accept -------------------------------- */
SELECT DeviceId, SerialNumber, [Name], BranchId, IsActive,
       LastSyncUtc, LastPushUtc,
       PushStatus = CASE WHEN IsActive = 1 THEN 'allowed on /iclock' ELSE 'RETIRED - pushes refused 403' END
FROM attendance.DEVICE
ORDER BY SerialNumber;

SELECT SettingKey, SettingValue,
       Effect = CASE WHEN NULLIF(LTRIM(RTRIM(SettingValue)), N'') IS NULL
                     THEN 'OFF - allowlist alone'
                     ELSE 'ON - &key= must match' END
FROM core.SETTING
WHERE SettingKey = 'IclockSharedKey';
GO
