/* ============================================================================
   tests/qa3/webhr/swap_counterparts.sql - QA3 WEB-2 (docs/106_qa3_webhr.sql).

   The shift-swap form lists who the requester can swap with. It read GET /api/employees, which is
   branch-scoped since script 87, so a barista saw nobody. hr.usp_Employee_GetSwapCounterparts:

     S1  the requester's own call lists the ACTIVE colleagues of the requester's branch in the SAME
         position - not the requester, not another branch, not another position, not a leaver
         (termination date before today), not a removed employee; somebody leaving later still counts
     S2  the requester comes back too, flagged IsRequester = 1 (name and position, for the form's wording)
     S3  a colleague without EMP_VIEW_ALL, REQUEST_RAISE_OTHERS or the branch's management cannot list
         somebody else's partners (refused); a caller holding EMP_VIEW_ALL can

   One transaction, rolled back; rows named 'QA3 swap ...'. RAISERROR on a wrong result.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(2000) = NULL, @Msg NVARCHAR(400), @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE),
        @B1 INT, @B2 INT, @D INT, @P1 INT, @P2 INT, @UR INT, @UO INT, @UH INT, @RoleHr INT,
        @Req INT, @Mate INT, @Later INT, @Gone INT, @Removed INT, @Elsewhere INT, @OtherPos INT;
DECLARE @list TABLE (EmployeeId INT, FullName NVARCHAR(150), Position NVARCHAR(100), Branch NVARCHAR(100), TerminationDate DATE, IsRequester BIT);

BEGIN TRAN;
BEGIN TRY
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 swap branch', 1);        SET @B1 = SCOPE_IDENTITY();
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 swap elsewhere', 1);     SET @B2 = SCOPE_IDENTITY();
    INSERT INTO hr.DEPARTMENT (Name, IsActive) VALUES (N'QA3 swap department', 1); SET @D = SCOPE_IDENTITY();
    INSERT INTO hr.[POSITION] (Title, IsActive) VALUES (N'QA3 swap barista', 1);   SET @P1 = SCOPE_IDENTITY();
    INSERT INTO hr.[POSITION] (Title, IsActive) VALUES (N'QA3 swap cashier', 1);   SET @P2 = SCOPE_IDENTITY();
    INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'qa3.swap.requester', N'x', 1); SET @UR = SCOPE_IDENTITY();
    INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'qa3.swap.other', N'x', 1);     SET @UO = SCOPE_IDENTITY();
    INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'qa3.swap.hr', N'x', 1);        SET @UH = SCOPE_IDENTITY();
    /* the HR user holds EMP_VIEW_ALL through a throw-away role */
    INSERT INTO security.[ROLE] (Name) VALUES (N'QA3 swap viewer'); SET @RoleHr = SCOPE_IDENTITY();
    INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId) SELECT @RoleHr, PermissionId FROM security.PERMISSION WHERE Code = 'EMP_VIEW_ALL';
    INSERT INTO security.USER_ROLE (UserId, RoleId) VALUES (@UH, @RoleHr);

    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@UR, @B1, @D, @P1, N'QA3 swap requester', '2024-01-01', NULL, 5, 'en');                         SET @Req = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (NULL, @B1, @D, @P1, N'QA3 swap mate', '2024-01-01', NULL, 5, 'en');                              SET @Mate = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (NULL, @B1, @D, @P1, N'QA3 swap leaving later', '2024-01-01', DATEADD(DAY, 20, @Today), 5, 'en');  SET @Later = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (NULL, @B1, @D, @P1, N'QA3 swap gone', '2024-01-01', DATEADD(DAY, -1, @Today), 5, 'en');           SET @Gone = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage, IsDeleted)
    VALUES (NULL, @B1, @D, @P1, N'QA3 swap removed', '2024-01-01', NULL, 5, 'en', 1);                         SET @Removed = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@UO, @B1, @D, @P2, N'QA3 swap other position', '2024-01-01', NULL, 5, 'en');                       SET @OtherPos = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (NULL, @B2, @D, @P1, N'QA3 swap other branch', '2024-01-01', NULL, 5, 'en');                        SET @Elsewhere = SCOPE_IDENTITY();

    /* S1 + S2 */
    INSERT INTO @list EXEC hr.usp_Employee_GetSwapCounterparts @EmployeeId = @Req, @CallerUserId = @UR;
    IF (SELECT COUNT(*) FROM @list WHERE IsRequester = 1) <> 1
       OR NOT EXISTS (SELECT 1 FROM @list WHERE IsRequester = 1 AND EmployeeId = @Req AND Position = N'QA3 swap barista' AND Branch = N'QA3 swap branch')
        SET @fail = CONCAT(@fail, ' S2: the requester row is missing or wrong;');
    IF (SELECT COUNT(*) FROM @list WHERE IsRequester = 0) <> 2
       OR NOT EXISTS (SELECT 1 FROM @list WHERE IsRequester = 0 AND EmployeeId = @Mate)
       OR NOT EXISTS (SELECT 1 FROM @list WHERE IsRequester = 0 AND EmployeeId = @Later)
        SET @fail = CONCAT(@fail, ' S1: expected exactly the mate and the one leaving later, got ',
                           (SELECT STRING_AGG(FullName, N', ') FROM @list WHERE IsRequester = 0), ';');

    /* S3 */
    SET @Msg = NULL;
    BEGIN TRY
        DELETE FROM @list;
        INSERT INTO @list EXEC hr.usp_Employee_GetSwapCounterparts @EmployeeId = @Req, @CallerUserId = @UO;
    END TRY
    BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
    IF @Msg IS NULL OR EXISTS (SELECT 1 FROM @list)
        SET @fail = CONCAT(@fail, ' S3: a colleague listed somebody else''s swap partners;');
    BEGIN TRY
        DELETE FROM @list;
        INSERT INTO @list EXEC hr.usp_Employee_GetSwapCounterparts @EmployeeId = @Req, @CallerUserId = @UH;
    END TRY
    BEGIN CATCH SET @fail = CONCAT(@fail, ' S3: a caller with EMP_VIEW_ALL was refused: ', ERROR_MESSAGE(), ';'); END CATCH;
    IF (SELECT COUNT(*) FROM @list WHERE IsRequester = 0) <> 2
        SET @fail = CONCAT(@fail, ' S3: a caller with EMP_VIEW_ALL did not get the list;');
END TRY
BEGIN CATCH
    SET @fail = CONCAT(@fail, ' unexpected error: ', ERROR_MESSAGE(), ' (line ', ERROR_LINE(), ');');
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;

IF @fail IS NOT NULL RAISERROR('FAIL swap_counterparts:%s', 16, 1, @fail);
ELSE PRINT 'ok swap_counterparts';
