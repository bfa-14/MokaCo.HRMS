/* ============================================================================
   75_roster_approval_applies_and_locks.sql — the roster approval takes effect,
   and an approved (or pending) month is protected from edits.

   BUG-01 · approving the last step of a ROSTER_APPROVAL request changed nothing:
   the month stayed PendingApproval, ROSTER_APPROVAL.AppliedAt stayed NULL and
   the processor kept treating every day as unrostered. Nobody called
   usp_Request_ApplyApprovalEffects for it (the typed requests apply their own
   effects inside their _Decide procs; ROSTER_APPROVAL has no _Decide).
     · workflow.usp_Request_ApplyApprovalEffects — the ROSTER_APPROVAL arm is now
       guarded by AppliedAt IS NULL (a second call is a no-op), sets the month to
       Approved, ApprovedAt = the request's ClosedAt, and points the header at the
       approving request (a re-approval supersedes the previous one). The OVERTIME
       arm gets the same marker guard (AppliedToAttendanceAt) as the others.
     · workflow.usp_Request_Approve — when the approval CLOSES a ROSTER_APPROVAL
       request, it applies the effects in the same transaction. ONLY that type:
       the typed _Decide procs stamp the approved figure (DaysApproved,
       ApprovedAmount, …) AFTER the engine call and then apply the effect
       themselves, so applying inside the engine would use the previous step's
       figure and — the "already created" flag having been read before the engine
       call — would be applied a second time by the _Decide proc.
     · data repair at the end: applies the effect of every Approved-but-unapplied
       ROSTER_APPROVAL request (request 59, branch 1, August 2026) and cancels
       the duplicate open requests that were raised because the approval never
       showed (63, 69, 73, 74 — nobody had signed a step of them). No attendance
       re-processing here: prompt Q2 rewrites usp_Attendance_ReprocessDay and
       re-processes the current and previous month as its migration.

   BUG-02 · an approved month was not locked: PUT /api/roster/day returned 200,
   the row changed, the month stayed Approved with no re-approval.
     · attendance.usp_Roster_AssertEditable — ONE guard for every assignment
       writer, evaluated on the rows that would actually CHANGE (a no-op click,
       or a generator with Overwrite off over existing rows, is not a change):
         - a branch-month with an OPEN ROSTER_APPROVAL request (Draft/Pending/
           OnHold) is read-only:
           "Waiting for approval — request #N. Withdraw or wait for the decision
            before editing."
         - in an APPROVED month, a date before today (Beirut) or a date that
           already has an attendance record is refused:
           "This day is already in an approved roster and attendance was
            recorded — correct the attendance record instead."
           Future dates may still be changed by the roster manager; the change
           stamps ModifiedUtc (72) so ChangedSinceApproval becomes true, and the
           month STAYS Approved so processing keeps using the shifts.
     · callers: usp_ShiftAssignment_Upsert, _Delete, _GenerateRange (+_Bulk, now
       atomic), _CopyPeriod, _ApplyPattern. Parameters and result shapes are
       unchanged; GenerateRange returns 1 on a refusal so Bulk can roll back.
     · workflow.usp_RosterApproval_Create — re-submitting an APPROVED month (only
       possible when it changed since, guard 72) keeps the month Approved while
       the new request is open, instead of dropping it to PendingApproval, so
       the processor keeps using the shifts until the new decision supersedes
       the old one. A first submission still moves the month to PendingApproval.
   Every refusal is RAISERROR(msg,16,1) + RETURN (ROLLBACK inside a tran).
   Idempotent. Run with sqlcmd -I.
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ============================================================================
   1. Approval effects — the ROSTER_APPROVAL arm, guarded like the others
   ============================================================================ */
