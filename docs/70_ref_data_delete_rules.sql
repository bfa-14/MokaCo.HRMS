/* ============================================================================
   70_ref_data_delete_rules.sql — reference data can be deleted only when
   nothing references it; otherwise the delete is REFUSED with a sentence the
   UI can show, and the row is deactivated instead.

   · core.usp_Object_GetReferences — generic: walks sys.foreign_keys for the
     given table, counts the rows in every referencing table (sp_executesql)
     and returns "12 employees, 340 payslip lines" (plain words per table,
     falling back to the table name).
   · core.fn_ListWithAnd — "a, b, c" → "a, b and c" for the sentence.
   · IsActive on hr.LEAVE_TYPE and hr.COMPONENT_TYPE (BRANCH / DEPARTMENT /
     POSITION already have it), exposed by the GetAll / Upsert procs.
   · hr.usp_LeaveType_Delete · usp_ComponentType_Delete · usp_Position_Delete
     · usp_Department_Delete · usp_Branch_Delete — hard-delete when unused,
     RAISERROR "Cannot delete 'X': it is used by … . Deactivate it instead."
   · hr.usp_*_SetActive — the "deactivate instead" path.
   Every refusal is RAISERROR(msg,16,1) + RETURN (ROLLBACK inside a tran).
   Idempotent (CREATE OR ALTER / IF NOT EXISTS). Run with sqlcmd -I.
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---- 1. IsActive where missing ---------------------------------------------- */
IF COL_LENGTH('hr.LEAVE_TYPE', 'IsActive') IS NULL
    ALTER TABLE hr.LEAVE_TYPE ADD IsActive BIT NOT NULL CONSTRAINT DF_LEAVE_TYPE_IsActive DEFAULT 1;
IF COL_LENGTH('hr.COMPONENT_TYPE', 'IsActive') IS NULL
    ALTER TABLE hr.COMPONENT_TYPE ADD IsActive BIT NOT NULL CONSTRAINT DF_COMPONENT_TYPE_IsActive DEFAULT 1;
GO

