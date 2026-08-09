/* ============================================================================
   WITHDRAW A DECISION  -  unsign, while it is still yours to unsign
   MokaCo_HRMS
   RUN AFTER: workflow_update_all.sql, workflow_advisory_rejection.sql,
              workflow_hold_and_notes.sql
   ----------------------------------------------------------------------------
   THE CASE
     HR rejects an exit permission and immediately sees they misread the date. The
     Owner has not looked at it yet. Nothing downstream has happened. There was no
     way back: the signature was permanent from the moment it was written.

   THE RULE
     You may withdraw YOUR OWN decision while BOTH hold:
       1. the request is still open (Pending or OnHold), and
       2. nobody AFTER you has acted

     The second is the one that matters. Once the Owner has decided, he decided
     partly BECAUSE of what you signed - pulling your decision out from under his
     would leave a chain that never happened in that order. At that point the way
     back is a new request, not an edit.

   NOTHING IS ERASED
     The withdrawal is its own event in the signature log, sitting after the
     decision it undoes:
         14:20  Rejected by sara.hr - "Clashes with the delivery."
         14:22  Withdrawn by sara.hr - "Misread the date, it is Thursday."
     The step returns to Pending and is HERS again. An audit trail that can lose
     entries is not an audit trail.

   THE FIGURE HAS TO GO BACK TOO
     If HR cut 180 minutes to 120 and then withdraws, ApprovedMinutes must return to
     180 - otherwise the withdrawal is a lie, and worse, HR cannot restore it: the
     decide procedure refuses to grant more than currently stands, so 120 would be
     permanent. REQUEST_STEP_INSTANCE.ValueBefore holds the figure as it stood when
     the step opened, written by the typed _Decide procedure, read back on
     withdrawal. One nullable column, and the minimum needed for a withdrawal to be
     truthful.

   AND FOR CLOSED REQUESTS
     A REJECTED or CANCELLED request may be REOPENED by HR - it never had an effect,
     so nothing has to be unwound.
     An APPROVED one may NOT. Its minutes are already on the attendance day and its
     leave may already be posted. Correct that through attendance
     (usp_Attendance_SetExitApproval), which is built for it, rather than pretending
     the approval never happened.

   ADDS   : ValueBefore on REQUEST_STEP_INSTANCE, 'Withdrawn' and 'Reopened' actions,
            3 procedures
   CHANGES: usp_ExitPermission_Decide (snapshots the figure), usp_Request_GetSteps
   ============================================================================ */
USE MokaCo_HRMS;
GO

DROP PROCEDURE IF EXISTS workflow.usp_ExitPermission_WithdrawDecision;
DROP PROCEDURE IF EXISTS workflow.usp_Request_ReopenClosed;
DROP PROCEDURE IF EXISTS workflow.usp_Request_WithdrawDecision;
GO

/* The typed table's figure as it stood when this step opened. Written by the typed
   _Decide procedure only when it changes something; NULL means this step changed
   nothing and there is nothing to put back. Text, because one column has to serve
   minutes, money and days alike - nothing computes from it, it is only ever handed
   back to the typed procedure that wrote it. */
IF COL_LENGTH('workflow.REQUEST_STEP_INSTANCE', 'ValueBefore') IS NULL
    ALTER TABLE workflow.REQUEST_STEP_INSTANCE ADD ValueBefore NVARCHAR(100) NULL;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_WfSig_Action')
    ALTER TABLE workflow.WORKFLOW_SIGNATURE DROP CONSTRAINT CK_WfSig_Action;
ALTER TABLE workflow.WORKFLOW_SIGNATURE ADD CONSTRAINT CK_WfSig_Action
    CHECK ([Action] IN ('Submitted','Approved','Rejected','Skipped','Cancelled',
                        'VersionMoved','OnHold','Resumed','Withdrawn','Reopened'));
GO

/* ############################################################################
   =====================  THE ENGINE HALF (value-agnostic)  ==================
   ############################################################################ */