CREATE OR ALTER PROCEDURE [workflow].[usp_Request_ApplyApprovalEffects]
    @RequestInstanceId INT,
    @ActorUserId       INT = NULL      -- recorded as the ledger/row creator
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Code VARCHAR(40), @Status VARCHAR(20), @RaisedBy INT, @ClosedAt DATETIME2;
    SELECT @Code = rt.Code, @Status = ri.[Status], @RaisedBy = ri.RaisedByUserId, @ClosedAt = ri.ClosedAt
    FROM workflow.REQUEST_INSTANCE ri
    JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = ri.RequestTypeId
    WHERE ri.RequestInstanceId = @RequestInstanceId;

    IF @Status <> 'Approved' RETURN;            -- effects follow approval only
    SET @ActorUserId = ISNULL(@ActorUserId, @RaisedBy);

    /* ---- LEAVE: post Usage once; discretionary adds the give-back row ---- */
    IF @Code = 'LEAVE_REQUEST'
       AND EXISTS (SELECT 1 FROM workflow.LEAVE_REQUEST
                   WHERE RequestInstanceId = @RequestInstanceId AND AppliedToLedgerAt IS NULL)
    BEGIN
        INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType,
                                     LeaveRequestId, Days, EffectiveDate, Note, CreatedBy)
        SELECT lr.EmployeeId, lr.LeaveTypeId, FORMAT(lr.FromDate,'yyyy-MM'), 'Usage',
               lr.LeaveRequestId, -ISNULL(lr.DaysApproved, lr.DaysRequested), lr.FromDate,
               N'Approved leave request (applied on approval).', @ActorUserId
        FROM workflow.LEAVE_REQUEST lr
        WHERE lr.RequestInstanceId = @RequestInstanceId;

        INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType,
                                     LeaveRequestId, Days, EffectiveDate, Note, CreatedBy)
        SELECT lr.EmployeeId, lr.LeaveTypeId, FORMAT(lr.FromDate,'yyyy-MM'), 'Adjustment',
               lr.LeaveRequestId, ISNULL(lr.DaysApproved, lr.DaysRequested), lr.FromDate,
               N'Discretionary grant — days returned to the balance by the approver.', @ActorUserId
        FROM workflow.LEAVE_REQUEST lr
        WHERE lr.RequestInstanceId = @RequestInstanceId
          AND lr.IsDiscretionary = 1;

        UPDATE workflow.LEAVE_REQUEST SET AppliedToLedgerAt = SYSUTCDATETIME()
        WHERE RequestInstanceId = @RequestInstanceId;
    END

    /* ---- SALARY ADVANCE: create the payroll advance once ---- */
    IF @Code = 'SALARY_ADVANCE'
       AND EXISTS (SELECT 1 FROM workflow.SALARY_ADVANCE_REQUEST
                   WHERE RequestInstanceId = @RequestInstanceId AND CreatedAdvanceId IS NULL)
    BEGIN
        DECLARE @Amt DECIMAL(18,2), @Mon DECIMAL(18,2);
        SELECT @Amt = ISNULL(ApprovedAmount, Amount),
               @Mon = ISNULL(ApprovedMonthlyDeduction,
                             IIF(MonthlyDeduction > ISNULL(ApprovedAmount, Amount),
                                 ISNULL(ApprovedAmount, Amount), MonthlyDeduction))
        FROM workflow.SALARY_ADVANCE_REQUEST WHERE RequestInstanceId = @RequestInstanceId;

        INSERT INTO payroll.SALARY_ADVANCE
            (EmployeeId, RequestInstanceId, Amount, CurrencyCode, AdvanceDate,
             MonthlyDeduction, RemainingAmount, FirstDeductionPeriod, Reason, CreatedByUserId)
        SELECT EmployeeId, @RequestInstanceId, @Amt, CurrencyCode, CAST(GETDATE() AS DATE),
               @Mon, @Amt, FirstDeductionPeriod, Reason, @ActorUserId
        FROM workflow.SALARY_ADVANCE_REQUEST WHERE RequestInstanceId = @RequestInstanceId;

        UPDATE workflow.SALARY_ADVANCE_REQUEST
        SET CreatedAdvanceId = SCOPE_IDENTITY(), AdvanceCreatedAt = SYSUTCDATETIME()
        WHERE RequestInstanceId = @RequestInstanceId;
    END

    /* ---- PAYROLL ADJUSTMENT: create the adjustment once ---- */
    IF @Code = 'PAYROLL_ADJUSTMENT'
       AND EXISTS (SELECT 1 FROM workflow.PAYROLL_ADJUSTMENT_REQUEST
                   WHERE RequestInstanceId = @RequestInstanceId AND CreatedAdjustmentId IS NULL)
    BEGIN
        INSERT INTO payroll.PAYROLL_ADJUSTMENT
            (EmployeeId, ComponentTypeId, Amount, CurrencyCode, TargetPeriod,
             CorrectsRunId, Reason, CreatedByUserId, RequestInstanceId)
        SELECT EmployeeId, ComponentTypeId, ISNULL(ApprovedAmount, Amount), CurrencyCode,
               TargetPeriod, CorrectsRunId, Reason, @ActorUserId, @RequestInstanceId
        FROM workflow.PAYROLL_ADJUSTMENT_REQUEST WHERE RequestInstanceId = @RequestInstanceId;

        UPDATE workflow.PAYROLL_ADJUSTMENT_REQUEST
        SET CreatedAdjustmentId = SCOPE_IDENTITY(), AdjustmentCreatedAt = SYSUTCDATETIME()
        WHERE RequestInstanceId = @RequestInstanceId;
    END

    /* ---- OVERTIME: settle the figure, then link to attendance (no rowset —
            inlined from usp_Overtime_ApplyToAttendance, which SELECTs). Guarded by
            its marker like every other arm; the marker is stamped only once the
            worked day exists, which is why the reconciler leaves this type out. ---- */
    IF @Code = 'OVERTIME'
       AND EXISTS (SELECT 1 FROM workflow.OVERTIME_REQUEST
                   WHERE RequestInstanceId = @RequestInstanceId AND AppliedToAttendanceAt IS NULL)
    BEGIN
        UPDATE workflow.OVERTIME_REQUEST
        SET ApprovedMinutes = ISNULL(ApprovedMinutes, RequestedMinutes)
        WHERE RequestInstanceId = @RequestInstanceId;

        UPDATE ar
        SET ar.OvertimeApprovedMinutes = o.ApprovedMinutes,
            ar.OvertimeRequestId       = o.OvertimeRequestId
        FROM attendance.ATTENDANCE_RECORD ar
        JOIN workflow.OVERTIME_REQUEST o
          ON o.EmployeeId = ar.EmployeeId AND o.WorkDate = ar.WorkDate
        WHERE o.RequestInstanceId = @RequestInstanceId
          AND (ar.OvertimeRequestId IS NULL OR ar.OvertimeRequestId = o.OvertimeRequestId);

        UPDATE o SET AppliedToAttendanceAt = SYSUTCDATETIME()
        FROM workflow.OVERTIME_REQUEST o
        JOIN attendance.ATTENDANCE_RECORD ar ON ar.OvertimeRequestId = o.OvertimeRequestId
        WHERE o.RequestInstanceId = @RequestInstanceId AND o.AppliedToAttendanceAt IS NULL;
    END

    /* ---- SHIFT SWAP: apply the exchange once (same-date rule as F5).
            A missing roster row skips silently; the reconciler sweeps it. ---- */
    IF @Code = 'SHIFT_SWAP'
       AND EXISTS (SELECT 1 FROM workflow.SHIFT_SWAP
                   WHERE RequestInstanceId = @RequestInstanceId AND AppliedAt IS NULL)
    BEGIN
        DECLARE @E1 INT,@E2 INT,@D1 DATE,@D2 DATE;
        SELECT @E1=RequesterEmployeeId,@E2=CounterpartEmployeeId,
               @D1=RequesterDate,@D2=CounterpartDate
        FROM workflow.SHIFT_SWAP WHERE RequestInstanceId=@RequestInstanceId;

        DECLARE @S1 INT=(SELECT ShiftId FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId=@E1 AND WorkDate=@D1);
        DECLARE @S2 INT=(SELECT ShiftId FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId=@E2 AND WorkDate=@D2);

        IF @S1 IS NOT NULL AND @S2 IS NOT NULL
        BEGIN
            MERGE attendance.SHIFT_ASSIGNMENT t
            USING (VALUES (@E1,@D2,@S2),(@E2,@D1,@S1)) s(EmployeeId,WorkDate,ShiftId)
               ON t.EmployeeId=s.EmployeeId AND t.WorkDate=s.WorkDate
            WHEN MATCHED THEN UPDATE SET ShiftId=s.ShiftId, IsRestDay=0
            WHEN NOT MATCHED THEN INSERT (EmployeeId,ShiftId,WorkDate,IsRestDay)
                 VALUES (s.EmployeeId,s.ShiftId,s.WorkDate,0);

            IF @D1 <> @D2
                UPDATE attendance.SHIFT_ASSIGNMENT SET ShiftId=NULL, IsRestDay=1
                WHERE (EmployeeId=@E1 AND WorkDate=@D1) OR (EmployeeId=@E2 AND WorkDate=@D2);

            UPDATE workflow.SHIFT_SWAP SET AppliedAt=SYSUTCDATETIME()
            WHERE RequestInstanceId=@RequestInstanceId;
        END
    END

    /* ---- ROSTER_APPROVAL: the month's roster becomes ACTIVE only here. Applied
            once (AppliedAt); a later approval of the same branch-month supersedes
            the previous one — the header follows the request that approved last. ---- */
    IF @Code = 'ROSTER_APPROVAL'
       AND EXISTS (SELECT 1 FROM workflow.ROSTER_APPROVAL
                   WHERE RequestInstanceId = @RequestInstanceId AND AppliedAt IS NULL)
    BEGIN
        DECLARE @RaBranch INT, @RaMonth DATE;
        SELECT @RaBranch = BranchId, @RaMonth = MonthDate
        FROM workflow.ROSTER_APPROVAL WHERE RequestInstanceId = @RequestInstanceId;

        DECLARE @ApprovedAt DATETIME2 = ISNULL(@ClosedAt, SYSUTCDATETIME());

        MERGE attendance.ROSTER_MONTH AS t
        USING (SELECT @RaBranch AS BranchId, @RaMonth AS MonthDate) AS s
           ON t.BranchId = s.BranchId AND t.MonthDate = s.MonthDate
        WHEN MATCHED THEN UPDATE SET [Status] = 'Approved', ApprovedAt = @ApprovedAt,
                                     RequestInstanceId = @RequestInstanceId
        WHEN NOT MATCHED THEN INSERT (BranchId, MonthDate, [Status], RequestInstanceId, ApprovedAt)
                              VALUES (s.BranchId, s.MonthDate, 'Approved', @RequestInstanceId, @ApprovedAt);

        UPDATE workflow.ROSTER_APPROVAL
        SET AppliedAt = SYSUTCDATETIME()
        WHERE RequestInstanceId = @RequestInstanceId AND AppliedAt IS NULL;
    END;
