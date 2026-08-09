/* ============================================================================
   DECISION TYPES  -  the choices an approver has, as configuration
   MokaCo_HRMS
   RUN AFTER: workflow_update_all.sql, workflow_advisory_rejection.sql,
              workflow_hold_and_notes.sql, workflow_withdraw_decision.sql
   ----------------------------------------------------------------------------
   WHY
     Approve and reject were hardcoded, then hold was added by hand, and each new
     choice meant touching the engine, the API and the UI together. With more
     decision types coming that does not hold. So the CHOICES become a catalogue,
     the same way request types did.

   ============ THE ONE THING THAT CANNOT BE DATA ============
     What a decision DOES to the chain is a code path, not a row. There are exactly
     four, and adding a fifth is real work:

       Approve   sign and move on
       Reject    sign against it (ending the request, or advising, per the step)
       Hold      pause without deciding; the step stays yours
       Delegate  hand this step to a named person; it stays open

     A decision TYPE names one of those four as its EngineAction, and layers its own
     label, colour, and requirements on top. So:

       "Ask the employee for details"   = Hold + waiting on requester + comment
                                          required   -> PURE DATA, no code
       "Approve with conditions"        = Approve + comment required
                                          -> PURE DATA, no code
       "Escalate to the owner"          = a new behaviour -> needs engine work

     Two of the three things you named are free. Be suspicious of anyone (including
     me) who claims the third is.

   ============ WHAT A STEP OFFERS ============
     WORKFLOW_STEP_DECISION lists the choices for one step. A step with NO rows
     offers every default - so chains keep working untouched, and you only configure
     where you want something narrower. A step that merely endorses can be limited to
     Approve and Reject; a step that decides money can have the full set.

   ADDS   : DECISION_TYPE, WORKFLOW_STEP_DECISION, delegation columns, 5 procedures
   ============================================================================ */
USE MokaCo_HRMS;
GO

DROP PROCEDURE IF EXISTS workflow.usp_Step_GetAvailableDecisions;
DROP PROCEDURE IF EXISTS workflow.usp_Definition_SetStepDecisions;
DROP PROCEDURE IF EXISTS workflow.usp_DecisionType_Upsert;
DROP PROCEDURE IF EXISTS workflow.usp_DecisionType_GetAll;
DROP PROCEDURE IF EXISTS workflow.usp_Request_Delegate;
GO
DROP TABLE IF EXISTS workflow.WORKFLOW_STEP_DECISION;
DROP TABLE IF EXISTS workflow.DECISION_TYPE;
GO

/* workflow.DECISION_TYPE
   One choice an approver can make. Reference data.

   Code is the stable key, and it is what lands in REQUEST_STEP_INSTANCE.Decision -
   so the values already stored there ('Approved', 'ApprovedWithChanges', 'Rejected')
   are seeded here unchanged and nothing needs migrating.

   IsSelectable = 0 marks a decision the engine DERIVES rather than the user picking:
   'ApprovedWithChanges' is what an approval becomes when a figure was altered. It
   needs a label and a colour like any other, but it must never appear in the menu. */
CREATE TABLE workflow.DECISION_TYPE (
    DecisionTypeId INT IDENTITY NOT NULL PRIMARY KEY,   -- e.g. 1
    Code           VARCHAR(30)  NOT NULL UNIQUE,        -- e.g. 'OnHold'
    Label          NVARCHAR(60) NOT NULL,               -- on the button. e.g. 'Put on hold'
    [Description]  NVARCHAR(300) NULL,                  -- help text under the menu item

    /* which of the four engine behaviours carries this out */
    EngineAction   VARCHAR(20)  NOT NULL,               -- Approve/Reject/Hold/Delegate

    /* how it should look: green, red, or neither */
    Tone           VARCHAR(10)  NOT NULL DEFAULT 'Neutral',

    /* what the dialog must collect before it can be submitted */
    RequiresComment    BIT NOT NULL DEFAULT 0,
    RequiresAttachment BIT NOT NULL DEFAULT 0,          -- proof for this decision
    RequiresTargetUser BIT NOT NULL DEFAULT 0,          -- Delegate: to whom
    AllowsValueChange  BIT NOT NULL DEFAULT 0,          -- may adjust the typed figure
    /* Hold-family only: does this put the ball in the EMPLOYEE'S court? */
    WaitingOnRequester BIT NOT NULL DEFAULT 0,

    IsPrimary      BIT NOT NULL DEFAULT 0,              -- the filled button; at most one
    IsSelectable   BIT NOT NULL DEFAULT 1,              -- 0 = derived, never offered
    IsSystem       BIT NOT NULL DEFAULT 0,              -- cannot be deleted
    IsActive       BIT NOT NULL DEFAULT 1,
    Icon           VARCHAR(40) NULL,                    -- lucide-react name
    SortOrder      INT NOT NULL DEFAULT 0,

    CONSTRAINT CK_DecType_Action CHECK (EngineAction IN ('Approve','Reject','Hold','Delegate')),
    CONSTRAINT CK_DecType_Tone   CHECK (Tone IN ('Positive','Negative','Neutral')),
    /* a delegation with nobody to delegate to is not a decision */
    CONSTRAINT CK_DecType_Target CHECK (EngineAction <> 'Delegate' OR RequiresTargetUser = 1)
);
GO

