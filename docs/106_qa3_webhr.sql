/* ============================================================================
   106_qa3_webhr.sql - QA3 (deep test, 2026-10-19), unit W (web + HR): the HR side of the people
   records - who a new employee is in the hierarchy, what ends when somebody leaves, when a record
   may be removed - and the two reads the web needs.

   QA3 LEAD-1  A NEW EMPLOYEE WITHOUT A CHOSEN TIER WAS THE HEAD. Since decision D6 tier 1 is the head
               of the organisation, but hr.EMPLOYEE.ApprovalTier still defaulted to 1 and
               hr.usp_Employee_Create took no tier, so everyone created without one became tier 1:
               tier-scoped chains, approval routing and the salary band all treated them as the head.
                 - hr.usp_Employee_Create takes @ApprovalTier (last, optional). NULL = the LOWEST tier,
                   the highest TierNo of hr.APPROVAL_TIER; a tier the dictionary does not have is refused.
                 - the column default becomes hr.fn_ApprovalTier_Lowest() (the same lowest tier), for any
                   other path that inserts an employee without naming a tier. NOTE: SQL Server does not
                   let a function referenced by a default constraint be ALTERed; this script creates it
                   only when it is missing. To change it later, drop DF_Employee_ApprovalTier first.
                 - hr.usp_Employee_SetApprovalTier accepted only 1-3 (the first, three-tier model) while
                   the dictionary holds 1-9: it now accepts exactly the tiers of hr.APPROVAL_TIER.
               NO DATA IS CHANGED: who is on tier 1 is a business fact. The owner reviews the list with
                   SELECT e.EmployeeId, e.FullName, b.Name AS Branch, p.Title AS Position, e.HireDate,
                          e.CreatedAt, e.TerminationDate
                   FROM hr.EMPLOYEE e
                   JOIN hr.BRANCH b ON b.BranchId = e.BranchId
                   JOIN hr.[POSITION] p ON p.PositionId = e.PositionId
                   WHERE e.ApprovalTier = 1 AND e.IsDeleted = 0
                   ORDER BY e.CreatedAt DESC;
               and moves anybody who is not the head with the tier box of the employee form.
   QA3 REL-4   A TERMINATION ENDED NOTHING OUTSIDE PAYROLL. Access ends the day after the termination
               date: hr.usp_Employee_ApplyDueTerminations (the nightly job, once per termination date)
                 - disables the employee's login (not when another record still in employment uses the
                   same account - a rehire - nor when it is the last active account that can manage users),
                 - removes them as the manager of any branch (the post shows vacant on the branch-managers
                   page; branch-manager steps of that branch skip, with a reason, until somebody is named),
                 - removes their device PIN mappings, so the PIN can be enrolled for somebody else (a late
                   punch of theirs then lands in the unknown-PIN list, from where it can be mapped back),
                 - writes each of those to the new table hr.EMPLOYEE_TERMINATION_EFFECT, with the open
                   requests still waiting on their signature and the open requests raised for them -
                   which it does NOT touch (cancelling and re-routing belong to the workflow engine).
               Never touches anybody whose termination date is cleared (rehired) or not yet passed. The
               first nightly run after this script applies every termination already in the past, once.
   QA3 REL-5   "REMOVE" DROPPED A WORKED MONTH FROM PAYROLL (the generator skips removed employees).
               hr.usp_Employee_SoftDelete now refuses, with a sentence, unless the employee has a
               termination date, every month of their employment is in a locked primary run for them
               (months before the first locked primary run were paid outside the system), and no payroll
               adjustment or salary advance of theirs is still open. A record with nothing on file (no
               salary, attendance, payslip, adjustment or advance) has no pay to lose and needs only the
               termination date.
   QA3 WEB-2   THE SHIFT-SWAP FORM LISTED NOBODY FOR STAFF (it read the branch-scoped employee list).
               hr.usp_Employee_GetSwapCounterparts: the requester and the active colleagues of their
               branch in the same position, for the requester themself, somebody who sees them, or
               somebody who may raise requests for others. GET /api/employees/{id}/swap-counterparts.
   Suspicion   DEACTIVATING A BRANCH THAT STILL HAS PEOPLE was allowed. hr.usp_Branch_SetActive and
               hr.usp_Branch_Update refuse it and say how many active employees (including one transferred
               in on a later date) still belong to it.
   Owner       THE OPERATIONS MANAGER SEES EVERY BRANCH (handoff section 12, now decided): the role named
               'Operations Manager' or 'OperationsManager' gets EMP_VIEW_ALL. They pick it up at their next
               sign-in (permissions travel in the token).

   STALE REPO COPIES (contract review CON-7). hr.usp_Employee_SetApprovalTier, hr.usp_Employee_SoftDelete
   and hr.usp_Branch_Update are redefined from UNNUMBERED scripts, checked against what the API passes and
   reads. The first batches below stop the whole script (before anything changes, with -b or without it)
   if the live copy of one of them has a parameter this script does not know.

   Needs: hr.APPROVAL_TIER, script 82 (hr.EMPLOYEE_BRANCH_HISTORY, payroll.fn_IsPeriodPaid), script 87
   (hr.fn_CallerScope, EMP_VIEW_ALL). Idempotent: run it again and nothing changes. Apply with sqlcmd -C -I -b.
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

/* ------------------------- prerequisites and stale-copy guards (nothing changes before these pass) ------------------------- */
IF OBJECT_ID('hr.APPROVAL_TIER') IS NULL OR COL_LENGTH('hr.EMPLOYEE', 'ApprovalTier') IS NULL
BEGIN RAISERROR('106_qa3_webhr.sql needs hr.APPROVAL_TIER and hr.EMPLOYEE.ApprovalTier (workflow_approval_tiers.sql). Nothing was applied.', 16, 1); SET NOEXEC ON; END
GO
IF OBJECT_ID('hr.EMPLOYEE_BRANCH_HISTORY') IS NULL OR OBJECT_ID('payroll.fn_IsPeriodPaid') IS NULL
BEGIN RAISERROR('106_qa3_webhr.sql needs script 82 (hr.EMPLOYEE_BRANCH_HISTORY, payroll.fn_IsPeriodPaid). Apply 82 first; nothing was applied.', 16, 1); SET NOEXEC ON; END
GO
IF OBJECT_ID('hr.fn_CallerScope') IS NULL
BEGIN RAISERROR('106_qa3_webhr.sql needs script 87 (hr.fn_CallerScope). Apply 87 first; nothing was applied.', 16, 1); SET NOEXEC ON; END
GO
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('hr.usp_Employee_SetApprovalTier')
           AND name NOT IN (N'@EmployeeId', N'@ApprovalTier'))