/* ---- 2. "a, b, c" → "a, b and c" ------------------------------------------- */
CREATE OR ALTER FUNCTION core.fn_ListWithAnd (@List NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    IF @List IS NULL RETURN NULL;
    DECLARE @r NVARCHAR(MAX) = REVERSE(@List);
    DECLARE @p INT = CHARINDEX(N' ,', @r);          -- the LAST ", " of the original
    IF @p = 0 RETURN @List;
    RETURN REVERSE(STUFF(@r, @p, 2, N' dna '));     -- " and " reversed
END;
GO

/* ---- 3. Generic reference counter ------------------------------------------- */
/* @Summary comes back NULL when nothing references the row, otherwise
   "12 employees, 340 payslip lines" ordered by count desc. @ExcludeTables is an
   optional comma list of 'schema.table' to leave out — for child rows that are
   PART of the object (a leave type's own tiers) rather than uses of it. */
CREATE OR ALTER PROCEDURE core.usp_Object_GetReferences
    @Schema        SYSNAME,
    @Table         SYSNAME,
    @KeyColumn     SYSNAME,
    @Id            INT,
    @Summary       NVARCHAR(MAX) OUTPUT,
    @ExcludeTables NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Summary = NULL;

    DECLARE @Target INT = OBJECT_ID(QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table));
    IF @Target IS NULL
    BEGIN RAISERROR('Unknown table %s.%s.', 16, 1, @Schema, @Table); RETURN; END

    DECLARE @refs TABLE (Ord INT IDENTITY(1,1), RefSchema SYSNAME, RefTable SYSNAME, RefColumn SYSNAME, Cnt INT NULL);

    INSERT INTO @refs (RefSchema, RefTable, RefColumn)
    SELECT DISTINCT
           OBJECT_SCHEMA_NAME(fk.parent_object_id),
           OBJECT_NAME(fk.parent_object_id),
           COL_NAME(fkc.parent_object_id, fkc.parent_column_id)
    FROM sys.foreign_keys fk
    JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    WHERE fk.referenced_object_id = @Target
      AND COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id) = @KeyColumn
      AND (@ExcludeTables IS NULL OR NOT EXISTS (
              SELECT 1 FROM STRING_SPLIT(@ExcludeTables, ',') x
              WHERE LTRIM(RTRIM(x.value)) = OBJECT_SCHEMA_NAME(fk.parent_object_id) + N'.' + OBJECT_NAME(fk.parent_object_id)));

    DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @refs);
    DECLARE @s SYSNAME, @t SYSNAME, @c SYSNAME, @sql NVARCHAR(MAX), @cnt INT;
    WHILE @i <= @n
    BEGIN
        SELECT @s = RefSchema, @t = RefTable, @c = RefColumn FROM @refs WHERE Ord = @i;
        SET @sql = N'SELECT @cnt = COUNT(*) FROM ' + QUOTENAME(@s) + N'.' + QUOTENAME(@t)
                 + N' WHERE ' + QUOTENAME(@c) + N' = @Id;';
        EXEC sp_executesql @sql, N'@Id INT, @cnt INT OUTPUT', @Id = @Id, @cnt = @cnt OUTPUT;
        UPDATE @refs SET Cnt = @cnt WHERE Ord = @i;
        SET @i += 1;
    END

    /* plain words per table; anything unmapped falls back to the table name */
    ;WITH words (Tbl, Singular, Plural) AS (
        SELECT * FROM (VALUES
            ('hr.EMPLOYEE',                        'employee',                   'employees'),
            ('hr.SALARY_COMPONENT',                'salary component',           'salary components'),
            ('payroll.PAYSLIP_LINE',               'payslip line',               'payslip lines'),
            ('payroll.PAYROLL_ADJUSTMENT',         'payroll adjustment',         'payroll adjustments'),
            ('workflow.PAYROLL_ADJUSTMENT_REQUEST','payroll adjustment request', 'payroll adjustment requests'),
            ('hr.LEAVE_LEDGER',                    'leave ledger entry',         'leave ledger entries'),
            ('workflow.LEAVE_REQUEST',             'leave request',              'leave requests'),
            ('hr.LEAVE_ACCRUAL_TIER',              'accrual tier',               'accrual tiers'),
            ('hr.LEAVE_PAY_TIER',                  'pay tier',                   'pay tiers'),
            ('hr.LEAVE_RELATION_ENTITLEMENT',      'relation entitlement',       'relation entitlements'),
            ('attendance.ATTENDANCE_RECORD',       'attendance record',          'attendance records'),
            ('attendance.DEVICE',                  'attendance device',          'attendance devices'),
            ('attendance.SHIFT_ASSIGNMENT',        'roster row',                 'roster rows'),
            ('attendance.ROSTER_MONTH',            'roster month',               'roster months'),
            ('workflow.ROSTER_APPROVAL',           'roster approval request',    'roster approval requests'),
            ('workflow.ONBOARDING',                'onboarding request',         'onboarding requests'),
            ('workflow.TIP_DISTRIBUTION',          'tip distribution',           'tip distributions'),
            ('workflow.REQUEST_INSTANCE',          'request',                    'requests'),
            ('booking.BOOKING',                    'booking',                    'bookings'),
            ('booking.ROOM',                       'room',                       'rooms')
        ) v (Tbl, Singular, Plural)
    )
    SELECT @Summary = STRING_AGG(
               CONCAT(r.Cnt, N' ', CASE WHEN r.Cnt = 1 THEN ISNULL(w.Singular, LOWER(REPLACE(r.RefTable, '_', ' ')))
                                        ELSE ISNULL(w.Plural, LOWER(REPLACE(r.RefTable, '_', ' ')) + N's') END),
               N', ') WITHIN GROUP (ORDER BY r.Cnt DESC, r.RefTable)
    FROM @refs r
    LEFT JOIN words w ON w.Tbl = r.RefSchema + '.' + r.RefTable
    WHERE r.Cnt > 0;
END;
GO

/* ---- 4. Reads expose IsActive ------------------------------------------------ */
CREATE OR ALTER PROCEDURE hr.usp_LeaveType_GetAll
AS
BEGIN
    SET NOCOUNT ON;
    SELECT LeaveTypeId, Name, IsPaid, CarryOver,
           RequiresCertificate, MinServiceMonthsToUse, NoticePreferredDays,
           FixedEntitlementDays, IsDiscretionary, IsActive
    FROM hr.LEAVE_TYPE
    ORDER BY Name;
END;
GO

