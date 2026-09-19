/* ============================================================================
   87_branch_scoping_role_hygiene.sql
   1. BUG-04 — BRANCH-SCOPED LISTS. New permission EMP_VIEW_ALL (Owner, General Manager, HR, Admin). A caller WITHOUT it
      sees, in every list below, only
        - their own rows, and
        - the employees of the branches they manage (hr.BRANCH.ManagerEmployeeId = the caller's employee),
          by the branch the employee belonged to ON THE DAY the row is about (D7) — a transferred employee's old days
          stay with the old branch's manager.
      The rule lives in the procedures (@CallerUserId, last parameter, NULL = the system itself: jobs and other
      procedures see everything, and every existing caller keeps working). Result shapes are unchanged.
        hr.usp_Employee_GetAll
        attendance.usp_Attendance_GetByDateRange / _GetAnomalies / _GetExitVariances / _GetWorkedWithoutRoster
        attendance.usp_Correction_GetPending
        attendance.usp_ShiftAssignment_GetByDateRange / _GetGaps
   2. ROLE HYGIENE — the Employee role loses REQUEST_RAISE_OTHERS, REQUEST_VIEW_ALL and WORKFLOW_CONFIGURE;
      AllowSystemReset = 0. What changed is printed.
   Idempotent. Apply with: sqlcmd -S <server> -U <user> -C -I -d MokaCo_HRMS -i docs/87_branch_scoping_role_hygiene.sql
   ============================================================================ */
SET NOCOUNT ON;
GO

/* ───────────────────────── 1. the permission ───────────────────────── */
IF NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'EMP_VIEW_ALL')
BEGIN
    INSERT INTO security.PERMISSION (Code, Name, Module) VALUES ('EMP_VIEW_ALL', N'View employees of every branch', 'HR');
    PRINT 'permission EMP_VIEW_ALL created';
END
ELSE PRINT 'permission EMP_VIEW_ALL already there';

DECLARE @granted TABLE (RoleId INT);
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
OUTPUT inserted.RoleId INTO @granted
SELECT r.RoleId, p.PermissionId
FROM security.[ROLE] r
CROSS JOIN security.PERMISSION p
WHERE p.Code = 'EMP_VIEW_ALL'
  AND r.Name IN (N'Owner', N'General Manager', N'HR', N'Admin')
  AND NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION x WHERE x.RoleId = r.RoleId AND x.PermissionId = p.PermissionId);
DECLARE @g NVARCHAR(400) = (SELECT STRING_AGG(r.Name, N', ') FROM @granted g JOIN security.[ROLE] r ON r.RoleId = g.RoleId);
PRINT CONCAT('EMP_VIEW_ALL granted now to: ', ISNULL(@g, N'(nobody — already granted)'));
GO

/* ───────────────────────── 2. the caller's scope ───────────────────────── */
/* One row, always. SeesAll = 1 for the system (NULL caller) and for a user holding EMP_VIEW_ALL through any role.
   CallerEmployeeId = the employee the login belongs to (NULL for a login with no employee: such a caller without
   EMP_VIEW_ALL sees nothing, which is the safe answer). */
CREATE OR ALTER FUNCTION hr.fn_CallerScope (@CallerUserId INT)
RETURNS TABLE
AS RETURN
    SELECT SeesAll = CAST(CASE WHEN @CallerUserId IS NULL THEN 1
                               WHEN EXISTS (SELECT 1
                                            FROM security.USER_ROLE ur
                                            JOIN security.ROLE_PERMISSION rp ON rp.RoleId = ur.RoleId
                                            JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
                                            WHERE ur.UserId = @CallerUserId AND p.Code = 'EMP_VIEW_ALL') THEN 1
                               ELSE 0 END AS BIT),
           CallerEmployeeId = (SELECT TOP 1 e.EmployeeId FROM hr.EMPLOYEE e WHERE e.UserId = @CallerUserId AND e.IsDeleted = 0 ORDER BY e.EmployeeId);
GO

/* ───────────────────────── 3. the lists ───────────────────────── */
/* Employee list — now carrying ApprovalTier so the grid can tag tier > 1. */
CREATE OR ALTER PROCEDURE hr.usp_Employee_GetAll
    @CallerUserId INT = NULL      -- script 87 (BUG-04): the signed-in user; without EMP_VIEW_ALL they see their own rows and the branches they manage