/* WITHDRAW your own decision on one step.

   Refuses, with the reason stated plainly, when:
     - the request is closed          -> reopening is a different, HR-only act
     - you did not make that decision -> you cannot unsign for somebody else
     - anyone after you has acted     -> their decision assumed yours

   The step returns to Pending with its comment cleared, and CurrentStepNo moves
   back to it. The typed procedure has already put any changed figure back before
   calling this. */
CREATE PROCEDURE workflow.usp_Request_WithdrawDecision
    @RequestInstanceId INT,
    @StepNo            INT,
    @ActedByUserId     INT,
    @Reason            NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = ''
    BEGIN RAISERROR('Say why you are withdrawing. The original decision stays on the record, so the reason is what explains it.', 16, 1); RETURN; END

    DECLARE @ReqStatus VARCHAR(20);
    SELECT @ReqStatus = [Status] FROM workflow.REQUEST_INSTANCE
    WHERE RequestInstanceId = @RequestInstanceId;

    IF @ReqStatus IS NULL
    BEGIN RAISERROR('Request not found.', 16, 1); RETURN; END

    IF @ReqStatus NOT IN ('Pending', 'OnHold')
    BEGIN
        RAISERROR('This request is closed. A rejected or cancelled request can be reopened by HR; an approved one must be corrected through attendance.', 16, 1);
        RETURN;
    END

    DECLARE @StepInstId INT, @StepStatus VARCHAR(20), @Signer INT;
    SELECT @StepInstId = RequestStepInstanceId, @StepStatus = [Status], @Signer = ActedByUserId
    FROM workflow.REQUEST_STEP_INSTANCE
    WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @StepNo;

    IF @StepInstId IS NULL
    BEGIN RAISERROR('That step does not exist on this request.', 16, 1); RETURN; END

    IF @StepStatus NOT IN ('Approved', 'Rejected')
    BEGIN RAISERROR('There is no decision on that step to withdraw.', 16, 1); RETURN; END

    IF @Signer IS NULL OR @Signer <> @ActedByUserId
    BEGIN RAISERROR('You can only withdraw a decision you made yourself.', 16, 1); RETURN; END

    /* has anybody moved on the strength of this? */
    DECLARE @LaterActor NVARCHAR(150) = (
        SELECT TOP 1 CONCAT(si.Name, N' (', ISNULL(u.Username, N'the engine'), N')')
        FROM workflow.REQUEST_STEP_INSTANCE si
        LEFT JOIN security.[USER] u ON u.UserId = si.ActedByUserId
        WHERE si.RequestInstanceId = @RequestInstanceId
          AND si.StepNo > @StepNo
          AND si.ActedAt IS NOT NULL
        ORDER BY si.StepNo);

    IF @LaterActor IS NOT NULL
    BEGIN
        RAISERROR('%s has already acted on this request, so your decision can no longer be withdrawn. Raise a new request instead.', 16, 1, @LaterActor);
        RETURN;
    END

    DECLARE @WasDecision VARCHAR(25) = (SELECT Decision FROM workflow.REQUEST_STEP_INSTANCE
                                        WHERE RequestStepInstanceId = @StepInstId);

    BEGIN TRAN;

    /* the step becomes unsigned and open again */
    UPDATE workflow.REQUEST_STEP_INSTANCE
    SET [Status] = 'Pending', Decision = NULL,
        ActedByUserId = NULL, ActedAt = NULL, Comment = NULL, ValueBefore = NULL,
        HoldReason = NULL, HoldSetAt = NULL, HoldSetByUserId = NULL, WaitingOnRequester = 0
    WHERE RequestStepInstanceId = @StepInstId;

    /* the withdrawal is recorded AFTER the decision it undoes, never in place of it */
    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    VALUES (@RequestInstanceId, @StepNo, 'Withdrawn', @ActedByUserId,
            LEFT(CONCAT(N'Withdrew their ', LOWER(ISNULL(@WasDecision, 'decision')), N'. ', @Reason), 300));

    /* the request comes back to the earliest step still needing someone */
    DECLARE @NextStep INT = (SELECT MIN(StepNo) FROM workflow.REQUEST_STEP_INSTANCE
                             WHERE RequestInstanceId = @RequestInstanceId
                               AND [Status] IN ('Pending','OnHold'));

    UPDATE workflow.REQUEST_INSTANCE
    SET [Status] = 'Pending', CurrentStepNo = @NextStep,
        ClosedAt = NULL, ClosedReason = NULL
    WHERE RequestInstanceId = @RequestInstanceId;

    COMMIT TRAN;

    SELECT RequestInstanceId, [Status], CurrentStepNo
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;
END;
GO

