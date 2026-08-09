/* ============================================================================
   ATTENDANCE  -  COMPLETE STAGE  (v3)  -  RE-RUNNABLE
   SQL Server 2025  -  database MokaCo_HRMS
   ----------------------------------------------------------------------------
   This script DROPS and RECREATES everything it owns, so it can be run repeatedly
   without error. It owns: core.SETTING (+2 helper functions) and the whole
   `attendance` schema. It does NOT touch security / hr / core tables built earlier.

   RESERVED-WORD NOTE: [RowCount], [Status], [Source], [USER], [POSITION] are
   bracketed throughout because they are T-SQL / ODBC reserved words.

   ============================ CORE PRINCIPLES ==============================
   1. THREE ingestion paths, ONE destination. Device push, Excel import, manual entry
      all land in RAW_DEVICE_LOG; ONE processor builds ATTENDANCE_RECORD.
   2. ATTENDANCE REPORTS. WORKFLOW AUTHORIZES. HR DECIDES.
      Overtime is DETECTED, never auto-paid. Nothing is silently netted.
   3. APPROVED != ACTUAL. An exit approved for 2h may actually have been 1.5h or 2.5h.
      BOTH are stored; neither overwrites the other; HR dispositions the difference.
   4. LEAVE DEDUCTION BASIS IS CONFIGURABLE. DEFAULT = the ACTUAL minutes are deducted
      from the leave balance. HR may switch the basis, override a single day, and
      treat the +/- difference as OVERTIME or UNPAID absence.
   5. WORKED TIME = SUM OF PAIRED INTERVALS. 08:00-12:00 + 14:00-17:00 = 7h, NOT 9h.
      Otherwise a mid-day absence would be paid and exit permissions meaningless.
   6. A "WORKING DAY" IS CONFIGURABLE: the rostered SHIFT's own length when there is
      one; otherwise core.SETTING.StandardWorkDayHours.
   7. HR KEEPS FULL POWER: anything possible via workflow is also possible manually.

   REQUIRES (already created by earlier stages):
     security.[USER], hr.BRANCH, hr.DEPARTMENT, hr.EMPLOYEE, hr.LEAVE_LEDGER
   ============================================================================ */
USE MokaCo_HRMS;
GO

/* ############################################################################
   ===================  DROP (children first, FK-safe)  ======================
   ############################################################################ */

/* -- procedures -- */
DROP PROCEDURE IF EXISTS attendance.usp_Attendance_MarkLeaveDays;
DROP PROCEDURE IF EXISTS attendance.usp_Attendance_MonthlyByBranch;
DROP PROCEDURE IF EXISTS attendance.usp_Attendance_MonthlySummary_All;
DROP PROCEDURE IF EXISTS attendance.usp_Attendance_MonthlySummary;
DROP PROCEDURE IF EXISTS attendance.usp_Attendance_PayrollReadiness;
DROP PROCEDURE IF EXISTS attendance.usp_Correction_GetPending;
DROP PROCEDURE IF EXISTS attendance.usp_Correction_GetByRecord;
DROP PROCEDURE IF EXISTS attendance.usp_Correction_Reject;
DROP PROCEDURE IF EXISTS attendance.usp_Correction_Approve;
DROP PROCEDURE IF EXISTS attendance.usp_Correction_Create;
DROP PROCEDURE IF EXISTS attendance.usp_RawLog_GetByEmployeeDay;
DROP PROCEDURE IF EXISTS attendance.usp_RawLog_GetUnresolved;
DROP PROCEDURE IF EXISTS attendance.usp_Attendance_GetAnomalies;
DROP PROCEDURE IF EXISTS attendance.usp_Attendance_GetById;
DROP PROCEDURE IF EXISTS attendance.usp_Attendance_GetByDateRange;
DROP PROCEDURE IF EXISTS attendance.usp_Attendance_GetExitVariances;
DROP PROCEDURE IF EXISTS attendance.usp_Attendance_HrAdjustDay;
DROP PROCEDURE IF EXISTS attendance.usp_Attendance_SetExitDisposition;
DROP PROCEDURE IF EXISTS attendance.usp_Attendance_SetExitApproval;
DROP PROCEDURE IF EXISTS attendance.usp_Attendance_ManualUpsert;
DROP PROCEDURE IF EXISTS attendance.usp_Attendance_MarkAbsentees;
DROP PROCEDURE IF EXISTS attendance.usp_Attendance_ProcessRawLogs;
DROP PROCEDURE IF EXISTS attendance.usp_ImportBatch_GetJson;
DROP PROCEDURE IF EXISTS attendance.usp_ImportBatch_GetAll;
DROP PROCEDURE IF EXISTS attendance.usp_ImportBatch_SetResult;
DROP PROCEDURE IF EXISTS attendance.usp_ImportBatch_Create;
DROP PROCEDURE IF EXISTS attendance.usp_RawLog_Insert;
DROP PROCEDURE IF EXISTS attendance.usp_ShiftAssignment_GetGaps;
DROP PROCEDURE IF EXISTS attendance.usp_ShiftAssignment_ApplyPatternForMonth;
DROP PROCEDURE IF EXISTS attendance.usp_ShiftAssignment_ApplyPattern;
DROP PROCEDURE IF EXISTS attendance.usp_ShiftPattern_Delete;
DROP PROCEDURE IF EXISTS attendance.usp_ShiftPattern_Upsert;
DROP PROCEDURE IF EXISTS attendance.usp_ShiftPattern_GetByEmployee;
DROP PROCEDURE IF EXISTS attendance.usp_ShiftAssignment_CopyPeriod;
DROP PROCEDURE IF EXISTS attendance.usp_ShiftAssignment_GenerateRange_Bulk;
DROP PROCEDURE IF EXISTS attendance.usp_ShiftAssignment_GenerateRange;
DROP PROCEDURE IF EXISTS attendance.usp_ShiftAssignment_Delete;
DROP PROCEDURE IF EXISTS attendance.usp_ShiftAssignment_Upsert;
DROP PROCEDURE IF EXISTS attendance.usp_ShiftAssignment_GetByDateRange;
DROP PROCEDURE IF EXISTS attendance.usp_Shift_Update;
DROP PROCEDURE IF EXISTS attendance.usp_Shift_Create;
DROP PROCEDURE IF EXISTS attendance.usp_Shift_GetAll;
DROP PROCEDURE IF EXISTS attendance.usp_EmployeeDevice_Unmap;
DROP PROCEDURE IF EXISTS attendance.usp_EmployeeDevice_Map;
DROP PROCEDURE IF EXISTS attendance.usp_EmployeeDevice_GetAll;
DROP PROCEDURE IF EXISTS attendance.usp_Device_TouchSync;
DROP PROCEDURE IF EXISTS attendance.usp_Device_Update;
DROP PROCEDURE IF EXISTS attendance.usp_Device_Create;
DROP PROCEDURE IF EXISTS attendance.usp_Device_GetBySerial;
DROP PROCEDURE IF EXISTS attendance.usp_Device_GetAll;
DROP PROCEDURE IF EXISTS core.usp_Setting_Upsert;
DROP PROCEDURE IF EXISTS core.usp_Setting_GetAll;
DROP PROCEDURE IF EXISTS core.usp_Setting_Get;
GO

/* -- functions (before the table they read) -- */
DROP FUNCTION IF EXISTS core.fn_MinutesToLeaveDays;
DROP FUNCTION IF EXISTS core.fn_StandardDayMinutes;
GO

/* -- tables: children first -- */
DROP TABLE IF EXISTS attendance.ATTENDANCE_INTERVAL;
DROP TABLE IF EXISTS attendance.ATTENDANCE_CORRECTION;
DROP TABLE IF EXISTS attendance.ATTENDANCE_RECORD;
DROP TABLE IF EXISTS attendance.RAW_DEVICE_LOG;
DROP TABLE IF EXISTS attendance.ATTENDANCE_IMPORT_BATCH;
DROP TABLE IF EXISTS attendance.SHIFT_ASSIGNMENT;
DROP TABLE IF EXISTS attendance.EMPLOYEE_SHIFT_PATTERN;
DROP TABLE IF EXISTS attendance.EMPLOYEE_DEVICE;
DROP TABLE IF EXISTS attendance.SHIFT;
DROP TABLE IF EXISTS attendance.DEVICE;
DROP TABLE IF EXISTS core.SETTING;
GO

/* ############################################################################
   =============================  CONFIG  ===================================
   ############################################################################ */

/* core.SETTING
   Global key/value configuration, so policy changes need no code deploy. */
CREATE TABLE core.SETTING (
    SettingKey   VARCHAR(60)   NOT NULL PRIMARY KEY,  -- e.g. 'StandardWorkDayHours'
    SettingValue NVARCHAR(200) NOT NULL,              -- e.g. '8'
    DataType     VARCHAR(20)   NOT NULL,              -- decimal/int/string/bool. e.g. 'decimal'
    [Description] NVARCHAR(300) NULL,                 -- what it controls
    ModifiedAt   DATETIME2     NULL,                  -- e.g. '2026-07-01T09:00:00'
    ModifiedBy   INT           NULL                   -- e.g. 2 (sara.hr)
                 REFERENCES security.[USER](UserId)
);
GO

INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, [Description]) VALUES
 ('StandardWorkDayHours', '8',      'decimal',
  'Hours in a standard working day. Used when no shift is rostered, and to convert exit-permission minutes into leave days.'),
 ('ExitLeaveBasis',       'Actual', 'string',
  'Which minutes an exit permission deducts from leave: Actual (what the punches show - DEFAULT) or Approved (what workflow authorised). HR can override per day.'),
 ('FullDayThreshold',     '1.00',   'decimal',
  'Fraction of the standard day that must be worked to count as a full day.');
GO

CREATE PROCEDURE core.usp_Setting_Get @SettingKey VARCHAR(60)
AS BEGIN SET NOCOUNT ON;
    SELECT SettingKey, SettingValue, DataType, [Description]
    FROM core.SETTING WHERE SettingKey = @SettingKey; END;
GO

CREATE PROCEDURE core.usp_Setting_GetAll
AS BEGIN SET NOCOUNT ON;
    SELECT SettingKey, SettingValue, DataType, [Description], ModifiedAt, ModifiedBy
    FROM core.SETTING ORDER BY SettingKey; END;
GO

CREATE PROCEDURE core.usp_Setting_Upsert
    @SettingKey VARCHAR(60), @SettingValue NVARCHAR(200),
    @DataType VARCHAR(20) = 'string', @Description NVARCHAR(300) = NULL,
    @ModifiedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = @SettingKey)
        UPDATE core.SETTING
        SET SettingValue = @SettingValue, DataType = @DataType,
            [Description] = COALESCE(@Description, [Description]),
            ModifiedAt = SYSUTCDATETIME(), ModifiedBy = @ModifiedBy
        WHERE SettingKey = @SettingKey;
    ELSE
        INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, [Description], ModifiedAt, ModifiedBy)
        VALUES (@SettingKey, @SettingValue, @DataType, @Description, SYSUTCDATETIME(), @ModifiedBy);
END;
GO

/* Standard working minutes per day, from config. e.g. 8h -> 480 */
CREATE FUNCTION core.fn_StandardDayMinutes()
RETURNS INT
AS
BEGIN
    DECLARE @h DECIMAL(6,2) =
        TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'StandardWorkDayHours') AS DECIMAL(6,2));
    RETURN CAST(ROUND(ISNULL(@h, 8) * 60, 0) AS INT);
END;
GO

/* Convert minutes to leave DAYS using the configured working day.
   e.g. 120 minutes with an 8h day -> 0.25 days */
CREATE FUNCTION core.fn_MinutesToLeaveDays(@Minutes INT)
RETURNS DECIMAL(6,2)
AS
BEGIN
    DECLARE @std INT = core.fn_StandardDayMinutes();
    IF @std IS NULL OR @std = 0 RETURN 0;
    RETURN CAST(ROUND(CAST(ISNULL(@Minutes,0) AS DECIMAL(12,4)) / @std, 2) AS DECIMAL(6,2));
END;
GO

/* ############################################################################
   ===============================  TABLES  =================================
   ############################################################################ */

/* attendance.DEVICE
   A fingerprint terminal - a PHYSICAL object, so it belongs to a BRANCH (required)
   and optionally to a DEPARTMENT. A "branch" is any physical site: a shop, or later
   a head office. Manual and Excel sources are synthetic device rows so every raw
   punch can always name a device. */
CREATE TABLE attendance.DEVICE (
    DeviceId     INT IDENTITY  NOT NULL PRIMARY KEY,   -- e.g. 1
    SerialNumber VARCHAR(60)   NOT NULL UNIQUE,        -- e.g. 'ZK-1234'
    BranchId     INT           NOT NULL                -- where it is mounted. e.g. 1
                 REFERENCES hr.BRANCH(BranchId),
    DepartmentId INT           NULL                    -- optional org tag. e.g. NULL
                 REFERENCES hr.DEPARTMENT(DepartmentId),
    IsActive     BIT           NOT NULL DEFAULT 1,     -- 0 = retired. e.g. 1
    LastSyncUtc  DATETIME2     NULL                    -- e.g. '2026-06-02T17:00:00'
);

/* attendance.EMPLOYEE_DEVICE
   TRANSLATION table, not a restriction. Maps (Device, PIN) -> Employee, because a
   device knows people only by an enrollment PIN, and a PIN is only unique WITHIN a
   device. MANY-TO-MANY: an employee has ONE ROW PER DEVICE they are enrolled on, so
   staff who work across several branches can punch at any of them. */
CREATE TABLE attendance.EMPLOYEE_DEVICE (
    EmployeeDeviceId INT IDENTITY NOT NULL PRIMARY KEY, -- e.g. 1
    EmployeeId       INT NOT NULL                       -- e.g. 10 (Rami)
                     REFERENCES hr.EMPLOYEE(EmployeeId),
    DeviceId         INT NOT NULL                       -- e.g. 1 (ZK-1234)
                     REFERENCES attendance.DEVICE(DeviceId),
    EnrollPin        VARCHAR(30) NOT NULL,              -- the device's id for them. e.g. '1001'
    CONSTRAINT UQ_EmployeeDevice UNIQUE (DeviceId, EnrollPin)
);

/* attendance.SHIFT
   Shift definitions. Start/end + grace + break define what "late", "a full day" and
   "overtime" mean. CrossesMidnight marks overnight shifts (they end the next day but
   belong to the day they START on). */
CREATE TABLE attendance.SHIFT (
    ShiftId         INT IDENTITY NOT NULL PRIMARY KEY,  -- e.g. 1
    Name            NVARCHAR(50) NOT NULL,              -- e.g. 'Morning'
    StartTime       TIME NOT NULL,                      -- e.g. '08:00'
    EndTime         TIME NOT NULL,                      -- e.g. '16:00'
    GraceMinutes    INT  NOT NULL DEFAULT 0,            -- lateness allowance. e.g. 10
    CrossesMidnight BIT  NOT NULL DEFAULT 0,            -- 1 = ends next day. e.g. 0
    BreakMinutes    INT  NOT NULL DEFAULT 0,            -- unpaid break. e.g. 30
    IsActive        BIT  NOT NULL DEFAULT 1             -- e.g. 1
);

/* attendance.EMPLOYEE_SHIFT_PATTERN
   An employee's DEFAULT WEEK (a template; holds no dates). Roster generation expands
   it into dated SHIFT_ASSIGNMENT rows, so HR never types the roster day by day. */
CREATE TABLE attendance.EMPLOYEE_SHIFT_PATTERN (
    PatternId  INT IDENTITY NOT NULL PRIMARY KEY,  -- e.g. 1
    EmployeeId INT NOT NULL                        -- e.g. 10 (Rami)
               REFERENCES hr.EMPLOYEE(EmployeeId),
    DayOfWeek  TINYINT NOT NULL,                   -- 1=Mon .. 7=Sun (ISO). e.g. 1
    ShiftId    INT NULL                            -- NULL if rest. e.g. 1
               REFERENCES attendance.SHIFT(ShiftId),
    IsRestDay  BIT NOT NULL DEFAULT 0,             -- e.g. 0
    IsActive   BIT NOT NULL DEFAULT 1,             -- e.g. 1
    CONSTRAINT UQ_EmpPattern UNIQUE (EmployeeId, DayOfWeek),
    CONSTRAINT CK_EmpPattern_Day CHECK (DayOfWeek BETWEEN 1 AND 7)
);

