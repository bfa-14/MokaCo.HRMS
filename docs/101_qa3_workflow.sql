/* ============================================================================
   101_qa3_workflow.sql - QA3 (deep test, 2026-10-19): the workflow engine (unit A).

   WF-1  (= PAY-1, ATT-3, LEV-3, ROS-s13) usp_Reversal_UndoEffects deleted the advance / adjustment while the request
         row still POINTED at it (FK), so every retract and every GM + Owner reopen of an approved advance or adjustment
         died with error 547 - and a reopen stayed half-signed for ever. Now: collect the ids, clear the pointer, then
         delete (the order of workflow_reversal_fixes.sql), keeping script 84's leave arm, and clearing the leave's
         ApprovedToDate (and PaidSnapshot when present) when a leave approval is undone.
   WF-2  decisions were not concurrency-safe: the status was read outside the transaction, the step update had no
         expected-status predicate and the request update was unconditional (two HR users both signed one step; an
         approval in flight landed on a request the requester had just cancelled). usp_Request_Approve,
         _RetractLastDecision, _Reopen, _ReopenClosed, _WithdrawDecision and _MoveToVersion now open the transaction
         BEFORE they read, lock the request row (UPDLOCK, ROWLOCK), re-check the status and the step under the lock,
         and update conditionally with a row-count check - otherwise "This step was decided a moment ago - reload."
         Approve also takes an optional @ExpectedStepNo (the step the caller was looking at).
   WF-4  (= LEV-7) a struck decision's figure is put back: NEW workflow.usp_Request_RestoreFigure(@RequestInstanceId,
         @StepNo) restores the payload figure from the step's ValueBefore (leave days + the discretionary flag, exit-
         permission and overtime minutes, advance and adjustment amounts) and is called by retract, reopen and withdraw
         before the step is unsigned.
   WF-5  a retract takes back only an APPROVED or REJECTED request's last decision (it used to re-open a cancelled one).
   WF-6  a reopen (GM + Owner, both signatures; HR's reopen of a cancelled request; a same-day retract of a rejection)
         re-runs the type's create guards against everything raised since, the request itself excluded: leave overlap,
         one overtime per date, overlapping exit-permission windows, one open roster request per branch-month
         (NEW workflow.fn_ReopenConflict).
   WF-8  (+ ROS-11, ATT-5) undo arms for EXIT_PERMISSION (applied mark and the day's pointer cleared, the day
         re-derived), OVERTIME (the applied minutes cleared, the day re-derived) and ROSTER_APPROVAL (the month header
         goes back to the approval that still stands, or to PendingApproval; AppliedAt cleared; the month re-derived by
         attendance.usp_Roster_RederiveMonth when unit C's procedure exists). Taking back the APPROVAL of any other type
         is refused with a sentence (NEW workflow.fn_ReversalUndoBlock), as is undoing an approval whose days are
         already paid ("This period is paid - raise a payroll adjustment instead."), whose exit minutes were already
         converted to leave, or whose advance / adjustment was already consumed.
   WF-9  usp_Request_MoveToVersion applies the effects when a (confirmed) move closes the request; ApplyApprovalEffects
         gains the EXIT_PERMISSION arm (ATT-5: applied at final approval, not only by the nightly job) and its OVERTIME
         arm re-derives the worked day (ATT-4); the advance's AdvanceDate is Beirut's date, not the server's.
   WF-10 version moves stay inside the requester's population (the target serves the same MinRequesterTier as the
         chain the request is on, and the old-versions queue only offers that one); the remaining steps are rebuilt by
         POSITION after the last acted step; target steps the request has already passed are logged as Skipped; the
         deputy and flag columns are copied; a move that would leave nothing to sign is refused unless @ConfirmClose = 1.
   WF-13 "same day" for a retract is the Beirut calendar day.
   WF-14 HR's single-signature usp_Request_ReopenClosed reopens CANCELLED requests only; the GM + Owner reopen needs
         two different people and a password signature at each half (@SignedWithPassword, set by the API after it
         verified the password - fails closed), and a request with no standing decision is refused at the FIRST half.
   WF-15 a reversal (retract, the completing half of a reopen, HR's reopen) removes the request's earlier outbox rows,
         so the closing mail of its next outcome is queued again instead of being suppressed by the one already sent
         (and a queued "approved" mail of a decision that no longer stands is never sent).
   WEB-7 NEW workflow.usp_Request_GetDelegateCandidates(@RequestInstanceId, @ForUserId): the people the waiting step can
         be handed to (usp_Request_Delegate's own rules), for the "Hand to someone else" picker; empty for anybody who
         cannot act on the step.
   CON-1 usp_ExitPermission_WithdrawDecision committed the restored minutes even when the engine refused, and returned
         the engine's row as its first result set: the engine is now captured with INSERT...EXEC (no row = nothing
         done), and the engine restores the minutes itself, under its lock.
   SUSPICIONS CONFIRMED AND FIXED
         - overruling an advisory rejection at the final step needs a note (handoff 7.4);
         - usp_Request_ApplyApprovalEffects stamped AdvanceDate with the server's GETDATE().

   TRANSACTIONS: a refusal found BEFORE anything was written ends the procedure's own transaction level with COMMIT
   (nothing to undo) and then RAISERROR + RETURN 1 - ROLLBACK is not allowed inside INSERT...EXEC (error 3915, and
   usp_Request_Approve / usp_Request_WithdrawDecision run under one) and would undo a caller's own work. A failure
   AFTER a write rolls back at top level, and THROWs (XACT_ABORT undoes everything) when nested.

   PREREQUISITES: 99 (workflow.LEAVE_REQUEST.ApprovedToDate), 82/84 (payroll.fn_IsPeriodPaid,
   attendance.usp_Attendance_RecomputeLeaveRange) and the base workflow.fn_ReversalBlockReason and
   attendance.usp_Attendance_ComputeDay. Optional: attendance.usp_Roster_RederiveMonth (102, unit C).
   STALE COPIES (CON-7): usp_Request_WithdrawDecision, usp_Request_ReopenClosed, usp_Request_MoveToVersion,
   usp_Request_GetOnOldVersions and usp_ExitPermission_WithdrawDecision were last defined by unnumbered scripts; each
   is checked against what the API passes and reads, and a guard batch right before it stops this script when the
   live procedure has a parameter this one does not know. usp_Request_Reject/_Cancel/_PutOnHold/_Resume/_Submit and
   fn_ResolveApprover are NOT redefined (MoveToVersion calls fn_ResolveApprover with whatever parameters it has).
   DATA REPAIRS (guarded, idempotent; no money is touched): ApprovedToDate cleared on leave requests that are no longer
   approved; roster months still Approved on an approval that was taken back (old reversals had no roster arm) are
   listed for a person to review - un-approving a roster in use is not done by a script.

   Re-runnable: CREATE OR ALTER throughout. Apply with sqlcmd -I.
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------------------------------------------------------------- prerequisites ---- */
IF COL_LENGTH('workflow.LEAVE_REQUEST', 'ApprovedToDate') IS NULL
    RAISERROR('101_qa3_workflow.sql needs workflow.LEAVE_REQUEST.ApprovedToDate (script 99, leave). Apply 99 first.', 16, 1);
GO
IF OBJECT_ID('payroll.fn_IsPeriodPaid') IS NULL OR OBJECT_ID('attendance.usp_Attendance_RecomputeLeaveRange') IS NULL
    RAISERROR('101_qa3_workflow.sql needs scripts 82 and 84 (payroll.fn_IsPeriodPaid, attendance.usp_Attendance_RecomputeLeaveRange). Apply them first.', 16, 1);
GO
IF OBJECT_ID('workflow.fn_ReversalBlockReason') IS NULL OR OBJECT_ID('attendance.usp_Attendance_ComputeDay') IS NULL
   OR OBJECT_ID('workflow.fn_ResolveApprover') IS NULL OR OBJECT_ID('workflow.fn_CanUserActOnStep') IS NULL
    RAISERROR('101_qa3_workflow.sql needs the base workflow.fn_ReversalBlockReason, fn_ResolveApprover, fn_CanUserActOnStep and attendance.usp_Attendance_ComputeDay.', 16, 1);
GO

/* ============================================================================
   1. Which approvals can be taken back (WF-8, WF-16 / LEV-11 for reversals)
   ============================================================================ */
/* NULL when the request's APPROVAL can be undone safely, else the sentence that says why not and what to do instead.
   Complements the base workflow.fn_ReversalBlockReason (whose body is not in the repository); the callers ask both.
   A REJECTED request has no effect to undo, so only an approved one is examined. */
CREATE OR ALTER FUNCTION workflow.fn_ReversalUndoBlock (@RequestInstanceId INT)
RETURNS NVARCHAR(300)
AS
BEGIN
    DECLARE @Code VARCHAR(40), @TypeName NVARCHAR(80), @Status VARCHAR(20);
    SELECT @Code = rt.Code, @TypeName = rt.Name, @Status = ri.[Status]
    FROM workflow.REQUEST_INSTANCE ri
    JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = ri.RequestTypeId
    WHERE ri.RequestInstanceId = @RequestInstanceId;

    IF @Code IS NULL OR @Status <> 'Approved' RETURN NULL;

    /* decision: only the types whose effect has a safe undo arm (usp_Reversal_UndoEffects) */
    IF @Code NOT IN ('LEAVE_REQUEST', 'SALARY_ADVANCE', 'PAYROLL_ADJUSTMENT', 'EXIT_PERMISSION', 'OVERTIME', 'ROSTER_APPROVAL')
        RETURN CONCAT(N'An approved ', LOWER(@TypeName), N' cannot be taken back: what its approval did has no safe undo. Raise a new request to correct it.');

    DECLARE @Paid NVARCHAR(300) = N'This period is paid ' + NCHAR(8212) + N' raise a payroll adjustment instead.';

    IF @Code = 'LEAVE_REQUEST'
    BEGIN
        DECLARE @LvEmp INT, @LvFrom DATE, @LvTo DATE;
        SELECT @LvEmp = EmployeeId, @LvFrom = FromDate, @LvTo = ISNULL(ApprovedToDate, ToDate)
        FROM workflow.LEAVE_REQUEST WHERE RequestInstanceId = @RequestInstanceId;
        /* the period guard is per employee and month: every month the approved days touch */
        DECLARE @m DATE = DATEFROMPARTS(YEAR(@LvFrom), MONTH(@LvFrom), 1);
        WHILE @LvEmp IS NOT NULL AND @m <= @LvTo
        BEGIN
            IF payroll.fn_IsPeriodPaid(@LvEmp, CASE WHEN @m < @LvFrom THEN @LvFrom ELSE @m END) = 1 RETURN @Paid;
            SET @m = DATEADD(MONTH, 1, @m);
        END
    END

    IF @Code = 'EXIT_PERMISSION'
    BEGIN
        DECLARE @EpEmp INT, @EpDate DATE;
        SELECT @EpEmp = EmployeeId, @EpDate = ExitDate FROM workflow.EXIT_PERMISSION WHERE RequestInstanceId = @RequestInstanceId;
        IF @EpEmp IS NOT NULL AND payroll.fn_IsPeriodPaid(@EpEmp, @EpDate) = 1 RETURN @Paid;
        /* the period close converted the day's exit minutes to leave (or to unpaid days) once, keyed by the day */
        IF EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER l
                   JOIN workflow.EXIT_PERMISSION e2 ON e2.ExitPermissionId = l.SourceRef
                   WHERE l.SourceType = 'ExitPermission' AND e2.EmployeeId = @EpEmp AND e2.ExitDate = @EpDate)
           OR EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a
                      WHERE a.EmployeeId = @EpEmp AND a.WorkDate = @EpDate AND ISNULL(a.ExitUnpaidDays, 0) > 0)
            RETURN N'The exit minutes of that day were already converted to leave at the period close - correct the attendance day instead.';
    END

    IF @Code = 'OVERTIME'
    BEGIN
        DECLARE @OtEmp INT, @OtDate DATE;
        SELECT @OtEmp = EmployeeId, @OtDate = WorkDate FROM workflow.OVERTIME_REQUEST WHERE RequestInstanceId = @RequestInstanceId;
        IF @OtEmp IS NOT NULL AND payroll.fn_IsPeriodPaid(@OtEmp, @OtDate) = 1 RETURN @Paid;
    END

    IF @Code = 'ROSTER_APPROVAL'
    BEGIN
        DECLARE @RaBranch INT, @RaMonth DATE;
        SELECT @RaBranch = BranchId, @RaMonth = MonthDate FROM workflow.ROSTER_APPROVAL WHERE RequestInstanceId = @RequestInstanceId;
        /* anybody rostered in that branch-month (the branch of the DAY) already paid for the month */
        IF EXISTS (SELECT 1
                   FROM (SELECT DISTINCT sa.EmployeeId
                         FROM attendance.SHIFT_ASSIGNMENT sa
                         WHERE sa.WorkDate >= @RaMonth AND sa.WorkDate < DATEADD(MONTH, 1, @RaMonth)
                           AND hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate) = @RaBranch) x
                   WHERE payroll.fn_IsPeriodPaid(x.EmployeeId, @RaMonth) = 1)
            RETURN @Paid;
    END

    /* consumed money (the base fn_ReversalBlockReason says so too; asked again because UndoEffects only removes
       untouched rows, and a consumed one left behind would make the reversal a lie) */
    IF @Code = 'PAYROLL_ADJUSTMENT'
       AND EXISTS (SELECT 1 FROM workflow.PAYROLL_ADJUSTMENT_REQUEST q
                   JOIN payroll.PAYROLL_ADJUSTMENT a ON a.PayrollAdjustmentId = q.CreatedAdjustmentId
                   WHERE q.RequestInstanceId = @RequestInstanceId AND a.AppliedToPayslipId IS NOT NULL)
        RETURN N'Its adjustment was already paid by a payroll run - correct it with a counter-adjustment.';
    IF @Code = 'SALARY_ADVANCE'
       AND EXISTS (SELECT 1 FROM workflow.SALARY_ADVANCE_REQUEST q
                   JOIN payroll.SALARY_ADVANCE a ON a.SalaryAdvanceId = q.CreatedAdvanceId
                   WHERE q.RequestInstanceId = @RequestInstanceId AND (a.RemainingAmount <> a.Amount OR a.IsSettled = 1))
        RETURN N'Recovery of this advance has started - it can no longer be taken back.';

    RETURN NULL;
