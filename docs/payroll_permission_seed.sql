/* ============================================================================
   PAYROLL PERMISSION GRANTS  -  RE-RUNNABLE
   SQL Server 2025  -  database MokaCo_HRMS
   ----------------------------------------------------------------------------
   THIS SCRIPT TOUCHES NOTHING IN THE PAYROLL SCHEMA. The payroll tables,
   functions and procedures are installed and are not this script's business.
   All it does is hand the two EXISTING permission codes to the roles that need
   them, so the module is reachable by the people who run it.

   THE TWO CODES WERE ALREADY IN THE CATALOGUE, held by Admin and Owner alone:
     PAYROLL_RUN      (PermissionId 9)   Run payroll
     PAYROLL_APPROVE  (PermissionId 10)  Approve & lock payroll
   Left as they were, a General Manager, an Operations Manager and HR would all
   get a 403 on every payroll route — the JWT carries one "perm" claim per code
   and the policy provider demands a matching one.

   WHO GETS WHAT, AND WHY THE TWO LISTS DIFFER
     PAYROLL_RUN gates EVERY route under api/payroll: reading runs and payslips,
     generating, cancelling, recording advances and adjustments. It goes to the
     five managerial roles and to nobody else. A barista must not be able to
     read the company's pay figures by typing a URL, so the gate is on the
     server and the hidden menu item is only a courtesy on top of it.

     PAYROLL_APPROVE gates the two acts that turn figures into money — locking a
     run, and recording that a payslip was paid. HR may PREPARE a run and read
     every payslip in it; HR may not commit it. That is the whole reason the
     second code exists.

   A NOTE ON Admin, DELIBERATELY LEFT ALONE
     Admin already holds PAYROLL_APPROVE from the original security seed. The
     module's stated approver list is Owner / General Manager / Operations
     Manager, so Admin's grant is wider than that sentence — but it is the
     existing, deliberate shape of the Admin role across every module in this
     system, and quietly REVOKING a right somebody may be relying on is not a
     side effect a permission-grant script should have. Revoke it by hand if
     Admin is meant to be locked out of approving.

   ROLE NAMES ARE MATCHED AS LITERALS, so mind the spelling: the roles are
   'OperationsManager' (no space) and 'General Manager' (WITH a space). This
   exact inconsistency once silently gave the GM the wrong dashboard; see
   docs/dashboard_managerial_role_fix.sql.
   ============================================================================ */
USE MokaCo_HRMS;
GO

/* -- the codes, in case this runs against a database seeded without them ----- */
INSERT INTO security.PERMISSION (Code, Name, Module)
SELECT 'PAYROLL_RUN', N'Run payroll', 'Payroll'
WHERE NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'PAYROLL_RUN');

INSERT INTO security.PERMISSION (Code, Name, Module)
SELECT 'PAYROLL_APPROVE', N'Approve & lock payroll', 'Payroll'
WHERE NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'PAYROLL_APPROVE');
GO

/* -- PAYROLL_RUN: the five managerial roles -------------------------------- */
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
SELECT r.RoleId, p.PermissionId
FROM security.[ROLE] r
CROSS JOIN security.PERMISSION p
WHERE p.Code = 'PAYROLL_RUN'
  AND r.Name IN ('Owner', 'General Manager', 'OperationsManager', 'HR', 'Admin')
  AND NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION rp
                  WHERE rp.RoleId = r.RoleId AND rp.PermissionId = p.PermissionId);
GO

/* -- PAYROLL_APPROVE: approving and recording payment ---------------------- */
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
SELECT r.RoleId, p.PermissionId
FROM security.[ROLE] r
CROSS JOIN security.PERMISSION p
WHERE p.Code = 'PAYROLL_APPROVE'
  AND r.Name IN ('Owner', 'General Manager', 'OperationsManager')
  AND NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION rp
                  WHERE rp.RoleId = r.RoleId AND rp.PermissionId = p.PermissionId);
GO

/* -- verify ---------------------------------------------------------------- */
SELECT p.Code, r.Name AS RoleName
FROM security.ROLE_PERMISSION rp
JOIN security.[ROLE] r     ON r.RoleId = rp.RoleId
JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
WHERE p.Code LIKE 'PAYROLL%'
ORDER BY p.Code, r.Name;
GO
