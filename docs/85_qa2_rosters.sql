/* ============================================================================
   85_qa2_rosters.sql — the roster fixes of the QA2 scenario suite (tests/qa2, cases A4) and D7, the branch transfer.
   Needs 82 (hr.EMPLOYEE_BRANCH_HISTORY, hr.fn_EmployeeBranchOn, payroll.fn_IsPeriodPaid, core.fn_IsHoliday).

   D7  A BRANCH CHANGE IS A TRANSFER WITH A DATE. hr.usp_Employee_Update takes @BranchEffectiveFrom (NULL = today in
       Beirut): when the branch changes it writes a history row instead of rewriting the employee's whole past, keeps
       EMPLOYEE.BranchId as "the branch today" (a transfer dated ahead moves it on its day, nightly), re-derives the
       attendance days from the effective date, and refuses a date before the hire, before a later transfer already on
       file, or inside a period that is paid. hr.usp_Employee_Create writes the first history row.
       Rosters resolve the branch AS OF THE WORK DATE: usp_ShiftAssignment_GetByDateRange (new optional @BranchId, and
       a BranchId column appended), usp_RosterMonth_Get, usp_Roster_AssertEditable, usp_Roster_Clear,
       usp_ShiftAssignment_Delete, the SHIFT_ASSIGNMENT trigger and workflow.usp_RosterApproval_Create. Attendance
       records carry the branch of the day since 83; the readiness gate and payroll follow in 86.
   D10 usp_Roster_AssertEditable — the one guard of every roster writer — refuses a day already paid for the employee.
   D1  usp_ShiftAssignment_CopyPeriod keeps the holidays of the target month: no shift is rostered on a public holiday
       of the employee's branch.
   A4a (future day of an approved month edited, resubmitted) and A4b (absence on the swapped shift) needed no change.

   Idempotent: CREATE OR ALTER throughout. Apply with sqlcmd -C -I.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ───────────────────────── hr.usp_Employee_Create ───────────────────────── */
CREATE OR ALTER PROCEDURE [hr].[usp_Employee_Create]
    @UserId INT = NULL, @BranchId INT, @DepartmentId INT, @PositionId INT,
    @FullName NVARCHAR(150), @NationalId VARCHAR(50) = NULL, @NssfNumber VARCHAR(50) = NULL,
    @HireDate DATE, @CreatedBy INT = NULL,
    @Email NVARCHAR(150) = NULL, @PhoneNumber VARCHAR(30) = NULL,
    @PreferredLanguage CHAR(2) = 'en'
AS
BEGIN
    SET NOCOUNT ON;

    SET @Email       = NULLIF(LTRIM(RTRIM(@Email)), N'');
    SET @PhoneNumber = NULLIF(LTRIM(RTRIM(@PhoneNumber)), '');

    IF @Email IS NULL OR @PhoneNumber IS NULL
    BEGIN
        RAISERROR('Phone number and e-mail are required for a new employee.', 16, 1);
        RETURN;
    END

    IF @UserId IS NOT NULL
    BEGIN
        DECLARE @TakenBy NVARCHAR(150) = (
            SELECT TOP 1 e.FullName FROM hr.EMPLOYEE e
            WHERE e.UserId = @UserId AND e.IsDeleted = 0);
        IF @TakenBy IS NOT NULL
        BEGIN
            RAISERROR('That account is already linked to %s. Unlink it from them first.', 16, 1, @TakenBy);
            RETURN;
        END
    END

    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName,
                             NationalId, NssfNumber, HireDate, CreatedBy,
                             Email, PhoneNumber, PreferredLanguage)
    VALUES (@UserId, @BranchId, @DepartmentId, @PositionId, @FullName,
            @NationalId, @NssfNumber, @HireDate, @CreatedBy,
            @Email, @PhoneNumber,
            ISNULL(@PreferredLanguage, 'en'));

    DECLARE @NewEmployeeId INT = CAST(SCOPE_IDENTITY() AS INT);
    /* script 85 (D7): the branch history starts with the hire */
    INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom, Note, CreatedBy)
    VALUES (@NewEmployeeId, @BranchId, @HireDate, N'Hired into this branch.', @CreatedBy);
    SELECT @NewEmployeeId AS EmployeeId;
END;
GO