/* attendance.SHIFT_ASSIGNMENT
   The ROSTER: which shift each employee works on each date, plus per-employee rest
   days. ONE row per employee-day (enforced). Tells the processor the expected shift,
   and therefore what "late" and "a full day" mean for that person on that date.
   WorkDate for an overnight shift = the day the shift STARTS.
   HR NEVER types these one by one - they are GENERATED (see the roster section). */
CREATE TABLE attendance.SHIFT_ASSIGNMENT (
    ShiftAssignmentId INT IDENTITY NOT NULL PRIMARY KEY, -- e.g. 1
    EmployeeId        INT NOT NULL                       -- e.g. 10 (Rami)
                      REFERENCES hr.EMPLOYEE(EmployeeId),
    ShiftId           INT NULL                           -- NULL on a rest day. e.g. 1
                      REFERENCES attendance.SHIFT(ShiftId),
    WorkDate          DATE NOT NULL,                     -- e.g. '2026-06-02'
    IsRestDay         BIT  NOT NULL DEFAULT 0,           -- e.g. 0
    CONSTRAINT UQ_ShiftAssignment UNIQUE (EmployeeId, WorkDate)
);

/* attendance.ATTENDANCE_IMPORT_BATCH
   One row per Excel file imported from a device. Keeps the ORIGINAL file as JSON for
   AUDIT ONLY ("what the file actually said"); the JSON is never used for processing.
   The API parses the same file into typed RAW_DEVICE_LOG rows.
   NOTE: [RowCount] is bracketed - ROWCOUNT is a reserved word. */
CREATE TABLE attendance.ATTENDANCE_IMPORT_BATCH (
    ImportBatchId  INT IDENTITY  NOT NULL PRIMARY KEY,  -- e.g. 1
    FileName       NVARCHAR(255) NOT NULL,              -- e.g. 'ZK-1234_June.xlsx'
    RawJson        NVARCHAR(MAX) NOT NULL,              -- whole file as JSON, audit only
    [RowCount]     INT           NOT NULL DEFAULT 0,    -- punch rows parsed. e.g. 42
    [Status]       VARCHAR(20)   NOT NULL DEFAULT 'Received', -- Received/Parsed/Failed
    ImportedByUser INT           NULL                   -- e.g. 2 (sara.hr)
                   REFERENCES security.[USER](UserId),
    ImportedUtc    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    Note           NVARCHAR(300) NULL                   -- e.g. '2 unknown PINs'
);

/* attendance.RAW_DEVICE_LOG
   Immutable, write-once landing table for raw punches from ANY source. Nothing edits
   these rows. DedupHash makes ingestion idempotent (a re-sent push or duplicated
   Excel row is ignored). [Source] records HOW it arrived. EmployeeId is resolved from
   the PIN when known (NULL = unresolved, kept not dropped). IsProcessed marks rows
   the processor has consumed - the PROCESSOR IS THE ONLY THING THAT SETS IT TO 1. */
CREATE TABLE attendance.RAW_DEVICE_LOG (
    RawLogId      BIGINT IDENTITY NOT NULL PRIMARY KEY, -- e.g. 1
    DeviceId      INT NOT NULL                          -- e.g. 1
                  REFERENCES attendance.DEVICE(DeviceId),
    ImportBatchId INT NULL                              -- set when [Source]='Excel'
                  REFERENCES attendance.ATTENDANCE_IMPORT_BATCH(ImportBatchId),
    EnrollPin     VARCHAR(30) NOT NULL,                 -- e.g. '1001'
    EmployeeId    INT NULL                              -- NULL = unknown PIN. e.g. 10
                  REFERENCES hr.EMPLOYEE(EmployeeId),
    PunchTimeUtc  DATETIME2   NOT NULL,                 -- e.g. '2026-06-02T08:20:00'
    PunchType     SMALLINT    NOT NULL,                 -- 0 = IN, 1 = OUT. e.g. 0
    [Source]      VARCHAR(10) NOT NULL,                 -- Device/Excel/Manual. e.g. 'Device'
    DedupHash     VARCHAR(64) NOT NULL UNIQUE,          -- idempotency key
    IsProcessed   BIT NOT NULL DEFAULT 0,               -- 1 once consumed. e.g. 0
    CreatedUtc    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);

/* attendance.ATTENDANCE_RECORD
   The PROCESSED result: ONE row per employee-day. This - never the raw log - is what
   payroll reads.

   TIME MODEL:
     GrossMinutes    = SUM of the PAIRED in/out intervals (08-12 + 14-17 = 420, not 540)
     GapMinutes      = total time clocked OUT between those intervals
     BreakApplied    = break actually charged. If they punched out for the break, the
                       gap already covers it; only the shortfall is taken off Gross.
     WorkedMinutes   = GrossMinutes - (break not already taken as a gap)
     StandardMinutes = rostered SHIFT length minus its break; else config default
     DayFraction     = Worked / Standard, capped 1.00 -> "was a whole day worked?"
     ShortfallMinutes/OvertimeMinutes = how far under / over the standard day

   EXIT PERMISSIONS - approved and actual are INDEPENDENT; neither overwrites the other:
     ExitActualMinutes   = observed gap beyond the break (what really happened)
     ExitApprovedMinutes = what workflow approved, or what HR entered manually when the
                           employee never punched out/in for their exit
     ExitVarianceMinutes = actual - approved  (+ took more, - came back early)
     ExitLeaveMinutes    = what is deducted from the leave balance.
                           DEFAULT = the ACTUAL minutes (core.SETTING.ExitLeaveBasis);
                           HR may switch the basis or override this single day.
     ExitVarianceDisposition = HR's call on the difference: 'UnpaidAbsence',
                           'Overtime' (offset), or 'Ignore'.
   Overtime is DETECTED here but NEVER auto-paid. */
CREATE TABLE attendance.ATTENDANCE_RECORD (
    AttendanceId      BIGINT IDENTITY NOT NULL PRIMARY KEY, -- e.g. 1
    EmployeeId        INT NOT NULL                          -- e.g. 10 (Rami)
                      REFERENCES hr.EMPLOYEE(EmployeeId),
    ShiftAssignmentId INT NULL                              -- roster row. e.g. 1
                      REFERENCES attendance.SHIFT_ASSIGNMENT(ShiftAssignmentId),
    WorkDate          DATE NOT NULL,                        -- e.g. '2026-06-02'

    FirstInUtc        DATETIME2 NULL,                       -- e.g. '2026-06-02T08:20:00'
    LastOutUtc        DATETIME2 NULL,                       -- e.g. '2026-06-02T17:00:00'
    PunchPairs        INT NOT NULL DEFAULT 0,               -- complete in/out intervals. e.g. 2

    GrossMinutes      INT NOT NULL DEFAULT 0,               -- sum of intervals. e.g. 400
    GapMinutes        INT NOT NULL DEFAULT 0,               -- clocked-out time mid-day. e.g. 120
    BreakApplied      INT NOT NULL DEFAULT 0,               -- break charged. e.g. 30
    WorkedMinutes     INT NOT NULL DEFAULT 0,               -- the paid time. e.g. 400
    StandardMinutes   INT NOT NULL DEFAULT 0,               -- a full day for this person/day. e.g. 450
    DayFraction       DECIMAL(5,2) NOT NULL DEFAULT 0,      -- worked/standard, cap 1.00. e.g. 0.89
    IsFullDay         BIT NOT NULL DEFAULT 0,               -- e.g. 0
    ShortfallMinutes  INT NOT NULL DEFAULT 0,               -- e.g. 50
    LateMinutes       INT NOT NULL DEFAULT 0,               -- past (start + grace). e.g. 10
    OvertimeMinutes   INT NOT NULL DEFAULT 0,               -- DETECTED only. e.g. 0

    ExitActualMinutes       INT NOT NULL DEFAULT 0,         -- observed. e.g. 90
    ExitApprovedMinutes     INT NOT NULL DEFAULT 0,         -- approved. e.g. 120
    ExitVarianceMinutes     INT NOT NULL DEFAULT 0,         -- actual - approved. e.g. -30
    ExitLeaveMinutes        INT NOT NULL DEFAULT 0,         -- deducted from leave. e.g. 90
    ExitVarianceDisposition VARCHAR(20) NULL,               -- UnpaidAbsence/Overtime/Ignore
    ExitPermissionId        INT NULL,                       -- workflow.EXIT_PERMISSION (FK added later)

    [Status]          VARCHAR(20) NOT NULL,                 -- Present/Absent/RestDay/Leave
    [Source]          VARCHAR(10) NOT NULL DEFAULT 'Device',-- Device/Excel/Manual
    DeviceId          INT NULL                              -- e.g. 1
                      REFERENCES attendance.DEVICE(DeviceId),
    BranchId          INT NULL                              -- WHERE the day was worked. e.g. 1
                      REFERENCES hr.BRANCH(BranchId),
    HasAnomaly        BIT NOT NULL DEFAULT 0,               -- 1 = unpaired/odd punches. e.g. 0
    IsManual          BIT NOT NULL DEFAULT 0,               -- 1 = HR-entered/corrected; processor must not touch
    HrNote            NVARCHAR(300) NULL,                   -- why HR overrode it
    ProcessedUtc      DATETIME2 NULL,                       -- e.g. '2026-06-02T17:05:00'
    CONSTRAINT UQ_Attendance UNIQUE (EmployeeId, WorkDate)
);

/* attendance.ATTENDANCE_INTERVAL
   The individual PAIRED in/out intervals behind one record - the audit trail for
   WorkedMinutes. A day with a 2-hour mid-day exit has TWO rows, and the gap between
   them is the exit. Regenerated by the processor; never hand-edited. */
CREATE TABLE attendance.ATTENDANCE_INTERVAL (
    IntervalId   BIGINT IDENTITY NOT NULL PRIMARY KEY, -- e.g. 1
    AttendanceId BIGINT NOT NULL                       -- e.g. 1
                 REFERENCES attendance.ATTENDANCE_RECORD(AttendanceId) ON DELETE CASCADE,
    SeqNo        INT NOT NULL,                         -- 1,2,3 in time order. e.g. 1
    InTimeUtc    DATETIME2 NOT NULL,                   -- e.g. '2026-06-02T08:20:00'
    OutTimeUtc   DATETIME2 NOT NULL,                   -- e.g. '2026-06-02T12:00:00'
    Minutes      INT NOT NULL,                         -- e.g. 220
    GapAfterMins INT NOT NULL DEFAULT 0,               -- until the next interval. e.g. 120
    CONSTRAINT UQ_Interval UNIQUE (AttendanceId, SeqNo)
);

/* attendance.ATTENDANCE_CORRECTION
   A LOGGED, APPROVED change to a processed record. Stores OLD and NEW values so the
   change is auditable; raw logs are NEVER touched. Approving applies the NEW values
   and RECOMPUTES the day. HR-only (permission ATTENDANCE_CORRECT). */
CREATE TABLE attendance.ATTENDANCE_CORRECTION (
    CorrectionId    INT IDENTITY NOT NULL PRIMARY KEY,   -- e.g. 1
    AttendanceId    BIGINT NOT NULL                      -- e.g. 1
                    REFERENCES attendance.ATTENDANCE_RECORD(AttendanceId),
    RequestedBy     INT NOT NULL                         -- e.g. 2 (sara.hr)
                    REFERENCES security.[USER](UserId),
    ApprovedBy      INT NULL                             -- e.g. 2, or NULL while pending
                    REFERENCES security.[USER](UserId),
    OldFirstInUtc   DATETIME2 NULL,                      -- e.g. '2026-06-02T08:20:00'
    OldLastOutUtc   DATETIME2 NULL,                      -- e.g. NULL (forgot to punch out)
    OldExitMinutes  INT NULL,                            -- e.g. 0
    OldStatus       VARCHAR(20) NULL,                    -- e.g. 'Absent'
    NewFirstInUtc   DATETIME2 NULL,                      -- e.g. '2026-06-02T08:20:00'
    NewLastOutUtc   DATETIME2 NULL,                      -- e.g. '2026-06-02T16:30:00'
    NewExitMinutes  INT NULL,                            -- e.g. 120
    NewStatus       VARCHAR(20) NULL,                    -- e.g. 'Present'
    Reason          NVARCHAR(300) NOT NULL,              -- e.g. 'Employee forgot to punch out'
    ApprovalStatus  VARCHAR(20) NOT NULL DEFAULT 'Pending', -- Pending/Approved/Rejected
    RequestedUtc    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    ActedUtc        DATETIME2 NULL
);
GO

CREATE INDEX IX_RawLog_Unprocessed ON attendance.RAW_DEVICE_LOG (IsProcessed, PunchTimeUtc) INCLUDE (EmployeeId);
CREATE INDEX IX_RawLog_EmpTime     ON attendance.RAW_DEVICE_LOG (EmployeeId, PunchTimeUtc);
CREATE INDEX IX_Attendance_EmpDate ON attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate);
CREATE INDEX IX_Attendance_Date    ON attendance.ATTENDANCE_RECORD (WorkDate) INCLUDE ([Status], HasAnomaly);
GO

/* ############################################################################
   ============================  SAMPLE DATA  ===============================
   Raw punches are seeded UNPROCESSED so the smoke test at the bottom actually
   EXERCISES the processor and you can see the computed results.

   Rami (10), 2026-06-02, Morning 08:00-16:00 (grace 10, break 30):
     IN 08:20, OUT 12:00, IN 14:00, OUT 17:00
     -> intervals 220 + 180 = 400 gross;  gap 120;  break 30 taken from the gap
     -> WORKED = 400  (NOT 520 - the mid-day absence is not paid)
     -> ExitActual = 90  (120 gap - 30 break)
     -> Standard = 480 - 30 = 450;  DayFraction = 0.89;  IsFullDay = 0
     -> Late = 10   (08:20 vs 08:10 = start + grace)
   Lina (11), 2026-06-02, Evening 15:00-23:00: IN 15:00, OUT 23:30, never punched
     out for the break -> Worked = 510 - 30 = 480;  Standard 450 -> OT detected 30.
   Joe (12): rest day, no punches -> MarkAbsentees creates the RestDay row.
   ############################################################################ */

SET IDENTITY_INSERT attendance.DEVICE ON;
INSERT INTO attendance.DEVICE (DeviceId, SerialNumber, BranchId, DepartmentId, LastSyncUtc) VALUES
 (1, 'ZK-1234',      1, NULL, '2026-06-02T17:00:00'),   -- the shop terminal
 (2, 'MANUAL-ENTRY', 1, NULL, NULL),                    -- synthetic: manual HR entry
 (3, 'EXCEL-IMPORT', 1, NULL, NULL);                    -- synthetic: Excel import
SET IDENTITY_INSERT attendance.DEVICE OFF;

SET IDENTITY_INSERT attendance.EMPLOYEE_DEVICE ON;
INSERT INTO attendance.EMPLOYEE_DEVICE (EmployeeDeviceId, EmployeeId, DeviceId, EnrollPin) VALUES
 (1, 10, 1, '1001'), (2, 11, 1, '1002'), (3, 12, 1, '1003');
SET IDENTITY_INSERT attendance.EMPLOYEE_DEVICE OFF;

SET IDENTITY_INSERT attendance.SHIFT ON;
INSERT INTO attendance.SHIFT (ShiftId, Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes) VALUES
 (1, 'Morning', '08:00', '16:00', 10, 0, 30),
 (2, 'Evening', '15:00', '23:00', 10, 0, 30),
 (3, 'Night',   '22:00', '06:00', 10, 1, 30);