END;
GO

/* ============================================================================
   2. The engine applies the effects of the ONE type that has no typed decide
   ============================================================================ */
CREATE OR ALTER PROCEDURE workflow.usp_Request_Approve
    @RequestInstanceId  INT,
    @ActedByUserId      INT,
    @Comment            NVARCHAR(1000) = NULL,
    @ChangeSummary      NVARCHAR(300)  = NULL,
    @SignedWithPassword BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Changed BIT = CASE WHEN @ChangeSummary IS NULL
                                  OR LTRIM(RTRIM(@ChangeSummary)) = '' THEN 0 ELSE 1 END;

    DECLARE @Step INT, @ReqStatus VARCHAR(20), @DefId INT, @TypeCode VARCHAR(40);
    SELECT @Step = ri.CurrentStepNo, @ReqStatus = ri.[Status], @DefId = ri.WorkflowDefinitionId,
           @TypeCode = rt.Code
    FROM workflow.REQUEST_INSTANCE ri
    JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = ri.RequestTypeId
    WHERE ri.RequestInstanceId = @RequestInstanceId;

    IF @ReqStatus IS NULL BEGIN RAISERROR('Request not found.', 16, 1); RETURN; END
    IF @ReqStatus NOT IN ('Pending','OnHold')
    BEGIN RAISERROR('This request is already closed.', 16, 1); RETURN; END

    DECLARE @StepInstId INT = (SELECT RequestStepInstanceId FROM workflow.REQUEST_STEP_INSTANCE
                               WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @Step);

    IF workflow.fn_CanUserActOnStep(@StepInstId, @ActedByUserId) = 0
    BEGIN RAISERROR('You are not the approver for this step.', 16, 1); RETURN; END

    DECLARE @NeedsSignature BIT =
        CASE WHEN ISNULL((SELECT RequiresSignature FROM workflow.WORKFLOW_STEP
                          WHERE WorkflowDefinitionId = @DefId AND StepNo = @Step), 0) = 1
               OR EXISTS (SELECT 1 FROM security.USER_ROLE ur
                          JOIN security.[ROLE] r ON r.RoleId = ur.RoleId
                          WHERE ur.UserId = @ActedByUserId AND r.RequiresSignaturePassword = 1)
             THEN 1 ELSE 0 END;
    IF @NeedsSignature = 1 AND @SignedWithPassword = 0
    BEGIN RAISERROR('This decision must be signed with your password.', 16, 1); RETURN; END

    DECLARE @CanAdjust BIT = 0, @RequiresComment BIT = 0;
    SELECT @CanAdjust = ISNULL(CanAdjust,0), @RequiresComment = ISNULL(RequiresComment,0)
    FROM workflow.WORKFLOW_STEP WHERE WorkflowDefinitionId = @DefId AND StepNo = @Step;

    IF @Changed = 1 AND @CanAdjust = 0
    BEGIN RAISERROR('This step may approve or reject, but may not change what was requested.', 16, 1); RETURN; END
    IF (@Changed = 1 OR @RequiresComment = 1)
       AND (@Comment IS NULL OR LTRIM(RTRIM(@Comment)) = '')
    BEGIN RAISERROR('A comment is required with this decision. Say why.', 16, 1); RETURN; END

    DECLARE @DecisionKind VARCHAR(25) =
        CASE WHEN @Changed = 1 THEN 'ApprovedWithChanges' ELSE 'Approved' END;
    DECLARE @FullComment NVARCHAR(1000) =
        CASE WHEN @Changed = 1 THEN LEFT(CONCAT(@ChangeSummary, N'. ', @Comment), 1000)
             ELSE @Comment END;

    DECLARE @SignedAsDeputy BIT = 0;
    SELECT @SignedAsDeputy = CASE
        WHEN si.ApproverType <> 'Role' AND ISNULL(si.ResolvedUserId,-1) <> @ActedByUserId THEN 1
        WHEN si.ApproverType =  'Role' AND NOT EXISTS (
                SELECT 1 FROM security.USER_ROLE ur
                WHERE ur.UserId = @ActedByUserId AND ur.RoleId = si.ApproverRoleId) THEN 1
        ELSE 0 END
    FROM workflow.REQUEST_STEP_INSTANCE si WHERE si.RequestStepInstanceId = @StepInstId;
    IF @SignedAsDeputy = 1
        SET @FullComment = LEFT(CONCAT(N'Signed as deputy. ', @FullComment), 1000);

    /* freeze the signer's image at the moment of signing */
    DECLARE @Img VARBINARY(MAX) = NULL, @ImgType VARCHAR(30) = NULL;
    IF @SignedWithPassword = 1
        SELECT @Img = ImageBytes, @ImgType = ContentType
        FROM security.USER_SIGNATURE WHERE UserId = @ActedByUserId;

    BEGIN TRAN;

    UPDATE workflow.REQUEST_STEP_INSTANCE
    SET [Status]='Approved', Decision=@DecisionKind,
        ActedByUserId=@ActedByUserId, ActedAt=SYSUTCDATETIME(), Comment=@FullComment,
        SignedWithPassword=@SignedWithPassword,
        HoldReason=NULL, HoldSetAt=NULL, HoldSetByUserId=NULL, WaitingOnRequester=0
    WHERE RequestStepInstanceId=@StepInstId;

    INSERT INTO workflow.WORKFLOW_SIGNATURE
        (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment, SignedWithPassword,
         SignatureImage, SignatureContentType)
    VALUES (@RequestInstanceId, @Step, 'Approved', @ActedByUserId,
            LEFT(@FullComment,300), @SignedWithPassword, @Img, @ImgType);

    DECLARE @NextStep INT = (SELECT MIN(StepNo) FROM workflow.REQUEST_STEP_INSTANCE
                             WHERE RequestInstanceId=@RequestInstanceId AND [Status] IN ('Pending','OnHold'));

    IF @NextStep IS NULL
    BEGIN
        DECLARE @Overruled NVARCHAR(300) = (
            SELECT STRING_AGG(CONCAT(N'step ', si.StepNo, N' (', si.Name, N')'), N', ')
            FROM workflow.REQUEST_STEP_INSTANCE si
            WHERE si.RequestInstanceId=@RequestInstanceId
              AND si.[Status]='Rejected' AND si.StepNo < @Step);
        UPDATE workflow.REQUEST_INSTANCE
        SET [Status]='Approved', CurrentStepNo=NULL, ClosedAt=SYSUTCDATETIME(),
            ClosedReason = CASE WHEN @Overruled IS NOT NULL
                THEN LEFT(CONCAT(N'Approved at the final step, overruling a rejection at ', @Overruled, N'.'),300)
                ELSE NULL END
        WHERE RequestInstanceId=@RequestInstanceId;

        /* THE APPROVAL TAKES EFFECT HERE for the type that has no typed decide (the roster
           month becomes active). The typed types are deliberately NOT applied from the engine:
           their _Decide procs stamp the approved figure AFTER this call and then apply the
           effect themselves; applying here would use the previous step's figure and be applied
           twice. usp_Request_ApplyApprovalEffects is idempotent, emits no rowset, and does no
           INSERT-EXEC, so it is safe under the INSERT-EXEC the callers wrap this proc in. */
        IF @TypeCode = 'ROSTER_APPROVAL'
            EXEC workflow.usp_Request_ApplyApprovalEffects
                 @RequestInstanceId = @RequestInstanceId, @ActorUserId = @ActedByUserId;
    END
    ELSE
        UPDATE workflow.REQUEST_INSTANCE SET [Status]='Pending', CurrentStepNo=@NextStep
        WHERE RequestInstanceId=@RequestInstanceId;

    COMMIT TRAN;

    SELECT RequestInstanceId, [Status], CurrentStepNo, ClosedReason,
           @DecisionKind AS Decision, @SignedAsDeputy AS SignedAsDeputy,
           @SignedWithPassword AS SignedWithPassword
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId=@RequestInstanceId;
END;
GO

