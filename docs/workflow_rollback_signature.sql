/* ============================================================================
   SIGNING A ROLLBACK  -  and a correction to how delegation works
   MokaCo_HRMS
   RUN AFTER: workflow_password_signature.sql
   ----------------------------------------------------------------------------
   PART ONE - THE HOLE

     Approving required a password. Withdrawing that approval did not. So the
     ceremony was one-way: the Owner signs to approve, and anyone at his unlocked
     machine un-signs it for free. That is exactly the case the password was meant
     to close, left open on the way back out.

     Undoing a signed act is at least as consequential as making it. Withdrawal now
     asks for a password when ANY of these hold:

       - the decision being withdrawn was itself signed
       - the person withdrawing holds a role with RequiresSignaturePassword
       - the step is marked RequiresSignature

     Same fail-closed rule: if a signature is required and the flag is absent, the
     procedure refuses.

   PART TWO - A CORRECTION I OWE YOU

     usp_Request_Delegate overwrote the step's ApproverType, ResolvedUserId and
     ApproverRoleId. That DESTROYS how the step had resolved - after delegating a
     BranchManager step, nothing remembers it was ever a branch-manager step, so it
     can never be handed back.

     Fixed here, non-destructively: delegation now writes DelegatedToUserId and
     leaves the original resolution alone. fn_CanUserActOnStep honours the delegate
     when that column is set. Undoing is clearing three columns, and the original
     approver is still there underneath.

     If you already ran the delegation from workflow_decision_types.sql on real data,
     the repair block at the end of this file restores what it flattened, as far as
     it can be recovered.

   AND WHAT DOES NOT NEED THIS
     A HOLD already has its undo: usp_Request_Resume. Nothing was signed, nothing
     needs unsigning. Withdrawal is for decisions - approvals and rejections.

   ADDS   : DelegatedToUserId, usp_Request_ReclaimDelegation
   CHANGES: fn_CanUserActOnStep, usp_Request_Delegate,
            usp_Request_WithdrawDecision, usp_ExitPermission_WithdrawDecision,
            usp_Request_GetSteps
   ============================================================================ */
USE MokaCo_HRMS;
GO

DROP PROCEDURE IF EXISTS workflow.usp_Request_ReclaimDelegation;
GO

/* who the step was handed TO. The original ApproverType / ResolvedUserId /
   ApproverRoleId stay exactly as they were underneath, so a delegation can be
   undone and the step returns to whoever it resolved to in the first place. */
IF COL_LENGTH('workflow.REQUEST_STEP_INSTANCE', 'DelegatedToUserId') IS NULL
    ALTER TABLE workflow.REQUEST_STEP_INSTANCE ADD DelegatedToUserId INT NULL
        REFERENCES security.[USER](UserId);
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_WfSig_Action')
    ALTER TABLE workflow.WORKFLOW_SIGNATURE DROP CONSTRAINT CK_WfSig_Action;
ALTER TABLE workflow.WORKFLOW_SIGNATURE ADD CONSTRAINT CK_WfSig_Action
    CHECK ([Action] IN ('Submitted','Approved','Rejected','Skipped','Cancelled',
                        'VersionMoved','OnHold','Resumed','Withdrawn','Reopened',
                        'Delegated','Reclaimed'));
GO

/* ############################################################################
   ==============  WHO MAY ACT  -  now aware of delegation  ==================
   ############################################################################ */

/* May @UserId act on this step?

   Order matters, and the first rule outranks everything:

     0. NEVER your own request. By any route - resolved, role, deputy or delegate.
        Handing a request to the person who raised it, or being handed one of your
        own, does not make it yours to decide.

     1. DELEGATED - when DelegatedToUserId is set, the step belongs to that person.
        The original approver has given it away and cannot act on it while it is
        gone; they may RECLAIM it, which is a different act with its own record.
        The fallback role still applies, because a deputy covers the STEP, not a
        particular person.

     2. Otherwise, as before: the resolved user, anyone holding a Role step's role,
        or anyone holding the step's fallback role.

   Every procedure that authorises anything calls this, so the rule lives in one
   place and cannot drift between approve, reject, hold and withdraw. */
