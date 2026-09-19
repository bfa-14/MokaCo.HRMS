/* ============================================================================
   82_qa2_foundation.sql — the objects the QA2 fixes and features stand on. No behaviour changes here:
   the rules that use them are in 83 (attendance), 84 (leaves), 85 (rosters) and 86 (payroll).

   D1  core.HOLIDAY (HolidayDate, Name, NameAr, IsPaid, BranchId NULL = every branch) + core.fn_IsHoliday
       + core.usp_Holiday_GetAll / _Upsert / _Delete. A holiday row changes what a day IS, so writing one re-derives
       the attendance days it touches, and a holiday on a PAID period is refused (D10).
   D3  workflow.LEAVE_REQUEST.HalfDay ('AM' | 'PM' | NULL).
   D7  hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom) + hr.fn_EmployeeBranchOn(employee, date)
       + hr.usp_EmployeeBranch_ApplyDue (nightly: a transfer dated in the future becomes the current branch on its day).
       Back-filled with one row per existing employee: their branch since they were hired.
   D10 payroll.fn_IsPeriodPaid(employee, date) and payroll.usp_AssertPeriodOpen: THE PERIOD IS PAID FOR AN EMPLOYEE
       when a locked (Approved) PRIMARY run of that month holds a payslip for them. Per employee, not per month: a
       locked run says nothing about somebody it never paid (hired later, another company's test data), and refusing
       their attendance would leave it uncorrectable for ever. The refusal, word for word:
           This period is paid — raise a payroll adjustment instead.
   Settings (idempotent, with descriptions; sections Attendance / Leave / Payroll):
       HolidayWorkRate 2.0 · LeaveCountsRestDays 0 · LeaveAllowNegativeBalance 0 · LeaveCarryOverMaxDays (empty = no cap)
       · LeaveCarryOverExpiresOn (MM-DD, empty = never) · LeavePayoutOnTermination 1

   Idempotent. Apply with sqlcmd -C -I.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ───────────────────────── 1. settings ───────────────────────── */
DECLARE @s TABLE (SettingKey VARCHAR(60), SettingValue NVARCHAR(400), DataType VARCHAR(60), [Description] NVARCHAR(600), Section VARCHAR(30), SortOrder INT);
INSERT INTO @s VALUES
 ('HolidayWorkRate', '2.0', 'decimal', N'What a day worked on a public holiday is paid at, as a multiple of the normal day. The holiday itself is already paid (1.0), so the payslip line "Holiday work" pays the difference: worked minutes x (rate - 1). 2.0 = double pay.', 'Payroll', 46),
 ('LeavePayoutOnTermination', '1', 'bool', N'1 = the payslip of the month an employee leaves carries "Leave balance payout" for the unused annual leave (or a deduction when the balance is negative), at the day rate. 0 = no line.', 'Payroll', 47),
 ('LeaveCountsRestDays', '0', 'bool', N'0 = a leave request uses the employee''s rostered WORKING days only (rest days and public holidays inside it cost nothing); 1 = every calendar day counts. Where no roster exists for a day, it counts as a working day.', 'Leave', 10),
 ('LeaveAllowNegativeBalance', '0', 'bool', N'0 = a request for more paid leave than the balance holds is refused when it is raised (a discretionary grant still goes through: its days are returned). 1 = allowed; the balance goes negative and is settled at termination.', 'Leave', 11),
 ('LeaveCarryOverMaxDays', '', 'decimal', N'The most unused annual leave that is carried into a new leave year. Empty = no cap (everything unused is carried).', 'Leave', 20),
 ('LeaveCarryOverExpiresOn', '', 'string', N'MM-DD on which carried-over days that are still unused expire (for example 03-31). Empty = they never expire. The nightly job posts one "Expiry" ledger line per employee and year.', 'Leave', 21);
INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, [Description], Section, SortOrder)
SELECT s.SettingKey, s.SettingValue, s.DataType, s.[Description], s.Section, s.SortOrder
FROM @s s WHERE NOT EXISTS (SELECT 1 FROM core.SETTING x WHERE x.SettingKey = s.SettingKey);
GO

