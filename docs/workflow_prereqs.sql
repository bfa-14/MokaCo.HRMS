/* ============================================================================
   WORKFLOW PREREQUISITES  -  run after workflow_core.sql + workflow_exit_permission.sql
   MokaCo_HRMS
   ----------------------------------------------------------------------------
   Three gaps that must be closed before the workflow pages can be built:

     1. PERMISSIONS. The engine had none seeded, so every endpoint would be
        ungated.
     2. BRANCH MANAGER. hr.BRANCH gained ManagerEmployeeId but nothing can SET it,
        and until it is set every BranchManager step skips itself.
     3. WHO AM I. An employee logs in as a USER; the workflow needs their
        EMPLOYEE. Nothing resolved one to the other.

   NOTE ON APPROVAL: there is deliberately NO "approve" permission. Whether you
   may sign is not a role question - it is "are you the resolved approver for THIS
   step, or do you hold the role it names". usp_Request_Approve checks exactly
   that and raises an error otherwise, so the rule cannot be bypassed by calling
   the endpoint directly. Any authenticated user may attempt it; the database
   decides.
   ============================================================================ */
USE MokaCo_HRMS;
GO

DROP PROCEDURE IF EXISTS hr.usp_Branch_SetManager;
DROP PROCEDURE IF EXISTS hr.usp_Branch_GetAllWithManager;
DROP PROCEDURE IF EXISTS hr.usp_Employee_GetByUserId;
GO

/* ############################################################################
   ==========================  1. PERMISSIONS  ===============================
   ############################################################################ */

/* Guarded insert: safe to re-run, never duplicates. */
INSERT INTO security.PERMISSION (Code, Name, Module)
SELECT v.Code, v.Name, v.Module
FROM (VALUES
    ('WORKFLOW_CONFIGURE',   N'Configure approval chains',
     N'Workflow'),
    ('WORKFLOW_VERSION_MOVE',N'Move pending requests to a newer chain version',
     N'Workflow'),
    ('REQUEST_RAISE_SELF',   N'Raise own requests',
     N'Workflow'),
    ('REQUEST_RAISE_OTHERS', N'Raise a request on another employee''s behalf',
     N'Workflow'),
    ('REQUEST_VIEW_ALL',     N'View every request, not only own',
     N'Workflow'),
    ('SIGNATURE_MANAGE',     N'Upload or remove signature images',
     N'Security')
) AS v(Code, Name, Module)
WHERE NOT EXISTS (SELECT 1 FROM security.PERMISSION p WHERE p.Code = v.Code);
GO

/* ---- grant them ----
   Admin  : everything
   HR     : run the process day to day, including moving stuck requests
   Owner  : sees everything, raises own
   Manager: raises own (approving is decided per step, not by permission)
   Employee: raises own                                                        */
;WITH grants(RoleName, PermCode) AS (
    SELECT * FROM (VALUES
        ('Admin','WORKFLOW_CONFIGURE'), ('Admin','WORKFLOW_VERSION_MOVE'),
        ('Admin','REQUEST_RAISE_SELF'), ('Admin','REQUEST_RAISE_OTHERS'),
        ('Admin','REQUEST_VIEW_ALL'),   ('Admin','SIGNATURE_MANAGE'),

        ('HR','WORKFLOW_VERSION_MOVE'), ('HR','REQUEST_RAISE_SELF'),
        ('HR','REQUEST_RAISE_OTHERS'),  ('HR','REQUEST_VIEW_ALL'),

        ('Owner','REQUEST_VIEW_ALL'),   ('Owner','REQUEST_RAISE_SELF'),
        ('Owner','SIGNATURE_MANAGE'),

        ('Manager','REQUEST_RAISE_SELF'),
        ('Employee','REQUEST_RAISE_SELF')
    ) AS g(RoleName, PermCode)
)
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
SELECT r.RoleId, p.PermissionId
FROM grants g
JOIN security.[ROLE] r     ON r.Name = g.RoleName
JOIN security.PERMISSION p ON p.Code = g.PermCode
WHERE NOT EXISTS (
    SELECT 1 FROM security.ROLE_PERMISSION rp
    WHERE rp.RoleId = r.RoleId AND rp.PermissionId = p.PermissionId);
GO

/* ############################################################################
   =========================  2. BRANCH MANAGER  =============================
   Until a branch has a manager, every BranchManager step resolves to nobody and
   is skipped (with a reason). This is the CRUD that stops that happening.
   ############################################################################ */

