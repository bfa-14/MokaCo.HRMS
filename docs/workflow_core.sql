/* ============================================================================
   WORKFLOW ENGINE  -  CORE  (v1)  -  RE-RUNNABLE
   SQL Server 2025  -  database MokaCo_HRMS
   ----------------------------------------------------------------------------
   The configurable approval engine. Request TYPES and their PATHS are DATA, not
   code: you define a chain once, publish it, and every request follows it.

   =========================== DESIGN PRINCIPLES =============================
   1. VERSIONED, NEVER EDITED. Changing a chain publishes a NEW WORKFLOW_DEFINITION
      version. A request locks the version it was submitted under and follows THAT
      chain to the end, so in-flight requests can never be stranded and history
      always shows the rules that actually applied.

   2. A NEW VERSION NEVER MOVES ANYTHING BY ITSELF. Publishing affects NEW requests
      only; pending requests keep following the version they locked. HR may then
      DECIDE, per request, to move one onto the newer chain (usp_Request_MoveToVersion).
      Nothing is ever rewritten silently underneath an approver mid-signature.
      When a request IS moved:
        - steps already ACTED ON keep their signatures and are never re-asked
        - the remaining chain is replaced by the new version's later steps
        - a new step inserted BEFORE the point already reached is SKIPPED and logged,
          not run retroactively
        - both versions are recorded on the request, so history stays unambiguous

   3. APPROVERS ARE RESOLVED, NOT NAMED. A step says WHAT KIND of approver it needs
      and the engine resolves the person at submit time:
        BranchManager - the manager of the REQUESTER'S OWN branch (scoped: a manager
                        of another branch can never sign)
        Role          - anyone holding that role (HR, General Manager: company-wide
                        on purpose, so any HR user can process any branch)
        SpecificUser  - a named person (rare, for exceptions)

   4. NOBODY APPROVES THEMSELVES. If a step resolves to the requester (the branch
      manager requesting their own leave), the step is SKIPPED and the skip is
      logged. Same when a step cannot resolve at all (vacant manager post): an
      org-chart gap must never block a request, but it must be visible.

   5. WHOSE REQUEST vs WHO TYPED IT are different facts. EmployeeId is the person
      the request is FOR; RaisedByUserId is the account that submitted it. HR
      raising on someone's behalf is a first-class case, not a workaround.

   6. THE SIGNATURE LOG IS APPEND-ONLY. Every action - submit, approve, reject,
      skip, cancel - is one immutable row. Step rows carry the current state; the
      signature log carries the history.

   This file is the ENGINE ONLY. The request TYPES and their payload tables
   (leave, exit permission, overtime, advance) come next, once the paths are known.

   REQUIRES: security.[USER], security.[ROLE], security.USER_ROLE,
             hr.BRANCH, hr.EMPLOYEE
   ============================================================================ */
USE MokaCo_HRMS;
GO

IF SCHEMA_ID('workflow') IS NULL EXEC('CREATE SCHEMA workflow');
GO

/* ############################################################################
   ===================  DROP (children first, FK-safe)  ======================
   ############################################################################ */
DROP PROCEDURE IF EXISTS workflow.usp_Request_GetOnOldVersions;
DROP PROCEDURE IF EXISTS workflow.usp_Request_MoveToVersion;
DROP PROCEDURE IF EXISTS workflow.usp_Request_GetPendingForUser;
DROP PROCEDURE IF EXISTS workflow.usp_Request_GetForEmployee;
DROP PROCEDURE IF EXISTS workflow.usp_Request_GetById;
DROP PROCEDURE IF EXISTS workflow.usp_Request_Cancel;
DROP PROCEDURE IF EXISTS workflow.usp_Request_Reject;
DROP PROCEDURE IF EXISTS workflow.usp_Request_Approve;
DROP PROCEDURE IF EXISTS workflow.usp_Request_Submit;
DROP PROCEDURE IF EXISTS workflow.usp_Definition_GetActive;
DROP PROCEDURE IF EXISTS workflow.usp_Definition_GetSteps;
DROP PROCEDURE IF EXISTS workflow.usp_Definition_Publish;
DROP PROCEDURE IF EXISTS workflow.usp_Definition_AddStep;
DROP PROCEDURE IF EXISTS workflow.usp_Definition_CreateDraft;
DROP PROCEDURE IF EXISTS workflow.usp_Definition_GetAll;
DROP PROCEDURE IF EXISTS workflow.usp_RequestType_Upsert;
DROP PROCEDURE IF EXISTS workflow.usp_RequestType_GetAll;
GO
DROP FUNCTION IF EXISTS workflow.fn_ResolveApprover;
GO
DROP TABLE IF EXISTS workflow.WORKFLOW_SIGNATURE;
DROP TABLE IF EXISTS workflow.REQUEST_STEP_INSTANCE;
DROP TABLE IF EXISTS workflow.REQUEST_INSTANCE;
DROP TABLE IF EXISTS workflow.WORKFLOW_STEP;
DROP TABLE IF EXISTS workflow.WORKFLOW_DEFINITION;
DROP TABLE IF EXISTS workflow.REQUEST_TYPE;
GO

/* ---- BRANCH needs a manager, or the BranchManager step type cannot resolve ---- */
IF COL_LENGTH('hr.BRANCH', 'ManagerEmployeeId') IS NULL
BEGIN
    ALTER TABLE hr.BRANCH ADD ManagerEmployeeId INT NULL;      -- e.g. 10 (Rami manages Main Branch)
    /* nullable on purpose: a vacant post must not break the schema. A step that
       cannot resolve is SKIPPED and logged, never left blocking. */
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Branch_Manager')
    ALTER TABLE hr.BRANCH ADD CONSTRAINT FK_Branch_Manager
        FOREIGN KEY (ManagerEmployeeId) REFERENCES hr.EMPLOYEE(EmployeeId);
GO

/* ############################################################################
   ===============================  TABLES  =================================
   ############################################################################ */

/* workflow.REQUEST_TYPE
   The KINDS of request the system knows (Leave, ExitPermission, Overtime,
   Advance...). Reference data. Code is the stable key the API and the typed
   payload tables join on; Name is what HR sees. */
CREATE TABLE workflow.REQUEST_TYPE (
    RequestTypeId INT IDENTITY  NOT NULL PRIMARY KEY,  -- e.g. 1
    Code          VARCHAR(30)   NOT NULL UNIQUE,       -- stable key. e.g. 'LEAVE'
    Name          NVARCHAR(80)  NOT NULL,              -- e.g. 'Leave request'
    [Description] NVARCHAR(300) NULL,                  -- what it is for
    IsActive      BIT           NOT NULL DEFAULT 1     -- 0 = retired, keeps history
);