/* ───────────────────────── hr.usp_Employee_Update ───────────────────────── */
CREATE OR ALTER PROCEDURE [hr].[usp_Employee_Update]
    @EmployeeId INT, @BranchId INT, @DepartmentId INT, @PositionId INT,
    @FullName NVARCHAR(150), @NationalId VARCHAR(50) = NULL, @NssfNumber VARCHAR(50) = NULL,
    @HireDate DATE, @TerminationDate DATE = NULL, @ModifiedBy INT = NULL,
    @Email NVARCHAR(150) = NULL, @PhoneNumber VARCHAR(30) = NULL,
    @PreferredLanguage CHAR(2) = 'en',
    @BranchEffectiveFrom DATE = NULL        -- script 85 (D7): when the branch changes, the day the transfer takes effect (NULL = today in Beirut)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    /* script 85 (D7): A BRANCH CHANGE IS A TRANSFER, AND A TRANSFER HAS A DATE. Overwriting EMPLOYEE.BranchId moved the
       employee's whole past with it: last month's roster and attendance showed up under the new branch. The change is
       now a row in hr.EMPLOYEE_BRANCH_HISTORY; rosters, attendance and reports resolve the branch as of each work date
       (hr.fn_EmployeeBranchOn). EMPLOYEE.BranchId stays "the branch today": a transfer dated ahead leaves it alone
       until its day (hr.usp_EmployeeBranch_ApplyDue, nightly). */
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @OldBranch INT, @OldHire DATE;
    SELECT @OldBranch = BranchId, @OldHire = HireDate FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId;
    DECLARE @CurrentBranchToStore INT = @BranchId, @Transferred BIT = 0, @Eff DATE = NULL;
    IF @OldBranch IS NOT NULL AND @OldBranch <> @BranchId
    BEGIN
        SET @Transferred = 1;
        SET @Eff = ISNULL(@BranchEffectiveFrom, @Today);
        IF @Eff < @HireDate
        BEGIN RAISERROR('A transfer cannot take effect before the employee was hired.', 16, 1); RETURN; END
        IF EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeId = @EmployeeId AND EffectiveFrom > @Eff)
        BEGIN RAISERROR('A later transfer is already on file for this employee. A transfer cannot be dated before it.', 16, 1); RETURN; END
        /* D10: moving somebody out of a branch on a day that is already paid re-files paid days under another branch */
        IF payroll.fn_IsPeriodPaid(@EmployeeId, @Eff) = 1
        BEGIN RAISERROR(N'This period is paid — raise a payroll adjustment instead.', 16, 1); RETURN; END
        IF @Eff > @Today SET @CurrentBranchToStore = @OldBranch;      -- not yet: the nightly job moves them on the day
    END

    BEGIN TRAN;
    IF @Transferred = 1
    BEGIN
        /* somebody created before branch history existed (or inserted around the procedures): their past starts here */
        IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeId = @EmployeeId)
            INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom, Note, CreatedBy)
            VALUES (@EmployeeId, @OldBranch, ISNULL(@OldHire, @HireDate), N'The branch on file before the first recorded transfer.', @ModifiedBy);
        IF EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeId = @EmployeeId AND EffectiveFrom = @Eff)
            UPDATE hr.EMPLOYEE_BRANCH_HISTORY SET BranchId = @BranchId, Note = N'Transfer (re-entered).', CreatedBy = @ModifiedBy, CreatedAt = SYSUTCDATETIME()
            WHERE EmployeeId = @EmployeeId AND EffectiveFrom = @Eff;
        ELSE
            INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom, Note, CreatedBy)
            VALUES (@EmployeeId, @BranchId, @Eff, N'Transfer.', @ModifiedBy);
    END
    UPDATE hr.EMPLOYEE
    SET BranchId = @CurrentBranchToStore, DepartmentId = @DepartmentId, PositionId = @PositionId,
        FullName = @FullName, NationalId = @NationalId, NssfNumber = @NssfNumber,
        HireDate = @HireDate, TerminationDate = @TerminationDate,
        Email = NULLIF(LTRIM(RTRIM(@Email)), N''),
        PhoneNumber = NULLIF(LTRIM(RTRIM(@PhoneNumber)), ''),
        PreferredLanguage = ISNULL(@PreferredLanguage, 'en'),
        ModifiedAt = SYSUTCDATETIME(), ModifiedBy = @ModifiedBy
    WHERE EmployeeId = @EmployeeId;
    COMMIT TRAN;

    /* the days from the effective date that were already derived belong to the new branch now (a holiday of that branch,
       its approved roster): re-derive them. Days before it are not touched; paid and manual days are skipped by the writer. */
    IF @Transferred = 1
    BEGIN
        DECLARE @d DATE = @Eff, @last DATE = CASE WHEN @Today > @Eff THEN @Today ELSE @Eff END;
        WHILE @d <= @last
        BEGIN
            IF EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @EmployeeId AND WorkDate = @d)
               OR EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @EmployeeId AND WorkDate = @d)
                EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @EmployeeId, @WorkDate = @d;
            SET @d = DATEADD(DAY, 1, @d);
        END
    END
