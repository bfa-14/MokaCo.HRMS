/* ============================================================================
   EXIT PERMISSION  -  first typed request  (runs after workflow_core.sql)
   MokaCo_HRMS
   ----------------------------------------------------------------------------
   A short leave of an hour or two during the working day. This is the request
   type that closes the loop with attendance: attendance already carries
   ExitApprovedMinutes and an ExitPermissionId slot waiting for this table.

   =============================== THE LINK ==================================
   ONE direction only: attendance.ATTENDANCE_RECORD.ExitPermissionId points at the
   permission. The permission does NOT store an AttendanceId - a two-way link can
   disagree with itself, and there is nothing to point at when the permission is
   approved BEFORE the day happens.

   Which leads to the timing problem, and the two paths that solve it:

     FORWARD  (the normal case) - approved days before the exit. No attendance
              record exists yet, so nothing can be linked. The permission waits.
              When the day is eventually processed, usp_ExitPermission_ApplyToAttendance
              finds it and applies it. The nightly job runs this after the processor.

     RETROACTIVE (the sudden exit) - the day already happened and HR approves after
              the fact. The record exists, so the same procedure applies it at once.

   The SAME procedure covers both, and it is idempotent: AppliedToAttendanceAt
   marks what has already been applied, so re-running changes nothing.

   ============================ LEAVE DEDUCTION ==============================
   ConvertToLeave says whether this exit is FUNDED FROM ANNUAL LEAVE (1) or is a
   plain salary matter (0). It does NOT decide how many minutes come off - that is
   attendance's ExitLeaveMinutes, which defaults to the ACTUAL minutes observed
   (core.SETTING.ExitLeaveBasis) and which HR can override per day.

   The actual LEAVE_LEDGER posting therefore happens at PERIOD CLOSE, not at
   approval - by then HR has dispositioned any variance and the final deducted
   figure is known. Posting at approval time would use the approved minutes and
   contradict the "deduct what actually happened" default.
   ============================================================================ */
USE MokaCo_HRMS;
GO

DROP PROCEDURE IF EXISTS workflow.usp_ExitPermission_PostLeaveUsage;
DROP PROCEDURE IF EXISTS workflow.usp_ExitPermission_ApplyToAttendance;
DROP PROCEDURE IF EXISTS workflow.usp_ExitPermission_GetPendingApplication;
DROP PROCEDURE IF EXISTS workflow.usp_ExitPermission_GetForEmployee;
DROP PROCEDURE IF EXISTS workflow.usp_ExitPermission_GetByRequest;
DROP PROCEDURE IF EXISTS workflow.usp_ExitPermission_Create;
GO

/* the attendance FK can only exist once this table does - drop it before we drop the table */
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Attendance_ExitPermission')
    ALTER TABLE attendance.ATTENDANCE_RECORD DROP CONSTRAINT FK_Attendance_ExitPermission;
GO
DROP TABLE IF EXISTS workflow.EXIT_PERMISSION;
GO

/* workflow.EXIT_PERMISSION
   The PAYLOAD of one exit-permission request. The approval chain, its state and
   its history all live in the engine tables; this holds only what is specific to
   an exit permission. One row per request instance. */
