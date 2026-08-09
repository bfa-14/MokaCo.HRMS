/* ============================================================================
   DRAFT DECISIONS  -  prepare now, sign later
   MokaCo_HRMS
   RUN AFTER: workflow_rollback_signature.sql
   ----------------------------------------------------------------------------
   THE CASE
     An approver knows what they want to do but cannot sign right now - not at their
     own machine, no time to type a password, wants to sleep on it. They should be
     able to write the decision down and come back to it.

   ============ WHY THIS IS A DRAFT AND NOT A NEW STATE ============
     The obvious design is a 'Decided but unsigned' status on the request. It is the
     wrong one, and expensively so:

       - if the request ADVANCES on an unsigned decision, the signature is
         decorative; the next approver already has it and the effect already happened
       - if it does NOT advance, you have invented a second way for a request to
         stall silently: a step that looks decided, has not moved, and is asking
         nobody for anything
       - and every query that treats Pending as open would need teaching about the
         new state, exactly as OnHold did

     So nothing here is a decision. It is the APPROVER'S OWN SAVED WORKING, stored on
     the step, changing no status. The step stays Pending because it IS pending -
     nobody is misled, the inbox still shows it as outstanding, and every existing
     query keeps working untouched.

     Signing later is not a second phase of a decision. It is making the decision,
     with the typing already done.

   DRAFTS ARE PRIVATE TO THEIR AUTHOR
     A Role step can be signed by any HR user. If Sara saves a draft, Nadia must not
     see it, and must certainly not submit it under her own name. So a draft belongs
     to the person who wrote it, and saving over somebody else's is refused rather
     than done silently.

   ADDS: 7 draft columns on REQUEST_STEP_INSTANCE, 3 procedures
   ============================================================================ */
USE MokaCo_HRMS;
GO

DROP PROCEDURE IF EXISTS workflow.usp_Step_DiscardDraftDecision;
DROP PROCEDURE IF EXISTS workflow.usp_Step_GetDraftDecision;
DROP PROCEDURE IF EXISTS workflow.usp_Step_SaveDraftDecision;
GO

/* Everything the popup would have submitted, held until its author comes back.
   None of it means anything to the engine - no procedure reads these except the
   three below, and the step's Status is untouched. */
IF COL_LENGTH('workflow.REQUEST_STEP_INSTANCE', 'DraftDecisionCode') IS NULL
    ALTER TABLE workflow.REQUEST_STEP_INSTANCE ADD
        DraftDecisionCode       VARCHAR(30)    NULL,   -- e.g. 'Approved'
        DraftComment            NVARCHAR(1000) NULL,   -- the note they typed
        DraftValue              NVARCHAR(100)  NULL,   -- adjusted figure, as text
        DraftTargetUserId       INT            NULL    -- for a delegation
                                REFERENCES security.[USER](UserId),
        DraftWaitingOnRequester BIT            NOT NULL DEFAULT 0,
        DraftSavedByUserId      INT            NULL    -- whose draft this is
                                REFERENCES security.[USER](UserId),
        DraftSavedAt            DATETIME2      NULL;
GO

/* ############################################################################
   ==============================  SAVE  =====================================
   ############################################################################ */

/* Save what you would have submitted, without submitting it.

   Refuses when somebody ELSE already has a draft here. On a Role step two people can
   both act, and quietly overwriting a colleague's unsigned working - possibly a
   carefully worded rejection - is worse than making them talk to each other.

   Nothing is validated beyond that: a draft is allowed to be incomplete. Missing a
   required comment, an adjustment outside the range - none of it matters until it is
   actually submitted, and refusing to SAVE half-formed thinking would defeat the
   point. The real rules apply at signing, unchanged. */
