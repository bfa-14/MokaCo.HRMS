/* ============================================================================
   CORE + HR  -  schema, tables, sample data, and FULL CRUD stored procedures
   SQL Server 2025  -  database MokaCo_HRMS
   ----------------------------------------------------------------------------
   Every table and procedure is preceded by a description of its function.
   Per your choice (option b), ALL core/hr operations are exposed as stored
   procedures (not just the logic-bearing ones).
   Assumes the database and the `core` / `hr` schemas already exist.
   ============================================================================ */
USE MokaCo_HRMS;
GO
create schema core;
go
create schema hr;
go
/* ############################################################################
   ===============================  TABLES  =================================
   ############################################################################ */

/* core.CURRENCY
   The currencies the system understands (USD, LBP). Every monetary value in the
   whole system references a currency here, so money is always amount + currency.
   DecimalPlaces drives rounding (USD = 2, LBP = 0). */
CREATE TABLE core.CURRENCY (
    CurrencyCode  CHAR(3)      NOT NULL PRIMARY KEY,
    Name          NVARCHAR(50) NOT NULL,
    DecimalPlaces INT          NOT NULL
);

/* core.EXCHANGE_RATE
   Time-stamped USD<->LBP rates. RateType separates the several rates that can
   apply at once in Lebanon (Official vs Market). Payroll uses the rate effective
   for the period and snapshots it on lock. */
CREATE TABLE core.EXCHANGE_RATE (
    ExchangeRateId INT IDENTITY  NOT NULL PRIMARY KEY,
    FromCurrency   CHAR(3)       NOT NULL REFERENCES core.CURRENCY(CurrencyCode),
    ToCurrency     CHAR(3)       NOT NULL REFERENCES core.CURRENCY(CurrencyCode),
    RateType       VARCHAR(20)   NOT NULL,
    EffectiveDate  DATE          NOT NULL,
    Rate           DECIMAL(18,4) NOT NULL
);

/* hr.BRANCH
   Physical locations. Modelled from day one even with one shop. Every employee
   belongs to a branch. */
CREATE TABLE hr.BRANCH (
    BranchId  INT IDENTITY  NOT NULL PRIMARY KEY,
    Name      NVARCHAR(100) NOT NULL,
    IsActive  BIT           NOT NULL DEFAULT 1
);

/* hr.DEPARTMENT
   Organisational grouping (Operations, Management). Reference data for employees. */
CREATE TABLE hr.DEPARTMENT (
    DepartmentId INT IDENTITY  NOT NULL PRIMARY KEY,
    Name         NVARCHAR(100) NOT NULL,
    IsActive     BIT           NOT NULL DEFAULT 1
);

/* hr.[POSITION]
   Job titles (Barista, Shift Lead, Cashier, HR Officer) assigned to employees. */
CREATE TABLE hr.[POSITION] (
    PositionId INT IDENTITY  NOT NULL PRIMARY KEY,
    Title      NVARCHAR(100) NOT NULL,
    IsActive   BIT           NOT NULL DEFAULT 1
);

/* hr.COMPONENT_TYPE
   Catalogue of pay components (Basic, Allowance, Bonus, Overtime, Late Deduction,
   Unpaid Leave, Advance Repayment, NSSF). Category + Sign (+1 earn / -1 deduct)
   let payroll sum lines correctly. Salary structure and payslip lines classify
   themselves against t his. */
CREATE TABLE hr.COMPONENT_TYPE (
    ComponentTypeId INT IDENTITY NOT NULL PRIMARY KEY,
    Name            NVARCHAR(60) NOT NULL,
    Category        VARCHAR(20)  NOT NULL,   -- Earning / Deduction
    Sign            SMALLINT     NOT NULL    -- +1 / -1
);

/* hr.EMPLOYEE
   The central person record: identity, org placement (branch/department/position),
   NSSF number, hire/termination dates, optional link to a login user. IsDeleted
   gives soft-delete (HR records are never hard deleted). Audit columns track who
   created/changed the row. Almost every other domain references this. */
