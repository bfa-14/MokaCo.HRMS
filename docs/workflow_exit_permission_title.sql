/* ============================================================================
   EXIT PERMISSION  -  optional title override
   MokaCo_HRMS   (ALTERs usp_ExitPermission_Create only — does NOT touch the table)
   ----------------------------------------------------------------------------
   The create procedure composed the request title itself. It still does — that
   format lives HERE and only here, so nothing can drift from it — but it now
   accepts an optional @Title. Passed a non-blank value, it uses it verbatim;
   left NULL or blank, it composes the standard title exactly as before.

   Based on the DEPLOYED procedure (columns RequestedMinutes/ApprovedMinutes,
   title format "(N min requested)"), which had diverged from the original
   workflow_exit_permission.sql. Deliberately a focused CREATE OR ALTER: that
   file DROPs and recreates the table, so it must never be re-run for a proc change.
   ============================================================================ */
USE MokaCo_HRMS;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE workflow.usp_ExitPermission_Create
    @EmployeeId     INT,
    @RaisedByUserId INT,
    @ExitDate       DATE,
    @FromTime       TIME,
    @ToTime         TIME,
    @Reason         NVARCHAR(300),
    @ConvertToLeave BIT = 1,
    @Title          NVARCHAR(150) = NULL   -- optional override; NULL/blank = auto-compose
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ToTime <= @FromTime
    BEGIN RAISERROR('The return time must be after the leaving time.', 16, 1); RETURN; END
    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = ''
    BEGIN RAISERROR('A reason is required for an exit permission.', 16, 1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId AND IsDeleted = 0)
    BEGIN RAISERROR('Employee not found.', 16, 1); RETURN; END

    DECLARE @Minutes INT = DATEDIFF(MINUTE, @FromTime, @ToTime);

    IF EXISTS (
        SELECT 1 FROM workflow.EXIT_PERMISSION ep
        JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
        WHERE ep.EmployeeId = @EmployeeId AND ep.ExitDate = @ExitDate
          AND r.[Status] IN ('Pending','Approved'))
    BEGIN
        RAISERROR('This employee already has a pending or approved exit permission for that date.', 16, 1);
        RETURN;
    END

    /* The standard title — the ONE definition of the format. The optional override
       wins only when it is a non-blank string. */
    DECLARE @AutoTitle NVARCHAR(150) =
        CONCAT(N'Exit permission ', CONVERT(CHAR(10), @ExitDate, 23), N' ',
               LEFT(CONVERT(VARCHAR(8), @FromTime, 108), 5), N'-',
               LEFT(CONVERT(VARCHAR(8), @ToTime, 108), 5),
               N' (', @Minutes, N' min requested)');

    DECLARE @FinalTitle NVARCHAR(150) =
        COALESCE(NULLIF(LTRIM(RTRIM(@Title)), N''), @AutoTitle);

    DECLARE @Submitted TABLE (RequestInstanceId INT, [Status] VARCHAR(20),
                              CurrentStepNo INT, WorkflowDefinitionId INT, WorkflowVersion INT);

    BEGIN TRAN;

    INSERT INTO @Submitted
    EXEC workflow.usp_Request_Submit
         @RequestTypeCode = 'EXIT_PERMISSION', @EmployeeId = @EmployeeId,
         @RaisedByUserId = @RaisedByUserId, @Title = @FinalTitle;

    DECLARE @ReqId INT = (SELECT TOP 1 RequestInstanceId FROM @Submitted);

    IF @ReqId IS NULL
    BEGIN
        ROLLBACK TRAN;
        RAISERROR('The request could not be submitted - check that an EXIT_PERMISSION workflow is published.', 16, 1);
        RETURN;
    END

    INSERT INTO workflow.EXIT_PERMISSION
        (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime,
         RequestedMinutes, ApprovedMinutes, Reason, ConvertToLeave)
    VALUES (@ReqId, @EmployeeId, @ExitDate, @FromTime, @ToTime,
            @Minutes, @Minutes, @Reason, @ConvertToLeave);

    DECLARE @NewId INT = CAST(SCOPE_IDENTITY() AS INT);

    COMMIT TRAN;

    IF EXISTS (SELECT 1 FROM @Submitted WHERE [Status] = 'Approved')
        EXEC workflow.usp_ExitPermission_ApplyToAttendance @ExitPermissionId = @NewId;

    SELECT ep.ExitPermissionId, ep.RequestInstanceId, ep.EmployeeId, ep.ExitDate,
           ep.FromTime, ep.ToTime, ep.RequestedMinutes, ep.ApprovedMinutes,
           ep.ConvertToLeave, r.[Status], r.CurrentStepNo, r.Title
    FROM workflow.EXIT_PERMISSION ep
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
    WHERE ep.ExitPermissionId = @NewId;
END;
GO