CREATE TABLE workflow.EXIT_PERMISSION (
    ExitPermissionId  INT IDENTITY NOT NULL PRIMARY KEY,   -- e.g. 1
    RequestInstanceId INT NOT NULL UNIQUE                  -- the request in the engine. e.g. 7
                      REFERENCES workflow.REQUEST_INSTANCE(RequestInstanceId) ON DELETE CASCADE,
    EmployeeId        INT NOT NULL                         -- whose exit. e.g. 10 (Rami)
                      REFERENCES hr.EMPLOYEE(EmployeeId),
    ExitDate          DATE NOT NULL,                       -- the working day. e.g. '2026-07-14'
    FromTime          TIME NOT NULL,                       -- leaving at. e.g. '12:00'
    ToTime            TIME NOT NULL,                       -- back at. e.g. '14:00'
    Minutes           INT  NOT NULL,                       -- ToTime - FromTime. e.g. 120
    Reason            NVARCHAR(300) NOT NULL,              -- required. e.g. 'Doctor appointment'
    /* 1 = funded from annual leave; 0 = not a leave matter (salary/unpaid handling).
       This does NOT set HOW MANY minutes are deducted - see the header. */
    ConvertToLeave    BIT NOT NULL DEFAULT 1,              -- e.g. 1
    /* set once the approval has been pushed into the attendance record. NULL means
       still waiting - usually because the day has not been processed yet. */
    AppliedToAttendanceAt DATETIME2 NULL,                  -- e.g. '2026-07-15T01:05:00'
    CreatedAt         DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT CK_ExitPerm_Times   CHECK (ToTime > FromTime),
    CONSTRAINT CK_ExitPerm_Minutes CHECK (Minutes > 0)
);
GO

CREATE INDEX IX_ExitPerm_EmpDate ON workflow.EXIT_PERMISSION (EmployeeId, ExitDate);
CREATE INDEX IX_ExitPerm_Pending ON workflow.EXIT_PERMISSION (AppliedToAttendanceAt) INCLUDE (EmployeeId, ExitDate);
GO

/* now attendance can point at it */
ALTER TABLE attendance.ATTENDANCE_RECORD
    ADD CONSTRAINT FK_Attendance_ExitPermission
    FOREIGN KEY (ExitPermissionId) REFERENCES workflow.EXIT_PERMISSION(ExitPermissionId);
GO

/* register the request type (idempotent) */
EXEC workflow.usp_RequestType_Upsert
     @Code = 'EXIT_PERMISSION',
     @Name = N'Exit permission',
     @Description = N'Permission to leave during the working day for an hour or two and return.';
GO

/* ############################################################################
   ===========================  RAISE A REQUEST  =============================
   ############################################################################ */

/* Create an exit permission and submit it into the workflow.
   Writes the payload, then calls the engine, which locks the active chain version
   and resolves the approvers. Both happen in ONE transaction: a payload with no
   request, or a request with no payload, would be a broken record.

   @RaisedByUserId is who typed it - the employee's own account normally, or HR
   raising on someone's behalf. The engine records the difference. */