/* ───────────────────────── 2. D10: is this day already paid for this employee? ───────────────────────── */
CREATE OR ALTER FUNCTION payroll.fn_IsPeriodPaid (@EmployeeId INT, @WorkDate DATE)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (
        SELECT 1
        FROM payroll.PAYROLL_RUN r
        JOIN payroll.PAYSLIP ps ON ps.PayrollRunId = r.PayrollRunId
        WHERE r.RunType = 'Primary' AND r.[Status] = 'Approved'
          AND r.PeriodYearMonth = CONVERT(CHAR(7), @WorkDate, 23)
          AND ps.EmployeeId = @EmployeeId) THEN 1 ELSE 0 END;
END;
GO
CREATE OR ALTER PROCEDURE payroll.usp_AssertPeriodOpen
    @EmployeeId INT, @WorkDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    IF @EmployeeId IS NOT NULL AND @WorkDate IS NOT NULL AND payroll.fn_IsPeriodPaid(@EmployeeId, @WorkDate) = 1
    BEGIN
        RAISERROR(N'This period is paid — raise a payroll adjustment instead.', 16, 1);
        RETURN 1;
    END
    RETURN 0;
END;
GO

/* ───────────────────────── 3. D7: branch history ───────────────────────── */
IF OBJECT_ID('hr.EMPLOYEE_BRANCH_HISTORY') IS NULL
BEGIN
    CREATE TABLE hr.EMPLOYEE_BRANCH_HISTORY (
        EmployeeBranchHistoryId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_EMPLOYEE_BRANCH_HISTORY PRIMARY KEY,
        EmployeeId    INT  NOT NULL CONSTRAINT FK_EBH_Employee REFERENCES hr.EMPLOYEE (EmployeeId),
        BranchId      INT  NOT NULL CONSTRAINT FK_EBH_Branch   REFERENCES hr.BRANCH (BranchId),
        EffectiveFrom DATE NOT NULL,
        Note          NVARCHAR(300) NULL,
        CreatedAt     DATETIME2 NOT NULL CONSTRAINT DF_EBH_CreatedAt DEFAULT SYSUTCDATETIME(),
        CreatedBy     INT NULL,
        CONSTRAINT UQ_EBH_Employee_From UNIQUE (EmployeeId, EffectiveFrom)
    );
END
GO
/* back-fill: everybody has been in their current branch since they were hired (the only fact on file) */
INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom, Note)
SELECT e.EmployeeId, e.BranchId, e.HireDate, N'Back-filled: the branch on file when branch history was introduced.'
FROM hr.EMPLOYEE e
WHERE NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY h WHERE h.EmployeeId = e.EmployeeId);
GO
/* The branch an employee belonged to ON a date: the latest history row that had started by then; before the first
   row (or with no history at all) the earliest row / the branch on the employee record. */
CREATE OR ALTER FUNCTION hr.fn_EmployeeBranchOn (@EmployeeId INT, @OnDate DATE)
RETURNS INT
AS
BEGIN
    DECLARE @b INT = (SELECT TOP 1 BranchId FROM hr.EMPLOYEE_BRANCH_HISTORY
                      WHERE EmployeeId = @EmployeeId AND EffectiveFrom <= @OnDate
                      ORDER BY EffectiveFrom DESC, EmployeeBranchHistoryId DESC);
    IF @b IS NULL
        SET @b = (SELECT TOP 1 BranchId FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeId = @EmployeeId
                  ORDER BY EffectiveFrom ASC, EmployeeBranchHistoryId ASC);
    IF @b IS NULL SET @b = (SELECT BranchId FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId);
    RETURN @b;
END;
GO
/* nightly: a transfer recorded ahead of its date becomes the employee's current branch on that date */
CREATE OR ALTER PROCEDURE hr.usp_EmployeeBranch_ApplyDue
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    UPDATE e SET e.BranchId = hr.fn_EmployeeBranchOn(e.EmployeeId, @Today), e.ModifiedAt = SYSUTCDATETIME()
    FROM hr.EMPLOYEE e
    WHERE e.IsDeleted = 0 AND e.BranchId <> hr.fn_EmployeeBranchOn(e.EmployeeId, @Today);
    SELECT @@ROWCOUNT AS EmployeesMoved;