/* workflow.WORKFLOW_DEFINITION
   ONE VERSION of the approval chain for one request type. Never edited once
   published - changing the chain means publishing the NEXT version. Exactly one
   version per type may be Active at a time; requests always lock the version
   that was active when they were submitted. */
CREATE TABLE workflow.WORKFLOW_DEFINITION (
    WorkflowDefinitionId INT IDENTITY NOT NULL PRIMARY KEY,  -- e.g. 1
    RequestTypeId  INT NOT NULL                              -- which kind of request
                   REFERENCES workflow.REQUEST_TYPE(RequestTypeId),
    [Version]      INT NOT NULL,                             -- 1, 2, 3... per type. e.g. 2
    [Status]       VARCHAR(20) NOT NULL DEFAULT 'Draft',     -- Draft/Active/Retired
    Notes          NVARCHAR(300) NULL,                       -- why this version exists
    PublishedAt    DATETIME2 NULL,                           -- when it went live
    PublishedBy    INT NULL REFERENCES security.[USER](UserId),
    CreatedAt      DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    CreatedBy      INT NULL REFERENCES security.[USER](UserId),
    CONSTRAINT UQ_WfDef_Version UNIQUE (RequestTypeId, [Version]),
    CONSTRAINT CK_WfDef_Status  CHECK ([Status] IN ('Draft','Active','Retired'))
);

/* workflow.WORKFLOW_STEP
   One APPROVAL STEP in a definition, in order. The step does not name a person -
   it names the KIND of approver, and the engine resolves the actual user when the
   request is submitted (see fn_ResolveApprover). That is what lets a branch
   manager change without touching any workflow.

   ApproverType:
     'BranchManager' - the manager of the REQUESTER'S branch. Scoped: managers of
                       other branches can never sign this request.
     'Role'          - anyone holding ApproverRoleId (HR, General Manager).
                       Deliberately NOT branch-scoped.
     'SpecificUser'  - ApproverUserId, a named person. Use sparingly: it breaks
                       when that person leaves.  */
CREATE TABLE workflow.WORKFLOW_STEP (
    WorkflowStepId       INT IDENTITY NOT NULL PRIMARY KEY,  -- e.g. 1
    WorkflowDefinitionId INT NOT NULL                        -- the version it belongs to
                         REFERENCES workflow.WORKFLOW_DEFINITION(WorkflowDefinitionId) ON DELETE CASCADE,
    StepNo               INT NOT NULL,                       -- 1, 2, 3 in order. e.g. 1
    Name                 NVARCHAR(80) NOT NULL,              -- e.g. 'Branch manager approval'
    ApproverType         VARCHAR(20) NOT NULL,               -- BranchManager/Role/SpecificUser
    ApproverRoleId       INT NULL REFERENCES security.[ROLE](RoleId),   -- when Role. e.g. 3 (HR)
    ApproverUserId       INT NULL REFERENCES security.[USER](UserId),   -- when SpecificUser
    IsMandatory          BIT NOT NULL DEFAULT 1,             -- 0 = may be skipped if unresolved
    CONSTRAINT UQ_WfStep UNIQUE (WorkflowDefinitionId, StepNo),
    CONSTRAINT CK_WfStep_Type CHECK (ApproverType IN ('BranchManager','Role','SpecificUser')),
    /* a Role step must name a role; a SpecificUser step must name a user */
    CONSTRAINT CK_WfStep_Target CHECK (
        (ApproverType = 'Role'         AND ApproverRoleId IS NOT NULL) OR
        (ApproverType = 'SpecificUser' AND ApproverUserId IS NOT NULL) OR
        (ApproverType = 'BranchManager'))
);

/* workflow.REQUEST_INSTANCE
   ONE raised request. The version is captured at submit and never changes, so the
   chain this request follows is frozen even if the definition is superseded
   tomorrow.

   EmployeeId  = WHOSE request it is (drives branch-manager resolution, and whose
                 leave balance / attendance it affects).
   RaisedByUserId = WHO submitted it. Usually the employee's own account; but HR
                 raising on someone's behalf is normal and must stay visible. */
CREATE TABLE workflow.REQUEST_INSTANCE (
    RequestInstanceId INT IDENTITY NOT NULL PRIMARY KEY,  -- e.g. 1
    RequestTypeId     INT NOT NULL                        -- e.g. 1 (LEAVE)
                      REFERENCES workflow.REQUEST_TYPE(RequestTypeId),
    WorkflowDefinitionId INT NOT NULL                     -- the VERSION this request follows
                      REFERENCES workflow.WORKFLOW_DEFINITION(WorkflowDefinitionId),
    EmployeeId        INT NOT NULL                        -- whose request. e.g. 10
                      REFERENCES hr.EMPLOYEE(EmployeeId),
    RaisedByUserId    INT NOT NULL                        -- who typed it. e.g. 2 (sara.hr)
                      REFERENCES security.[USER](UserId),
    [Status]          VARCHAR(20) NOT NULL DEFAULT 'Pending', -- Pending/Approved/Rejected/Cancelled
    CurrentStepNo     INT NULL,                           -- step awaiting action; NULL when closed
    Title             NVARCHAR(150) NULL,                 -- short summary for lists
    SubmittedAt       DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    ClosedAt          DATETIME2 NULL,                     -- when it reached a final state
    ClosedReason      NVARCHAR(300) NULL,                 -- rejection/cancellation reason

    /* --- version moves (see usp_Request_MoveToVersion) ---
       A pending request normally follows the version it locked at submit. HR may
       explicitly move it onto a newer chain; these columns record that it happened
       so the history is never ambiguous. */
    OriginalWorkflowDefinitionId INT NULL                 -- the version it STARTED on
                      REFERENCES workflow.WORKFLOW_DEFINITION(WorkflowDefinitionId),
    VersionMovedAt    DATETIME2 NULL,                     -- when HR moved it
    VersionMovedBy    INT NULL                            -- who moved it
                      REFERENCES security.[USER](UserId),
    CONSTRAINT CK_ReqInst_Status CHECK ([Status] IN ('Pending','Approved','Rejected','Cancelled'))
);

/* workflow.REQUEST_STEP_INSTANCE
   The chain MATERIALISED for one request: one row per step, created at submit with
   the approver already RESOLVED. Materialising means the approver is fixed at
   submit time - a branch manager who changes mid-approval does not silently take
   over someone else's pending signature.

   [Status]: Pending -> Approved / Rejected / Skipped.
   Skipped happens for two honest reasons, both recorded in SkipReason:
     - the step resolved to the REQUESTER (nobody approves themselves)
     - the step could not resolve at all (e.g. vacant branch-manager post) */