END;
GO

/* ───────────────────────── attendance.usp_ShiftAssignment_GetByDateRange ───────────────────────── */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_GetByDateRange
    @FromDate DATE, @ToDate DATE, @EmployeeId INT = NULL,
    @BranchId INT = NULL               -- script 85 (D7): the rows of ONE branch — by the branch each employee belonged to ON the work date
AS BEGIN SET NOCOUNT ON;
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
    ORDER BY sa.WorkDate, e.FullName; END;
GO

/* ───────────────────────── attendance.usp_Roster_AssertEditable ───────────────────────── */
CREATE OR ALTER PROCEDURE attendance.usp_Roster_AssertEditable
AS
BEGIN
    SET NOCOUNT ON;
    IF OBJECT_ID('tempdb..#roster_change') IS NULL RETURN 0;
    IF NOT EXISTS (SELECT 1 FROM #roster_change) RETURN 0;

    /* a row for somebody who does not exist would otherwise die on the foreign key */
    IF EXISTS (SELECT 1 FROM #roster_change c
               WHERE NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE e WHERE e.EmployeeId = c.EmployeeId))
    BEGIN RAISERROR('Employee not found.', 16, 1); RETURN 1; END

    /* script 85 (D10): a day that is already PAID for the employee is not re-rostered — that is a payroll adjustment */
    IF EXISTS (SELECT 1 FROM #roster_change c WHERE payroll.fn_IsPeriodPaid(c.EmployeeId, c.WorkDate) = 1)
    BEGIN RAISERROR(N'This period is paid — raise a payroll adjustment instead.', 16, 1); RETURN 1; END

    /* (a) a branch-month with an OPEN roster request is read-only
           script 85 (D7): "the branch" is the one the employee belongs to ON that day, here and in (b) */
    DECLARE @OpenRid INT = (
        SELECT TOP 1 ri.RequestInstanceId
        FROM #roster_change c
        JOIN hr.EMPLOYEE e            ON e.EmployeeId = c.EmployeeId
        JOIN workflow.ROSTER_APPROVAL ra ON ra.BranchId = hr.fn_EmployeeBranchOn(c.EmployeeId, c.WorkDate)
                                        AND ra.MonthDate = DATEFROMPARTS(YEAR(c.WorkDate), MONTH(c.WorkDate), 1)
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
        WHERE ri.[Status] IN ('Draft', 'Pending', 'OnHold')
        ORDER BY ri.RequestInstanceId DESC);
    IF @OpenRid IS NOT NULL
    BEGIN
        RAISERROR(N'Waiting for approval — request #%d. Withdraw or wait for the decision before editing.', 16, 1, @OpenRid);
        RETURN 1;
    END

    /* (b) in an APPROVED month, the past — and any day attendance already judged — is a record */
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    IF EXISTS (
        SELECT 1
        FROM #roster_change c
        JOIN hr.EMPLOYEE e            ON e.EmployeeId = c.EmployeeId
        JOIN attendance.ROSTER_MONTH rm ON rm.BranchId = hr.fn_EmployeeBranchOn(c.EmployeeId, c.WorkDate)
                                       AND rm.MonthDate = DATEFROMPARTS(YEAR(c.WorkDate), MONTH(c.WorkDate), 1)
                                       AND rm.[Status] = 'Approved'
        WHERE c.WorkDate < @Today
           OR EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD ar
                      WHERE ar.EmployeeId = c.EmployeeId AND ar.WorkDate = c.WorkDate))
    BEGIN
        RAISERROR(N'This day is already in an approved roster and attendance was recorded — correct the attendance record instead.', 16, 1);
        RETURN 1;
    END

    RETURN 0;
END;
GO