CREATE OR ALTER PROCEDURE hr.usp_LeavePolicy_GetAll
AS BEGIN SET NOCOUNT ON;
    SELECT LeaveTypeId, Name, IsPaid, CarryOver,
           RequiresCertificate, MinServiceMonthsToUse, NoticePreferredDays,
           FixedEntitlementDays, IsDiscretionary, IsActive
    FROM hr.LEAVE_TYPE ORDER BY Name;
    SELECT LeaveTypeId, MinServiceYears, AnnualDays
    FROM hr.LEAVE_ACCRUAL_TIER ORDER BY LeaveTypeId, MinServiceYears;
    SELECT LeaveTypeId, MinServiceYears, FullPayDays, HalfPayDays
    FROM hr.LEAVE_PAY_TIER ORDER BY LeaveTypeId, MinServiceYears;
    SELECT LeaveTypeId, Relation, Days
    FROM hr.LEAVE_RELATION_ENTITLEMENT ORDER BY LeaveTypeId, Relation;
END;
GO

CREATE OR ALTER PROCEDURE hr.usp_ComponentType_GetAll
AS BEGIN SET NOCOUNT ON;
    SELECT ComponentTypeId, Name, Category, Sign, IsActive
    FROM hr.COMPONENT_TYPE ORDER BY ComponentTypeId;
END;
GO

/* ---- 5. Upserts take IsActive (NULL = keep / default 1) ---------------------- */
CREATE OR ALTER PROCEDURE [hr].[usp_LeaveType_Upsert]
    @LeaveTypeId INT = NULL, @Name NVARCHAR(60), @IsPaid BIT,
    @CarryOver BIT = 0,
    @RequiresCertificate BIT = 0, @MinServiceMonthsToUse INT = 0,
    @NoticePreferredDays INT = 0, @FixedEntitlementDays DECIMAL(5,1) = NULL,
    @IsDiscretionary BIT = 0,
    @IsActive BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @LeaveTypeId IS NULL AND EXISTS (SELECT 1 FROM hr.LEAVE_TYPE WHERE Name=@Name)
    BEGIN RAISERROR('A leave type with that name already exists.',16,1); RETURN; END

    IF @FixedEntitlementDays IS NOT NULL AND @IsPaid = 0
    BEGIN RAISERROR('Unpaid leave has no entitlement — leave Fixed entitlement empty.',16,1); RETURN; END

    IF @FixedEntitlementDays IS NOT NULL AND @LeaveTypeId IS NOT NULL
       AND (   EXISTS (SELECT 1 FROM hr.LEAVE_ACCRUAL_TIER         WHERE LeaveTypeId=@LeaveTypeId)
            OR EXISTS (SELECT 1 FROM hr.LEAVE_PAY_TIER             WHERE LeaveTypeId=@LeaveTypeId)
            OR EXISTS (SELECT 1 FROM hr.LEAVE_RELATION_ENTITLEMENT WHERE LeaveTypeId=@LeaveTypeId))
    BEGIN RAISERROR('This type''s days come from its tiers (tenure/pay/relation) — leave Fixed entitlement empty.',16,1); RETURN; END

    IF @LeaveTypeId IS NULL
    BEGIN
        INSERT INTO hr.LEAVE_TYPE (Name,IsPaid,CarryOver,RequiresCertificate,
            MinServiceMonthsToUse,NoticePreferredDays,FixedEntitlementDays,IsDiscretionary,IsActive)
        VALUES (@Name,@IsPaid,@CarryOver,@RequiresCertificate,
            @MinServiceMonthsToUse,@NoticePreferredDays,@FixedEntitlementDays,@IsDiscretionary,ISNULL(@IsActive,1));
        SET @LeaveTypeId = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE hr.LEAVE_TYPE
        SET Name=@Name, IsPaid=@IsPaid, CarryOver=@CarryOver,
            RequiresCertificate=@RequiresCertificate, MinServiceMonthsToUse=@MinServiceMonthsToUse,
            NoticePreferredDays=@NoticePreferredDays, FixedEntitlementDays=@FixedEntitlementDays,
            IsDiscretionary=@IsDiscretionary,
            IsActive=ISNULL(@IsActive, IsActive)
        WHERE LeaveTypeId=@LeaveTypeId;

    SELECT * FROM hr.LEAVE_TYPE WHERE LeaveTypeId=@LeaveTypeId;
END;
GO

CREATE OR ALTER PROCEDURE hr.usp_ComponentType_Create
    @Name NVARCHAR(60), @Category VARCHAR(20), @Sign SMALLINT, @IsActive BIT = NULL
AS BEGIN SET NOCOUNT ON;
    INSERT INTO hr.COMPONENT_TYPE (Name, Category, Sign, IsActive)
    VALUES (@Name, @Category, @Sign, ISNULL(@IsActive, 1));
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS ComponentTypeId; END;
GO

