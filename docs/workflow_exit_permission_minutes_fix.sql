/* ============================================================================
   FIX: usp_ExitPermission_GetForEmployee still selected ep.Minutes
   MokaCo_HRMS
   ----------------------------------------------------------------------------
   The EXIT_PERMISSION table's Minutes column was renamed to RequestedMinutes (and
   ApprovedMinutes added), but this read procedure was never updated with the others.
   It therefore fails outright with "Invalid column name 'Minutes'", which means
   GET /api/exit-permissions/mine returns a 500 — the employee's own list of exit
   permissions cannot be read at all.

   This only replaces the SELECT list: RequestedMinutes and ApprovedMinutes are both
   returned, because the caller needs to show "granted 120 of 180" wherever they differ.
   ============================================================================ */
USE MokaCo_HRMS;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE workflow.usp_ExitPermission_GetForEmployee
    @EmployeeId INT, @FromDate DATE = NULL, @ToDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ep.ExitPermissionId, ep.RequestInstanceId, ep.ExitDate, ep.FromTime,
           ep.ToTime, ep.RequestedMinutes, ep.ApprovedMinutes, ep.Reason, ep.ConvertToLeave,
           r.[Status], r.CurrentStepNo, si.Name AS CurrentStepName,
           ep.AppliedToAttendanceAt, r.SubmittedAt, r.ClosedAt, r.ClosedReason
    FROM workflow.EXIT_PERMISSION ep
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
    LEFT JOIN workflow.REQUEST_STEP_INSTANCE si
           ON si.RequestInstanceId = r.RequestInstanceId AND si.StepNo = r.CurrentStepNo
    WHERE ep.EmployeeId = @EmployeeId
      AND (@FromDate IS NULL OR ep.ExitDate >= @FromDate)
      AND (@ToDate   IS NULL OR ep.ExitDate <= @ToDate)
    ORDER BY ep.ExitDate DESC;
END;
GO