BEGIN RAISERROR('106_qa3_webhr.sql: the live hr.usp_Employee_SetApprovalTier has a parameter this script does not know (it is newer than the repo copy). Merge by hand; nothing was applied.', 16, 1); SET NOEXEC ON; END
GO
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('hr.usp_Employee_SoftDelete')
           AND name NOT IN (N'@EmployeeId', N'@ModifiedBy'))
BEGIN RAISERROR('106_qa3_webhr.sql: the live hr.usp_Employee_SoftDelete has a parameter this script does not know (it is newer than the repo copy). Merge by hand; nothing was applied.', 16, 1); SET NOEXEC ON; END
GO
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('hr.usp_Branch_Update')
           AND name NOT IN (N'@BranchId', N'@Name', N'@IsActive'))
BEGIN RAISERROR('106_qa3_webhr.sql: the live hr.usp_Branch_Update has a parameter this script does not know (it is newer than the repo copy). Merge by hand; nothing was applied.', 16, 1); SET NOEXEC ON; END
GO

/* ==================================== 1. QA3 LEAD-1: the tier of a new employee ==================================== */

/* The lowest tier = the highest number in the dictionary (1 is the head, D6). NULL when the dictionary is empty: an
   insert that names no tier then fails rather than making somebody the head. Created only when missing - a function
   a default constraint references cannot be ALTERed (see the header). */