CREATE TABLE workflow.REQUEST_STEP_INSTANCE (
    RequestStepInstanceId INT IDENTITY NOT NULL PRIMARY KEY, -- e.g. 1
    RequestInstanceId INT NOT NULL                           -- the request
                      REFERENCES workflow.REQUEST_INSTANCE(RequestInstanceId) ON DELETE CASCADE,
    StepNo            INT NOT NULL,                          -- 1, 2, 3. e.g. 1
    Name              NVARCHAR(80) NOT NULL,                 -- copied from the step
    ApproverType      VARCHAR(20) NOT NULL,                  -- copied from the step
    ResolvedUserId    INT NULL                               -- the person who must sign
                      REFERENCES security.[USER](UserId),
    ApproverRoleId    INT NULL                               -- for Role steps: anyone with it
                      REFERENCES security.[ROLE](RoleId),
    [Status]          VARCHAR(20) NOT NULL DEFAULT 'Pending',-- Pending/Approved/Rejected/Skipped
    ActedByUserId     INT NULL                               -- who actually signed
                      REFERENCES security.[USER](UserId),
    ActedAt           DATETIME2 NULL,
    Comment           NVARCHAR(300) NULL,                    -- approver's note
    SkipReason        NVARCHAR(200) NULL,                    -- why it was skipped
    CONSTRAINT UQ_ReqStep UNIQUE (RequestInstanceId, StepNo),
    CONSTRAINT CK_ReqStep_Status CHECK ([Status] IN ('Pending','Approved','Rejected','Skipped'))
);

/* workflow.WORKFLOW_SIGNATURE
   APPEND-ONLY history. Every action on every request lands here and nothing ever
   updates or deletes a row. The step table tells you where a request stands now;
   this tells you how it got there - which is what an audit needs. */
CREATE TABLE workflow.WORKFLOW_SIGNATURE (
    SignatureId       INT IDENTITY NOT NULL PRIMARY KEY,  -- e.g. 1
    RequestInstanceId INT NOT NULL                        -- the request
                      REFERENCES workflow.REQUEST_INSTANCE(RequestInstanceId) ON DELETE CASCADE,
    StepNo            INT NULL,                           -- NULL for submit/cancel
    [Action]          VARCHAR(20) NOT NULL,               -- Submitted/Approved/Rejected/Skipped/Cancelled/VersionMoved
    ActedByUserId     INT NULL                            -- NULL when the ENGINE acted (a skip)
                      REFERENCES security.[USER](UserId),
    ActedAt           DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    Comment           NVARCHAR(300) NULL,                 -- reason / note
    CONSTRAINT CK_WfSig_Action CHECK ([Action] IN ('Submitted','Approved','Rejected','Skipped','Cancelled','VersionMoved'))
);
GO

CREATE INDEX IX_ReqInst_Employee ON workflow.REQUEST_INSTANCE (EmployeeId, [Status]);
CREATE INDEX IX_ReqInst_Status   ON workflow.REQUEST_INSTANCE ([Status], SubmittedAt);
CREATE INDEX IX_ReqStep_Pending  ON workflow.REQUEST_STEP_INSTANCE ([Status], ResolvedUserId) INCLUDE (RequestInstanceId, StepNo);
CREATE INDEX IX_WfSig_Request    ON workflow.WORKFLOW_SIGNATURE (RequestInstanceId, ActedAt);
GO

/* ############################################################################
   ========================  APPROVER RESOLUTION  ============================
   ############################################################################ */

/* fn_ResolveApprover
   Turns "what KIND of approver does this step need" into "which USER must sign",
   for one specific request.

   BranchManager - reads the REQUESTER'S branch, then that branch's manager, then
                   that manager's user account. Scoped by construction: a manager
                   of another branch can never be returned.
   SpecificUser  - the named user.
   Role          - returns NULL BY DESIGN. A role step is not one person: any user
                   holding the role may sign it, so the step stores the ROLE and
                   the approve procedure checks membership at signing time.

   Returns NULL when it cannot resolve (vacant manager post, manager has no login).
   The caller treats NULL as "skip this step and say why" - an org-chart gap must
   never block a request, but it must be visible. */
CREATE FUNCTION workflow.fn_ResolveApprover
(
    @ApproverType   VARCHAR(20),
    @ApproverUserId INT,
    @EmployeeId     INT            -- the REQUESTER, for branch-scoped resolution
)
RETURNS INT
AS
BEGIN
    IF @ApproverType = 'SpecificUser'
        RETURN @ApproverUserId;

    IF @ApproverType = 'BranchManager'
    BEGIN
        DECLARE @ManagerUserId INT;
        SELECT @ManagerUserId = mgr.UserId
        FROM hr.EMPLOYEE e
        JOIN hr.BRANCH   b   ON b.BranchId = e.BranchId
        JOIN hr.EMPLOYEE mgr ON mgr.EmployeeId = b.ManagerEmployeeId
        WHERE e.EmployeeId = @EmployeeId
          AND mgr.IsDeleted = 0;
        RETURN @ManagerUserId;              -- NULL if vacant / no login
    END

    RETURN NULL;                            -- 'Role' resolves at signing time
END;
GO

/* ############################################################################
   =====================  DEFINITION CONFIGURATION  ==========================
   Chains are DATA. Build a draft, add steps, publish it. Publishing retires the
   previous Active version; in-flight requests are untouched because they locked
   their own version at submit.
   ############################################################################ */

CREATE PROCEDURE workflow.usp_RequestType_GetAll
AS BEGIN SET NOCOUNT ON;
    SELECT RequestTypeId, Code, Name, [Description], IsActive
    FROM workflow.REQUEST_TYPE ORDER BY Name; END;
GO

CREATE PROCEDURE workflow.usp_RequestType_Upsert
    @Code VARCHAR(30), @Name NVARCHAR(80),
    @Description NVARCHAR(300) = NULL, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM workflow.REQUEST_TYPE WHERE Code = @Code)
        UPDATE workflow.REQUEST_TYPE
        SET Name = @Name, [Description] = @Description, IsActive = @IsActive
        WHERE Code = @Code;
    ELSE
        INSERT INTO workflow.REQUEST_TYPE (Code, Name, [Description], IsActive)
        VALUES (@Code, @Name, @Description, @IsActive);

    SELECT RequestTypeId FROM workflow.REQUEST_TYPE WHERE Code = @Code;
END;
GO

CREATE PROCEDURE workflow.usp_Definition_GetAll
    @RequestTypeId INT = NULL