/* ============================================================================
   3. Re-submitting an approved month keeps it Approved while the request is open
      (only the MERGE differs from 72; everything else is that script's text)
   ============================================================================ */
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

/* ============================================================================
   4. The lock — one guard for every assignment writer
      Reads #roster_change (EmployeeId INT, WorkDate DATE): the rows the caller is
      about to INSERT, change or DELETE. Returns 0 when every row may change;
      otherwise RAISERRORs the reason and returns 1 (the caller RETURNs / rolls back).
   ============================================================================ */
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

    /* (a) a branch-month with an OPEN roster request is read-only */
    DECLARE @OpenRid INT = (
        SELECT TOP 1 ri.RequestInstanceId
        FROM #roster_change c
        JOIN hr.EMPLOYEE e            ON e.EmployeeId = c.EmployeeId
        JOIN workflow.ROSTER_APPROVAL ra ON ra.BranchId = e.BranchId
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
        JOIN attendance.ROSTER_MONTH rm ON rm.BranchId = e.BranchId
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

/* ---- 4a. Upsert: one cell. The guard sees the row only when it would CHANGE
        (an open ROSTER_APPROVAL request, or an approved ROSTER_MONTH with the
        day in the past / attendance recorded, refuses it — usp_Roster_AssertEditable). ---- */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_Upsert
    @EmployeeId INT, @WorkDate DATE, @ShiftId INT = NULL, @IsRestDay BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#roster_change') IS NOT NULL DROP TABLE #roster_change;
    CREATE TABLE #roster_change (EmployeeId INT NOT NULL, WorkDate DATE NOT NULL);
    INSERT INTO #roster_change (EmployeeId, WorkDate)
    SELECT @EmployeeId, @WorkDate
    WHERE NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT
                      WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate
                        AND ISNULL(ShiftId, -1) = ISNULL(@ShiftId, -1) AND IsRestDay = @IsRestDay);
    DECLARE @rc INT;
    EXEC @rc = attendance.usp_Roster_AssertEditable;
    DROP TABLE #roster_change;
    IF @rc <> 0 RETURN 1;

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