CREATE OR ALTER FUNCTION workflow.fn_CanUserActOnStep
(
    @RequestStepInstanceId INT,
    @UserId                INT
)
RETURNS BIT
AS
BEGIN
    DECLARE @Resolved INT, @RoleId INT, @Fallback INT, @Type VARCHAR(20),
            @ReqId INT, @DelegatedTo INT;

    SELECT @Resolved = si.ResolvedUserId, @RoleId = si.ApproverRoleId,
           @Fallback = si.FallbackRoleId, @Type = si.ApproverType,
           @ReqId    = si.RequestInstanceId, @DelegatedTo = si.DelegatedToUserId
    FROM workflow.REQUEST_STEP_INSTANCE si
    WHERE si.RequestStepInstanceId = @RequestStepInstanceId;

    IF @ReqId IS NULL RETURN 0;

    /* 0. never your own request */
    IF EXISTS (SELECT 1
               FROM workflow.REQUEST_INSTANCE r
               JOIN hr.EMPLOYEE e ON e.EmployeeId = r.EmployeeId
               WHERE r.RequestInstanceId = @ReqId AND e.UserId = @UserId)
        RETURN 0;

    /* the deputy covers the step whatever else is true of it */
    DECLARE @IsDeputy BIT =
        CASE WHEN @Fallback IS NOT NULL
              AND EXISTS (SELECT 1 FROM security.USER_ROLE ur
                          JOIN security.[USER] u ON u.UserId = ur.UserId
                          WHERE ur.UserId = @UserId AND ur.RoleId = @Fallback AND u.IsActive = 1)
             THEN 1 ELSE 0 END;

    /* 1. handed over: the delegate holds it, plus the deputy */
    IF @DelegatedTo IS NOT NULL
        RETURN CASE WHEN @DelegatedTo = @UserId OR @IsDeputy = 1 THEN 1 ELSE 0 END;

    /* 2. the ordinary rules */
    IF @Type <> 'Role' AND @Resolved IS NOT NULL AND @Resolved = @UserId
        RETURN 1;

    IF @Type = 'Role' AND @RoleId IS NOT NULL
       AND EXISTS (SELECT 1 FROM security.USER_ROLE ur
                   JOIN security.[USER] u ON u.UserId = ur.UserId
                   WHERE ur.UserId = @UserId AND ur.RoleId = @RoleId AND u.IsActive = 1)
        RETURN 1;

    RETURN @IsDeputy;
END;
GO

/* ############################################################################
   ==================  DELEGATE, NON-DESTRUCTIVELY  ==========================
   ############################################################################ */

/* Hand this step to a named person. The request does NOT move on - the step is
   still open, it simply belongs to somebody else for now.

   Nothing about how the step resolved is overwritten, so it can be taken back. */
CREATE OR ALTER PROCEDURE workflow.usp_Request_Delegate
    @RequestInstanceId INT,
    @ActedByUserId     INT,
    @ToUserId          INT,
    @Reason            NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = ''
    BEGIN RAISERROR('Say why you are handing this over. The person receiving it needs the context.', 16, 1); RETURN; END

    DECLARE @Step INT, @ReqStatus VARCHAR(20), @EmployeeId INT;
    SELECT @Step = CurrentStepNo, @ReqStatus = [Status], @EmployeeId = EmployeeId
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;

    IF @ReqStatus IS NULL
    BEGIN RAISERROR('Request not found.', 16, 1); RETURN; END
    IF @ReqStatus NOT IN ('Pending','OnHold')
    BEGIN RAISERROR('This request is already closed.', 16, 1); RETURN; END

    DECLARE @StepInstId INT = (SELECT RequestStepInstanceId FROM workflow.REQUEST_STEP_INSTANCE
                               WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @Step);

    IF workflow.fn_CanUserActOnStep(@StepInstId, @ActedByUserId) = 0
    BEGIN RAISERROR('You are not the approver for this step.', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM security.[USER] WHERE UserId = @ToUserId AND IsActive = 1)
    BEGIN RAISERROR('That user does not exist or their account is disabled.', 16, 1); RETURN; END

    IF @ToUserId = @ActedByUserId
    BEGIN RAISERROR('You already have this step.', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM hr.EMPLOYEE e
               WHERE e.EmployeeId = @EmployeeId AND e.UserId = @ToUserId)
    BEGIN RAISERROR('You cannot hand this to the person who raised it.', 16, 1); RETURN; END

    BEGIN TRAN;

    /* the original resolution is left untouched underneath */
    UPDATE workflow.REQUEST_STEP_INSTANCE
    SET DelegatedToUserId   = @ToUserId,
        DelegatedFromUserId = @ActedByUserId,
        DelegatedAt         = SYSUTCDATETIME(),
        [Status]            = 'Pending',      -- clears any hold: it is theirs now
        HoldReason = NULL, HoldSetAt = NULL, HoldSetByUserId = NULL, WaitingOnRequester = 0
    WHERE RequestStepInstanceId = @StepInstId;

    UPDATE workflow.REQUEST_INSTANCE SET [Status] = 'Pending'
    WHERE RequestInstanceId = @RequestInstanceId;

    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    VALUES (@RequestInstanceId, @Step, 'Delegated', @ActedByUserId,
            LEFT(CONCAT(N'Handed to ',
                        (SELECT Username FROM security.[USER] WHERE UserId = @ToUserId),
                        N'. ', @Reason), 300));

    COMMIT TRAN;

    SELECT r.RequestInstanceId, r.[Status], r.CurrentStepNo,
           si.DelegatedToUserId, u.Username AS NowWith
    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.REQUEST_STEP_INSTANCE si
      ON si.RequestInstanceId = r.RequestInstanceId AND si.StepNo = r.CurrentStepNo
    LEFT JOIN security.[USER] u ON u.UserId = si.DelegatedToUserId
    WHERE r.RequestInstanceId = @RequestInstanceId;