CREATE PROCEDURE workflow.usp_ExitPermission_Create
    @EmployeeId     INT,
    @RaisedByUserId INT,
    @ExitDate       DATE,
    @FromTime       TIME,
    @ToTime         TIME,
    @Reason         NVARCHAR(300),
    @ConvertToLeave BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ToTime <= @FromTime
    BEGIN RAISERROR('The return time must be after the leaving time.', 16, 1); RETURN; END

    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = ''
    BEGIN RAISERROR('A reason is required for an exit permission.', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId AND IsDeleted = 0)
    BEGIN RAISERROR('Employee not found.', 16, 1); RETURN; END

    DECLARE @Minutes INT = DATEDIFF(MINUTE, @FromTime, @ToTime);

    /* one pending permission per employee per day - two overlapping approvals for
       the same day cannot both be applied to a single attendance record */
    IF EXISTS (
        SELECT 1
        FROM workflow.EXIT_PERMISSION ep
        JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
        WHERE ep.EmployeeId = @EmployeeId
          AND ep.ExitDate   = @ExitDate
          AND r.[Status] IN ('Pending','Approved'))
    BEGIN
        RAISERROR('This employee already has a pending or approved exit permission for that date.', 16, 1);
        RETURN;
    END

    DECLARE @Title NVARCHAR(150) =
        CONCAT(N'Exit permission ', CONVERT(CHAR(10), @ExitDate, 23), N' ',
               LEFT(CONVERT(VARCHAR(8), @FromTime, 108), 5), N'-',
               LEFT(CONVERT(VARCHAR(8), @ToTime, 108), 5),
               N' (', @Minutes, N' min)');

    DECLARE @Submitted TABLE (RequestInstanceId INT, [Status] VARCHAR(20),
                              CurrentStepNo INT, WorkflowDefinitionId INT, WorkflowVersion INT);

    BEGIN TRAN;

    INSERT INTO @Submitted
    EXEC workflow.usp_Request_Submit
         @RequestTypeCode = 'EXIT_PERMISSION',
         @EmployeeId      = @EmployeeId,
         @RaisedByUserId  = @RaisedByUserId,
         @Title           = @Title;

    DECLARE @ReqId INT = (SELECT TOP 1 RequestInstanceId FROM @Submitted);

    IF @ReqId IS NULL
    BEGIN
        ROLLBACK TRAN;
        RAISERROR('The request could not be submitted - check that an EXIT_PERMISSION workflow is published.', 16, 1);
        RETURN;
    END

    INSERT INTO workflow.EXIT_PERMISSION
        (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime, Minutes, Reason, ConvertToLeave)
    VALUES (@ReqId, @EmployeeId, @ExitDate, @FromTime, @ToTime, @Minutes, @Reason, @ConvertToLeave);

    DECLARE @NewId INT = CAST(SCOPE_IDENTITY() AS INT);

    COMMIT TRAN;

    /* if every step skipped, the engine already approved it - apply it now */
    IF EXISTS (SELECT 1 FROM @Submitted WHERE [Status] = 'Approved')
        EXEC workflow.usp_ExitPermission_ApplyToAttendance @ExitPermissionId = @NewId;

    SELECT ep.ExitPermissionId, ep.RequestInstanceId, ep.EmployeeId, ep.ExitDate,
           ep.FromTime, ep.ToTime, ep.Minutes, ep.ConvertToLeave,
           r.[Status], r.CurrentStepNo, r.Title
    FROM workflow.EXIT_PERMISSION ep
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
    WHERE ep.ExitPermissionId = @NewId;
END;
GO

/* ############################################################################
   =====================  APPLY APPROVAL TO ATTENDANCE  ======================
   ############################################################################ */

/* Push APPROVED permissions into the attendance record for their day.

   Handles both timings with one piece of logic:
     - the day already has a record -> apply now
     - it does not (the exit is in the future, or the day is unprocessed) -> leave
       it alone; the next run picks it up once the record exists

   Call it three ways:
     @ExitPermissionId - one permission, straight after its final approval
     @WorkDate         - everything for one day, from the nightly job after the processor
     neither           - sweep every approved-but-unapplied permission

   IDEMPOTENT: AppliedToAttendanceAt is the guard, so re-running is harmless.

   It sets ExitApprovedMinutes via usp_Attendance_SetExitApproval, which keeps
   approved and actual INDEPENDENT and recomputes the variance. @AlsoSetActual = 1
   is passed ONLY when the punches show no gap at all - that is the "approved but
   never punched out" case, where the permission is the only evidence the person
   was away. Where punches DO show a gap, the observed minutes are never
   overwritten. */
CREATE PROCEDURE workflow.usp_ExitPermission_ApplyToAttendance
    @ExitPermissionId INT  = NULL,
    @WorkDate         DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Applied INT = 0;

    DECLARE @Id INT, @AttId BIGINT, @Mins INT, @ActualMins INT;

    DECLARE ep_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT ep.ExitPermissionId, a.AttendanceId, ep.Minutes, a.ExitActualMinutes
        FROM workflow.EXIT_PERMISSION ep
        JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
        JOIN attendance.ATTENDANCE_RECORD a
          ON a.EmployeeId = ep.EmployeeId AND a.WorkDate = ep.ExitDate
        WHERE r.[Status] = 'Approved'
          AND ep.AppliedToAttendanceAt IS NULL
          AND (@ExitPermissionId IS NULL OR ep.ExitPermissionId = @ExitPermissionId)
          AND (@WorkDate         IS NULL OR ep.ExitDate         = @WorkDate);

    OPEN ep_cur;
    FETCH NEXT FROM ep_cur INTO @Id, @AttId, @Mins, @ActualMins;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        /* only claim the actual when the machine saw nothing */
        DECLARE @AlsoSetActual BIT = CASE WHEN ISNULL(@ActualMins, 0) = 0 THEN 1 ELSE 0 END;

        EXEC attendance.usp_Attendance_SetExitApproval
             @AttendanceId        = @AttId,
             @ExitApprovedMinutes = @Mins,
             @ExitPermissionId    = @Id,
             @AlsoSetActual       = @AlsoSetActual,
             @HrNote              = N'Applied from approved exit permission.';

        UPDATE workflow.EXIT_PERMISSION
        SET AppliedToAttendanceAt = SYSUTCDATETIME()
        WHERE ExitPermissionId = @Id;

        SET @Applied = @Applied + 1;
        FETCH NEXT FROM ep_cur INTO @Id, @AttId, @Mins, @ActualMins;
    END

    CLOSE ep_cur;
    DEALLOCATE ep_cur;

    SELECT @Applied AS PermissionsApplied;