CREATE TABLE hr.EMPLOYEE (
    EmployeeId      INT IDENTITY  NOT NULL PRIMARY KEY,
    UserId          INT           NULL REFERENCES security.[USER](UserId),
    BranchId        INT           NOT NULL REFERENCES hr.BRANCH(BranchId),
    DepartmentId    INT           NOT NULL REFERENCES hr.DEPARTMENT(DepartmentId),
    PositionId      INT           NOT NULL REFERENCES hr.[POSITION](PositionId),
    FullName        NVARCHAR(150) NOT NULL,
    NationalId      VARCHAR(50)   NULL,
    NssfNumber      VARCHAR(50)   NULL,
    HireDate        DATE          NOT NULL,
    TerminationDate DATE          NULL,
    IsDeleted       BIT           NOT NULL DEFAULT 0,
    CreatedAt       DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    CreatedBy       INT           NULL,
    ModifiedAt      DATETIME2     NULL,
    ModifiedBy      INT           NULL
);

/* hr.LEAVE_TYPE
   Each kind of leave (Annual, Sick, Unpaid), its paid flag, and monthly accrual
   rate. This is where the "X days per month per employee" policy is configured. */
CREATE TABLE hr.LEAVE_TYPE (
    LeaveTypeId     INT IDENTITY NOT NULL PRIMARY KEY,
    Name            NVARCHAR(60) NOT NULL,
    IsPaid          BIT          NOT NULL,
    AccrualPerMonth DECIMAL(5,2) NOT NULL DEFAULT 0,
    CarryOver       BIT          NOT NULL DEFAULT 0
);

/* hr.SALARY_COMPONENT
   The standing salary structure: the recurring pay parts each employee earns
   (basic, allowances...), each with its own currency and effective-date range.
   This is the split USD/LBP salary - one row per component per currency. Payroll
   reads this as a primary input each run. */
CREATE TABLE hr.SALARY_COMPONENT (
    SalaryComponentId INT IDENTITY  NOT NULL PRIMARY KEY,
    EmployeeId        INT           NOT NULL REFERENCES hr.EMPLOYEE(EmployeeId),
    ComponentTypeId   INT           NOT NULL REFERENCES hr.COMPONENT_TYPE(ComponentTypeId),
    Amount            DECIMAL(18,2) NOT NULL,
    CurrencyCode      CHAR(3)       NOT NULL REFERENCES core.CURRENCY(CurrencyCode),
    EffectiveFrom     DATE          NOT NULL,
    EffectiveTo       DATE          NULL
);

/* hr.DOCUMENT
   Metadata for employee file attachments (contracts, IDs...). The file itself
   lives on disk/blob storage; the DB keeps path, type, size and access link. */
CREATE TABLE hr.DOCUMENT (
    DocumentId  INT IDENTITY  NOT NULL PRIMARY KEY,
    EmployeeId  INT           NOT NULL REFERENCES hr.EMPLOYEE(EmployeeId),
    FileName    NVARCHAR(255) NOT NULL,
    StoragePath NVARCHAR(500) NOT NULL,
    ContentType NVARCHAR(100) NOT NULL,
    SizeBytes   BIGINT        NOT NULL,
    UploadedUtc DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);

/* hr.LEAVE_LEDGER
   The itemised statement of leave: ONE signed movement per row -
     +Days = Accrual or CarryOver (credit),   -Days = Usage (debit).
   Usage rows carry LeaveRequestId (nullable here; the workflow stage fills it)
   so each debit is traceable to the leave that caused it. A leave spanning two
   months is posted as TWO usage rows (one per month) so each period stays correct.
   The running balance is NEVER stored - it is derived by hr.vw_LEAVE_BALANCE.
   NOTE: LeaveRequestId has no FK yet because workflow.LEAVE_REQUEST is built in a
   later stage; add the FK when that table exists. */
CREATE TABLE hr.LEAVE_LEDGER (
    LeaveLedgerId   INT IDENTITY  NOT NULL PRIMARY KEY,
    EmployeeId      INT           NOT NULL REFERENCES hr.EMPLOYEE(EmployeeId),
    LeaveTypeId     INT           NOT NULL REFERENCES hr.LEAVE_TYPE(LeaveTypeId),
    PeriodYearMonth CHAR(7)       NOT NULL,        -- 'YYYY-MM'
    MovementType    VARCHAR(20)   NOT NULL,        -- Accrual / Usage / CarryOver / Adjustment
    LeaveRequestId  INT           NULL,            -- set on Usage rows (FK added in workflow stage)
    Days            DECIMAL(6,2)  NOT NULL,        -- + credit, - usage
    EffectiveDate   DATE          NOT NULL,
    Note            NVARCHAR(200) NULL,
    CreatedAt       DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    CreatedBy       INT           NULL
);
GO

