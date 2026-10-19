/* ============================================================================
   tests/qa3/webhr/ops_manager_view_all.sql - the Operations Manager sees every branch
   (docs/106_qa3_webhr.sql; handoff section 12, decided by the owner).

     O1  every role named 'Operations Manager' or 'OperationsManager' holds EMP_VIEW_ALL
     O2  so hr.fn_CallerScope says SeesAll = 1 for a user who holds only that role

   Read-only apart from a throw-away user, rolled back. Prints 'ok ... (no such role here)' when the
   database has neither spelling of the role. RAISERROR on a wrong result.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(2000) = NULL, @Role INT, @U INT, @Sees BIT;

BEGIN TRAN;
BEGIN TRY
    SELECT TOP 1 @Role = RoleId FROM security.[ROLE] WHERE Name IN (N'Operations Manager', N'OperationsManager') ORDER BY RoleId;
    IF @Role IS NOT NULL
    BEGIN
        /* O1 */
        IF EXISTS (SELECT 1 FROM security.[ROLE] r
                   WHERE r.Name IN (N'Operations Manager', N'OperationsManager')
                     AND NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION rp JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
                                     WHERE rp.RoleId = r.RoleId AND p.Code = 'EMP_VIEW_ALL'))
            SET @fail = CONCAT(@fail, ' O1: an Operations Manager role lacks EMP_VIEW_ALL;');
        /* O2 */
        INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'qa3.ops.viewer', N'x', 1); SET @U = SCOPE_IDENTITY();
        INSERT INTO security.USER_ROLE (UserId, RoleId) VALUES (@U, @Role);
        SELECT @Sees = SeesAll FROM hr.fn_CallerScope(@U);
        IF ISNULL(@Sees, 0) <> 1
            SET @fail = CONCAT(@fail, ' O2: an Operations Manager is still limited to the branches they manage;');
    END
END TRY
BEGIN CATCH
    SET @fail = CONCAT(@fail, ' unexpected error: ', ERROR_MESSAGE(), ' (line ', ERROR_LINE(), ');');
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;

IF @fail IS NOT NULL RAISERROR('FAIL ops_manager_view_all:%s', 16, 1, @fail);
ELSE IF @Role IS NULL PRINT 'ok ops_manager_view_all (no such role here)';
ELSE PRINT 'ok ops_manager_view_all';