END;
GO

/* ============================================================================
   2. Re-running the create guards when a request comes back (WF-6)
   ============================================================================ */
/* NULL when the request can be in flight again next to everything raised since it closed, else the create guard's own
   sentence. The request itself is excluded; an approved neighbour counts with the days it was actually approved for. */
CREATE OR ALTER FUNCTION workflow.fn_ReopenConflict (@RequestInstanceId INT)
RETURNS NVARCHAR(300)
AS
BEGIN
    DECLARE @Code VARCHAR(40) = (SELECT rt.Code FROM workflow.REQUEST_INSTANCE ri
                                 JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = ri.RequestTypeId
                                 WHERE ri.RequestInstanceId = @RequestInstanceId);
    DECLARE @Clash NVARCHAR(300);

    IF @Code = 'LEAVE_REQUEST'
        SELECT TOP 1 @Clash = CONCAT(N'These dates overlap leave request #', o.RequestInstanceId, N' from ',
                                     CONVERT(CHAR(10), o.FromDate, 23), N' to ',
                                     CONVERT(CHAR(10), CASE WHEN r.[Status] = 'Approved' THEN ISNULL(o.ApprovedToDate, o.ToDate) ELSE o.ToDate END, 23),
                                     N' (', r.[Status], N'). Cancel or change it first.')
        FROM workflow.LEAVE_REQUEST me
        JOIN workflow.LEAVE_REQUEST o ON o.EmployeeId = me.EmployeeId AND o.RequestInstanceId <> me.RequestInstanceId
        JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = o.RequestInstanceId
        WHERE me.RequestInstanceId = @RequestInstanceId
          AND r.[Status] IN ('Pending', 'OnHold', 'Approved')
          AND o.FromDate <= me.ToDate
          AND CASE WHEN r.[Status] = 'Approved' THEN ISNULL(o.ApprovedToDate, o.ToDate) ELSE o.ToDate END >= me.FromDate
        ORDER BY o.FromDate, o.RequestInstanceId;

    IF @Code = 'OVERTIME'
        SELECT TOP 1 @Clash = CONCAT(N'An overtime request already exists for this employee on that date (#', o.RequestInstanceId, N', ', r.[Status], N').')
        FROM workflow.OVERTIME_REQUEST me
        JOIN workflow.OVERTIME_REQUEST o ON o.EmployeeId = me.EmployeeId AND o.WorkDate = me.WorkDate
                                        AND o.RequestInstanceId <> me.RequestInstanceId
        JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = o.RequestInstanceId
        WHERE me.RequestInstanceId = @RequestInstanceId AND r.[Status] IN ('Pending', 'OnHold', 'Approved')
        ORDER BY o.RequestInstanceId;

    IF @Code = 'EXIT_PERMISSION'
        SELECT TOP 1 @Clash = CONCAT(N'This employee already has a pending or approved exit permission that overlaps those times (#', o.RequestInstanceId, N').')
        FROM workflow.EXIT_PERMISSION me
        JOIN workflow.EXIT_PERMISSION o ON o.EmployeeId = me.EmployeeId AND o.ExitDate = me.ExitDate
                                       AND o.RequestInstanceId <> me.RequestInstanceId
                                       AND o.FromTime < me.ToTime AND o.ToTime > me.FromTime
        JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = o.RequestInstanceId
        WHERE me.RequestInstanceId = @RequestInstanceId AND r.[Status] IN ('Pending', 'OnHold', 'Approved')
        ORDER BY o.RequestInstanceId;

    IF @Code = 'ROSTER_APPROVAL'
        SELECT TOP 1 @Clash = CONCAT(N'This roster is already waiting for approval (request #', o.RequestInstanceId, N').')
        FROM workflow.ROSTER_APPROVAL me
        JOIN workflow.ROSTER_APPROVAL o ON o.BranchId = me.BranchId AND o.MonthDate = me.MonthDate
                                       AND o.RequestInstanceId <> me.RequestInstanceId
        JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = o.RequestInstanceId
        WHERE me.RequestInstanceId = @RequestInstanceId AND r.[Status] IN ('Draft', 'Pending', 'OnHold')
        ORDER BY o.RequestInstanceId DESC;

    RETURN @Clash;
END;
GO

/* ============================================================================
   3. Putting back the figure a struck decision changed (WF-4 / LEV-7)
   ============================================================================ */
/* The typed _Decide procedures write the figure AS IT STOOD before their decision into the step's ValueBefore (exit
   permission: the minutes; leave, unit D: the standing days). Retract, reopen and withdraw call this BEFORE they unsign
   the step (unsigning clears ValueBefore), inside their own transaction. No result set, no transaction of its own.
   ValueBefore is text: '<figure>' or '<figure>|<second>' - for a leave the second part is the discretionary flag
   (0/1), for an advance the monthly deduction. A leave's discretionary flag belongs to the decision that set it, so
   when the struck decision's ValueBefore does not carry the earlier flag it goes back to 0 (the next decision states
   it again; an auto-approval in between must not grant days nobody stands behind). */
CREATE OR ALTER PROCEDURE workflow.usp_Request_RestoreFigure
    @RequestInstanceId INT,
    @StepNo            INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @VB NVARCHAR(100), @Code VARCHAR(40);
    SELECT @VB = NULLIF(LTRIM(RTRIM(si.ValueBefore)), N''), @Code = rt.Code
    FROM workflow.REQUEST_STEP_INSTANCE si
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = si.RequestInstanceId
    JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = ri.RequestTypeId
    WHERE si.RequestInstanceId = @RequestInstanceId AND si.StepNo = @StepNo;

    IF @Code IS NULL RETURN 0;

    DECLARE @Bar INT = CHARINDEX(N'|', ISNULL(@VB, N''));
    DECLARE @Main NVARCHAR(100) = LTRIM(RTRIM(CASE WHEN @Bar > 0 THEN LEFT(@VB, @Bar - 1) ELSE @VB END));
    DECLARE @Second NVARCHAR(100) = LTRIM(RTRIM(CASE WHEN @Bar > 0 THEN SUBSTRING(@VB, @Bar + 1, 100) END));

    IF @Code = 'LEAVE_REQUEST'
    BEGIN
        UPDATE workflow.LEAVE_REQUEST
        SET DaysApproved    = COALESCE(TRY_CAST(@Main AS NUMERIC(20,1)), DaysApproved),
            IsDiscretionary = CASE WHEN @Second IN (N'1', N'0') THEN CAST(@Second AS BIT) ELSE 0 END
        WHERE RequestInstanceId = @RequestInstanceId;
        RETURN 0;
    END

    IF @VB IS NULL RETURN 0;      -- the struck decision changed no figure

    IF @Code = 'EXIT_PERMISSION' AND TRY_CAST(@Main AS INT) IS NOT NULL
        UPDATE workflow.EXIT_PERMISSION SET ApprovedMinutes = TRY_CAST(@Main AS INT)
        WHERE RequestInstanceId = @RequestInstanceId;

    IF @Code = 'OVERTIME' AND TRY_CAST(@Main AS INT) IS NOT NULL
        UPDATE workflow.OVERTIME_REQUEST SET ApprovedMinutes = TRY_CAST(@Main AS INT)
        WHERE RequestInstanceId = @RequestInstanceId;

    IF @Code = 'SALARY_ADVANCE' AND TRY_CAST(@Main AS DECIMAL(18,2)) IS NOT NULL
        UPDATE workflow.SALARY_ADVANCE_REQUEST
        SET ApprovedAmount = TRY_CAST(@Main AS DECIMAL(18,2)),
            ApprovedMonthlyDeduction = COALESCE(TRY_CAST(@Second AS DECIMAL(18,2)), ApprovedMonthlyDeduction)
        WHERE RequestInstanceId = @RequestInstanceId;

    IF @Code = 'PAYROLL_ADJUSTMENT' AND TRY_CAST(@Main AS DECIMAL(18,2)) IS NOT NULL
        UPDATE workflow.PAYROLL_ADJUSTMENT_REQUEST SET ApprovedAmount = TRY_CAST(@Main AS DECIMAL(18,2))
        WHERE RequestInstanceId = @RequestInstanceId;

    RETURN 0;
END;
GO

/* ============================================================================
   4. Undoing what an approval did (WF-1, WF-8, ROS-11, ATT-5)
   ============================================================================ */
/* Called by the reversals for an APPROVED request, inside their transaction, BEFORE the request's status moves.
   Removes or resets what the approval created; the attendance days are re-derived afterwards by
   workflow.usp_Reversal_Rederive, once the request no longer reads Approved (the day rule counts approved requests).
   Only rows that are still untouched are removed; anything further along was refused before this point by
   workflow.fn_ReversalBlockReason / fn_ReversalUndoBlock. No result set. */
CREATE OR ALTER PROCEDURE workflow.usp_Reversal_UndoEffects
    @RequestInstanceId INT