IF OBJECT_ID('hr.fn_ApprovalTier_Lowest') IS NULL
    EXEC (N'CREATE FUNCTION hr.fn_ApprovalTier_Lowest ()
RETURNS INT
AS
BEGIN
    /* script 106 (QA3 LEAD-1): the default tier of a new employee - the LOWEST, never 1 (the head). Referenced by
       the default constraint DF_Employee_ApprovalTier: drop that before altering this function. */
    RETURN (SELECT MAX(TierNo) FROM hr.APPROVAL_TIER);
END;');
GO

/* the column default: whatever constraint holds it now (DEFAULT 1 from workflow_approval_tiers.sql) is replaced */
DECLARE @df SYSNAME, @def NVARCHAR(MAX), @drop NVARCHAR(400);
SELECT @df = dc.name, @def = dc.definition
FROM sys.default_constraints dc
JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
WHERE dc.parent_object_id = OBJECT_ID('hr.EMPLOYEE') AND c.name = 'ApprovalTier';
IF @def IS NULL OR @def NOT LIKE N'%fn_ApprovalTier_Lowest%'
BEGIN
    IF @df IS NOT NULL
    BEGIN
        SET @drop = N'ALTER TABLE hr.EMPLOYEE DROP CONSTRAINT ' + QUOTENAME(@df) + N';';
        EXEC (@drop);
    END
    ALTER TABLE hr.EMPLOYEE ADD CONSTRAINT DF_Employee_ApprovalTier DEFAULT (hr.fn_ApprovalTier_Lowest()) FOR ApprovalTier;
    PRINT CONCAT('QA3 LEAD-1: hr.EMPLOYEE.ApprovalTier now defaults to the lowest tier (was ', ISNULL(@def, N'no default'), ')');
END
ELSE PRINT 'QA3 LEAD-1: hr.EMPLOYEE.ApprovalTier already defaults to the lowest tier';
GO

/* ------------------------- hr.usp_Employee_Create (script 85's body + @ApprovalTier) ------------------------- */
CREATE OR ALTER PROCEDURE [hr].[usp_Employee_Create]
    @UserId INT = NULL, @BranchId INT, @DepartmentId INT, @PositionId INT,
    @FullName NVARCHAR(150), @NationalId VARCHAR(50) = NULL, @NssfNumber VARCHAR(50) = NULL,
    @HireDate DATE, @CreatedBy INT = NULL,
    @Email NVARCHAR(150) = NULL, @PhoneNumber VARCHAR(30) = NULL,
    @PreferredLanguage CHAR(2) = 'en',
    @ApprovalTier INT = NULL        -- script 106 (QA3 LEAD-1): the seniority tier; NULL = the LOWEST tier of hr.APPROVAL_TIER, never 1 (the head)
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

    /* script 106 (QA3 LEAD-1): tier 1 is the head (D6). Somebody created without a tier used to become tier 1 through
       the column default - head of every tier-scoped chain and of the salary band. No tier now means the lowest one. */
    IF @ApprovalTier IS NULL
        SET @ApprovalTier = (SELECT MAX(TierNo) FROM hr.APPROVAL_TIER);
    IF @ApprovalTier IS NULL
    BEGIN
        RAISERROR('No seniority tiers are defined yet. Add them on the Tiers page before creating an employee.', 16, 1);
        RETURN 1;
    END
    IF NOT EXISTS (SELECT 1 FROM hr.APPROVAL_TIER WHERE TierNo = @ApprovalTier)
    BEGIN
        RAISERROR('Tier %d is not on the tier list. Choose one of the tiers on the Tiers page.', 16, 1, @ApprovalTier);
        RETURN 1;
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
                             Email, PhoneNumber, PreferredLanguage, ApprovalTier)
    VALUES (@UserId, @BranchId, @DepartmentId, @PositionId, @FullName,
            @NationalId, @NssfNumber, @HireDate, @CreatedBy,
            @Email, @PhoneNumber,
            ISNULL(@PreferredLanguage, 'en'), @ApprovalTier);

    DECLARE @NewEmployeeId INT = CAST(SCOPE_IDENTITY() AS INT);
    /* script 85 (D7): the branch history starts with the hire */
    INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom, Note, CreatedBy)
    VALUES (@NewEmployeeId, @BranchId, @HireDate, N'Hired into this branch.', @CreatedBy);
    SELECT @NewEmployeeId AS EmployeeId;
END;
GO

/* ------------------------- hr.usp_Employee_SetApprovalTier (workflow_approval_tiers.sql's, checked against the API) ------------------------- */
CREATE OR ALTER PROCEDURE hr.usp_Employee_SetApprovalTier
    @EmployeeId INT, @ApprovalTier INT
AS BEGIN SET NOCOUNT ON;
    /* script 106 (QA3 LEAD-1): the tiers are the dictionary hr.APPROVAL_TIER (1 = the head ... 9 = the lowest, D6), not
       the three of the first model ("1 staff, 2 management, 3 executive"), which refused every tier above 3. */
    IF @ApprovalTier IS NULL OR NOT EXISTS (SELECT 1 FROM hr.APPROVAL_TIER WHERE TierNo = @ApprovalTier)
    BEGIN RAISERROR('Tier %d is not on the tier list. Choose one of the tiers on the Tiers page.', 16, 1, @ApprovalTier); RETURN 1; END
    UPDATE hr.EMPLOYEE SET ApprovalTier = @ApprovalTier WHERE EmployeeId = @EmployeeId;
    SELECT EmployeeId, FullName, ApprovalTier FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId;
END;
GO

/* ==================================== 2. QA3 REL-4: what ends the day after the termination date ==================================== */

IF OBJECT_ID('hr.EMPLOYEE_TERMINATION_EFFECT') IS NULL
BEGIN
    CREATE TABLE hr.EMPLOYEE_TERMINATION_EFFECT (
        EmployeeTerminationEffectId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_EMPLOYEE_TERMINATION_EFFECT PRIMARY KEY,
        EmployeeId      INT           NOT NULL CONSTRAINT FK_EmpTermEffect_Employee REFERENCES hr.EMPLOYEE(EmployeeId),
        TerminationDate DATE          NOT NULL,         -- the termination date the effect was applied for
        Effect          VARCHAR(30)   NOT NULL,
        Detail          NVARCHAR(400) NULL,              -- what exactly: the login, the branch, the device and PIN, the request numbers
        AppliedAt       DATETIME2(0)  NOT NULL CONSTRAINT DF_EmpTermEffect_AppliedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT CK_EmpTermEffect_Effect CHECK (Effect IN ('Applied', 'UserDisabled', 'UserKept', 'BranchManagerCleared',
                                                             'PinMappingRemoved', 'StepsWaiting', 'OpenRequests')));
    PRINT 'QA3 REL-4: table hr.EMPLOYEE_TERMINATION_EFFECT created';