/* REOPEN a closed request. HR only - gate it on WORKFLOW_VERSION_MOVE in the API.

   REJECTED and CANCELLED requests only. An APPROVED request has already had its
   effect: its minutes are on the attendance day and its leave may be posted.
   Un-approving it would leave those behind, so the honest correction is through
   attendance, and this refuses rather than making a mess someone finds at payroll.

   Reopening returns the request to the step that closed it, unsigned. */
CREATE PROCEDURE workflow.usp_Request_ReopenClosed
    @RequestInstanceId INT,
    @ActedByUserId     INT,
    @Reason            NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = ''
    BEGIN RAISERROR('A reason is required to reopen a closed request.', 16, 1); RETURN; END

    DECLARE @ReqStatus VARCHAR(20);
    SELECT @ReqStatus = [Status] FROM workflow.REQUEST_INSTANCE
    WHERE RequestInstanceId = @RequestInstanceId;

    IF @ReqStatus IS NULL
    BEGIN RAISERROR('Request not found.', 16, 1); RETURN; END

    IF @ReqStatus = 'Approved'
    BEGIN
        RAISERROR('An approved request cannot be reopened - its result has already been applied. Correct the attendance day instead, or cancel and raise a new request.', 16, 1);
        RETURN;
    END

    IF @ReqStatus NOT IN ('Rejected', 'Cancelled')
    BEGIN RAISERROR('Only a rejected or cancelled request can be reopened.', 16, 1); RETURN; END

    /* the step that ended it - that is where it goes back to */
    DECLARE @StepNo INT = (SELECT MAX(StepNo) FROM workflow.REQUEST_STEP_INSTANCE
                           WHERE RequestInstanceId = @RequestInstanceId AND [Status] = 'Rejected');

    BEGIN TRAN;

    IF @StepNo IS NOT NULL
        UPDATE workflow.REQUEST_STEP_INSTANCE
        SET [Status] = 'Pending', Decision = NULL,
            ActedByUserId = NULL, ActedAt = NULL, Comment = NULL, ValueBefore = NULL
        WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @StepNo;

    DECLARE @NextStep INT = (SELECT MIN(StepNo) FROM workflow.REQUEST_STEP_INSTANCE
                             WHERE RequestInstanceId = @RequestInstanceId
                               AND [Status] IN ('Pending','OnHold'));

    UPDATE workflow.REQUEST_INSTANCE
    SET [Status] = 'Pending', CurrentStepNo = @NextStep,
        ClosedAt = NULL, ClosedReason = NULL
    WHERE RequestInstanceId = @RequestInstanceId;

    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    VALUES (@RequestInstanceId, @StepNo, 'Reopened', @ActedByUserId, LEFT(@Reason, 300));

    COMMIT TRAN;

    SELECT RequestInstanceId, [Status], CurrentStepNo
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;
END;
GO

/* ############################################################################
   =======================  THE TYPED HALF (the figure)  =====================
   ############################################################################ */

/* Decide, now snapshotting the standing figure before changing it - so a
   withdrawal can put it back. Identical in every other respect. */