/* hr.vw_LEAVE_BALANCE
   The DERIVED leave balance: the SUM of the ledger per employee / leave type /
   month. CarriedOver is reported separately from Accrued so each column is
   meaningful. Because it is derived, the balance can never drift out of sync with
   the individual leaves and cannot be hand-edited. */
CREATE VIEW hr.vw_LEAVE_BALANCE AS
SELECT
    EmployeeId,
    LeaveTypeId,
    PeriodYearMonth,
    SUM(CASE WHEN MovementType = 'Accrual'   THEN Days ELSE 0 END) AS Accrued,
    SUM(CASE WHEN MovementType = 'CarryOver' THEN Days ELSE 0 END) AS CarriedOver,
    SUM(CASE WHEN Days < 0 THEN -Days ELSE 0 END)                  AS Used,
    SUM(Days)                                                      AS Remaining
FROM hr.LEAVE_LEDGER
GROUP BY EmployeeId, LeaveTypeId, PeriodYearMonth;
GO

/* ############################################################################
   ============================  SAMPLE DATA  ===============================
   ############################################################################ */

/* ---- core.CURRENCY ---- */
IF NOT EXISTS (SELECT 1 FROM core.CURRENCY)
INSERT INTO core.CURRENCY (CurrencyCode, Name, DecimalPlaces) VALUES
 ('USD', 'US Dollar', 2),
 ('LBP', 'Lebanese Pound', 0);

/* ---- core.EXCHANGE_RATE ---- */
SET IDENTITY_INSERT core.EXCHANGE_RATE ON;
IF NOT EXISTS (SELECT 1 FROM core.EXCHANGE_RATE)
INSERT INTO core.EXCHANGE_RATE (ExchangeRateId, FromCurrency, ToCurrency, RateType, EffectiveDate, Rate) VALUES
 (1, 'USD', 'LBP', 'Official', '2026-06-01', 15000.0000),
 (2, 'USD', 'LBP', 'Market',   '2026-06-01', 89000.0000);
SET IDENTITY_INSERT core.EXCHANGE_RATE OFF;

/* ---- hr lookups ---- */
SET IDENTITY_INSERT hr.BRANCH ON;
IF NOT EXISTS (SELECT 1 FROM hr.BRANCH)
INSERT INTO hr.BRANCH (BranchId, Name) VALUES (1, 'Main Branch - Beirut');
SET IDENTITY_INSERT hr.BRANCH OFF;

SET IDENTITY_INSERT hr.DEPARTMENT ON;
IF NOT EXISTS (SELECT 1 FROM hr.DEPARTMENT)
INSERT INTO hr.DEPARTMENT (DepartmentId, Name) VALUES (1, 'Operations'), (2, 'Management');
SET IDENTITY_INSERT hr.DEPARTMENT OFF;

SET IDENTITY_INSERT hr.[POSITION] ON;
IF NOT EXISTS (SELECT 1 FROM hr.[POSITION])
INSERT INTO hr.[POSITION] (PositionId, Title) VALUES
 (1, 'Barista'), (2, 'Shift Lead'), (3, 'Cashier'), (4, 'HR Officer');
SET IDENTITY_INSERT hr.[POSITION] OFF;

SET IDENTITY_INSERT hr.COMPONENT_TYPE ON;
IF NOT EXISTS (SELECT 1 FROM hr.COMPONENT_TYPE)
INSERT INTO hr.COMPONENT_TYPE (ComponentTypeId, Name, Category, Sign) VALUES
 (1, 'Basic',              'Earning',   1),
 (2, 'Transport Allowance','Earning',   1),
 (3, 'Bonus',              'Earning',   1),
 (4, 'Overtime',           'Earning',   1),
 (5, 'Late Deduction',     'Deduction', -1),
 (6, 'Unpaid Leave',       'Deduction', -1),
 (7, 'Advance Repayment',  'Deduction', -1),
 (8, 'NSSF',               'Deduction', -1);
SET IDENTITY_INSERT hr.COMPONENT_TYPE OFF;