END
GO
/* one 'Applied' per employee and termination date: what makes the sweep apply each termination once */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('hr.EMPLOYEE_TERMINATION_EFFECT') AND name = 'UX_EmpTermEffect_Applied')
    CREATE UNIQUE INDEX UX_EmpTermEffect_Applied ON hr.EMPLOYEE_TERMINATION_EFFECT (EmployeeId, TerminationDate) WHERE Effect = 'Applied';
GO

CREATE OR ALTER PROCEDURE hr.usp_Employee_ApplyDueTerminations
    @AsOfDate DATE = NULL           -- "today"; NULL = today in Beirut. A termination takes effect the day AFTER its date.
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Today DATE = ISNULL(@AsOfDate, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));

    DECLARE @Due TABLE (EmployeeId INT PRIMARY KEY, FullName NVARCHAR(150) NOT NULL, TerminationDate DATE NOT NULL, UserId INT NULL);
    DECLARE @Log TABLE (EmployeeId INT NOT NULL, TerminationDate DATE NOT NULL, Effect VARCHAR(30) NOT NULL, Detail NVARCHAR(400) NULL);
    DECLARE @Users TABLE (UserId INT PRIMARY KEY, EmployeeId INT NOT NULL, Username NVARCHAR(100) NULL, KeptBecause NVARCHAR(200) NULL);
    DECLARE @Branches TABLE (BranchId INT NOT NULL, Name NVARCHAR(100) NULL, EmployeeId INT NOT NULL);
    DECLARE @Pins TABLE (EmployeeId INT NOT NULL, DeviceId INT NOT NULL, EnrollPin VARCHAR(50) NOT NULL);
    DECLARE @Waiting TABLE (EmployeeId INT NOT NULL, RequestInstanceId INT NOT NULL);
    DECLARE @Open TABLE (EmployeeId INT NOT NULL, RequestInstanceId INT NOT NULL);

    BEGIN TRAN;

    /* who is due: the termination date has passed, and this termination date was not applied yet. A rehire (the date
       cleared) or a date still ahead is not touched; a date moved after it was applied is applied again. */
    INSERT INTO @Due (EmployeeId, FullName, TerminationDate, UserId)
    SELECT e.EmployeeId, e.FullName, e.TerminationDate, e.UserId
    FROM hr.EMPLOYEE e
    WHERE e.TerminationDate IS NOT NULL
      AND e.TerminationDate < @Today
      AND NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_TERMINATION_EFFECT x
                      WHERE x.EmployeeId = e.EmployeeId AND x.TerminationDate = e.TerminationDate AND x.Effect = 'Applied');

    /* 1. THE LOGIN. Not when another record still in employment uses the same account (a rehire on a new record),
          and not the last active account that can manage users: nobody could switch it back on. */
    INSERT INTO @Users (UserId, EmployeeId, Username)
    SELECT u.UserId, MIN(d.EmployeeId), MIN(u.Username)
    FROM @Due d
    JOIN security.[USER] u ON u.UserId = d.UserId
    WHERE u.IsActive = 1
      AND NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE o
                      WHERE o.UserId = u.UserId AND o.IsDeleted = 0
                        AND (o.TerminationDate IS NULL OR o.TerminationDate >= @Today))
    GROUP BY u.UserId;

    UPDATE c SET KeptBecause = N'it is the last active account that can manage users'
    FROM @Users c
    WHERE EXISTS (SELECT 1 FROM security.USER_ROLE ur
                  JOIN security.ROLE_PERMISSION rp ON rp.RoleId = ur.RoleId
                  JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
                  WHERE ur.UserId = c.UserId AND p.Code = 'USER_MANAGE')
      AND NOT EXISTS (SELECT 1 FROM security.[USER] o
                      JOIN security.USER_ROLE ur ON ur.UserId = o.UserId
                      JOIN security.ROLE_PERMISSION rp ON rp.RoleId = ur.RoleId
                      JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
                      WHERE p.Code = 'USER_MANAGE' AND o.IsActive = 1
                        AND NOT EXISTS (SELECT 1 FROM @Users x WHERE x.UserId = o.UserId));

    UPDATE u SET u.IsActive = 0, u.ModifiedAt = SYSUTCDATETIME()
    FROM security.[USER] u
    JOIN @Users c ON c.UserId = u.UserId
    WHERE c.KeptBecause IS NULL AND u.IsActive = 1;

    INSERT INTO @Log (EmployeeId, TerminationDate, Effect, Detail)
    SELECT d.EmployeeId, d.TerminationDate,
           CASE WHEN c.KeptBecause IS NULL THEN 'UserDisabled' ELSE 'UserKept' END,
           CASE WHEN c.KeptBecause IS NULL
                THEN CONCAT(N'Login ', c.Username, N' (user #', c.UserId, N') disabled.')
                ELSE CONCAT(N'Login ', c.Username, N' (user #', c.UserId, N') kept active: ', c.KeptBecause, N'.') END
    FROM @Users c JOIN @Due d ON d.EmployeeId = c.EmployeeId;

    /* 2. THE BRANCH THEY MANAGED: the post becomes vacant */
    UPDATE b SET b.ManagerEmployeeId = NULL
    OUTPUT inserted.BranchId, inserted.Name, deleted.ManagerEmployeeId INTO @Branches (BranchId, Name, EmployeeId)
    FROM hr.BRANCH b
    JOIN @Due d ON d.EmployeeId = b.ManagerEmployeeId;

    INSERT INTO @Log (EmployeeId, TerminationDate, Effect, Detail)
    SELECT d.EmployeeId, d.TerminationDate, 'BranchManagerCleared',
           CONCAT(N'No longer the manager of ', x.Name, N' (branch #', x.BranchId, N'); the post is vacant until somebody is named.')
    FROM @Branches x JOIN @Due d ON d.EmployeeId = x.EmployeeId;

    /* 3. THE DEVICE PINS: unmapped, so each PIN can be enrolled for somebody else */
    DELETE ed
    OUTPUT deleted.EmployeeId, deleted.DeviceId, deleted.EnrollPin INTO @Pins (EmployeeId, DeviceId, EnrollPin)
    FROM attendance.EMPLOYEE_DEVICE ed
    JOIN @Due d ON d.EmployeeId = ed.EmployeeId;

    INSERT INTO @Log (EmployeeId, TerminationDate, Effect, Detail)
    SELECT d.EmployeeId, d.TerminationDate, 'PinMappingRemoved',
           CONCAT(N'PIN ', x.EnrollPin, N' on ', COALESCE(NULLIF(dv.[Name], N''), dv.SerialNumber, N'device'), N' (device #', x.DeviceId,
                  N') unmapped; it can be enrolled again.')
    FROM @Pins x
    JOIN @Due d ON d.EmployeeId = x.EmployeeId
    LEFT JOIN attendance.DEVICE dv ON dv.DeviceId = x.DeviceId;

    /* 4. WHAT IS LEFT FOR A PERSON (reported, never changed here): open requests whose current step waits on their
          login, and open requests raised for them. Cancelling and re-routing are the workflow engine's. */
    INSERT INTO @Waiting (EmployeeId, RequestInstanceId)
    SELECT DISTINCT d.EmployeeId, s.RequestInstanceId
    FROM @Due d
    JOIN workflow.REQUEST_STEP_INSTANCE s ON (s.ResolvedUserId = d.UserId OR s.DelegatedToUserId = d.UserId)
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = s.RequestInstanceId
    WHERE d.UserId IS NOT NULL
      AND s.[Status] IN ('Pending', 'OnHold') AND r.[Status] IN ('Pending', 'OnHold');

    INSERT INTO @Open (EmployeeId, RequestInstanceId)
    SELECT d.EmployeeId, r.RequestInstanceId
    FROM @Due d
    JOIN workflow.REQUEST_INSTANCE r ON r.EmployeeId = d.EmployeeId
    WHERE r.[Status] IN ('Pending', 'OnHold');

    INSERT INTO @Log (EmployeeId, TerminationDate, Effect, Detail)
    SELECT d.EmployeeId, d.TerminationDate, 'StepsWaiting',
           LEFT(CONCAT(N'Still the approver of open request(s) ',
                       (SELECT STRING_AGG(CONCAT(N'#', w.RequestInstanceId), N', ') WITHIN GROUP (ORDER BY w.RequestInstanceId)
                        FROM @Waiting w WHERE w.EmployeeId = d.EmployeeId),
                       N': a deputy can sign now the login is off; otherwise reassign them.'), 400)
    FROM @Due d
    WHERE EXISTS (SELECT 1 FROM @Waiting w WHERE w.EmployeeId = d.EmployeeId);

    INSERT INTO @Log (EmployeeId, TerminationDate, Effect, Detail)
    SELECT d.EmployeeId, d.TerminationDate, 'OpenRequests',
           LEFT(CONCAT(N'Open request(s) raised for them: ',
                       (SELECT STRING_AGG(CONCAT(N'#', o.RequestInstanceId), N', ') WITHIN GROUP (ORDER BY o.RequestInstanceId)
                        FROM @Open o WHERE o.EmployeeId = d.EmployeeId),
                       N'. Cancel the ones about days after they left.'), 400)
    FROM @Due d
    WHERE EXISTS (SELECT 1 FROM @Open o WHERE o.EmployeeId = d.EmployeeId);

    /* 5. THE MARK that this termination is applied */
    INSERT INTO @Log (EmployeeId, TerminationDate, Effect, Detail)
    SELECT d.EmployeeId, d.TerminationDate, 'Applied', CONCAT(N'Left on ', CONVERT(CHAR(10), d.TerminationDate, 23), N'.')
    FROM @Due d;

    INSERT INTO hr.EMPLOYEE_TERMINATION_EFFECT (EmployeeId, TerminationDate, Effect, Detail)
    SELECT EmployeeId, TerminationDate, Effect, Detail FROM @Log;

    COMMIT;

    /* one row: the counts, and a line per person for the job's log */
    DECLARE @Lines TABLE (EmployeeId INT PRIMARY KEY, Line NVARCHAR(MAX) NOT NULL);
    INSERT INTO @Lines (EmployeeId, Line)
    SELECT d.EmployeeId, CONCAT(d.FullName, N' (#', d.EmployeeId, N'): ',
                                (SELECT STRING_AGG(CAST(l.Detail AS NVARCHAR(MAX)), N' ')
                                        WITHIN GROUP (ORDER BY CASE l.Effect WHEN 'Applied' THEN 0 WHEN 'UserDisabled' THEN 1 WHEN 'UserKept' THEN 1
                                                                             WHEN 'BranchManagerCleared' THEN 2 WHEN 'PinMappingRemoved' THEN 3 ELSE 4 END)
                                 FROM @Log l WHERE l.EmployeeId = d.EmployeeId))
    FROM @Due d;

    SELECT EmployeesApplied      = (SELECT COUNT(*) FROM @Due),
           UsersDisabled         = (SELECT COUNT(*) FROM @Users WHERE KeptBecause IS NULL),
           UsersKept             = (SELECT COUNT(*) FROM @Users WHERE KeptBecause IS NOT NULL),
           BranchManagersCleared = (SELECT COUNT(*) FROM @Branches),
           PinMappingsRemoved    = (SELECT COUNT(*) FROM @Pins),
           StepsWaiting          = (SELECT COUNT(*) FROM @Waiting),
           OpenRequests          = (SELECT COUNT(*) FROM @Open),
           Summary               = (SELECT STRING_AGG(Line, NCHAR(10)) WITHIN GROUP (ORDER BY EmployeeId) FROM @Lines);