END;
GO

/* Approved permissions still WAITING for their attendance day to exist.
   Normal for future dates; a PAST date sitting here means the day was never
   processed, and payroll would miss the approval. Worth surfacing to HR. */
CREATE PROCEDURE workflow.usp_ExitPermission_GetPendingApplication
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ep.ExitPermissionId, ep.RequestInstanceId, ep.EmployeeId, e.FullName,
           b.Name AS BranchName, ep.ExitDate, ep.FromTime, ep.ToTime, ep.Minutes,
           ep.ConvertToLeave, r.[Status],
           CASE WHEN ep.ExitDate < CAST(SYSUTCDATETIME() AS DATE)
                THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsOverdue
    FROM workflow.EXIT_PERMISSION ep
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
    JOIN hr.EMPLOYEE e ON e.EmployeeId = ep.EmployeeId
    JOIN hr.BRANCH b   ON b.BranchId = e.BranchId
    WHERE r.[Status] = 'Approved'
      AND ep.AppliedToAttendanceAt IS NULL
    ORDER BY ep.ExitDate;
END;
GO

/* ############################################################################
   ==========================  LEAVE LEDGER  =================================
   ############################################################################ */

/* --------------------------------------------------------------------------
   The ledger must be able to say WHERE a movement came from.
   hr.LEAVE_LEDGER was written with only LeaveRequestId, which cannot express
   "this came from an exit permission". Add a soft source reference - the same
   SourceType/SourceRef pattern already used by the payroll bridge - and extend
   PostMovement to accept it. Deliberately NOT a foreign key: the ledger must be
   able to reference several different tables.
   -------------------------------------------------------------------------- */
IF COL_LENGTH('hr.LEAVE_LEDGER', 'SourceType') IS NULL
    ALTER TABLE hr.LEAVE_LEDGER ADD
        SourceType VARCHAR(30) NULL,      -- e.g. 'ExitPermission', 'LeaveRequest', 'Accrual'
        SourceRef  INT         NULL;      -- the id in that table. e.g. 4
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LeaveLedger_Source')
    CREATE INDEX IX_LeaveLedger_Source ON hr.LEAVE_LEDGER (SourceType, SourceRef);
GO

/* PostMovement, extended with the source reference.
   Unchanged in every other respect: the MOVEMENT TYPE still drives the sign, so
   callers pass a POSITIVE magnitude - Accrual and CarryOver add, Usage subtracts,
   and only Adjustment keeps the caller's sign. */
