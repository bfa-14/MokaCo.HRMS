/* ============================================================================
   ATTENDANCE - IMPORT PREVIEW SUPPORT  -  RE-RUNNABLE
   SQL Server 2025  -  database MokaCo_HRMS
   ----------------------------------------------------------------------------
   Run AFTER docs/attendance_full_v3.sql. Adds ONE read-only procedure. It creates
   no tables, changes no columns and writes nothing.

   WHY IT EXISTS
     The import wizard shows the user what an upload WILL do before anything is
     written: which rows are already in the system and will be skipped, which are on
     a PIN nobody is enrolled on. Unknown devices and unenrolled PINs can be worked
     out from usp_Device_GetAll and usp_EmployeeDevice_GetAll, but "have I already
     got this exact punch?" cannot - RAW_DEVICE_LOG has no read path by DedupHash.

     Without this, the preview would have to GUESS, and a preview that disagrees with
     the import it is previewing is worse than no preview at all: it teaches the user
     to distrust the screen.

   The set-based STRING_SPLIT parameter mirrors the pattern the schema contract
   already uses in usp_ShiftAssignment_GenerateRange_Bulk.
   ============================================================================ */
USE MokaCo_HRMS;
GO

/* Of these dedup hashes, which does the system ALREADY have?
   Read-only. The caller (the import preview) uses the answer to mark rows as
   "already imported - will be skipped" before writing a single row. */
CREATE OR ALTER PROCEDURE attendance.usp_RawLog_GetExistingHashes
    @Hashes NVARCHAR(MAX)          -- comma-separated SHA-256 hex values
AS
BEGIN
    SET NOCOUNT ON;

    SELECT r.DedupHash
    FROM attendance.RAW_DEVICE_LOG r
    JOIN STRING_SPLIT(@Hashes, ',') s ON s.value = r.DedupHash;
END;
GO
