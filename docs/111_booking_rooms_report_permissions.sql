/* ============================================================================
   111_booking_rooms_report_permissions.sql - THE ROOMS CATALOGUE AND THE BOOKINGS REPORT GET THEIR OWN PERMISSIONS.

   Until now the Rooms page (prices, opening hours, add-ons, discounts) needed BOOKING_MANAGE and the bookings report
   (revenue) BOOKING_VIEW, so everybody who takes bookings at the desk also saw both. Two codes, set on
   Security > Role permissions (card Booking):
     BOOKING_ROOMS    edit the rooms: prices, opening hours, add-ons, discounts   (the API's room writes)
     BOOKING_REPORT   see the bookings report (revenue)                         (GET /api/bookings/report)
   Reading the rooms stays BOOKING_VIEW: the calendar draws a column per room.

   DEFAULT GRANTS, made once - on the run that creates each code, never again (the Role permissions page deletes an
   un-ticked row, so a re-run must not hand back what was taken away): the roles that manage roles or users (Admin)
   and the roles named Owner or General Manager. Every other role - the booking desk included - starts without them.
   The OWNER CHECK line at the end names the roles that hold each code now.

   Also security.usp_Permission_Holders @Code: the roles holding a permission (used by the OWNER CHECK; the MARKER
   of this script for the deploy guard).

   Idempotent. Apply: sqlcmd -C -I -b -d <database> -i docs/111_booking_rooms_report_permissions.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('security.PERMISSION') IS NULL OR OBJECT_ID('security.ROLE_PERMISSION') IS NULL
BEGIN RAISERROR('111_booking_rooms_report_permissions.sql: security.PERMISSION / ROLE_PERMISSION not found. Nothing was applied.', 16, 1); SET NOEXEC ON; END
GO

/* ------------------------- 1. the two permissions, granted once ------------------------- */
DECLARE @new TABLE (Code VARCHAR(50) NOT NULL);
IF NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'BOOKING_ROOMS')
BEGIN
    INSERT INTO security.PERMISSION (Code, Name, Module)
    VALUES ('BOOKING_ROOMS', N'Edit rooms: prices, opening hours, add-ons', 'Booking');
    INSERT INTO @new (Code) VALUES ('BOOKING_ROOMS');
    PRINT 'permission BOOKING_ROOMS created';
END
ELSE PRINT 'permission BOOKING_ROOMS already there (its role grants are left as they are)';
IF NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'BOOKING_REPORT')
BEGIN
    INSERT INTO security.PERMISSION (Code, Name, Module)
    VALUES ('BOOKING_REPORT', N'See the bookings report (revenue)', 'Booking');
    INSERT INTO @new (Code) VALUES ('BOOKING_REPORT');
    PRINT 'permission BOOKING_REPORT created';
END
ELSE PRINT 'permission BOOKING_REPORT already there (its role grants are left as they are)';

INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
SELECT r.RoleId, p.PermissionId
FROM security.[ROLE] r
JOIN security.PERMISSION p ON p.Code IN (SELECT Code FROM @new)
WHERE NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION x WHERE x.RoleId = r.RoleId AND x.PermissionId = p.PermissionId)
  AND (   r.Name IN (N'Owner', N'General Manager')
       OR EXISTS (SELECT 1 FROM security.ROLE_PERMISSION rp JOIN security.PERMISSION q ON q.PermissionId = rp.PermissionId
                  WHERE rp.RoleId = r.RoleId AND q.Code IN ('ROLE_MANAGE', 'USER_MANAGE')));
PRINT CONCAT('default role grants made now: ', @@ROWCOUNT);
GO

/* ------------------------- 2. who holds a permission (the MARKER) ------------------------- */
CREATE OR ALTER PROCEDURE security.usp_Permission_Holders
    @Code VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.RoleId, r.Name AS RoleName,
           (SELECT COUNT(*) FROM security.USER_ROLE ur JOIN security.[USER] u ON u.UserId = ur.UserId
            WHERE ur.RoleId = r.RoleId AND u.IsActive = 1) AS ActiveUsers
    FROM security.[ROLE] r
    JOIN security.ROLE_PERMISSION rp ON rp.RoleId = r.RoleId
    JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
    WHERE p.Code = @Code
    ORDER BY r.Name;
END;
GO

/* ------------------------- 3. OWNER CHECK ------------------------- */
DECLARE @rooms NVARCHAR(MAX) = (SELECT STRING_AGG(r.Name, N', ') FROM security.[ROLE] r JOIN security.ROLE_PERMISSION rp ON rp.RoleId = r.RoleId
                                JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId WHERE p.Code = 'BOOKING_ROOMS');
DECLARE @report NVARCHAR(MAX) = (SELECT STRING_AGG(r.Name, N', ') FROM security.[ROLE] r JOIN security.ROLE_PERMISSION rp ON rp.RoleId = r.RoleId
                                 JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId WHERE p.Code = 'BOOKING_REPORT');
PRINT CONCAT('OWNER CHECK (111): edit rooms: ', ISNULL(@rooms, N'(no role)'), ' | bookings report: ', ISNULL(@report, N'(no role)'),
             '. Change it on Security > Role permissions (card Booking).');
PRINT '111_booking_rooms_report_permissions.sql: the rooms and the bookings report have their own permissions - in place.';
GO

SET NOEXEC OFF;
GO
