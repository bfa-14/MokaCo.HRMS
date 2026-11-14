/* ============================================================================
   112_my_branch_shifts_permission.sql - EMPLOYEES SEE THEIR OWN BRANCH'S WEEKLY SHIFTS.

   The Weekly shifts poster (Attendance > Weekly shifts) needs ATTENDANCE_VIEW, which also opens everybody's
   attendance. One code, set on Security > Role permissions (card Attendance), opens a read-only copy of the
   poster in the "My" part of the menu:
     SHIFTS_VIEW_BRANCH   see my branch's weekly shifts     (GET /api/me/team-shifts)
   It shows who works which shift on which day, in the branch of the signed-in employee only: no attendance, no
   leave (somebody on approved leave for the whole day is simply not on the poster), nothing of other branches.

   DEFAULT GRANT, made once - on the run that creates the code, never again (the Role permissions page deletes an
   un-ticked row, so a re-run must not hand back what was taken away): every role that may raise its own requests
   (REQUEST_RAISE_SELF), i.e. the roles of people who work in a branch. The OWNER CHECK line at the end names the
   roles that hold it now.

   No procedure: the API reads the roster it already reads for "My attendance". So this script is not on the API's
   deploy guard (Scripts.Required); deploy/check-scripts.sql checks it by the permission row.

   Idempotent. Apply: sqlcmd -C -I -b -d <database> -i docs/112_my_branch_shifts_permission.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('security.PERMISSION') IS NULL OR OBJECT_ID('security.ROLE_PERMISSION') IS NULL
BEGIN RAISERROR('112_my_branch_shifts_permission.sql: security.PERMISSION / ROLE_PERMISSION not found. Nothing was applied.', 16, 1); SET NOEXEC ON; END
GO

/* ------------------------- 1. the permission, granted once ------------------------- */
IF NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'SHIFTS_VIEW_BRANCH')
BEGIN
    INSERT INTO security.PERMISSION (Code, Name, Module)
    VALUES ('SHIFTS_VIEW_BRANCH', N'See my branch''s weekly shifts', 'Attendance');
    PRINT 'permission SHIFTS_VIEW_BRANCH created';

    INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
    SELECT DISTINCT rp.RoleId, p.PermissionId
    FROM security.ROLE_PERMISSION rp
    JOIN security.PERMISSION q ON q.PermissionId = rp.PermissionId AND q.Code = 'REQUEST_RAISE_SELF'
    CROSS JOIN security.PERMISSION p
    WHERE p.Code = 'SHIFTS_VIEW_BRANCH'
      AND NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION x WHERE x.RoleId = rp.RoleId AND x.PermissionId = p.PermissionId);
    PRINT CONCAT('default role grants made now: ', @@ROWCOUNT);
END
ELSE PRINT 'permission SHIFTS_VIEW_BRANCH already there (its role grants are left as they are)';
GO

/* ------------------------- 2. OWNER CHECK ------------------------- */
DECLARE @holders NVARCHAR(MAX) = (SELECT STRING_AGG(r.Name, N', ') FROM security.[ROLE] r JOIN security.ROLE_PERMISSION rp ON rp.RoleId = r.RoleId
                                  JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId WHERE p.Code = 'SHIFTS_VIEW_BRANCH');
PRINT CONCAT('OWNER CHECK (112): my branch''s weekly shifts: ', ISNULL(@holders, N'(no role)'),
             '. Change it on Security > Role permissions (card Attendance).');
PRINT '112_my_branch_shifts_permission.sql: employees can see their branch''s weekly shifts - in place.';
GO

SET NOEXEC OFF;
GO