/* ---- hr.EMPLOYEE (UserId links to seeded security users where present) ---- */
SET IDENTITY_INSERT hr.EMPLOYEE ON;
IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE)
INSERT INTO hr.EMPLOYEE (EmployeeId, UserId, BranchId, DepartmentId, PositionId, FullName, NationalId, NssfNumber, HireDate) VALUES
 (10, 4, 1, 1, 1, 'Rami Haddad', 'LB-1001', 'NSSF-1001', '2024-03-01'),
 (11, 5, 1, 1, 2, 'Lina Saad',   'LB-1002', 'NSSF-1002', '2023-06-15'),
 (12, 6, 1, 1, 3, 'Joe Khoury',  'LB-1003', 'NSSF-1003', '2025-01-10'),
 (13, 2, 1, 2, 4, 'Sara Nasr',   'LB-1004', 'NSSF-1004', '2022-09-01');
SET IDENTITY_INSERT hr.EMPLOYEE OFF;

/* ---- hr.LEAVE_TYPE ---- */
SET IDENTITY_INSERT hr.LEAVE_TYPE ON;
IF NOT EXISTS (SELECT 1 FROM hr.LEAVE_TYPE)
INSERT INTO hr.LEAVE_TYPE (LeaveTypeId, Name, IsPaid, AccrualPerMonth, CarryOver) VALUES
 (1, 'Annual', 1, 1.50, 1),
 (2, 'Sick',   1, 1.00, 0),
 (3, 'Unpaid', 0, 0.00, 0);
SET IDENTITY_INSERT hr.LEAVE_TYPE OFF;

/* ---- hr.SALARY_COMPONENT (split USD / LBP) ---- */
SET IDENTITY_INSERT hr.SALARY_COMPONENT ON;
IF NOT EXISTS (SELECT 1 FROM hr.SALARY_COMPONENT)
INSERT INTO hr.SALARY_COMPONENT (SalaryComponentId, EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom) VALUES
 (1, 10, 1, 400.00,     'USD', '2025-01-01'),
 (2, 10, 2, 3000000.00, 'LBP', '2025-01-01'),
 (3, 11, 1, 650.00,     'USD', '2024-01-01'),
 (4, 11, 2, 5000000.00, 'LBP', '2024-01-01'),
 (5, 12, 1, 350.00,     'USD', '2025-01-10'),
 (6, 12, 2, 2500000.00, 'LBP', '2025-01-10');
SET IDENTITY_INSERT hr.SALARY_COMPONENT OFF;

/* ---- hr.LEAVE_LEDGER (dummy data; balances derive from these)
   Rami June: +9 accrual, -2 usage, -1 usage (spanning) => remaining 6
   Rami July: +6 carryover, +1.5 accrual, -2 usage (spanning) => remaining 5.5 */
SET IDENTITY_INSERT hr.LEAVE_LEDGER ON;
IF NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER)
INSERT INTO hr.LEAVE_LEDGER (LeaveLedgerId, EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, LeaveRequestId, Days, EffectiveDate, Note) VALUES
 (1, 10, 1, '2026-06', 'Accrual',   NULL,  9.00, '2026-06-01', 'Opening accrued'),
 (2, 11, 1, '2026-06', 'Accrual',   NULL, 12.00, '2026-06-01', 'Opening accrued'),
 (3, 12, 1, '2026-06', 'Accrual',   NULL,  4.50, '2026-06-01', 'Opening accrued'),
 (4, 10, 1, '2026-06', 'Usage',     NULL, -2.00, '2026-06-10', 'Leave 10-11 Jun'),
 (5, 10, 1, '2026-06', 'Usage',     NULL, -1.00, '2026-06-30', 'Leave 30 Jun (part 1)'),
 (6, 10, 1, '2026-07', 'CarryOver', NULL,  6.00, '2026-07-01', 'Carried from June'),
 (7, 10, 1, '2026-07', 'Accrual',   NULL,  1.50, '2026-07-01', 'July accrual'),
 (8, 10, 1, '2026-07', 'Usage',     NULL, -2.00, '2026-07-01', 'Leave 1-2 Jul (part 2)');
SET IDENTITY_INSERT hr.LEAVE_LEDGER OFF;
GO

/* ############################################################################
   =====================  STORED PROCEDURES (CRUD)  =========================
   Naming: usp_<Table>_<Action>. Simple list/get/create/update; deletes are soft
   (deactivate) where the entity is referenced elsewhere.
   ############################################################################ */

/* ---------------------------- core.CURRENCY ------------------------------- */

/* List all currencies. */
CREATE OR ALTER PROCEDURE core.usp_Currency_GetAll
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CurrencyCode, Name, DecimalPlaces FROM core.CURRENCY ORDER BY CurrencyCode;
END;
GO