AS BEGIN SET NOCOUNT ON;
    /* script 87 (BUG-04): what this caller may see. NULL caller = the system itself (jobs, other procedures): everything. */
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    SELECT e.EmployeeId, e.FullName, e.NationalId, e.NssfNumber, e.HireDate, e.TerminationDate,
           e.ApprovalTier,
           b.Name AS Branch, d.Name AS Department, p.Title AS Position
    FROM hr.EMPLOYEE e
    JOIN hr.BRANCH b     ON b.BranchId = e.BranchId
    JOIN hr.DEPARTMENT d ON d.DepartmentId = e.DepartmentId
    JOIN hr.[POSITION] p ON p.PositionId = e.PositionId
    WHERE e.IsDeleted = 0
      AND (@SeesAll = 1 OR e.EmployeeId = @CallerEmp OR EXISTS (SELECT 1 FROM hr.BRANCH mb WHERE mb.ManagerEmployeeId = @CallerEmp AND mb.BranchId = e.BranchId))
    ORDER BY e.FullName;
END;
GO

/* the list read: expose the new figure (additive) */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_GetByDateRange
    @FromDate DATE, @ToDate DATE, @EmployeeId INT = NULL, @BranchId INT = NULL,
    @CallerUserId INT = NULL      -- script 87 (BUG-04): the signed-in user; without EMP_VIEW_ALL they see their own rows and the branches they manage
AS BEGIN SET NOCOUNT ON;
    /* script 87 (BUG-04): what this caller may see. NULL caller = the system itself (jobs, other procedures): everything. */
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    SELECT a.AttendanceId, a.EmployeeId, e.FullName, a.WorkDate,
           a.FirstInUtc, a.LastOutUtc, a.PunchPairs,
           a.WorkedMinutes, a.StandardMinutes, a.DayFraction, a.IsFullDay,
           a.LateMinutes, a.OvertimeMinutes, a.ShortfallMinutes,
           a.ExitActualMinutes, a.ExitApprovedMinutes, a.ExitVarianceMinutes,
           a.ExitLeaveMinutes, a.ExitVarianceDisposition,
           a.[Status], a.[Source], a.IsManual, a.HasAnomaly,
           a.BranchId, b.Name AS BranchName, a.HrNote,
           a.LateDeductMinutes, a.EarlyExitMinutes, a.CoveredMinutes, a.EarlyDeductMinutes,
           UndecidedAnomalies = (SELECT COUNT(*) FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId AND an.Decision IS NULL)
    FROM attendance.ATTENDANCE_RECORD a
    JOIN hr.EMPLOYEE e    ON e.EmployeeId = a.EmployeeId
    LEFT JOIN hr.BRANCH b ON b.BranchId = a.BranchId
    WHERE a.WorkDate BETWEEN @FromDate AND @ToDate
      AND (@EmployeeId IS NULL OR a.EmployeeId = @EmployeeId)
      AND (@BranchId  IS NULL OR a.BranchId  = @BranchId)
      AND (@SeesAll = 1 OR a.EmployeeId = @CallerEmp OR EXISTS (SELECT 1 FROM hr.BRANCH mb WHERE mb.ManagerEmployeeId = @CallerEmp AND mb.BranchId = ISNULL(a.BranchId, e.BranchId)))   -- the record's branch: the employee's branch of THAT day
    ORDER BY a.WorkDate, e.FullName; END;
GO

/* ============================================================================
   5. the list and the decisions
   ============================================================================ */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_GetAnomalies
    @FromDate DATE, @ToDate DATE, @OnlyUndecided BIT = 0, @BranchId INT = NULL,
    @CallerUserId INT = NULL      -- script 87 (BUG-04): the signed-in user; without EMP_VIEW_ALL they see their own rows and the branches they manage