/* ---- 4b. Delete: one row ---- */
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
    WHERE rm.BranchId = e.BranchId
      AND rm.MonthDate = DATEFROMPARTS(YEAR(sa.WorkDate), MONTH(sa.WorkDate), 1);

    DELETE FROM attendance.SHIFT_ASSIGNMENT WHERE ShiftAssignmentId = @ShiftAssignmentId;
END;
GO

/* ---- 4c. Generators: the plan is built exactly as before; the rows of it that
        would land (inserts, and with Overwrite the rows whose values differ) go
        through the guard BEFORE anything is written. Return 1 on a refusal. ---- */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_GenerateRange
    @EmployeeId INT,
    @FromDate   DATE,
    @ToDate     DATE,
    @ShiftId    INT,
    @Weekdays   CHAR(7) = '1111100',
    @Overwrite  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate > @ToDate
    BEGIN RAISERROR('FromDate must be on or before ToDate.', 16, 1); RETURN 1; END

    IF OBJECT_ID('tempdb..#roster_plan') IS NOT NULL DROP TABLE #roster_plan;

    ;WITH cal_dates AS (
        SELECT @FromDate AS d
        UNION ALL
        SELECT DATEADD(DAY, 1, d) FROM cal_dates WHERE d < @ToDate
    )
    SELECT
        @EmployeeId AS EmployeeId,
        c.d         AS WorkDate,
        CASE WHEN SUBSTRING(@Weekdays, ((DATEPART(WEEKDAY, c.d) + @@DATEFIRST - 2) % 7) + 1, 1) = '1'
             THEN @ShiftId ELSE NULL END AS ShiftId,
        CASE WHEN SUBSTRING(@Weekdays, ((DATEPART(WEEKDAY, c.d) + @@DATEFIRST - 2) % 7) + 1, 1) = '1'
             THEN 0 ELSE 1 END           AS IsRestDay
    INTO #roster_plan
    FROM cal_dates c
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