SET IDENTITY_INSERT attendance.SHIFT OFF;

SET IDENTITY_INSERT attendance.SHIFT_ASSIGNMENT ON;
INSERT INTO attendance.SHIFT_ASSIGNMENT (ShiftAssignmentId, EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES
 (1, 10, 1,    '2026-06-02', 0),
 (2, 11, 2,    '2026-06-02', 0),
 (3, 12, NULL, '2026-06-02', 1);
SET IDENTITY_INSERT attendance.SHIFT_ASSIGNMENT OFF;

SET IDENTITY_INSERT attendance.RAW_DEVICE_LOG ON;
INSERT INTO attendance.RAW_DEVICE_LOG
    (RawLogId, DeviceId, ImportBatchId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash, IsProcessed) VALUES
 (1, 1, NULL, '1001', 10, '2026-06-02T08:20:00', 0, 'Device', 'H-1001-20260602-0820-IN',  0),
 (2, 1, NULL, '1001', 10, '2026-06-02T12:00:00', 1, 'Device', 'H-1001-20260602-1200-OUT', 0),
 (3, 1, NULL, '1001', 10, '2026-06-02T14:00:00', 0, 'Device', 'H-1001-20260602-1400-IN',  0),
 (4, 1, NULL, '1001', 10, '2026-06-02T17:00:00', 1, 'Device', 'H-1001-20260602-1700-OUT', 0),
 (5, 1, NULL, '1002', 11, '2026-06-02T15:00:00', 0, 'Device', 'H-1002-20260602-1500-IN',  0),
 (6, 1, NULL, '1002', 11, '2026-06-02T23:30:00', 1, 'Device', 'H-1002-20260602-2330-OUT', 0);
SET IDENTITY_INSERT attendance.RAW_DEVICE_LOG OFF;

/* Rami's default week (Approach B): Mon-Fri Morning, weekend off. */
INSERT INTO attendance.EMPLOYEE_SHIFT_PATTERN (EmployeeId, DayOfWeek, ShiftId, IsRestDay) VALUES
 (10, 1, 1, 0), (10, 2, 1, 0), (10, 3, 1, 0), (10, 4, 1, 0), (10, 5, 1, 0),
 (10, 6, NULL, 1), (10, 7, NULL, 1);
GO

/* ############################################################################
   ==============  SECTION 1 - DEVICES & ENROLLMENT (CRUD)  ==================
   ############################################################################ */

CREATE PROCEDURE attendance.usp_Device_GetAll
AS BEGIN SET NOCOUNT ON;
    SELECT d.DeviceId, d.SerialNumber, d.BranchId, b.Name AS BranchName,
           d.DepartmentId, dp.Name AS DepartmentName, d.IsActive, d.LastSyncUtc
    FROM attendance.DEVICE d
    JOIN hr.BRANCH b           ON b.BranchId = d.BranchId
    LEFT JOIN hr.DEPARTMENT dp ON dp.DepartmentId = d.DepartmentId
    ORDER BY b.Name, d.SerialNumber; END;
GO

/* The push endpoint sends a SERIAL, not an id - resolve it here. */
CREATE PROCEDURE attendance.usp_Device_GetBySerial @SerialNumber VARCHAR(60)
AS BEGIN SET NOCOUNT ON;
    SELECT DeviceId, SerialNumber, BranchId, DepartmentId, IsActive
    FROM attendance.DEVICE WHERE SerialNumber = @SerialNumber; END;
GO

CREATE PROCEDURE attendance.usp_Device_Create
    @SerialNumber VARCHAR(60), @BranchId INT, @DepartmentId INT = NULL
AS BEGIN SET NOCOUNT ON;
    INSERT INTO attendance.DEVICE (SerialNumber, BranchId, DepartmentId)
    VALUES (@SerialNumber, @BranchId, @DepartmentId);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS DeviceId; END;
GO

CREATE PROCEDURE attendance.usp_Device_Update
    @DeviceId INT, @SerialNumber VARCHAR(60), @BranchId INT,
    @DepartmentId INT = NULL, @IsActive BIT
AS BEGIN SET NOCOUNT ON;
    UPDATE attendance.DEVICE
    SET SerialNumber = @SerialNumber, BranchId = @BranchId,
        DepartmentId = @DepartmentId, IsActive = @IsActive
    WHERE DeviceId = @DeviceId; END;
GO

CREATE PROCEDURE attendance.usp_Device_TouchSync @DeviceId INT
AS BEGIN SET NOCOUNT ON;
    UPDATE attendance.DEVICE SET LastSyncUtc = SYSUTCDATETIME() WHERE DeviceId = @DeviceId; END;
GO

CREATE PROCEDURE attendance.usp_EmployeeDevice_GetAll
AS BEGIN SET NOCOUNT ON;
    SELECT ed.EmployeeDeviceId, ed.EmployeeId, e.FullName,
           ed.DeviceId, d.SerialNumber, b.Name AS BranchName, ed.EnrollPin
    FROM attendance.EMPLOYEE_DEVICE ed
    JOIN hr.EMPLOYEE e       ON e.EmployeeId = ed.EmployeeId
    JOIN attendance.DEVICE d ON d.DeviceId = ed.DeviceId
    JOIN hr.BRANCH b         ON b.BranchId = d.BranchId
    ORDER BY e.FullName, d.SerialNumber; END;
GO

/* Map a PIN on a device to an employee, and RETRO-RESOLVE any punches that already
   arrived under that (device, PIN) with no employee - so nothing is ever lost.
   NOTE: @@ROWCOUNT is captured BEFORE the COMMIT (a COMMIT resets it). */
CREATE PROCEDURE attendance.usp_EmployeeDevice_Map
    @EmployeeId INT, @DeviceId INT, @EnrollPin VARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Resolved INT = 0;

    BEGIN TRAN;

    IF NOT EXISTS (SELECT 1 FROM attendance.EMPLOYEE_DEVICE
                   WHERE DeviceId = @DeviceId AND EnrollPin = @EnrollPin)
        INSERT INTO attendance.EMPLOYEE_DEVICE (EmployeeId, DeviceId, EnrollPin)
        VALUES (@EmployeeId, @DeviceId, @EnrollPin);

    UPDATE attendance.RAW_DEVICE_LOG
    SET EmployeeId = @EmployeeId
    WHERE DeviceId = @DeviceId AND EnrollPin = @EnrollPin AND EmployeeId IS NULL;

    SET @Resolved = @@ROWCOUNT;          -- capture BEFORE commit

    COMMIT TRAN;

    SELECT @Resolved AS OrphanPunchesResolved;
END;
GO

CREATE PROCEDURE attendance.usp_EmployeeDevice_Unmap @EmployeeDeviceId INT
AS BEGIN SET NOCOUNT ON;
    DELETE FROM attendance.EMPLOYEE_DEVICE WHERE EmployeeDeviceId = @EmployeeDeviceId; END;
GO

/* ############################################################################
   ==================  SECTION 2 - SHIFTS (CRUD)  ============================
   ############################################################################ */

CREATE PROCEDURE attendance.usp_Shift_GetAll
AS BEGIN SET NOCOUNT ON;
    SELECT ShiftId, Name, StartTime, EndTime, GraceMinutes, CrossesMidnight,
           BreakMinutes, IsActive
    FROM attendance.SHIFT ORDER BY StartTime; END;
GO

CREATE PROCEDURE attendance.usp_Shift_Create
    @Name NVARCHAR(50), @StartTime TIME, @EndTime TIME,
    @GraceMinutes INT = 0, @CrossesMidnight BIT = 0, @BreakMinutes INT = 0
AS BEGIN SET NOCOUNT ON;
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes)
    VALUES (@Name, @StartTime, @EndTime, @GraceMinutes, @CrossesMidnight, @BreakMinutes);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS ShiftId; END;
GO

CREATE PROCEDURE attendance.usp_Shift_Update
    @ShiftId INT, @Name NVARCHAR(50), @StartTime TIME, @EndTime TIME,
    @GraceMinutes INT, @CrossesMidnight BIT, @BreakMinutes INT, @IsActive BIT
AS BEGIN SET NOCOUNT ON;
    UPDATE attendance.SHIFT
    SET Name = @Name, StartTime = @StartTime, EndTime = @EndTime,
        GraceMinutes = @GraceMinutes, CrossesMidnight = @CrossesMidnight,
        BreakMinutes = @BreakMinutes, IsActive = @IsActive
    WHERE ShiftId = @ShiftId; END;
GO

/* ############################################################################
   ==============  SECTION 3 - ROSTER (CRUD + GENERATION)  ===================
   SHIFT_ASSIGNMENT is one row per employee-DAY (the processor needs that), but HR
   must NEVER type those rows day by day. These procedures GENERATE them.

   TWO APPROACHES - HR uses whichever suits; both write the same rows:
     A "generate on demand"   : GenerateRange / GenerateRange_Bulk / CopyPeriod
     B "saved weekly pattern" : EMPLOYEE_SHIFT_PATTERN + ApplyPattern(_ForMonth)
   All are SAFE to re-run: @Overwrite = 0 (default) preserves existing rows, so
   manual swaps survive a regeneration.
   NOTE: CTEs are named roster_plan / cal_dates - 'plan' alone is a reserved word.
   ############################################################################ */

CREATE PROCEDURE attendance.usp_ShiftAssignment_GetByDateRange
    @FromDate DATE, @ToDate DATE, @EmployeeId INT = NULL
AS BEGIN SET NOCOUNT ON;
    SELECT sa.ShiftAssignmentId, sa.EmployeeId, e.FullName, sa.ShiftId, s.Name AS ShiftName,
           s.StartTime, s.EndTime, sa.WorkDate, sa.IsRestDay
    FROM attendance.SHIFT_ASSIGNMENT sa
    JOIN hr.EMPLOYEE e           ON e.EmployeeId = sa.EmployeeId
    LEFT JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
    WHERE sa.WorkDate BETWEEN @FromDate AND @ToDate
      AND (@EmployeeId IS NULL OR sa.EmployeeId = @EmployeeId)
    ORDER BY sa.WorkDate, e.FullName; END;
GO

/* Set/change ONE employee-day (what a click on a calendar cell calls). */
CREATE PROCEDURE attendance.usp_ShiftAssignment_Upsert
    @EmployeeId INT, @WorkDate DATE, @ShiftId INT = NULL, @IsRestDay BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT
               WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate)
        UPDATE attendance.SHIFT_ASSIGNMENT
        SET ShiftId = @ShiftId, IsRestDay = @IsRestDay
        WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate;
    ELSE
        INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
        VALUES (@EmployeeId, @ShiftId, @WorkDate, @IsRestDay);

    SELECT ShiftAssignmentId FROM attendance.SHIFT_ASSIGNMENT
    WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate;
END;
GO

CREATE PROCEDURE attendance.usp_ShiftAssignment_Delete @ShiftAssignmentId INT
AS BEGIN SET NOCOUNT ON;
    DELETE FROM attendance.SHIFT_ASSIGNMENT WHERE ShiftAssignmentId = @ShiftAssignmentId; END;
GO

/* APPROACH A - generate one employee's roster over a range, on chosen weekdays.
   @Weekdays is a 7-char mask Mon..Sun, '1' = a working day. e.g. '1111100' = Mon-Fri.
   Days NOT in the mask are written as REST DAYS, so the roster is complete.
   Weekday is derived independently of @@DATEFIRST, so the server's locale can't
   silently shift everyone's schedule. */
CREATE PROCEDURE attendance.usp_ShiftAssignment_GenerateRange
    @EmployeeId INT,
    @FromDate   DATE,
    @ToDate     DATE,
    @ShiftId    INT,
    @Weekdays   CHAR(7) = '1111100',
    @Overwrite  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate > @ToDate
    BEGIN RAISERROR('FromDate must be on or before ToDate.', 16, 1); RETURN; END

    IF OBJECT_ID('tempdb..#roster_plan') IS NOT NULL DROP TABLE #roster_plan;

    ;WITH cal_dates AS (
        SELECT @FromDate AS d
        UNION ALL
        SELECT DATEADD(DAY, 1, d) FROM cal_dates WHERE d < @ToDate
    )
    SELECT
        @EmployeeId AS EmployeeId,
        c.d         AS WorkDate,
        CASE WHEN SUBSTRING(@Weekdays, ((DATEPART(WEEKDAY, c.d) + @@DATEFIRST - 2) % 7) + 1, 1) = '1'
             THEN @ShiftId ELSE NULL END AS ShiftId,
        CASE WHEN SUBSTRING(@Weekdays, ((DATEPART(WEEKDAY, c.d) + @@DATEFIRST - 2) % 7) + 1, 1) = '1'
             THEN 0 ELSE 1 END           AS IsRestDay
    INTO #roster_plan
    FROM cal_dates c
    OPTION (MAXRECURSION 400);

    IF @Overwrite = 1
        UPDATE sa
        SET sa.ShiftId = p.ShiftId, sa.IsRestDay = p.IsRestDay
        FROM attendance.SHIFT_ASSIGNMENT sa
        JOIN #roster_plan p ON p.EmployeeId = sa.EmployeeId AND p.WorkDate = sa.WorkDate;

    INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
    SELECT p.EmployeeId, p.ShiftId, p.WorkDate, p.IsRestDay
    FROM #roster_plan p
    WHERE NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                      WHERE sa.EmployeeId = p.EmployeeId AND sa.WorkDate = p.WorkDate);

    DECLARE @Inserted INT = @@ROWCOUNT;
    DROP TABLE #roster_plan;
    SELECT @Inserted AS RowsInserted;
END;
GO