/* ───────────────────────── attendance.usp_RosterMonth_Get ───────────────────────── */
CREATE OR ALTER PROCEDURE [attendance].[usp_RosterMonth_Get]
    @BranchId INT, @MonthDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    SET @MonthDate = DATEFROMPARTS(YEAR(@MonthDate), MONTH(@MonthDate), 1);
    DECLARE @NextMonth DATE = DATEADD(MONTH, 1, @MonthDate);

    DECLARE @OpenRid INT, @OpenStatus VARCHAR(20);
    SELECT TOP 1 @OpenRid = ri.RequestInstanceId, @OpenStatus = ri.[Status]
    FROM workflow.ROSTER_APPROVAL ra
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
    WHERE ra.BranchId = @BranchId AND ra.MonthDate = @MonthDate
      AND ri.[Status] IN ('Draft', 'Pending', 'OnHold')
    ORDER BY ri.RequestInstanceId DESC;

    DECLARE @LastStatus VARCHAR(20), @LastClosedAt DATETIME2;
    SELECT TOP 1 @LastStatus = ri.[Status], @LastClosedAt = ri.ClosedAt
    FROM workflow.ROSTER_APPROVAL ra
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
    WHERE ra.BranchId = @BranchId AND ra.MonthDate = @MonthDate
    ORDER BY ri.RequestInstanceId DESC;

    DECLARE @ApprovedAt DATETIME2 = NULL;
    IF @LastStatus = 'Approved'
        SET @ApprovedAt = ISNULL(@LastClosedAt,
                                 (SELECT ApprovedAt FROM attendance.ROSTER_MONTH
                                  WHERE BranchId = @BranchId AND MonthDate = @MonthDate));
    ELSE IF @LastStatus IS NULL
        SET @ApprovedAt = (SELECT ApprovedAt FROM attendance.ROSTER_MONTH
                           WHERE BranchId = @BranchId AND MonthDate = @MonthDate AND [Status] = 'Approved');

    DECLARE @LastChanged DATETIME2 = (
        SELECT MAX(x.Utc) FROM (
            SELECT MAX(sa.ModifiedUtc) AS Utc
            FROM attendance.SHIFT_ASSIGNMENT sa
            JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId
            WHERE hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate) = @BranchId      -- script 85 (D7): the branch of the DAY
              AND sa.WorkDate >= @MonthDate AND sa.WorkDate < @NextMonth
            UNION ALL
            SELECT LastChangedUtc FROM attendance.ROSTER_MONTH
            WHERE BranchId = @BranchId AND MonthDate = @MonthDate) x
        WHERE x.Utc IS NOT NULL);

    SELECT rm.RosterMonthId, rm.BranchId, rm.MonthDate, rm.[Status], rm.ApprovedAt,
           rm.RequestInstanceId, ri.[Status] AS RequestStatus,
           @OpenRid     AS OpenRequestId,
           @OpenStatus  AS OpenRequestStatus,
           @ApprovedAt  AS LastApprovedAt,
           CAST(CASE WHEN @ApprovedAt IS NULL THEN 0
                     WHEN @LastChanged > @ApprovedAt THEN 1 ELSE 0 END AS BIT) AS ChangedSinceApproval,
           @LastChanged AS LastChangedUtc
    FROM attendance.ROSTER_MONTH rm
    LEFT JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = rm.RequestInstanceId
    WHERE rm.BranchId = @BranchId AND rm.MonthDate = @MonthDate;
END;
GO

/* ───────────────────────── attendance.trg_ShiftAssignment_Modified ───────────────────────── */
CREATE OR ALTER TRIGGER attendance.trg_ShiftAssignment_Modified
ON attendance.SHIFT_ASSIGNMENT
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF TRIGGER_NESTLEVEL(@@PROCID, 'AFTER', 'DML') > 1 RETURN;   -- our own stamp UPDATE below
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    /* rows whose CONTENT changed: inserts, real updates, deletes */
    DECLARE @changed TABLE (ShiftAssignmentId INT, EmployeeId INT, WorkDate DATE, StillExists BIT);
    INSERT INTO @changed (ShiftAssignmentId, EmployeeId, WorkDate, StillExists)
    SELECT i.ShiftAssignmentId, i.EmployeeId, i.WorkDate, 1
    FROM inserted i
    LEFT JOIN deleted d ON d.ShiftAssignmentId = i.ShiftAssignmentId
    WHERE d.ShiftAssignmentId IS NULL
       OR ISNULL(i.ShiftId, -1) <> ISNULL(d.ShiftId, -1)
       OR i.IsRestDay <> d.IsRestDay
       OR i.WorkDate <> d.WorkDate
       OR i.EmployeeId <> d.EmployeeId
    UNION ALL
    SELECT d.ShiftAssignmentId, d.EmployeeId, d.WorkDate, 0
    FROM deleted d
    WHERE NOT EXISTS (SELECT 1 FROM inserted i WHERE i.ShiftAssignmentId = d.ShiftAssignmentId);

    IF NOT EXISTS (SELECT 1 FROM @changed) RETURN;

    UPDATE sa SET ModifiedUtc = @Now
    FROM attendance.SHIFT_ASSIGNMENT sa
    JOIN @changed c ON c.ShiftAssignmentId = sa.ShiftAssignmentId AND c.StillExists = 1;

    /* the month header, when one exists, remembers the change even after the row is gone */
    UPDATE rm SET LastChangedUtc = @Now
    FROM attendance.ROSTER_MONTH rm
    WHERE EXISTS (SELECT 1
                  FROM @changed c
                  JOIN hr.EMPLOYEE e ON e.EmployeeId = c.EmployeeId
                  WHERE hr.fn_EmployeeBranchOn(c.EmployeeId, c.WorkDate) = rm.BranchId      -- script 85 (D7)
                    AND rm.MonthDate = DATEFROMPARTS(YEAR(c.WorkDate), MONTH(c.WorkDate), 1));