CREATE OR ALTER PROCEDURE hr.usp_ComponentType_Update
    @ComponentTypeId INT, @Name NVARCHAR(60), @Category VARCHAR(20), @Sign SMALLINT, @IsActive BIT = NULL
AS BEGIN SET NOCOUNT ON;
    UPDATE hr.COMPONENT_TYPE
    SET Name = @Name, Category = @Category, Sign = @Sign, IsActive = ISNULL(@IsActive, IsActive)
    WHERE ComponentTypeId = @ComponentTypeId; END;
GO

/* ---- 6. SetActive — the "deactivate it instead" path -------------------------- */
CREATE OR ALTER PROCEDURE hr.usp_LeaveType_SetActive @LeaveTypeId INT, @IsActive BIT
AS BEGIN SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM hr.LEAVE_TYPE WHERE LeaveTypeId = @LeaveTypeId)
    BEGIN RAISERROR('Leave type not found.', 16, 1); RETURN; END
    UPDATE hr.LEAVE_TYPE SET IsActive = @IsActive WHERE LeaveTypeId = @LeaveTypeId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_ComponentType_SetActive @ComponentTypeId INT, @IsActive BIT
AS BEGIN SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM hr.COMPONENT_TYPE WHERE ComponentTypeId = @ComponentTypeId)
    BEGIN RAISERROR('Salary component type not found.', 16, 1); RETURN; END
    UPDATE hr.COMPONENT_TYPE SET IsActive = @IsActive WHERE ComponentTypeId = @ComponentTypeId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_Position_SetActive @PositionId INT, @IsActive BIT
AS BEGIN SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM hr.[POSITION] WHERE PositionId = @PositionId)
    BEGIN RAISERROR('Position not found.', 16, 1); RETURN; END
    UPDATE hr.[POSITION] SET IsActive = @IsActive WHERE PositionId = @PositionId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_Department_SetActive @DepartmentId INT, @IsActive BIT
AS BEGIN SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM hr.DEPARTMENT WHERE DepartmentId = @DepartmentId)
    BEGIN RAISERROR('Department not found.', 16, 1); RETURN; END
    UPDATE hr.DEPARTMENT SET IsActive = @IsActive WHERE DepartmentId = @DepartmentId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_Branch_SetActive @BranchId INT, @IsActive BIT
AS BEGIN SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId)
    BEGIN RAISERROR('Branch not found.', 16, 1); RETURN; END
    UPDATE hr.BRANCH SET IsActive = @IsActive WHERE BranchId = @BranchId; END;
GO

/* ---- 7. Deletes: unused → hard delete; used → refused with the sentence ------- */

/* A leave type OWNS its tiers and relation rows (they are its policy, not uses of
   it), so those go with it; the ledger and leave requests are uses and block. */
CREATE OR ALTER PROCEDURE hr.usp_LeaveType_Delete @LeaveTypeId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Name NVARCHAR(120) = (SELECT Name FROM hr.LEAVE_TYPE WHERE LeaveTypeId = @LeaveTypeId);
    IF @Name IS NULL BEGIN RAISERROR('Leave type not found.', 16, 1); RETURN; END

    DECLARE @Summary NVARCHAR(MAX);
    EXEC core.usp_Object_GetReferences 'hr', 'LEAVE_TYPE', 'LeaveTypeId', @LeaveTypeId, @Summary OUTPUT,
         @ExcludeTables = 'hr.LEAVE_ACCRUAL_TIER,hr.LEAVE_PAY_TIER,hr.LEAVE_RELATION_ENTITLEMENT';
    IF @Summary IS NOT NULL
    BEGIN
        SET @Summary = core.fn_ListWithAnd(@Summary);
        RAISERROR('Cannot delete ''%s'': it is used by %s. Deactivate it instead.', 16, 1, @Name, @Summary);
        RETURN;
    END

    BEGIN TRAN;
        DELETE FROM hr.LEAVE_ACCRUAL_TIER         WHERE LeaveTypeId = @LeaveTypeId;
        DELETE FROM hr.LEAVE_PAY_TIER             WHERE LeaveTypeId = @LeaveTypeId;
        DELETE FROM hr.LEAVE_RELATION_ENTITLEMENT WHERE LeaveTypeId = @LeaveTypeId;
        DELETE FROM hr.LEAVE_TYPE                 WHERE LeaveTypeId = @LeaveTypeId;
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE hr.usp_ComponentType_Delete @ComponentTypeId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Name NVARCHAR(120) = (SELECT Name FROM hr.COMPONENT_TYPE WHERE ComponentTypeId = @ComponentTypeId);
    IF @Name IS NULL BEGIN RAISERROR('Salary component type not found.', 16, 1); RETURN; END

    DECLARE @Summary NVARCHAR(MAX);
    EXEC core.usp_Object_GetReferences 'hr', 'COMPONENT_TYPE', 'ComponentTypeId', @ComponentTypeId, @Summary OUTPUT;
    IF @Summary IS NOT NULL
    BEGIN
        SET @Summary = core.fn_ListWithAnd(@Summary);
        RAISERROR('Cannot delete ''%s'': it is used by %s. Deactivate it instead.', 16, 1, @Name, @Summary);
        RETURN;
    END
    DELETE FROM hr.COMPONENT_TYPE WHERE ComponentTypeId = @ComponentTypeId;