AS BEGIN SET NOCOUNT ON;
    /* script 87 (BUG-04): what this caller may see. NULL caller = the system itself (jobs, other procedures): everything. */
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    SELECT a.AttendanceId, a.EmployeeId, e.FullName, a.WorkDate,
           a.FirstInUtc, a.LastOutUtc, a.PunchPairs, a.[Status], a.[Source],
           an.AnomalyId, an.[Type], an.[Minutes],
           an.ShiftStartUtc AS ShiftStart, an.ShiftEndUtc AS ShiftEnd,
           an.PunchInUtc AS PunchIn, an.PunchOutUtc AS PunchOut,
           an.Decision, an.DecidedByUserId,
           COALESCE(de.FullName, u.Username) AS DecidedBy,
           an.DecidedAt, an.Note,
           a.DayFraction, a.WorkedMinutes, a.CoveredMinutes, a.StandardMinutes, a.IsManual, a.HasAnomaly,
           ISNULL(a.BranchId, e.BranchId) AS BranchId, b.Name AS BranchName
    FROM attendance.ATTENDANCE_ANOMALY an
    JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = an.AttendanceId
    JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
    LEFT JOIN security.[USER] u ON u.UserId = an.DecidedByUserId
    LEFT JOIN hr.EMPLOYEE de ON de.UserId = an.DecidedByUserId AND de.IsDeleted = 0
    LEFT JOIN hr.BRANCH b ON b.BranchId = ISNULL(a.BranchId, e.BranchId)
    WHERE a.WorkDate BETWEEN @FromDate AND @ToDate
      AND (@OnlyUndecided = 0 OR an.Decision IS NULL)
      AND (@BranchId IS NULL OR ISNULL(a.BranchId, e.BranchId) = @BranchId)
      AND (@SeesAll = 1 OR a.EmployeeId = @CallerEmp OR EXISTS (SELECT 1 FROM hr.BRANCH mb WHERE mb.ManagerEmployeeId = @CallerEmp AND mb.BranchId = ISNULL(a.BranchId, e.BranchId)))
    ORDER BY a.WorkDate, e.FullName, an.[Type]; END;
GO

/* ============================================================================
   7. the queue and the readiness gate: a variance is a POSITIVE difference; a rostered
      day with no record is one of an APPROVED roster month
   ============================================================================ */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_GetExitVariances
    @FromDate DATE, @ToDate DATE, @OnlyUndecided BIT = 1,
    @CallerUserId INT = NULL      -- script 87 (BUG-04): the signed-in user; without EMP_VIEW_ALL they see their own rows and the branches they manage
AS
BEGIN
    SET NOCOUNT ON;
    /* script 87 (BUG-04): what this caller may see. NULL caller = the system itself (jobs, other procedures): everything. */
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    SELECT a.AttendanceId, a.EmployeeId, e.FullName, a.WorkDate,
           a.ExitActualMinutes, a.ExitApprovedMinutes, a.ExitVarianceMinutes,
           a.ExitLeaveMinutes, a.ExitVarianceDisposition,
           a.OvertimeMinutes,
           core.fn_MinutesToLeaveDays(a.ExitLeaveMinutes) AS LeaveDaysToDeduct,
           a.HrNote,
           a.EarlyExitMinutes, a.CoveredMinutes, a.DayFraction
    FROM attendance.ATTENDANCE_RECORD a
    JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
    WHERE a.WorkDate BETWEEN @FromDate AND @ToDate
      AND (a.ExitVarianceMinutes > 0 OR (@OnlyUndecided = 0 AND a.ExitVarianceMinutes <> 0))
      AND (@OnlyUndecided = 0 OR a.ExitVarianceDisposition IS NULL)
      AND (@SeesAll = 1 OR a.EmployeeId = @CallerEmp OR EXISTS (SELECT 1 FROM hr.BRANCH mb WHERE mb.ManagerEmployeeId = @CallerEmp AND mb.BranchId = ISNULL(a.BranchId, e.BranchId)))
    ORDER BY a.WorkDate, e.FullName;
END;
GO

/* ───────────────────────── 8. worked without roster ───────────────────────── */
/* Employee-days that have punches but NO attendance record because the approved roster of the month gives the employee
   no row for the day. HR either adds the day to the roster (it is then derived on the next reprocess) or leaves it. */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_GetWorkedWithoutRoster
    @FromDate DATE, @ToDate DATE, @BranchId INT = NULL,
    @CallerUserId INT = NULL      -- script 87 (BUG-04): the signed-in user; without EMP_VIEW_ALL they see their own rows and the branches they manage
