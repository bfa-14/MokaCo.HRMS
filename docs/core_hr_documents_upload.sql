/* ============================================================================
   Documents — file upload support (migration on top of the Core/HR script)
   Adds a single GetById proc used by the download endpoint. The file bytes live
   on the server's document storage folder; the DB keeps the path/metadata.
   Run this against MokaCo_HRMS after the core_hr_schema_and_procedures.sql.
   ============================================================================ */
USE MokaCo_HRMS;
GO

/* Fetch a single document's metadata by id (used to stream the file back). */
CREATE OR ALTER PROCEDURE hr.usp_Document_GetById
    @DocumentId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DocumentId, EmployeeId, FileName, StoragePath, ContentType, SizeBytes, UploadedUtc
    FROM hr.DOCUMENT
    WHERE DocumentId = @DocumentId;
END;
GO