CREATE OR ALTER PROCEDURE workflow.usp_ExitPermission_Decide
    @RequestInstanceId INT,
    @ActedByUserId     INT,
    @ApprovedMinutes   INT = NULL,
    @Comment           NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @EpId INT, @Standing INT, @Step INT;
    SELECT @EpId = ep.ExitPermissionId, @Standing = ep.ApprovedMinutes, @Step = r.CurrentStepNo
    FROM workflow.EXIT_PERMISSION ep
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
    WHERE ep.RequestInstanceId = @RequestInstanceId AND r.[Status] IN ('Pending','OnHold');

    IF @EpId IS NULL
    BEGIN RAISERROR('No open exit permission for that request.', 16, 1); RETURN; END

    DECLARE @Changed BIT =
        CASE WHEN @ApprovedMinutes IS NOT NULL AND @ApprovedMinutes <> @Standing THEN 1 ELSE 0 END;

    IF @Changed = 1
    BEGIN
        IF @ApprovedMinutes < 0
        BEGIN RAISERROR('Minutes cannot be negative.', 16, 1); RETURN; END
        IF @ApprovedMinutes > @Standing
        BEGIN
            RAISERROR('You can approve less than was requested, but not more. If more time is needed, the employee should raise a new request.', 16, 1);
            RETURN;
        END
    END

    DECLARE @Summary NVARCHAR(300) =
        CASE WHEN @Changed = 1
             THEN CONCAT(N'Minutes away: ', @Standing, N' -> ', @ApprovedMinutes)
             ELSE NULL END;

    BEGIN TRAN;

    IF @Changed = 1
    BEGIN
        UPDATE workflow.EXIT_PERMISSION
        SET ApprovedMinutes = @ApprovedMinutes
        WHERE ExitPermissionId = @EpId;

        /* keep what it was, so this decision can be taken back */
        UPDATE workflow.REQUEST_STEP_INSTANCE
        SET ValueBefore = CAST(@Standing AS NVARCHAR(100))
        WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @Step;
    END

    COMMIT TRAN;

    EXEC workflow.usp_Request_Approve
         @RequestInstanceId = @RequestInstanceId,
         @ActedByUserId     = @ActedByUserId,
         @Comment           = @Comment,
         @ChangeSummary     = @Summary;

    SELECT ep.ExitPermissionId, ep.RequestInstanceId,
           ep.RequestedMinutes, ep.ApprovedMinutes,
           ep.RequestedMinutes - ep.ApprovedMinutes AS MinutesReduced,
           CAST(CASE WHEN ep.ApprovedMinutes <> ep.RequestedMinutes THEN 1 ELSE 0 END AS BIT) AS WasReduced,
           r.[Status], r.CurrentStepNo
    FROM workflow.EXIT_PERMISSION ep
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
    WHERE ep.ExitPermissionId = @EpId;
END;
GO

/* Withdraw a decision on an exit permission: put the figure back, then unsign.

   THE ORDER MATTERS. The engine validates who may withdraw and whether anyone has
   acted since, and RAISERRORs if not - which rolls back the figure restoration too,
   because both run in the caller's transaction. Restoring first and letting the
   engine be the gate means a refused withdrawal leaves nothing behind.

   This is the pattern every future request type copies. */
CREATE PROCEDURE workflow.usp_ExitPermission_WithdrawDecision
    @RequestInstanceId INT,
    @StepNo            INT,
    @ActedByUserId     INT,
    @Reason            NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Before NVARCHAR(100) = (
        SELECT ValueBefore FROM workflow.REQUEST_STEP_INSTANCE
        WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @StepNo);

    BEGIN TRAN;

    /* only when this step actually changed the figure */
    IF @Before IS NOT NULL
        UPDATE workflow.EXIT_PERMISSION
        SET ApprovedMinutes = TRY_CAST(@Before AS INT)
        WHERE RequestInstanceId = @RequestInstanceId;

    EXEC workflow.usp_Request_WithdrawDecision
         @RequestInstanceId = @RequestInstanceId,
         @StepNo            = @StepNo,
         @ActedByUserId     = @ActedByUserId,
         @Reason            = @Reason;

    COMMIT TRAN;

    SELECT ep.ExitPermissionId, ep.RequestedMinutes, ep.ApprovedMinutes,
           r.[Status], r.CurrentStepNo
    FROM workflow.EXIT_PERMISSION ep
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
    WHERE ep.RequestInstanceId = @RequestInstanceId;
