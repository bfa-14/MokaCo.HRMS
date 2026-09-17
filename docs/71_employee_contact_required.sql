/* ============================================================================
   71_employee_contact_required.sql — a NEW employee must have a phone number
   and an e-mail address. hr.usp_Employee_Create refuses when either is
   NULL/blank; hr.usp_Employee_Update is deliberately untouched (older staff
   may lack them, and an edit must not be blocked by a field it did not touch).
   The API validates the format (valid address; Lebanese 8 digits or +961…)
   and normalises before calling this; the procedure guards the invariant that
   matters regardless of caller.
   Parameters and result set are unchanged from 51/employee_create_link_guard.
   Idempotent. Run with sqlcmd -I.
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE [hr].[usp_Employee_Create]
    @UserId INT = NULL, @BranchId INT, @DepartmentId INT, @PositionId INT,
    @FullName NVARCHAR(150), @NationalId VARCHAR(50) = NULL, @NssfNumber VARCHAR(50) = NULL,
    @HireDate DATE, @CreatedBy INT = NULL,
    @Email NVARCHAR(150) = NULL, @PhoneNumber VARCHAR(30) = NULL,
    @PreferredLanguage CHAR(2) = 'en'
AS
BEGIN
    SET NOCOUNT ON;

    SET @Email       = NULLIF(LTRIM(RTRIM(@Email)), N'');
    SET @PhoneNumber = NULLIF(LTRIM(RTRIM(@PhoneNumber)), '');

    IF @Email IS NULL OR @PhoneNumber IS NULL
    BEGIN
        RAISERROR('Phone number and e-mail are required for a new employee.', 16, 1);
        RETURN;
    END

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
                             NationalId, NssfNumber, HireDate, CreatedBy,
                             Email, PhoneNumber, PreferredLanguage)
    VALUES (@UserId, @BranchId, @DepartmentId, @PositionId, @FullName,
            @NationalId, @NssfNumber, @HireDate, @CreatedBy,
            @Email, @PhoneNumber,
            ISNULL(@PreferredLanguage, 'en'));

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS EmployeeId;
END;
GO