/* APPROACH A (bulk) - roster a whole TEAM in one action. @EmployeeIds = '10,11,12'. */
CREATE PROCEDURE attendance.usp_ShiftAssignment_GenerateRange_Bulk
    @EmployeeIds NVARCHAR(MAX),
    @FromDate    DATE,
    @ToDate      DATE,
    @ShiftId     INT,
    @Weekdays    CHAR(7) = '1111100',
    @Overwrite   BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Emp INT, @Count INT = 0;

    DECLARE emp_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT CAST(LTRIM(RTRIM(value)) AS INT)
        FROM STRING_SPLIT(@EmployeeIds, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

    OPEN emp_cur;
    FETCH NEXT FROM emp_cur INTO @Emp;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC attendance.usp_ShiftAssignment_GenerateRange
             @EmployeeId = @Emp, @FromDate = @FromDate, @ToDate = @ToDate,
             @ShiftId = @ShiftId, @Weekdays = @Weekdays, @Overwrite = @Overwrite;
        SET @Count = @Count + 1;
        FETCH NEXT FROM emp_cur INTO @Emp;
    END
    CLOSE emp_cur;
    DEALLOCATE emp_cur;

    SELECT @Count AS EmployeesProcessed;
END;
GO

/* APPROACH A - copy one month's roster to another, aligned by WEEKDAY (a Monday
   shift lands on a Monday, not on the same date number). This is how HR really
   works: copy last month, then tweak the exceptions. */
CREATE PROCEDURE attendance.usp_ShiftAssignment_CopyPeriod
    @SourceYearMonth CHAR(7),         -- e.g. '2026-06'
    @TargetYearMonth CHAR(7),         -- e.g. '2026-07'
    @EmployeeId      INT = NULL,      -- NULL = everyone
    @Overwrite       BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @srcFrom DATE = CAST(@SourceYearMonth + '-01' AS DATE);
    DECLARE @srcTo   DATE = EOMONTH(@srcFrom);
    DECLARE @tgtFrom DATE = CAST(@TargetYearMonth + '-01' AS DATE);
    DECLARE @tgtTo   DATE = EOMONTH(@tgtFrom);

    IF OBJECT_ID('tempdb..#roster_plan') IS NOT NULL DROP TABLE #roster_plan;

    ;WITH cal_dates AS (
        SELECT @tgtFrom AS d
        UNION ALL
        SELECT DATEADD(DAY, 1, d) FROM cal_dates WHERE d < @tgtTo
    ),
    tgt_days AS (
        SELECT d AS WorkDate, ((DATEPART(WEEKDAY, d) + @@DATEFIRST - 2) % 7) + 1 AS Dow
        FROM cal_dates
    ),
    src_rows AS (
        SELECT sa.EmployeeId,
               ((DATEPART(WEEKDAY, sa.WorkDate) + @@DATEFIRST - 2) % 7) + 1 AS Dow,
               sa.ShiftId, sa.IsRestDay,
               COUNT(*) AS Freq
        FROM attendance.SHIFT_ASSIGNMENT sa
        WHERE sa.WorkDate BETWEEN @srcFrom AND @srcTo
          AND (@EmployeeId IS NULL OR sa.EmployeeId = @EmployeeId)
        GROUP BY sa.EmployeeId,
                 ((DATEPART(WEEKDAY, sa.WorkDate) + @@DATEFIRST - 2) % 7) + 1,
                 sa.ShiftId, sa.IsRestDay
    ),
    src_pattern AS (
        SELECT EmployeeId, Dow, ShiftId, IsRestDay,
               ROW_NUMBER() OVER (PARTITION BY EmployeeId, Dow ORDER BY Freq DESC) AS rn
        FROM src_rows
    )
    SELECT sp.EmployeeId, td.WorkDate, sp.ShiftId, sp.IsRestDay
    INTO #roster_plan
    FROM src_pattern sp
    JOIN tgt_days td ON td.Dow = sp.Dow
    WHERE sp.rn = 1
    OPTION (MAXRECURSION 400);

    IF @Overwrite = 1
        UPDATE sa
        SET sa.ShiftId = p.ShiftId, sa.IsRestDay = p.IsRestDay
        FROM attendance.SHIFT_ASSIGNMENT sa
        JOIN #roster_plan p ON p.EmployeeId = sa.EmployeeId AND p.WorkDate = sa.WorkDate;

    INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
    SELECT p.EmployeeId, p.ShiftId, p.WorkDate, p.IsRestDay
    FROM #roster_plan p
    WHERE NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                      WHERE sa.EmployeeId = p.EmployeeId AND sa.WorkDate = p.WorkDate);

    DECLARE @Inserted INT = @@ROWCOUNT;
    DROP TABLE #roster_plan;
    SELECT @Inserted AS RowsInserted;
END;
GO

/* APPROACH B - the saved weekly pattern. */
CREATE PROCEDURE attendance.usp_ShiftPattern_GetByEmployee @EmployeeId INT
AS BEGIN SET NOCOUNT ON;
    SELECT p.PatternId, p.EmployeeId, p.DayOfWeek, p.ShiftId, s.Name AS ShiftName,
           p.IsRestDay, p.IsActive
    FROM attendance.EMPLOYEE_SHIFT_PATTERN p
    LEFT JOIN attendance.SHIFT s ON s.ShiftId = p.ShiftId
    WHERE p.EmployeeId = @EmployeeId
    ORDER BY p.DayOfWeek; END;
GO

CREATE PROCEDURE attendance.usp_ShiftPattern_Upsert
    @EmployeeId INT, @DayOfWeek TINYINT, @ShiftId INT = NULL, @IsRestDay BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @DayOfWeek NOT BETWEEN 1 AND 7
    BEGIN RAISERROR('DayOfWeek must be 1 (Mon) .. 7 (Sun).', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM attendance.EMPLOYEE_SHIFT_PATTERN
               WHERE EmployeeId = @EmployeeId AND DayOfWeek = @DayOfWeek)
        UPDATE attendance.EMPLOYEE_SHIFT_PATTERN
        SET ShiftId = @ShiftId, IsRestDay = @IsRestDay, IsActive = 1
        WHERE EmployeeId = @EmployeeId AND DayOfWeek = @DayOfWeek;
    ELSE
        INSERT INTO attendance.EMPLOYEE_SHIFT_PATTERN (EmployeeId, DayOfWeek, ShiftId, IsRestDay)
        VALUES (@EmployeeId, @DayOfWeek, @ShiftId, @IsRestDay);
END;
GO

CREATE PROCEDURE attendance.usp_ShiftPattern_Delete @EmployeeId INT
AS BEGIN SET NOCOUNT ON;
    DELETE FROM attendance.EMPLOYEE_SHIFT_PATTERN WHERE EmployeeId = @EmployeeId; END;
GO

/* Expand saved weekly patterns into real roster rows for a range. Skips employees
   with no pattern (they use Approach A). A monthly job can call this so the roster
   rolls forward with nobody touching it. */
CREATE PROCEDURE attendance.usp_ShiftAssignment_ApplyPattern
    @FromDate   DATE,
    @ToDate     DATE,
    @EmployeeId INT = NULL,
    @Overwrite  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate > @ToDate
    BEGIN RAISERROR('FromDate must be on or before ToDate.', 16, 1); RETURN; END

    IF OBJECT_ID('tempdb..#roster_plan') IS NOT NULL DROP TABLE #roster_plan;

    ;WITH cal_dates AS (
        SELECT @FromDate AS d
        UNION ALL
        SELECT DATEADD(DAY, 1, d) FROM cal_dates WHERE d < @ToDate
    ),
    cal_days AS (
        SELECT d AS WorkDate, ((DATEPART(WEEKDAY, d) + @@DATEFIRST - 2) % 7) + 1 AS Dow
        FROM cal_dates
    )
    SELECT p.EmployeeId, cd.WorkDate, p.ShiftId, p.IsRestDay
    INTO #roster_plan
    FROM attendance.EMPLOYEE_SHIFT_PATTERN p
    JOIN cal_days cd   ON cd.Dow = p.DayOfWeek
    JOIN hr.EMPLOYEE e ON e.EmployeeId = p.EmployeeId AND e.IsDeleted = 0
    WHERE p.IsActive = 1
      AND (@EmployeeId IS NULL OR p.EmployeeId = @EmployeeId)
      AND e.HireDate <= cd.WorkDate
      AND (e.TerminationDate IS NULL OR e.TerminationDate >= cd.WorkDate)
    OPTION (MAXRECURSION 400);

    IF @Overwrite = 1
        UPDATE sa
        SET sa.ShiftId = p.ShiftId, sa.IsRestDay = p.IsRestDay
        FROM attendance.SHIFT_ASSIGNMENT sa
        JOIN #roster_plan p ON p.EmployeeId = sa.EmployeeId AND p.WorkDate = sa.WorkDate;

    INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
    SELECT p.EmployeeId, p.ShiftId, p.WorkDate, p.IsRestDay
    FROM #roster_plan p
    WHERE NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                      WHERE sa.EmployeeId = p.EmployeeId AND sa.WorkDate = p.WorkDate);

    DECLARE @Inserted INT = @@ROWCOUNT;
    DROP TABLE #roster_plan;
    SELECT @Inserted AS RowsInserted;
END;
GO

CREATE PROCEDURE attendance.usp_ShiftAssignment_ApplyPatternForMonth
    @YearMonth CHAR(7), @EmployeeId INT = NULL, @Overwrite BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATE = CAST(@YearMonth + '-01' AS DATE);
    DECLARE @to   DATE = EOMONTH(@from);
    EXEC attendance.usp_ShiftAssignment_ApplyPattern
         @FromDate = @from, @ToDate = @to, @EmployeeId = @EmployeeId, @Overwrite = @Overwrite;
END;
GO

/* Employee-days with NO roster row. Attendance cannot judge late/absent without one,
   so HR should clear these before the month starts. */
CREATE PROCEDURE attendance.usp_ShiftAssignment_GetGaps
    @FromDate DATE, @ToDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH cal_dates AS (
        SELECT @FromDate AS d
        UNION ALL
        SELECT DATEADD(DAY, 1, d) FROM cal_dates WHERE d < @ToDate
    )
    SELECT e.EmployeeId, e.FullName, c.d AS WorkDate
    FROM cal_dates c
    CROSS JOIN hr.EMPLOYEE e
    WHERE e.IsDeleted = 0
      AND e.HireDate <= c.d
      AND (e.TerminationDate IS NULL OR e.TerminationDate >= c.d)
      AND NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                      WHERE sa.EmployeeId = e.EmployeeId AND sa.WorkDate = c.d)
    ORDER BY c.d, e.FullName
    OPTION (MAXRECURSION 400);
END;
GO

/* ############################################################################
   ================  SECTION 4 - INGESTION (the three paths)  ================
   Path 1 device push  -> usp_RawLog_Insert ([Source]='Device')
   Path 2 excel import -> usp_ImportBatch_Create, then usp_RawLog_Insert per parsed
                          row ([Source]='Excel'), then usp_ImportBatch_SetResult
   Path 3 manual entry -> usp_Attendance_ManualUpsert (Section 6)
   ############################################################################ */

/* Insert ONE raw punch. Used by BOTH device push and Excel shredding.
   Idempotent: a repeat of the same punch (same DedupHash) is ignored and reported as
   WasDuplicate = 1. The API builds DedupHash from device+pin+time+type.
   An unknown PIN is still STORED (EmployeeId NULL) so no punch is ever lost. */
