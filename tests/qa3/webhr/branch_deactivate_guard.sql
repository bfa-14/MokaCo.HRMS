/* ============================================================================
   tests/qa3/webhr/branch_deactivate_guard.sql - QA3 suspicion "branch deactivation unguarded"
   (docs/106_qa3_webhr.sql).

   A deactivated branch disappears from every pick-list, but its people stayed in it: rosters,
   attendance and requests kept pointing at a branch nobody could choose any more.

     G1  hr.usp_Branch_SetActive refuses to deactivate a branch that still has active employees, and
         the sentence says how many; hr.usp_Branch_Update (the edit form's Active box) refuses the same
     G2  somebody leaving LATER counts as active; somebody who has LEFT and a removed employee do not
     G3  an employee transferred INTO the branch on a later date counts too
     G4  once nobody active belongs to it the branch can be deactivated, and reactivated

   One transaction, rolled back; rows named 'QA3 branch ...'. RAISERROR on a wrong result.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(2000) = NULL, @Msg NVARCHAR(400), @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE),
        @B INT, @B2 INT, @D INT, @P INT, @E1 INT, @E2 INT, @E3 INT;

BEGIN TRAN;
BEGIN TRY
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 branch closing', 1);      SET @B = SCOPE_IDENTITY();
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 branch other', 1);        SET @B2 = SCOPE_IDENTITY();
    INSERT INTO hr.DEPARTMENT (Name, IsActive) VALUES (N'QA3 branch department', 1); SET @D = SCOPE_IDENTITY();
    INSERT INTO hr.[POSITION] (Title, IsActive) VALUES (N'QA3 branch position', 1);  SET @P = SCOPE_IDENTITY();

    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@B, @D, @P, N'QA3 branch active', '2024-01-01', NULL, 5, 'en');                           SET @E1 = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@B, @D, @P, N'QA3 branch leaving later', '2024-01-01', DATEADD(DAY, 10, @Today), 5, 'en'); SET @E2 = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@B, @D, @P, N'QA3 branch left', '2024-01-01', DATEADD(DAY, -10, @Today), 5, 'en');        SET @E3 = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage, IsDeleted)
    VALUES (@B, @D, @P, N'QA3 branch removed', '2024-01-01', NULL, 5, 'en', 1);

    /* G1 + G2: two active (one leaving later), one gone, one removed */
    SET @Msg = NULL;
    BEGIN TRY EXEC hr.usp_Branch_SetActive @BranchId = @B, @IsActive = 0; END TRY
    BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
    IF @Msg IS NULL OR @Msg NOT LIKE N'%2 %' OR EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @B AND IsActive = 0)
        SET @fail = CONCAT(@fail, ' G1: SetActive deactivated a branch with 2 active employees (', ISNULL(@Msg, 'no refusal'), ');');
    SET @Msg = NULL;
    BEGIN TRY EXEC hr.usp_Branch_Update @BranchId = @B, @Name = N'QA3 branch closing', @IsActive = 0; END TRY
    BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
    IF @Msg IS NULL OR EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @B AND IsActive = 0)
        SET @fail = CONCAT(@fail, ' G1: Update deactivated a branch with active employees;');
    /* a rename that keeps it active is not a deactivation */
    BEGIN TRY EXEC hr.usp_Branch_Update @BranchId = @B, @Name = N'QA3 branch closing soon', @IsActive = 1; END TRY
    BEGIN CATCH SET @fail = CONCAT(@fail, ' G1: renaming an active branch was refused: ', ERROR_MESSAGE(), ';'); END CATCH;

    /* G3: both move out today, but somebody else is transferred in next week */
    UPDATE hr.EMPLOYEE SET BranchId = @B2 WHERE EmployeeId IN (@E1, @E2);
    UPDATE hr.EMPLOYEE SET BranchId = @B2 WHERE EmployeeId = @E3;
    INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom, Note)
    VALUES (@E1, @B, DATEADD(DAY, 7, @Today), N'QA3 transfer back next week');
    SET @Msg = NULL;
    BEGIN TRY EXEC hr.usp_Branch_SetActive @BranchId = @B, @IsActive = 0; END TRY
    BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
    IF @Msg IS NULL OR EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @B AND IsActive = 0)
        SET @fail = CONCAT(@fail, ' G3: a branch with a transfer in on file was deactivated;');

    /* G4 */
    DELETE FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeId = @E1 AND BranchId = @B AND EffectiveFrom > @Today;
    BEGIN TRY EXEC hr.usp_Branch_SetActive @BranchId = @B, @IsActive = 0; END TRY
    BEGIN CATCH SET @fail = CONCAT(@fail, ' G4: an empty branch could not be deactivated: ', ERROR_MESSAGE(), ';'); END CATCH;
    IF NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @B AND IsActive = 0)
        SET @fail = CONCAT(@fail, ' G4: the empty branch is still active;');
    BEGIN TRY EXEC hr.usp_Branch_Update @BranchId = @B, @Name = N'QA3 branch closing', @IsActive = 1; END TRY
    BEGIN CATCH SET @fail = CONCAT(@fail, ' G4: reactivating failed: ', ERROR_MESSAGE(), ';'); END CATCH;
    IF NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @B AND IsActive = 1)
        SET @fail = CONCAT(@fail, ' G4: the branch was not reactivated;');
END TRY
BEGIN CATCH
    SET @fail = CONCAT(@fail, ' unexpected error: ', ERROR_MESSAGE(), ' (line ', ERROR_LINE(), ');');
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;

IF @fail IS NOT NULL RAISERROR('FAIL branch_deactivate_guard:%s', 16, 1, @fail);
ELSE PRINT 'ok branch_deactivate_guard';