END;
GO

/* ==================================== 3. QA3 REL-5: removing an employee ==================================== */
/* hr.usp_Employee_SoftDelete (core_hr_schema_and_procedures.sql's, checked against the API: @EmployeeId, @ModifiedBy, no result) */
CREATE OR ALTER PROCEDURE hr.usp_Employee_SoftDelete
    @EmployeeId INT, @ModifiedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    /* script 106 (QA3 REL-5): a removed employee is invisible to payroll from then on - the generator skips them - so
       a month they worked that no locked run has paid yet would never be paid. Removing is for somebody who has left
       and has nothing left to be paid. */
    DECLARE @Name NVARCHAR(150), @Hire DATE, @Term DATE, @Deleted BIT;
    SELECT @Name = FullName, @Hire = HireDate, @Term = TerminationDate, @Deleted = IsDeleted
    FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId;

    IF @Name IS NULL BEGIN RAISERROR('Employee not found.', 16, 1); RETURN 1; END
    IF @Deleted = 1 RETURN 0;                              -- removed already: nothing to do

    IF @Term IS NULL
    BEGIN
        RAISERROR('%s still works here. Set their termination date first: only somebody who has left, and has been paid for every month, can be removed.', 16, 1, @Name);
        RETURN 1;
    END

    /* a record with nothing on file (created by mistake, never started) has no pay to lose */
    IF EXISTS (SELECT 1 FROM hr.SALARY_COMPONENT WHERE EmployeeId = @EmployeeId)
       OR EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @EmployeeId)
       OR EXISTS (SELECT 1 FROM payroll.PAYSLIP WHERE EmployeeId = @EmployeeId)
       OR EXISTS (SELECT 1 FROM payroll.PAYROLL_ADJUSTMENT WHERE EmployeeId = @EmployeeId)
       OR EXISTS (SELECT 1 FROM payroll.SALARY_ADVANCE WHERE EmployeeId = @EmployeeId)
    BEGIN
        IF EXISTS (SELECT 1 FROM payroll.PAYROLL_ADJUSTMENT WHERE EmployeeId = @EmployeeId AND AppliedToPayslipId IS NULL)
        BEGIN
            RAISERROR('%s cannot be removed yet: a payroll adjustment of theirs has not been paid. Remove them after the run that pays it is approved.', 16, 1, @Name);
            RETURN 1;
        END
        IF EXISTS (SELECT 1 FROM payroll.SALARY_ADVANCE WHERE EmployeeId = @EmployeeId AND IsSettled = 0)
        BEGIN
            RAISERROR('%s cannot be removed yet: a salary advance of theirs is not fully recovered. Remove them after it is settled.', 16, 1, @Name);
            RETURN 1;
        END

        /* every month of employment in a locked primary run for them (payroll.fn_IsPeriodPaid, D10). The months before
           the first locked primary run were paid outside the system. */
        DECLARE @FirstLocked CHAR(7) = (SELECT MIN(PeriodYearMonth) FROM payroll.PAYROLL_RUN WHERE RunType = 'Primary' AND [Status] = 'Approved');
        DECLARE @m DATE = DATEFROMPARTS(YEAR(@Hire), MONTH(@Hire), 1),
                @Last DATE = DATEFROMPARTS(YEAR(@Term), MONTH(@Term), 1),
                @Month CHAR(7);
        WHILE @m <= @Last
        BEGIN
            SET @Month = CONVERT(CHAR(7), @m, 23);
            IF (@FirstLocked IS NULL OR @Month >= @FirstLocked) AND payroll.fn_IsPeriodPaid(@EmployeeId, @m) = 0
            BEGIN
                RAISERROR('%s cannot be removed yet: their pay for %s is not in a locked payroll run. Remove them once that month''s payroll is approved.', 16, 1, @Name, @Month);
                RETURN 1;
            END
            SET @m = DATEADD(MONTH, 1, @m);
        END
    END

    UPDATE hr.EMPLOYEE
    SET IsDeleted = 1, ModifiedAt = SYSUTCDATETIME(), ModifiedBy = @ModifiedBy
    WHERE EmployeeId = @EmployeeId;
