/* ============================================================================
   EMPLOYEE CREATE  -  friendly duplicate-account guard
   MokaCo_HRMS   (ALTERs hr.usp_Employee_Create only)
   ----------------------------------------------------------------------------
   hr.EMPLOYEE has a FILTERED unique index UQ_Employee_UserId, so creating an
   employee with an account another employee already holds fails at the database
   with a raw unique-index violation. This adds the SAME friendly refusal
   usp_Employee_LinkUser gives — naming the other employee — BEFORE the insert, so
   the create endpoint can surface it (mapped to a 400 by WorkflowSqlErrors) instead
   of a constraint error. The message lives in SQL, next to the identical one in
   LinkUser.

   QUOTED_IDENTIFIER ON is REQUIRED: this proc does DML on a table with a filtered
   index, and the setting is baked in at CREATE time (sqlcmd defaults it OFF).
   ============================================================================ */
USE MokaCo_HRMS;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE hr.usp_Employee_Create
    @UserId INT = NULL, @BranchId INT, @DepartmentId INT, @PositionId INT,
    @FullName NVARCHAR(150), @NationalId VARCHAR(50) = NULL, @NssfNumber VARCHAR(50) = NULL,
    @HireDate DATE, @CreatedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /* Same refusal as usp_Employee_LinkUser: a taken account names its holder, never
       surfaces as a raw unique-index violation. */
    IF @UserId IS NOT NULL
    BEGIN
        DECLARE @TakenBy NVARCHAR(150) = (
            SELECT TOP 1 e.FullName FROM hr.EMPLOYEE e
            WHERE e.UserId = @UserId AND e.IsDeleted = 0);
        IF @TakenBy IS NOT NULL
        BEGIN
            RAISERROR('That account is already linked to %s. Unlink it from them first.', 16, 1, @TakenBy);
            RETURN;
        END
    END

    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName,
                             NationalId, NssfNumber, HireDate, CreatedBy)
    VALUES (@UserId, @BranchId, @DepartmentId, @PositionId, @FullName,
            @NationalId, @NssfNumber, @HireDate, @CreatedBy);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS EmployeeId;
END;
GO