AS BEGIN SET NOCOUNT ON;
    SELECT d.WorkflowDefinitionId, d.RequestTypeId, rt.Code AS RequestTypeCode,
           rt.Name AS RequestTypeName, d.[Version], d.[Status], d.Notes,
           d.PublishedAt, d.CreatedAt,
           (SELECT COUNT(*) FROM workflow.WORKFLOW_STEP s
            WHERE s.WorkflowDefinitionId = d.WorkflowDefinitionId) AS StepCount
    FROM workflow.WORKFLOW_DEFINITION d
    JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = d.RequestTypeId
    WHERE (@RequestTypeId IS NULL OR d.RequestTypeId = @RequestTypeId)
    ORDER BY rt.Name, d.[Version] DESC; END;
GO

/* Start a NEW draft version for a request type. Version number is auto-assigned,
   so you can never accidentally overwrite a published chain. */
CREATE PROCEDURE workflow.usp_Definition_CreateDraft
    @RequestTypeId INT, @Notes NVARCHAR(300) = NULL, @CreatedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Next INT = ISNULL((SELECT MAX([Version]) FROM workflow.WORKFLOW_DEFINITION
                                WHERE RequestTypeId = @RequestTypeId), 0) + 1;

    INSERT INTO workflow.WORKFLOW_DEFINITION (RequestTypeId, [Version], [Status], Notes, CreatedBy)
    VALUES (@RequestTypeId, @Next, 'Draft', @Notes, @CreatedBy);

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS WorkflowDefinitionId, @Next AS [Version];
END;
GO

/* Add a step to a DRAFT. Published versions are immutable - that is the whole
   point of versioning, so this refuses to touch them. */
CREATE PROCEDURE workflow.usp_Definition_AddStep
    @WorkflowDefinitionId INT,
    @StepNo         INT,
    @Name           NVARCHAR(80),
    @ApproverType   VARCHAR(20),          -- BranchManager / Role / SpecificUser
    @ApproverRoleId INT = NULL,
    @ApproverUserId INT = NULL,
    @IsMandatory    BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM workflow.WORKFLOW_DEFINITION
                   WHERE WorkflowDefinitionId = @WorkflowDefinitionId AND [Status] = 'Draft')
    BEGIN
        RAISERROR('Steps can only be added to a Draft definition. Create a new draft version instead.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM workflow.WORKFLOW_STEP
               WHERE WorkflowDefinitionId = @WorkflowDefinitionId AND StepNo = @StepNo)
        UPDATE workflow.WORKFLOW_STEP
        SET Name = @Name, ApproverType = @ApproverType,
            ApproverRoleId = @ApproverRoleId, ApproverUserId = @ApproverUserId,
            IsMandatory = @IsMandatory
        WHERE WorkflowDefinitionId = @WorkflowDefinitionId AND StepNo = @StepNo;
    ELSE
        INSERT INTO workflow.WORKFLOW_STEP
            (WorkflowDefinitionId, StepNo, Name, ApproverType, ApproverRoleId, ApproverUserId, IsMandatory)
        VALUES (@WorkflowDefinitionId, @StepNo, @Name, @ApproverType, @ApproverRoleId, @ApproverUserId, @IsMandatory);
END;
GO

/* Publish a draft: it becomes the Active chain for its request type and the
   previous Active version is Retired. Requests already in flight keep following
   the version they locked at submit - nothing is migrated, ever. */
CREATE PROCEDURE workflow.usp_Definition_Publish
    @WorkflowDefinitionId INT, @PublishedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @TypeId INT = (SELECT RequestTypeId FROM workflow.WORKFLOW_DEFINITION
                           WHERE WorkflowDefinitionId = @WorkflowDefinitionId AND [Status] = 'Draft');
    IF @TypeId IS NULL
    BEGIN RAISERROR('No Draft definition with that id.', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM workflow.WORKFLOW_STEP WHERE WorkflowDefinitionId = @WorkflowDefinitionId)
    BEGIN RAISERROR('A workflow must have at least one step before it can be published.', 16, 1); RETURN; END

    BEGIN TRAN;

    UPDATE workflow.WORKFLOW_DEFINITION
    SET [Status] = 'Retired'
    WHERE RequestTypeId = @TypeId AND [Status] = 'Active';

    UPDATE workflow.WORKFLOW_DEFINITION
    SET [Status] = 'Active', PublishedAt = SYSUTCDATETIME(), PublishedBy = @PublishedBy
    WHERE WorkflowDefinitionId = @WorkflowDefinitionId;

    COMMIT TRAN;

    SELECT WorkflowDefinitionId, RequestTypeId, [Version], [Status], PublishedAt
    FROM workflow.WORKFLOW_DEFINITION WHERE WorkflowDefinitionId = @WorkflowDefinitionId;
END;
GO

CREATE PROCEDURE workflow.usp_Definition_GetSteps @WorkflowDefinitionId INT
AS BEGIN SET NOCOUNT ON;
    SELECT s.WorkflowStepId, s.StepNo, s.Name, s.ApproverType,
           s.ApproverRoleId, r.Name AS ApproverRoleName,
           s.ApproverUserId, u.Username AS ApproverUsername,
           s.IsMandatory
    FROM workflow.WORKFLOW_STEP s
    LEFT JOIN security.[ROLE] r ON r.RoleId = s.ApproverRoleId
    LEFT JOIN security.[USER] u ON u.UserId = s.ApproverUserId
    WHERE s.WorkflowDefinitionId = @WorkflowDefinitionId
    ORDER BY s.StepNo; END;
GO

/* The chain a NEW request of this type would follow right now. */
CREATE PROCEDURE workflow.usp_Definition_GetActive @RequestTypeCode VARCHAR(30)
AS BEGIN SET NOCOUNT ON;
    SELECT d.WorkflowDefinitionId, d.[Version], d.PublishedAt,
           s.StepNo, s.Name, s.ApproverType, s.ApproverRoleId, s.IsMandatory
    FROM workflow.WORKFLOW_DEFINITION d
    JOIN workflow.REQUEST_TYPE rt   ON rt.RequestTypeId = d.RequestTypeId
    LEFT JOIN workflow.WORKFLOW_STEP s ON s.WorkflowDefinitionId = d.WorkflowDefinitionId
    WHERE rt.Code = @RequestTypeCode AND d.[Status] = 'Active'
    ORDER BY s.StepNo; END;
GO

/* ############################################################################
   =========================  THE REQUEST LIFECYCLE  =========================
   ############################################################################ */

/* SUBMIT
   Locks the ACTIVE version, materialises its steps with approvers already
   resolved, and advances to the first step that actually needs a signature.

   Two kinds of step are auto-skipped, each logged with a reason:
     - it resolved to the REQUESTER (a branch manager's own leave)
     - it could not resolve at all (vacant manager post, manager has no login)
   Skipping keeps requests moving; the SkipReason keeps it honest.

   If EVERY step skips, the request is approved outright - and the signature log
   shows exactly why nobody signed.

   Called by the typed request procedures (leave, exit permission...) after they
   have written their own payload row. Returns RequestInstanceId. */