/* Which choices one step offers.
   NO ROWS FOR A STEP = every active, selectable, default decision type. That is the
   important default: existing chains keep working with nothing configured, and you
   only touch this when you want a step to be narrower than the norm. */
CREATE TABLE workflow.WORKFLOW_STEP_DECISION (
    WorkflowStepId INT NOT NULL
                   REFERENCES workflow.WORKFLOW_STEP(WorkflowStepId) ON DELETE CASCADE,
    DecisionTypeId INT NOT NULL
                   REFERENCES workflow.DECISION_TYPE(DecisionTypeId),
    CONSTRAINT PK_StepDecision PRIMARY KEY (WorkflowStepId, DecisionTypeId)
);
GO

/* delegation: who handed this step over, so the chain does not silently show a
   different approver than the one it resolved to */
IF COL_LENGTH('workflow.REQUEST_STEP_INSTANCE', 'DelegatedFromUserId') IS NULL
    ALTER TABLE workflow.REQUEST_STEP_INSTANCE ADD
        DelegatedFromUserId INT NULL REFERENCES security.[USER](UserId),
        DelegatedAt         DATETIME2 NULL;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_WfSig_Action')
    ALTER TABLE workflow.WORKFLOW_SIGNATURE DROP CONSTRAINT CK_WfSig_Action;
ALTER TABLE workflow.WORKFLOW_SIGNATURE ADD CONSTRAINT CK_WfSig_Action
    CHECK ([Action] IN ('Submitted','Approved','Rejected','Skipped','Cancelled',
                        'VersionMoved','OnHold','Resumed','Withdrawn','Reopened','Delegated'));
GO

/* ---- the starting catalogue ----------------------------------------------
   The first three are what the engine already writes, so existing rows keep their
   meaning. The last two are new choices built entirely from existing behaviour -
   which is the point of the table.                                            */
INSERT INTO workflow.DECISION_TYPE
    (Code, Label, [Description], EngineAction, Tone, RequiresComment, RequiresTargetUser,
     AllowsValueChange, WaitingOnRequester, IsPrimary, IsSelectable, IsSystem, Icon, SortOrder)
SELECT v.* FROM (VALUES
 ('Approved', N'Approve',
  N'Sign this step and pass the request on.',
  'Approve','Positive', 0,0,1,0, 1,1,1, 'check', 10),

 ('ApprovedWithChanges', N'Approved with changes',
  N'Set automatically when an approver alters a figure. Never offered as a choice.',
  'Approve','Positive', 1,0,1,0, 0,0,1, 'check', 20),

 ('Rejected', N'Reject',
  N'Sign against this request. Whether that ends it depends on the step.',
  'Reject','Negative', 1,0,0,0, 0,1,1, 'x', 30),

 ('OnHold', N'Put on hold',
  N'Pause without deciding. The step stays yours.',
  'Hold','Neutral', 1,0,0,0, 0,1,1, 'pause', 40),

 ('MoreInfo', N'Ask the employee',
  N'Pause and ask the person who raised it for something. It appears in their list as a question to answer.',
  'Hold','Neutral', 1,0,0,1, 0,1,0, 'help-circle', 50),

 ('Delegated', N'Hand to someone else',
  N'Pass this step to a named person. They decide instead of you; the request does not move on.',
  'Delegate','Neutral', 1,1,0,0, 0,1,0, 'user-plus', 60)
) AS v(Code, Label, [Description], EngineAction, Tone, RequiresComment, RequiresTargetUser,
       AllowsValueChange, WaitingOnRequester, IsPrimary, IsSelectable, IsSystem, Icon, SortOrder)