AS
BEGIN
    SET NOCOUNT ON;
    /* script 87 (BUG-04): what this caller may see. NULL caller = the system itself (jobs, other procedures): everything. */
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    ;WITH p AS (
        SELECT r.EmployeeId, attendance.fn_AttributedWorkDate(r.EmployeeId, r.PunchTimeUtc) AS WorkDate, r.PunchTimeUtc
        FROM attendance.RAW_DEVICE_LOG r
        WHERE r.EmployeeId IS NOT NULL
          AND r.PunchTimeUtc >= CAST(@FromDate AS DATETIME2) AND r.PunchTimeUtc < CAST(DATEADD(DAY, 2, @ToDate) AS DATETIME2)
    ), d AS (
        SELECT p.EmployeeId, p.WorkDate, MIN(p.PunchTimeUtc) AS FirstPunch, MAX(p.PunchTimeUtc) AS LastPunch, COUNT(*) AS PunchCount
        FROM p WHERE p.WorkDate BETWEEN @FromDate AND @ToDate
        GROUP BY p.EmployeeId, p.WorkDate
    )
    SELECT d.EmployeeId, e.FullName AS EmployeeName, x.BranchId, b.Name AS BranchName, d.WorkDate,
           d.FirstPunch, d.LastPunch, d.PunchCount,
           DATEDIFF(MINUTE, d.FirstPunch, d.LastPunch) AS WorkedMinutes
    FROM d
    JOIN hr.EMPLOYEE e ON e.EmployeeId = d.EmployeeId AND e.IsDeleted = 0
    CROSS APPLY (SELECT hr.fn_EmployeeBranchOn(d.EmployeeId, d.WorkDate) AS BranchId) x
    JOIN hr.BRANCH b ON b.BranchId = x.BranchId
    WHERE (@BranchId IS NULL OR x.BranchId = @BranchId)
      AND (@SeesAll = 1 OR d.EmployeeId = @CallerEmp OR EXISTS (SELECT 1 FROM hr.BRANCH mb WHERE mb.ManagerEmployeeId = @CallerEmp AND mb.BranchId = x.BranchId))
      AND EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                  WHERE rm.BranchId = x.BranchId AND rm.MonthDate = DATEFROMPARTS(YEAR(d.WorkDate), MONTH(d.WorkDate), 1) AND rm.[Status] = 'Approved')
      AND NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa WHERE sa.EmployeeId = d.EmployeeId AND sa.WorkDate = d.WorkDate)
      AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = d.EmployeeId AND a.WorkDate = d.WorkDate)
    ORDER BY d.WorkDate DESC, e.FullName;
END;
GO

CREATE OR ALTER PROCEDURE attendance.usp_Correction_GetPending
    @CallerUserId INT = NULL      -- script 87 (BUG-04): the signed-in user; without EMP_VIEW_ALL they see their own rows and the branches they manage
AS BEGIN SET NOCOUNT ON;
    /* script 87 (BUG-04): what this caller may see. NULL caller = the system itself (jobs, other procedures): everything. */
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    SELECT c.CorrectionId, c.AttendanceId, a.WorkDate, a.EmployeeId, e.FullName,
           c.OldFirstInUtc, c.OldLastOutUtc, c.OldExitMinutes,
           c.NewFirstInUtc, c.NewLastOutUtc, c.NewExitMinutes,
           c.Reason, c.RequestedBy, ru.Username AS RequestedByUser, c.RequestedUtc
    FROM attendance.ATTENDANCE_CORRECTION c
    JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = c.AttendanceId
    JOIN hr.EMPLOYEE e                  ON e.EmployeeId = a.EmployeeId
    LEFT JOIN security.[USER] ru        ON ru.UserId = c.RequestedBy
    WHERE c.ApprovalStatus = 'Pending'
      AND (@SeesAll = 1 OR a.EmployeeId = @CallerEmp OR EXISTS (SELECT 1 FROM hr.BRANCH mb WHERE mb.ManagerEmployeeId = @CallerEmp AND mb.BranchId = ISNULL(a.BranchId, e.BranchId)))
    ORDER BY c.RequestedUtc; END;
GO

/* ───────────────────────── attendance.usp_ShiftAssignment_GetByDateRange ───────────────────────── */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_GetByDateRange
    @FromDate DATE, @ToDate DATE, @EmployeeId INT = NULL,
    @BranchId INT = NULL,               -- script 85 (D7): the rows of ONE branch — by the branch each employee belonged to ON the work date
    @CallerUserId INT = NULL      -- script 87 (BUG-04): the signed-in user; without EMP_VIEW_ALL they see their own rows and the branches they manage
