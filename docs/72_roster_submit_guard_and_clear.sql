/* ============================================================================
   72_roster_submit_guard_and_clear.sql — one roster approval at a time, and a
   way to clear a month that was never approved.

   · attendance.SHIFT_ASSIGNMENT.ModifiedUtc — when the row last changed.
     attendance.ROSTER_MONTH.LastChangedUtc — when ANY row of that branch-month
     last changed, including deletes (a deleted row cannot carry a stamp).
     Both are kept current by usp_ShiftAssignment_Upsert/_Delete explicitly and,
     as the net for the generators (GenerateRange, CopyPeriod, ApplyPattern) and
     the SHIFT_SWAP approval effect, by trg_ShiftAssignment_Modified.
   · workflow.usp_RosterApproval_Create — refuses while a ROSTER_APPROVAL
     request for the branch+month is Draft/Pending/OnHold ("already waiting …
     (request #N)"); after an approval it is allowed only if the roster changed
     since (compared with REQUEST_INSTANCE.ClosedAt of that approved request,
     falling back to ROSTER_MONTH.ApprovedAt); after a rejection it is allowed.
     Result set: RequestInstanceId, Status, CurrentStepNo (superset of before).
   · attendance.usp_RosterMonth_Get — adds OpenRequestId, OpenRequestStatus,
     LastApprovedAt, ChangedSinceApproval, LastChangedUtc (existing columns kept).
   · attendance.usp_Roster_Clear — deletes the month's assignment rows for the
     branch (and the ROSTER_MONTH header) when no Pending/OnHold/Approved
     ROSTER_APPROVAL request exists AND no attendance record was processed.
   Every refusal is RAISERROR(msg,16,1) + RETURN (ROLLBACK inside a tran).
   Idempotent. Run with sqlcmd -I.
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---- 1. Columns --------------------------------------------------------------- */
IF COL_LENGTH('attendance.SHIFT_ASSIGNMENT', 'ModifiedUtc') IS NULL
    ALTER TABLE attendance.SHIFT_ASSIGNMENT
        ADD ModifiedUtc DATETIME2(3) NOT NULL CONSTRAINT DF_SHIFT_ASSIGNMENT_ModifiedUtc DEFAULT SYSUTCDATETIME();
IF COL_LENGTH('attendance.ROSTER_MONTH', 'LastChangedUtc') IS NULL
    ALTER TABLE attendance.ROSTER_MONTH ADD LastChangedUtc DATETIME2(3) NULL;
GO

/* ---- 2. Trigger: stamp changed rows, bump the branch-month header --------------- */
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
                  WHERE e.BranchId = rm.BranchId
                    AND rm.MonthDate = DATEFROMPARTS(YEAR(c.WorkDate), MONTH(c.WorkDate), 1));
END;
GO

/* ---- 3. Upsert / Delete keep the stamps explicitly ------------------------------ */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_Upsert
    @EmployeeId INT, @WorkDate DATE, @ShiftId INT = NULL, @IsRestDay BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT
               WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate)
        /* a no-op click must not mark the roster as changed */
        UPDATE attendance.SHIFT_ASSIGNMENT
        SET ShiftId = @ShiftId, IsRestDay = @IsRestDay, ModifiedUtc = SYSUTCDATETIME()
        WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate
          AND (ISNULL(ShiftId, -1) <> ISNULL(@ShiftId, -1) OR IsRestDay <> @IsRestDay);
    ELSE
        INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay, ModifiedUtc)
        VALUES (@EmployeeId, @ShiftId, @WorkDate, @IsRestDay, SYSUTCDATETIME());

    SELECT ShiftAssignmentId FROM attendance.SHIFT_ASSIGNMENT
    WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate;
END;
GO

CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_Delete @ShiftAssignmentId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE rm SET LastChangedUtc = SYSUTCDATETIME()
    FROM attendance.ROSTER_MONTH rm
    JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.ShiftAssignmentId = @ShiftAssignmentId
    JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId
    WHERE rm.BranchId = e.BranchId
      AND rm.MonthDate = DATEFROMPARTS(YEAR(sa.WorkDate), MONTH(sa.WorkDate), 1);

    DELETE FROM attendance.SHIFT_ASSIGNMENT WHERE ShiftAssignmentId = @ShiftAssignmentId;
END;
GO

/* ---- 4. Submit guard -------------------------------------------------------- */
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
                   WHERE e.BranchId = @BranchId
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
       is the approved request's ClosedAt — ROSTER_MONTH.ApprovedAt is only a fallback,
       because the API does not always apply the ROSTER_APPROVAL effect. */
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
                WHERE e.BranchId = @BranchId
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

    /* month state: pending, pointing at the live request */
    MERGE attendance.ROSTER_MONTH AS t
    USING (SELECT @BranchId AS BranchId, @MonthDate AS MonthDate) AS s
       ON t.BranchId = s.BranchId AND t.MonthDate = s.MonthDate
    WHEN MATCHED THEN UPDATE SET [Status] = 'PendingApproval', RequestInstanceId = @Rid
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

/* ---- 5. Month status for the Roster page — now with what the button needs ------ */
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
            WHERE e.BranchId = @BranchId AND sa.WorkDate >= @MonthDate AND sa.WorkDate < @NextMonth
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

/* ---- 6. Clear a month's roster for a branch ------------------------------------ */
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
          AND (EXISTS (SELECT 1 FROM hr.EMPLOYEE e WHERE e.EmployeeId = ar.EmployeeId AND e.BranchId = @BranchId)
               OR EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                          JOIN hr.EMPLOYEE e2 ON e2.EmployeeId = sa.EmployeeId
                          WHERE sa.ShiftAssignmentId = ar.ShiftAssignmentId AND e2.BranchId = @BranchId)));
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
        WHERE e.BranchId = @BranchId
          AND sa.WorkDate >= @MonthDate AND sa.WorkDate < @NextMonth;
        DECLARE @Deleted INT = @@ROWCOUNT;

        DELETE FROM attendance.ROSTER_MONTH WHERE BranchId = @BranchId AND MonthDate = @MonthDate;
        DECLARE @HeaderDeleted INT = @@ROWCOUNT;
    COMMIT;

    SELECT @Deleted AS RowsDeleted, CAST(@HeaderDeleted AS BIT) AS HeaderDeleted;
END;
GO
