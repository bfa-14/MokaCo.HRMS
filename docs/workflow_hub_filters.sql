/* ============================================================================
   REQUESTS HUB FILTERS  -  status + date range
   MokaCo_HRMS   (replaces usp_Request_GetForUser from workflow_requests_for_user.sql)
   ----------------------------------------------------------------------------
   The hub could only say "open" or "everything". It now filters by STATUS and by
   DATE, with one rule that matters more than the rest:

     A PENDING REQUEST IS NEVER HIDDEN BY A DATE FILTER.

   Pending means someone still has to act. A request raised nine weeks ago that
   nobody signed is not less urgent than yesterday's - it is more urgent. If a date
   range could hide it, the hub would quietly lose work, and the person waiting
   would never know why nothing happened.

   So the date range applies to CLOSED requests only. Open work always shows.
   ============================================================================ */
USE MokaCo_HRMS;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE workflow.usp_Request_GetForUser
    @UserId        INT,
    @Status        VARCHAR(20) = NULL,   -- Pending/Approved/Rejected/Cancelled; NULL = any
    @IncludeClosed BIT  = 0,             -- ignored when @Status names a closed state
    @RequestTypeId INT  = NULL,
    @FromDate      DATE = NULL,          -- on SubmittedAt; applies to CLOSED rows only
    @ToDate        DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /* asking for a closed status implies wanting closed rows */
    IF @Status IS NOT NULL AND @Status <> 'Pending' SET @IncludeClosed = 1;

    DECLARE @EmployeeId INT = (SELECT EmployeeId FROM hr.EMPLOYEE
                               WHERE UserId = @UserId AND IsDeleted = 0);

    SELECT
        r.RequestInstanceId,
        rt.Code AS RequestTypeCode,
        rt.Name AS RequestTypeName,
        r.EmployeeId,
        e.FullName AS EmployeeName,
        b.Name     AS BranchName,
        r.Title,
        r.[Status],
        r.CurrentStepNo,
        cur.Name AS CurrentStepName,
        r.SubmittedAt,
        r.ClosedAt,
        r.ClosedReason,
        d.[Version] AS WorkflowVersion,
        DATEDIFF(DAY, r.SubmittedAt, ISNULL(r.ClosedAt, SYSUTCDATETIME())) AS DaysOpen,

        CAST(CASE WHEN r.[Status] = 'Pending' AND EXISTS (
                SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE si
                WHERE si.RequestInstanceId = r.RequestInstanceId
                  AND si.StepNo   = r.CurrentStepNo
                  AND si.[Status] = 'Pending'
                  AND (si.ResolvedUserId = @UserId
                       OR (si.ApproverType = 'Role'
                           AND EXISTS (SELECT 1 FROM security.USER_ROLE ur
                                       WHERE ur.UserId = @UserId
                                         AND ur.RoleId = si.ApproverRoleId))))
             THEN 1 ELSE 0 END AS BIT) AS WaitingOnMe,

        CAST(CASE WHEN r.EmployeeId = @EmployeeId THEN 1 ELSE 0 END AS BIT) AS IsMine,
        CAST(CASE WHEN r.RaisedByUserId = @UserId THEN 1 ELSE 0 END AS BIT) AS RaisedByMe,
        CAST(CASE WHEN EXISTS (
                SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE si
                WHERE si.RequestInstanceId = r.RequestInstanceId
                  AND si.ActedByUserId = @UserId)
             THEN 1 ELSE 0 END AS BIT) AS IActedOnIt,

        my.[Status]   AS MyStepStatus,
        my.Decision   AS MyDecision,
        my.ActedAt    AS MyActedAt,
        my.Comment    AS MyComment      -- the note left with the decision, e.g. a rejection reason

    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.REQUEST_TYPE rt       ON rt.RequestTypeId = r.RequestTypeId
    JOIN workflow.WORKFLOW_DEFINITION d ON d.WorkflowDefinitionId = r.WorkflowDefinitionId
    JOIN hr.EMPLOYEE e                  ON e.EmployeeId = r.EmployeeId
    JOIN hr.BRANCH b                    ON b.BranchId = e.BranchId
    LEFT JOIN workflow.REQUEST_STEP_INSTANCE cur
           ON cur.RequestInstanceId = r.RequestInstanceId AND cur.StepNo = r.CurrentStepNo
    OUTER APPLY (
        SELECT TOP 1 si.[Status], si.Decision, si.ActedAt, si.Comment
        FROM workflow.REQUEST_STEP_INSTANCE si
        WHERE si.RequestInstanceId = r.RequestInstanceId
          AND si.ActedByUserId = @UserId
        ORDER BY si.ActedAt DESC
    ) my

    WHERE
        (
              r.EmployeeId     = @EmployeeId
           OR r.RaisedByUserId = @UserId
           OR EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE si
                      WHERE si.RequestInstanceId = r.RequestInstanceId
                        AND (si.ResolvedUserId = @UserId
                             OR si.ActedByUserId = @UserId
                             OR (si.ApproverType = 'Role'
                                 AND EXISTS (SELECT 1 FROM security.USER_ROLE ur
                                             WHERE ur.UserId = @UserId
                                               AND ur.RoleId = si.ApproverRoleId))))
        )
      AND (@Status IS NULL OR r.[Status] = @Status)
      AND (@IncludeClosed = 1 OR r.[Status] = 'Pending')
      AND (@RequestTypeId IS NULL OR r.RequestTypeId = @RequestTypeId)
      /* the date range never hides open work - see the header */
      AND (r.[Status] = 'Pending'
           OR ((@FromDate IS NULL OR CAST(r.SubmittedAt AS DATE) >= @FromDate)
           AND (@ToDate   IS NULL OR CAST(r.SubmittedAt AS DATE) <= @ToDate)))

    ORDER BY
        CASE WHEN r.[Status] = 'Pending' THEN 0 ELSE 1 END,
        r.SubmittedAt DESC;
END;
GO
