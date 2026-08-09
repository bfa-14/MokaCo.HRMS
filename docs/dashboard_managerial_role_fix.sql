/* ============================================================================
   core.usp_Dashboard_Get — the managerial test could never match the General Manager.

   The procedure decides whether a caller sees the company-wide half of the dashboard by matching
   their role names against a literal list, and that list spelled the role 'GeneralManager'. The role
   in security.[ROLE] is actually named 'General Manager', WITH A SPACE — so the match never
   succeeded, @IsManagerial stayed 0 for the GM, and result sets 5 to 10 came back empty. The failure
   is silent by construction: an empty set is exactly what a non-managerial caller is supposed to get,
   so the GM's dashboard looked like a correctly-rendered employee dashboard rather than like a bug.

   Verified against the live database before the change: EXEC core.usp_Dashboard_Get @UserId=17
   (ghada.gm, role 'General Manager') returned no company snapshot at all.

   BOTH SPELLINGS ARE LISTED, not just the correct one. The role name is data somebody can retype,
   and a dashboard that quietly loses half its content when a role is renamed is the failure mode this
   is fixing; matching either form costs nothing and removes the trap.

   Only that one line changes. Everything else is the deployed definition, reproduced verbatim so a
   future edit can diff against what is actually running.

   Deploy with: sqlcmd -S localhost -d MokaCo_HRMS -E -C -I -i dashboard_managerial_role_fix.sql
   (-I matters: the procedure is stored with QUOTED_IDENTIFIER ON and must stay that way.)
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

ALTER PROCEDURE core.usp_Dashboard_Get
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @EmpId INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE UserId=@UserId AND IsDeleted=0);
    DECLARE @IsManagerial BIT = CASE WHEN EXISTS (
        SELECT 1 FROM security.USER_ROLE ur
        JOIN security.[ROLE] r ON r.RoleId=ur.RoleId
        WHERE ur.UserId=@UserId
          -- 'General Manager' is how the role is actually named; 'GeneralManager' is kept so a
          -- rename in either direction cannot silently empty half of somebody's dashboard.
          AND r.Name IN ('Owner','General Manager','GeneralManager','OperationsManager','HR','Admin'))
        THEN 1 ELSE 0 END;
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @MonthStart DATE = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);

    /* 1 - waiting on me */
    ;WITH actionable AS (
        SELECT r.RequestInstanceId, r.Title, rt.Code AS RequestTypeCode,
               rt.Name AS RequestTypeName, r.SubmittedAt,
               DATEDIFF(DAY, r.SubmittedAt, SYSUTCDATETIME()) AS AgeDays
        FROM workflow.REQUEST_INSTANCE r
        JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId=r.RequestTypeId
        JOIN workflow.REQUEST_STEP_INSTANCE si
          ON si.RequestInstanceId=r.RequestInstanceId AND si.StepNo=r.CurrentStepNo
        WHERE r.[Status] IN ('Pending','OnHold')
          AND workflow.fn_CanUserActOnStep(si.RequestStepInstanceId,@UserId)=1)
    SELECT (SELECT COUNT(*) FROM actionable) AS TotalCount,
           a.RequestInstanceId, a.Title, a.RequestTypeCode, a.RequestTypeName,
           a.SubmittedAt, a.AgeDays
    FROM actionable a ORDER BY a.SubmittedAt ASC
    OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY;

    /* 2 - my open requests */
    ;WITH mine AS (
        SELECT r.RequestInstanceId, r.Title, rt.Name AS RequestTypeName,
               r.[Status], r.CurrentStepNo, r.SubmittedAt
        FROM workflow.REQUEST_INSTANCE r
        JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId=r.RequestTypeId
        WHERE r.[Status] IN ('Pending','OnHold')
          AND (r.RaisedByUserId=@UserId OR (@EmpId IS NOT NULL AND r.EmployeeId=@EmpId)))
    SELECT (SELECT COUNT(*) FROM mine) AS TotalCount,
           m.RequestInstanceId, m.Title, m.RequestTypeName, m.[Status],
           m.CurrentStepNo, m.SubmittedAt
    FROM mine m ORDER BY m.SubmittedAt DESC
    OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY;

    /* 3 - recent activity on my requests */
    SELECT TOP 6 g.RequestInstanceId, r.Title, g.[Action],
           u.Username AS ActedBy, g.ActedAt
    FROM workflow.WORKFLOW_SIGNATURE g
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId=g.RequestInstanceId
    LEFT JOIN security.[USER] u ON u.UserId=g.ActedByUserId
    WHERE (r.RaisedByUserId=@UserId OR (@EmpId IS NOT NULL AND r.EmployeeId=@EmpId))
      AND g.[Action] IN ('Approved','Rejected','Skipped','VersionMoved')
    ORDER BY g.ActedAt DESC;

    /* 4 - my leave balances */
    SELECT lt.LeaveTypeId, lt.Name AS LeaveTypeName, lt.IsPaid,
           hr.fn_GetAnnualEntitlement(@EmpId, lt.LeaveTypeId, @Today) AS AnnualEntitlementDays,
           ISNULL((SELECT SUM(ll.Days) FROM hr.LEAVE_LEDGER ll
                   WHERE ll.EmployeeId=@EmpId AND ll.LeaveTypeId=lt.LeaveTypeId),0) AS CurrentBalance
    FROM hr.LEAVE_TYPE lt
    WHERE @EmpId IS NOT NULL
      AND (EXISTS (SELECT 1 FROM hr.LEAVE_ACCRUAL_TIER t WHERE t.LeaveTypeId=lt.LeaveTypeId)
           OR lt.FixedEntitlementDays IS NOT NULL)
    ORDER BY lt.Name;

    /* 5 - coverage gaps (managerial) */
    SELECT rt.RequestTypeId, rt.Code, rt.Name
    FROM workflow.REQUEST_TYPE rt
    WHERE @IsManagerial=1
      AND NOT EXISTS (SELECT 1 FROM workflow.WORKFLOW_DEFINITION d
                      WHERE d.RequestTypeId=rt.RequestTypeId AND d.[Status]='Active')
    ORDER BY rt.Name;

    /* 6 - company snapshot (managerial) */
    SELECT
        (SELECT COUNT(*) FROM hr.EMPLOYEE WHERE IsDeleted=0)                        AS ActiveEmployees,
        (SELECT COUNT(*) FROM workflow.REQUEST_INSTANCE
         WHERE [Status] IN ('Pending','OnHold'))                                    AS OpenRequests,
        (SELECT COUNT(*) FROM workflow.REQUEST_INSTANCE
         WHERE [Status]='Approved' AND ClosedAt>=DATEADD(DAY,-30,SYSUTCDATETIME())) AS ApprovedLast30Days,
        (SELECT COUNT(*) FROM workflow.WORKFLOW_DEFINITION WHERE [Status]='Active') AS ActiveChains,
        (SELECT CASE WHEN SettingValue='1' THEN 1 ELSE 0 END
         FROM core.SETTING WHERE SettingKey='AllowSystemReset')                     AS ResetArmed
    WHERE @IsManagerial=1;

    /* 7 - staffing today (managerial): rostered vs on approved leave, per branch */
    SELECT b.BranchId, b.Name AS BranchName,
           (SELECT COUNT(*) FROM attendance.SHIFT_ASSIGNMENT sa
            JOIN hr.EMPLOYEE e ON e.EmployeeId=sa.EmployeeId AND e.IsDeleted=0
            WHERE e.BranchId=b.BranchId AND sa.WorkDate=@Today
              AND sa.IsRestDay=0 AND sa.ShiftId IS NOT NULL) AS RosteredToday,
           (SELECT COUNT(DISTINCT lr.EmployeeId)
            FROM workflow.LEAVE_REQUEST lr
            JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId=lr.RequestInstanceId
            JOIN hr.EMPLOYEE e ON e.EmployeeId=lr.EmployeeId AND e.IsDeleted=0
            WHERE e.BranchId=b.BranchId AND r.[Status]='Approved'
              AND lr.FromDate<=@Today AND lr.ToDate>=@Today) AS OnLeaveToday
    FROM hr.BRANCH b
    WHERE @IsManagerial=1 AND b.IsActive=1
    ORDER BY b.Name;

    /* 8 - who is on leave today (managerial), named */
    SELECT e.FullName, b.Name AS BranchName, lt.Name AS LeaveTypeName,
           lr.FromDate, lr.ToDate, lr.RequestInstanceId
    FROM workflow.LEAVE_REQUEST lr
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId=lr.RequestInstanceId
    JOIN hr.EMPLOYEE e ON e.EmployeeId=lr.EmployeeId
    JOIN hr.BRANCH b ON b.BranchId=e.BranchId
    JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId=lr.LeaveTypeId
    WHERE @IsManagerial=1 AND r.[Status]='Approved'
      AND lr.FromDate<=@Today AND lr.ToDate>=@Today
    ORDER BY b.Name, e.FullName;

    /* 9 - open requests by type (managerial) - the workflow at a glance */
    SELECT rt.Code, rt.Name, COUNT(*) AS OpenCount,
           MAX(DATEDIFF(DAY, r.SubmittedAt, SYSUTCDATETIME())) AS OldestAgeDays
    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId=r.RequestTypeId
    WHERE @IsManagerial=1 AND r.[Status] IN ('Pending','OnHold')
    GROUP BY rt.Code, rt.Name
    ORDER BY OpenCount DESC;

    /* 10 - money this month (managerial), per currency:
            approved expenses + finalized tips + approved overtime minutes */
    SELECT 'Expenses (approved)' AS Item, x.CurrencyCode,
           SUM(ISNULL(x.ApprovedAmount,x.Amount)) AS Amount, NULL AS Minutes
    FROM workflow.EXPENSE_REIMBURSEMENT x
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId=x.RequestInstanceId
    WHERE @IsManagerial=1 AND r.[Status]='Approved' AND x.ExpenseDate>=@MonthStart
    GROUP BY x.CurrencyCode
    UNION ALL
    SELECT 'Tips (finalized)', l.CurrencyCode, SUM(l.Amount), NULL
    FROM workflow.TIP_DISTRIBUTION_LINE l
    JOIN workflow.TIP_DISTRIBUTION t ON t.TipDistributionId=l.TipDistributionId
    WHERE @IsManagerial=1 AND t.FinalizedAt IS NOT NULL AND t.ShiftDate>=@MonthStart
    GROUP BY l.CurrencyCode
    UNION ALL
    SELECT 'Overtime (approved)', NULL, NULL, SUM(o.ApprovedMinutes)
    FROM workflow.OVERTIME_REQUEST o
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId=o.RequestInstanceId
    WHERE @IsManagerial=1 AND r.[Status]='Approved' AND o.WorkDate>=@MonthStart
      AND o.ApprovedMinutes IS NOT NULL;
END;
GO