AS
BEGIN
    SET NOCOUNT ON;

    /* ---- payroll adjustment: the ids, then the request's POINTER, then the row (WF-1 - the order is the fix) ---- */
    DECLARE @AdjIds TABLE (Id INT PRIMARY KEY);
    INSERT INTO @AdjIds (Id)
    SELECT a.PayrollAdjustmentId
    FROM workflow.PAYROLL_ADJUSTMENT_REQUEST q
    JOIN payroll.PAYROLL_ADJUSTMENT a ON a.PayrollAdjustmentId = q.CreatedAdjustmentId
    WHERE q.RequestInstanceId = @RequestInstanceId AND a.AppliedToPayslipId IS NULL;

    UPDATE workflow.PAYROLL_ADJUSTMENT_REQUEST
    SET CreatedAdjustmentId = NULL, AdjustmentCreatedAt = NULL
    WHERE RequestInstanceId = @RequestInstanceId AND CreatedAdjustmentId IN (SELECT Id FROM @AdjIds);

    DELETE a FROM payroll.PAYROLL_ADJUSTMENT a WHERE a.PayrollAdjustmentId IN (SELECT Id FROM @AdjIds);

    /* ---- salary advance: same order; only an advance whose recovery has not started ---- */
    DECLARE @AdvIds TABLE (Id INT PRIMARY KEY);
    INSERT INTO @AdvIds (Id)
    SELECT a.SalaryAdvanceId
    FROM workflow.SALARY_ADVANCE_REQUEST q
    JOIN payroll.SALARY_ADVANCE a ON a.SalaryAdvanceId = q.CreatedAdvanceId
    WHERE q.RequestInstanceId = @RequestInstanceId AND a.RemainingAmount = a.Amount AND a.IsSettled = 0;

    UPDATE workflow.SALARY_ADVANCE_REQUEST
    SET CreatedAdvanceId = NULL, AdvanceCreatedAt = NULL
    WHERE RequestInstanceId = @RequestInstanceId AND CreatedAdvanceId IN (SELECT Id FROM @AdvIds);

    DELETE a FROM payroll.SALARY_ADVANCE a WHERE a.SalaryAdvanceId IN (SELECT Id FROM @AdvIds);

    /* ---- leave (script 84's arm): EVERY ledger row of the request - the usage, one row per month, and the
            discretionary give-back - and the marks the posting left: AppliedToLedgerAt, and unit D's ApprovedToDate
            (the last day the approval covered; contract: unit A clears it) and PaidSnapshot (taken again at the next
            final approval) ---- */
    DELETE l
    FROM hr.LEAVE_LEDGER l
    JOIN workflow.LEAVE_REQUEST lr ON lr.LeaveRequestId = l.LeaveRequestId
    WHERE lr.RequestInstanceId = @RequestInstanceId
      AND l.MovementType IN ('Usage', 'Adjustment');
    UPDATE workflow.LEAVE_REQUEST
    SET AppliedToLedgerAt = NULL, ApprovedToDate = NULL
    WHERE RequestInstanceId = @RequestInstanceId;
    IF COL_LENGTH('workflow.LEAVE_REQUEST', 'PaidSnapshot') IS NOT NULL
        EXEC sp_executesql N'UPDATE workflow.LEAVE_REQUEST SET PaidSnapshot = NULL WHERE RequestInstanceId = @r',
                           N'@r INT', @r = @RequestInstanceId;

    /* ---- exit permission (WF-8 / ATT-5): no longer applied; the day stops pointing at it ---- */
    DECLARE @EpId INT = (SELECT ExitPermissionId FROM workflow.EXIT_PERMISSION WHERE RequestInstanceId = @RequestInstanceId);
    IF @EpId IS NOT NULL
    BEGIN
        UPDATE workflow.EXIT_PERMISSION SET AppliedToAttendanceAt = NULL WHERE ExitPermissionId = @EpId;
        UPDATE attendance.ATTENDANCE_RECORD SET ExitPermissionId = NULL WHERE ExitPermissionId = @EpId;
    END

    /* ---- overtime (WF-8): the approved minutes stamped on the worked day go ---- */
    DECLARE @OtId INT = (SELECT OvertimeRequestId FROM workflow.OVERTIME_REQUEST WHERE RequestInstanceId = @RequestInstanceId);
    IF @OtId IS NOT NULL
    BEGIN
        UPDATE attendance.ATTENDANCE_RECORD
        SET OvertimeApprovedMinutes = NULL, OvertimeRequestId = NULL
        WHERE OvertimeRequestId = @OtId;
        UPDATE workflow.OVERTIME_REQUEST SET AppliedToAttendanceAt = NULL WHERE OvertimeRequestId = @OtId;
    END

    /* ---- roster approval (WF-8 / ROS-11): the month follows the approval that still stands ---- */
    DECLARE @RaBranch INT, @RaMonth DATE;
    SELECT @RaBranch = BranchId, @RaMonth = MonthDate FROM workflow.ROSTER_APPROVAL WHERE RequestInstanceId = @RequestInstanceId;
    IF @RaBranch IS NOT NULL
    BEGIN
        UPDATE workflow.ROSTER_APPROVAL SET AppliedAt = NULL WHERE RequestInstanceId = @RequestInstanceId;

        /* only when the header follows THIS approval - a later one that superseded it keeps the month as it is */
        IF EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH
                   WHERE BranchId = @RaBranch AND MonthDate = @RaMonth AND RequestInstanceId = @RequestInstanceId)
        BEGIN
            DECLARE @PrevRid INT, @PrevAt DATETIME2;
            SELECT TOP 1 @PrevRid = ri.RequestInstanceId, @PrevAt = ri.ClosedAt
            FROM workflow.ROSTER_APPROVAL ra
            JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
            WHERE ra.BranchId = @RaBranch AND ra.MonthDate = @RaMonth
              AND ra.RequestInstanceId <> @RequestInstanceId
              AND ri.[Status] = 'Approved' AND ra.AppliedAt IS NOT NULL
            ORDER BY ri.ClosedAt DESC, ri.RequestInstanceId DESC;

            /* the request goes back in flight, so the header points at it (as usp_RosterApproval_Create does for a
               re-submission); the month stays Approved on the earlier approval when there is one */
            UPDATE attendance.ROSTER_MONTH
            SET [Status]   = CASE WHEN @PrevRid IS NOT NULL THEN 'Approved' ELSE 'PendingApproval' END,
                ApprovedAt = @PrevAt
            WHERE BranchId = @RaBranch AND MonthDate = @RaMonth;
        END
    END

    RETURN 0;
END;
GO

/* After the status moved away from Approved (inside the reversal's transaction): the attendance days the approval
   touched are derived again by the day rule. No result set. */
CREATE OR ALTER PROCEDURE workflow.usp_Reversal_Rederive
    @RequestInstanceId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Code VARCHAR(40) = (SELECT rt.Code FROM workflow.REQUEST_INSTANCE ri
                                 JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = ri.RequestTypeId
                                 WHERE ri.RequestInstanceId = @RequestInstanceId);
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);

    IF @Code = 'LEAVE_REQUEST'
        EXEC attendance.usp_Attendance_RecomputeLeaveRange @RequestInstanceId = @RequestInstanceId;

    IF @Code IN ('EXIT_PERMISSION', 'OVERTIME')
    BEGIN
        DECLARE @Emp INT, @Day DATE;
        IF @Code = 'EXIT_PERMISSION'
            SELECT @Emp = EmployeeId, @Day = ExitDate FROM workflow.EXIT_PERMISSION WHERE RequestInstanceId = @RequestInstanceId;
        ELSE
            SELECT @Emp = EmployeeId, @Day = WorkDate FROM workflow.OVERTIME_REQUEST WHERE RequestInstanceId = @RequestInstanceId;
        IF @Emp IS NOT NULL AND @Day <= @Today
           AND (EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @Emp AND WorkDate = @Day)
                OR EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @Emp AND WorkDate = @Day))
            EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @Day;
    END

    /* the roster month: unit C's re-derivation (102), when it is installed */
    IF @Code = 'ROSTER_APPROVAL' AND OBJECT_ID('attendance.usp_Roster_RederiveMonth') IS NOT NULL
    BEGIN
        DECLARE @B INT, @M DATE;
        SELECT @B = BranchId, @M = MonthDate FROM workflow.ROSTER_APPROVAL WHERE RequestInstanceId = @RequestInstanceId;
        IF @B IS NOT NULL
        BEGIN
            DECLARE @Y INT = YEAR(@M), @Mo INT = MONTH(@M);
            EXEC attendance.usp_Roster_RederiveMonth @BranchId = @B, @Year = @Y, @Month = @Mo;
        END
    END

    RETURN 0;
END;
GO

/* WF-15: a decision that no longer stands takes its closing mail with it, so the NEXT outcome is mailed again
   (the queue writes one mail per request and channel and skips a request that already has one). An unsent mail
   about the old outcome is never sent. */
CREATE OR ALTER PROCEDURE workflow.usp_Request_SupersedeOutbox
    @RequestInstanceId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF OBJECT_ID('core.EMAIL_OUTBOX') IS NOT NULL
        DELETE FROM core.EMAIL_OUTBOX WHERE RequestInstanceId = @RequestInstanceId;
    RETURN 0;
END;
GO

/* ============================================================================
   5. What an approval does (script 84's body; WF-9, ATT-4, ATT-5, AdvanceDate)
   ============================================================================ */