END;
GO

/* TAKE IT BACK. Only the person who handed it over, and only while the delegate has
   not decided - once they have, there is nothing left to reclaim and the way back is
   for THEM to withdraw their own decision.

   No password: nothing was signed. Handing something over and taking it back are
   both administrative, and both are logged. */
CREATE PROCEDURE workflow.usp_Request_ReclaimDelegation
    @RequestInstanceId INT,
    @ActedByUserId     INT,
    @Reason            NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Step INT, @ReqStatus VARCHAR(20);
    SELECT @Step = CurrentStepNo, @ReqStatus = [Status]
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;

    IF @ReqStatus NOT IN ('Pending','OnHold')
    BEGIN RAISERROR('This request is already closed.', 16, 1); RETURN; END

    DECLARE @StepInstId INT, @From INT, @StepStatus VARCHAR(20), @To INT;
    SELECT @StepInstId = RequestStepInstanceId, @From = DelegatedFromUserId,
           @StepStatus = [Status], @To = DelegatedToUserId
    FROM workflow.REQUEST_STEP_INSTANCE
    WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @Step;

    IF @To IS NULL
    BEGIN RAISERROR('This step has not been handed to anyone.', 16, 1); RETURN; END

    IF @From <> @ActedByUserId
    BEGIN RAISERROR('Only the person who handed this step over can take it back.', 16, 1); RETURN; END

    IF @StepStatus IN ('Approved','Rejected')
    BEGIN RAISERROR('That step has already been decided. Ask them to withdraw their decision instead.', 16, 1); RETURN; END

    BEGIN TRAN;

    /* clearing these three restores the step to whatever it resolved to originally,
       which was never overwritten */
    UPDATE workflow.REQUEST_STEP_INSTANCE
    SET DelegatedToUserId = NULL, DelegatedFromUserId = NULL, DelegatedAt = NULL,
        [Status] = 'Pending',
        HoldReason = NULL, HoldSetAt = NULL, HoldSetByUserId = NULL, WaitingOnRequester = 0
    WHERE RequestStepInstanceId = @StepInstId;

    UPDATE workflow.REQUEST_INSTANCE SET [Status] = 'Pending'
    WHERE RequestInstanceId = @RequestInstanceId;

    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    VALUES (@RequestInstanceId, @Step, 'Reclaimed', @ActedByUserId,
            LEFT(ISNULL(@Reason, N'Took the step back.'), 300));

    COMMIT TRAN;

    SELECT RequestInstanceId, [Status], CurrentStepNo
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;
END;
GO

/* ############################################################################
   ==================  WITHDRAWAL, NOW SIGNABLE  =============================
   ############################################################################ */