CREATE PROCEDURE attendance.usp_RawLog_Insert
    @DeviceId INT, @EnrollPin VARCHAR(30), @PunchTimeUtc DATETIME2, @PunchType SMALLINT,
    @Source VARCHAR(10), @DedupHash VARCHAR(64), @ImportBatchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM attendance.RAW_DEVICE_LOG WHERE DedupHash = @DedupHash)
    BEGIN
        SELECT CAST(NULL AS BIGINT) AS RawLogId,
               CAST(1 AS BIT)       AS WasDuplicate,
               CAST(0 AS BIT)       AS WasUnresolved;
        RETURN;
    END

    DECLARE @EmployeeId INT =
        (SELECT TOP 1 EmployeeId FROM attendance.EMPLOYEE_DEVICE
         WHERE DeviceId = @DeviceId AND EnrollPin = @EnrollPin);

    INSERT INTO attendance.RAW_DEVICE_LOG
        (DeviceId, ImportBatchId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
    VALUES (@DeviceId, @ImportBatchId, @EnrollPin, @EmployeeId,
            @PunchTimeUtc, @PunchType, @Source, @DedupHash);

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS RawLogId,
           CAST(0 AS BIT) AS WasDuplicate,
           CASE WHEN @EmployeeId IS NULL THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS WasUnresolved;
END;
GO

/* Open an Excel import batch: the ORIGINAL file is stored as JSON here (AUDIT ONLY).
   The API then parses it in C# and calls usp_RawLog_Insert per row. */
CREATE PROCEDURE attendance.usp_ImportBatch_Create
    @FileName NVARCHAR(255), @RawJson NVARCHAR(MAX), @ImportedByUser INT = NULL
AS BEGIN SET NOCOUNT ON;
    INSERT INTO attendance.ATTENDANCE_IMPORT_BATCH (FileName, RawJson, ImportedByUser)
    VALUES (@FileName, @RawJson, @ImportedByUser);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS ImportBatchId; END;
GO

/* Close the batch with its outcome. [RowCount] is bracketed (reserved word). */
CREATE PROCEDURE attendance.usp_ImportBatch_SetResult
    @ImportBatchId INT, @ParsedRows INT, @Status VARCHAR(20), @Note NVARCHAR(300) = NULL
AS BEGIN SET NOCOUNT ON;
    UPDATE attendance.ATTENDANCE_IMPORT_BATCH
    SET [RowCount] = @ParsedRows, [Status] = @Status, Note = @Note
    WHERE ImportBatchId = @ImportBatchId; END;
GO

/* Import history. RawJson is deliberately NOT returned (it can be large). */
CREATE PROCEDURE attendance.usp_ImportBatch_GetAll
AS BEGIN SET NOCOUNT ON;
    SELECT b.ImportBatchId, b.FileName, b.[RowCount], b.[Status],
           b.ImportedByUser, u.Username AS ImportedByUsername, b.ImportedUtc, b.Note
    FROM attendance.ATTENDANCE_IMPORT_BATCH b
    LEFT JOIN security.[USER] u ON u.UserId = b.ImportedByUser
    ORDER BY b.ImportedUtc DESC; END;
GO

/* Fetch one batch INCLUDING its raw JSON (the audit copy). */
CREATE PROCEDURE attendance.usp_ImportBatch_GetJson @ImportBatchId INT
AS BEGIN SET NOCOUNT ON;
    SELECT ImportBatchId, FileName, RawJson, [RowCount], [Status], ImportedUtc
    FROM attendance.ATTENDANCE_IMPORT_BATCH WHERE ImportBatchId = @ImportBatchId; END;
GO

/* ############################################################################
   ==================  SECTION 5 - THE PROCESSOR  ============================
   The ONLY thing that sets RAW_DEVICE_LOG.IsProcessed = 1.
   ############################################################################ */

/* Turn unprocessed raw punches into one ATTENDANCE_RECORD (+ its intervals) per
   employee-day.

   PAIRING: punches are ordered by time; each IN is paired with the NEXT OUT after it.
   Consecutive duplicate punches (IN,IN or OUT,OUT) are collapsed - only an IN whose
   previous punch was an OUT (or which is first) opens an interval - so a double-tap
   on the sensor cannot corrupt the day.

   TIME:  Gross = SUM(intervals);  Gap = SUM(time between them)
          BreakTakenAsGap = MIN(Gap, shift break)      -- they punched out for it
          BreakRemaining  = shift break - BreakTakenAsGap  -- they did not
          Worked = Gross - BreakRemaining
          ExitActual = Gap - BreakTakenAsGap           -- absence BEYOND the break
          Standard = shift length - its break; else config default
          DayFraction = Worked / Standard (capped 1.00);  IsFullDay = >= threshold
          Overtime = Worked - Standard (floored 0)  -- DETECTED ONLY, never auto-paid
          ExitLeave = per core.SETTING.ExitLeaveBasis ('Actual' default / 'Approved')

   IDEMPOTENT: only consumes IsProcessed = 0, and NEVER touches a row with
   IsManual = 1 (manual entries and approved corrections are protected).
   Unresolved PINs (EmployeeId NULL) are SKIPPED and stay unprocessed until HR maps
   the PIN - they are never lost. */
CREATE PROCEDURE attendance.usp_Attendance_ProcessRawLogs
    @WorkDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @StdDefault INT = core.fn_StandardDayMinutes();
    DECLARE @LeaveBasis VARCHAR(20) =
        ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'ExitLeaveBasis'), 'Actual');
    DECLARE @FullDayThreshold DECIMAL(5,2) =
        ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'FullDayThreshold') AS DECIMAL(5,2)), 1.00);
    DECLARE @DaysProcessed INT = 0;

    BEGIN TRAN;

    /* -- 1. punches in scope, with the previous punch type (to collapse duplicates) -- */
    IF OBJECT_ID('tempdb..#punch') IS NOT NULL DROP TABLE #punch;

    SELECT
        r.RawLogId, r.EmployeeId,
        CAST(r.PunchTimeUtc AS DATE) AS WorkDate,
        r.PunchTimeUtc, r.PunchType, r.[Source], r.DeviceId,
        LAG(r.PunchType) OVER (PARTITION BY r.EmployeeId, CAST(r.PunchTimeUtc AS DATE)
                               ORDER BY r.PunchTimeUtc) AS PrevType
    INTO #punch
    FROM attendance.RAW_DEVICE_LOG r
    WHERE r.IsProcessed = 0
      AND r.EmployeeId IS NOT NULL
      AND (@WorkDate IS NULL OR CAST(r.PunchTimeUtc AS DATE) = @WorkDate);

    /* -- 2. pair each opening IN with the next OUT -- */
    IF OBJECT_ID('tempdb..#pair') IS NOT NULL DROP TABLE #pair;

    SELECT
        i.EmployeeId, i.WorkDate, i.PunchTimeUtc AS InTimeUtc,
        (SELECT MIN(o.PunchTimeUtc)
         FROM #punch o
         WHERE o.EmployeeId = i.EmployeeId
           AND o.WorkDate   = i.WorkDate
           AND o.PunchType  = 1
           AND o.PunchTimeUtc > i.PunchTimeUtc) AS OutTimeUtc
    INTO #pair
    FROM #punch i
    WHERE i.PunchType = 0
      AND (i.PrevType IS NULL OR i.PrevType = 1);     -- collapse consecutive INs

    /* -- 3. number, measure, and find the gap after each interval -- */
    IF OBJECT_ID('tempdb..#ivl') IS NOT NULL DROP TABLE #ivl;

    SELECT
        x.EmployeeId, x.WorkDate, x.SeqNo, x.InTimeUtc, x.OutTimeUtc, x.Minutes,
        ISNULL(DATEDIFF(MINUTE, x.OutTimeUtc,
               LEAD(x.InTimeUtc) OVER (PARTITION BY x.EmployeeId, x.WorkDate ORDER BY x.SeqNo)), 0) AS GapAfterMins
    INTO #ivl
    FROM (
        SELECT EmployeeId, WorkDate, InTimeUtc, OutTimeUtc,
               ROW_NUMBER() OVER (PARTITION BY EmployeeId, WorkDate ORDER BY InTimeUtc) AS SeqNo,
               DATEDIFF(MINUTE, InTimeUtc, OutTimeUtc) AS Minutes
        FROM #pair
        WHERE OutTimeUtc IS NOT NULL                  -- an IN with no OUT = anomaly
    ) x;

    /* -- 4. one row per employee-day, with the shift and the interval roll-up -- */
    IF OBJECT_ID('tempdb..#calc') IS NOT NULL DROP TABLE #calc;

    SELECT
        d.EmployeeId, d.WorkDate, d.FirstInUtc, d.LastOutUtc, d.InCount, d.OutCount,
        d.SourceName, d.DeviceId,
        dev.BranchId,
        sa.ShiftAssignmentId,
        ISNULL(sa.IsRestDay, 0)   AS IsRestDay,
        ISNULL(s.GraceMinutes, 0) AS GraceMinutes,
        ISNULL(s.BreakMinutes, 0) AS BreakMinutes,
        ISNULL(iv.Pairs, 0)       AS PunchPairs,
        ISNULL(iv.GrossMinutes,0) AS GrossMinutes,
        ISNULL(iv.GapMinutes, 0)  AS GapMinutes,
        CASE WHEN s.StartTime IS NULL THEN NULL
             ELSE DATEADD(MINUTE, DATEDIFF(MINUTE, 0, s.StartTime), CAST(d.WorkDate AS DATETIME2))
        END AS ShiftStartUtc,
        CASE WHEN s.StartTime IS NULL THEN @StdDefault
             ELSE (DATEDIFF(MINUTE, s.StartTime, s.EndTime)
                   + CASE WHEN s.CrossesMidnight = 1 THEN 1440 ELSE 0 END)
                  - ISNULL(s.BreakMinutes, 0)
        END AS StandardMinutes
    INTO #calc
    FROM (
        SELECT p.EmployeeId, p.WorkDate,
               MIN(CASE WHEN p.PunchType = 0 THEN p.PunchTimeUtc END) AS FirstInUtc,
               MAX(CASE WHEN p.PunchType = 1 THEN p.PunchTimeUtc END) AS LastOutUtc,
               SUM(CASE WHEN p.PunchType = 0 THEN 1 ELSE 0 END)       AS InCount,
               SUM(CASE WHEN p.PunchType = 1 THEN 1 ELSE 0 END)       AS OutCount,
               MIN(p.[Source])                                        AS SourceName,
               MIN(p.DeviceId)                                        AS DeviceId
        FROM #punch p
        GROUP BY p.EmployeeId, p.WorkDate
    ) d
    JOIN attendance.DEVICE dev ON dev.DeviceId = d.DeviceId
    LEFT JOIN attendance.SHIFT_ASSIGNMENT sa
           ON sa.EmployeeId = d.EmployeeId AND sa.WorkDate = d.WorkDate
    LEFT JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
    OUTER APPLY (
        SELECT COUNT(*) AS Pairs, SUM(g.Minutes) AS GrossMinutes, SUM(g.GapAfterMins) AS GapMinutes
        FROM #ivl g
        WHERE g.EmployeeId = d.EmployeeId AND g.WorkDate = d.WorkDate
    ) iv;

    /* -- 5. derive worked / exit / fraction / overtime -- */
    IF OBJECT_ID('tempdb..#rec') IS NOT NULL DROP TABLE #rec;

    SELECT
        b.EmployeeId, b.WorkDate, b.FirstInUtc, b.LastOutUtc, b.ShiftAssignmentId,
        b.SourceName, b.DeviceId, b.BranchId, b.PunchPairs, b.GrossMinutes, b.GapMinutes,
        b.StandardMinutes, b.LateMinutes, b.RecStatus, b.HasAnomaly,
        b.BreakApplied, b.WorkedMinutes, b.ExitActualMinutes,
        DayFraction = CASE
            WHEN b.StandardMinutes = 0 THEN 0
            WHEN CAST(b.WorkedMinutes AS DECIMAL(12,4)) / b.StandardMinutes > 1 THEN 1.00
            ELSE CAST(ROUND(CAST(b.WorkedMinutes AS DECIMAL(12,4)) / b.StandardMinutes, 2) AS DECIMAL(5,2))
            END,
        ShortfallMinutes = CASE WHEN b.StandardMinutes - b.WorkedMinutes > 0
                                THEN b.StandardMinutes - b.WorkedMinutes ELSE 0 END,
        OvertimeMinutes  = CASE WHEN b.WorkedMinutes - b.StandardMinutes > 0
                                THEN b.WorkedMinutes - b.StandardMinutes ELSE 0 END
    INTO #rec
    FROM (
        SELECT
            a.EmployeeId, a.WorkDate, a.FirstInUtc, a.LastOutUtc, a.ShiftAssignmentId,
            a.SourceName, a.DeviceId, a.BranchId, a.PunchPairs, a.GrossMinutes, a.GapMinutes,
            a.StandardMinutes,
            BreakApplied  = a.BreakTakenAsGap + a.BreakRemaining,
            WorkedMinutes = CASE WHEN a.GrossMinutes - a.BreakRemaining > 0
                                 THEN a.GrossMinutes - a.BreakRemaining ELSE 0 END,
            ExitActualMinutes = CASE WHEN a.GapMinutes - a.BreakTakenAsGap > 0
                                     THEN a.GapMinutes - a.BreakTakenAsGap ELSE 0 END,
            LateMinutes = CASE
                WHEN a.FirstInUtc IS NULL OR a.ShiftStartUtc IS NULL THEN 0
                WHEN DATEDIFF(MINUTE, DATEADD(MINUTE, a.GraceMinutes, a.ShiftStartUtc), a.FirstInUtc) > 0
                     THEN DATEDIFF(MINUTE, DATEADD(MINUTE, a.GraceMinutes, a.ShiftStartUtc), a.FirstInUtc)
                ELSE 0 END,
            RecStatus = CASE
                WHEN a.IsRestDay = 1          THEN 'RestDay'
                WHEN a.FirstInUtc IS NOT NULL THEN 'Present'
                ELSE 'Absent' END,
            HasAnomaly = CASE
                WHEN a.InCount <> a.OutCount OR a.FirstInUtc IS NULL OR a.LastOutUtc IS NULL
                THEN 1 ELSE 0 END
        FROM (
            SELECT c.*,
                   BreakTakenAsGap = CASE WHEN c.GapMinutes < c.BreakMinutes
                                          THEN c.GapMinutes ELSE c.BreakMinutes END,
                   BreakRemaining  = CASE WHEN c.BreakMinutes - c.GapMinutes > 0
                                          THEN c.BreakMinutes - c.GapMinutes ELSE 0 END
            FROM #calc c
        ) a
    ) b;

    /* -- 6. upsert the records; never touch manual/corrected rows -- */
    UPDATE a
    SET a.FirstInUtc          = r.FirstInUtc,
        a.LastOutUtc          = r.LastOutUtc,
        a.ShiftAssignmentId   = r.ShiftAssignmentId,
        a.PunchPairs          = r.PunchPairs,
        a.GrossMinutes        = r.GrossMinutes,
        a.GapMinutes          = r.GapMinutes,
        a.BreakApplied        = r.BreakApplied,
        a.WorkedMinutes       = r.WorkedMinutes,
        a.StandardMinutes     = r.StandardMinutes,
        a.DayFraction         = r.DayFraction,
        a.IsFullDay           = CASE WHEN r.DayFraction >= @FullDayThreshold THEN 1 ELSE 0 END,
        a.ShortfallMinutes    = r.ShortfallMinutes,
        a.LateMinutes         = r.LateMinutes,
        a.OvertimeMinutes     = r.OvertimeMinutes,
        a.ExitActualMinutes   = r.ExitActualMinutes,
        a.ExitVarianceMinutes = r.ExitActualMinutes - a.ExitApprovedMinutes,
        a.ExitLeaveMinutes    = CASE WHEN @LeaveBasis = 'Approved'
                                     THEN a.ExitApprovedMinutes ELSE r.ExitActualMinutes END,
        a.[Status]            = r.RecStatus,
        a.[Source]            = r.SourceName,
        a.DeviceId            = r.DeviceId,
        a.BranchId            = r.BranchId,
        a.HasAnomaly          = r.HasAnomaly,
        a.ProcessedUtc        = SYSUTCDATETIME()
    FROM attendance.ATTENDANCE_RECORD a
    JOIN #rec r ON r.EmployeeId = a.EmployeeId AND r.WorkDate = a.WorkDate
    WHERE a.IsManual = 0;

    INSERT INTO attendance.ATTENDANCE_RECORD
        (EmployeeId, ShiftAssignmentId, WorkDate, FirstInUtc, LastOutUtc, PunchPairs,
         GrossMinutes, GapMinutes, BreakApplied, WorkedMinutes, StandardMinutes,
         DayFraction, IsFullDay, ShortfallMinutes, LateMinutes, OvertimeMinutes,
         ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes, ExitLeaveMinutes,
         [Status], [Source], DeviceId, BranchId, HasAnomaly, IsManual, ProcessedUtc)
    SELECT r.EmployeeId, r.ShiftAssignmentId, r.WorkDate, r.FirstInUtc, r.LastOutUtc, r.PunchPairs,
           r.GrossMinutes, r.GapMinutes, r.BreakApplied, r.WorkedMinutes, r.StandardMinutes,
           r.DayFraction,
           CASE WHEN r.DayFraction >= @FullDayThreshold THEN 1 ELSE 0 END,
           r.ShortfallMinutes, r.LateMinutes, r.OvertimeMinutes,
           r.ExitActualMinutes,
           0,                                          -- no approval known yet
           r.ExitActualMinutes,                        -- variance = actual - 0
           CASE WHEN @LeaveBasis = 'Approved' THEN 0 ELSE r.ExitActualMinutes END,
           r.RecStatus, r.SourceName, r.DeviceId, r.BranchId, r.HasAnomaly, 0, SYSUTCDATETIME()
    FROM #rec r
    WHERE NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a
                      WHERE a.EmployeeId = r.EmployeeId AND a.WorkDate = r.WorkDate);

    /* -- 7. rewrite the interval audit rows for the days we touched -- */
    DELETE i
    FROM attendance.ATTENDANCE_INTERVAL i
    JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = i.AttendanceId
    JOIN #rec r ON r.EmployeeId = a.EmployeeId AND r.WorkDate = a.WorkDate
    WHERE a.IsManual = 0;

    INSERT INTO attendance.ATTENDANCE_INTERVAL (AttendanceId, SeqNo, InTimeUtc, OutTimeUtc, Minutes, GapAfterMins)
    SELECT a.AttendanceId, g.SeqNo, g.InTimeUtc, g.OutTimeUtc, g.Minutes, g.GapAfterMins
    FROM #ivl g
    JOIN attendance.ATTENDANCE_RECORD a
      ON a.EmployeeId = g.EmployeeId AND a.WorkDate = g.WorkDate
    WHERE a.IsManual = 0;

    /* -- 8. mark exactly the raw rows we consumed -- */
    UPDATE r
    SET r.IsProcessed = 1
    FROM attendance.RAW_DEVICE_LOG r
    JOIN #rec f ON f.EmployeeId = r.EmployeeId
               AND f.WorkDate   = CAST(r.PunchTimeUtc AS DATE)
    WHERE r.IsProcessed = 0 AND r.EmployeeId IS NOT NULL;

    SET @DaysProcessed = (SELECT COUNT(*) FROM #rec);

    COMMIT TRAN;

    SELECT @DaysProcessed AS EmployeeDaysProcessed;
END;
GO

/* Rostered employees with NO punches at all. The processor only sees days that HAVE
   punches, so without this a fully-absent employee would have no record and payroll
   would never know. Run AFTER the processor. Never overwrites an existing record. */
CREATE PROCEDURE attendance.usp_Attendance_MarkAbsentees
    @WorkDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @StdDefault INT = core.fn_StandardDayMinutes();

    INSERT INTO attendance.ATTENDANCE_RECORD
        (EmployeeId, ShiftAssignmentId, WorkDate, StandardMinutes, [Status], [Source],
         BranchId, IsManual, ProcessedUtc)
    SELECT sa.EmployeeId, sa.ShiftAssignmentId, sa.WorkDate,
           CASE WHEN s.StartTime IS NULL THEN @StdDefault
                ELSE (DATEDIFF(MINUTE, s.StartTime, s.EndTime)
                      + CASE WHEN s.CrossesMidnight = 1 THEN 1440 ELSE 0 END)
                     - ISNULL(s.BreakMinutes, 0) END,
           CASE WHEN sa.IsRestDay = 1 THEN 'RestDay' ELSE 'Absent' END,
           'Device', e.BranchId, 0, SYSUTCDATETIME()
    FROM attendance.SHIFT_ASSIGNMENT sa
    JOIN hr.EMPLOYEE e           ON e.EmployeeId = sa.EmployeeId AND e.IsDeleted = 0
    LEFT JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
    WHERE sa.WorkDate = @WorkDate
      AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a
                      WHERE a.EmployeeId = sa.EmployeeId AND a.WorkDate = sa.WorkDate);

    SELECT @@ROWCOUNT AS AbsenteesMarked;
END;
GO

/* ############################################################################
   ==========  SECTION 6 - MANUAL ENTRY + HR OVERRIDES (HR ONLY)  ============
   Permission ATTENDANCE_CORRECT in the API. "Anything HR can do via workflow,
   HR can also do manually."
   ############################################################################ */

/* Create/override a day directly - machine down, or a punch never happened.
   @ExitMinutes lets HR record a mid-day absence they know about; @ExitApprovedMins
   how much of it was authorised. Late/worked/OT/fraction are recomputed against the
   rostered shift, so a manual day is measured by exactly the same rules. IsManual=1. */