CREATE PROCEDURE hr.usp_Branch_GetAllWithManager
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.BranchId, b.Name, b.IsActive,
           b.ManagerEmployeeId,
           m.FullName AS ManagerName,
           m.UserId   AS ManagerUserId,
           /* a manager with no login cannot approve anything - surface it */
           CAST(CASE WHEN b.ManagerEmployeeId IS NOT NULL AND m.UserId IS NULL
                     THEN 1 ELSE 0 END AS BIT) AS ManagerHasNoLogin
    FROM hr.BRANCH b
    LEFT JOIN hr.EMPLOYEE m ON m.EmployeeId = b.ManagerEmployeeId AND m.IsDeleted = 0
    ORDER BY b.Name;
END;
GO

/* Set (or clear, with NULL) a branch's manager.
   Warns rather than blocks when the chosen manager has no user account: the data
   is still valid, but that person cannot sign anything until they can log in. */
CREATE PROCEDURE hr.usp_Branch_SetManager
    @BranchId          INT,
    @ManagerEmployeeId INT = NULL,
    @ModifiedBy        INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @ManagerEmployeeId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE
                       WHERE EmployeeId = @ManagerEmployeeId AND IsDeleted = 0)
    BEGIN RAISERROR('That employee does not exist.', 16, 1); RETURN; END

    UPDATE hr.BRANCH
    SET ManagerEmployeeId = @ManagerEmployeeId
    WHERE BranchId = @BranchId;

    SELECT b.BranchId, b.Name, b.ManagerEmployeeId, m.FullName AS ManagerName,
           m.UserId AS ManagerUserId,
           CAST(CASE WHEN @ManagerEmployeeId IS NOT NULL AND m.UserId IS NULL
                     THEN 1 ELSE 0 END AS BIT) AS ManagerHasNoLogin,
           CASE WHEN @ManagerEmployeeId IS NOT NULL AND m.UserId IS NULL
                THEN N'This manager has no user account, so they cannot approve anything yet.'
                ELSE NULL END AS Warning
    FROM hr.BRANCH b
    LEFT JOIN hr.EMPLOYEE m ON m.EmployeeId = b.ManagerEmployeeId
    WHERE b.BranchId = @BranchId;
END;
GO

/* ############################################################################
   ===========================  3. WHO AM I  =================================
   ############################################################################ */

/* Resolve the signed-in USER to their EMPLOYEE record.
   Every self-service screen needs this: "my requests", "my leave balance", "my
   attendance" all key off EmployeeId, but the token carries a UserId.
   Returns nothing when the account is not linked to an employee (e.g. a pure
   admin login) - the API should treat that as "no self-service", not an error. */
CREATE PROCEDURE hr.usp_Employee_GetByUserId @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.EmployeeId, e.UserId, e.FullName,
           e.BranchId, b.Name AS BranchName,
           e.DepartmentId, d.Name AS DepartmentName,
           e.PositionId, p.Name AS PositionName,
           e.HireDate, e.TerminationDate,
           /* is this person the manager of their own branch? the UI uses this to
              explain why a step was skipped on their own requests */
           CAST(CASE WHEN b.ManagerEmployeeId = e.EmployeeId THEN 1 ELSE 0 END AS BIT) AS IsBranchManager
    FROM hr.EMPLOYEE e
    JOIN hr.BRANCH b        ON b.BranchId = e.BranchId
    JOIN hr.DEPARTMENT d    ON d.DepartmentId = e.DepartmentId
    JOIN hr.[POSITION] p    ON p.PositionId = e.PositionId
    WHERE e.UserId = @UserId AND e.IsDeleted = 0;
END;
GO

/* ---- health check: what still needs setting up ---- */
SELECT 'Branches with no manager' AS Issue, COUNT(*) AS [Count]
FROM hr.BRANCH WHERE ManagerEmployeeId IS NULL AND IsActive = 1
UNION ALL
SELECT 'Active employees with no login', COUNT(*)
FROM hr.EMPLOYEE WHERE UserId IS NULL AND IsDeleted = 0
UNION ALL
SELECT 'Request types with no published chain', COUNT(*)
FROM workflow.REQUEST_TYPE rt
WHERE rt.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM workflow.WORKFLOW_DEFINITION d
                  WHERE d.RequestTypeId = rt.RequestTypeId AND d.[Status] = 'Active');
GO