END;
GO

/* ───────────────────────── attendance.usp_ShiftAssignment_Delete ───────────────────────── */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_Delete @ShiftAssignmentId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#roster_change') IS NOT NULL DROP TABLE #roster_change;
    CREATE TABLE #roster_change (EmployeeId INT NOT NULL, WorkDate DATE NOT NULL);
    INSERT INTO #roster_change (EmployeeId, WorkDate)
    SELECT EmployeeId, WorkDate FROM attendance.SHIFT_ASSIGNMENT WHERE ShiftAssignmentId = @ShiftAssignmentId;
    DECLARE @rc INT;
    EXEC @rc = attendance.usp_Roster_AssertEditable;
    DROP TABLE #roster_change;
    IF @rc <> 0 RETURN 1;

    UPDATE rm SET LastChangedUtc = SYSUTCDATETIME()
    FROM attendance.ROSTER_MONTH rm
    JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.ShiftAssignmentId = @ShiftAssignmentId
    JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId
    WHERE rm.BranchId = hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate)      -- script 85 (D7)
      AND rm.MonthDate = DATEFROMPARTS(YEAR(sa.WorkDate), MONTH(sa.WorkDate), 1);

    DELETE FROM attendance.SHIFT_ASSIGNMENT WHERE ShiftAssignmentId = @ShiftAssignmentId;
END;
GO

/* ───────────────────────── attendance.usp_Roster_Clear ───────────────────────── */
CREATE OR ALTER PROCEDURE attendance.usp_Roster_Clear
    @BranchId INT, @Year INT, @Month INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Month < 1 OR @Month > 12 OR @Year < 2000 OR @Year > 2100
    BEGIN RAISERROR('Give a real year and month.', 16, 1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId)
    BEGIN RAISERROR('Branch not found.', 16, 1); RETURN; END

    DECLARE @MonthDate DATE = DATEFROMPARTS(@Year, @Month, 1);
    DECLARE @NextMonth DATE = DATEADD(MONTH, 1, @MonthDate);

    /* (a) no open or approved roster request for that branch + month */
    DECLARE @Rid INT, @RStatus VARCHAR(20), @RClosedAt DATETIME2;
    SELECT TOP 1 @Rid = ri.RequestInstanceId, @RStatus = ri.[Status], @RClosedAt = ri.ClosedAt
    FROM workflow.ROSTER_APPROVAL ra
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
    WHERE ra.BranchId = @BranchId AND ra.MonthDate = @MonthDate
      AND ri.[Status] IN ('Pending', 'OnHold', 'Approved')
    ORDER BY CASE ri.[Status] WHEN 'Approved' THEN 0 ELSE 1 END, ri.RequestInstanceId DESC;

    IF @RStatus = 'Approved'
    BEGIN
        DECLARE @When VARCHAR(20) = CONVERT(VARCHAR(11), ISNULL(@RClosedAt,
            (SELECT ApprovedAt FROM attendance.ROSTER_MONTH WHERE BranchId = @BranchId AND MonthDate = @MonthDate)), 106);
        RAISERROR('This roster cannot be cleared: it was approved on %s (request #%d).', 16, 1, @When, @Rid);
        RETURN;
    END
    IF @RStatus IS NOT NULL
    BEGIN RAISERROR('This roster cannot be cleared: it is waiting for approval (request #%d).', 16, 1, @Rid); RETURN; END
    IF EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH
               WHERE BranchId = @BranchId AND MonthDate = @MonthDate AND [Status] = 'Approved')
    BEGIN
        DECLARE @When2 VARCHAR(20) = CONVERT(VARCHAR(11),
            (SELECT ApprovedAt FROM attendance.ROSTER_MONTH WHERE BranchId = @BranchId AND MonthDate = @MonthDate), 106);
        RAISERROR('This roster cannot be cleared: it was approved on %s.', 16, 1, @When2);
        RETURN;
    END

    /* (b) no attendance processed on those days for those employees */
    DECLARE @Days INT = (
        SELECT COUNT(DISTINCT ar.WorkDate)
        FROM attendance.ATTENDANCE_RECORD ar
        WHERE ar.WorkDate >= @MonthDate AND ar.WorkDate < @NextMonth
          AND (hr.fn_EmployeeBranchOn(ar.EmployeeId, ar.WorkDate) = @BranchId       -- script 85 (D7): the branch of the DAY, here and below
               OR EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                          JOIN hr.EMPLOYEE e2 ON e2.EmployeeId = sa.EmployeeId
                          WHERE sa.ShiftAssignmentId = ar.ShiftAssignmentId AND hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate) = @BranchId)));
    IF @Days > 0
    BEGIN
        DECLARE @DaysText VARCHAR(20) = CONCAT(@Days, CASE WHEN @Days = 1 THEN ' day' ELSE ' days' END);
        RAISERROR('This roster cannot be cleared: attendance already recorded for %s.', 16, 1, @DaysText);
        RETURN;
    END

    BEGIN TRAN;
        DELETE sa
        FROM attendance.SHIFT_ASSIGNMENT sa
        JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId
        WHERE hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate) = @BranchId
          AND sa.WorkDate >= @MonthDate AND sa.WorkDate < @NextMonth;
        DECLARE @Deleted INT = @@ROWCOUNT;

        DELETE FROM attendance.ROSTER_MONTH WHERE BranchId = @BranchId AND MonthDate = @MonthDate;
        DECLARE @HeaderDeleted INT = @@ROWCOUNT;
    COMMIT;

    SELECT @Deleted AS RowsDeleted, CAST(@HeaderDeleted AS BIT) AS HeaderDeleted;