/* Idempotent and type-guarded (each arm has its marker), emits NO result set and does no INSERT...EXEC, because it
   runs inside usp_Request_Approve, which the typed _Decide procedures capture with INSERT...EXEC. Changes from 84:
     - SALARY_ADVANCE: AdvanceDate is Beirut's date, not the server's GETDATE();
     - OVERTIME (ATT-4): when the worked day already has a record it is derived again (the day rule reads the
       approved minutes), so overtime approved after the day was processed is paid;
     - EXIT_PERMISSION (ATT-5): applied at the final approval when the day already has a record - the same work as
       usp_ExitPermission_ApplyToAttendance for one permission (re-derive, point the day at it, stamp it); a day not
       yet worked is still applied by the nightly job. */
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

    /* ---- LEAVE: post Usage once; discretionary adds the give-back rows (through the one poster) ---- */
    IF @Code = 'LEAVE_REQUEST'
        EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId=@RequestInstanceId, @ActorUserId=@ActorUserId,
             @UsageNote=N'Approved leave request (applied on approval).';

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
        SELECT EmployeeId, @RequestInstanceId, @Amt, CurrencyCode,
               CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE),      -- QA3: Beirut's date
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

    /* ---- OVERTIME: settle the figure, link it to the worked day and (QA3 ATT-4) derive that day again, so the
            approved minutes count; the marker is stamped only once the worked day exists ---- */
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

        DECLARE @OtEmp INT, @OtDay DATE;
        SELECT @OtEmp = o.EmployeeId, @OtDay = o.WorkDate
        FROM workflow.OVERTIME_REQUEST o
        WHERE o.RequestInstanceId = @RequestInstanceId
          AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD ar WHERE ar.EmployeeId = o.EmployeeId AND ar.WorkDate = o.WorkDate);
        IF @OtEmp IS NOT NULL
            EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @OtEmp, @WorkDate = @OtDay;

        UPDATE o SET AppliedToAttendanceAt = SYSUTCDATETIME()
        FROM workflow.OVERTIME_REQUEST o
        JOIN attendance.ATTENDANCE_RECORD ar ON ar.OvertimeRequestId = o.OvertimeRequestId
        WHERE o.RequestInstanceId = @RequestInstanceId AND o.AppliedToAttendanceAt IS NULL;
    END

    /* ---- EXIT PERMISSION (QA3 ATT-5): applied at the final approval when the day already has a record ---- */
    IF @Code = 'EXIT_PERMISSION'
    BEGIN
        DECLARE @EpId INT, @EpEmp INT, @EpDay DATE;
        SELECT @EpId = ep.ExitPermissionId, @EpEmp = ep.EmployeeId, @EpDay = ep.ExitDate
        FROM workflow.EXIT_PERMISSION ep
        WHERE ep.RequestInstanceId = @RequestInstanceId AND ep.AppliedToAttendanceAt IS NULL
          AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = ep.EmployeeId AND a.WorkDate = ep.ExitDate);
        IF @EpId IS NOT NULL
        BEGIN
            /* the rule reads the approved minutes itself; a manual day is left to HR */
            EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @EpEmp, @WorkDate = @EpDay;

            UPDATE attendance.ATTENDANCE_RECORD
            SET ExitPermissionId = @EpId,
                HrNote = CASE WHEN HrNote IS NULL THEN N'Applied from approved exit permission.' ELSE HrNote END
            WHERE EmployeeId = @EpEmp AND WorkDate = @EpDay AND ExitPermissionId IS NULL;

            UPDATE workflow.EXIT_PERMISSION SET AppliedToAttendanceAt = SYSUTCDATETIME() WHERE ExitPermissionId = @EpId;
        END
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
            the previous one - the header follows the request that approved last. ---- */
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
   6. Approving a step (script 75's body; WF-2, the advisory overrule note, ATT-5)
   ============================================================================ */
/* Changes from 75:
     - WF-2: the transaction opens BEFORE the read; the request row is locked (UPDLOCK, ROWLOCK) and the status and
       step are checked under the lock; the step update expects the step still open and the request update expects
       the request still at that step - otherwise "This step was decided a moment ago - reload.". @ExpectedStepNo
       (optional, last) is the step the caller was deciding: a different current step means somebody else moved it.
     - handoff 7.4: approving at the final step over an advisory rejection needs a note.
     - ATT-5: closing an EXIT_PERMISSION applies it to the attendance day (its typed decide stamps the minutes BEFORE
       it calls this), as ROSTER_APPROVAL already was. The other typed types still apply their own effects after the
       engine call, with the figure they stamp then.
   The result set is unchanged (seven columns; the typed _Decide procedures capture it with INSERT...EXEC). */
CREATE OR ALTER PROCEDURE workflow.usp_Request_Approve
    @RequestInstanceId  INT,
    @ActedByUserId      INT,
    @Comment            NVARCHAR(1000) = NULL,
    @ChangeSummary      NVARCHAR(300)  = NULL,
    @SignedWithPassword BIT = 0,
    @ExpectedStepNo     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Tc INT = @@TRANCOUNT, @Rows INT, @Msg NVARCHAR(400);
    DECLARE @Moment NVARCHAR(200) = N'This step was decided a moment ago ' + NCHAR(8212) + N' reload.';

    DECLARE @Changed BIT = CASE WHEN @ChangeSummary IS NULL
                                  OR LTRIM(RTRIM(@ChangeSummary)) = '' THEN 0 ELSE 1 END;

    BEGIN TRAN;

    DECLARE @Step INT, @ReqStatus VARCHAR(20), @DefId INT, @TypeCode VARCHAR(40), @ClosedAt DATETIME2;
    SELECT @Step = ri.CurrentStepNo, @ReqStatus = ri.[Status], @DefId = ri.WorkflowDefinitionId, @ClosedAt = ri.ClosedAt,
           @TypeCode = (SELECT rt.Code FROM workflow.REQUEST_TYPE rt WHERE rt.RequestTypeId = ri.RequestTypeId)
    FROM workflow.REQUEST_INSTANCE ri WITH (UPDLOCK, ROWLOCK)
    WHERE ri.RequestInstanceId = @RequestInstanceId;

    /* refusals before any write end this level with COMMIT: nothing to undo, and ROLLBACK is not allowed under the
       INSERT...EXEC the typed procedures wrap this in */
    IF @ReqStatus IS NULL BEGIN COMMIT; RAISERROR('Request not found.', 16, 1); RETURN 1; END
    IF @ReqStatus NOT IN ('Pending','OnHold')
    BEGIN
        COMMIT;
        IF @ClosedAt >= DATEADD(MINUTE, -2, SYSUTCDATETIME()) RAISERROR(@Moment, 16, 1);       -- closed while the caller looked at it
        ELSE RAISERROR('This request is already closed.', 16, 1);
        RETURN 1;
    END
    IF @ExpectedStepNo IS NOT NULL AND @ExpectedStepNo <> ISNULL(@Step, -1)
    BEGIN COMMIT; RAISERROR(@Moment, 16, 1); RETURN 1; END

    DECLARE @StepInstId INT, @StepStatus VARCHAR(20);
    SELECT @StepInstId = RequestStepInstanceId, @StepStatus = [Status]
    FROM workflow.REQUEST_STEP_INSTANCE WITH (UPDLOCK, ROWLOCK)
    WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @Step;
    IF @StepInstId IS NULL OR @StepStatus NOT IN ('Pending','OnHold')
    BEGIN COMMIT; RAISERROR(@Moment, 16, 1); RETURN 1; END

    IF workflow.fn_CanUserActOnStep(@StepInstId, @ActedByUserId) = 0
    BEGIN COMMIT; RAISERROR('You are not the approver for this step.', 16, 1); RETURN 1; END

    DECLARE @NeedsSignature BIT =
        CASE WHEN ISNULL((SELECT RequiresSignature FROM workflow.WORKFLOW_STEP
                          WHERE WorkflowDefinitionId = @DefId AND StepNo = @Step), 0) = 1
               OR EXISTS (SELECT 1 FROM security.USER_ROLE ur
                          JOIN security.[ROLE] r ON r.RoleId = ur.RoleId
                          WHERE ur.UserId = @ActedByUserId AND r.RequiresSignaturePassword = 1)
             THEN 1 ELSE 0 END;
    IF @NeedsSignature = 1 AND @SignedWithPassword = 0
    BEGIN COMMIT; RAISERROR('This decision must be signed with your password.', 16, 1); RETURN 1; END

    DECLARE @CanAdjust BIT = 0, @RequiresComment BIT = 0;
    SELECT @CanAdjust = ISNULL(CanAdjust,0), @RequiresComment = ISNULL(RequiresComment,0)
    FROM workflow.WORKFLOW_STEP WHERE WorkflowDefinitionId = @DefId AND StepNo = @Step;

    IF @Changed = 1 AND @CanAdjust = 0
    BEGIN COMMIT; RAISERROR('This step may approve or reject, but may not change what was requested.', 16, 1); RETURN 1; END
    IF (@Changed = 1 OR @RequiresComment = 1)
       AND (@Comment IS NULL OR LTRIM(RTRIM(@Comment)) = '')
    BEGIN COMMIT; RAISERROR('A comment is required with this decision. Say why.', 16, 1); RETURN 1; END

    /* where the request goes once this step is signed: the next step still open, or nowhere (closed) */
    DECLARE @NextStep INT = (SELECT MIN(StepNo) FROM workflow.REQUEST_STEP_INSTANCE
                             WHERE RequestInstanceId = @RequestInstanceId AND StepNo <> @Step
                               AND [Status] IN ('Pending','OnHold'));
    DECLARE @Overruled NVARCHAR(300) = NULL;
    IF @NextStep IS NULL
        SET @Overruled = (SELECT STRING_AGG(CONCAT(N'step ', si.StepNo, N' (', si.Name, N')'), N', ')
                                 WITHIN GROUP (ORDER BY si.StepNo)
                          FROM workflow.REQUEST_STEP_INSTANCE si
                          WHERE si.RequestInstanceId = @RequestInstanceId
                            AND si.[Status] = 'Rejected' AND si.StepNo < @Step);
    /* handoff 7.4: a rejection before the final step is advisory - the final approver may overrule it WITH a note */
    IF @Overruled IS NOT NULL AND (@Comment IS NULL OR LTRIM(RTRIM(@Comment)) = '')
    BEGIN
        COMMIT;
        SET @Msg = LEFT(CONCAT(N'Approving here overrules the rejection at ', @Overruled, N' - add a note saying why.'), 400);
        RAISERROR(N'%s', 16, 1, @Msg);
        RETURN 1;
    END

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

    /* the first write expects the step still open: if not, nothing has been written yet */
    UPDATE workflow.REQUEST_STEP_INSTANCE
    SET [Status]='Approved', Decision=@DecisionKind,
        ActedByUserId=@ActedByUserId, ActedAt=SYSUTCDATETIME(), Comment=@FullComment,
        SignedWithPassword=@SignedWithPassword,
        HoldReason=NULL, HoldSetAt=NULL, HoldSetByUserId=NULL, WaitingOnRequester=0
    WHERE RequestStepInstanceId=@StepInstId AND [Status] IN ('Pending','OnHold');
    IF @@ROWCOUNT <> 1 BEGIN COMMIT; RAISERROR(@Moment, 16, 1); RETURN 1; END

    INSERT INTO workflow.WORKFLOW_SIGNATURE
        (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment, SignedWithPassword,
         SignatureImage, SignatureContentType)
    VALUES (@RequestInstanceId, @Step, 'Approved', @ActedByUserId,
            LEFT(@FullComment,300), @SignedWithPassword, @Img, @ImgType);

    IF @NextStep IS NULL
    BEGIN
        UPDATE workflow.REQUEST_INSTANCE
        SET [Status]='Approved', CurrentStepNo=NULL, ClosedAt=SYSUTCDATETIME(),
            ClosedReason = CASE WHEN @Overruled IS NOT NULL
                THEN LEFT(CONCAT(N'Approved at the final step, overruling a rejection at ', @Overruled, N'.'),300)
                ELSE NULL END
        WHERE RequestInstanceId=@RequestInstanceId AND [Status] IN ('Pending','OnHold') AND CurrentStepNo = @Step;
        SET @Rows = @@ROWCOUNT;
    END
    ELSE
    BEGIN
        UPDATE workflow.REQUEST_INSTANCE SET [Status]='Pending', CurrentStepNo=@NextStep
        WHERE RequestInstanceId=@RequestInstanceId AND [Status] IN ('Pending','OnHold') AND CurrentStepNo = @Step;
        SET @Rows = @@ROWCOUNT;
    END
    IF @Rows <> 1
    BEGIN
        /* written already: undo all of it - at top level with ROLLBACK, nested by failing the caller's transaction */
        IF @Tc = 0 BEGIN ROLLBACK; RAISERROR(@Moment, 16, 1); RETURN 1; END;
        THROW 50000, @Moment, 1;
    END

    /* THE APPROVAL TAKES EFFECT HERE for the types whose figure is final before the engine is called: the roster
       month (no typed decide) and the exit permission (its decide stamps the minutes first). The other typed types
       apply their own effects after this call. ApplyApprovalEffects is idempotent, emits no rowset and does no
       INSERT...EXEC, so it is safe under the INSERT...EXEC the callers wrap this procedure in. */
    IF @NextStep IS NULL AND @TypeCode IN ('ROSTER_APPROVAL', 'EXIT_PERMISSION')
        EXEC workflow.usp_Request_ApplyApprovalEffects
             @RequestInstanceId = @RequestInstanceId, @ActorUserId = @ActedByUserId;

    COMMIT TRAN;

    SELECT RequestInstanceId, [Status], CurrentStepNo, ClosedReason,
           @DecisionKind AS Decision, @SignedAsDeputy AS SignedAsDeputy,
           @SignedWithPassword AS SignedWithPassword
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId=@RequestInstanceId;
    RETURN 0;
END;
GO

/* ============================================================================
   7. Retract: the last signer takes their decision back the same Beirut day
      (script 84's body; WF-1, WF-2, WF-4, WF-5, WF-6, WF-8, WF-13, WF-15)
   ============================================================================ */
CREATE OR ALTER PROCEDURE [workflow].[usp_Request_RetractLastDecision]
    @RequestInstanceId  INT,
    @ActedByUserId      INT,
    @Reason             NVARCHAR(300),
    @SignedWithPassword BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    DECLARE @Tc INT = @@TRANCOUNT, @Rows INT, @Msg NVARCHAR(400);
    DECLARE @Moment NVARCHAR(200) = N'This step was decided a moment ago ' + NCHAR(8212) + N' reload.';

    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason))=''
    BEGIN RAISERROR('A reason is required to retract a decision.',16,1); RETURN 1; END

    BEGIN TRAN;

    DECLARE @ReqStatus VARCHAR(20);
    SELECT @ReqStatus = [Status] FROM workflow.REQUEST_INSTANCE WITH (UPDLOCK, ROWLOCK)
    WHERE RequestInstanceId = @RequestInstanceId;
    IF @ReqStatus IS NULL BEGIN COMMIT; RAISERROR('Request not found.', 16, 1); RETURN 1; END

    /* WF-5: a retract takes back the decision that CLOSED the request - approved or rejected. A request still open
       is changed by withdrawing a decision; a cancelled one has no decision to take back. */
    IF @ReqStatus = 'Cancelled'
    BEGIN COMMIT; RAISERROR('This request was cancelled - there is no decision to retract. HR can reopen a cancelled request.', 16, 1); RETURN 1; END
    IF @ReqStatus NOT IN ('Approved', 'Rejected')
    BEGIN COMMIT; RAISERROR('This request is still open - use Change decision to take back your own decision on it.', 16, 1); RETURN 1; END

    DECLARE @SigId INT,@SigUser INT,@SigAt DATETIME2,@StepNo INT,@WasSigned BIT;
    /* StepNo IS NOT NULL excludes the 'Submitted' row: a submission is not a decision */
    SELECT TOP 1 @SigId=SignatureId,@SigUser=ActedByUserId,
                 @SigAt=ActedAt,@StepNo=StepNo,@WasSigned=ISNULL(SignedWithPassword,0)
    FROM workflow.WORKFLOW_SIGNATURE
    WHERE RequestInstanceId=@RequestInstanceId AND RetractedAt IS NULL
      AND StepNo IS NOT NULL AND [Action] IN ('Approved','Rejected')
    ORDER BY ActedAt DESC, SignatureId DESC;
    IF @SigId IS NULL BEGIN COMMIT; RAISERROR('There is no decision to retract.',16,1); RETURN 1; END
    IF @SigUser<>@ActedByUserId
    BEGIN COMMIT; RAISERROR('Only the person who signed the LAST decision may retract it, and only same-day. Later than that, reopening needs the GM and the Owner together.',16,1); RETURN 1; END
    /* WF-13: the same BEIRUT calendar day (ActedAt is UTC) */
    IF CAST(CAST(@SigAt AS DATETIMEOFFSET) AT TIME ZONE 'Middle East Standard Time' AS DATE)
       <> CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE)
    BEGIN COMMIT; RAISERROR('Same-day only: this decision is from an earlier day. Reopening now needs the GM and the Owner together.',16,1); RETURN 1; END

    /* the signature gate, fails closed like approve/reject/withdraw */
    DECLARE @NeedsSignature BIT =
        CASE WHEN @WasSigned = 1
               OR EXISTS (SELECT 1 FROM security.USER_ROLE ur
                          JOIN security.[ROLE] r ON r.RoleId = ur.RoleId
                          WHERE ur.UserId = @ActedByUserId AND r.RequiresSignaturePassword = 1)
             THEN 1 ELSE 0 END;
    IF @NeedsSignature = 1 AND @SignedWithPassword = 0
    BEGIN COMMIT; RAISERROR('Retracting this decision must be signed with your password.',16,1); RETURN 1; END

    /* what cannot be undone (the base rule, then the types and paid periods - WF-8), and what was raised since (WF-6) */
    SET @Msg = COALESCE(workflow.fn_ReversalBlockReason(@RequestInstanceId),
                        workflow.fn_ReversalUndoBlock(@RequestInstanceId),
                        workflow.fn_ReopenConflict(@RequestInstanceId));
    IF @Msg IS NOT NULL BEGIN COMMIT; RAISERROR(N'%s',16,1,@Msg); RETURN 1; END

    /* ---- writes ---- */
    IF @ReqStatus = 'Approved'
        EXEC workflow.usp_Reversal_UndoEffects @RequestInstanceId;
    EXEC workflow.usp_Request_RestoreFigure @RequestInstanceId = @RequestInstanceId, @StepNo = @StepNo;     -- WF-4

    UPDATE workflow.WORKFLOW_SIGNATURE
        SET RetractedAt=SYSUTCDATETIME(), RetractedReason=@Reason
        WHERE SignatureId=@SigId AND RetractedAt IS NULL;
    SET @Rows = @@ROWCOUNT;

    /* unsign the step (as usp_Request_WithdrawDecision does) */
    IF @Rows = 1
    BEGIN
        UPDATE workflow.REQUEST_STEP_INSTANCE
            SET [Status]='Pending', Decision=NULL,
                ActedByUserId=NULL, ActedAt=NULL, Comment=NULL, ValueBefore=NULL,
                SignedWithPassword=0,
                HoldReason=NULL, HoldSetAt=NULL, HoldSetByUserId=NULL, WaitingOnRequester=0
            WHERE RequestInstanceId=@RequestInstanceId AND StepNo=@StepNo AND [Status] IN ('Approved','Rejected');
        SET @Rows = @@ROWCOUNT;
    END
    IF @Rows = 1
    BEGIN
        UPDATE workflow.REQUEST_INSTANCE
            SET [Status]='Pending', CurrentStepNo=@StepNo,
                ClosedAt=NULL, ClosedReason=NULL
            WHERE RequestInstanceId=@RequestInstanceId AND [Status] = @ReqStatus;
        SET @Rows = @@ROWCOUNT;
    END
    IF @Rows <> 1
    BEGIN
        IF @Tc = 0 BEGIN ROLLBACK; RAISERROR(@Moment, 16, 1); RETURN 1; END;
        THROW 50000, @Moment, 1;
    END

    INSERT INTO workflow.REQUEST_REVERSAL
        (RequestInstanceId,Kind,Reason,FirstSignUserId,FirstSignRole,CompletedAt)
    VALUES (@RequestInstanceId,'Retract',@Reason,@ActedByUserId,N'Self',SYSUTCDATETIME());

    EXEC workflow.usp_Request_SupersedeOutbox @RequestInstanceId = @RequestInstanceId;       -- WF-15
    /* the days the approval touched follow the punches again, now that it no longer reads Approved */
    IF @ReqStatus = 'Approved'
        EXEC workflow.usp_Reversal_Rederive @RequestInstanceId = @RequestInstanceId;

    COMMIT TRAN;
    SELECT @RequestInstanceId AS RequestInstanceId,'Pending' AS [Status],@StepNo AS CurrentStepNo;
    RETURN 0;