END;
GO
CREATE OR ALTER PROCEDURE hr.usp_EmployeeBranchHistory_Get @EmployeeId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT h.EmployeeBranchHistoryId, h.EmployeeId, h.BranchId, b.Name AS BranchName, h.EffectiveFrom,
           LEAD(DATEADD(DAY, -1, h.EffectiveFrom)) OVER (ORDER BY h.EffectiveFrom, h.EmployeeBranchHistoryId) AS EffectiveTo,
           h.Note, h.CreatedAt, h.CreatedBy, u.Username AS CreatedByName
    FROM hr.EMPLOYEE_BRANCH_HISTORY h
    JOIN hr.BRANCH b ON b.BranchId = h.BranchId
    LEFT JOIN security.[USER] u ON u.UserId = h.CreatedBy
    WHERE h.EmployeeId = @EmployeeId
    ORDER BY h.EffectiveFrom DESC, h.EmployeeBranchHistoryId DESC;
END;
GO

/* ───────────────────────── 4. D3: half-day leave ───────────────────────── */
IF COL_LENGTH('workflow.LEAVE_REQUEST', 'HalfDay') IS NULL
    ALTER TABLE workflow.LEAVE_REQUEST ADD HalfDay CHAR(2) NULL
        CONSTRAINT CK_LEAVE_REQUEST_HalfDay CHECK (HalfDay IS NULL OR HalfDay IN ('AM', 'PM'));
GO

/* ───────────────────────── 5. D1: public holidays ───────────────────────── */
IF OBJECT_ID('core.HOLIDAY') IS NULL
BEGIN
    CREATE TABLE core.HOLIDAY (
        HolidayId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_HOLIDAY PRIMARY KEY,
        HolidayDate DATE NOT NULL,
        Name        NVARCHAR(100) NOT NULL,
        NameAr      NVARCHAR(100) NULL,
        IsPaid      BIT NOT NULL CONSTRAINT DF_HOLIDAY_IsPaid DEFAULT 1,
        BranchId    INT NULL CONSTRAINT FK_HOLIDAY_Branch REFERENCES hr.BRANCH (BranchId),     -- NULL = every branch
        CreatedAt   DATETIME2 NOT NULL CONSTRAINT DF_HOLIDAY_CreatedAt DEFAULT SYSUTCDATETIME(),
        CreatedBy   INT NULL,
        ModifiedAt  DATETIME2 NULL,
        ModifiedBy  INT NULL
    );
    /* one holiday per date for everybody, and one per date per branch */
    CREATE UNIQUE INDEX UX_HOLIDAY_Date_All    ON core.HOLIDAY (HolidayDate)           WHERE BranchId IS NULL;
    CREATE UNIQUE INDEX UX_HOLIDAY_Date_Branch ON core.HOLIDAY (HolidayDate, BranchId) WHERE BranchId IS NOT NULL;