WHERE NOT EXISTS (SELECT 1 FROM workflow.DECISION_TYPE d WHERE d.Code = v.Code);
GO

/* ############################################################################
   =========================  THE CATALOGUE  =================================
   ############################################################################ */

CREATE PROCEDURE workflow.usp_DecisionType_GetAll
    @IncludeInactive BIT = 0
AS BEGIN SET NOCOUNT ON;
    SELECT DecisionTypeId, Code, Label, [Description], EngineAction, Tone,
           RequiresComment, RequiresAttachment, RequiresTargetUser,
           AllowsValueChange, WaitingOnRequester,
           IsPrimary, IsSelectable, IsSystem, IsActive, Icon, SortOrder
    FROM workflow.DECISION_TYPE
    WHERE (@IncludeInactive = 1 OR IsActive = 1)
    ORDER BY SortOrder, Label; END;
GO

/* Add or edit a decision type.
   EngineAction is the one field that cannot be invented: it must name a behaviour
   the engine already implements. Anything else is presentation and rules. */
CREATE PROCEDURE workflow.usp_DecisionType_Upsert
    @Code VARCHAR(30), @Label NVARCHAR(60),
    @Description NVARCHAR(300) = NULL,
    @EngineAction VARCHAR(20),
    @Tone VARCHAR(10) = 'Neutral',
    @RequiresComment BIT = 0, @RequiresAttachment BIT = 0,
    @RequiresTargetUser BIT = 0, @AllowsValueChange BIT = 0,
    @WaitingOnRequester BIT = 0,
    @IsActive BIT = 1, @Icon VARCHAR(40) = NULL, @SortOrder INT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM workflow.DECISION_TYPE WHERE Code = @Code AND IsSystem = 1)
    BEGIN
        /* system types may be relabelled and reordered, never rewired */
        UPDATE workflow.DECISION_TYPE
        SET Label = @Label, [Description] = @Description,
            Icon = @Icon, SortOrder = @SortOrder, IsActive = @IsActive
        WHERE Code = @Code;
    END
    ELSE IF EXISTS (SELECT 1 FROM workflow.DECISION_TYPE WHERE Code = @Code)
        UPDATE workflow.DECISION_TYPE
        SET Label = @Label, [Description] = @Description, EngineAction = @EngineAction,
            Tone = @Tone, RequiresComment = @RequiresComment,
            RequiresAttachment = @RequiresAttachment, RequiresTargetUser = @RequiresTargetUser,
            AllowsValueChange = @AllowsValueChange, WaitingOnRequester = @WaitingOnRequester,
            IsActive = @IsActive, Icon = @Icon, SortOrder = @SortOrder
        WHERE Code = @Code;
    ELSE
        INSERT INTO workflow.DECISION_TYPE
            (Code, Label, [Description], EngineAction, Tone, RequiresComment,
             RequiresAttachment, RequiresTargetUser, AllowsValueChange, WaitingOnRequester,
             IsActive, Icon, SortOrder)
        VALUES (@Code, @Label, @Description, @EngineAction, @Tone, @RequiresComment,
                @RequiresAttachment, @RequiresTargetUser, @AllowsValueChange, @WaitingOnRequester,
                @IsActive, @Icon, @SortOrder);

    SELECT * FROM workflow.DECISION_TYPE WHERE Code = @Code;
END;
GO

/* Limit one step to a specific set. Pass an empty list to clear the restriction and
   return the step to offering everything. */