END;
GO

/* ==================================== 4. QA3 WEB-2: who the requester can swap a shift with ==================================== */
CREATE OR ALTER PROCEDURE hr.usp_Employee_GetSwapCounterparts
    @EmployeeId   INT,              -- the requester: whose rostered day is offered
    @CallerUserId INT = NULL        -- the signed-in user; NULL = the system itself
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @Branch INT, @Position INT;
    SELECT @Branch = BranchId, @Position = PositionId FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId AND IsDeleted = 0;
    IF @Branch IS NULL BEGIN RAISERROR('Employee not found.', 16, 1); RETURN 1; END

    /* who may ask: the requester themself, somebody who sees them (EMP_VIEW_ALL, or the manager of their branch -
       hr.fn_CallerScope, script 87), or somebody who may raise requests for others (REQUEST_RAISE_OTHERS) */
    IF @CallerUserId IS NOT NULL
    BEGIN
        DECLARE @SeesAll BIT, @CallerEmp INT, @Allowed BIT = 0;
        SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
        IF @SeesAll = 1 OR @CallerEmp = @EmployeeId
            SET @Allowed = 1;
        ELSE IF EXISTS (SELECT 1 FROM hr.BRANCH b WHERE b.BranchId = @Branch AND b.ManagerEmployeeId = @CallerEmp)
            SET @Allowed = 1;
        ELSE IF EXISTS (SELECT 1 FROM security.USER_ROLE ur
                        JOIN security.ROLE_PERMISSION rp ON rp.RoleId = ur.RoleId
                        JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
                        WHERE ur.UserId = @CallerUserId AND p.Code = 'REQUEST_RAISE_OTHERS')
            SET @Allowed = 1;
        IF @Allowed = 0
        BEGIN RAISERROR('You can list swap partners only for yourself or for somebody you raise requests for.', 16, 1); RETURN 1; END
    END

    /* the requester (IsRequester = 1, first), then the colleagues: same branch today, same position, not removed, not
       gone (somebody leaving later still counts - the swap procedure checks the dates) */
    SELECT e.EmployeeId, e.FullName, p.Title AS Position, b.Name AS Branch, e.TerminationDate,
           CAST(CASE WHEN e.EmployeeId = @EmployeeId THEN 1 ELSE 0 END AS BIT) AS IsRequester
    FROM hr.EMPLOYEE e
    JOIN hr.[POSITION] p ON p.PositionId = e.PositionId
    JOIN hr.BRANCH b ON b.BranchId = e.BranchId
    WHERE e.IsDeleted = 0
      AND e.BranchId = @Branch
      AND e.PositionId = @Position
      AND (e.EmployeeId = @EmployeeId OR e.TerminationDate IS NULL OR e.TerminationDate >= @Today)
    ORDER BY CASE WHEN e.EmployeeId = @EmployeeId THEN 0 ELSE 1 END, e.FullName;
