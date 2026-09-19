/* ============================================================================
   ATTENDANCE - PERMISSION SEED  -  RE-RUNNABLE
   SQL Server 2025  -  database MokaCo_HRMS
   ----------------------------------------------------------------------------
   Run AFTER docs/attendance_full_v3.sql.

   Without these rows every attendance endpoint returns 403: the JWT carries one
   "perm" claim per permission code, and the policy provider demands a matching
   claim. The attendance schema script does not seed them - permissions live in the
   SECURITY schema, which that script deliberately does not own.

   NOTE: ATTENDANCE_VIEW and ATTENDANCE_CORRECT already exist from the original
   security seed (PermissionId 5 and 6). This script is guarded, so it ADDS the four
   missing codes and leaves those two alone rather than duplicating them.

   WHY THE SPLIT IS WHAT IT IS
     ATTENDANCE_VIEW     reading is harmless - most staff can have it.
     ATTENDANCE_MANAGE   running the processor and editing the roster CHANGES the
                         numbers payroll will read, so it is an operator right.
     ATTENDANCE_CORRECT  HR AND THE OPERATIONS MANAGER. Corrections, exit approvals,
                         dispositions, day adjustments and the late / early / missing-punch
                         anomaly decisions all directly change what a person is PAID. It is
                         kept apart from MANAGE precisely so whoever runs the processor
                         cannot also quietly rewrite somebody's hours. The Operations
                         Manager has it because the anomalies are decided by the person who
                         knows why somebody was late — without it the decide endpoints
                         answered 403 for that role (section 4).
     ATTENDANCE_IMPORT   uploading a spreadsheet injects punches into the system.
     DEVICE_MANAGE       a device is a source of truth about pay, so who may add one
                         (and issue its API key) is a security decision, not an admin chore.
     SETTING_MANAGE      the three core.SETTING values silently re-price everyone's
                         exits and part-days. NOT granted to HR - owner-level, not daily.
   ============================================================================ */
USE MokaCo_HRMS;
GO

/* -- 1. permission codes (guarded on Code, which is UNIQUE) ----------------- */
INSERT INTO security.PERMISSION (Code, Name, Module)
SELECT v.Code, v.Name, v.Module
FROM (VALUES
    ('ATTENDANCE_VIEW',    N'View attendance',                 'Attendance'),
    ('ATTENDANCE_MANAGE',  N'Run processor / edit roster',     'Attendance'),
    ('ATTENDANCE_CORRECT', N'Correct attendance',              'Attendance'),
    ('ATTENDANCE_IMPORT',  N'Import punches / map PINs',       'Attendance'),
    ('DEVICE_MANAGE',      N'Manage devices & enrollments',    'Attendance'),
    ('SETTING_MANAGE',     N'Change attendance policy settings','Attendance')
) AS v (Code, Name, Module)
WHERE NOT EXISTS (SELECT 1 FROM security.PERMISSION p WHERE p.Code = v.Code);
GO

/* -- 2. Admin gets all six ------------------------------------------------- */
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
SELECT r.RoleId, p.PermissionId
FROM security.[ROLE] r
CROSS JOIN security.PERMISSION p
WHERE r.Name = 'Admin'
  AND p.Module = 'Attendance'
  AND NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION rp
                  WHERE rp.RoleId = r.RoleId AND rp.PermissionId = p.PermissionId);
GO

/* -- 3. HR gets everything EXCEPT SETTING_MANAGE --------------------------- */
/* HR corrects attendance every day. HR does not get to re-price the standard working
   day, because that silently changes every calculation, past and future, at once. */
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
SELECT r.RoleId, p.PermissionId
FROM security.[ROLE] r
CROSS JOIN security.PERMISSION p
WHERE r.Name = 'HR'
  AND p.Module = 'Attendance'
  AND p.Code <> 'SETTING_MANAGE'
  AND NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION rp
                  WHERE rp.RoleId = r.RoleId AND rp.PermissionId = p.PermissionId);
GO

/* -- 4. Operations Manager may correct attendance and decide anomalies ------ */
/* Only this one code: not MANAGE, IMPORT, DEVICE_MANAGE or SETTING_MANAGE. Guarded, so re-running
   the script (or a database where the owner already granted it on the Role Permissions page)
   changes nothing. */
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
SELECT r.RoleId, p.PermissionId
FROM security.[ROLE] r
CROSS JOIN security.PERMISSION p
WHERE r.Name = 'OperationsManager'
  AND p.Code = 'ATTENDANCE_CORRECT'
  AND NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION rp
                  WHERE rp.RoleId = r.RoleId AND rp.PermissionId = p.PermissionId);
GO

/* -- verify: who can do what ---------------------------------------------- */
SELECT r.Name AS RoleName, p.Code, p.Name AS PermissionName
FROM security.ROLE_PERMISSION rp
JOIN security.[ROLE] r     ON r.RoleId = rp.RoleId
JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
WHERE p.Module = 'Attendance'
ORDER BY r.Name, p.Code;
GO