CREATE PROCEDURE workflow.usp_Step_SaveDraftDecision
    @RequestInstanceId  INT,
    @ActedByUserId      INT,
    @DecisionCode       VARCHAR(30),
    @Comment            NVARCHAR(1000) = NULL,
    @Value              NVARCHAR(100)  = NULL,
    @TargetUserId       INT = NULL,
    @WaitingOnRequester BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Step INT, @ReqStatus VARCHAR(20);
    SELECT @Step = CurrentStepNo, @ReqStatus = [Status]
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;

    IF @ReqStatus NOT IN ('Pending','OnHold')
    BEGIN RAISERROR('This request is closed.', 16, 1); RETURN; END

    DECLARE @StepInstId INT, @ExistingAuthor INT;
    SELECT @StepInstId = RequestStepInstanceId, @ExistingAuthor = DraftSavedByUserId
    FROM workflow.REQUEST_STEP_INSTANCE
    WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @Step;

    IF workflow.fn_CanUserActOnStep(@StepInstId, @ActedByUserId) = 0
    BEGIN RAISERROR('You are not the approver for this step.', 16, 1); RETURN; END

    IF @ExistingAuthor IS NOT NULL AND @ExistingAuthor <> @ActedByUserId
    BEGIN
        DECLARE @Other NVARCHAR(100) = (SELECT Username FROM security.[USER] WHERE UserId = @ExistingAuthor);
        RAISERROR('%s has an unsigned decision saved here. Ask them to sign or discard it first.', 16, 1, @Other);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM workflow.DECISION_TYPE
                   WHERE Code = @DecisionCode AND IsActive = 1 AND IsSelectable = 1)
    BEGIN RAISERROR('That is not a decision anyone can choose.', 16, 1); RETURN; END

    UPDATE workflow.REQUEST_STEP_INSTANCE
    SET DraftDecisionCode = @DecisionCode,
        DraftComment      = @Comment,
        DraftValue        = @Value,
        DraftTargetUserId = @TargetUserId,
        DraftWaitingOnRequester = @WaitingOnRequester,
        DraftSavedByUserId = @ActedByUserId,
        DraftSavedAt       = SYSUTCDATETIME()
    WHERE RequestStepInstanceId = @StepInstId;

    SELECT @RequestInstanceId AS RequestInstanceId, @Step AS StepNo,
           @DecisionCode AS DraftDecisionCode, SYSUTCDATETIME() AS DraftSavedAt;
END;
GO

/* Read back your own draft. Returns nothing when the draft belongs to someone else -
   theirs is not yours to see, still less to submit under your name. */
CREATE PROCEDURE workflow.usp_Step_GetDraftDecision
    @RequestInstanceId INT,
    @ForUserId         INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT si.StepNo, si.Name AS StepName,
           si.DraftDecisionCode, dt.Label AS DraftDecisionLabel,
           si.DraftComment, si.DraftValue,
           si.DraftTargetUserId, tu.Username AS DraftTargetUsername,
           si.DraftWaitingOnRequester, si.DraftSavedAt,
           DATEDIFF(DAY, si.DraftSavedAt, SYSUTCDATETIME()) AS DaysSinceSaved
    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.REQUEST_STEP_INSTANCE si
      ON si.RequestInstanceId = r.RequestInstanceId AND si.StepNo = r.CurrentStepNo
    LEFT JOIN workflow.DECISION_TYPE dt ON dt.Code = si.DraftDecisionCode
    LEFT JOIN security.[USER] tu        ON tu.UserId = si.DraftTargetUserId
    WHERE r.RequestInstanceId = @RequestInstanceId
      AND si.DraftSavedByUserId = @ForUserId;
END;
GO