END;
GO

/* ───────────────────────── workflow.usp_RosterApproval_Create ───────────────────────── */
CREATE OR ALTER PROCEDURE [workflow].[usp_RosterApproval_Create]
    @EmployeeId     INT,
    @RaisedByUserId INT,
    @BranchId       INT,
    @MonthDate      DATE,           -- any day; normalised to the 1st
    @Title          NVARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @MonthDate = DATEFROMPARTS(YEAR(@MonthDate), MONTH(@MonthDate), 1);
    DECLARE @NextMonth DATE = DATEADD(MONTH, 1, @MonthDate);

    IF NOT EXISTS (SELECT 1
                   FROM attendance.SHIFT_ASSIGNMENT sa
                   JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId AND e.IsDeleted = 0
                   WHERE hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate) = @BranchId      -- script 85 (D7): the branch of the DAY
                     AND sa.WorkDate >= @MonthDate AND sa.WorkDate < @NextMonth)
    BEGIN RAISERROR('No roster rows exist for that branch and month — build the roster first.', 16, 1); RETURN; END

    /* (a) one open request at a time */
    DECLARE @OpenRid INT = (
        SELECT TOP 1 ri.RequestInstanceId
        FROM workflow.ROSTER_APPROVAL ra
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
        WHERE ra.BranchId = @BranchId AND ra.MonthDate = @MonthDate
          AND ri.[Status] IN ('Draft', 'Pending', 'OnHold')
        ORDER BY ri.RequestInstanceId DESC);
    IF @OpenRid IS NOT NULL
    BEGIN RAISERROR('This roster is already waiting for approval (request #%d).', 16, 1, @OpenRid); RETURN; END

    /* (b) after an approval, only a CHANGED roster may go up again. The approval time
       is the approved request's ClosedAt — ROSTER_MONTH.ApprovedAt is only a fallback. */
    DECLARE @LastStatus VARCHAR(20), @LastClosedAt DATETIME2;
    SELECT TOP 1 @LastStatus = ri.[Status], @LastClosedAt = ri.ClosedAt
    FROM workflow.ROSTER_APPROVAL ra
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
    WHERE ra.BranchId = @BranchId AND ra.MonthDate = @MonthDate
    ORDER BY ri.RequestInstanceId DESC;

    DECLARE @ApprovedAt DATETIME2 = NULL;
    IF @LastStatus = 'Approved'
        SET @ApprovedAt = ISNULL(@LastClosedAt,
                                 (SELECT ApprovedAt FROM attendance.ROSTER_MONTH
                                  WHERE BranchId = @BranchId AND MonthDate = @MonthDate));
    ELSE IF @LastStatus IS NULL
        SET @ApprovedAt = (SELECT ApprovedAt FROM attendance.ROSTER_MONTH
                           WHERE BranchId = @BranchId AND MonthDate = @MonthDate AND [Status] = 'Approved');

    IF @ApprovedAt IS NOT NULL
    BEGIN
        DECLARE @Changed BIT = CASE WHEN EXISTS (
                SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId
                WHERE hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate) = @BranchId
                  AND sa.WorkDate >= @MonthDate AND sa.WorkDate < @NextMonth
                  AND sa.ModifiedUtc > @ApprovedAt)
            OR EXISTS (
                SELECT 1 FROM attendance.ROSTER_MONTH rm
                WHERE rm.BranchId = @BranchId AND rm.MonthDate = @MonthDate
                  AND rm.LastChangedUtc > @ApprovedAt)
            THEN 1 ELSE 0 END;
        IF @Changed = 0
        BEGIN
            DECLARE @When VARCHAR(20) = CONVERT(VARCHAR(11), @ApprovedAt, 106);   -- '19 Aug 2026'
            RAISERROR('This roster was approved on %s and has not changed since.', 16, 1, @When);
            RETURN;
        END
    END

    BEGIN TRAN;

    /* usp_Request_Submit returns SIX columns — the capture table must match. */
    DECLARE @T TABLE (RequestInstanceId    INT,
                      [Status]             VARCHAR(20),
                      CurrentStepNo        INT,
                      WorkflowDefinitionId INT,
                      WorkflowVersion      INT,
                      MinRequesterTier     INT);
    INSERT INTO @T
    EXEC workflow.usp_Request_Submit
         @RequestTypeCode = 'ROSTER_APPROVAL',
         @EmployeeId      = @EmployeeId,
         @RaisedByUserId  = @RaisedByUserId,
         @Title           = @Title;

    DECLARE @Rid INT = (SELECT TOP 1 RequestInstanceId FROM @T);
    IF @Rid IS NULL
    BEGIN ROLLBACK; RAISERROR('The workflow engine refused the submission.', 16, 1); RETURN; END

    INSERT INTO workflow.ROSTER_APPROVAL (RequestInstanceId, BranchId, MonthDate)
    VALUES (@Rid, @BranchId, @MonthDate);

    /* month state, pointing at the live request. An APPROVED month stays Approved while the
       re-approval is open — the processor keeps using the shifts that were signed off; the
       new decision supersedes the old one when it lands (usp_Request_ApplyApprovalEffects).
       Anything else becomes PendingApproval. */
    MERGE attendance.ROSTER_MONTH AS t
    USING (SELECT @BranchId AS BranchId, @MonthDate AS MonthDate) AS s
       ON t.BranchId = s.BranchId AND t.MonthDate = s.MonthDate
    WHEN MATCHED THEN UPDATE SET [Status] = CASE WHEN t.[Status] = 'Approved' THEN 'Approved' ELSE 'PendingApproval' END,
                                 RequestInstanceId = @Rid
    WHEN NOT MATCHED THEN INSERT (BranchId, MonthDate, [Status], RequestInstanceId)
                          VALUES (s.BranchId, s.MonthDate, 'PendingApproval', @Rid);

    /* auto-approve path: effects again now that the payload exists (idempotent) */
    IF (SELECT [Status] FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @Rid) = 'Approved'
        EXEC workflow.usp_Request_ApplyApprovalEffects @RequestInstanceId = @Rid;

    COMMIT;

    SELECT ri.RequestInstanceId, ri.[Status], ri.CurrentStepNo
    FROM workflow.REQUEST_INSTANCE ri WHERE ri.RequestInstanceId = @Rid;