CREATE PROCEDURE workflow.usp_Request_Submit
    @RequestTypeCode VARCHAR(30),          -- e.g. 'LEAVE'
    @EmployeeId      INT,                  -- WHOSE request
    @RaisedByUserId  INT,                  -- WHO submitted it (may be HR)
    @Title           NVARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @TypeId INT, @DefId INT;
    SELECT @TypeId = rt.RequestTypeId, @DefId = d.WorkflowDefinitionId
    FROM workflow.REQUEST_TYPE rt
    JOIN workflow.WORKFLOW_DEFINITION d
      ON d.RequestTypeId = rt.RequestTypeId AND d.[Status] = 'Active'
    WHERE rt.Code = @RequestTypeCode AND rt.IsActive = 1;

    IF @DefId IS NULL
    BEGIN
        RAISERROR('No active workflow is published for that request type.', 16, 1);
        RETURN;
    END

    /* the requester's own login, so we can detect self-approval */
    DECLARE @RequesterUserId INT =
        (SELECT UserId FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId);

    DECLARE @ReqId INT;

    BEGIN TRAN;

    INSERT INTO workflow.REQUEST_INSTANCE
        (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title)
    VALUES (@TypeId, @DefId, @EmployeeId, @RaisedByUserId, 'Pending', @Title);

    SET @ReqId = CAST(SCOPE_IDENTITY() AS INT);

    /* materialise the chain, resolving each approver now */
    INSERT INTO workflow.REQUEST_STEP_INSTANCE
        (RequestInstanceId, StepNo, Name, ApproverType, ResolvedUserId, ApproverRoleId, [Status], SkipReason)
    SELECT
        @ReqId, s.StepNo, s.Name, s.ApproverType,
        workflow.fn_ResolveApprover(s.ApproverType, s.ApproverUserId, @EmployeeId),
        s.ApproverRoleId,
        CASE
            /* nobody approves their own request */
            WHEN workflow.fn_ResolveApprover(s.ApproverType, s.ApproverUserId, @EmployeeId) IS NOT NULL
             AND workflow.fn_ResolveApprover(s.ApproverType, s.ApproverUserId, @EmployeeId) = @RequesterUserId
                THEN 'Skipped'
            /* a non-Role step that resolved to nobody */
            WHEN s.ApproverType <> 'Role'
             AND workflow.fn_ResolveApprover(s.ApproverType, s.ApproverUserId, @EmployeeId) IS NULL
                THEN 'Skipped'
            ELSE 'Pending'
        END,
        CASE
            WHEN workflow.fn_ResolveApprover(s.ApproverType, s.ApproverUserId, @EmployeeId) IS NOT NULL
             AND workflow.fn_ResolveApprover(s.ApproverType, s.ApproverUserId, @EmployeeId) = @RequesterUserId
                THEN 'Approver is the requester - nobody approves their own request.'
            WHEN s.ApproverType <> 'Role'
             AND workflow.fn_ResolveApprover(s.ApproverType, s.ApproverUserId, @EmployeeId) IS NULL
                THEN 'No approver could be resolved (post vacant or no login).'
            ELSE NULL
        END
    FROM workflow.WORKFLOW_STEP s
    WHERE s.WorkflowDefinitionId = @DefId;

    /* log the auto-skips: the engine acted, so ActedByUserId is NULL */
    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    SELECT @ReqId, StepNo, 'Skipped', NULL, SkipReason
    FROM workflow.REQUEST_STEP_INSTANCE
    WHERE RequestInstanceId = @ReqId AND [Status] = 'Skipped';

    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    VALUES (@ReqId, NULL, 'Submitted', @RaisedByUserId,
            CASE WHEN @RaisedByUserId = @RequesterUserId OR @RequesterUserId IS NULL
                 THEN NULL ELSE 'Raised on the employee''s behalf.' END);

    /* advance to the first step still needing a signature */
    DECLARE @NextStep INT = (SELECT MIN(StepNo) FROM workflow.REQUEST_STEP_INSTANCE
                             WHERE RequestInstanceId = @ReqId AND [Status] = 'Pending');

    IF @NextStep IS NULL
        UPDATE workflow.REQUEST_INSTANCE
        SET [Status] = 'Approved', CurrentStepNo = NULL, ClosedAt = SYSUTCDATETIME(),
            ClosedReason = 'Approved automatically: every step was skipped.'
        WHERE RequestInstanceId = @ReqId;
    ELSE
        UPDATE workflow.REQUEST_INSTANCE
        SET CurrentStepNo = @NextStep
        WHERE RequestInstanceId = @ReqId;

    COMMIT TRAN;

    SELECT r.RequestInstanceId, r.[Status], r.CurrentStepNo, r.WorkflowDefinitionId,
           d.[Version] AS WorkflowVersion
    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.WORKFLOW_DEFINITION d ON d.WorkflowDefinitionId = r.WorkflowDefinitionId
    WHERE r.RequestInstanceId = @ReqId;
END;
GO

/* APPROVE the current step.
   Authorisation is checked HERE, not in the API, so it cannot be bypassed:
     - a resolved-user step (BranchManager / SpecificUser) may only be signed by
       that exact user
     - a Role step may be signed by any ACTIVE user holding that role
   Approving the last step approves the request. */