/* WITHDRAW your own decision.

   The rules on WHO and WHEN are unchanged: your own decision, request still open,
   nobody after you has acted.

   What is new is the SIGNATURE. A password is required when any of these hold:
     - the decision being withdrawn was itself signed
     - you hold a role with RequiresSignaturePassword
     - the step is marked RequiresSignature
   Fails closed, like approve and reject: the flag is set by the API only after it
   has verified the password. */
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

    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = ''
    BEGIN RAISERROR('Say why you are withdrawing. The original decision stays on the record, so the reason is what explains it.', 16, 1); RETURN; END

    DECLARE @ReqStatus VARCHAR(20), @DefId INT;
    SELECT @ReqStatus = [Status], @DefId = WorkflowDefinitionId
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;

    IF @ReqStatus IS NULL
    BEGIN RAISERROR('Request not found.', 16, 1); RETURN; END

    IF @ReqStatus NOT IN ('Pending', 'OnHold')
    BEGIN
        RAISERROR('This request is closed. A rejected or cancelled request can be reopened by HR; an approved one must be corrected through attendance.', 16, 1);
        RETURN;
    END

    DECLARE @StepInstId INT, @StepStatus VARCHAR(20), @Signer INT, @WasSigned BIT;
    SELECT @StepInstId = RequestStepInstanceId, @StepStatus = [Status],
           @Signer = ActedByUserId, @WasSigned = ISNULL(SignedWithPassword, 0)
    FROM workflow.REQUEST_STEP_INSTANCE
    WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @StepNo;

    IF @StepInstId IS NULL
    BEGIN RAISERROR('That step does not exist on this request.', 16, 1); RETURN; END

    IF @StepStatus NOT IN ('Approved', 'Rejected')
    BEGIN RAISERROR('There is no decision on that step to withdraw.', 16, 1); RETURN; END

    IF @Signer IS NULL OR @Signer <> @ActedByUserId
    BEGIN RAISERROR('You can only withdraw a decision you made yourself.', 16, 1); RETURN; END

    DECLARE @LaterActor NVARCHAR(150) = (
        SELECT TOP 1 CONCAT(si.Name, N' (', ISNULL(u.Username, N'the engine'), N')')
        FROM workflow.REQUEST_STEP_INSTANCE si
        LEFT JOIN security.[USER] u ON u.UserId = si.ActedByUserId
        WHERE si.RequestInstanceId = @RequestInstanceId
          AND si.StepNo > @StepNo AND si.ActedAt IS NOT NULL
        ORDER BY si.StepNo);

    IF @LaterActor IS NOT NULL
    BEGIN
        RAISERROR('%s has already acted on this request, so your decision can no longer be withdrawn. Raise a new request instead.', 16, 1, @LaterActor);
        RETURN;
    END

    /* --- THE SIGNATURE GATE. Fails closed, exactly like approve and reject. --- */
    DECLARE @NeedsSignature BIT =
        CASE WHEN @WasSigned = 1                                   -- undoing a signed act
               OR ISNULL((SELECT RequiresSignature FROM workflow.WORKFLOW_STEP
                          WHERE WorkflowDefinitionId = @DefId AND StepNo = @StepNo), 0) = 1
               OR EXISTS (SELECT 1 FROM security.USER_ROLE ur      -- security.[ROLE]
                          JOIN security.[ROLE] r ON r.RoleId = ur.RoleId
                          WHERE ur.UserId = @ActedByUserId AND r.RequiresSignaturePassword = 1)
             THEN 1 ELSE 0 END;

    IF @NeedsSignature = 1 AND @SignedWithPassword = 0
    BEGIN
        RAISERROR('Withdrawing this decision must be signed with your password.', 16, 1);
        RETURN;
    END

    DECLARE @WasDecision VARCHAR(25) = (SELECT Decision FROM workflow.REQUEST_STEP_INSTANCE
                                        WHERE RequestStepInstanceId = @StepInstId);

    BEGIN TRAN;

    UPDATE workflow.REQUEST_STEP_INSTANCE
    SET [Status] = 'Pending', Decision = NULL,
        ActedByUserId = NULL, ActedAt = NULL, Comment = NULL, ValueBefore = NULL,
        SignedWithPassword = 0,
        HoldReason = NULL, HoldSetAt = NULL, HoldSetByUserId = NULL, WaitingOnRequester = 0
    WHERE RequestStepInstanceId = @StepInstId;

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
    WHERE RequestInstanceId = @RequestInstanceId;

    COMMIT TRAN;

    SELECT RequestInstanceId, [Status], CurrentStepNo
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;
END;
GO