END;
GO

/* ============================================================================
   8. Reopen: the General Manager and the Owner together, in either order
      (script 84's body; WF-1, WF-2, WF-4, WF-6, WF-8, WF-14, WF-15)
   ============================================================================ */
/* WF-14: two DIFFERENT people (the role of each is recorded), each half signed with the signer's password - the API
   verifies it and sets @SignedWithPassword; the procedure fails closed without it. Everything that would stop the
   second half (no standing decision, a block, a conflict) is checked at the FIRST half too, so a reopen can no longer
   be left half-signed with no way to finish it; the second half checks again, the world may have moved. */
CREATE OR ALTER PROCEDURE workflow.usp_Request_Reopen
    @RequestInstanceId  INT,
    @ActedByUserId      INT,
    @Reason             NVARCHAR(300),
    @SignedWithPassword BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    DECLARE @Tc INT = @@TRANCOUNT, @Rows INT, @Msg NVARCHAR(400);
    DECLARE @Moment NVARCHAR(200) = N'This step was decided a moment ago ' + NCHAR(8212) + N' reload.';

    /* BOTH spellings of the GM role */
    DECLARE @IsGm BIT=CASE WHEN payroll.fn_UserHasRole(@ActedByUserId,N'GeneralManager')=1
                             OR payroll.fn_UserHasRole(@ActedByUserId,N'General Manager')=1
                           THEN 1 ELSE 0 END;
    DECLARE @IsOwner BIT=payroll.fn_UserHasRole(@ActedByUserId,N'Owner');
    IF @IsGm=0 AND @IsOwner=0
    BEGIN RAISERROR('Reopening a closed request needs the General Manager and the Owner.',16,1); RETURN 1; END
    IF ISNULL(@SignedWithPassword, 0) = 0
    BEGIN RAISERROR('Reopening a closed request must be signed with your password.',16,1); RETURN 1; END

    BEGIN TRAN;

    DECLARE @ReqStatus VARCHAR(20);
    SELECT @ReqStatus = [Status] FROM workflow.REQUEST_INSTANCE WITH (UPDLOCK, ROWLOCK)
    WHERE RequestInstanceId = @RequestInstanceId;
    IF @ReqStatus IS NULL BEGIN COMMIT; RAISERROR('Request not found.', 16, 1); RETURN 1; END
    IF @ReqStatus = 'Cancelled'
    BEGIN COMMIT; RAISERROR('A cancelled request is reopened by HR (Reopen request), not by the GM and the Owner.',16,1); RETURN 1; END
    IF @ReqStatus NOT IN ('Approved','Rejected')
    BEGIN COMMIT; RAISERROR('Only a closed (approved or rejected) request can be reopened.',16,1); RETURN 1; END

    /* the decision a reopen strikes: the highest step whose decision still stands */
    DECLARE @LastStep INT=(SELECT MAX(s.StepNo) FROM workflow.WORKFLOW_SIGNATURE s
        WHERE s.RequestInstanceId=@RequestInstanceId AND s.RetractedAt IS NULL
          AND s.StepNo IS NOT NULL AND s.[Action] IN ('Approved','Rejected'));
    IF @LastStep IS NULL
    BEGIN COMMIT; RAISERROR('There is no decision to reverse on this request - it closed without anybody signing (approved automatically).',16,1); RETURN 1; END

    SET @Msg = COALESCE(workflow.fn_ReversalBlockReason(@RequestInstanceId),
                        workflow.fn_ReversalUndoBlock(@RequestInstanceId),
                        workflow.fn_ReopenConflict(@RequestInstanceId));
    IF @Msg IS NOT NULL BEGIN COMMIT; RAISERROR(N'%s',16,1,@Msg); RETURN 1; END

    DECLARE @Role NVARCHAR(30)=IIF(@IsOwner=1,N'Owner',N'GeneralManager');
    DECLARE @Open INT, @FirstUser INT, @FirstRole NVARCHAR(30);
    SELECT TOP 1 @Open = ReversalId, @FirstUser = FirstSignUserId, @FirstRole = FirstSignRole
    FROM workflow.REQUEST_REVERSAL WITH (UPDLOCK, ROWLOCK)
    WHERE RequestInstanceId=@RequestInstanceId AND Kind='Reopen' AND CompletedAt IS NULL
    ORDER BY ReversalId DESC;

    IF @Open IS NULL
    BEGIN
        IF @Reason IS NULL OR LTRIM(RTRIM(@Reason))=''
        BEGIN COMMIT; RAISERROR('A reason is required to reopen.',16,1); RETURN 1; END
        INSERT INTO workflow.REQUEST_REVERSAL
            (RequestInstanceId,Kind,Reason,FirstSignUserId,FirstSignRole)
        VALUES (@RequestInstanceId,'Reopen',@Reason,@ActedByUserId,@Role);
        COMMIT TRAN;
        SELECT 'AwaitingSecond' AS [State], @Role AS FirstSignRole;
        RETURN 0;
    END

    /* WF-14: the second signature is somebody else's, in the other role */
    IF @FirstUser = @ActedByUserId
    BEGIN COMMIT; RAISERROR('You already signed this reopen - the other of the General Manager and the Owner must countersign it.',16,1); RETURN 1; END
    IF @FirstRole = @Role
    BEGIN COMMIT; RAISERROR('This role already signed the reopen - the OTHER of GM/Owner must sign.',16,1); RETURN 1; END

    /* ---- writes ---- */
    IF @ReqStatus = 'Approved'
        EXEC workflow.usp_Reversal_UndoEffects @RequestInstanceId;
    EXEC workflow.usp_Request_RestoreFigure @RequestInstanceId = @RequestInstanceId, @StepNo = @LastStep;   -- WF-4

    UPDATE workflow.WORKFLOW_SIGNATURE
        SET RetractedAt=SYSUTCDATETIME(),
            RetractedReason=N'Reopened by GM + Owner'
        WHERE RequestInstanceId=@RequestInstanceId AND StepNo=@LastStep AND RetractedAt IS NULL
          AND [Action] IN ('Approved','Rejected');

    /* unsign the step the struck signature belonged to */
    UPDATE workflow.REQUEST_STEP_INSTANCE
        SET [Status]='Pending', Decision=NULL,
            ActedByUserId=NULL, ActedAt=NULL, Comment=NULL, ValueBefore=NULL,
            SignedWithPassword=0,
            HoldReason=NULL, HoldSetAt=NULL, HoldSetByUserId=NULL, WaitingOnRequester=0
        WHERE RequestInstanceId=@RequestInstanceId AND StepNo=@LastStep AND [Status] IN ('Approved','Rejected');
    SET @Rows = @@ROWCOUNT;

    IF @Rows = 1
    BEGIN
        UPDATE workflow.REQUEST_REVERSAL
            SET SecondSignUserId=@ActedByUserId, SecondSignRole=@Role, CompletedAt=SYSUTCDATETIME()
            WHERE ReversalId=@Open AND CompletedAt IS NULL;
        SET @Rows = @@ROWCOUNT;
    END
    IF @Rows = 1
    BEGIN
        UPDATE workflow.REQUEST_INSTANCE
            SET [Status]='Pending', CurrentStepNo=@LastStep,
                ClosedAt=NULL, ClosedReason=NULL
            WHERE RequestInstanceId=@RequestInstanceId AND [Status] = @ReqStatus;
        SET @Rows = @@ROWCOUNT;
    END
    IF @Rows <> 1
    BEGIN
        IF @Tc = 0 BEGIN ROLLBACK; RAISERROR(@Moment, 16, 1); RETURN 1; END;
        THROW 50000, @Moment, 1;
    END

    EXEC workflow.usp_Request_SupersedeOutbox @RequestInstanceId = @RequestInstanceId;       -- WF-15
    IF @ReqStatus = 'Approved'
        EXEC workflow.usp_Reversal_Rederive @RequestInstanceId = @RequestInstanceId;

    COMMIT TRAN;
    SELECT @RequestInstanceId AS RequestInstanceId,'Pending' AS [Status],@LastStep AS CurrentStepNo;
    RETURN 0;
END;
GO

/* ============================================================================
   9. HR's reopen: a CANCELLED request back in flight (WF-14, WF-6, WF-2)
   ============================================================================ */
/* Stale-copy guard (CON-7): the API passes RequestInstanceId, ActedByUserId, Reason and reads RequestInstanceId,
   Status, CurrentStepNo - as workflow_withdraw_decision.sql did. A live version with more parameters stops here. */
DECLARE @Unknown NVARCHAR(128) = (SELECT TOP 1 p.name FROM sys.parameters p
    WHERE p.object_id = OBJECT_ID('workflow.usp_Request_ReopenClosed')
      AND p.name NOT IN ('@RequestInstanceId', '@ActedByUserId', '@Reason'));
IF @Unknown IS NOT NULL
    RAISERROR('101_qa3_workflow.sql: the live workflow.usp_Request_ReopenClosed has a parameter this script does not know (%s) - it is newer than the repository copy. Re-base the QA3 fix on it before applying.', 16, 1, @Unknown);
GO
/* HR (WORKFLOW_VERSION_MOVE in the API) puts a CANCELLED request back at the first step still waiting. A rejected or
   approved request has decisions that stand: the last signer retracts it the same day, after that the General Manager
   and the Owner reopen it together (usp_Request_Reopen). Nothing is unsigned here - a cancellation is not a decision,
   and an advisory rejection recorded before it still stands. */