CREATE PROCEDURE workflow.usp_Request_Approve
    @RequestInstanceId INT,
    @ActedByUserId     INT,
    @Comment           NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Step INT, @ReqStatus VARCHAR(20);
    SELECT @Step = CurrentStepNo, @ReqStatus = [Status]
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;

    IF @ReqStatus <> 'Pending'
    BEGIN RAISERROR('This request is already closed.', 16, 1); RETURN; END

    DECLARE @Resolved INT, @RoleId INT, @Type VARCHAR(20);
    SELECT @Resolved = ResolvedUserId, @RoleId = ApproverRoleId, @Type = ApproverType
    FROM workflow.REQUEST_STEP_INSTANCE
    WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @Step;

    /* may this user sign THIS step? */
    DECLARE @Allowed BIT = 0;
    IF @Type = 'Role'
    BEGIN
        IF EXISTS (SELECT 1 FROM security.USER_ROLE ur
                   JOIN security.[USER] u ON u.UserId = ur.UserId
                   WHERE ur.UserId = @ActedByUserId AND ur.RoleId = @RoleId AND u.IsActive = 1)
            SET @Allowed = 1;
    END
    ELSE IF @Resolved IS NOT NULL AND @Resolved = @ActedByUserId
        SET @Allowed = 1;

    IF @Allowed = 0
    BEGIN RAISERROR('You are not the approver for this step.', 16, 1); RETURN; END

    BEGIN TRAN;

    UPDATE workflow.REQUEST_STEP_INSTANCE
    SET [Status] = 'Approved', ActedByUserId = @ActedByUserId,
        ActedAt = SYSUTCDATETIME(), Comment = @Comment
    WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @Step;

    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    VALUES (@RequestInstanceId, @Step, 'Approved', @ActedByUserId, @Comment);

    DECLARE @NextStep INT = (SELECT MIN(StepNo) FROM workflow.REQUEST_STEP_INSTANCE
                             WHERE RequestInstanceId = @RequestInstanceId AND [Status] = 'Pending');

    IF @NextStep IS NULL
        UPDATE workflow.REQUEST_INSTANCE
        SET [Status] = 'Approved', CurrentStepNo = NULL, ClosedAt = SYSUTCDATETIME()
        WHERE RequestInstanceId = @RequestInstanceId;
    ELSE
        UPDATE workflow.REQUEST_INSTANCE
        SET CurrentStepNo = @NextStep
        WHERE RequestInstanceId = @RequestInstanceId;

    COMMIT TRAN;

    SELECT RequestInstanceId, [Status], CurrentStepNo
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;
END;
GO

/* REJECT at the current step. One rejection ends the request - later approvers
   are never asked. The reason is mandatory: a rejection with no explanation is
   useless to the person who raised it. */
CREATE PROCEDURE workflow.usp_Request_Reject
    @RequestInstanceId INT,
    @ActedByUserId     INT,
    @Reason            NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = ''
    BEGIN RAISERROR('A rejection reason is required.', 16, 1); RETURN; END

    DECLARE @Step INT, @ReqStatus VARCHAR(20);
    SELECT @Step = CurrentStepNo, @ReqStatus = [Status]
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;

    IF @ReqStatus <> 'Pending'
    BEGIN RAISERROR('This request is already closed.', 16, 1); RETURN; END

    DECLARE @Resolved INT, @RoleId INT, @Type VARCHAR(20);
    SELECT @Resolved = ResolvedUserId, @RoleId = ApproverRoleId, @Type = ApproverType
    FROM workflow.REQUEST_STEP_INSTANCE
    WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @Step;

    DECLARE @Allowed BIT = 0;
    IF @Type = 'Role'
    BEGIN
        IF EXISTS (SELECT 1 FROM security.USER_ROLE ur
                   JOIN security.[USER] u ON u.UserId = ur.UserId
                   WHERE ur.UserId = @ActedByUserId AND ur.RoleId = @RoleId AND u.IsActive = 1)
            SET @Allowed = 1;
    END
    ELSE IF @Resolved IS NOT NULL AND @Resolved = @ActedByUserId
        SET @Allowed = 1;

    IF @Allowed = 0
    BEGIN RAISERROR('You are not the approver for this step.', 16, 1); RETURN; END

    BEGIN TRAN;

    UPDATE workflow.REQUEST_STEP_INSTANCE
    SET [Status] = 'Rejected', ActedByUserId = @ActedByUserId,
        ActedAt = SYSUTCDATETIME(), Comment = @Reason
    WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @Step;

    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    VALUES (@RequestInstanceId, @Step, 'Rejected', @ActedByUserId, @Reason);

    UPDATE workflow.REQUEST_INSTANCE
    SET [Status] = 'Rejected', CurrentStepNo = NULL,
        ClosedAt = SYSUTCDATETIME(), ClosedReason = @Reason
    WHERE RequestInstanceId = @RequestInstanceId;

    COMMIT TRAN;

    SELECT RequestInstanceId, [Status], ClosedReason
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;
END;
GO

/* CANCEL a pending request.
   This is also the CHANGE-OF-CHAIN path: workflows are never migrated, so when a
   new version must apply to something in flight, HR cancels it here and it is
   raised again on the new chain. Two clean records, one clear story.
   Allowed for the requester, whoever raised it, or HR (the API gates that). */
CREATE PROCEDURE workflow.usp_Request_Cancel
    @RequestInstanceId INT,
    @ActedByUserId     INT,
    @Reason            NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = ''
    BEGIN RAISERROR('A cancellation reason is required.', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE
                   WHERE RequestInstanceId = @RequestInstanceId AND [Status] = 'Pending')
    BEGIN RAISERROR('Only a pending request can be cancelled.', 16, 1); RETURN; END

    BEGIN TRAN;

    UPDATE workflow.REQUEST_INSTANCE
    SET [Status] = 'Cancelled', CurrentStepNo = NULL,
        ClosedAt = SYSUTCDATETIME(), ClosedReason = @Reason
    WHERE RequestInstanceId = @RequestInstanceId;

    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    VALUES (@RequestInstanceId, NULL, 'Cancelled', @ActedByUserId, @Reason);

    COMMIT TRAN;

    SELECT RequestInstanceId, [Status], ClosedReason
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;
END;
GO

/* ############################################################################
   ==============================  READS  ====================================
   ############################################################################ */

/* One request in full: the header, its materialised chain, and the signature log.
   Three result sets - the detail view reads all three. */
CREATE PROCEDURE workflow.usp_Request_GetById @RequestInstanceId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT r.RequestInstanceId, r.RequestTypeId, rt.Code AS RequestTypeCode,
           rt.Name AS RequestTypeName, r.EmployeeId, e.FullName AS EmployeeName,
           b.Name AS BranchName, r.RaisedByUserId, ru.Username AS RaisedByUsername,
           CASE WHEN r.RaisedByUserId <> ISNULL(e.UserId, -1)
                THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS RaisedOnBehalf,
           r.[Status], r.CurrentStepNo, r.Title, r.SubmittedAt, r.ClosedAt, r.ClosedReason,
           d.[Version] AS WorkflowVersion
    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.REQUEST_TYPE rt        ON rt.RequestTypeId = r.RequestTypeId
    JOIN workflow.WORKFLOW_DEFINITION d  ON d.WorkflowDefinitionId = r.WorkflowDefinitionId
    JOIN hr.EMPLOYEE e                   ON e.EmployeeId = r.EmployeeId
    JOIN hr.BRANCH b                     ON b.BranchId = e.BranchId
    JOIN security.[USER] ru              ON ru.UserId = r.RaisedByUserId
    WHERE r.RequestInstanceId = @RequestInstanceId;

    SELECT si.StepNo, si.Name, si.ApproverType,
           si.ResolvedUserId, ru.Username AS ResolvedUsername,
           si.ApproverRoleId, ro.Name AS ApproverRoleName,
           si.[Status], si.ActedByUserId, au.Username AS ActedByUsername,
           si.ActedAt, si.Comment, si.SkipReason
    FROM workflow.REQUEST_STEP_INSTANCE si
    LEFT JOIN security.[USER] ru ON ru.UserId = si.ResolvedUserId
    LEFT JOIN security.[USER] au ON au.UserId = si.ActedByUserId
    LEFT JOIN security.[ROLE] ro ON ro.RoleId = si.ApproverRoleId
    WHERE si.RequestInstanceId = @RequestInstanceId
    ORDER BY si.StepNo;

    SELECT sg.SignatureId, sg.StepNo, sg.[Action], sg.ActedByUserId,
           u.Username AS ActedByUsername, sg.ActedAt, sg.Comment
    FROM workflow.WORKFLOW_SIGNATURE sg
    LEFT JOIN security.[USER] u ON u.UserId = sg.ActedByUserId
    WHERE sg.RequestInstanceId = @RequestInstanceId
    ORDER BY sg.ActedAt, sg.SignatureId;