END;
GO

CREATE OR ALTER PROCEDURE hr.usp_Position_Delete @PositionId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Name NVARCHAR(200) = (SELECT Title FROM hr.[POSITION] WHERE PositionId = @PositionId);
    IF @Name IS NULL BEGIN RAISERROR('Position not found.', 16, 1); RETURN; END

    DECLARE @Summary NVARCHAR(MAX);
    EXEC core.usp_Object_GetReferences 'hr', 'POSITION', 'PositionId', @PositionId, @Summary OUTPUT;
    IF @Summary IS NOT NULL
    BEGIN
        SET @Summary = core.fn_ListWithAnd(@Summary);
        RAISERROR('Cannot delete ''%s'': it is used by %s. Deactivate it instead.', 16, 1, @Name, @Summary);
        RETURN;
    END
    DELETE FROM hr.[POSITION] WHERE PositionId = @PositionId;
END;
GO

CREATE OR ALTER PROCEDURE hr.usp_Department_Delete @DepartmentId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Name NVARCHAR(200) = (SELECT Name FROM hr.DEPARTMENT WHERE DepartmentId = @DepartmentId);
    IF @Name IS NULL BEGIN RAISERROR('Department not found.', 16, 1); RETURN; END

    DECLARE @Summary NVARCHAR(MAX);
    EXEC core.usp_Object_GetReferences 'hr', 'DEPARTMENT', 'DepartmentId', @DepartmentId, @Summary OUTPUT;
    IF @Summary IS NOT NULL
    BEGIN
        SET @Summary = core.fn_ListWithAnd(@Summary);
        RAISERROR('Cannot delete ''%s'': it is used by %s. Deactivate it instead.', 16, 1, @Name, @Summary);
        RETURN;
    END
    DELETE FROM hr.DEPARTMENT WHERE DepartmentId = @DepartmentId;
END;
GO

CREATE OR ALTER PROCEDURE hr.usp_Branch_Delete @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Name NVARCHAR(200) = (SELECT Name FROM hr.BRANCH WHERE BranchId = @BranchId);
    IF @Name IS NULL BEGIN RAISERROR('Branch not found.', 16, 1); RETURN; END

    DECLARE @Summary NVARCHAR(MAX);
    EXEC core.usp_Object_GetReferences 'hr', 'BRANCH', 'BranchId', @BranchId, @Summary OUTPUT;

    /* roster months / roster approvals carry BranchId WITHOUT a foreign key, so the
       generic walk cannot see them — counted by hand here. */
    DECLARE @Rosters INT = (SELECT COUNT(*) FROM attendance.ROSTER_MONTH WHERE BranchId = @BranchId)
                         + (SELECT COUNT(*) FROM workflow.ROSTER_APPROVAL WHERE BranchId = @BranchId);
    IF @Rosters > 0
        SET @Summary = CONCAT_WS(N', ', @Summary,
                                 CONCAT(@Rosters, CASE WHEN @Rosters = 1 THEN N' roster' ELSE N' rosters' END));

    IF @Summary IS NOT NULL
    BEGIN
        SET @Summary = core.fn_ListWithAnd(@Summary);
        RAISERROR('Cannot delete ''%s'': it is used by %s. Deactivate it instead.', 16, 1, @Name, @Summary);
        RETURN;
    END
    DELETE FROM hr.BRANCH WHERE BranchId = @BranchId;
END;
GO
