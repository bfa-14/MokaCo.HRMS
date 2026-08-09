/* ============================================================================
   ATTENDANCE - DEVICE PUSH AUTHENTICATION  -  RE-RUNNABLE
   SQL Server 2025  -  database MokaCo_HRMS
   ----------------------------------------------------------------------------
   Run AFTER docs/attendance_full_v3.sql. RE-RUN IT any time you re-run that script,
   because attendance_full_v3.sql DROPS AND RECREATES attendance.DEVICE, which takes
   this column (and every issued key) with it.

   WHY THIS IS A SEPARATE FILE
     attendance_full_v3.sql is the schema CONTRACT and is not ours to edit. It has no
     column for a device credential. So this script ADDS one, additively, rather than
     forking the contract.

   WHY IT EXISTS AT ALL
     POST /api/attendance/punch is called by a fingerprint terminal. There is no human
     at a fingerprint terminal: no login, no JWT, no bearer token. Leaving the endpoint
     unauthenticated would let anyone who can reach the network POST punches for any
     PIN - which is forging attendance, which is forging PAY.

     So each device authenticates as ITSELF, with a per-device API key sent as the
     X-Device-Key header. Only the SHA-256 HASH is stored. The plaintext is shown to the
     administrator exactly once, when it is issued, and cannot be recovered afterwards -
     a lost key is re-issued, never looked up.

     Known weaknesses, stated rather than hidden:
       - It is a BEARER secret. Anyone who reads it (or sniffs plain HTTP) can replay it.
         It MUST only ever travel over TLS.
       - It does not sign the punch body, so a key-holder can still post any PIN and any
         timestamp. It authenticates the DEVICE, not the punch.
       - There is no rotation schedule; rotation is manual, via POST /api/devices/{id}/api-key.
     Mitigating this properly means request signing (HMAC over body + timestamp + nonce),
     which the terminals in question do not support.
   ============================================================================ */
USE MokaCo_HRMS;
GO

/* -- 1. the credential column --------------------------------------------- */
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('attendance.DEVICE') AND name = 'ApiKeyHash')
BEGIN
    ALTER TABLE attendance.DEVICE
        ADD ApiKeyHash   VARCHAR(64) NULL,   -- SHA-256 hex. NULL = no key issued yet = device cannot push.
            ApiKeyIssued DATETIME2   NULL;   -- when it was last issued, so a stale key is visible.
END
GO

/* -- 2. what the punch endpoint authenticates against ---------------------- */
/* Returns the HASH, never a key. An inactive device is still returned so the API can
   answer "known but retired" (403) rather than "unknown" (401) - the difference matters
   when you are trying to work out why a terminal in a shop has gone quiet. */
CREATE OR ALTER PROCEDURE attendance.usp_Device_GetAuth
    @SerialNumber VARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DeviceId, SerialNumber, IsActive, ApiKeyHash
    FROM attendance.DEVICE
    WHERE SerialNumber = @SerialNumber;
END;
GO

/* -- 3. issue / rotate a key ---------------------------------------------- */
/* The API generates the key and hashes it; only the hash arrives here. Writing a new
   hash INVALIDATES the previous key immediately - that is the revocation path. */
CREATE OR ALTER PROCEDURE attendance.usp_Device_SetApiKey
    @DeviceId   INT,
    @ApiKeyHash VARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE attendance.DEVICE
    SET ApiKeyHash = @ApiKeyHash, ApiKeyIssued = SYSUTCDATETIME()
    WHERE DeviceId = @DeviceId;
END;
GO

/* -- verify: which devices can actually push ------------------------------ */
SELECT DeviceId, SerialNumber, IsActive,
       CASE WHEN ApiKeyHash IS NULL THEN 'NO KEY - cannot push' ELSE 'key issued' END AS PushStatus,
       ApiKeyIssued
FROM attendance.DEVICE
ORDER BY SerialNumber;
GO
