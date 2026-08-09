/* ============================================================================
   usp_Request_GetForUser  -  everything ONE user is involved in
   MokaCo_HRMS   (run after workflow_core.sql)
   ----------------------------------------------------------------------------
   The two existing reads each answer a narrower question:
     usp_Request_GetPendingForUser  - only what is waiting on me RIGHT NOW
     usp_Request_GetForEmployee     - only what was raised FOR me
   Neither shows a request I approved last month, and neither shows closed work.

   This returns every request a user is connected to, in ANY capacity, with flags
   saying HOW - so one call feeds the whole hub and the frontend can slice it into
   tabs without asking the server again.

   FOUR WAYS TO BE INVOLVED (a request can be several at once):
     WaitingOnMe  - it is sitting on my signature this moment
     IsMine       - it was raised FOR me (I am the employee)
     RaisedByMe   - I typed it (mine, or on someone else's behalf)
     IActedOnIt   - I approved, rejected or signed a step at some point

   Closed requests are EXCLUDED by default. @IncludeClosed = 1 brings back
   approved / rejected / cancelled ones too, which is what the "show completed"
   toggle sends.
   ============================================================================ */
USE MokaCo_HRMS;
GO

DROP PROCEDURE IF EXISTS workflow.usp_Request_GetForUser;
GO

CREATE PROCEDURE workflow.usp_Request_GetForUser
    @UserId        INT,
    @IncludeClosed BIT = 0,            -- 1 = also approved / rejected / cancelled
    @RequestTypeId INT = NULL,         -- optional filter
    @FromDate      DATE = NULL,        -- on SubmittedAt
    @ToDate        DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /* the caller's employee record, if they have one. An admin account with no
       employee still sees requests they raised or approved - they simply have
       nothing that was raised FOR them. */
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

        /* ---- how THIS user is involved ---- */

        /* waiting on my signature right now: either the current step resolved to me
           personally, or it is a Role step and I hold that role */
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

        /* I signed something on it, whenever that was */
        CAST(CASE WHEN EXISTS (
                SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE si
                WHERE si.RequestInstanceId = r.RequestInstanceId
                  AND si.ActedByUserId = @UserId)
             THEN 1 ELSE 0 END AS BIT) AS IActedOnIt,

        /* what I did, and when - so a history list can say "you approved this" */
        my.[Status] AS MyStepStatus,
        my.ActedAt  AS MyActedAt

    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.REQUEST_TYPE rt       ON rt.RequestTypeId = r.RequestTypeId
    JOIN workflow.WORKFLOW_DEFINITION d ON d.WorkflowDefinitionId = r.WorkflowDefinitionId
    JOIN hr.EMPLOYEE e                  ON e.EmployeeId = r.EmployeeId
    JOIN hr.BRANCH b                    ON b.BranchId = e.BranchId
    LEFT JOIN workflow.REQUEST_STEP_INSTANCE cur
           ON cur.RequestInstanceId = r.RequestInstanceId AND cur.StepNo = r.CurrentStepNo
    /* the most recent step I personally acted on, if any */
    OUTER APPLY (
        SELECT TOP 1 si.[Status], si.ActedAt
        FROM workflow.REQUEST_STEP_INSTANCE si
        WHERE si.RequestInstanceId = r.RequestInstanceId
          AND si.ActedByUserId = @UserId
        ORDER BY si.ActedAt DESC
    ) my

    WHERE
        /* involved in at least ONE way - written as EXISTS so a request with
           several matching steps still returns exactly one row */
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
      AND (@IncludeClosed = 1 OR r.[Status] = 'Pending')
      AND (@RequestTypeId IS NULL OR r.RequestTypeId = @RequestTypeId)
      AND (@FromDate IS NULL OR CAST(r.SubmittedAt AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR CAST(r.SubmittedAt AS DATE) <= @ToDate)

    ORDER BY
        /* what needs me comes first, then open work, then history */
        CASE WHEN r.[Status] = 'Pending' THEN 0 ELSE 1 END,
        r.SubmittedAt DESC;
END;
GO

/* counts for the hub's tab badges, in one round trip */
DROP PROCEDURE IF EXISTS workflow.usp_Request_GetCountsForUser;
GO

CREATE PROCEDURE workflow.usp_Request_GetCountsForUser @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @EmployeeId INT = (SELECT EmployeeId FROM hr.EMPLOYEE
                               WHERE UserId = @UserId AND IsDeleted = 0);

    SELECT
        (SELECT COUNT(*) FROM workflow.REQUEST_INSTANCE r
         WHERE r.[Status] = 'Pending'
           AND EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE si
                       WHERE si.RequestInstanceId = r.RequestInstanceId
                         AND si.StepNo = r.CurrentStepNo AND si.[Status] = 'Pending'
                         AND (si.ResolvedUserId = @UserId
                              OR (si.ApproverType = 'Role'
                                  AND EXISTS (SELECT 1 FROM security.USER_ROLE ur
                                              WHERE ur.UserId = @UserId
                                                AND ur.RoleId = si.ApproverRoleId)))))
        AS WaitingOnMe,

        (SELECT COUNT(*) FROM workflow.REQUEST_INSTANCE r
         WHERE r.EmployeeId = @EmployeeId AND r.[Status] = 'Pending') AS MyOpenRequests,

        (SELECT COUNT(*) FROM workflow.REQUEST_INSTANCE r
         WHERE r.EmployeeId = @EmployeeId) AS MyTotalRequests;
END;
GO