/* ---- 4d. Bulk: all-or-nothing now — one refused employee rolls the team back ---- */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_GenerateRange_Bulk
    @EmployeeIds NVARCHAR(MAX),
    @FromDate    DATE,
    @ToDate      DATE,
    @ShiftId     INT,
    @Weekdays    CHAR(7) = '1111100',
    @Overwrite   BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Emp INT, @Count INT = 0, @rc INT;

    DECLARE emp_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT CAST(LTRIM(RTRIM(value)) AS INT)
        FROM STRING_SPLIT(@EmployeeIds, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

    BEGIN TRAN;
    OPEN emp_cur;
    FETCH NEXT FROM emp_cur INTO @Emp;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC @rc = attendance.usp_ShiftAssignment_GenerateRange
             @EmployeeId = @Emp, @FromDate = @FromDate, @ToDate = @ToDate,
             @ShiftId = @ShiftId, @Weekdays = @Weekdays, @Overwrite = @Overwrite;
        IF ISNULL(@rc, 1) <> 0
        BEGIN
            CLOSE emp_cur; DEALLOCATE emp_cur;
            ROLLBACK TRAN;
            RETURN 1;          -- the refusal was already raised by the nested proc
        END
        SET @Count = @Count + 1;
        FETCH NEXT FROM emp_cur INTO @Emp;
    END
    CLOSE emp_cur;
    DEALLOCATE emp_cur;
    COMMIT TRAN;

    SELECT @Count AS EmployeesProcessed;
    RETURN 0;
END;
GO

/* ---- 4e. Copy period ---- */
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

/* ---- 4f. Apply pattern (ApplyPatternForMonth wraps this one; unchanged) ---- */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_ApplyPattern
    @FromDate   DATE,
    @ToDate     DATE,
    @EmployeeId INT = NULL,
    @Overwrite  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate > @ToDate
    BEGIN RAISERROR('FromDate must be on or before ToDate.', 16, 1); RETURN 1; END

    IF OBJECT_ID('tempdb..#roster_plan') IS NOT NULL DROP TABLE #roster_plan;

    ;WITH cal_dates AS (
        SELECT @FromDate AS d
        UNION ALL
        SELECT DATEADD(DAY, 1, d) FROM cal_dates WHERE d < @ToDate
    ),
    cal_days AS (
        SELECT d AS WorkDate, ((DATEPART(WEEKDAY, d) + @@DATEFIRST - 2) % 7) + 1 AS Dow
        FROM cal_dates
    )
    SELECT p.EmployeeId, cd.WorkDate, p.ShiftId, p.IsRestDay
    INTO #roster_plan
    FROM attendance.EMPLOYEE_SHIFT_PATTERN p
    JOIN cal_days cd   ON cd.Dow = p.DayOfWeek
    JOIN hr.EMPLOYEE e ON e.EmployeeId = p.EmployeeId AND e.IsDeleted = 0
    WHERE p.IsActive = 1
      AND (@EmployeeId IS NULL OR p.EmployeeId = @EmployeeId)
      AND e.HireDate <= cd.WorkDate
      AND (e.TerminationDate IS NULL OR e.TerminationDate >= cd.WorkDate)
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

/* ============================================================================
   5. Data repair (idempotent): apply the approvals that never took effect, and
      close the duplicate requests raised because the approval never showed.
      No attendance re-processing here — prompt Q2 rewrites ReprocessDay and
      re-processes the current and previous month for everybody as its migration.
   ============================================================================ */
SET NOCOUNT ON;
DECLARE @Rid INT, @Branch INT, @Month DATE, @Before VARCHAR(20), @After VARCHAR(20), @Applied INT = 0;

DECLARE fix_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT ra.RequestInstanceId, ra.BranchId, ra.MonthDate
    FROM workflow.ROSTER_APPROVAL ra
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
    WHERE ri.[Status] = 'Approved' AND ra.AppliedAt IS NULL
    ORDER BY ra.RequestInstanceId;
OPEN fix_cur;
FETCH NEXT FROM fix_cur INTO @Rid, @Branch, @Month;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Before = ISNULL((SELECT [Status] FROM attendance.ROSTER_MONTH WHERE BranchId = @Branch AND MonthDate = @Month), '(no header)');
    EXEC workflow.usp_Request_ApplyApprovalEffects @RequestInstanceId = @Rid;
    SET @After = (SELECT [Status] FROM attendance.ROSTER_MONTH WHERE BranchId = @Branch AND MonthDate = @Month);
    PRINT CONCAT('REPAIR | ROSTER_APPROVAL request #', @Rid, ' (branch ', @Branch, ', ', CONVERT(VARCHAR(7), @Month, 120),
                 '): effect applied — roster month ', @Before, ' -> ', @After, ', AppliedAt stamped.');
    SET @Applied += 1;
    FETCH NEXT FROM fix_cur INTO @Rid, @Branch, @Month;
END
CLOSE fix_cur; DEALLOCATE fix_cur;
PRINT CONCAT('REPAIR | approved-but-unapplied roster approvals applied: ', @Applied);

/* the duplicates: open ROSTER_APPROVAL requests raised before this repair on a
   branch-month that is Approved, with no step signed. A later, legitimate
   re-submission (after a change) is never touched: it post-dates this script. */
DECLARE @Dups TABLE (RequestInstanceId INT, BranchId INT, MonthDate DATE, ApprovedRid INT);
INSERT INTO @Dups (RequestInstanceId, BranchId, MonthDate, ApprovedRid)
SELECT ri.RequestInstanceId, ra.BranchId, ra.MonthDate, rm.RequestInstanceId
FROM workflow.ROSTER_APPROVAL ra
JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
JOIN attendance.ROSTER_MONTH rm ON rm.BranchId = ra.BranchId AND rm.MonthDate = ra.MonthDate AND rm.[Status] = 'Approved'
WHERE ri.[Status] IN ('Draft', 'Pending', 'OnHold')
  AND ri.SubmittedAt < '2026-09-17'
  AND ri.RequestInstanceId <> rm.RequestInstanceId
  AND NOT EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE si
                  WHERE si.RequestInstanceId = ri.RequestInstanceId AND si.[Status] IN ('Approved', 'Rejected'));

UPDATE ri
SET [Status] = 'Cancelled', CurrentStepNo = NULL, ClosedAt = SYSUTCDATETIME(),
    ClosedReason = LEFT(CONCAT(N'Cancelled by data repair (script 75): duplicate roster approval — this branch-month was already approved by request #',
                               d.ApprovedRid, N', whose effect is now applied.'), 300)
FROM workflow.REQUEST_INSTANCE ri
JOIN @Dups d ON d.RequestInstanceId = ri.RequestInstanceId;

DECLARE @DupList NVARCHAR(400) = (SELECT STRING_AGG(CONCAT('#', RequestInstanceId, ' (branch ', BranchId, ', ', CONVERT(VARCHAR(7), MonthDate, 120), ', approved by #', ApprovedRid, ')'), ', ') FROM @Dups);
PRINT CONCAT('REPAIR | duplicate open roster approvals cancelled: ', ISNULL(@DupList, 'none'));

PRINT 'REPAIR | attendance NOT re-processed here (prompt Q2 re-processes the current and previous month after rewriting usp_Attendance_ReprocessDay).';
GO