/* the typed wrapper, carrying the flag through */
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

    DECLARE @Before NVARCHAR(100) = (
        SELECT ValueBefore FROM workflow.REQUEST_STEP_INSTANCE
        WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @StepNo);

    BEGIN TRAN;

    /* put the figure back first; the engine is the gate, and if it refuses, this
       rolls back with it */
    IF @Before IS NOT NULL
        UPDATE workflow.EXIT_PERMISSION
        SET ApprovedMinutes = TRY_CAST(@Before AS INT)
        WHERE RequestInstanceId = @RequestInstanceId;

    EXEC workflow.usp_Request_WithdrawDecision
         @RequestInstanceId  = @RequestInstanceId,
         @StepNo             = @StepNo,
         @ActedByUserId      = @ActedByUserId,
         @Reason             = @Reason,
         @SignedWithPassword = @SignedWithPassword;

    COMMIT TRAN;

    SELECT ep.ExitPermissionId, ep.RequestedMinutes, ep.ApprovedMinutes,
           r.[Status], r.CurrentStepNo
    FROM workflow.EXIT_PERMISSION ep
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
    WHERE ep.RequestInstanceId = @RequestInstanceId;
END;
GO

/* ############################################################################
   ===============================  READ  ====================================
   ############################################################################ */

/* The step list, now answering three questions the UI would otherwise guess at:
   can this person withdraw, will that need a password, and who is holding a
   delegated step. */
CREATE OR ALTER PROCEDURE workflow.usp_Request_GetSteps
    @RequestInstanceId INT,
    @ForUserId         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ReqStatus VARCHAR(20), @DefId INT;
    SELECT @ReqStatus = [Status], @DefId = WorkflowDefinitionId
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;

    /* does THIS user sign for everything they do? asked once, not per row */
    DECLARE @UserAlwaysSigns BIT =
        CASE WHEN @ForUserId IS NOT NULL AND EXISTS (
                SELECT 1 FROM security.USER_ROLE ur
                JOIN security.[ROLE] r ON r.RoleId = ur.RoleId
                WHERE ur.UserId = @ForUserId AND r.RequiresSignaturePassword = 1)
             THEN 1 ELSE 0 END;

    SELECT si.RequestStepInstanceId, si.StepNo, si.Name, si.ApproverType,
           si.ResolvedUserId, ru.Username AS ResolvedUsername,
           si.ApproverRoleId, ro.Name AS ApproverRoleName,
           si.FallbackRoleId, fro.Name AS FallbackRoleName,
           si.[Status], si.Decision,
           si.ActedByUserId, au.Username AS ActedByUsername,
           si.ActedAt, si.Comment, si.SkipReason,
           si.RejectionEndsRequest, si.SignedWithPassword,
           si.HoldReason, si.HoldSetAt, si.WaitingOnRequester,
           hu.Username AS HoldSetByUsername,
           si.DelegatedToUserId, du.Username AS DelegatedToUsername,
           si.DelegatedFromUserId, fu.Username AS DelegatedFromUsername, si.DelegatedAt,
           ISNULL(s.CanAdjust, 0)         AS CanAdjust,
           ISNULL(s.RequiresComment, 0)   AS RequiresComment,
           ISNULL(s.RequiresSignature, 0) AS StepRequiresSignature,

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

           /* ...and whether doing so will ask for a password */
           CAST(CASE WHEN ISNULL(si.SignedWithPassword, 0) = 1
                       OR ISNULL(s.RequiresSignature, 0) = 1
                       OR @UserAlwaysSigns = 1
                     THEN 1 ELSE 0 END AS BIT) AS WithdrawNeedsSignature,

           /* only the person who handed it over may take it back, and only while
              the delegate has not decided */
           CAST(CASE WHEN @ForUserId IS NOT NULL
                      AND si.DelegatedToUserId IS NOT NULL
                      AND si.DelegatedFromUserId = @ForUserId
                      AND si.[Status] NOT IN ('Approved','Rejected')
                     THEN 1 ELSE 0 END AS BIT) AS CanReclaim,

           (SELECT COUNT(*) FROM workflow.REQUEST_ATTACHMENT at
            WHERE at.RequestInstanceId = si.RequestInstanceId AND at.StepNo = si.StepNo) AS ProofCount
    FROM workflow.REQUEST_STEP_INSTANCE si
    LEFT JOIN workflow.WORKFLOW_STEP s
           ON s.WorkflowDefinitionId = @DefId AND s.StepNo = si.StepNo
    LEFT JOIN security.[USER] ru  ON ru.UserId = si.ResolvedUserId
    LEFT JOIN security.[USER] au  ON au.UserId = si.ActedByUserId
    LEFT JOIN security.[USER] hu  ON hu.UserId = si.HoldSetByUserId
    LEFT JOIN security.[USER] du  ON du.UserId = si.DelegatedToUserId
    LEFT JOIN security.[USER] fu  ON fu.UserId = si.DelegatedFromUserId
    LEFT JOIN security.[ROLE] ro  ON ro.RoleId = si.ApproverRoleId
    LEFT JOIN security.[ROLE] fro ON fro.RoleId = si.FallbackRoleId
    WHERE si.RequestInstanceId = @RequestInstanceId
    ORDER BY si.StepNo;