AS BEGIN SET NOCOUNT ON;
    /* script 87 (BUG-04): what this caller may see. NULL caller = the system itself (jobs, other procedures): everything. */
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    SELECT sa.ShiftAssignmentId, sa.EmployeeId, e.FullName, sa.ShiftId, s.Name AS ShiftName,
           s.StartTime, s.EndTime, sa.WorkDate, sa.IsRestDay,
           x.BranchId                   -- script 85 (D7): the employee's branch that day (appended: existing readers keep their columns)
    FROM attendance.SHIFT_ASSIGNMENT sa
    JOIN hr.EMPLOYEE e           ON e.EmployeeId = sa.EmployeeId
    LEFT JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
    CROSS APPLY (SELECT hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate) AS BranchId) x
    WHERE sa.WorkDate BETWEEN @FromDate AND @ToDate
      AND (@EmployeeId IS NULL OR sa.EmployeeId = @EmployeeId)
      AND (@BranchId IS NULL OR x.BranchId = @BranchId)
      AND (@SeesAll = 1 OR sa.EmployeeId = @CallerEmp OR EXISTS (SELECT 1 FROM hr.BRANCH mb WHERE mb.ManagerEmployeeId = @CallerEmp AND mb.BranchId = x.BranchId))
    ORDER BY sa.WorkDate, e.FullName; END;
GO

/* Employee-days with NO roster row. Attendance cannot judge late/absent without one,
   so HR should clear these before the month starts. */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_GetGaps
    @FromDate DATE, @ToDate DATE,
    @CallerUserId INT = NULL      -- script 87 (BUG-04): the signed-in user; without EMP_VIEW_ALL they see their own rows and the branches they manage
AS
BEGIN
    SET NOCOUNT ON;
    /* script 87 (BUG-04): what this caller may see. NULL caller = the system itself (jobs, other procedures): everything. */
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    ;WITH cal_dates AS (
        SELECT @FromDate AS d
        UNION ALL
        SELECT DATEADD(DAY, 1, d) FROM cal_dates WHERE d < @ToDate
    )
    SELECT e.EmployeeId, e.FullName, c.d AS WorkDate
    FROM cal_dates c
    CROSS JOIN hr.EMPLOYEE e
    WHERE e.IsDeleted = 0
      AND (@SeesAll = 1 OR e.EmployeeId = @CallerEmp OR EXISTS (SELECT 1 FROM hr.BRANCH mb WHERE mb.ManagerEmployeeId = @CallerEmp AND mb.BranchId = hr.fn_EmployeeBranchOn(e.EmployeeId, c.d)))
      AND e.HireDate <= c.d
      AND (e.TerminationDate IS NULL OR e.TerminationDate >= c.d)
      AND NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                      WHERE sa.EmployeeId = e.EmployeeId AND sa.WorkDate = c.d)
    ORDER BY c.d, e.FullName
    OPTION (MAXRECURSION 400);
END;
GO

/* ───────────────────────── 4. role hygiene ───────────────────────── */
DECLARE @removed TABLE (PermissionId INT);
DELETE rp
OUTPUT deleted.PermissionId INTO @removed
FROM security.ROLE_PERMISSION rp
JOIN security.[ROLE] r ON r.RoleId = rp.RoleId
JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
WHERE r.Name = N'Employee' AND p.Code IN ('REQUEST_RAISE_OTHERS', 'REQUEST_VIEW_ALL', 'WORKFLOW_CONFIGURE');
DECLARE @r NVARCHAR(400) = (SELECT STRING_AGG(p.Code, ', ') FROM @removed x JOIN security.PERMISSION p ON p.PermissionId = x.PermissionId);
PRINT CONCAT('Employee role lost: ', ISNULL(@r, '(nothing — already clean)'));

DECLARE @was NVARCHAR(100) = (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'AllowSystemReset');
IF @was IS NULL PRINT 'AllowSystemReset: no such setting (nothing to disarm)';
ELSE IF @was <> '0'
BEGIN
    UPDATE core.SETTING SET SettingValue = '0', ModifiedAt = SYSUTCDATETIME() WHERE SettingKey = 'AllowSystemReset';
    PRINT CONCAT('AllowSystemReset: ', @was, ' -> 0 (disarmed)');
END
ELSE PRINT 'AllowSystemReset: already 0';
GO

/* ───────────────────────── 5. verification ───────────────────────── */
SELECT r.Name AS RoleName, p.Code
FROM security.ROLE_PERMISSION rp
JOIN security.[ROLE] r ON r.RoleId = rp.RoleId
JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
WHERE p.Code = 'EMP_VIEW_ALL' OR (r.Name = N'Employee' AND p.Code IN ('REQUEST_RAISE_OTHERS', 'REQUEST_VIEW_ALL', 'WORKFLOW_CONFIGURE'))
ORDER BY p.Code, r.Name;
SELECT SettingKey, SettingValue FROM core.SETTING WHERE SettingKey = 'AllowSystemReset';
PRINT '87_branch_scoping_role_hygiene.sql applied';
GO