END;
GO

/* ==================================== 5. a branch with people in it is not deactivated ==================================== */
/* The employees still employed (or leaving later) who belong to the branch today, or are transferred into it on a later
   date (hr.EMPLOYEE_BRANCH_HISTORY, D7). */
CREATE OR ALTER FUNCTION hr.fn_Branch_ActivePeople (@BranchId INT, @Today DATE)
RETURNS INT
AS
BEGIN
    RETURN (SELECT COUNT(*)
            FROM hr.EMPLOYEE e
            WHERE e.IsDeleted = 0
              AND (e.TerminationDate IS NULL OR e.TerminationDate >= @Today)
              AND (e.BranchId = @BranchId
                   OR EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY h
                              WHERE h.EmployeeId = e.EmployeeId AND h.BranchId = @BranchId AND h.EffectiveFrom > @Today)));
END;
GO

/* hr.usp_Branch_SetActive (script 70's body + the guard) */
CREATE OR ALTER PROCEDURE hr.usp_Branch_SetActive @BranchId INT, @IsActive BIT
AS BEGIN SET NOCOUNT ON;
    DECLARE @Name NVARCHAR(100), @WasActive BIT;
    SELECT @Name = Name, @WasActive = IsActive FROM hr.BRANCH WHERE BranchId = @BranchId;
    IF @Name IS NULL
    BEGIN RAISERROR('Branch not found.', 16, 1); RETURN; END
    /* script 106: a deactivated branch leaves every pick-list, so the people still in it would be filed under a branch
       nobody can choose */
    IF @IsActive = 0 AND @WasActive = 1
    BEGIN
        DECLARE @People INT = hr.fn_Branch_ActivePeople(@BranchId, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));
        IF @People > 0
        BEGIN
            DECLARE @Who NVARCHAR(100) = CASE WHEN @People = 1 THEN N'1 active employee still belongs'
                                              ELSE CONCAT(@People, N' active employees still belong') END;
            RAISERROR('Cannot deactivate ''%s'': %s to it. Transfer them to another branch first.', 16, 1, @Name, @Who);
            RETURN 1;
        END
    END
    UPDATE hr.BRANCH SET IsActive = @IsActive WHERE BranchId = @BranchId; END;
