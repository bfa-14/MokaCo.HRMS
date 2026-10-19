/* ============================================================================
   tests/qa3/webhr/apply_due_terminations.sql - QA3 REL-4 (docs/106_qa3_webhr.sql).

   Access ends the day after the termination date: hr.usp_Employee_ApplyDueTerminations (nightly)

     D1  an employee whose termination date was YESTERDAY: their login is disabled, they stop being
         the branch's manager, their device PIN mappings are removed (the PIN can be enrolled again),
         and each of those is written to hr.EMPLOYEE_TERMINATION_EFFECT
     D2  terminated TODAY (not yet due), terminated in the FUTURE, and REHIRED (termination date
         cleared) employees keep their login and their PIN mappings
     D3  an approval step still waiting on the leaver is reported (counted and logged), not changed
     D4  a second run changes nothing and applies nobody (idempotent); a login HR re-enabled after
         the sweep stays enabled (each termination is applied once)

   One transaction, rolled back; rows named 'QA3 term ...'. RAISERROR on a wrong result.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(2000) = NULL, @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE),
        @B INT, @D INT, @P INT, @Dev INT, @UA INT, @UB INT, @UC INT, @UD INT, @EA INT, @EB INT, @EC INT, @ED INT,
        @Def INT, @Type INT, @Req INT;
DECLARE @r TABLE (EmployeesApplied INT, UsersDisabled INT, UsersKept INT, BranchManagersCleared INT, PinMappingsRemoved INT,
                  StepsWaiting INT, OpenRequests INT, Summary NVARCHAR(MAX));

BEGIN TRAN;
BEGIN TRY
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 term branch', 1);          SET @B = SCOPE_IDENTITY();
    INSERT INTO hr.DEPARTMENT (Name, IsActive) VALUES (N'QA3 term department', 1);  SET @D = SCOPE_IDENTITY();
    INSERT INTO hr.[POSITION] (Title, IsActive) VALUES (N'QA3 term position', 1);   SET @P = SCOPE_IDENTITY();
    INSERT INTO attendance.DEVICE (SerialNumber, BranchId, IsActive, Name) VALUES ('QA3TERM0001', @B, 1, N'QA3 term device');
    SET @Dev = SCOPE_IDENTITY();

    INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'qa3.term.a', N'x', 1); SET @UA = SCOPE_IDENTITY();
    INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'qa3.term.b', N'x', 1); SET @UB = SCOPE_IDENTITY();
    INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'qa3.term.c', N'x', 1); SET @UC = SCOPE_IDENTITY();
    INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'qa3.term.d', N'x', 1); SET @UD = SCOPE_IDENTITY();

    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@UA, @B, @D, @P, N'QA3 term left yesterday', '2024-01-01', DATEADD(DAY, -1, @Today), 5, 'en');
    SET @EA = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@UB, @B, @D, @P, N'QA3 term leaves today', '2024-01-01', @Today, 5, 'en');
    SET @EB = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@UC, @B, @D, @P, N'QA3 term leaves next month', '2024-01-01', DATEADD(MONTH, 1, @Today), 5, 'en');
    SET @EC = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@UD, @B, @D, @P, N'QA3 term rehired', '2024-01-01', NULL, 5, 'en');
    SET @ED = SCOPE_IDENTITY();

    UPDATE hr.BRANCH SET ManagerEmployeeId = @EA WHERE BranchId = @B;
    INSERT INTO attendance.EMPLOYEE_DEVICE (EmployeeId, DeviceId, EnrollPin)
    VALUES (@EA, @Dev, 'QA3901'), (@EB, @Dev, 'QA3902'), (@EC, @Dev, 'QA3903'), (@ED, @Dev, 'QA3904');

    /* D3: an open request of the rehired employee whose step waits on the leaver */
    SELECT TOP 1 @Def = d.WorkflowDefinitionId, @Type = d.RequestTypeId FROM workflow.WORKFLOW_DEFINITION d ORDER BY d.WorkflowDefinitionId;
    IF @Def IS NOT NULL
    BEGIN
        INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], CurrentStepNo, Title)
        VALUES (@Type, @Def, @ED, @UD, 'Pending', 1, N'QA3 term request');
        SET @Req = SCOPE_IDENTITY();
        INSERT INTO workflow.REQUEST_STEP_INSTANCE (RequestInstanceId, StepNo, Name, ApproverType, ResolvedUserId, [Status])
        VALUES (@Req, 1, N'QA3 term step', 'SpecificUser', @UA, 'Pending');
    END

    /* the sweep */
    INSERT INTO @r EXEC hr.usp_Employee_ApplyDueTerminations;

    /* D1 */
    IF EXISTS (SELECT 1 FROM security.[USER] WHERE UserId = @UA AND IsActive = 1)
        SET @fail = CONCAT(@fail, ' D1: the leaver''s login is still active;');
    IF EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @B AND ManagerEmployeeId = @EA)
        SET @fail = CONCAT(@fail, ' D1: the leaver still manages the branch;');
    IF EXISTS (SELECT 1 FROM attendance.EMPLOYEE_DEVICE WHERE EmployeeId = @EA)
        SET @fail = CONCAT(@fail, ' D1: the leaver''s PIN mapping is still there;');
    IF (SELECT COUNT(*) FROM hr.EMPLOYEE_TERMINATION_EFFECT WHERE EmployeeId = @EA
          AND Effect IN ('Applied', 'UserDisabled', 'BranchManagerCleared', 'PinMappingRemoved')) <> 4
        SET @fail = CONCAT(@fail, ' D1: the four effects of the leaver are not all in the log;');
    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_TERMINATION_EFFECT WHERE EmployeeId = @EA AND Effect = 'PinMappingRemoved' AND Detail LIKE N'%QA3901%')
        SET @fail = CONCAT(@fail, ' D1: the log does not name the removed PIN;');
    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_TERMINATION_EFFECT WHERE EmployeeId = @EA AND Effect = 'BranchManagerCleared' AND Detail LIKE N'%QA3 term branch%')
        SET @fail = CONCAT(@fail, ' D1: the log does not name the branch;');
    IF NOT EXISTS (SELECT 1 FROM @r WHERE EmployeesApplied >= 1 AND UsersDisabled >= 1 AND BranchManagersCleared >= 1 AND PinMappingsRemoved >= 1)
        SET @fail = CONCAT(@fail, ' D1: the summary row does not count the effects;');

    /* D2 */
    IF (SELECT COUNT(*) FROM security.[USER] WHERE UserId IN (@UB, @UC, @UD) AND IsActive = 1) <> 3
        SET @fail = CONCAT(@fail, ' D2: a login of somebody not yet gone (or rehired) was disabled;');
    IF (SELECT COUNT(*) FROM attendance.EMPLOYEE_DEVICE WHERE EmployeeId IN (@EB, @EC, @ED)) <> 3
        SET @fail = CONCAT(@fail, ' D2: a PIN mapping of somebody not yet gone (or rehired) was removed;');
    IF EXISTS (SELECT 1 FROM hr.EMPLOYEE_TERMINATION_EFFECT WHERE EmployeeId IN (@EB, @EC, @ED))
        SET @fail = CONCAT(@fail, ' D2: somebody not yet gone (or rehired) was logged;');

    /* D3 */
    IF @Req IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @Req AND ResolvedUserId = @UA AND [Status] = 'Pending')
            SET @fail = CONCAT(@fail, ' D3: the waiting step was changed (it is reported, not re-routed);');
        IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_TERMINATION_EFFECT WHERE EmployeeId = @EA AND Effect = 'StepsWaiting' AND Detail LIKE CONCAT(N'%#', @Req, N'%'))
            SET @fail = CONCAT(@fail, ' D3: the step waiting on the leaver is not in the log;');
        IF NOT EXISTS (SELECT 1 FROM @r WHERE StepsWaiting >= 1)
            SET @fail = CONCAT(@fail, ' D3: the summary does not count the waiting step;');
    END

    /* D4 */
    UPDATE security.[USER] SET IsActive = 1 WHERE UserId = @UA;      -- HR re-enables the login on purpose
    DELETE FROM @r;
    INSERT INTO @r EXEC hr.usp_Employee_ApplyDueTerminations;
    IF NOT EXISTS (SELECT 1 FROM @r WHERE EmployeesApplied = 0 AND UsersDisabled = 0 AND BranchManagersCleared = 0 AND PinMappingsRemoved = 0)
        SET @fail = CONCAT(@fail, ' D4: a second run applied something again;');
    IF NOT EXISTS (SELECT 1 FROM security.[USER] WHERE UserId = @UA AND IsActive = 1)
        SET @fail = CONCAT(@fail, ' D4: a login HR re-enabled after the sweep was disabled again;');
    IF (SELECT COUNT(*) FROM hr.EMPLOYEE_TERMINATION_EFFECT WHERE EmployeeId = @EA AND Effect = 'Applied') <> 1
        SET @fail = CONCAT(@fail, ' D4: the leaver was applied twice;');
END TRY
BEGIN CATCH
    SET @fail = CONCAT(@fail, ' unexpected error: ', ERROR_MESSAGE(), ' (line ', ERROR_LINE(), ');');
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;

IF @fail IS NOT NULL RAISERROR('FAIL apply_due_terminations:%s', 16, 1, @fail);
ELSE PRINT 'ok apply_due_terminations';