END;
GO

/* "My requests" - everything raised FOR one employee. */
CREATE PROCEDURE workflow.usp_Request_GetForEmployee
    @EmployeeId INT, @Status VARCHAR(20) = NULL
AS BEGIN SET NOCOUNT ON;
    SELECT r.RequestInstanceId, rt.Code AS RequestTypeCode, rt.Name AS RequestTypeName,
           r.Title, r.[Status], r.CurrentStepNo,
           si.Name AS CurrentStepName, r.SubmittedAt, r.ClosedAt, r.ClosedReason
    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = r.RequestTypeId
    LEFT JOIN workflow.REQUEST_STEP_INSTANCE si
           ON si.RequestInstanceId = r.RequestInstanceId AND si.StepNo = r.CurrentStepNo
    WHERE r.EmployeeId = @EmployeeId
      AND (@Status IS NULL OR r.[Status] = @Status)
    ORDER BY r.SubmittedAt DESC; END;
GO

/* THE APPROVAL INBOX - everything waiting on ONE user right now.
   Two ways a request can be waiting on you: the step resolved to you personally,
   or the step is a Role step and you hold that role. */
CREATE PROCEDURE workflow.usp_Request_GetPendingForUser @UserId INT
AS BEGIN SET NOCOUNT ON;
    SELECT r.RequestInstanceId, rt.Code AS RequestTypeCode, rt.Name AS RequestTypeName,
           r.EmployeeId, e.FullName AS EmployeeName, b.Name AS BranchName,
           r.Title, si.StepNo, si.Name AS StepName, si.ApproverType,
           r.SubmittedAt,
           DATEDIFF(DAY, r.SubmittedAt, SYSUTCDATETIME()) AS DaysWaiting
    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.REQUEST_STEP_INSTANCE si
      ON si.RequestInstanceId = r.RequestInstanceId
     AND si.StepNo = r.CurrentStepNo
     AND si.[Status] = 'Pending'
    JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = r.RequestTypeId
    JOIN hr.EMPLOYEE e            ON e.EmployeeId = r.EmployeeId
    JOIN hr.BRANCH b              ON b.BranchId = e.BranchId
    WHERE r.[Status] = 'Pending'
      AND (
            si.ResolvedUserId = @UserId
            OR (si.ApproverType = 'Role'
                AND EXISTS (SELECT 1 FROM security.USER_ROLE ur
                            WHERE ur.UserId = @UserId AND ur.RoleId = si.ApproverRoleId))
          )
    ORDER BY r.SubmittedAt; END;
GO


/* ############################################################################
   ====================  VERSION MOVES (HR-DECIDED)  =========================
   Publishing a new chain does NOT touch requests already in flight. These two
   procedures let HR see what is still on an older chain and move individual
   requests onto the newer one, deliberately.
   ############################################################################ */

/* Pending requests whose locked version is no longer the Active one.
   This is the list HR is shown after publishing a new chain: "12 pending requests
   are still on v1 - move any of them to v2?" */
CREATE PROCEDURE workflow.usp_Request_GetOnOldVersions
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
    JOIN workflow.WORKFLOW_DEFINITION act  ON act.RequestTypeId = r.RequestTypeId
                                          AND act.[Status] = 'Active'
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

/* MOVE ONE PENDING REQUEST ONTO A NEWER CHAIN.  HR-triggered, never automatic.

   THE RULES - stated plainly, because this is where approval systems get subtly
   wrong and someone ends up paid or absent on a signature that never happened:

     1. A step already ACTED ON (Approved / Rejected / Skipped) is UNTOUCHABLE.
        Its signature stays exactly as it was and its approver is never re-asked.

     2. Everything NOT yet acted on is DISCARDED and rebuilt from the new chain.
        The request continues from the first new step that comes AFTER the highest
        step number it has already completed.

     3. A step that the new chain inserts BEFORE the point already reached is
        recorded as SKIPPED with the reason "added after this point had already
        passed" - it is NOT run retroactively. Going backwards would mean asking
        someone to approve something that already moved past them.

     4. Approvers on the new steps are resolved NOW, using the same rules as
        submit: nobody approves their own request, and an unresolvable approver
        (vacant post) is skipped and logged rather than blocking the request.

     5. If nothing is left to sign after the move, the request is approved and the
        log says why.

   Both versions are stored on the request (OriginalWorkflowDefinitionId keeps the
   one it started on) and a VersionMoved signature records who moved it and why.
   A reason is REQUIRED: moving a live request changes who must sign it. */