GO

/* hr.usp_Branch_Update (core_hr_schema_and_procedures.sql's, checked against the API: @BranchId, @Name, @IsActive, no
   result) - the edit form's Active box is the other way to deactivate */
CREATE OR ALTER PROCEDURE hr.usp_Branch_Update @BranchId INT, @Name NVARCHAR(100), @IsActive BIT
AS BEGIN SET NOCOUNT ON;
    DECLARE @Current NVARCHAR(100), @WasActive BIT;
    SELECT @Current = Name, @WasActive = IsActive FROM hr.BRANCH WHERE BranchId = @BranchId;
    IF @Current IS NOT NULL AND @IsActive = 0 AND @WasActive = 1
    BEGIN
        DECLARE @People INT = hr.fn_Branch_ActivePeople(@BranchId, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));
        IF @People > 0
        BEGIN
            DECLARE @Who NVARCHAR(100) = CASE WHEN @People = 1 THEN N'1 active employee still belongs'
                                              ELSE CONCAT(@People, N' active employees still belong') END;
            RAISERROR('Cannot deactivate ''%s'': %s to it. Transfer them to another branch first.', 16, 1, @Current, @Who);
            RETURN 1;
        END
    END
    UPDATE hr.BRANCH SET Name = @Name, IsActive = @IsActive WHERE BranchId = @BranchId; END;
GO

/* ==================================== 6. the Operations Manager sees every branch ==================================== */
DECLARE @added TABLE (RoleId INT);
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
OUTPUT inserted.RoleId INTO @added
SELECT r.RoleId, p.PermissionId
FROM security.[ROLE] r
CROSS JOIN security.PERMISSION p
WHERE p.Code = 'EMP_VIEW_ALL'
  AND r.Name IN (N'Operations Manager', N'OperationsManager')
  AND NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION x WHERE x.RoleId = r.RoleId AND x.PermissionId = p.PermissionId);
DECLARE @n INT = (SELECT COUNT(*) FROM @added);
PRINT CONCAT('EMP_VIEW_ALL granted to the Operations Manager role: ', @n, ' row(s) added');
GO

/* skipped, like everything above, when a guard at the top stopped the script */
PRINT '106_qa3_webhr.sql (QA3 LEAD-1, REL-4, REL-5, WEB-2, branch deactivation, Operations Manager scope) in place';
GO
SET NOEXEC OFF;
GO