END;
GO

/* ############################################################################
   ===============================  READS  ===================================
   ############################################################################ */

/* The step list, now telling the UI whether each decision can still be taken back -
   so a Withdraw button appears only where it would actually work. */
CREATE OR ALTER PROCEDURE workflow.usp_Request_GetSteps
    @RequestInstanceId INT,
    @ForUserId         INT = NULL      -- whose buttons are we deciding about
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ReqStatus VARCHAR(20) = (SELECT [Status] FROM workflow.REQUEST_INSTANCE
                                      WHERE RequestInstanceId = @RequestInstanceId);

    SELECT si.RequestStepInstanceId, si.StepNo, si.Name, si.ApproverType,
           si.ResolvedUserId, ru.Username AS ResolvedUsername,
           si.ApproverRoleId, ro.Name AS ApproverRoleName,
           si.FallbackRoleId, fro.Name AS FallbackRoleName,
           si.[Status], si.Decision,
           si.ActedByUserId, au.Username AS ActedByUsername,
           si.ActedAt, si.Comment, si.SkipReason,
           si.RejectionEndsRequest,
           si.HoldReason, si.HoldSetAt, si.WaitingOnRequester,
           hu.Username AS HoldSetByUsername,
           ISNULL(s.CanAdjust, 0)       AS CanAdjust,
           ISNULL(s.RequiresComment, 0) AS RequiresComment,
           CAST(CASE WHEN si.[Status] = 'Rejected' AND si.RejectionEndsRequest = 0
                      AND EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE nx
                                  WHERE nx.RequestInstanceId = si.RequestInstanceId
                                    AND nx.StepNo > si.StepNo AND nx.ActedAt IS NOT NULL)
                     THEN 1 ELSE 0 END AS BIT) AS WasOverruled,

           /* every condition the withdraw procedure enforces, answered up front */
           CAST(CASE WHEN @ForUserId IS NOT NULL
                      AND @ReqStatus IN ('Pending','OnHold')
                      AND si.[Status] IN ('Approved','Rejected')
                      AND si.ActedByUserId = @ForUserId
                      AND NOT EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE nx
                                      WHERE nx.RequestInstanceId = si.RequestInstanceId
                                        AND nx.StepNo > si.StepNo AND nx.ActedAt IS NOT NULL)
                     THEN 1 ELSE 0 END AS BIT) AS CanWithdraw,

           (SELECT COUNT(*) FROM workflow.REQUEST_ATTACHMENT at
            WHERE at.RequestInstanceId = si.RequestInstanceId AND at.StepNo = si.StepNo) AS ProofCount
    FROM workflow.REQUEST_STEP_INSTANCE si
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = si.RequestInstanceId
    LEFT JOIN workflow.WORKFLOW_STEP s
           ON s.WorkflowDefinitionId = r.WorkflowDefinitionId AND s.StepNo = si.StepNo
    LEFT JOIN security.[USER] ru  ON ru.UserId = si.ResolvedUserId
    LEFT JOIN security.[USER] au  ON au.UserId = si.ActedByUserId
    LEFT JOIN security.[USER] hu  ON hu.UserId = si.HoldSetByUserId
    LEFT JOIN security.[ROLE] ro  ON ro.RoleId = si.ApproverRoleId
    LEFT JOIN security.[ROLE] fro ON fro.RoleId = si.FallbackRoleId
    WHERE si.RequestInstanceId = @RequestInstanceId
    ORDER BY si.StepNo;