/* Insert or update a currency (upsert on the CHAR(3) code). */
CREATE OR ALTER PROCEDURE core.usp_Currency_Upsert
    @CurrencyCode CHAR(3), @Name NVARCHAR(50), @DecimalPlaces INT
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM core.CURRENCY WHERE CurrencyCode = @CurrencyCode)
        UPDATE core.CURRENCY SET Name = @Name, DecimalPlaces = @DecimalPlaces
        WHERE CurrencyCode = @CurrencyCode;
    ELSE
        INSERT INTO core.CURRENCY (CurrencyCode, Name, DecimalPlaces)
        VALUES (@CurrencyCode, @Name, @DecimalPlaces);
END;
GO

/* -------------------------- core.EXCHANGE_RATE ---------------------------- */

/* List exchange rates, newest effective date first. */
CREATE OR ALTER PROCEDURE core.usp_ExchangeRate_GetAll
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ExchangeRateId, FromCurrency, ToCurrency, RateType, EffectiveDate, Rate
    FROM core.EXCHANGE_RATE
    ORDER BY EffectiveDate DESC, RateType;
END;
GO

/* Add a new exchange-rate row. */
CREATE OR ALTER PROCEDURE core.usp_ExchangeRate_Create
    @FromCurrency CHAR(3), @ToCurrency CHAR(3), @RateType VARCHAR(20),
    @EffectiveDate DATE, @Rate DECIMAL(18,4)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO core.EXCHANGE_RATE (FromCurrency, ToCurrency, RateType, EffectiveDate, Rate)
    VALUES (@FromCurrency, @ToCurrency, @RateType, @EffectiveDate, @Rate);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS ExchangeRateId;
END;
GO

/* Get the rate effective ON a given date for a currency pair + type
   (the latest row on or before that date). Used by payroll later. */
CREATE OR ALTER PROCEDURE core.usp_ExchangeRate_GetEffective
    @FromCurrency CHAR(3), @ToCurrency CHAR(3), @RateType VARCHAR(20), @AsOf DATE
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 ExchangeRateId, FromCurrency, ToCurrency, RateType, EffectiveDate, Rate
    FROM core.EXCHANGE_RATE
    WHERE FromCurrency = @FromCurrency AND ToCurrency = @ToCurrency
      AND RateType = @RateType AND EffectiveDate <= @AsOf
    ORDER BY EffectiveDate DESC;
END;
GO

/* ------------------------------- hr.BRANCH -------------------------------- */

CREATE OR ALTER PROCEDURE hr.usp_Branch_GetAll
AS BEGIN SET NOCOUNT ON;
    SELECT BranchId, Name, IsActive FROM hr.BRANCH ORDER BY Name; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_Branch_Create @Name NVARCHAR(100)
AS BEGIN SET NOCOUNT ON;
    INSERT INTO hr.BRANCH (Name) VALUES (@Name);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS BranchId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_Branch_Update @BranchId INT, @Name NVARCHAR(100), @IsActive BIT
AS BEGIN SET NOCOUNT ON;
    UPDATE hr.BRANCH SET Name = @Name, IsActive = @IsActive WHERE BranchId = @BranchId; END;
GO

/* ----------------------------- hr.DEPARTMENT ------------------------------ */

CREATE OR ALTER PROCEDURE hr.usp_Department_GetAll
AS BEGIN SET NOCOUNT ON;
    SELECT DepartmentId, Name, IsActive FROM hr.DEPARTMENT ORDER BY Name; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_Department_Create @Name NVARCHAR(100)
AS BEGIN SET NOCOUNT ON;
    INSERT INTO hr.DEPARTMENT (Name) VALUES (@Name);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS DepartmentId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_Department_Update @DepartmentId INT, @Name NVARCHAR(100), @IsActive BIT
AS BEGIN SET NOCOUNT ON;
    UPDATE hr.DEPARTMENT SET Name = @Name, IsActive = @IsActive WHERE DepartmentId = @DepartmentId; END;
GO

/* ------------------------------ hr.POSITION ------------------------------- */

CREATE OR ALTER PROCEDURE hr.usp_Position_GetAll
AS BEGIN SET NOCOUNT ON;
    SELECT PositionId, Title, IsActive FROM hr.[POSITION] ORDER BY Title; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_Position_Create @Title NVARCHAR(100)
AS BEGIN SET NOCOUNT ON;
    INSERT INTO hr.[POSITION] (Title) VALUES (@Title);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS PositionId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_Position_Update @PositionId INT, @Title NVARCHAR(100), @IsActive BIT