CREATE PROCEDURE attendance.usp_Attendance_ManualUpsert
    @EmployeeId       INT,
    @WorkDate         DATE,
    @FirstInUtc       DATETIME2 = NULL,
    @LastOutUtc       DATETIME2 = NULL,
    @ExitMinutes      INT = 0,
    @ExitApprovedMins INT = 0,
    @Status           VARCHAR(20) = NULL,
    @BranchId         INT = NULL,
    @HrNote           NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @LeaveBasis VARCHAR(20) =
        ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'ExitLeaveBasis'), 'Actual');
    DECLARE @FullDayThreshold DECIMAL(5,2) =
        ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'FullDayThreshold') AS DECIMAL(5,2)), 1.00);
    DECLARE @StdDefault INT = core.fn_StandardDayMinutes();

    DECLARE @Sa INT, @Grace INT = 0, @Break INT = 0, @IsRest BIT = 0,
            @ShiftStart TIME, @ShiftEnd TIME, @Crosses BIT = 0;

    SELECT @Sa = sa.ShiftAssignmentId, @IsRest = sa.IsRestDay,
           @ShiftStart = s.StartTime, @ShiftEnd = s.EndTime,
           @Grace = ISNULL(s.GraceMinutes, 0), @Break = ISNULL(s.BreakMinutes, 0),
           @Crosses = ISNULL(s.CrossesMidnight, 0)
    FROM attendance.SHIFT_ASSIGNMENT sa
    LEFT JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
    WHERE sa.EmployeeId = @EmployeeId AND sa.WorkDate = @WorkDate;

    DECLARE @Std INT = CASE
        WHEN @ShiftStart IS NULL THEN @StdDefault
        ELSE (DATEDIFF(MINUTE, @ShiftStart, @ShiftEnd)
              + CASE WHEN @Crosses = 1 THEN 1440 ELSE 0 END) - @Break END;

    DECLARE @ShiftStartUtc DATETIME2 =
        CASE WHEN @ShiftStart IS NULL THEN NULL
             ELSE DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @ShiftStart), CAST(@WorkDate AS DATETIME2)) END;

    DECLARE @Gross INT = CASE
        WHEN @FirstInUtc IS NULL OR @LastOutUtc IS NULL THEN 0
        ELSE DATEDIFF(MINUTE, @FirstInUtc, @LastOutUtc) END;

    DECLARE @Worked INT = CASE
        WHEN @Gross - @Break - ISNULL(@ExitMinutes, 0) > 0
        THEN @Gross - @Break - ISNULL(@ExitMinutes, 0) ELSE 0 END;

    DECLARE @Late INT = CASE
        WHEN @FirstInUtc IS NULL OR @ShiftStartUtc IS NULL THEN 0
        WHEN DATEDIFF(MINUTE, DATEADD(MINUTE, @Grace, @ShiftStartUtc), @FirstInUtc) > 0
             THEN DATEDIFF(MINUTE, DATEADD(MINUTE, @Grace, @ShiftStartUtc), @FirstInUtc)
        ELSE 0 END;

    DECLARE @Frac DECIMAL(5,2) = CASE
        WHEN @Std = 0 THEN 0
        WHEN CAST(@Worked AS DECIMAL(12,4)) / @Std > 1 THEN 1.00
        ELSE CAST(ROUND(CAST(@Worked AS DECIMAL(12,4)) / @Std, 2) AS DECIMAL(5,2)) END;

    DECLARE @FinalStatus VARCHAR(20) = COALESCE(@Status,
        CASE WHEN @IsRest = 1 THEN 'RestDay'
             WHEN @FirstInUtc IS NOT NULL THEN 'Present' ELSE 'Absent' END);

    DECLARE @FinalBranch INT = COALESCE(@BranchId,
        (SELECT BranchId FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId));

    DECLARE @ExitLeave INT = CASE WHEN @LeaveBasis = 'Approved'
                                  THEN ISNULL(@ExitApprovedMins, 0) ELSE ISNULL(@ExitMinutes, 0) END;

    BEGIN TRAN;

    IF EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD
               WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate)
        UPDATE attendance.ATTENDANCE_RECORD
        SET FirstInUtc = @FirstInUtc, LastOutUtc = @LastOutUtc,
            PunchPairs = CASE WHEN @FirstInUtc IS NOT NULL AND @LastOutUtc IS NOT NULL THEN 1 ELSE 0 END,
            GrossMinutes = @Gross, GapMinutes = ISNULL(@ExitMinutes, 0), BreakApplied = @Break,
            WorkedMinutes = @Worked, StandardMinutes = @Std, DayFraction = @Frac,
            IsFullDay = CASE WHEN @Frac >= @FullDayThreshold THEN 1 ELSE 0 END,
            ShortfallMinutes = CASE WHEN @Std - @Worked > 0 THEN @Std - @Worked ELSE 0 END,
            LateMinutes = @Late,
            OvertimeMinutes = CASE WHEN @Worked - @Std > 0 THEN @Worked - @Std ELSE 0 END,
            ExitActualMinutes = ISNULL(@ExitMinutes, 0),
            ExitApprovedMinutes = ISNULL(@ExitApprovedMins, 0),
            ExitVarianceMinutes = ISNULL(@ExitMinutes, 0) - ISNULL(@ExitApprovedMins, 0),
            ExitLeaveMinutes = @ExitLeave,
            [Status] = @FinalStatus, [Source] = 'Manual', IsManual = 1, HasAnomaly = 0,
            ShiftAssignmentId = @Sa, BranchId = @FinalBranch, DeviceId = NULL,
            HrNote = COALESCE(@HrNote, HrNote), ProcessedUtc = SYSUTCDATETIME()
        WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate;
    ELSE
        INSERT INTO attendance.ATTENDANCE_RECORD
            (EmployeeId, ShiftAssignmentId, WorkDate, FirstInUtc, LastOutUtc, PunchPairs,
             GrossMinutes, GapMinutes, BreakApplied, WorkedMinutes, StandardMinutes,
             DayFraction, IsFullDay, ShortfallMinutes, LateMinutes, OvertimeMinutes,
             ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes, ExitLeaveMinutes,
             [Status], [Source], DeviceId, BranchId, HasAnomaly, IsManual, HrNote, ProcessedUtc)
        VALUES (@EmployeeId, @Sa, @WorkDate, @FirstInUtc, @LastOutUtc,
                CASE WHEN @FirstInUtc IS NOT NULL AND @LastOutUtc IS NOT NULL THEN 1 ELSE 0 END,
                @Gross, ISNULL(@ExitMinutes, 0), @Break, @Worked, @Std, @Frac,
                CASE WHEN @Frac >= @FullDayThreshold THEN 1 ELSE 0 END,
                CASE WHEN @Std - @Worked > 0 THEN @Std - @Worked ELSE 0 END,
                @Late,
                CASE WHEN @Worked - @Std > 0 THEN @Worked - @Std ELSE 0 END,
                ISNULL(@ExitMinutes, 0), ISNULL(@ExitApprovedMins, 0),
                ISNULL(@ExitMinutes, 0) - ISNULL(@ExitApprovedMins, 0), @ExitLeave,
                @FinalStatus, 'Manual', NULL, @FinalBranch, 0, 1, @HrNote, SYSUTCDATETIME());

    COMMIT TRAN;

    SELECT AttendanceId, WorkedMinutes, StandardMinutes, DayFraction, IsFullDay,
           LateMinutes, OvertimeMinutes, ExitActualMinutes, ExitApprovedMinutes,
           ExitVarianceMinutes, ExitLeaveMinutes, [Status]
    FROM attendance.ATTENDANCE_RECORD
    WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate;
END;
GO

/* Attach an APPROVED exit permission to a day.
   Called by the WORKFLOW stage on approval, AND available to HR manually for the case
   where the employee had an approved exit but NEVER PUNCHED for it (so attendance
   sees no gap): pass @AlsoSetActual = 1 and the approved minutes become the actual,
   with worked time reduced accordingly.
   It NEVER overwrites observed ExitActualMinutes when punches exist - approved and
   actual stay independent. */
CREATE PROCEDURE attendance.usp_Attendance_SetExitApproval
    @AttendanceId        BIGINT,
    @ExitApprovedMinutes INT,
    @ExitPermissionId    INT = NULL,
    @AlsoSetActual       BIT = 0,
    @HrNote              NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @LeaveBasis VARCHAR(20) =
        ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'ExitLeaveBasis'), 'Actual');
    DECLARE @FullDayThreshold DECIMAL(5,2) =
        ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'FullDayThreshold') AS DECIMAL(5,2)), 1.00);

    BEGIN TRAN;

    UPDATE attendance.ATTENDANCE_RECORD
    SET ExitApprovedMinutes = @ExitApprovedMinutes,
        ExitPermissionId    = COALESCE(@ExitPermissionId, ExitPermissionId),
        ExitActualMinutes   = CASE WHEN @AlsoSetActual = 1 AND ExitActualMinutes = 0
                                   THEN @ExitApprovedMinutes ELSE ExitActualMinutes END,
        WorkedMinutes       = CASE WHEN @AlsoSetActual = 1 AND ExitActualMinutes = 0
                                   THEN CASE WHEN WorkedMinutes - @ExitApprovedMinutes > 0
                                             THEN WorkedMinutes - @ExitApprovedMinutes ELSE 0 END
                                   ELSE WorkedMinutes END,
        HrNote              = COALESCE(@HrNote, HrNote),
        ProcessedUtc        = SYSUTCDATETIME()
    WHERE AttendanceId = @AttendanceId;

    UPDATE attendance.ATTENDANCE_RECORD
    SET ExitVarianceMinutes = ExitActualMinutes - ExitApprovedMinutes,
        ExitLeaveMinutes    = CASE WHEN @LeaveBasis = 'Approved'
                                   THEN ExitApprovedMinutes ELSE ExitActualMinutes END,
        DayFraction         = CASE WHEN StandardMinutes = 0 THEN 0
                                   WHEN CAST(WorkedMinutes AS DECIMAL(12,4)) / StandardMinutes > 1 THEN 1.00
                                   ELSE CAST(ROUND(CAST(WorkedMinutes AS DECIMAL(12,4)) / StandardMinutes, 2) AS DECIMAL(5,2)) END,
        ShortfallMinutes    = CASE WHEN StandardMinutes - WorkedMinutes > 0
                                   THEN StandardMinutes - WorkedMinutes ELSE 0 END,
        OvertimeMinutes     = CASE WHEN WorkedMinutes - StandardMinutes > 0
                                   THEN WorkedMinutes - StandardMinutes ELSE 0 END
    WHERE AttendanceId = @AttendanceId;

    UPDATE attendance.ATTENDANCE_RECORD
    SET IsFullDay = CASE WHEN DayFraction >= @FullDayThreshold THEN 1 ELSE 0 END
    WHERE AttendanceId = @AttendanceId;

    COMMIT TRAN;

    SELECT AttendanceId, ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes,
           ExitLeaveMinutes, WorkedMinutes, DayFraction, IsFullDay, OvertimeMinutes
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
END;
GO

/* HR DISPOSITIONS THE VARIANCE. Approved 2h, actually took 2.5h (+30) or 1.5h (-30).
   HR decides what the difference means:
     'UnpaidAbsence' -> payroll deducts it
     'Overtime'      -> offset against detected overtime
     'Ignore'        -> no consequence
   @ExitLeaveMinutesOverride lets HR set EXACTLY how many minutes come off the leave
   balance, overriding the configured basis. This is the "HR keeps full power" path. */
CREATE PROCEDURE attendance.usp_Attendance_SetExitDisposition
    @AttendanceId             BIGINT,
    @Disposition              VARCHAR(20),
    @ExitLeaveMinutesOverride INT = NULL,
    @HrNote                   NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @Disposition NOT IN ('UnpaidAbsence', 'Overtime', 'Ignore')
    BEGIN RAISERROR('Disposition must be UnpaidAbsence, Overtime, or Ignore.', 16, 1); RETURN; END

    UPDATE attendance.ATTENDANCE_RECORD
    SET ExitVarianceDisposition = @Disposition,
        ExitLeaveMinutes        = COALESCE(@ExitLeaveMinutesOverride, ExitLeaveMinutes),
        HrNote                  = COALESCE(@HrNote, HrNote),
        IsManual                = 1,
        ProcessedUtc            = SYSUTCDATETIME()
    WHERE AttendanceId = @AttendanceId;

    SELECT AttendanceId, ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes,
           ExitLeaveMinutes, ExitVarianceDisposition
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
END;
GO

/* HR FULL DAY OVERRIDE - add or deduct working time for any reason, with a mandatory
   note. Pass EITHER @WorkedMinutes OR @DayFraction (fraction wins). Marks IsManual. */
CREATE PROCEDURE attendance.usp_Attendance_HrAdjustDay
    @AttendanceId  BIGINT,
    @WorkedMinutes INT = NULL,
    @DayFraction   DECIMAL(5,2) = NULL,
    @Status        VARCHAR(20) = NULL,
    @HrNote        NVARCHAR(300),
    @ModifiedBy    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @WorkedMinutes IS NULL AND @DayFraction IS NULL
    BEGIN RAISERROR('Provide WorkedMinutes or DayFraction.', 16, 1); RETURN; END

    DECLARE @FullDayThreshold DECIMAL(5,2) =
        ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'FullDayThreshold') AS DECIMAL(5,2)), 1.00);

    DECLARE @Std INT = (SELECT StandardMinutes FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId);
    IF @Std IS NULL OR @Std = 0 SET @Std = core.fn_StandardDayMinutes();

    DECLARE @NewWorked INT =
        CASE WHEN @DayFraction IS NOT NULL THEN CAST(ROUND(@DayFraction * @Std, 0) AS INT)
             ELSE @WorkedMinutes END;

    BEGIN TRAN;

    UPDATE attendance.ATTENDANCE_RECORD
    SET WorkedMinutes    = @NewWorked,
        StandardMinutes  = @Std,
        DayFraction      = CASE WHEN @Std = 0 THEN 0
                                WHEN CAST(@NewWorked AS DECIMAL(12,4)) / @Std > 1 THEN 1.00
                                ELSE CAST(ROUND(CAST(@NewWorked AS DECIMAL(12,4)) / @Std, 2) AS DECIMAL(5,2)) END,
        ShortfallMinutes = CASE WHEN @Std - @NewWorked > 0 THEN @Std - @NewWorked ELSE 0 END,
        OvertimeMinutes  = CASE WHEN @NewWorked - @Std > 0 THEN @NewWorked - @Std ELSE 0 END,
        [Status]         = COALESCE(@Status, [Status]),
        HrNote           = @HrNote,
        IsManual         = 1,
        HasAnomaly       = 0,
        ProcessedUtc     = SYSUTCDATETIME()
    WHERE AttendanceId = @AttendanceId;

    UPDATE attendance.ATTENDANCE_RECORD
    SET IsFullDay = CASE WHEN DayFraction >= @FullDayThreshold THEN 1 ELSE 0 END
    WHERE AttendanceId = @AttendanceId;

    COMMIT TRAN;

    SELECT AttendanceId, WorkedMinutes, StandardMinutes, DayFraction, IsFullDay,
           ShortfallMinutes, OvertimeMinutes, [Status], HrNote
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
END;
GO

/* HR's action queue: days where actual != approved and HR has not decided yet.
   Payroll should not run with these outstanding. */
CREATE PROCEDURE attendance.usp_Attendance_GetExitVariances
    @FromDate DATE, @ToDate DATE, @OnlyUndecided BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.AttendanceId, a.EmployeeId, e.FullName, a.WorkDate,
           a.ExitActualMinutes, a.ExitApprovedMinutes, a.ExitVarianceMinutes,
           a.ExitLeaveMinutes, a.ExitVarianceDisposition,
           a.OvertimeMinutes,                                          -- what HR could offset against
           core.fn_MinutesToLeaveDays(a.ExitLeaveMinutes) AS LeaveDaysToDeduct,
           a.HrNote
    FROM attendance.ATTENDANCE_RECORD a
    JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
    WHERE a.WorkDate BETWEEN @FromDate AND @ToDate
      AND a.ExitVarianceMinutes <> 0
      AND (@OnlyUndecided = 0 OR a.ExitVarianceDisposition IS NULL)
    ORDER BY a.WorkDate, e.FullName;
END;
GO

/* ############################################################################
   ======================  SECTION 7 - READS  ================================
   ############################################################################ */

CREATE PROCEDURE attendance.usp_Attendance_GetByDateRange
    @FromDate DATE, @ToDate DATE, @EmployeeId INT = NULL, @BranchId INT = NULL