CREATE OR ALTER PROCEDURE workflow.usp_Request_ReopenClosed
    @RequestInstanceId INT,
    @ActedByUserId     INT,
    @Reason            NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Tc INT = @@TRANCOUNT, @Rows INT, @Msg NVARCHAR(400);
    DECLARE @Moment NVARCHAR(200) = N'This step was decided a moment ago ' + NCHAR(8212) + N' reload.';

    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = ''
    BEGIN RAISERROR('A reason is required to reopen a closed request.', 16, 1); RETURN 1; END

    BEGIN TRAN;

    DECLARE @ReqStatus VARCHAR(20);
    SELECT @ReqStatus = [Status] FROM workflow.REQUEST_INSTANCE WITH (UPDLOCK, ROWLOCK)
    WHERE RequestInstanceId = @RequestInstanceId;

    IF @ReqStatus IS NULL
    BEGIN COMMIT; RAISERROR('Request not found.', 16, 1); RETURN 1; END
    IF @ReqStatus = 'Approved'
    BEGIN
        COMMIT;
        RAISERROR('An approved request is not reopened here - its result has been applied. The last signer can retract it the same day; after that the General Manager and the Owner reopen it together.', 16, 1);
        RETURN 1;
    END
    IF @ReqStatus = 'Rejected'
    BEGIN
        COMMIT;
        RAISERROR('A rejected request is reopened by the General Manager and the Owner together (or retracted the same day by whoever rejected it), not by HR alone.', 16, 1);
        RETURN 1;
    END
    IF @ReqStatus <> 'Cancelled'
    BEGIN COMMIT; RAISERROR('Only a cancelled request can be reopened here.', 16, 1); RETURN 1; END

    /* WF-6: what was raised since the cancellation */
    SET @Msg = workflow.fn_ReopenConflict(@RequestInstanceId);
    IF @Msg IS NOT NULL BEGIN COMMIT; RAISERROR(N'%s', 16, 1, @Msg); RETURN 1; END

    /* back to the first step still waiting, with its hold if it had one */
    DECLARE @NextStep INT, @NextStatus VARCHAR(20);
    SELECT TOP 1 @NextStep = StepNo, @NextStatus = [Status]
    FROM workflow.REQUEST_STEP_INSTANCE
    WHERE RequestInstanceId = @RequestInstanceId AND [Status] IN ('Pending','OnHold')
    ORDER BY StepNo;
    IF @NextStep IS NULL
    BEGIN COMMIT; RAISERROR('Nothing is left to sign on this request - raise a new one instead.', 16, 1); RETURN 1; END

    UPDATE workflow.REQUEST_INSTANCE
    SET [Status] = CASE WHEN @NextStatus = 'OnHold' THEN 'OnHold' ELSE 'Pending' END,
        CurrentStepNo = @NextStep, ClosedAt = NULL, ClosedReason = NULL
    WHERE RequestInstanceId = @RequestInstanceId AND [Status] = 'Cancelled';
    IF @@ROWCOUNT <> 1 BEGIN COMMIT; RAISERROR(@Moment, 16, 1); RETURN 1; END      -- nothing written yet

    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    VALUES (@RequestInstanceId, NULL, 'Reopened', @ActedByUserId, LEFT(@Reason, 300));

    EXEC workflow.usp_Request_SupersedeOutbox @RequestInstanceId = @RequestInstanceId;       -- WF-15

    COMMIT TRAN;

    SELECT RequestInstanceId, [Status], CurrentStepNo
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;
    RETURN 0;
END;
GO

/* ============================================================================
   10. Withdrawing your own decision while the request is open (WF-2, WF-4 / LEV-7)
   ============================================================================ */
/* Stale-copy guard (CON-7): the API passes RequestInstanceId, StepNo, ActedByUserId, Reason, SignedWithPassword and
   reads RequestInstanceId, Status, CurrentStepNo - as workflow_rollback_signature.sql did. */
DECLARE @Unknown NVARCHAR(128) = (SELECT TOP 1 p.name FROM sys.parameters p
    WHERE p.object_id = OBJECT_ID('workflow.usp_Request_WithdrawDecision')
      AND p.name NOT IN ('@RequestInstanceId', '@StepNo', '@ActedByUserId', '@Reason', '@SignedWithPassword'));
IF @Unknown IS NOT NULL
    RAISERROR('101_qa3_workflow.sql: the live workflow.usp_Request_WithdrawDecision has a parameter this script does not know (%s) - it is newer than the repository copy. Re-base the QA3 fix on it before applying.', 16, 1, @Unknown);
GO
/* The rules on WHO and WHEN are unchanged: your own decision, request still open, nobody after you has acted; a signed
   decision needs a signed withdrawal. New: the read happens under the request's lock (WF-2), and the figure the
   withdrawn decision changed is put back (usp_Request_RestoreFigure - every type, not only exit permissions: WF-4).
   Runs under INSERT...EXEC (usp_ExitPermission_WithdrawDecision), so a refusal never ROLLBACKs. */
CREATE OR ALTER PROCEDURE workflow.usp_Request_WithdrawDecision
    @RequestInstanceId  INT,
    @StepNo             INT,
    @ActedByUserId      INT,
    @Reason             NVARCHAR(500),
    @SignedWithPassword BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Tc INT = @@TRANCOUNT, @Rows INT;
    DECLARE @Moment NVARCHAR(200) = N'This step was decided a moment ago ' + NCHAR(8212) + N' reload.';

    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = ''
    BEGIN RAISERROR('Say why you are withdrawing. The original decision stays on the record, so the reason is what explains it.', 16, 1); RETURN 1; END

    BEGIN TRAN;

    DECLARE @ReqStatus VARCHAR(20), @DefId INT;
    SELECT @ReqStatus = [Status], @DefId = WorkflowDefinitionId
    FROM workflow.REQUEST_INSTANCE WITH (UPDLOCK, ROWLOCK) WHERE RequestInstanceId = @RequestInstanceId;

    IF @ReqStatus IS NULL
    BEGIN COMMIT; RAISERROR('Request not found.', 16, 1); RETURN 1; END

    IF @ReqStatus NOT IN ('Pending', 'OnHold')
    BEGIN
        COMMIT;
        RAISERROR('This request is closed. The last signer can retract the decision that closed it the same day; after that the General Manager and the Owner reopen it together, and HR reopens a cancelled one.', 16, 1);
        RETURN 1;
    END

    DECLARE @StepInstId INT, @StepStatus VARCHAR(20), @Signer INT, @WasSigned BIT;
    SELECT @StepInstId = RequestStepInstanceId, @StepStatus = [Status],
           @Signer = ActedByUserId, @WasSigned = ISNULL(SignedWithPassword, 0)
    FROM workflow.REQUEST_STEP_INSTANCE WITH (UPDLOCK, ROWLOCK)
    WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @StepNo;

    IF @StepInstId IS NULL
    BEGIN COMMIT; RAISERROR('That step does not exist on this request.', 16, 1); RETURN 1; END

    IF @StepStatus NOT IN ('Approved', 'Rejected')
    BEGIN COMMIT; RAISERROR('There is no decision on that step to withdraw.', 16, 1); RETURN 1; END

    IF @Signer IS NULL OR @Signer <> @ActedByUserId
    BEGIN COMMIT; RAISERROR('You can only withdraw a decision you made yourself.', 16, 1); RETURN 1; END

    DECLARE @LaterActor NVARCHAR(150) = (
        SELECT TOP 1 CONCAT(si.Name, N' (', ISNULL(u.Username, N'the engine'), N')')
        FROM workflow.REQUEST_STEP_INSTANCE si
        LEFT JOIN security.[USER] u ON u.UserId = si.ActedByUserId
        WHERE si.RequestInstanceId = @RequestInstanceId
          AND si.StepNo > @StepNo AND si.ActedAt IS NOT NULL
        ORDER BY si.StepNo);

    IF @LaterActor IS NOT NULL
    BEGIN
        COMMIT;
        RAISERROR('%s has already acted on this request, so your decision can no longer be withdrawn. Raise a new request instead.', 16, 1, @LaterActor);
        RETURN 1;
    END

    /* --- THE SIGNATURE GATE. Fails closed, exactly like approve and reject. --- */
    DECLARE @NeedsSignature BIT =
        CASE WHEN @WasSigned = 1                                   -- undoing a signed act
               OR ISNULL((SELECT RequiresSignature FROM workflow.WORKFLOW_STEP
                          WHERE WorkflowDefinitionId = @DefId AND StepNo = @StepNo), 0) = 1
               OR EXISTS (SELECT 1 FROM security.USER_ROLE ur
                          JOIN security.[ROLE] r ON r.RoleId = ur.RoleId
                          WHERE ur.UserId = @ActedByUserId AND r.RequiresSignaturePassword = 1)
             THEN 1 ELSE 0 END;

    IF @NeedsSignature = 1 AND @SignedWithPassword = 0
    BEGIN COMMIT; RAISERROR('Withdrawing this decision must be signed with your password.', 16, 1); RETURN 1; END

    DECLARE @WasDecision VARCHAR(25) = (SELECT Decision FROM workflow.REQUEST_STEP_INSTANCE
                                        WHERE RequestStepInstanceId = @StepInstId);

    /* ---- writes: the figure first (unsigning clears ValueBefore), then the step ---- */
    EXEC workflow.usp_Request_RestoreFigure @RequestInstanceId = @RequestInstanceId, @StepNo = @StepNo;

    UPDATE workflow.REQUEST_STEP_INSTANCE
    SET [Status] = 'Pending', Decision = NULL,
        ActedByUserId = NULL, ActedAt = NULL, Comment = NULL, ValueBefore = NULL,
        SignedWithPassword = 0,
        HoldReason = NULL, HoldSetAt = NULL, HoldSetByUserId = NULL, WaitingOnRequester = 0
    WHERE RequestStepInstanceId = @StepInstId AND [Status] IN ('Approved', 'Rejected') AND ActedByUserId = @ActedByUserId;
    SET @Rows = @@ROWCOUNT;

    IF @Rows = 1
    BEGIN
        INSERT INTO workflow.WORKFLOW_SIGNATURE
            (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment, SignedWithPassword)
        VALUES (@RequestInstanceId, @StepNo, 'Withdrawn', @ActedByUserId,
                LEFT(CONCAT(N'Withdrew their ', LOWER(ISNULL(@WasDecision, 'decision')), N'. ', @Reason), 300),
                @SignedWithPassword);

        DECLARE @NextStep INT = (SELECT MIN(StepNo) FROM workflow.REQUEST_STEP_INSTANCE
                                 WHERE RequestInstanceId = @RequestInstanceId
                                   AND [Status] IN ('Pending','OnHold'));

        UPDATE workflow.REQUEST_INSTANCE
        SET [Status] = 'Pending', CurrentStepNo = @NextStep,
            ClosedAt = NULL, ClosedReason = NULL
        WHERE RequestInstanceId = @RequestInstanceId AND [Status] IN ('Pending', 'OnHold');
        SET @Rows = @@ROWCOUNT;
    END
    IF @Rows <> 1
    BEGIN
        IF @Tc = 0 BEGIN ROLLBACK; RAISERROR(@Moment, 16, 1); RETURN 1; END;
        THROW 50000, @Moment, 1;
    END

    COMMIT TRAN;

    SELECT RequestInstanceId, [Status], CurrentStepNo
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;
    RETURN 0;
END;
GO

/* ============================================================================
   11. The exit-permission withdrawal (CON-1)
   ============================================================================ */
/* Stale-copy guard (CON-7): the API passes RequestInstanceId, StepNo, ActedByUserId, Reason, SignedWithPassword and
   reads ExitPermissionId, RequestedMinutes, ApprovedMinutes, Status, CurrentStepNo - as workflow_rollback_signature.sql did. */
DECLARE @Unknown NVARCHAR(128) = (SELECT TOP 1 p.name FROM sys.parameters p
    WHERE p.object_id = OBJECT_ID('workflow.usp_ExitPermission_WithdrawDecision')
      AND p.name NOT IN ('@RequestInstanceId', '@StepNo', '@ActedByUserId', '@Reason', '@SignedWithPassword'));
IF @Unknown IS NOT NULL
    RAISERROR('101_qa3_workflow.sql: the live workflow.usp_ExitPermission_WithdrawDecision has a parameter this script does not know (%s) - it is newer than the repository copy. Re-base the QA3 fix on it before applying.', 16, 1, @Unknown);
GO
/* CON-1: it used to put the minutes back FIRST, then call the engine with a plain EXEC and COMMIT whatever happened -
   the engine refuses with RAISERROR + RETURN, which does not roll anything back, so a refused withdrawal still
   committed the restored minutes; and the engine's own row came back as the first result set. Now the engine is
   captured with INSERT...EXEC (no row = it refused and nothing was done), and it restores the minutes itself, under
   its lock, only once it has accepted the withdrawal. One result set: the permission as it now stands. */
CREATE OR ALTER PROCEDURE workflow.usp_ExitPermission_WithdrawDecision
    @RequestInstanceId  INT,
    @StepNo             INT,
    @ActedByUserId      INT,
    @Reason             NVARCHAR(500),
    @SignedWithPassword BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Tc INT = @@TRANCOUNT;
    IF NOT EXISTS (SELECT 1 FROM workflow.EXIT_PERMISSION WHERE RequestInstanceId = @RequestInstanceId)
    BEGIN RAISERROR('This is not an exit permission.', 16, 1); RETURN 1; END

    DECLARE @Engine TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT);

    BEGIN TRAN;
    BEGIN TRY
        INSERT INTO @Engine (RequestInstanceId, [Status], CurrentStepNo)
        EXEC workflow.usp_Request_WithdrawDecision
             @RequestInstanceId  = @RequestInstanceId,
             @StepNo             = @StepNo,
             @ActedByUserId      = @ActedByUserId,
             @Reason             = @Reason,
             @SignedWithPassword = @SignedWithPassword;
    END TRY
    BEGIN CATCH
        /* the engine refused (it wrote nothing) or failed: at top level roll this transaction back; nested, a usable
           transaction gets this level closed and a doomed one is left to the caller (ROLLBACK is not allowed under
           INSERT...EXEC) - then the engine's sentence goes on, unchanged */
        IF @Tc = 0 AND @@TRANCOUNT > 0 ROLLBACK;
        ELSE IF XACT_STATE() = 1 AND @@TRANCOUNT > @Tc COMMIT;
        THROW;
    END CATCH

    IF NOT EXISTS (SELECT 1 FROM @Engine)
    BEGIN
        /* the engine refused (its sentence is already on its way to the caller) and wrote nothing */
        IF @Tc = 0 ROLLBACK; ELSE COMMIT;
        RETURN 1;
    END
    COMMIT TRAN;

    SELECT ep.ExitPermissionId, ep.RequestedMinutes, ep.ApprovedMinutes,
           r.[Status], r.CurrentStepNo
    FROM workflow.EXIT_PERMISSION ep
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
    WHERE ep.RequestInstanceId = @RequestInstanceId;
    RETURN 0;
