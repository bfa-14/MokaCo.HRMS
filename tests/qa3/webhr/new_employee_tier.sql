/* ============================================================================
   tests/qa3/webhr/new_employee_tier.sql - QA3 LEAD-1 (docs/106_qa3_webhr.sql).

   Tier 1 is the HEAD of the organisation since decision D6, so a new employee who was given no tier
   must land on the LOWEST tier (the highest TierNo in hr.APPROVAL_TIER), never on tier 1.

     T1  hr.usp_Employee_Create without @ApprovalTier -> the lowest tier of the dictionary
     T2  hr.usp_Employee_Create with a tier of the dictionary -> that tier
     T3  hr.usp_Employee_Create with a tier the dictionary does not have -> refused, nothing created
     T4  an INSERT that names no tier (any other path) -> the column default, the lowest tier
     T5  hr.usp_Employee_SetApprovalTier accepts every tier of the dictionary (5 included: the old
         copy accepted only 1-3) and refuses one the dictionary does not have

   One transaction, rolled back; rows named 'QA3 tier ...'. RAISERROR on a wrong result.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(2000) = NULL, @Msg NVARCHAR(400), @B INT, @D INT, @P INT, @Lowest INT, @Mid INT, @Bad INT,
        @E1 INT, @E2 INT, @E4 INT, @Tier INT;
DECLARE @id TABLE (EmployeeId INT);
DECLARE @set TABLE (EmployeeId INT, FullName NVARCHAR(150), ApprovalTier INT);

BEGIN TRAN;
BEGIN TRY
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 tier branch', 1);          SET @B = SCOPE_IDENTITY();
    INSERT INTO hr.DEPARTMENT (Name, IsActive) VALUES (N'QA3 tier department', 1);  SET @D = SCOPE_IDENTITY();
    INSERT INTO hr.[POSITION] (Title, IsActive) VALUES (N'QA3 tier position', 1);   SET @P = SCOPE_IDENTITY();

    /* the dictionary as this database has it, plus one tier below everything for the test */
    SELECT @Lowest = MAX(TierNo) + 1 FROM hr.APPROVAL_TIER;
    INSERT INTO hr.APPROVAL_TIER (TierNo, Name) VALUES (@Lowest, N'QA3 lowest tier');
    SELECT @Mid = MIN(TierNo) FROM hr.APPROVAL_TIER WHERE TierNo > 1;
    SET @Bad = @Lowest + 50;

    /* T1 */
    INSERT INTO @id EXEC hr.usp_Employee_Create @BranchId = @B, @DepartmentId = @D, @PositionId = @P,
         @FullName = N'QA3 tier no choice', @HireDate = '2026-01-05', @Email = N'qa3.tier1@example.com', @PhoneNumber = '+9613123456';
    SELECT @E1 = EmployeeId FROM @id;
    SELECT @Tier = ApprovalTier FROM hr.EMPLOYEE WHERE EmployeeId = @E1;
    IF @E1 IS NULL OR ISNULL(@Tier, -1) <> @Lowest
        SET @fail = CONCAT(@fail, ' T1: a new employee without a tier got tier ', ISNULL(CONVERT(VARCHAR(10), @Tier), 'none'), ', expected the lowest (', @Lowest, ');');

    /* T2 */
    DELETE FROM @id;
    BEGIN TRY
        INSERT INTO @id EXEC hr.usp_Employee_Create @BranchId = @B, @DepartmentId = @D, @PositionId = @P,
             @FullName = N'QA3 tier chosen', @HireDate = '2026-01-05', @Email = N'qa3.tier2@example.com', @PhoneNumber = '+9613123457',
             @ApprovalTier = @Mid;
    END TRY
    BEGIN CATCH SET @fail = CONCAT(@fail, ' T2: create with a chosen tier failed: ', ERROR_MESSAGE(), ';'); END CATCH;
    SELECT @E2 = EmployeeId FROM @id;
    SELECT @Tier = ApprovalTier FROM hr.EMPLOYEE WHERE EmployeeId = @E2;
    IF @E2 IS NULL OR ISNULL(@Tier, -1) <> @Mid
        SET @fail = CONCAT(@fail, ' T2: the chosen tier ', @Mid, ' was not stored;');

    /* T3 */
    SET @Msg = NULL;
    BEGIN TRY
        DELETE FROM @id;
        INSERT INTO @id EXEC hr.usp_Employee_Create @BranchId = @B, @DepartmentId = @D, @PositionId = @P,
             @FullName = N'QA3 tier unknown', @HireDate = '2026-01-05', @Email = N'qa3.tier3@example.com', @PhoneNumber = '+9613123458',
             @ApprovalTier = @Bad;
    END TRY
    BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
    IF @Msg IS NULL OR @Msg NOT LIKE N'%tier%' OR EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE FullName = N'QA3 tier unknown')
        SET @fail = CONCAT(@fail, ' T3: an unknown tier was not refused (', ISNULL(@Msg, 'no message'), ');');

    /* T4 */
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, PreferredLanguage)
    VALUES (@B, @D, @P, N'QA3 tier direct insert', '2026-01-05', 'en');
    SET @E4 = SCOPE_IDENTITY();
    SELECT @Tier = ApprovalTier FROM hr.EMPLOYEE WHERE EmployeeId = @E4;
    IF ISNULL(@Tier, -1) <> @Lowest
        SET @fail = CONCAT(@fail, ' T4: an insert naming no tier got tier ', @Tier, ' from the column default, expected ', @Lowest, ';');

    /* T5 */
    BEGIN TRY
        INSERT INTO @set EXEC hr.usp_Employee_SetApprovalTier @EmployeeId = @E1, @ApprovalTier = 5;
    END TRY
    BEGIN CATCH SET @fail = CONCAT(@fail, ' T5: tier 5 was refused: ', ERROR_MESSAGE(), ';'); END CATCH;
    IF NOT EXISTS (SELECT 1 FROM hr.APPROVAL_TIER WHERE TierNo = 5)
        SET @fail = CONCAT(@fail, ' T5: (setup) this database has no tier 5;');
    ELSE IF NOT EXISTS (SELECT 1 FROM @set WHERE EmployeeId = @E1 AND ApprovalTier = 5)
        SET @fail = CONCAT(@fail, ' T5: tier 5 was not set;');
    SET @Msg = NULL;
    BEGIN TRY
        INSERT INTO @set EXEC hr.usp_Employee_SetApprovalTier @EmployeeId = @E1, @ApprovalTier = @Bad;
    END TRY
    BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
    SELECT @Tier = ApprovalTier FROM hr.EMPLOYEE WHERE EmployeeId = @E1;
    IF @Msg IS NULL OR @Tier <> 5
        SET @fail = CONCAT(@fail, ' T5: a tier outside the dictionary was not refused;');
END TRY
BEGIN CATCH
    SET @fail = CONCAT(@fail, ' unexpected error: ', ERROR_MESSAGE(), ' (line ', ERROR_LINE(), ');');
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;

IF @fail IS NOT NULL RAISERROR('FAIL new_employee_tier:%s', 16, 1, @fail);
ELSE PRINT 'ok new_employee_tier';