END;
GO

/* ───────────────────────── attendance.usp_ShiftAssignment_CopyPeriod ───────────────────────── */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_CopyPeriod
    @SourceYearMonth CHAR(7),         -- e.g. '2026-06'
    @TargetYearMonth CHAR(7),         -- e.g. '2026-07'
    @EmployeeId      INT = NULL,      -- NULL = everyone
    @Overwrite       BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @srcFrom DATE = CAST(@SourceYearMonth + '-01' AS DATE);
    DECLARE @srcTo   DATE = EOMONTH(@srcFrom);
    DECLARE @tgtFrom DATE = CAST(@TargetYearMonth + '-01' AS DATE);
    DECLARE @tgtTo   DATE = EOMONTH(@tgtFrom);

    IF OBJECT_ID('tempdb..#roster_plan') IS NOT NULL DROP TABLE #roster_plan;

    ;WITH cal_dates AS (
        SELECT @tgtFrom AS d
        UNION ALL
        SELECT DATEADD(DAY, 1, d) FROM cal_dates WHERE d < @tgtTo
    ),
    tgt_days AS (
        SELECT d AS WorkDate, ((DATEPART(WEEKDAY, d) + @@DATEFIRST - 2) % 7) + 1 AS Dow
        FROM cal_dates
    ),
    src_rows AS (
        SELECT sa.EmployeeId,
               ((DATEPART(WEEKDAY, sa.WorkDate) + @@DATEFIRST - 2) % 7) + 1 AS Dow,
               sa.ShiftId, sa.IsRestDay,
               COUNT(*) AS Freq
        FROM attendance.SHIFT_ASSIGNMENT sa
        WHERE sa.WorkDate BETWEEN @srcFrom AND @srcTo
          AND (@EmployeeId IS NULL OR sa.EmployeeId = @EmployeeId)
        GROUP BY sa.EmployeeId,
                 ((DATEPART(WEEKDAY, sa.WorkDate) + @@DATEFIRST - 2) % 7) + 1,
                 sa.ShiftId, sa.IsRestDay
    ),
    src_pattern AS (
        SELECT EmployeeId, Dow, ShiftId, IsRestDay,
               ROW_NUMBER() OVER (PARTITION BY EmployeeId, Dow ORDER BY Freq DESC) AS rn
        FROM src_rows
    )
    SELECT sp.EmployeeId, td.WorkDate, sp.ShiftId, sp.IsRestDay
    INTO #roster_plan
    FROM src_pattern sp
    JOIN tgt_days td ON td.Dow = sp.Dow
    WHERE sp.rn = 1
      /* script 85 (D1): A COPY KEEPS THE HOLIDAYS of the target month. The pattern says "she works Tuesdays"; the calendar
         says this Tuesday is a public holiday of her branch — no shift is rostered on it (a row already there is left
         as it is). The day reads as Holiday in attendance, never as an absence, and if she does work it HR rosters it. */
      AND core.fn_IsHoliday(td.WorkDate, hr.fn_EmployeeBranchOn(sp.EmployeeId, td.WorkDate)) = 0
    OPTION (MAXRECURSION 400);

    IF OBJECT_ID('tempdb..#roster_change') IS NOT NULL DROP TABLE #roster_change;
    CREATE TABLE #roster_change (EmployeeId INT NOT NULL, WorkDate DATE NOT NULL);
    INSERT INTO #roster_change (EmployeeId, WorkDate)
    SELECT p.EmployeeId, p.WorkDate
    FROM #roster_plan p
    LEFT JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.EmployeeId = p.EmployeeId AND sa.WorkDate = p.WorkDate
    WHERE sa.ShiftAssignmentId IS NULL
       OR (@Overwrite = 1 AND (ISNULL(sa.ShiftId, -1) <> ISNULL(p.ShiftId, -1) OR sa.IsRestDay <> p.IsRestDay));
    DECLARE @rc INT;
    EXEC @rc = attendance.usp_Roster_AssertEditable;
    DROP TABLE #roster_change;
    IF @rc <> 0 BEGIN DROP TABLE #roster_plan; RETURN 1; END

    IF @Overwrite = 1
        UPDATE sa
        SET sa.ShiftId = p.ShiftId, sa.IsRestDay = p.IsRestDay
        FROM attendance.SHIFT_ASSIGNMENT sa
        JOIN #roster_plan p ON p.EmployeeId = sa.EmployeeId AND p.WorkDate = sa.WorkDate;

    INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
    SELECT p.EmployeeId, p.ShiftId, p.WorkDate, p.IsRestDay
    FROM #roster_plan p
    WHERE NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                      WHERE sa.EmployeeId = p.EmployeeId AND sa.WorkDate = p.WorkDate);

    DECLARE @Inserted INT = @@ROWCOUNT;
    DROP TABLE #roster_plan;
    SELECT @Inserted AS RowsInserted;
    RETURN 0;
END;
GO

/* ───────────────────────── verification ───────────────────────── */
DECLARE @p INT = (SELECT COUNT(*) FROM sys.parameters WHERE (object_id = OBJECT_ID('hr.usp_Employee_Update') AND name = '@BranchEffectiveFrom')
                                                         OR (object_id = OBJECT_ID('attendance.usp_ShiftAssignment_GetByDateRange') AND name = '@BranchId'));
PRINT CONCAT('new parameters present = ', @p, ' (expected 2)');
PRINT 'Script 85 applied.';
GO