END
GO
CREATE OR ALTER FUNCTION core.fn_IsHoliday (@OnDate DATE, @BranchId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (SELECT 1 FROM core.HOLIDAY h
                             WHERE h.HolidayDate = @OnDate AND (h.BranchId IS NULL OR h.BranchId = @BranchId)) THEN 1 ELSE 0 END;
END;
GO
/* D10 for holidays, per employee like every other paid-period check: is the date already paid for ANYBODY the holiday
   would apply to — an employee of that branch on that day (every branch when @BranchId is NULL)? */
CREATE OR ALTER FUNCTION core.fn_HolidayTouchesPaidDay (@OnDate DATE, @BranchId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (
        SELECT 1
        FROM payroll.PAYROLL_RUN r
        JOIN payroll.PAYSLIP ps ON ps.PayrollRunId = r.PayrollRunId
        WHERE r.RunType = 'Primary' AND r.[Status] = 'Approved'
          AND r.PeriodYearMonth = CONVERT(CHAR(7), @OnDate, 23)
          AND (@BranchId IS NULL OR hr.fn_EmployeeBranchOn(ps.EmployeeId, @OnDate) = @BranchId)) THEN 1 ELSE 0 END;
END;
GO
CREATE OR ALTER PROCEDURE core.usp_Holiday_GetAll
    @Year INT = NULL, @BranchId INT = NULL          -- a branch filter keeps the all-branch holidays too: they apply to it
AS
BEGIN
    SET NOCOUNT ON;
    SELECT h.HolidayId, h.HolidayDate, h.Name, h.NameAr, h.IsPaid, h.BranchId, b.Name AS BranchName,
           h.CreatedAt, h.CreatedBy, h.ModifiedAt, h.ModifiedBy
    FROM core.HOLIDAY h
    LEFT JOIN hr.BRANCH b ON b.BranchId = h.BranchId
    WHERE (@Year IS NULL OR YEAR(h.HolidayDate) = @Year)
      AND (@BranchId IS NULL OR h.BranchId IS NULL OR h.BranchId = @BranchId)
    ORDER BY h.HolidayDate, b.Name;
END;
GO
/* Re-derives the attendance days a holiday change touches: every employee-day of the date(s) that has a record or a
   roster row, in the branch the employee belonged to that day. Days already paid are left alone (they cannot be
   reached: the write procedures refuse a holiday on a paid period first). Manual records are skipped by ComputeDay. */
CREATE OR ALTER PROCEDURE core.usp_Holiday_RecomputeDays
    @Date1 DATE, @Branch1 INT, @Date2 DATE = NULL, @Branch2 INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @day TABLE (EmployeeId INT, WorkDate DATE, PRIMARY KEY (EmployeeId, WorkDate));
    INSERT INTO @day
    SELECT DISTINCT x.EmployeeId, x.WorkDate
    FROM (SELECT EmployeeId, WorkDate FROM attendance.ATTENDANCE_RECORD WHERE WorkDate IN (@Date1, @Date2)
          UNION
          SELECT EmployeeId, WorkDate FROM attendance.SHIFT_ASSIGNMENT  WHERE WorkDate IN (@Date1, @Date2)) x
    WHERE (   (x.WorkDate = @Date1 AND (@Branch1 IS NULL OR hr.fn_EmployeeBranchOn(x.EmployeeId, x.WorkDate) = @Branch1))
           OR (x.WorkDate = @Date2 AND (@Branch2 IS NULL OR hr.fn_EmployeeBranchOn(x.EmployeeId, x.WorkDate) = @Branch2)))
      AND payroll.fn_IsPeriodPaid(x.EmployeeId, x.WorkDate) = 0;
    DECLARE @e INT, @d DATE;
    DECLARE hc CURSOR LOCAL FAST_FORWARD FOR SELECT EmployeeId, WorkDate FROM @day;
    OPEN hc; FETCH NEXT FROM hc INTO @e, @d;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @e, @WorkDate = @d;
        FETCH NEXT FROM hc INTO @e, @d;
    END
    CLOSE hc; DEALLOCATE hc;
END;
GO
CREATE OR ALTER PROCEDURE core.usp_Holiday_Upsert
    @HolidayId INT = NULL, @HolidayDate DATE, @Name NVARCHAR(100), @NameAr NVARCHAR(100) = NULL,
    @IsPaid BIT = 1, @BranchId INT = NULL, @ActedByUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @Name = LTRIM(RTRIM(ISNULL(@Name, N'')));
    IF @HolidayDate IS NULL OR @Name = N''
    BEGIN RAISERROR('A holiday needs a date and a name.', 16, 1); RETURN; END
    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId)
    BEGIN RAISERROR('That branch does not exist.', 16, 1); RETURN; END

    DECLARE @OldDate DATE, @OldBranch INT;
    IF @HolidayId IS NOT NULL
    BEGIN
        SELECT @OldDate = HolidayDate, @OldBranch = BranchId FROM core.HOLIDAY WHERE HolidayId = @HolidayId;
        IF @OldDate IS NULL BEGIN RAISERROR('That holiday does not exist.', 16, 1); RETURN; END
    END
    IF EXISTS (SELECT 1 FROM core.HOLIDAY h WHERE h.HolidayDate = @HolidayDate
                 AND ISNULL(h.BranchId, -1) = ISNULL(@BranchId, -1) AND h.HolidayId <> ISNULL(@HolidayId, -1))
    BEGIN RAISERROR('A holiday is already recorded on that date for that branch.', 16, 1); RETURN; END
    /* D10: a holiday re-prices the day; where that day is already PAID for somebody it touches, that is an adjustment, not an edit */
    IF core.fn_HolidayTouchesPaidDay(@HolidayDate, @BranchId) = 1
       OR (@OldDate IS NOT NULL AND core.fn_HolidayTouchesPaidDay(@OldDate, @OldBranch) = 1)
    BEGIN RAISERROR(N'This period is paid — raise a payroll adjustment instead.', 16, 1); RETURN; END

    BEGIN TRAN;
    IF @HolidayId IS NULL
    BEGIN
        INSERT INTO core.HOLIDAY (HolidayDate, Name, NameAr, IsPaid, BranchId, CreatedBy)
        VALUES (@HolidayDate, @Name, NULLIF(LTRIM(RTRIM(@NameAr)), N''), ISNULL(@IsPaid, 1), @BranchId, @ActedByUserId);
        SET @HolidayId = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE core.HOLIDAY
        SET HolidayDate = @HolidayDate, Name = @Name, NameAr = NULLIF(LTRIM(RTRIM(@NameAr)), N''), IsPaid = ISNULL(@IsPaid, 1),
            BranchId = @BranchId, ModifiedAt = SYSUTCDATETIME(), ModifiedBy = @ActedByUserId
        WHERE HolidayId = @HolidayId;
    COMMIT TRAN;

    EXEC core.usp_Holiday_RecomputeDays @Date1 = @HolidayDate, @Branch1 = @BranchId, @Date2 = @OldDate, @Branch2 = @OldBranch;

    SELECT h.HolidayId, h.HolidayDate, h.Name, h.NameAr, h.IsPaid, h.BranchId, b.Name AS BranchName,
           h.CreatedAt, h.CreatedBy, h.ModifiedAt, h.ModifiedBy
    FROM core.HOLIDAY h LEFT JOIN hr.BRANCH b ON b.BranchId = h.BranchId
    WHERE h.HolidayId = @HolidayId;
END;
GO
CREATE OR ALTER PROCEDURE core.usp_Holiday_Delete
    @HolidayId INT, @ActedByUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Date DATE, @Branch INT;
    SELECT @Date = HolidayDate, @Branch = BranchId FROM core.HOLIDAY WHERE HolidayId = @HolidayId;
    IF @Date IS NULL BEGIN RAISERROR('That holiday does not exist.', 16, 1); RETURN; END
    IF core.fn_HolidayTouchesPaidDay(@Date, @Branch) = 1
    BEGIN RAISERROR(N'This period is paid — raise a payroll adjustment instead.', 16, 1); RETURN; END
    DELETE FROM core.HOLIDAY WHERE HolidayId = @HolidayId;
    EXEC core.usp_Holiday_RecomputeDays @Date1 = @Date, @Branch1 = @Branch;
    SELECT @HolidayId AS HolidayId, CAST(1 AS BIT) AS Deleted;
END;
GO

/* ───────────────────────── 6. verification ───────────────────────── */
DECLARE @n INT = (SELECT COUNT(*) FROM core.SETTING WHERE SettingKey IN ('HolidayWorkRate','LeavePayoutOnTermination','LeaveCountsRestDays','LeaveAllowNegativeBalance','LeaveCarryOverMaxDays','LeaveCarryOverExpiresOn'));
DECLARE @h INT = (SELECT COUNT(*) FROM hr.EMPLOYEE e WHERE NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY x WHERE x.EmployeeId = e.EmployeeId));
PRINT CONCAT('new settings present = ', @n, ' (expected 6)');
PRINT CONCAT('employees without a branch-history row = ', @h, ' (expected 0)');
PRINT CONCAT('core.HOLIDAY = ', CASE WHEN OBJECT_ID('core.HOLIDAY') IS NULL THEN 'missing' ELSE 'present' END,
             ', LEAVE_REQUEST.HalfDay = ', CASE WHEN COL_LENGTH('workflow.LEAVE_REQUEST','HalfDay') IS NULL THEN 'missing' ELSE 'present' END);
PRINT 'Script 82 applied.';
GO