CREATE PROCEDURE workflow.usp_Definition_SetStepDecisions
    @WorkflowStepId INT,
    @DecisionCodes  NVARCHAR(500) = NULL      -- comma-separated; NULL/'' = all defaults
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM workflow.WORKFLOW_STEP s
                   JOIN workflow.WORKFLOW_DEFINITION d ON d.WorkflowDefinitionId = s.WorkflowDefinitionId
                   WHERE s.WorkflowStepId = @WorkflowStepId AND d.[Status] = 'Draft')
    BEGIN
        RAISERROR('Decision options can only be changed on a Draft definition. Create a new draft version instead.', 16, 1);
        RETURN;
    END

    BEGIN TRAN;

    DELETE FROM workflow.WORKFLOW_STEP_DECISION WHERE WorkflowStepId = @WorkflowStepId;

    IF @DecisionCodes IS NOT NULL AND LTRIM(RTRIM(@DecisionCodes)) <> ''
    BEGIN
        INSERT INTO workflow.WORKFLOW_STEP_DECISION (WorkflowStepId, DecisionTypeId)
        SELECT @WorkflowStepId, dt.DecisionTypeId
        FROM STRING_SPLIT(@DecisionCodes, ',') sp
        JOIN workflow.DECISION_TYPE dt ON dt.Code = LTRIM(RTRIM(sp.value))
        WHERE dt.IsSelectable = 1 AND dt.IsActive = 1;

        /* a step that offers nothing is a dead end */
        IF NOT EXISTS (SELECT 1 FROM workflow.WORKFLOW_STEP_DECISION WHERE WorkflowStepId = @WorkflowStepId)
        BEGIN
            ROLLBACK TRAN;
            RAISERROR('None of those decision codes exist. A step must offer at least one choice.', 16, 1);
            RETURN;
        END
    END

    COMMIT TRAN;

    SELECT dt.Code, dt.Label
    FROM workflow.WORKFLOW_STEP_DECISION sd
    JOIN workflow.DECISION_TYPE dt ON dt.DecisionTypeId = sd.DecisionTypeId
    WHERE sd.WorkflowStepId = @WorkflowStepId
    ORDER BY dt.SortOrder;
END;
GO

/* ############################################################################
   ==============  WHAT CAN *THIS* PERSON DO, RIGHT NOW  =====================
   ############################################################################ */

/* The one call the decision UI makes. Returns the choices to render, already
   filtered by everything the engine would otherwise reject afterwards:

     - the step's configured set, or all defaults when it has none
     - AllowsValueChange dropped where the step's CanAdjust is 0, so nobody is
       offered an adjustment the engine will refuse
     - nothing at all if this user cannot act on the step

   Returning an empty set is a meaningful answer: it means "not yours to decide",
   and the UI should show the step as read-only rather than with dead buttons. */
CREATE PROCEDURE workflow.usp_Step_GetAvailableDecisions
    @RequestInstanceId INT,
    @UserId            INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Step INT, @ReqStatus VARCHAR(20), @DefId INT;
    SELECT @Step = CurrentStepNo, @ReqStatus = [Status], @DefId = WorkflowDefinitionId
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;

    IF @ReqStatus NOT IN ('Pending','OnHold') RETURN;      -- closed: nothing to offer

    DECLARE @StepInstId INT = (SELECT RequestStepInstanceId FROM workflow.REQUEST_STEP_INSTANCE
                               WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @Step);

    IF workflow.fn_CanUserActOnStep(@StepInstId, @UserId) = 0 RETURN;

    DECLARE @StepId INT, @CanAdjust BIT;
    SELECT @StepId = WorkflowStepId, @CanAdjust = ISNULL(CanAdjust, 0)
    FROM workflow.WORKFLOW_STEP
    WHERE WorkflowDefinitionId = @DefId AND StepNo = @Step;

    DECLARE @HasRestriction BIT =
        CASE WHEN EXISTS (SELECT 1 FROM workflow.WORKFLOW_STEP_DECISION
                          WHERE WorkflowStepId = @StepId) THEN 1 ELSE 0 END;

    SELECT dt.Code, dt.Label, dt.[Description], dt.EngineAction, dt.Tone,
           dt.RequiresComment, dt.RequiresAttachment, dt.RequiresTargetUser,
           dt.WaitingOnRequester, dt.IsPrimary, dt.Icon, dt.SortOrder,
           /* the step decides whether a figure may be touched, not the catalogue */
           CAST(CASE WHEN dt.AllowsValueChange = 1 AND @CanAdjust = 1
                     THEN 1 ELSE 0 END AS BIT) AS AllowsValueChange
    FROM workflow.DECISION_TYPE dt
    WHERE dt.IsActive = 1 AND dt.IsSelectable = 1
      AND (@HasRestriction = 0
           OR EXISTS (SELECT 1 FROM workflow.WORKFLOW_STEP_DECISION sd
                      WHERE sd.WorkflowStepId = @StepId AND sd.DecisionTypeId = dt.DecisionTypeId))
    ORDER BY dt.SortOrder, dt.Label;
END;
GO

/* ############################################################################
   ===========================  DELEGATE  ====================================
   The one new behaviour. The others already existed.
   ############################################################################ */