AS BEGIN SET NOCOUNT ON;
    UPDATE hr.[POSITION] SET Title = @Title, IsActive = @IsActive WHERE PositionId = @PositionId; END;
GO

/* --------------------------- hr.COMPONENT_TYPE ---------------------------- */

CREATE OR ALTER PROCEDURE hr.usp_ComponentType_GetAll
AS BEGIN SET NOCOUNT ON;
    SELECT ComponentTypeId, Name, Category, Sign FROM hr.COMPONENT_TYPE ORDER BY ComponentTypeId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_ComponentType_Create
    @Name NVARCHAR(60), @Category VARCHAR(20), @Sign SMALLINT
AS BEGIN SET NOCOUNT ON;
    INSERT INTO hr.COMPONENT_TYPE (Name, Category, Sign) VALUES (@Name, @Category, @Sign);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS ComponentTypeId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_ComponentType_Update
    @ComponentTypeId INT, @Name NVARCHAR(60), @Category VARCHAR(20), @Sign SMALLINT
AS BEGIN SET NOCOUNT ON;
    UPDATE hr.COMPONENT_TYPE SET Name = @Name, Category = @Category, Sign = @Sign
    WHERE ComponentTypeId = @ComponentTypeId; END;
GO

/* ------------------------------- hr.EMPLOYEE ------------------------------ */

/* List employees (grid view) with resolved lookup names; excludes soft-deleted. */
CREATE OR ALTER PROCEDURE hr.usp_Employee_GetAll
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.EmployeeId, e.FullName, e.NationalId, e.NssfNumber, e.HireDate, e.TerminationDate,
           b.Name AS Branch, d.Name AS Department, p.Title AS Position
    FROM hr.EMPLOYEE e
    JOIN hr.BRANCH b     ON b.BranchId = e.BranchId
    JOIN hr.DEPARTMENT d ON d.DepartmentId = e.DepartmentId
    JOIN hr.[POSITION] p ON p.PositionId = e.PositionId
    WHERE e.IsDeleted = 0
    ORDER BY e.FullName;
END;
GO

/* Full profile: the employee row + resolved names + current salary components,
   returned as two result sets (multi-mapping in Dapper). Heavy reuse -> a proc. */
CREATE OR ALTER PROCEDURE hr.usp_Employee_GetProfile
    @EmployeeId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT e.*, b.Name AS BranchName, d.Name AS DepartmentName, p.Title AS PositionTitle
    FROM hr.EMPLOYEE e
    JOIN hr.BRANCH b     ON b.BranchId = e.BranchId
    JOIN hr.DEPARTMENT d ON d.DepartmentId = e.DepartmentId
    JOIN hr.[POSITION] p ON p.PositionId = e.PositionId
    WHERE e.EmployeeId = @EmployeeId;

    SELECT sc.SalaryComponentId, ct.Name AS ComponentName, sc.Amount, sc.CurrencyCode,
           sc.EffectiveFrom, sc.EffectiveTo
    FROM hr.SALARY_COMPONENT sc
    JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId = sc.ComponentTypeId
    WHERE sc.EmployeeId = @EmployeeId
      AND (sc.EffectiveTo IS NULL OR sc.EffectiveTo >= CAST(SYSUTCDATETIME() AS DATE))
    ORDER BY ct.Name;
END;
GO

/* Create an employee. Returns the new EmployeeId. */
CREATE OR ALTER PROCEDURE hr.usp_Employee_Create
    @UserId INT = NULL, @BranchId INT, @DepartmentId INT, @PositionId INT,
    @FullName NVARCHAR(150), @NationalId VARCHAR(50) = NULL, @NssfNumber VARCHAR(50) = NULL,
    @HireDate DATE, @CreatedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName,
                             NationalId, NssfNumber, HireDate, CreatedBy)
    VALUES (@UserId, @BranchId, @DepartmentId, @PositionId, @FullName,
            @NationalId, @NssfNumber, @HireDate, @CreatedBy);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS EmployeeId;
END;
GO