CREATE OR ALTER PROCEDURE hr.usp_LeaveLedger_PostMovement
    @EmployeeId INT, @LeaveTypeId INT, @MovementType VARCHAR(20),
    @Days DECIMAL(6,2), @EffectiveDate DATE, @LeaveRequestId INT = NULL,
    @Note NVARCHAR(200) = NULL, @CreatedBy INT = NULL,
    @SourceType VARCHAR(30) = NULL, @SourceRef INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @MovementType NOT IN ('Accrual','Usage','CarryOver','Adjustment')
    BEGIN
        RAISERROR('MovementType must be Accrual, Usage, CarryOver or Adjustment.', 16, 1);
        RETURN;
    END

    DECLARE @Period CHAR(7) = FORMAT(@EffectiveDate, 'yyyy-MM');

    /* the TYPE decides the sign, not the caller */
    DECLARE @Signed DECIMAL(6,2) =
        CASE @MovementType
            WHEN 'Accrual'   THEN  ABS(@Days)
            WHEN 'CarryOver' THEN  ABS(@Days)
            WHEN 'Usage'     THEN -ABS(@Days)
            ELSE @Days                       -- Adjustment keeps the caller's sign
        END;

    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType,
                                 LeaveRequestId, Days, EffectiveDate, Note, CreatedBy,
                                 SourceType, SourceRef)
    VALUES (@EmployeeId, @LeaveTypeId, @Period, @MovementType,
            @LeaveRequestId, @Signed, @EffectiveDate, @Note, @CreatedBy,
            @SourceType, @SourceRef);

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS LeaveLedgerId;
END;
GO

/* Post the leave usage for exit permissions in a period.

   RUN AT PERIOD CLOSE, not at approval. By then HR has dispositioned any
   variances and ExitLeaveMinutes is final. Posting earlier would use the APPROVED
   minutes and contradict the configured default of deducting what ACTUALLY
   happened.

   Only permissions with ConvertToLeave = 1 are posted. The number of days comes
   from ATTENDANCE (ExitLeaveMinutes - which honours the basis setting and any HR
   override), converted by core.fn_MinutesToLeaveDays. That is the whole point of
   deferring: attendance holds the truth, and it is not final until HR says so.

   IDEMPOTENT: matched on (SourceType, SourceRef), so re-running posts nothing new. */
CREATE PROCEDURE workflow.usp_ExitPermission_PostLeaveUsage
    @PeriodYearMonth CHAR(7),          -- e.g. '2026-07'
    @LeaveTypeId     INT,              -- which balance it draws from (Annual)
    @PostedBy        INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @from DATE = CAST(@PeriodYearMonth + '-01' AS DATE);
    DECLARE @to   DATE = EOMONTH(@from);
    DECLARE @Posted INT = 0;

    DECLARE @Id INT, @Emp INT, @Date DATE, @Days DECIMAL(6,2);

    DECLARE lp_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT ep.ExitPermissionId, ep.EmployeeId, ep.ExitDate,
               core.fn_MinutesToLeaveDays(a.ExitLeaveMinutes)
        FROM workflow.EXIT_PERMISSION ep
        JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
        JOIN attendance.ATTENDANCE_RECORD a
          ON a.EmployeeId = ep.EmployeeId AND a.WorkDate = ep.ExitDate
        WHERE r.[Status] = 'Approved'
          AND ep.ConvertToLeave = 1
          AND ep.ExitDate BETWEEN @from AND @to
          AND a.ExitLeaveMinutes > 0
          AND NOT EXISTS (
                SELECT 1 FROM hr.LEAVE_LEDGER l
                WHERE l.SourceType = 'ExitPermission'
                  AND l.SourceRef  = ep.ExitPermissionId);

    OPEN lp_cur;
    FETCH NEXT FROM lp_cur INTO @Id, @Emp, @Date, @Days;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @Days > 0
        BEGIN
            EXEC hr.usp_LeaveLedger_PostMovement
                 @EmployeeId    = @Emp,
                 @LeaveTypeId   = @LeaveTypeId,
                 @MovementType  = 'Usage',
                 @Days          = @Days,          -- positive magnitude; the proc applies the sign
                 @EffectiveDate = @Date,
                 @Note          = N'Exit permission converted to leave.',
                 @CreatedBy     = @PostedBy,
                 @SourceType    = 'ExitPermission',
                 @SourceRef     = @Id;

            SET @Posted = @Posted + 1;
        END

        FETCH NEXT FROM lp_cur INTO @Id, @Emp, @Date, @Days;
    END

    CLOSE lp_cur;
    DEALLOCATE lp_cur;

    SELECT @Posted AS LeaveMovementsPosted;