END;
GO

/* ============================================================================
   12. Version moves (WF-10, WF-9, WF-2)
   ============================================================================ */
/* Stale-copy guard (CON-7): the API passes RequestTypeId and reads the fourteen columns below - as workflow_core.sql
   did. */
DECLARE @Unknown NVARCHAR(128) = (SELECT TOP 1 p.name FROM sys.parameters p
    WHERE p.object_id = OBJECT_ID('workflow.usp_Request_GetOnOldVersions')
      AND p.name NOT IN ('@RequestTypeId'));
IF @Unknown IS NOT NULL
    RAISERROR('101_qa3_workflow.sql: the live workflow.usp_Request_GetOnOldVersions has a parameter this script does not know (%s) - it is newer than the repository copy. Re-base the QA3 fix on it before applying.', 16, 1, @Unknown);
GO
/* Pending requests whose chain is no longer the ACTIVE one OF THEIR OWN POPULATION. Two chains of one type can be active
   at once (the default one and a management / executive one, MinRequesterTier); a request on the active default chain
   used to be listed as "old" because the management chain is active too, and moving it put a staff request on the
   management chain (WF-10). The population is the one the request's chain serves. */
CREATE OR ALTER PROCEDURE workflow.usp_Request_GetOnOldVersions
    @RequestTypeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        r.RequestInstanceId,
        rt.Code AS RequestTypeCode, rt.Name AS RequestTypeName,
        r.EmployeeId, e.FullName AS EmployeeName, b.Name AS BranchName,
        r.Title, r.SubmittedAt,
        r.CurrentStepNo, si.Name AS CurrentStepName,
        cur.[Version]    AS CurrentVersion,
        act.[Version]    AS ActiveVersion,
        act.WorkflowDefinitionId AS ActiveWorkflowDefinitionId,
        DATEDIFF(DAY, r.SubmittedAt, SYSUTCDATETIME()) AS DaysWaiting
    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.REQUEST_TYPE rt          ON rt.RequestTypeId = r.RequestTypeId
    JOIN workflow.WORKFLOW_DEFINITION cur  ON cur.WorkflowDefinitionId = r.WorkflowDefinitionId
    CROSS APPLY (SELECT TOP 1 a.WorkflowDefinitionId, a.[Version]
                 FROM workflow.WORKFLOW_DEFINITION a
                 WHERE a.RequestTypeId = r.RequestTypeId AND a.[Status] = 'Active'
                   AND ((a.MinRequesterTier IS NULL AND cur.MinRequesterTier IS NULL) OR a.MinRequesterTier = cur.MinRequesterTier)
                 ORDER BY a.[Version] DESC) act
    JOIN hr.EMPLOYEE e                     ON e.EmployeeId = r.EmployeeId
    JOIN hr.BRANCH b                       ON b.BranchId = e.BranchId
    LEFT JOIN workflow.REQUEST_STEP_INSTANCE si
           ON si.RequestInstanceId = r.RequestInstanceId AND si.StepNo = r.CurrentStepNo
    WHERE r.[Status] = 'Pending'
      AND r.WorkflowDefinitionId <> act.WorkflowDefinitionId
      AND (@RequestTypeId IS NULL OR r.RequestTypeId = @RequestTypeId)
    ORDER BY rt.Name, r.SubmittedAt;
END;
GO

/* The move keeps the version a request started on in REQUEST_INSTANCE.OriginalWorkflowDefinitionId, a column only the
   unnumbered workflow_core.sql creates. Added here (nullable) when the live table lacks it, so the procedure below
   compiles there too: SQL Server refuses a procedure naming a column its table does not have. */
IF COL_LENGTH('workflow.REQUEST_INSTANCE', 'OriginalWorkflowDefinitionId') IS NULL
BEGIN
    ALTER TABLE workflow.REQUEST_INSTANCE ADD OriginalWorkflowDefinitionId INT NULL;
    PRINT 'QA3 WF-10: workflow.REQUEST_INSTANCE.OriginalWorkflowDefinitionId added (the version a request started on)';
END
GO

/* Stale-copy guard (CON-7): the API passes RequestInstanceId, TargetWorkflowDefinitionId, ActedByUserId, Reason (and now
   ConfirmClose) and reads RequestInstanceId, Status, CurrentStepNo, MovedFromVersion, MovedToVersion, VersionMovedAt,
   VersionMovedBy - as workflow_core.sql did. */
DECLARE @Unknown NVARCHAR(128) = (SELECT TOP 1 p.name FROM sys.parameters p
    WHERE p.object_id = OBJECT_ID('workflow.usp_Request_MoveToVersion')
      AND p.name NOT IN ('@RequestInstanceId', '@TargetWorkflowDefinitionId', '@ActedByUserId', '@Reason', '@ConfirmClose'));
IF @Unknown IS NOT NULL
    RAISERROR('101_qa3_workflow.sql: the live workflow.usp_Request_MoveToVersion has a parameter this script does not know (%s) - it is newer than the repository copy. Re-base the QA3 fix on it before applying.', 16, 1, @Unknown);
GO
/* MOVE ONE PENDING REQUEST ONTO A NEWER VERSION OF ITS CHAIN. HR-triggered, never automatic. The rules:
     1. The target is an ACTIVE version of the same type serving the SAME population (MinRequesterTier) as the chain
        the request is on - a version move is a newer edition of the same chain, never another population's (WF-10).
     2. Steps already acted on (Approved / Rejected / Skipped) are untouchable.
     3. The rest is rebuilt BY POSITION: the request has passed k positions (its steps before the one it waits on); the
        target's first k steps are positions already passed and are DROPPED - each logged as Skipped with the reason,
        never run retroactively; the target's later steps are added with their own numbers, approvers resolved now
        (nobody approves their own request; an unresolvable non-role step is skipped and logged), with the deputy role
        and the step flags copied from the target chain (WF-10).
     4. A move that would leave nothing to sign approves the request - refused unless @ConfirmClose = 1, and then the
        approval's effects are applied (WF-9).
   Approvers are resolved with workflow.fn_ResolveApprover called with WHATEVER parameters it has (the live function may
   be newer than the repository's three-parameter copy), each fed from the target step by name. */