CREATE PROCEDURE workflow.usp_Request_MoveToVersion
    @RequestInstanceId       INT,
    @TargetWorkflowDefinitionId INT = NULL,   -- NULL = the currently Active version
    @ActedByUserId           INT,
    @Reason                  NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = ''
    BEGIN RAISERROR('A reason is required when moving a request to another workflow version.', 16, 1); RETURN; END

    DECLARE @TypeId INT, @EmployeeId INT, @CurDefId INT, @ReqStatus VARCHAR(20);
    SELECT @TypeId = RequestTypeId, @EmployeeId = EmployeeId,
           @CurDefId = WorkflowDefinitionId, @ReqStatus = [Status]
    FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId;

    IF @ReqStatus IS NULL
    BEGIN RAISERROR('Request not found.', 16, 1); RETURN; END
    IF @ReqStatus <> 'Pending'
    BEGIN RAISERROR('Only a pending request can be moved to another version.', 16, 1); RETURN; END

    /* default target = the active chain for this request type */
    IF @TargetWorkflowDefinitionId IS NULL
        SELECT @TargetWorkflowDefinitionId = WorkflowDefinitionId
        FROM workflow.WORKFLOW_DEFINITION
        WHERE RequestTypeId = @TypeId AND [Status] = 'Active';

    IF @TargetWorkflowDefinitionId IS NULL
    BEGIN RAISERROR('No active workflow version to move to.', 16, 1); RETURN; END

    IF @TargetWorkflowDefinitionId = @CurDefId
    BEGIN RAISERROR('The request is already on that version.', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM workflow.WORKFLOW_DEFINITION
                   WHERE WorkflowDefinitionId = @TargetWorkflowDefinitionId
                     AND RequestTypeId = @TypeId)
    BEGIN RAISERROR('That version belongs to a different request type.', 16, 1); RETURN; END

    DECLARE @RequesterUserId INT = (SELECT UserId FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId);

    /* how far the request has actually got: the highest step already acted on */
    DECLARE @HighestDone INT = ISNULL((
        SELECT MAX(StepNo) FROM workflow.REQUEST_STEP_INSTANCE
        WHERE RequestInstanceId = @RequestInstanceId
          AND [Status] IN ('Approved','Rejected','Skipped')), 0);

    BEGIN TRAN;

    /* RULE 2 - discard only what has NOT been acted on */
    DELETE FROM workflow.REQUEST_STEP_INSTANCE
    WHERE RequestInstanceId = @RequestInstanceId
      AND [Status] = 'Pending';

    /* rebuild from the target chain, skipping any step numbers already passed */
    INSERT INTO workflow.REQUEST_STEP_INSTANCE
        (RequestInstanceId, StepNo, Name, ApproverType, ResolvedUserId, ApproverRoleId, [Status], SkipReason)
    SELECT
        @RequestInstanceId, s.StepNo, s.Name, s.ApproverType,
        workflow.fn_ResolveApprover(s.ApproverType, s.ApproverUserId, @EmployeeId),
        s.ApproverRoleId,
        CASE
            /* RULE 3 - the new chain inserts this before where we already are */
            WHEN s.StepNo <= @HighestDone THEN 'Skipped'
            /* RULE 4 - nobody approves their own request */
            WHEN workflow.fn_ResolveApprover(s.ApproverType, s.ApproverUserId, @EmployeeId) IS NOT NULL
             AND workflow.fn_ResolveApprover(s.ApproverType, s.ApproverUserId, @EmployeeId) = @RequesterUserId
                THEN 'Skipped'
            WHEN s.ApproverType <> 'Role'
             AND workflow.fn_ResolveApprover(s.ApproverType, s.ApproverUserId, @EmployeeId) IS NULL
                THEN 'Skipped'
            ELSE 'Pending'
        END,
        CASE
            WHEN s.StepNo <= @HighestDone
                THEN 'Added by a later workflow version, after this point had already passed.'
            WHEN workflow.fn_ResolveApprover(s.ApproverType, s.ApproverUserId, @EmployeeId) IS NOT NULL
             AND workflow.fn_ResolveApprover(s.ApproverType, s.ApproverUserId, @EmployeeId) = @RequesterUserId
                THEN 'Approver is the requester - nobody approves their own request.'
            WHEN s.ApproverType <> 'Role'
             AND workflow.fn_ResolveApprover(s.ApproverType, s.ApproverUserId, @EmployeeId) IS NULL
                THEN 'No approver could be resolved (post vacant or no login).'
            ELSE NULL
        END
    FROM workflow.WORKFLOW_STEP s
    WHERE s.WorkflowDefinitionId = @TargetWorkflowDefinitionId
      /* RULE 1 - never overwrite a step that was already acted on */
      AND NOT EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE si
                      WHERE si.RequestInstanceId = @RequestInstanceId
                        AND si.StepNo = s.StepNo);

    /* record the move itself */
    DECLARE @FromVer INT = (SELECT [Version] FROM workflow.WORKFLOW_DEFINITION WHERE WorkflowDefinitionId = @CurDefId);
    DECLARE @ToVer   INT = (SELECT [Version] FROM workflow.WORKFLOW_DEFINITION WHERE WorkflowDefinitionId = @TargetWorkflowDefinitionId);

    UPDATE workflow.REQUEST_INSTANCE
    SET OriginalWorkflowDefinitionId = ISNULL(OriginalWorkflowDefinitionId, @CurDefId),
        WorkflowDefinitionId = @TargetWorkflowDefinitionId,
        VersionMovedAt = SYSUTCDATETIME(),
        VersionMovedBy = @ActedByUserId
    WHERE RequestInstanceId = @RequestInstanceId;

    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    VALUES (@RequestInstanceId, NULL, 'VersionMoved', @ActedByUserId,
            CONCAT('Moved from version ', @FromVer, ' to version ', @ToVer, '. ', @Reason));

    /* log any steps the move itself skipped */
    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment)
    SELECT @RequestInstanceId, StepNo, 'Skipped', NULL, SkipReason
    FROM workflow.REQUEST_STEP_INSTANCE
    WHERE RequestInstanceId = @RequestInstanceId
      AND [Status] = 'Skipped'
      AND ActedAt IS NULL
      AND NOT EXISTS (SELECT 1 FROM workflow.WORKFLOW_SIGNATURE g
                      WHERE g.RequestInstanceId = @RequestInstanceId
                        AND g.StepNo = workflow.REQUEST_STEP_INSTANCE.StepNo
                        AND g.[Action] = 'Skipped');

    /* RULE 5 - where does it stand now? */
    DECLARE @NextStep INT = (SELECT MIN(StepNo) FROM workflow.REQUEST_STEP_INSTANCE
                             WHERE RequestInstanceId = @RequestInstanceId AND [Status] = 'Pending');

    IF @NextStep IS NULL
        UPDATE workflow.REQUEST_INSTANCE
        SET [Status] = 'Approved', CurrentStepNo = NULL, ClosedAt = SYSUTCDATETIME(),
            ClosedReason = 'Approved automatically: no steps remained after moving to the new workflow version.'
        WHERE RequestInstanceId = @RequestInstanceId;
    ELSE
        UPDATE workflow.REQUEST_INSTANCE
        SET CurrentStepNo = @NextStep
        WHERE RequestInstanceId = @RequestInstanceId;

    COMMIT TRAN;

    SELECT r.RequestInstanceId, r.[Status], r.CurrentStepNo,
           @FromVer AS MovedFromVersion, @ToVer AS MovedToVersion,
           r.VersionMovedAt, r.VersionMovedBy
    FROM workflow.REQUEST_INSTANCE r
    WHERE r.RequestInstanceId = @RequestInstanceId;
END;
GO

/* ============================================================================
   END OF CORE ENGINE.
   6 tables | 1 function | 17 procedures.
   Next: the request TYPES and their payload tables, once the paths are decided.
   ============================================================================ */