AS BEGIN SET NOCOUNT ON;
    SELECT a.AttendanceId, a.EmployeeId, e.FullName, a.WorkDate,
           a.FirstInUtc, a.LastOutUtc, a.PunchPairs,
           a.WorkedMinutes, a.StandardMinutes, a.DayFraction, a.IsFullDay,
           a.LateMinutes, a.OvertimeMinutes, a.ShortfallMinutes,
           a.ExitActualMinutes, a.ExitApprovedMinutes, a.ExitVarianceMinutes,
           a.ExitLeaveMinutes, a.ExitVarianceDisposition,
           a.[Status], a.[Source], a.IsManual, a.HasAnomaly,
           a.BranchId, b.Name AS BranchName, a.HrNote
    FROM attendance.ATTENDANCE_RECORD a
    JOIN hr.EMPLOYEE e    ON e.EmployeeId = a.EmployeeId
    LEFT JOIN hr.BRANCH b ON b.BranchId = a.BranchId
    WHERE a.WorkDate BETWEEN @FromDate AND @ToDate
      AND (@EmployeeId IS NULL OR a.EmployeeId = @EmployeeId)
      AND (@BranchId  IS NULL OR a.BranchId  = @BranchId)
    ORDER BY a.WorkDate, e.FullName; END;
GO

/* One day WITH its paired intervals (the audit trail behind WorkedMinutes).
   Two result sets: the record, then its intervals. */
CREATE PROCEDURE attendance.usp_Attendance_GetById @AttendanceId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.*, e.FullName, b.Name AS BranchName,
           core.fn_MinutesToLeaveDays(a.ExitLeaveMinutes) AS LeaveDaysToDeduct
    FROM attendance.ATTENDANCE_RECORD a
    JOIN hr.EMPLOYEE e    ON e.EmployeeId = a.EmployeeId
    LEFT JOIN hr.BRANCH b ON b.BranchId = a.BranchId
    WHERE a.AttendanceId = @AttendanceId;

    SELECT IntervalId, SeqNo, InTimeUtc, OutTimeUtc, Minutes, GapAfterMins
    FROM attendance.ATTENDANCE_INTERVAL
    WHERE AttendanceId = @AttendanceId
    ORDER BY SeqNo;
END;
GO

CREATE PROCEDURE attendance.usp_Attendance_GetAnomalies
    @FromDate DATE, @ToDate DATE
AS BEGIN SET NOCOUNT ON;
    SELECT a.AttendanceId, a.EmployeeId, e.FullName, a.WorkDate,
           a.FirstInUtc, a.LastOutUtc, a.PunchPairs, a.[Status], a.[Source]
    FROM attendance.ATTENDANCE_RECORD a
    JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
    WHERE a.HasAnomaly = 1 AND a.WorkDate BETWEEN @FromDate AND @ToDate
    ORDER BY a.WorkDate, e.FullName; END;
GO

/* Punches whose PIN has no employee mapping. They are NOT lost - they sit here until
   HR maps the PIN (usp_EmployeeDevice_Map then retro-claims them). */
CREATE PROCEDURE attendance.usp_RawLog_GetUnresolved
    @FromDate DATE = NULL, @ToDate DATE = NULL
AS BEGIN SET NOCOUNT ON;
    SELECT r.RawLogId, r.DeviceId, d.SerialNumber, r.EnrollPin,
           r.PunchTimeUtc, r.PunchType, r.[Source], r.ImportBatchId
    FROM attendance.RAW_DEVICE_LOG r
    JOIN attendance.DEVICE d ON d.DeviceId = r.DeviceId
    WHERE r.EmployeeId IS NULL
      AND (@FromDate IS NULL OR CAST(r.PunchTimeUtc AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR CAST(r.PunchTimeUtc AS DATE) <= @ToDate)
    ORDER BY r.PunchTimeUtc DESC; END;
GO

CREATE PROCEDURE attendance.usp_RawLog_GetByEmployeeDay
    @EmployeeId INT, @WorkDate DATE
AS BEGIN SET NOCOUNT ON;
    SELECT r.RawLogId, r.DeviceId, d.SerialNumber, r.EnrollPin, r.PunchTimeUtc,
           r.PunchType, r.[Source], r.DedupHash, r.IsProcessed, r.CreatedUtc
    FROM attendance.RAW_DEVICE_LOG r
    JOIN attendance.DEVICE d ON d.DeviceId = r.DeviceId
    WHERE r.EmployeeId = @EmployeeId AND CAST(r.PunchTimeUtc AS DATE) = @WorkDate
    ORDER BY r.PunchTimeUtc; END;
GO

/* ############################################################################
   ==============  SECTION 8 - CORRECTIONS (HR ONLY, model ii)  ==============
   A correction is a LOGGED request holding OLD + NEW values. Approving applies the
   NEW values and RECOMPUTES the day. Raw logs are never touched.
   ############################################################################ */

CREATE PROCEDURE attendance.usp_Correction_Create
    @AttendanceId   BIGINT,
    @RequestedBy    INT,
    @NewFirstInUtc  DATETIME2 = NULL,
    @NewLastOutUtc  DATETIME2 = NULL,
    @NewExitMinutes INT = NULL,
    @NewStatus      VARCHAR(20) = NULL,
    @Reason         NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @oi DATETIME2, @oo DATETIME2, @oe INT, @os VARCHAR(20);
    SELECT @oi = FirstInUtc, @oo = LastOutUtc, @oe = ExitActualMinutes, @os = [Status]
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;

    IF @os IS NULL
    BEGIN RAISERROR('Attendance record not found.', 16, 1); RETURN; END

    INSERT INTO attendance.ATTENDANCE_CORRECTION
        (AttendanceId, RequestedBy, OldFirstInUtc, OldLastOutUtc, OldExitMinutes, OldStatus,
         NewFirstInUtc, NewLastOutUtc, NewExitMinutes, NewStatus, Reason, ApprovalStatus)
    VALUES (@AttendanceId, @RequestedBy, @oi, @oo, @oe, @os,
            @NewFirstInUtc, @NewLastOutUtc, @NewExitMinutes, @NewStatus, @Reason, 'Pending');

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS CorrectionId;
END;
GO

/* Approve: apply the NEW values, RECOMPUTE the day against the rostered shift (same
   rules as everywhere else), clear the anomaly, and protect the row (IsManual = 1). */
CREATE PROCEDURE attendance.usp_Correction_Approve
    @CorrectionId INT, @ApprovedBy INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AttendanceId BIGINT, @ni DATETIME2, @no DATETIME2, @ne INT, @ns VARCHAR(20);
    SELECT @AttendanceId = AttendanceId, @ni = NewFirstInUtc, @no = NewLastOutUtc,
           @ne = NewExitMinutes, @ns = NewStatus
    FROM attendance.ATTENDANCE_CORRECTION
    WHERE CorrectionId = @CorrectionId AND ApprovalStatus = 'Pending';

    IF @AttendanceId IS NULL
    BEGIN RAISERROR('No pending correction with that id.', 16, 1); RETURN; END

    DECLARE @EmployeeId INT, @WorkDate DATE;
    SELECT @EmployeeId = EmployeeId, @WorkDate = WorkDate
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;

    /* effective values after the correction */
    DECLARE @InT DATETIME2, @OutT DATETIME2, @Exit INT, @Approved INT;
    SELECT @InT = COALESCE(@ni, FirstInUtc),
           @OutT = COALESCE(@no, LastOutUtc),
           @Exit = COALESCE(@ne, ExitActualMinutes),
           @Approved = ExitApprovedMinutes
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;

    DECLARE @LeaveBasis VARCHAR(20) =
        ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'ExitLeaveBasis'), 'Actual');
    DECLARE @FullDayThreshold DECIMAL(5,2) =
        ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'FullDayThreshold') AS DECIMAL(5,2)), 1.00);
    DECLARE @StdDefault INT = core.fn_StandardDayMinutes();

    DECLARE @Grace INT = 0, @Break INT = 0, @ShiftStart TIME, @ShiftEnd TIME, @Crosses BIT = 0;
    SELECT @ShiftStart = s.StartTime, @ShiftEnd = s.EndTime,
           @Grace = ISNULL(s.GraceMinutes, 0), @Break = ISNULL(s.BreakMinutes, 0),
           @Crosses = ISNULL(s.CrossesMidnight, 0)
    FROM attendance.SHIFT_ASSIGNMENT sa
    LEFT JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
    WHERE sa.EmployeeId = @EmployeeId AND sa.WorkDate = @WorkDate;

    DECLARE @Std INT = CASE
        WHEN @ShiftStart IS NULL THEN @StdDefault
        ELSE (DATEDIFF(MINUTE, @ShiftStart, @ShiftEnd)
              + CASE WHEN @Crosses = 1 THEN 1440 ELSE 0 END) - @Break END;

    DECLARE @ShiftStartUtc DATETIME2 =
        CASE WHEN @ShiftStart IS NULL THEN NULL
             ELSE DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @ShiftStart), CAST(@WorkDate AS DATETIME2)) END;

    DECLARE @Gross INT = CASE WHEN @InT IS NULL OR @OutT IS NULL THEN 0
                              ELSE DATEDIFF(MINUTE, @InT, @OutT) END;
    DECLARE @Worked INT = CASE WHEN @Gross - @Break - ISNULL(@Exit,0) > 0
                               THEN @Gross - @Break - ISNULL(@Exit,0) ELSE 0 END;
    DECLARE @Late INT = CASE
        WHEN @InT IS NULL OR @ShiftStartUtc IS NULL THEN 0
        WHEN DATEDIFF(MINUTE, DATEADD(MINUTE, @Grace, @ShiftStartUtc), @InT) > 0
             THEN DATEDIFF(MINUTE, DATEADD(MINUTE, @Grace, @ShiftStartUtc), @InT)
        ELSE 0 END;
    DECLARE @Frac DECIMAL(5,2) = CASE
        WHEN @Std = 0 THEN 0
        WHEN CAST(@Worked AS DECIMAL(12,4)) / @Std > 1 THEN 1.00
        ELSE CAST(ROUND(CAST(@Worked AS DECIMAL(12,4)) / @Std, 2) AS DECIMAL(5,2)) END;

    BEGIN TRAN;

    UPDATE attendance.ATTENDANCE_RECORD
    SET FirstInUtc          = @InT,
        LastOutUtc          = @OutT,
        GrossMinutes        = @Gross,
        GapMinutes          = ISNULL(@Exit, 0),
        BreakApplied        = @Break,
        WorkedMinutes       = @Worked,
        StandardMinutes     = @Std,
        DayFraction         = @Frac,
        IsFullDay           = CASE WHEN @Frac >= @FullDayThreshold THEN 1 ELSE 0 END,
        ShortfallMinutes    = CASE WHEN @Std - @Worked > 0 THEN @Std - @Worked ELSE 0 END,
        LateMinutes         = @Late,
        OvertimeMinutes     = CASE WHEN @Worked - @Std > 0 THEN @Worked - @Std ELSE 0 END,
        ExitActualMinutes   = ISNULL(@Exit, 0),
        ExitVarianceMinutes = ISNULL(@Exit, 0) - ISNULL(@Approved, 0),
        ExitLeaveMinutes    = CASE WHEN @LeaveBasis = 'Approved'
                                   THEN ISNULL(@Approved, 0) ELSE ISNULL(@Exit, 0) END,
        [Status]            = COALESCE(@ns, [Status]),
        HasAnomaly          = 0,
        IsManual            = 1,
        ProcessedUtc        = SYSUTCDATETIME()
    WHERE AttendanceId = @AttendanceId;

    UPDATE attendance.ATTENDANCE_CORRECTION
    SET ApprovalStatus = 'Approved', ApprovedBy = @ApprovedBy, ActedUtc = SYSUTCDATETIME()
    WHERE CorrectionId = @CorrectionId;

    COMMIT TRAN;

    SELECT @AttendanceId AS AttendanceId, @Worked AS WorkedMinutes,
           @Frac AS DayFraction, @Late AS LateMinutes;
END;
GO

CREATE PROCEDURE attendance.usp_Correction_Reject
    @CorrectionId INT, @ApprovedBy INT
AS BEGIN SET NOCOUNT ON;
    UPDATE attendance.ATTENDANCE_CORRECTION
    SET ApprovalStatus = 'Rejected', ApprovedBy = @ApprovedBy, ActedUtc = SYSUTCDATETIME()
    WHERE CorrectionId = @CorrectionId AND ApprovalStatus = 'Pending'; END;
GO

CREATE PROCEDURE attendance.usp_Correction_GetByRecord @AttendanceId BIGINT
AS BEGIN SET NOCOUNT ON;
    SELECT c.CorrectionId, c.AttendanceId,
           c.RequestedBy, ru.Username AS RequestedByUser,
           c.ApprovedBy,  au.Username AS ApprovedByUser,
           c.OldFirstInUtc, c.OldLastOutUtc, c.OldExitMinutes, c.OldStatus,
           c.NewFirstInUtc, c.NewLastOutUtc, c.NewExitMinutes, c.NewStatus,
           c.Reason, c.ApprovalStatus, c.RequestedUtc, c.ActedUtc
    FROM attendance.ATTENDANCE_CORRECTION c
    LEFT JOIN security.[USER] ru ON ru.UserId = c.RequestedBy
    LEFT JOIN security.[USER] au ON au.UserId = c.ApprovedBy
    WHERE c.AttendanceId = @AttendanceId
    ORDER BY c.RequestedUtc DESC; END;
GO

CREATE PROCEDURE attendance.usp_Correction_GetPending
AS BEGIN SET NOCOUNT ON;
    SELECT c.CorrectionId, c.AttendanceId, a.WorkDate, a.EmployeeId, e.FullName,
           c.OldFirstInUtc, c.OldLastOutUtc, c.OldExitMinutes,
           c.NewFirstInUtc, c.NewLastOutUtc, c.NewExitMinutes,
           c.Reason, c.RequestedBy, ru.Username AS RequestedByUser, c.RequestedUtc
    FROM attendance.ATTENDANCE_CORRECTION c
    JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = c.AttendanceId
    JOIN hr.EMPLOYEE e                  ON e.EmployeeId = a.EmployeeId
    LEFT JOIN security.[USER] ru        ON ru.UserId = c.RequestedBy
    WHERE c.ApprovalStatus = 'Pending'
    ORDER BY c.RequestedUtc; END;
GO

/* ############################################################################
   ================  SECTION 9 - PAYROLL INTERFACE  =========================
   Payroll reads ATTENDANCE_RECORD only - never the raw log. This is the CONTRACT.
   ############################################################################ */

/* PAYROLL READINESS - run BEFORE creating/locking a payroll run.
   Attendance is INCOMPLETE (so payroll would be WRONG) if, for the period:
     - raw punches are still unprocessed      -> days missing entirely
     - punches have unresolved PINs           -> that person's days are missing
     - records are flagged HasAnomaly         -> missing punch-outs, wrong hours
     - corrections are still pending          -> figures about to change
     - rostered employee-days have NO record  -> nothing to pay/deduct against
     - exit variances are UNDECIDED           -> HR has not said whether the extra
                                                 time is unpaid, OT, or ignored
   The API should BLOCK the payroll run when IsReady = 0. */