/* Throw it away. Only its author. */
CREATE PROCEDURE workflow.usp_Step_DiscardDraftDecision
    @RequestInstanceId INT,
    @ActedByUserId     INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE si
    SET DraftDecisionCode = NULL, DraftComment = NULL, DraftValue = NULL,
        DraftTargetUserId = NULL, DraftWaitingOnRequester = 0,
        DraftSavedByUserId = NULL, DraftSavedAt = NULL
    FROM workflow.REQUEST_STEP_INSTANCE si
    JOIN workflow.REQUEST_INSTANCE r
      ON r.RequestInstanceId = si.RequestInstanceId AND si.StepNo = r.CurrentStepNo
    WHERE r.RequestInstanceId = @RequestInstanceId
      AND si.DraftSavedByUserId = @ActedByUserId;

    SELECT @@ROWCOUNT AS Discarded;
END;
GO

/* ############################################################################
   =====  THE INBOX MUST SAY "you started something here"  ===================
   Otherwise a draft is a note to yourself that you never see again.
   ############################################################################ */

CREATE OR ALTER PROCEDURE workflow.usp_Request_GetPendingForUser @UserId INT
AS BEGIN SET NOCOUNT ON;
    SELECT r.RequestInstanceId, rt.Code AS RequestTypeCode, rt.Name AS RequestTypeName,
           r.EmployeeId, e.FullName AS EmployeeName, b.Name AS BranchName,
           r.Title, r.[Status] AS RequestStatus,
           si.StepNo, si.Name AS StepName, si.ApproverType, si.[Status] AS StepStatus,
           si.HoldReason, si.HoldSetAt, si.WaitingOnRequester,
           DATEDIFF(DAY, si.HoldSetAt, SYSUTCDATETIME()) AS DaysOnHold,
           r.SubmittedAt,
           DATEDIFF(DAY, r.SubmittedAt, SYSUTCDATETIME()) AS DaysWaiting,

           /* an unsigned decision of MY OWN, waiting to be signed */
           CAST(CASE WHEN si.DraftSavedByUserId = @UserId THEN 1 ELSE 0 END AS BIT) AS HasMyDraft,
           CASE WHEN si.DraftSavedByUserId = @UserId THEN dt.Label END AS MyDraftDecision,
           CASE WHEN si.DraftSavedByUserId = @UserId THEN si.DraftSavedAt END AS MyDraftSavedAt,

           CAST(CASE WHEN si.ApproverType <> 'Role' AND si.ResolvedUserId = @UserId THEN 0
                     WHEN si.ApproverType =  'Role' AND EXISTS (
                          SELECT 1 FROM security.USER_ROLE ur
                          WHERE ur.UserId = @UserId AND ur.RoleId = si.ApproverRoleId) THEN 0
                     ELSE 1 END AS BIT) AS AsDeputy,
           fr.Name AS FallbackRoleName,
           si.DelegatedToUserId, du.Username AS DelegatedToUsername
    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.REQUEST_STEP_INSTANCE si
      ON si.RequestInstanceId = r.RequestInstanceId
     AND si.StepNo = r.CurrentStepNo AND si.[Status] IN ('Pending','OnHold')
    JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = r.RequestTypeId
    JOIN hr.EMPLOYEE e            ON e.EmployeeId = r.EmployeeId
    JOIN hr.BRANCH b              ON b.BranchId = e.BranchId
    LEFT JOIN workflow.DECISION_TYPE dt ON dt.Code = si.DraftDecisionCode
    LEFT JOIN security.[ROLE] fr  ON fr.RoleId = si.FallbackRoleId
    LEFT JOIN security.[USER] du  ON du.UserId = si.DelegatedToUserId
    WHERE r.[Status] IN ('Pending','OnHold')
      AND workflow.fn_CanUserActOnStep(si.RequestStepInstanceId, @UserId) = 1
    ORDER BY
        /* my own unfinished work first - I already started it */
        CASE WHEN si.DraftSavedByUserId = @UserId THEN 0
             WHEN si.[Status] = 'Pending' THEN 1 ELSE 2 END,
        r.SubmittedAt; END;
GO