/* Update an employee's editable fields. */
CREATE OR ALTER PROCEDURE hr.usp_Employee_Update
    @EmployeeId INT, @BranchId INT, @DepartmentId INT, @PositionId INT,
    @FullName NVARCHAR(150), @NationalId VARCHAR(50) = NULL, @NssfNumber VARCHAR(50) = NULL,
    @HireDate DATE, @TerminationDate DATE = NULL, @ModifiedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE hr.EMPLOYEE
    SET BranchId = @BranchId, DepartmentId = @DepartmentId, PositionId = @PositionId,
        FullName = @FullName, NationalId = @NationalId, NssfNumber = @NssfNumber,
        HireDate = @HireDate, TerminationDate = @TerminationDate,
        ModifiedAt = SYSUTCDATETIME(), ModifiedBy = @ModifiedBy
    WHERE EmployeeId = @EmployeeId;
END;
GO

/* Soft-delete an employee (never hard-deleted; keeps history/FKs intact). */
CREATE OR ALTER PROCEDURE hr.usp_Employee_SoftDelete
    @EmployeeId INT, @ModifiedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE hr.EMPLOYEE
    SET IsDeleted = 1, ModifiedAt = SYSUTCDATETIME(), ModifiedBy = @ModifiedBy
    WHERE EmployeeId = @EmployeeId;
END;
GO

/* ------------------------------ hr.LEAVE_TYPE ----------------------------- */

CREATE OR ALTER PROCEDURE hr.usp_LeaveType_GetAll
AS BEGIN SET NOCOUNT ON;
    SELECT LeaveTypeId, Name, IsPaid, AccrualPerMonth, CarryOver FROM hr.LEAVE_TYPE ORDER BY Name; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_LeaveType_Create
    @Name NVARCHAR(60), @IsPaid BIT, @AccrualPerMonth DECIMAL(5,2), @CarryOver BIT
AS BEGIN SET NOCOUNT ON;
    INSERT INTO hr.LEAVE_TYPE (Name, IsPaid, AccrualPerMonth, CarryOver)
    VALUES (@Name, @IsPaid, @AccrualPerMonth, @CarryOver);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS LeaveTypeId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_LeaveType_Update
    @LeaveTypeId INT, @Name NVARCHAR(60), @IsPaid BIT, @AccrualPerMonth DECIMAL(5,2), @CarryOver BIT
AS BEGIN SET NOCOUNT ON;
    UPDATE hr.LEAVE_TYPE SET Name=@Name, IsPaid=@IsPaid, AccrualPerMonth=@AccrualPerMonth, CarryOver=@CarryOver
    WHERE LeaveTypeId = @LeaveTypeId; END;
GO

/* --------------------------- hr.SALARY_COMPONENT -------------------------- */

/* List an employee's salary components (with type name). */
CREATE OR ALTER PROCEDURE hr.usp_SalaryComponent_GetByEmployee @EmployeeId INT
AS BEGIN SET NOCOUNT ON;
    SELECT sc.SalaryComponentId, sc.ComponentTypeId, ct.Name AS ComponentName,
           sc.Amount, sc.CurrencyCode, sc.EffectiveFrom, sc.EffectiveTo
    FROM hr.SALARY_COMPONENT sc
    JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId = sc.ComponentTypeId
    WHERE sc.EmployeeId = @EmployeeId
    ORDER BY sc.EffectiveFrom DESC; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_SalaryComponent_Create
    @EmployeeId INT, @ComponentTypeId INT, @Amount DECIMAL(18,2),
    @CurrencyCode CHAR(3), @EffectiveFrom DATE, @EffectiveTo DATE = NULL
AS BEGIN SET NOCOUNT ON;
    INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom, EffectiveTo)
    VALUES (@EmployeeId, @ComponentTypeId, @Amount, @CurrencyCode, @EffectiveFrom, @EffectiveTo);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS SalaryComponentId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_SalaryComponent_Update
    @SalaryComponentId INT, @Amount DECIMAL(18,2), @CurrencyCode CHAR(3),
    @EffectiveFrom DATE, @EffectiveTo DATE = NULL
AS BEGIN SET NOCOUNT ON;
    UPDATE hr.SALARY_COMPONENT SET Amount=@Amount, CurrencyCode=@CurrencyCode,
        EffectiveFrom=@EffectiveFrom, EffectiveTo=@EffectiveTo
    WHERE SalaryComponentId = @SalaryComponentId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_SalaryComponent_Delete @SalaryComponentId INT
AS BEGIN SET NOCOUNT ON;
    DELETE FROM hr.SALARY_COMPONENT WHERE SalaryComponentId = @SalaryComponentId; END;
GO

/* ------------------------------ hr.DOCUMENT ------------------------------- */