CREATE PROCEDURE attendance.usp_Attendance_PayrollReadiness
    @PeriodYearMonth CHAR(7)                      -- e.g. '2026-06'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATE = CAST(@PeriodYearMonth + '-01' AS DATE);
    DECLARE @to   DATE = EOMONTH(@from);

    DECLARE @Unprocessed INT = (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG
        WHERE IsProcessed = 0 AND CAST(PunchTimeUtc AS DATE) BETWEEN @from AND @to);

    DECLARE @Unresolved INT = (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG
        WHERE EmployeeId IS NULL AND CAST(PunchTimeUtc AS DATE) BETWEEN @from AND @to);

    DECLARE @Anomalies INT = (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD
        WHERE HasAnomaly = 1 AND WorkDate BETWEEN @from AND @to);

    DECLARE @PendingCorr INT = (SELECT COUNT(*)
        FROM attendance.ATTENDANCE_CORRECTION c
        JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = c.AttendanceId
        WHERE c.ApprovalStatus = 'Pending' AND a.WorkDate BETWEEN @from AND @to);

    DECLARE @MissingDays INT = (SELECT COUNT(*)
        FROM attendance.SHIFT_ASSIGNMENT sa
        JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId AND e.IsDeleted = 0
        WHERE sa.WorkDate BETWEEN @from AND @to
          AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a
                          WHERE a.EmployeeId = sa.EmployeeId AND a.WorkDate = sa.WorkDate));

    DECLARE @OpenVariances INT = (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD
        WHERE WorkDate BETWEEN @from AND @to
          AND ExitVarianceMinutes <> 0
          AND ExitVarianceDisposition IS NULL);

    SELECT
        @PeriodYearMonth AS PeriodYearMonth,
        @from            AS PeriodStart,
        @to              AS PeriodEnd,
        @Unprocessed     AS UnprocessedPunches,
        @Unresolved      AS UnresolvedPinPunches,
        @Anomalies       AS OpenAnomalies,
        @PendingCorr     AS PendingCorrections,
        @MissingDays     AS RosteredDaysWithNoRecord,
        @OpenVariances   AS UndecidedExitVariances,
        CASE WHEN @Unprocessed = 0 AND @Unresolved = 0 AND @Anomalies = 0
                  AND @PendingCorr = 0 AND @MissingDays = 0 AND @OpenVariances = 0
             THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsReady;
END;
GO

/* MONTHLY SUMMARY for ONE employee - the numbers payroll turns into pay lines.

   HOW PAYROLL USES THESE (the rules live in payroll/workflow, not here):
     TotalLateMinutes     -> Late Deduction line
     DaysWorked           -> FRACTIONAL days actually worked. Someone who left 2h
                             early counts 0.75, not 1.
     UnpaidAbsenceDays    -> absences NOT covered by approved leave -> deduction
     TotalOvertimeMinutes -> DETECTED overtime. NOT paid automatically: pay only what
                             an APPROVED overtime request authorises. HR may also have
                             used it to offset an exit variance.
     ExitLeaveDays        -> leave days to draw from the balance for short exits
                             (default: from the ACTUAL minutes; HR may override)
     ExitUnpaidMinutes    -> exit variance HR marked 'UnpaidAbsence' -> deduction
     ExitOffsetMinutes    -> exit variance HR marked 'Overtime'      -> offset, no pay */
CREATE PROCEDURE attendance.usp_Attendance_MonthlySummary
    @EmployeeId INT, @PeriodYearMonth CHAR(7)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATE = CAST(@PeriodYearMonth + '-01' AS DATE);
    DECLARE @to   DATE = EOMONTH(@from);

    DECLARE @ApprovedLeaveDays DECIMAL(6,2) = ISNULL((
        SELECT SUM(-Days) FROM hr.LEAVE_LEDGER
        WHERE EmployeeId = @EmployeeId AND PeriodYearMonth = @PeriodYearMonth
          AND MovementType = 'Usage'), 0);

    SELECT
        @EmployeeId      AS EmployeeId,
        @PeriodYearMonth AS PeriodYearMonth,

        ISNULL(SUM(a.LateMinutes), 0)      AS TotalLateMinutes,
        ISNULL(SUM(a.OvertimeMinutes), 0)  AS TotalOvertimeMinutes,      -- detected only
        ISNULL(SUM(a.WorkedMinutes), 0)    AS TotalWorkedMinutes,
        ISNULL(SUM(a.ShortfallMinutes), 0) AS TotalShortfallMinutes,

        ISNULL(SUM(a.DayFraction), 0)      AS DaysWorked,                -- fractional
        ISNULL(SUM(CASE WHEN a.IsFullDay = 1 THEN 1 ELSE 0 END), 0)      AS FullDaysWorked,
        ISNULL(SUM(CASE WHEN a.[Status] = 'Present' AND a.IsFullDay = 0 THEN 1 ELSE 0 END), 0) AS PartialDays,

        ISNULL(SUM(CASE WHEN a.[Status] = 'Present' THEN 1 ELSE 0 END), 0) AS PresentDays,
        ISNULL(SUM(CASE WHEN a.[Status] = 'Absent'  THEN 1 ELSE 0 END), 0) AS AbsentDays,
        ISNULL(SUM(CASE WHEN a.[Status] = 'RestDay' THEN 1 ELSE 0 END), 0) AS RestDays,
        ISNULL(SUM(CASE WHEN a.[Status] = 'Leave'   THEN 1 ELSE 0 END), 0) AS LeaveDays,

        ISNULL(SUM(a.ExitActualMinutes), 0)   AS ExitActualMinutes,
        ISNULL(SUM(a.ExitApprovedMinutes), 0) AS ExitApprovedMinutes,
        ISNULL(SUM(a.ExitLeaveMinutes), 0)    AS ExitLeaveMinutes,
        core.fn_MinutesToLeaveDays(ISNULL(SUM(a.ExitLeaveMinutes), 0)) AS ExitLeaveDays,
        ISNULL(SUM(CASE WHEN a.ExitVarianceDisposition = 'UnpaidAbsence'
                        THEN a.ExitVarianceMinutes ELSE 0 END), 0) AS ExitUnpaidMinutes,
        ISNULL(SUM(CASE WHEN a.ExitVarianceDisposition = 'Overtime'
                        THEN a.ExitVarianceMinutes ELSE 0 END), 0) AS ExitOffsetMinutes,

        @ApprovedLeaveDays AS ApprovedLeaveDays,
        CASE WHEN ISNULL(SUM(CASE WHEN a.[Status] = 'Absent' THEN 1 ELSE 0 END), 0) - @ApprovedLeaveDays > 0
             THEN ISNULL(SUM(CASE WHEN a.[Status] = 'Absent' THEN 1 ELSE 0 END), 0) - @ApprovedLeaveDays
             ELSE 0 END AS UnpaidAbsenceDays
    FROM attendance.ATTENDANCE_RECORD a
    WHERE a.EmployeeId = @EmployeeId AND a.WorkDate BETWEEN @from AND @to;
END;
GO

/* MONTHLY SUMMARY for ALL employees - what a payroll RUN iterates over. */
CREATE PROCEDURE attendance.usp_Attendance_MonthlySummary_All
    @PeriodYearMonth CHAR(7)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATE = CAST(@PeriodYearMonth + '-01' AS DATE);
    DECLARE @to   DATE = EOMONTH(@from);

    ;WITH leave_used AS (
        SELECT EmployeeId, SUM(-Days) AS ApprovedLeaveDays
        FROM hr.LEAVE_LEDGER
        WHERE PeriodYearMonth = @PeriodYearMonth AND MovementType = 'Usage'
        GROUP BY EmployeeId
    ),
    att AS (
        SELECT a.EmployeeId,
               SUM(a.LateMinutes)      AS TotalLateMinutes,
               SUM(a.OvertimeMinutes)  AS TotalOvertimeMinutes,
               SUM(a.WorkedMinutes)    AS TotalWorkedMinutes,
               SUM(a.ShortfallMinutes) AS TotalShortfallMinutes,
               SUM(a.DayFraction)      AS DaysWorked,
               SUM(CASE WHEN a.IsFullDay = 1 THEN 1 ELSE 0 END)        AS FullDaysWorked,
               SUM(CASE WHEN a.[Status] = 'Present' THEN 1 ELSE 0 END) AS PresentDays,
               SUM(CASE WHEN a.[Status] = 'Absent'  THEN 1 ELSE 0 END) AS AbsentDays,
               SUM(CASE WHEN a.[Status] = 'RestDay' THEN 1 ELSE 0 END) AS RestDays,
               SUM(a.ExitLeaveMinutes) AS ExitLeaveMinutes,
               SUM(CASE WHEN a.ExitVarianceDisposition = 'UnpaidAbsence'
                        THEN a.ExitVarianceMinutes ELSE 0 END) AS ExitUnpaidMinutes,
               SUM(CASE WHEN a.ExitVarianceDisposition = 'Overtime'
                        THEN a.ExitVarianceMinutes ELSE 0 END) AS ExitOffsetMinutes
        FROM attendance.ATTENDANCE_RECORD a
        WHERE a.WorkDate BETWEEN @from AND @to
        GROUP BY a.EmployeeId
    )
    SELECT
        e.EmployeeId, e.FullName, @PeriodYearMonth AS PeriodYearMonth,
        ISNULL(att.TotalLateMinutes, 0)      AS TotalLateMinutes,
        ISNULL(att.TotalOvertimeMinutes, 0)  AS TotalOvertimeMinutes,
        ISNULL(att.TotalWorkedMinutes, 0)    AS TotalWorkedMinutes,
        ISNULL(att.TotalShortfallMinutes, 0) AS TotalShortfallMinutes,
        ISNULL(att.DaysWorked, 0)            AS DaysWorked,
        ISNULL(att.FullDaysWorked, 0)        AS FullDaysWorked,
        ISNULL(att.PresentDays, 0)           AS PresentDays,
        ISNULL(att.AbsentDays, 0)            AS AbsentDays,
        ISNULL(att.RestDays, 0)              AS RestDays,
        ISNULL(att.ExitLeaveMinutes, 0)      AS ExitLeaveMinutes,
        core.fn_MinutesToLeaveDays(ISNULL(att.ExitLeaveMinutes, 0)) AS ExitLeaveDays,
        ISNULL(att.ExitUnpaidMinutes, 0)     AS ExitUnpaidMinutes,
        ISNULL(att.ExitOffsetMinutes, 0)     AS ExitOffsetMinutes,
        ISNULL(leave_used.ApprovedLeaveDays, 0) AS ApprovedLeaveDays,
        CASE WHEN ISNULL(att.AbsentDays, 0) - ISNULL(leave_used.ApprovedLeaveDays, 0) > 0
             THEN ISNULL(att.AbsentDays, 0) - ISNULL(leave_used.ApprovedLeaveDays, 0)
             ELSE 0 END                      AS UnpaidAbsenceDays
    FROM hr.EMPLOYEE e
    LEFT JOIN att        ON att.EmployeeId = e.EmployeeId
    LEFT JOIN leave_used ON leave_used.EmployeeId = e.EmployeeId
    WHERE e.IsDeleted = 0
      AND (e.TerminationDate IS NULL OR e.TerminationDate >= @from)
      AND e.HireDate <= @to
    ORDER BY e.FullName;
END;
GO

/* Per-branch breakdown - for staff who work across several branches. */
CREATE PROCEDURE attendance.usp_Attendance_MonthlyByBranch
    @PeriodYearMonth CHAR(7), @EmployeeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATE = CAST(@PeriodYearMonth + '-01' AS DATE);
    DECLARE @to   DATE = EOMONTH(@from);

    SELECT a.EmployeeId, e.FullName, a.BranchId, b.Name AS BranchName,
           COUNT(*)               AS Days,
           SUM(a.DayFraction)     AS DaysWorked,
           SUM(a.WorkedMinutes)   AS WorkedMinutes,
           SUM(a.OvertimeMinutes) AS OvertimeMinutes
    FROM attendance.ATTENDANCE_RECORD a
    JOIN hr.EMPLOYEE e    ON e.EmployeeId = a.EmployeeId
    LEFT JOIN hr.BRANCH b ON b.BranchId = a.BranchId
    WHERE a.WorkDate BETWEEN @from AND @to
      AND a.[Status] = 'Present'
      AND (@EmployeeId IS NULL OR a.EmployeeId = @EmployeeId)
    GROUP BY a.EmployeeId, e.FullName, a.BranchId, b.Name
    ORDER BY e.FullName, b.Name;
END;
GO

/* Mark days covered by APPROVED leave as [Status] = 'Leave' so they are not counted
   as unpaid absences. Driven by hr.LEAVE_LEDGER usage rows.
   NOTE: this matches the ledger's EffectiveDate. When workflow.LEAVE_REQUEST exists
   (with FromDate..ToDate) expand this to mark EVERY day in the range. */
CREATE PROCEDURE attendance.usp_Attendance_MarkLeaveDays
    @PeriodYearMonth CHAR(7)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATE = CAST(@PeriodYearMonth + '-01' AS DATE);
    DECLARE @to   DATE = EOMONTH(@from);

    UPDATE a
    SET a.[Status] = 'Leave', a.ProcessedUtc = SYSUTCDATETIME()
    FROM attendance.ATTENDANCE_RECORD a
    JOIN hr.LEAVE_LEDGER l
      ON l.EmployeeId    = a.EmployeeId
     AND l.MovementType  = 'Usage'
     AND l.EffectiveDate = a.WorkDate
    WHERE a.WorkDate BETWEEN @from AND @to
      AND a.[Status] = 'Absent'
      AND a.IsManual = 0;

    SELECT @@ROWCOUNT AS DaysMarkedAsLeave;
END;
GO

/* ############################################################################
   ==============================  SMOKE TEST  ==============================
   Run top-to-bottom. Expected results are stated so you can VERIFY the time maths
   rather than trust it.
   ############################################################################ */

PRINT '--- config ---';
EXEC core.usp_Setting_GetAll;

PRINT '--- process the seeded punches ---';
EXEC attendance.usp_Attendance_ProcessRawLogs @WorkDate = '2026-06-02';   -- expect 2 days
EXEC attendance.usp_Attendance_MarkAbsentees  @WorkDate = '2026-06-02';   -- expect 1 (Joe, RestDay)

PRINT '--- the computed day ---';
/* EXPECTED, Rami (10):
     PunchPairs 2 | Gross 400 | Gap 120 | BreakApplied 30 | WORKED 400
     Standard 450 | DayFraction 0.89 | IsFullDay 0 | Shortfall 50
     Late 10 | Overtime 0 | ExitActual 90 | ExitLeave 90 (basis = Actual)
   EXPECTED, Lina (11):
     PunchPairs 1 | Gross 510 | Gap 0 | BreakApplied 30 | WORKED 480
     Standard 450 | DayFraction 1.00 | IsFullDay 1 | Overtime 30 (DETECTED, unpaid) */
EXEC attendance.usp_Attendance_GetByDateRange @FromDate = '2026-06-01', @ToDate = '2026-06-30';

PRINT '--- the intervals behind Rami''s 400 worked minutes ---';
DECLARE @RamiId BIGINT = (SELECT AttendanceId FROM attendance.ATTENDANCE_RECORD
                          WHERE EmployeeId = 10 AND WorkDate = '2026-06-02');
EXEC attendance.usp_Attendance_GetById @AttendanceId = @RamiId;
/* EXPECTED: 08:20-12:00 = 220 (gap after 120), 14:00-17:00 = 180 */

PRINT '--- Rami had an APPROVED 2h exit, but only took 90 min ---';
EXEC attendance.usp_Attendance_SetExitApproval
     @AttendanceId = @RamiId, @ExitApprovedMinutes = 120,
     @HrNote = 'Approved 2h exit permission';
/* EXPECTED: ExitActual 90 | ExitApproved 120 | ExitVariance -30 (came back early)
             ExitLeave 90  (DEFAULT basis = Actual -> deduct what he really took) */

PRINT '--- HR''s queue of undecided variances ---';
EXEC attendance.usp_Attendance_GetExitVariances @FromDate = '2026-06-01', @ToDate = '2026-06-30';

PRINT '--- HR decides: ignore the 30-minute early return ---';
EXEC attendance.usp_Attendance_SetExitDisposition
     @AttendanceId = @RamiId, @Disposition = 'Ignore',
     @HrNote = 'Came back early, no action';

PRINT '--- is June safe to run payroll on? ---';
EXEC attendance.usp_Attendance_PayrollReadiness @PeriodYearMonth = '2026-06';

PRINT '--- what payroll consumes ---';
EXEC attendance.usp_Attendance_MonthlySummary     @EmployeeId = 10, @PeriodYearMonth = '2026-06';
EXEC attendance.usp_Attendance_MonthlySummary_All @PeriodYearMonth = '2026-06';
GO

/* ============================================================================
   END. 11 tables | 2 functions | 53 stored procedures.
   Re-runnable: every object is dropped and recreated.
   ============================================================================ */