END;
GO

/* ############################################################################
   ============  REPAIR: delegations made by the old procedure  ==============
   Run only if you delegated anything before this file. The old version flattened
   the step to 'SpecificUser'; this recovers what can be recovered by comparing
   against the definition the request is following. Steps never delegated are not
   touched.
   ############################################################################ */
UPDATE si
SET si.ApproverType     = s.ApproverType,
    si.ApproverRoleId   = s.ApproverRoleId,
    si.ResolvedUserId   = workflow.fn_ResolveApprover(s.ApproverType, s.ApproverUserId, r.EmployeeId),
    si.DelegatedToUserId = si.ResolvedUserId          -- who it had been handed to
FROM workflow.REQUEST_STEP_INSTANCE si
JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = si.RequestInstanceId
JOIN workflow.WORKFLOW_STEP s
  ON s.WorkflowDefinitionId = r.WorkflowDefinitionId AND s.StepNo = si.StepNo
WHERE si.DelegatedFromUserId IS NOT NULL
  AND si.DelegatedToUserId IS NULL
  AND si.ApproverType = 'SpecificUser'
  AND s.ApproverType <> 'SpecificUser';
GO

/* ============================================================================
   SMOKE TEST
   ============================================================================ */
/*
-- the Owner signs an approval (his role requires it)
EXEC workflow.usp_Request_Approve @RequestInstanceId = <id>, @ActedByUserId = <owner>,
     @Comment = N'Approved.', @SignedWithPassword = 1;

-- ...and now cannot un-sign it for free
EXEC workflow.usp_Request_WithdrawDecision @RequestInstanceId = <id>, @StepNo = 3,
     @ActedByUserId = <owner>, @Reason = N'Wrong request.';
--   "Withdrawing this decision must be signed with your password."

EXEC workflow.usp_Request_WithdrawDecision @RequestInstanceId = <id>, @StepNo = 3,
     @ActedByUserId = <owner>, @Reason = N'Wrong request.', @SignedWithPassword = 1;
--   succeeds

-- HR, whose role does NOT require signatures, withdraws an unsigned decision freely
EXEC workflow.usp_Request_WithdrawDecision @RequestInstanceId = <id>, @StepNo = 2,
     @ActedByUserId = <hr>, @Reason = N'Misread the date.';
--   succeeds without a password


------------------------------------------------------ DELEGATION, REVERSIBLY
EXEC workflow.usp_Request_Delegate @RequestInstanceId = <id>, @ActedByUserId = <hr>,
     @ToUserId = <other hr>, @Reason = N'On leave until Monday.';

SELECT StepNo, ApproverType, ApproverRoleId, DelegatedToUserId
FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = <id>;
--   ApproverType and ApproverRoleId UNCHANGED - only DelegatedToUserId is set

EXEC workflow.usp_Request_ReclaimDelegation @RequestInstanceId = <id>,
     @ActedByUserId = <hr>, @Reason = N'Back early.';
--   the step returns to the HR role, exactly as it resolved originally

-- someone else trying to reclaim it FAILS
-- reclaiming after the delegate has decided FAILS
*/

/* ============================================================================
   END. 1 column | 1 new proc | 1 function and 5 procedures replaced.
   Signing is now symmetric, and delegation no longer destroys what it replaces.
   ============================================================================ */