CREATE OR ALTER PROCEDURE hr.usp_Document_GetByEmployee @EmployeeId INT
AS BEGIN SET NOCOUNT ON;
    SELECT DocumentId, EmployeeId, FileName, StoragePath, ContentType, SizeBytes, UploadedUtc
    FROM hr.DOCUMENT WHERE EmployeeId = @EmployeeId ORDER BY UploadedUtc DESC; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_Document_Create
    @EmployeeId INT, @FileName NVARCHAR(255), @StoragePath NVARCHAR(500),
    @ContentType NVARCHAR(100), @SizeBytes BIGINT
AS BEGIN SET NOCOUNT ON;
    INSERT INTO hr.DOCUMENT (EmployeeId, FileName, StoragePath, ContentType, SizeBytes)
    VALUES (@EmployeeId, @FileName, @StoragePath, @ContentType, @SizeBytes);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS DocumentId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_Document_Delete @DocumentId INT
AS BEGIN SET NOCOUNT ON;
    DELETE FROM hr.DOCUMENT WHERE DocumentId = @DocumentId; END;
GO

/* ----------------------------- hr.LEAVE_LEDGER ---------------------------- */

/* All ledger movements for an employee (optionally one period). */
CREATE OR ALTER PROCEDURE hr.usp_LeaveLedger_GetByEmployee
    @EmployeeId INT, @PeriodYearMonth CHAR(7) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT LeaveLedgerId, EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType,
           LeaveRequestId, Days, EffectiveDate, Note, CreatedAt
    FROM hr.LEAVE_LEDGER
    WHERE EmployeeId = @EmployeeId
      AND (@PeriodYearMonth IS NULL OR PeriodYearMonth = @PeriodYearMonth)
    ORDER BY EffectiveDate, LeaveLedgerId;
END;
GO

/* Post ONE ledger movement (accrual / usage / carryover / adjustment).
   Days must be signed by the caller (+ credit, - usage). PeriodYearMonth is
   derived from EffectiveDate so it can't contradict the date. A month-spanning
   leave is posted by calling this once per month. Returns the new id. */
CREATE OR ALTER PROCEDURE hr.usp_LeaveLedger_PostMovement
    @EmployeeId INT, @LeaveTypeId INT, @MovementType VARCHAR(20),
    @Days DECIMAL(6,2), @EffectiveDate DATE, @LeaveRequestId INT = NULL,
    @Note NVARCHAR(200) = NULL, @CreatedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Period CHAR(7) = FORMAT(@EffectiveDate, 'yyyy-MM');
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType,
                                 LeaveRequestId, Days, EffectiveDate, Note, CreatedBy)
    VALUES (@EmployeeId, @LeaveTypeId, @Period, @MovementType,
            @LeaveRequestId, @Days, @EffectiveDate, @Note, @CreatedBy);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS LeaveLedgerId;
END;
GO

/* Correct/remove a single movement (adjustments are normally posted as a new
   offsetting row, but this allows deleting a mistaken entry). */
CREATE OR ALTER PROCEDURE hr.usp_LeaveLedger_Delete @LeaveLedgerId INT
AS BEGIN SET NOCOUNT ON;
    DELETE FROM hr.LEAVE_LEDGER WHERE LeaveLedgerId = @LeaveLedgerId; END;
GO

/* Derived balance for an employee (optionally one period), from the view. */
CREATE OR ALTER PROCEDURE hr.usp_LeaveBalance_Get
    @EmployeeId INT, @PeriodYearMonth CHAR(7) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT EmployeeId, LeaveTypeId, PeriodYearMonth, Accrued, CarriedOver, Used, Remaining
    FROM hr.vw_LEAVE_BALANCE
    WHERE EmployeeId = @EmployeeId
      AND (@PeriodYearMonth IS NULL OR PeriodYearMonth = @PeriodYearMonth)
    ORDER BY PeriodYearMonth, LeaveTypeId;
END;
GO

/* ############################################################################
   ==============================  SMOKE TEST  ==============================
   ############################################################################ */
EXEC core.usp_Currency_GetAll;
EXEC hr.usp_Employee_GetAll;
EXEC hr.usp_Employee_GetProfile @EmployeeId = 10;
EXEC hr.usp_LeaveLedger_GetByEmployee @EmployeeId = 10;
EXEC hr.usp_LeaveBalance_Get @EmployeeId = 10;   -- Jun 9/-/2/6 ; Jul 1.5/6/2/5.5
GO