END;
GO

/* ############################################################################
   ==============================  READS  ====================================
   ############################################################################ */

/* The payload for one request. The API pairs this with usp_Request_GetById, which
   returns the chain and the signature history. */
CREATE PROCEDURE workflow.usp_ExitPermission_GetByRequest @RequestInstanceId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ep.ExitPermissionId, ep.RequestInstanceId, ep.EmployeeId, e.FullName,
           b.Name AS BranchName, ep.ExitDate, ep.FromTime, ep.ToTime, ep.Minutes,
           core.fn_MinutesToLeaveDays(ep.Minutes) AS RequestedLeaveDays,
           ep.Reason, ep.ConvertToLeave, ep.AppliedToAttendanceAt, ep.CreatedAt,
           /* what attendance ended up recording for that day, if it exists yet */
           a.AttendanceId, a.ExitActualMinutes, a.ExitApprovedMinutes,
           a.ExitVarianceMinutes, a.ExitLeaveMinutes, a.ExitVarianceDisposition
    FROM workflow.EXIT_PERMISSION ep
    JOIN hr.EMPLOYEE e ON e.EmployeeId = ep.EmployeeId
    JOIN hr.BRANCH b   ON b.BranchId = e.BranchId
    LEFT JOIN attendance.ATTENDANCE_RECORD a
           ON a.EmployeeId = ep.EmployeeId AND a.WorkDate = ep.ExitDate
    WHERE ep.RequestInstanceId = @RequestInstanceId;
END;
GO

CREATE PROCEDURE workflow.usp_ExitPermission_GetForEmployee
    @EmployeeId INT, @FromDate DATE = NULL, @ToDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ep.ExitPermissionId, ep.RequestInstanceId, ep.ExitDate, ep.FromTime,
           ep.ToTime, ep.Minutes, ep.Reason, ep.ConvertToLeave,
           r.[Status], r.CurrentStepNo, si.Name AS CurrentStepName,
           ep.AppliedToAttendanceAt, r.SubmittedAt, r.ClosedAt, r.ClosedReason
    FROM workflow.EXIT_PERMISSION ep
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
    LEFT JOIN workflow.REQUEST_STEP_INSTANCE si
           ON si.RequestInstanceId = r.RequestInstanceId AND si.StepNo = r.CurrentStepNo
    WHERE ep.EmployeeId = @EmployeeId
      AND (@FromDate IS NULL OR ep.ExitDate >= @FromDate)
      AND (@ToDate   IS NULL OR ep.ExitDate <= @ToDate)
    ORDER BY ep.ExitDate DESC;
END;
GO

/* ############################################################################
   ====================  THE CHAIN  (configuration, not code)  ===============
   Employee raises  ->  1. Branch manager  ->  2. HR  ->  3. Owner

   Step 1 is BranchManager: resolved from the REQUESTER'S OWN branch, so a manager
   of another branch can never sign. Steps 2 and 3 are Role steps - any HR user,
   any Owner - because they are company-wide by design.

   This block is CONFIGURATION. Changing the chain later means publishing a NEW
   version through the same three procedures; pending requests keep their locked
   version until HR explicitly moves them.
   ############################################################################ */

DECLARE @TypeId INT = (SELECT RequestTypeId FROM workflow.REQUEST_TYPE WHERE Code = 'EXIT_PERMISSION');
DECLARE @HrRoleId    INT = (SELECT RoleId FROM security.[ROLE] WHERE Name = 'HR');
DECLARE @OwnerRoleId INT = (SELECT RoleId FROM security.[ROLE] WHERE Name = 'Owner');

IF NOT EXISTS (SELECT 1 FROM workflow.WORKFLOW_DEFINITION
               WHERE RequestTypeId = @TypeId AND [Status] = 'Active')