/* ---- clearing the draft when the decision is actually made ----
   Approve, Reject, Hold and Delegate all write to the step; none of them knows about
   drafts, and none should. One trigger-free sweep instead: the API calls this
   immediately after a successful decision. Harmless if there was no draft. */
GO

/* Long-unsigned drafts. A draft is meant to be picked up again; one sitting for a
   week is a request waiting on somebody who has forgotten they started. */
DROP PROCEDURE IF EXISTS workflow.usp_Request_GetStaleDrafts;
GO
CREATE PROCEDURE workflow.usp_Request_GetStaleDrafts
    @OlderThanDays INT = 3
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.RequestInstanceId, rt.Name AS RequestTypeName,
           e.FullName AS EmployeeName, b.Name AS BranchName, r.Title,
           si.StepNo, si.Name AS StepName,
           dt.Label AS DraftDecision, si.DraftSavedAt,
           u.Username AS SavedBy,
           DATEDIFF(DAY, si.DraftSavedAt, SYSUTCDATETIME()) AS DaysUnsigned,
           DATEDIFF(DAY, r.SubmittedAt, SYSUTCDATETIME()) AS DaysWaiting
    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.REQUEST_STEP_INSTANCE si
      ON si.RequestInstanceId = r.RequestInstanceId AND si.StepNo = r.CurrentStepNo
    JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = r.RequestTypeId
    JOIN hr.EMPLOYEE e ON e.EmployeeId = r.EmployeeId
    JOIN hr.BRANCH b   ON b.BranchId = e.BranchId
    LEFT JOIN workflow.DECISION_TYPE dt ON dt.Code = si.DraftDecisionCode
    LEFT JOIN security.[USER] u ON u.UserId = si.DraftSavedByUserId
    WHERE r.[Status] IN ('Pending','OnHold')
      AND si.DraftSavedAt IS NOT NULL
      AND DATEDIFF(DAY, si.DraftSavedAt, SYSUTCDATETIME()) >= @OlderThanDays
    ORDER BY si.DraftSavedAt;
END;
GO

/* ============================================================================
   SMOKE TEST
   ============================================================================ */
/*
-- HR writes the decision but cannot sign now
EXEC workflow.usp_Step_SaveDraftDecision
     @RequestInstanceId = <id>, @ActedByUserId = <hr>,
     @DecisionCode = 'Approved', @Value = N'120',
     @Comment = N'Two hours is enough; the branch is short-staffed.';

-- the request is STILL PENDING. Nothing moved, nothing was decided.
SELECT [Status], CurrentStepNo FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = <id>;
--   Pending, still step 2

-- and HR's inbox says so, at the top of the list
EXEC workflow.usp_Request_GetPendingForUser @UserId = <hr>;
--   HasMyDraft 1, MyDraftDecision 'Approve'

-- another HR user sees NO draft, and cannot save over it
EXEC workflow.usp_Step_GetDraftDecision @RequestInstanceId = <id>, @ForUserId = <other hr>;
--   nothing
EXEC workflow.usp_Step_SaveDraftDecision @RequestInstanceId = <id>, @ActedByUserId = <other hr>,
     @DecisionCode = 'Rejected', @Comment = N'no';
--   "sara.hr has an unsigned decision saved here. Ask them to sign or discard it first."

-- next morning, HR signs: the ordinary path, nothing special
EXEC workflow.usp_ExitPermission_Decide
     @RequestInstanceId = <id>, @ActedByUserId = <hr>, @ApprovedMinutes = 120,
     @Comment = N'Two hours is enough; the branch is short-staffed.';

EXEC workflow.usp_Step_DiscardDraftDecision @RequestInstanceId = <id>, @ActedByUserId = <hr>;
--   the API calls this straight after any successful decision

EXEC workflow.usp_Request_GetStaleDrafts @OlderThanDays = 3;
*/

/* ============================================================================
   END. 7 columns | 4 procedures | 1 replaced.
   No new status. The step is pending, because it is.
   ============================================================================ */