END;
GO

/* ============================================================================
   SMOKE TEST  -  your exact scenario
   ============================================================================ */
/*
EXEC workflow.usp_ExitPermission_Create
     @EmployeeId = <lina>, @RaisedByUserId = <lina user>,
     @ExitDate = '2026-09-02', @FromTime = '11:00', @ToTime = '14:00',
     @Reason = N'Family matter';
--   Requested 180 | Approved 180

EXEC workflow.usp_ExitPermission_Decide @RequestInstanceId = <id>, @ActedByUserId = <mgr>;
--   step 1 approved, now at step 2 (HR)

-- HR rejects by mistake. Step 2 is advisory, so the request stays open at step 3.
EXEC workflow.usp_Request_Reject @RequestInstanceId = <id>, @ActedByUserId = <hr>,
     @Reason = N'Clashes with the delivery.';
--   Status Pending, CurrentStepNo 3

-- The Owner has NOT acted. HR takes it back.
EXEC workflow.usp_ExitPermission_WithdrawDecision
     @RequestInstanceId = <id>, @StepNo = 2, @ActedByUserId = <hr>,
     @Reason = N'Misread the date - the delivery is Thursday.';
--   step 2 back to Pending and unsigned, CurrentStepNo back to 2

EXEC workflow.usp_Request_GetById @RequestInstanceId = <id>;
--   the log shows BOTH: Rejected at 14:20, Withdrawn at 14:22

-- HR decides properly this time, cutting the hours
EXEC workflow.usp_ExitPermission_Decide
     @RequestInstanceId = <id>, @ActedByUserId = <hr>, @ApprovedMinutes = 120,
     @Comment = N'Two hours is enough.';
--   Approved 120, now at step 3


------------------------------------------------------ THE FIGURE GOES BACK
-- withdraw that too, and 120 must return to 180
EXEC workflow.usp_ExitPermission_WithdrawDecision
     @RequestInstanceId = <id>, @StepNo = 2, @ActedByUserId = <hr>,
     @Reason = N'Checking with the branch first.';

SELECT RequestedMinutes, ApprovedMinutes FROM workflow.EXIT_PERMISSION
WHERE RequestInstanceId = <id>;
--   EXPECT 180 | 180.  If ApprovedMinutes were still 120, HR could never restore
--   the full request - the decide procedure refuses to grant more than stands.


---------------------------------------------------------- THE NEGATIVE TESTS
-- these must all FAIL
--
-- 1. the Owner approves, THEN HR tries to withdraw
EXEC workflow.usp_ExitPermission_Decide @RequestInstanceId = <id>, @ActedByUserId = <owner>;
EXEC workflow.usp_ExitPermission_WithdrawDecision
     @RequestInstanceId = <id>, @StepNo = 2, @ActedByUserId = <hr>, @Reason = N'changed my mind';
--   "Owner approval (owner) has already acted..."   AND the request is closed anyway
--
-- 2. withdrawing somebody else's decision
EXEC workflow.usp_ExitPermission_WithdrawDecision
     @RequestInstanceId = <other>, @StepNo = 1, @ActedByUserId = <hr>, @Reason = N'x';
--   "You can only withdraw a decision you made yourself."
--
-- 3. reopening an APPROVED request
EXEC workflow.usp_Request_ReopenClosed @RequestInstanceId = <approved>, @ActedByUserId = <hr>,
     @Reason = N'undo';
--   "An approved request cannot be reopened - its result has already been applied."
--
-- 4. but a REJECTED one reopens fine
EXEC workflow.usp_Request_ReopenClosed @RequestInstanceId = <rejected>, @ActedByUserId = <hr>,
     @Reason = N'The owner rejected on the wrong information.';
*/

/* ============================================================================
   END. 1 column | 2 signature actions | 3 new procs | 2 replaced.
   A decision can be taken back while it is still the only one that has been made.
   ============================================================================ */