BEGIN
    DECLARE @Draft TABLE (WorkflowDefinitionId INT, [Version] INT);
    INSERT INTO @Draft
    EXEC workflow.usp_Definition_CreateDraft
         @RequestTypeId = @TypeId,
         @Notes = N'Initial chain: branch manager, then HR, then Owner.';

    DECLARE @DefId INT = (SELECT TOP 1 WorkflowDefinitionId FROM @Draft);

    EXEC workflow.usp_Definition_AddStep @WorkflowDefinitionId = @DefId, @StepNo = 1,
         @Name = N'Branch manager approval', @ApproverType = 'BranchManager';

    EXEC workflow.usp_Definition_AddStep @WorkflowDefinitionId = @DefId, @StepNo = 2,
         @Name = N'HR approval', @ApproverType = 'Role', @ApproverRoleId = @HrRoleId;

    EXEC workflow.usp_Definition_AddStep @WorkflowDefinitionId = @DefId, @StepNo = 3,
         @Name = N'Owner approval', @ApproverType = 'Role', @ApproverRoleId = @OwnerRoleId;

    EXEC workflow.usp_Definition_Publish @WorkflowDefinitionId = @DefId;
END
GO

/* ############################################################################
   ==============================  SMOKE TEST  ==============================
   Uncomment and run once the branch has a manager and the users exist.
   ############################################################################ */
/*
-- 0. a branch must HAVE a manager, or step 1 skips (and says so)
UPDATE hr.BRANCH SET ManagerEmployeeId = 12 WHERE BranchId = 1;   -- Joe manages Main Branch

-- 1. the published chain
EXEC workflow.usp_Definition_GetActive @RequestTypeCode = 'EXIT_PERMISSION';
--    EXPECT: 3 steps - BranchManager, Role(HR), Role(Owner)

-- 2. Rami asks for two hours on 14 Jul
EXEC workflow.usp_ExitPermission_Create
     @EmployeeId = 10, @RaisedByUserId = 2,
     @ExitDate = '2026-07-14', @FromTime = '12:00', @ToTime = '14:00',
     @Reason = N'Doctor appointment', @ConvertToLeave = 1;
--    EXPECT: Status Pending, CurrentStepNo 1

-- 3. what the branch manager sees
EXEC workflow.usp_Request_GetPendingForUser @UserId = <the manager's UserId>;

-- 4. walk the chain
EXEC workflow.usp_Request_Approve @RequestInstanceId = 1, @ActedByUserId = <manager>, @Comment = N'OK';
EXEC workflow.usp_Request_Approve @RequestInstanceId = 1, @ActedByUserId = <hr user>;
EXEC workflow.usp_Request_Approve @RequestInstanceId = 1, @ActedByUserId = <owner user>;
--    EXPECT after the third: Status Approved, CurrentStepNo NULL

-- 5. the full picture: header, chain, signature log
EXEC workflow.usp_Request_GetById @RequestInstanceId = 1;

-- 6. push it into attendance (the nightly job calls this after the processor)
EXEC workflow.usp_ExitPermission_ApplyToAttendance @WorkDate = '2026-07-14';
--    If the day has no attendance record yet, nothing is applied - correct.
--    It waits, and appears here:
EXEC workflow.usp_ExitPermission_GetPendingApplication;

-- 7. once the day IS processed, applying sets ExitApprovedMinutes = 120 and
--    recomputes the variance against whatever the punches actually showed.
EXEC attendance.usp_Attendance_GetExitVariances @FromDate = '2026-07-01', @ToDate = '2026-07-31';

-- 8. AT PERIOD CLOSE, after HR has dispositioned variances:
EXEC workflow.usp_ExitPermission_PostLeaveUsage @PeriodYearMonth = '2026-07', @LeaveTypeId = 1;
*/

/* ============================================================================
   END. 1 table | 6 procedures | 1 chain published | hr.LEAVE_LEDGER extended
        with SourceType/SourceRef and PostMovement corrected to type-drives-sign.
   ============================================================================ */