/* Hand this step to a named person. The request does NOT move on - the step is
   still open, it simply belongs to somebody else now.

   Refuses to delegate to the requester, for the same reason nobody approves their
   own request: routing round that rule is still breaking it.

   The step becomes a SpecificUser step for this request only. The definition is
   untouched, and any fallback role still applies - a deputy can still step in. */
CREATE PROCEDURE workflow.usp_Request_Delegate
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

    /* nobody decides their own request, however it is routed */
    IF EXISTS (SELECT 1 FROM hr.EMPLOYEE e
               WHERE e.EmployeeId = @EmployeeId AND e.UserId = @ToUserId)
    BEGIN RAISERROR('You cannot hand this to the person who raised it.', 16, 1); RETURN; END

    BEGIN TRAN;

    UPDATE workflow.REQUEST_STEP_INSTANCE
    SET ApproverType        = 'SpecificUser',   -- for THIS request; the chain is unchanged
        ResolvedUserId      = @ToUserId,
        ApproverRoleId      = NULL,
        DelegatedFromUserId = ISNULL(DelegatedFromUserId, @ActedByUserId),
        DelegatedAt         = SYSUTCDATETIME(),
        [Status]            = 'Pending',        -- clears a hold: it is theirs now
        HoldReason = NULL, HoldSetAt = NULL, HoldSetByUserId = NULL, WaitingOnRequester = 0
    WHERE RequestStepInstanceId = @StepInstId;

    UPDATE workflow.REQUEST_INSTANCE
    SET [Status] = 'Pending'
    WHERE RequestInstanceId = @RequestInstanceId;

    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    VALUES (@RequestInstanceId, @Step, 'Delegated', @ActedByUserId,
            LEFT(CONCAT(N'Handed to ',
                        (SELECT Username FROM security.[USER] WHERE UserId = @ToUserId),
                        N'. ', @Reason), 300));

    COMMIT TRAN;

    SELECT r.RequestInstanceId, r.[Status], r.CurrentStepNo,
           si.ResolvedUserId, u.Username AS NowWith
    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.REQUEST_STEP_INSTANCE si
      ON si.RequestInstanceId = r.RequestInstanceId AND si.StepNo = r.CurrentStepNo
    LEFT JOIN security.[USER] u ON u.UserId = si.ResolvedUserId
    WHERE r.RequestInstanceId = @RequestInstanceId;
END;
GO

/* ============================================================================
   SMOKE TEST
   ============================================================================ */
/*
-- what the catalogue offers
EXEC workflow.usp_DecisionType_GetAll;
--   6 rows; ApprovedWithChanges has IsSelectable 0

-- what HR can do on a live request
EXEC workflow.usp_Step_GetAvailableDecisions @RequestInstanceId = <id>, @UserId = <hr>;
--   Approve (IsPrimary 1, AllowsValueChange 1 because step 2 has CanAdjust 1),
--   Reject, Put on hold, Ask the employee, Hand to someone else

-- the same call as the OWNER while it sits with HR
EXEC workflow.usp_Step_GetAvailableDecisions @RequestInstanceId = <id>, @UserId = <owner>;
--   NOTHING. Not his step. The UI shows it read-only rather than with dead buttons.

-- narrow step 1 to endorse-or-refuse only (on a DRAFT definition)
EXEC workflow.usp_Definition_SetStepDecisions
     @WorkflowStepId = <step 1 id>, @DecisionCodes = 'Approved,Rejected';

-- delegation
EXEC workflow.usp_Request_Delegate
     @RequestInstanceId = <id>, @ActedByUserId = <hr>, @ToUserId = <other hr>,
     @Reason = N'On leave until Monday.';
--   step now resolves to the other user; the request has NOT moved on
--   delegating to the requester FAILS

-- a brand new decision type, no code anywhere:
EXEC workflow.usp_DecisionType_Upsert
     @Code = 'ApprovedConditional', @Label = N'Approve with conditions',
     @Description = N'Allow it, with something the employee must do.',
     @EngineAction = 'Approve', @Tone = 'Positive',
     @RequiresComment = 1, @Icon = 'check-check', @SortOrder = 15;
--   appears in the menu on the next load
*/

/* ============================================================================
   END. 2 tables | 2 columns | 5 procedures.
   Decisions are configuration. Their four behaviours are not.
   ============================================================================ */