CREATE OR ALTER PROCEDURE workflow.usp_Request_MoveToVersion
    @RequestInstanceId          INT,
    @TargetWorkflowDefinitionId INT = NULL,   -- NULL = the active version of the request's own chain
    @ActedByUserId              INT,
    @Reason                     NVARCHAR(300),
    @ConfirmClose               BIT = 0       -- WF-10: yes, approve it if the new chain leaves nothing to sign
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Tc INT = @@TRANCOUNT, @Rows INT, @Msg NVARCHAR(400);
    DECLARE @Moment NVARCHAR(200) = N'This step was decided a moment ago ' + NCHAR(8212) + N' reload.';

    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = ''
    BEGIN RAISERROR('A reason is required when moving a request to another workflow version.', 16, 1); RETURN 1; END

    BEGIN TRAN;

    DECLARE @TypeId INT, @EmployeeId INT, @CurDefId INT, @ReqStatus VARCHAR(20), @CurStep INT;
    SELECT @TypeId = RequestTypeId, @EmployeeId = EmployeeId,
           @CurDefId = WorkflowDefinitionId, @ReqStatus = [Status], @CurStep = CurrentStepNo
    FROM workflow.REQUEST_INSTANCE WITH (UPDLOCK, ROWLOCK) WHERE RequestInstanceId = @RequestInstanceId;

    IF @ReqStatus IS NULL
    BEGIN COMMIT; RAISERROR('Request not found.', 16, 1); RETURN 1; END
    IF @ReqStatus <> 'Pending'
    BEGIN COMMIT; RAISERROR('Only a pending request can be moved to another version.', 16, 1); RETURN 1; END

    DECLARE @CurTier INT = (SELECT MinRequesterTier FROM workflow.WORKFLOW_DEFINITION WHERE WorkflowDefinitionId = @CurDefId);

    /* default target = the active version of the request's own chain (same population) */
    IF @TargetWorkflowDefinitionId IS NULL
        SELECT TOP 1 @TargetWorkflowDefinitionId = WorkflowDefinitionId
        FROM workflow.WORKFLOW_DEFINITION
        WHERE RequestTypeId = @TypeId AND [Status] = 'Active'
          AND ((MinRequesterTier IS NULL AND @CurTier IS NULL) OR MinRequesterTier = @CurTier)
        ORDER BY [Version] DESC;

    IF @TargetWorkflowDefinitionId IS NULL
    BEGIN COMMIT; RAISERROR('No active workflow version to move to.', 16, 1); RETURN 1; END

    IF @TargetWorkflowDefinitionId = @CurDefId
    BEGIN COMMIT; RAISERROR('The request is already on that version.', 16, 1); RETURN 1; END

    DECLARE @TgtType INT, @TgtStatus VARCHAR(20), @TgtTier INT, @ToVer INT;
    SELECT @TgtType = RequestTypeId, @TgtStatus = [Status], @TgtTier = MinRequesterTier, @ToVer = [Version]
    FROM workflow.WORKFLOW_DEFINITION WHERE WorkflowDefinitionId = @TargetWorkflowDefinitionId;

    IF @TgtType IS NULL OR @TgtType <> @TypeId
    BEGIN COMMIT; RAISERROR('That version belongs to a different request type.', 16, 1); RETURN 1; END
    IF @TgtStatus <> 'Active'
    BEGIN COMMIT; RAISERROR('A request can only be moved onto the active version of its chain.', 16, 1); RETURN 1; END
    IF ISNULL(@TgtTier, -1) <> ISNULL(@CurTier, -1)
    BEGIN
        COMMIT;
        RAISERROR('That version serves a different population of requesters (another tier) - a request only moves to a newer version of its own chain.', 16, 1);
        RETURN 1;
    END

    DECLARE @RequesterUserId INT = (SELECT UserId FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId);
    DECLARE @FromVer INT = (SELECT [Version] FROM workflow.WORKFLOW_DEFINITION WHERE WorkflowDefinitionId = @CurDefId);

    /* how far the request has got: the steps BEFORE the one it is waiting on (all acted on or skipped), their last
       number, and how many positions that is. A step skipped at submit AFTER the current one has not been passed. */
    IF @CurStep IS NULL
        SET @CurStep = ISNULL((SELECT MIN(StepNo) FROM workflow.REQUEST_STEP_INSTANCE
                               WHERE RequestInstanceId = @RequestInstanceId AND [Status] IN ('Pending', 'OnHold')),
                              ISNULL((SELECT MAX(StepNo) FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @RequestInstanceId), 0) + 1);
    DECLARE @HighestDone INT = ISNULL((SELECT MAX(StepNo) FROM workflow.REQUEST_STEP_INSTANCE
                                       WHERE RequestInstanceId = @RequestInstanceId AND StepNo < @CurStep), 0);
    DECLARE @Passed INT = (SELECT COUNT(*) FROM workflow.REQUEST_STEP_INSTANCE
                           WHERE RequestInstanceId = @RequestInstanceId AND StepNo < @CurStep);

    /* the target chain by position: kept (after the point reached) or dropped (already passed) */
    IF OBJECT_ID('tempdb..#mv') IS NOT NULL DROP TABLE #mv;
    CREATE TABLE #mv (StepNo INT PRIMARY KEY, Pos INT, Name NVARCHAR(80), ApproverType VARCHAR(20), ApproverRoleId INT,
                      ApproverUserId INT, FallbackRoleId INT, Keep BIT, ResolvedUserId INT NULL,
                      [Status] VARCHAR(20) NULL, SkipReason NVARCHAR(200) NULL);
    INSERT INTO #mv (StepNo, Pos, Name, ApproverType, ApproverRoleId, ApproverUserId, FallbackRoleId, Keep)
    SELECT s.StepNo, ROW_NUMBER() OVER (ORDER BY s.StepNo), s.Name, s.ApproverType, s.ApproverRoleId, s.ApproverUserId,
           s.FallbackRoleId, 0
    FROM workflow.WORKFLOW_STEP s WHERE s.WorkflowDefinitionId = @TargetWorkflowDefinitionId;
    UPDATE m SET Keep = 1
    FROM #mv m
    WHERE m.Pos > @Passed AND m.StepNo > @HighestDone
      /* never on top of a decision that stays (none is expected after the current step) */
      AND NOT EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE si
                      WHERE si.RequestInstanceId = @RequestInstanceId AND si.StepNo = m.StepNo AND si.[Status] IN ('Approved', 'Rejected'));

    /* resolve the kept steps' approvers with the live function's own parameter list */
    DECLARE @Args NVARCHAR(MAX) = (
        SELECT STRING_AGG(CAST(CASE
                 WHEN p.name LIKE '%ApproverType%' THEN 's.ApproverType'
                 WHEN p.name LIKE '%Employee%' THEN '@Emp'
                 WHEN p.name LIKE '%RoleId%' THEN 's.ApproverRoleId'
                 WHEN p.name LIKE '%UserId%' THEN 's.ApproverUserId'
                 WHEN (p.name LIKE '%Escalation%' OR p.name LIKE '%Level%') AND COL_LENGTH('workflow.WORKFLOW_STEP', 'EscalationLevels') IS NOT NULL THEN 's.EscalationLevels'
                 WHEN p.name LIKE '%Tier%' AND COL_LENGTH('workflow.WORKFLOW_STEP', 'ApproverTierNo') IS NOT NULL THEN 's.ApproverTierNo'
                 ELSE 'NULL' END AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY p.parameter_id)
        FROM sys.parameters p
        WHERE p.object_id = OBJECT_ID('workflow.fn_ResolveApprover') AND p.parameter_id > 0);
    DECLARE @Sql NVARCHAR(MAX) = N'UPDATE m SET m.ResolvedUserId = workflow.fn_ResolveApprover(' + @Args + N')
        FROM #mv m JOIN workflow.WORKFLOW_STEP s ON s.WorkflowDefinitionId = @Def AND s.StepNo = m.StepNo
        WHERE m.Keep = 1;';
    EXEC sp_executesql @Sql, N'@Def INT, @Emp INT', @Def = @TargetWorkflowDefinitionId, @Emp = @EmployeeId;

    UPDATE #mv
    SET [Status] = CASE WHEN ResolvedUserId IS NOT NULL AND ResolvedUserId = @RequesterUserId THEN 'Skipped'
                        WHEN ApproverType <> 'Role' AND ResolvedUserId IS NULL THEN 'Skipped'
                        ELSE 'Pending' END,
        SkipReason = CASE WHEN ResolvedUserId IS NOT NULL AND ResolvedUserId = @RequesterUserId
                               THEN 'Approver is the requester - nobody approves their own request.'
                          WHEN ApproverType <> 'Role' AND ResolvedUserId IS NULL
                               THEN 'No approver could be resolved (post vacant or no login).' END
    WHERE Keep = 1;

    /* WF-10: a move that leaves nothing to sign approves the request - only when HR says so */
    IF NOT EXISTS (SELECT 1 FROM #mv WHERE Keep = 1 AND [Status] = 'Pending') AND ISNULL(@ConfirmClose, 0) = 0
    BEGIN
        COMMIT;
        SET @Msg = CONCAT(N'Moving this request to version ', @ToVer, N' leaves no step to sign - it would be approved at once. Confirm the move to approve it.');
        RAISERROR(N'%s', 16, 1, @Msg);
        RETURN 1;
    END

    /* ---- writes ---- */
    UPDATE workflow.REQUEST_INSTANCE
    SET OriginalWorkflowDefinitionId = ISNULL(OriginalWorkflowDefinitionId, @CurDefId),
        WorkflowDefinitionId = @TargetWorkflowDefinitionId,
        VersionMovedAt = SYSUTCDATETIME(),
        VersionMovedBy = @ActedByUserId
    WHERE RequestInstanceId = @RequestInstanceId AND [Status] = 'Pending' AND WorkflowDefinitionId = @CurDefId;
    IF @@ROWCOUNT <> 1 BEGIN COMMIT; RAISERROR(@Moment, 16, 1); RETURN 1; END      -- nothing written yet

    /* rule 2: from the current step on, what has not been decided goes (waiting steps, and steps skipped at submit) */
    DELETE FROM workflow.REQUEST_STEP_INSTANCE
    WHERE RequestInstanceId = @RequestInstanceId AND StepNo >= @CurStep AND [Status] NOT IN ('Approved', 'Rejected');

    INSERT INTO workflow.REQUEST_STEP_INSTANCE
        (RequestInstanceId, StepNo, Name, ApproverType, ResolvedUserId, ApproverRoleId, FallbackRoleId, [Status], SkipReason)
    SELECT @RequestInstanceId, m.StepNo, m.Name, m.ApproverType, m.ResolvedUserId, m.ApproverRoleId, m.FallbackRoleId,
           m.[Status], m.SkipReason
    FROM #mv m WHERE m.Keep = 1;

    /* the step flags the chain carries, copied wherever both tables have the column */
    DECLARE @col SYSNAME, @Copy NVARCHAR(MAX);
    DECLARE cols CURSOR LOCAL FAST_FORWARD FOR
        SELECT v.c FROM (VALUES ('CanAdjust'), ('RequiresComment'), ('RequiresSignature'), ('RejectionEndsRequest'),
                                ('EscalationLevels'), ('ApproverTierNo'), ('IsMandatory')) v(c)
        WHERE COL_LENGTH('workflow.REQUEST_STEP_INSTANCE', v.c) IS NOT NULL AND COL_LENGTH('workflow.WORKFLOW_STEP', v.c) IS NOT NULL;
    OPEN cols;
    FETCH NEXT FROM cols INTO @col;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Copy = N'UPDATE si SET si.' + QUOTENAME(@col) + N' = s.' + QUOTENAME(@col) + N'
            FROM workflow.REQUEST_STEP_INSTANCE si
            JOIN workflow.WORKFLOW_STEP s ON s.WorkflowDefinitionId = @Def AND s.StepNo = si.StepNo
            JOIN #mv m ON m.StepNo = si.StepNo AND m.Keep = 1
            WHERE si.RequestInstanceId = @Rid;';
        EXEC sp_executesql @Copy, N'@Def INT, @Rid INT', @Def = @TargetWorkflowDefinitionId, @Rid = @RequestInstanceId;
        FETCH NEXT FROM cols INTO @col;
    END
    CLOSE cols; DEALLOCATE cols;

    /* record the move itself, then every step it skipped or dropped */
    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    VALUES (@RequestInstanceId, NULL, 'VersionMoved', @ActedByUserId,
            LEFT(CONCAT('Moved from version ', @FromVer, ' to version ', @ToVer, '. ', @Reason), 300));

    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    SELECT @RequestInstanceId, m.StepNo, 'Skipped', NULL, m.SkipReason
    FROM #mv m WHERE m.Keep = 1 AND m.[Status] = 'Skipped';

    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    SELECT @RequestInstanceId, NULL, 'Skipped', NULL,
           LEFT(CONCAT(N'Step ', m.StepNo, N' of version ', @ToVer, N' (', m.Name,
                       N') was not added: the request had already passed that point.'), 300)
    FROM #mv m WHERE m.Keep = 0;

    /* where does it stand now? */
    DECLARE @NextStep INT = (SELECT MIN(StepNo) FROM workflow.REQUEST_STEP_INSTANCE
                             WHERE RequestInstanceId = @RequestInstanceId AND [Status] = 'Pending');

    IF @NextStep IS NULL
        UPDATE workflow.REQUEST_INSTANCE
        SET [Status] = 'Approved', CurrentStepNo = NULL, ClosedAt = SYSUTCDATETIME(),
            ClosedReason = 'Approved automatically: no steps remained after moving to the new workflow version.'
        WHERE RequestInstanceId = @RequestInstanceId AND [Status] = 'Pending';
    ELSE
        UPDATE workflow.REQUEST_INSTANCE
        SET CurrentStepNo = @NextStep
        WHERE RequestInstanceId = @RequestInstanceId AND [Status] = 'Pending';
    SET @Rows = @@ROWCOUNT;
    IF @Rows <> 1
    BEGIN
        IF @Tc = 0 BEGIN ROLLBACK; RAISERROR(@Moment, 16, 1); RETURN 1; END;
        THROW 50000, @Moment, 1;
    END

    /* WF-9: a move that closes the request applies what its approval does */
    IF @NextStep IS NULL
        EXEC workflow.usp_Request_ApplyApprovalEffects @RequestInstanceId = @RequestInstanceId, @ActorUserId = @ActedByUserId;

    COMMIT TRAN;

    SELECT r.RequestInstanceId, r.[Status], r.CurrentStepNo,
           @FromVer AS MovedFromVersion, @ToVer AS MovedToVersion,
           r.VersionMovedAt, r.VersionMovedBy
    FROM workflow.REQUEST_INSTANCE r
    WHERE r.RequestInstanceId = @RequestInstanceId;
    RETURN 0;
END;
GO

/* ============================================================================
   12b. WEB-7: who the waiting step can be handed to - the picker behind "Hand to someone else", which used to send
        user 0 and always failed. NEW workflow.usp_Request_GetDelegateCandidates.
   ============================================================================ */
CREATE OR ALTER PROCEDURE workflow.usp_Request_GetDelegateCandidates
    @RequestInstanceId INT,
    @ForUserId         INT
AS
BEGIN
    SET NOCOUNT ON;

    /* only somebody who may act on the waiting step gets anybody back: the list is the picker for THEIR hand-over */
    DECLARE @StepInstId INT, @EmployeeId INT;
    SELECT @StepInstId = si.RequestStepInstanceId, @EmployeeId = ri.EmployeeId
    FROM workflow.REQUEST_INSTANCE ri
    JOIN workflow.REQUEST_STEP_INSTANCE si
      ON si.RequestInstanceId = ri.RequestInstanceId AND si.StepNo = ri.CurrentStepNo
    WHERE ri.RequestInstanceId = @RequestInstanceId AND ri.[Status] IN ('Pending', 'OnHold');

    IF @StepInstId IS NOT NULL AND workflow.fn_CanUserActOnStep(@StepInstId, @ForUserId) = 0
        SET @StepInstId = NULL;          -- same shape, no rows

    /* the rules usp_Request_Delegate applies: an active account, not the caller, not the person the request is about */
    SELECT u.UserId, u.Username, e.FullName
    FROM security.[USER] u
    OUTER APPLY (SELECT TOP 1 x.FullName
                 FROM hr.EMPLOYEE x
                 WHERE x.UserId = u.UserId AND ISNULL(x.IsDeleted, 0) = 0
                 ORDER BY x.EmployeeId) e
    WHERE @StepInstId IS NOT NULL
      AND u.IsActive = 1
      AND u.UserId <> @ForUserId
      AND NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE r WHERE r.EmployeeId = @EmployeeId AND r.UserId = u.UserId)
    ORDER BY ISNULL(e.FullName, u.Username), u.UserId;
END;
GO

/* ============================================================================
   13. Data repairs (guarded, idempotent; nothing here touches money)
   ============================================================================ */
/* a leave whose approval no longer stands carries no approved end date */
UPDATE lr SET ApprovedToDate = NULL
FROM workflow.LEAVE_REQUEST lr
JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
WHERE lr.ApprovedToDate IS NOT NULL AND ri.[Status] <> 'Approved';
GO
/* ROS-11: a month left Approved after its approval was taken back (the old reversal had no roster arm). It cannot be
   told apart from an open re-submission by its columns alone, and un-approving a roster in use is for a person to
   decide, so the months whose header points at a REVERSED request that is no longer approved are only listed. */
DECLARE @Left NVARCHAR(MAX) = (
    SELECT STRING_AGG(CONCAT(N'branch ', rm.BranchId, N' ', CONVERT(CHAR(7), rm.MonthDate, 23),
                             N' (request #', rm.RequestInstanceId, N' is ', cur.[Status], N')'), N'; ')
    FROM attendance.ROSTER_MONTH rm
    JOIN workflow.REQUEST_INSTANCE cur ON cur.RequestInstanceId = rm.RequestInstanceId
    WHERE rm.[Status] = 'Approved' AND cur.[Status] <> 'Approved'
      AND EXISTS (SELECT 1 FROM workflow.REQUEST_REVERSAL rv
                  WHERE rv.RequestInstanceId = cur.RequestInstanceId AND rv.CompletedAt IS NOT NULL));
IF @Left IS NOT NULL
    PRINT CONCAT(N'QA3 workflow: roster month(s) still Approved on an approval that was taken back - review them: ', @Left);
GO

PRINT 'QA3 workflow: reversals, decisions under lock, restored figures, reopen rules and version moves in place';
GO
