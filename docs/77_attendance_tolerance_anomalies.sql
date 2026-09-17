/* ============================================================================
   77_attendance_tolerance_anomalies.sql — tolerance-based late / early anomalies,
   decided by HR. Extends the single day rule of script 76.

   THE RULE (attendance.fn_AttendanceDayRule, still pure arithmetic):
     Tolerance           = SHIFT.GraceMinutes when set, else core.SETTING AttendanceToleranceMinutes
                           (default 10). SHIFT.GraceMinutes is now NULLable: NULL = use the setting.
     LateMinutes         = FirstIn − ShiftStart when that is ≥ Tolerance, else 0
     EarlyExitMinutes    = ShiftEnd − LastOut  when that is ≥ Tolerance, else 0
     ExitActualMinutes   = MidDayGapMinutes ONLY. An early departure is no longer an exit variance:
                           it is an 'EarlyDeparture' ANOMALY. Mid-day out/in gaps stay in the
                           exit-variance queue exactly as before (usp_Attendance_GetExitVariances,
                           SetExitApproval / SetExitDisposition).
     LateDeductMinutes   = LateMinutes      when the LateArrival    anomaly is decided 'Deducted', else 0
     EarlyDeductMinutes  = EarlyExitMinutes when the EarlyDeparture anomaly is decided 'Deducted', else 0
                           — minus whatever an approved exit permission still covers after the mid-day gap
     CoveredMinutes      = min(MidDayGap, Approved) + variance covered by HR's disposition (Ignore / Overtime)
                         + (arrival minutes after the start − LateDeductMinutes)
                         + (minutes before the shift end  − EarlyDeductMinutes)
                           → below the tolerance the day counts as on time; at or above it the minutes are
                             COVERED until HR decides; 'Deducted' takes them off the day; 'Excused' and
                             'Corrected' keep them covered.
     DayFraction         = min(1, (Worked + Covered) / Standard)   (unchanged)
   The LateDeductionBasis setting of script 76 is DELETED — the decision replaces it — and the
   @LateBasis input of the rule is replaced by the two decisions.

   THE ANOMALY TABLE attendance.ATTENDANCE_ANOMALY — one row per (AttendanceId, Type):
     Type      'LateArrival' | 'EarlyDeparture' | 'MissingPunch' (the existing HasAnomaly kind: an
               unpaired / missing punch, derived from the record's HasAnomaly bit)
     Minutes, ShiftStartUtc, ShiftEndUtc, PunchInUtc, PunchOutUtc — what HR looks at
     Decision  NULL (undecided) | 'Excused' | 'Deducted' | 'Corrected', DecidedByUserId, DecidedAt, Note
   usp_Attendance_SyncAnomalies keeps the rows in step with the day: re-processing UPDATES the minutes
   and the times but never touches a decision; a row whose condition no longer holds (the tolerance was
   raised, the punch was corrected) is removed — unless it is 'Corrected', which stays as the record
   of the correction. An approved exit permission whose minutes (after the mid-day gap) cover the early
   departure resolves that anomaly automatically as Excused ("Covered by exit permission #N").

   WRITERS — every path that computes a day now syncs its anomalies:
     usp_Attendance_ComputeDay        the one writer for machine days (reads the two decisions as inputs)
     usp_Attendance_ManualUpsert      now measured by the SAME rule (fn_AttendanceDayRule) instead of its
                                      own arithmetic; IsManual = 1 as before; result shape kept (+ columns)
     usp_Attendance_RecomputeManualDay re-runs ManualUpsert with the row's stored inputs after a decision
     usp_Correction_Approve           applies the correction through ManualUpsert (same rule, IsManual = 1)
     usp_Attendance_HrAdjustDay       HR overrode the whole day: its undecided anomalies become 'Corrected'
   DECISIONS:
     usp_Anomaly_Decide (@AnomalyId, @Decision Excuse|Deduct|Correct, @CorrectedTimeUtc, @Note, @DecidedByUserId)
       Excuse / Deduct   store the decision, re-derive the day (ComputeDay, or ManualUpsert for a manual day)
       Correct           store the corrected punch through ManualUpsert (the existing manual path): the
                         LateArrival's In, the EarlyDeparture's Out, the MissingPunch's missing side
       a MissingPunch can only be Corrected (there is no time to excuse or deduct)
     usp_Anomaly_DecideAll (@PeriodYearMonth, @Decision Excuse|Deduct, @BranchId, @Note, @DecidedByUserId)
       every undecided LateArrival / EarlyDeparture of the month (MissingPunch rows are skipped and counted)
   READS:
     usp_Attendance_GetAnomalies (@FromDate, @ToDate, @OnlyUndecided = 0, @BranchId = NULL) — one row per
       anomaly; the first nine columns are exactly the old shape, the rest is additive.
     usp_Attendance_PayrollReadiness adds UndecidedAnomalies (before IsReady; IsReady requires 0) — its
       INSERT-EXEC consumers (payroll.usp_PayrollRun_Create, tests/qa/cases/04_payroll.sql) are updated.
       usp_PayrollRun_Create refuses the run naming the count while UndecidedAnomalies > 0.
   MIGRATION at the end: MissingPunch rows for every HasAnomaly record; the previous and current month
   re-derived (ReprocessDay loop) so the tolerance classification lands in the anomaly table; an
   EarlyDeparture that HR had already dispositioned as an exit variance under script 76 keeps that
   decision (UnpaidAbsence → Deducted, Ignore / Overtime → Excused). Prints every employee-day that
   gained an anomaly row.
   Every refusal is RAISERROR(msg,16,1) + RETURN. Idempotent. Run with sqlcmd -I (filtered index).
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ============================================================================
   0. schema
   ============================================================================ */

/* the setting; the LateDeductionBasis row of script 76 goes (the decision replaces it) */
IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'AttendanceToleranceMinutes')
    INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, [Description], Section, SortOrder, ModifiedAt)
    VALUES ('AttendanceToleranceMinutes', '10', 'int',
            N'Late arrival or early departure of this many minutes or more becomes an anomaly for HR to decide; below it the day counts as on time.',
            'Attendance', 21, SYSUTCDATETIME());
ELSE
    UPDATE core.SETTING
    SET DataType = 'int', Section = 'Attendance', SortOrder = 21,
        [Description] = N'Late arrival or early departure of this many minutes or more becomes an anomaly for HR to decide; below it the day counts as on time.'
    WHERE SettingKey = 'AttendanceToleranceMinutes';
DELETE FROM core.SETTING WHERE SettingKey = 'LateDeductionBasis';
GO

/* SHIFT.GraceMinutes: NULL = use the setting. A shift whose grace equals the tolerance default is
   equivalent under the new rule and follows the setting from now on (done once, when the column flips). */
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('attendance.SHIFT') AND name = 'GraceMinutes' AND is_nullable = 0)
BEGIN
    DECLARE @df sysname = (SELECT dc.name FROM sys.default_constraints dc
                           JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
                           WHERE dc.parent_object_id = OBJECT_ID('attendance.SHIFT') AND c.name = 'GraceMinutes');
    IF @df IS NOT NULL EXEC ('ALTER TABLE attendance.SHIFT DROP CONSTRAINT [' + @df + ']');
    ALTER TABLE attendance.SHIFT ALTER COLUMN GraceMinutes INT NULL;
    DECLARE @tol INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'AttendanceToleranceMinutes') AS INT), 10);
    UPDATE attendance.SHIFT SET GraceMinutes = NULL WHERE GraceMinutes = @tol;
    PRINT CONCAT('SCHEMA | SHIFT.GraceMinutes is now NULLable; ', @@ROWCOUNT, ' shift(s) whose grace equalled the tolerance (', @tol, ') now follow the setting');
END
GO

IF COL_LENGTH('attendance.ATTENDANCE_RECORD', 'EarlyDeductMinutes') IS NULL
    ALTER TABLE attendance.ATTENDANCE_RECORD ADD EarlyDeductMinutes INT NOT NULL CONSTRAINT DF_AttRec_EarlyDeduct DEFAULT (0);
GO

IF OBJECT_ID('attendance.ATTENDANCE_ANOMALY') IS NULL
BEGIN
    CREATE TABLE attendance.ATTENDANCE_ANOMALY
    (
        AnomalyId       BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ATTENDANCE_ANOMALY PRIMARY KEY,
        AttendanceId    BIGINT       NOT NULL,
        EmployeeId      INT          NOT NULL,
        WorkDate        DATE         NOT NULL,
        [Type]          VARCHAR(20)  NOT NULL CONSTRAINT CK_AttAnomaly_Type CHECK ([Type] IN ('LateArrival', 'EarlyDeparture', 'MissingPunch')),
        [Minutes]       INT          NOT NULL CONSTRAINT DF_AttAnomaly_Minutes DEFAULT (0),
        ShiftStartUtc   DATETIME2    NULL,
        ShiftEndUtc     DATETIME2    NULL,
        PunchInUtc      DATETIME2    NULL,
        PunchOutUtc     DATETIME2    NULL,
        Decision        VARCHAR(10)  NULL CONSTRAINT CK_AttAnomaly_Decision CHECK (Decision IS NULL OR Decision IN ('Excused', 'Deducted', 'Corrected')),
        DecidedByUserId INT          NULL,
        DecidedAt       DATETIME2    NULL,
        Note            NVARCHAR(300) NULL,
        CreatedAt       DATETIME2    NOT NULL CONSTRAINT DF_AttAnomaly_Created DEFAULT (SYSUTCDATETIME()),
        UpdatedAt       DATETIME2    NULL,
        CONSTRAINT UQ_AttAnomaly_AttendanceType UNIQUE (AttendanceId, [Type]),
        CONSTRAINT FK_AttAnomaly_Record FOREIGN KEY (AttendanceId) REFERENCES attendance.ATTENDANCE_RECORD (AttendanceId) ON DELETE CASCADE,
        CONSTRAINT FK_AttAnomaly_Employee FOREIGN KEY (EmployeeId) REFERENCES hr.EMPLOYEE (EmployeeId),
        CONSTRAINT FK_AttAnomaly_DecidedBy FOREIGN KEY (DecidedByUserId) REFERENCES security.[USER] (UserId)
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('attendance.ATTENDANCE_ANOMALY') AND name = 'IX_AttAnomaly_WorkDate')
    CREATE INDEX IX_AttAnomaly_WorkDate ON attendance.ATTENDANCE_ANOMALY (WorkDate, EmployeeId) INCLUDE (Decision, [Type]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('attendance.ATTENDANCE_ANOMALY') AND name = 'IX_AttAnomaly_Undecided')
    CREATE INDEX IX_AttAnomaly_Undecided ON attendance.ATTENDANCE_ANOMALY (WorkDate) WHERE Decision IS NULL;
GO

/* shifts: the grace is optional */
CREATE OR ALTER PROCEDURE attendance.usp_Shift_Create
    @Name NVARCHAR(50), @StartTime TIME, @EndTime TIME,
    @GraceMinutes INT = NULL, @CrossesMidnight BIT = 0, @BreakMinutes INT = 0
AS BEGIN SET NOCOUNT ON;
    IF @GraceMinutes IS NOT NULL AND @GraceMinutes < 0
    BEGIN RAISERROR('GraceMinutes must be zero or more, or empty to use the AttendanceToleranceMinutes setting.', 16, 1); RETURN; END
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes)
    VALUES (@Name, @StartTime, @EndTime, @GraceMinutes, ISNULL(@CrossesMidnight, 0), ISNULL(@BreakMinutes, 0));
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS ShiftId; END;
GO

CREATE OR ALTER PROCEDURE attendance.usp_Shift_Update
    @ShiftId INT, @Name NVARCHAR(50), @StartTime TIME, @EndTime TIME,
    @GraceMinutes INT = NULL, @CrossesMidnight BIT, @BreakMinutes INT, @IsActive BIT
AS BEGIN SET NOCOUNT ON;
    IF @GraceMinutes IS NOT NULL AND @GraceMinutes < 0
    BEGIN RAISERROR('GraceMinutes must be zero or more, or empty to use the AttendanceToleranceMinutes setting.', 16, 1); RETURN; END
    UPDATE attendance.SHIFT
    SET Name = @Name, StartTime = @StartTime, EndTime = @EndTime,
        GraceMinutes = @GraceMinutes, CrossesMidnight = @CrossesMidnight,
        BreakMinutes = @BreakMinutes, IsActive = @IsActive
    WHERE ShiftId = @ShiftId; END;
GO

/* ============================================================================
   1. THE RULE — pure arithmetic, no table access (MokaCo.HRMS.Tests/Attendance/AttendanceDayRuleTests.cs)
   ============================================================================ */
CREATE OR ALTER FUNCTION attendance.fn_AttendanceDayRule
(
    @ShiftStartUtc           DATETIME2,     -- NULL = no rostered shift (default standard day; no late / early rule)
    @ShiftEndUtc             DATETIME2,     -- already on the next day for a shift that crosses midnight
    @BreakMinutes            INT,
    @ToleranceMinutes        INT,           -- SHIFT.GraceMinutes if set, else the AttendanceToleranceMinutes setting
    @StandardMinutes         INT,           -- End − Start − Break, or the default standard day when there is no shift
    @FirstInUtc              DATETIME2,
    @LastOutUtc              DATETIME2,
    @GapMinutes              INT,           -- Σ mid-day out→in gaps between paired intervals
    @ExitApprovedMinutes     INT,           -- HR's figure, else Σ approved exit permissions for the day
    @Disposition             VARCHAR(20),   -- HR's disposition of the (mid-day) variance: UnpaidAbsence | Overtime | Ignore | NULL
    @OvertimeApprovedMinutes INT,           -- Σ approved OVERTIME_REQUEST minutes for the day
    @LateDecision            VARCHAR(10),   -- the LateArrival anomaly's decision: NULL | Excused | Deducted | Corrected
    @EarlyDecision           VARCHAR(10),   -- the EarlyDeparture anomaly's decision: NULL | Excused | Deducted | Corrected
    @FullDayThreshold        DECIMAL(5,2),
    @IsRestDay               BIT,
    @IsOnLeave               BIT,
    @IsHoliday               BIT
)
RETURNS TABLE
AS
RETURN
    SELECT
        s4.[Status],
        s2.EffectiveInUtc,
        s2.EffectiveOutUtc,
        LateMinutes        = CASE WHEN s4.Measured = 1 THEN s3a.LateMinutes ELSE 0 END,
        LateDeductMinutes  = CASE WHEN s4.Measured = 1 THEN s3.LateDeductMinutes ELSE 0 END,
        EarlyExitMinutes   = CASE WHEN s4.Measured = 1 THEN s3a.EarlyExitMinutes ELSE 0 END,
        MidDayGapMinutes   = CASE WHEN s4.Measured = 1 THEN s2.MidDayGapMinutes ELSE 0 END,
        ExitActualMinutes  = CASE WHEN s4.Measured = 1 THEN s3a.ExitActualMinutes ELSE 0 END,
        ExitApprovedMinutes = s0.Approved,
        ExitVarianceMinutes = CASE WHEN s4.Measured = 1 THEN s3.ExitVarianceMinutes ELSE 0 END,
        OvertimeMinutes    = CASE WHEN s4.Measured = 1 THEN s3.OvertimeMinutes ELSE 0 END,
        WorkedMinutes      = s3a.WorkedMinutes,                          -- informational on a rest / leave day
        CoveredMinutes     = CASE WHEN s4.Measured = 1 THEN s3.CoveredMinutes ELSE 0 END,
        DayFraction        = s4.DayFraction,
        IsFullDay          = CAST(CASE WHEN s4.DayFraction IS NOT NULL AND s4.DayFraction >= ISNULL(@FullDayThreshold, 1.00) THEN 1 ELSE 0 END AS BIT),
        ShortfallMinutes   = CASE WHEN s4.Measured = 1 AND s0.Standard - s3a.WorkedMinutes - s3.CoveredMinutes > 0
                                  THEN s0.Standard - s3a.WorkedMinutes - s3.CoveredMinutes ELSE 0 END,
        BreakApplied       = CASE WHEN @FirstInUtc IS NOT NULL THEN s0.BreakMin ELSE 0 END,
        StandardMinutes    = s0.Standard,
        EarlyDeductMinutes = CASE WHEN s4.Measured = 1 THEN s3.EarlyDeductMinutes ELSE 0 END,
        ToleranceMinutes   = s0.Tol
    FROM (SELECT
              BreakMin   = ISNULL(@BreakMinutes, 0),
              Tol        = ISNULL(@ToleranceMinutes, 0),
              Approved   = ISNULL(@ExitApprovedMinutes, 0),
              OtApproved = ISNULL(@OvertimeApprovedMinutes, 0),
              Gap        = ISNULL(@GapMinutes, 0),
              HasShift   = CASE WHEN @ShiftStartUtc IS NOT NULL AND @ShiftEndUtc IS NOT NULL THEN 1 ELSE 0 END,
              Standard   = CASE WHEN ISNULL(@IsRestDay, 0) = 1 THEN 0 ELSE ISNULL(@StandardMinutes, 0) END
         ) s0
    CROSS APPLY (SELECT
              /* the arrival minutes after the shift start (inside or beyond the tolerance) */
              RawLate = CASE WHEN @FirstInUtc IS NULL OR s0.HasShift = 0 OR @FirstInUtc <= @ShiftStartUtc THEN 0
                             ELSE DATEDIFF(MINUTE, @ShiftStartUtc, @FirstInUtc) END,
              PreShift = CASE WHEN @FirstInUtc IS NULL OR s0.HasShift = 0 OR @FirstInUtc >= @ShiftStartUtc THEN 0
                              ELSE DATEDIFF(MINUTE, @FirstInUtc, @ShiftStartUtc) END,
              PostShift = CASE WHEN @LastOutUtc IS NULL OR s0.HasShift = 0 OR @LastOutUtc <= @ShiftEndUtc THEN 0
                               ELSE DATEDIFF(MINUTE, @ShiftEndUtc, @LastOutUtc) END,
              EffectiveInUtc = CASE WHEN @FirstInUtc IS NULL THEN NULL
                                    WHEN s0.HasShift = 1 AND @FirstInUtc < @ShiftStartUtc THEN @ShiftStartUtc
                                    ELSE @FirstInUtc END,
              EffectiveOutUtc = CASE WHEN @LastOutUtc IS NULL THEN NULL
                                     WHEN s0.HasShift = 1 AND @LastOutUtc > @ShiftEndUtc THEN @ShiftEndUtc
                                     ELSE @LastOutUtc END,
              /* the minutes before the shift end (inside or beyond the tolerance), capped at the shift length */
              RawEarly = CASE WHEN @LastOutUtc IS NULL OR s0.HasShift = 0 OR @LastOutUtc >= @ShiftEndUtc THEN 0
                              WHEN DATEDIFF(MINUTE, @LastOutUtc, @ShiftEndUtc) > DATEDIFF(MINUTE, @ShiftStartUtc, @ShiftEndUtc)
                                   THEN DATEDIFF(MINUTE, @ShiftStartUtc, @ShiftEndUtc)
                              ELSE DATEDIFF(MINUTE, @LastOutUtc, @ShiftEndUtc) END,
              MidDayGapMinutes = CASE WHEN s0.Gap - s0.BreakMin > 0 THEN s0.Gap - s0.BreakMin ELSE 0 END
         ) s2
    CROSS APPLY (SELECT
              /* at or beyond the tolerance the delay is an anomaly and is reported whole; below it, nothing */
              LateMinutes      = CASE WHEN s2.RawLate  > 0 AND s2.RawLate  >= s0.Tol THEN s2.RawLate  ELSE 0 END,
              EarlyExitMinutes = CASE WHEN s2.RawEarly > 0 AND s2.RawEarly >= s0.Tol THEN s2.RawEarly ELSE 0 END,
              WorkedMinutes = CASE WHEN s2.EffectiveInUtc IS NULL OR s2.EffectiveOutUtc IS NULL THEN 0
                                   WHEN DATEDIFF(MINUTE, s2.EffectiveInUtc, s2.EffectiveOutUtc) - s0.BreakMin - s2.MidDayGapMinutes > 0
                                        THEN DATEDIFF(MINUTE, s2.EffectiveInUtc, s2.EffectiveOutUtc) - s0.BreakMin - s2.MidDayGapMinutes
                                   ELSE 0 END,
              ExitActualMinutes = s2.MidDayGapMinutes,
              /* the approved exit minutes go to the mid-day gap first; what is left may cover the early departure */
              PermForGap = CASE WHEN s2.MidDayGapMinutes < s0.Approved THEN s2.MidDayGapMinutes ELSE s0.Approved END
         ) s3a
    CROSS APPLY (SELECT
              PermRemaining = s0.Approved - s3a.PermForGap
         ) s3b
    CROSS APPLY (SELECT
              LateDeductMinutes  = CASE WHEN s3a.LateMinutes > 0 AND @LateDecision = 'Deducted' THEN s3a.LateMinutes ELSE 0 END,
              EarlyDeductMinutes = CASE WHEN s3a.EarlyExitMinutes > 0 AND @EarlyDecision = 'Deducted'
                                        THEN s3a.EarlyExitMinutes - CASE WHEN s3b.PermRemaining < s3a.EarlyExitMinutes THEN s3b.PermRemaining ELSE s3a.EarlyExitMinutes END
                                        ELSE 0 END
         ) s3c
    CROSS APPLY (SELECT
              s3c.LateDeductMinutes, s3c.EarlyDeductMinutes,
              ExitVarianceMinutes = s3a.ExitActualMinutes - s0.Approved,
              OvertimeMinutes = CASE WHEN s0.HasShift = 0
                                     THEN CASE WHEN s3a.WorkedMinutes - s0.Standard > 0 THEN s3a.WorkedMinutes - s0.Standard ELSE 0 END
                                     ELSE s2.PostShift
                                          + CASE WHEN s0.OtApproved - s2.PostShift <= 0 THEN 0
                                                 WHEN s2.PreShift < s0.OtApproved - s2.PostShift THEN s2.PreShift
                                                 ELSE s0.OtApproved - s2.PostShift END
                                END,
              CoveredMinutes = s3a.PermForGap
                             + CASE WHEN @Disposition IN ('Ignore', 'Overtime') AND s3a.ExitActualMinutes - s0.Approved > 0
                                    THEN s3a.ExitActualMinutes - s0.Approved ELSE 0 END
                             + (s2.RawLate  - s3c.LateDeductMinutes)
                             + (s2.RawEarly - s3c.EarlyDeductMinutes)
         ) s3
    CROSS APPLY (SELECT
              [Status] = CASE WHEN ISNULL(@IsOnLeave, 0) = 1 THEN 'Leave'
                              WHEN ISNULL(@IsRestDay, 0) = 1 THEN 'RestDay'
                              WHEN ISNULL(@IsHoliday, 0) = 1 THEN 'Holiday'
                              WHEN @FirstInUtc IS NOT NULL THEN 'Present'
                              ELSE 'Absent' END,
              Measured = CASE WHEN ISNULL(@IsOnLeave, 0) = 1 OR ISNULL(@IsRestDay, 0) = 1 OR ISNULL(@IsHoliday, 0) = 1 THEN 0 ELSE 1 END,
              DayFraction = CASE WHEN ISNULL(@IsOnLeave, 0) = 1 OR ISNULL(@IsRestDay, 0) = 1 OR ISNULL(@IsHoliday, 0) = 1 THEN NULL
                                 WHEN s0.Standard <= 0 THEN CAST(0 AS DECIMAL(5,2))
                                 WHEN s3a.WorkedMinutes + s3.CoveredMinutes >= s0.Standard THEN CAST(1.00 AS DECIMAL(5,2))
                                 ELSE CAST(ROUND(CAST(s3a.WorkedMinutes + s3.CoveredMinutes AS DECIMAL(12,4)) / s0.Standard, 2) AS DECIMAL(5,2)) END
         ) s4;
GO

/* ============================================================================
   2. the anomaly rows of one day — kept in step with the record by every writer
   ============================================================================ */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_SyncAnomalies
    @AttendanceId     BIGINT,
    @EmployeeId       INT,
    @WorkDate         DATE,
    @LateMinutes      INT,
    @EarlyExitMinutes INT,
    @HasAnomaly       BIT,
    @ShiftStartUtc    DATETIME2 = NULL,
    @ShiftEndUtc      DATETIME2 = NULL,
    @FirstInUtc       DATETIME2 = NULL,
    @LastOutUtc       DATETIME2 = NULL,
    @AutoExcuseEarly  BIT = 0,                 -- an approved exit permission / HR approval covers the early departure
    @AutoExcuseNote   NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @want TABLE ([Type] VARCHAR(20) PRIMARY KEY, [Minutes] INT);
    IF ISNULL(@LateMinutes, 0) > 0      INSERT INTO @want VALUES ('LateArrival',    @LateMinutes);
    IF ISNULL(@EarlyExitMinutes, 0) > 0 INSERT INTO @want VALUES ('EarlyDeparture', @EarlyExitMinutes);
    IF ISNULL(@HasAnomaly, 0) = 1       INSERT INTO @want VALUES ('MissingPunch',   0);

    /* gone: the condition no longer holds (a 'Corrected' row stays as the record of the correction) */
    DELETE FROM attendance.ATTENDANCE_ANOMALY
    WHERE AttendanceId = @AttendanceId
      AND [Type] NOT IN (SELECT [Type] FROM @want)
      AND ISNULL(Decision, '') <> 'Corrected';

    /* still there: the minutes and the times move, the decision never does */
    UPDATE a
    SET a.[Minutes] = w.[Minutes], a.EmployeeId = @EmployeeId, a.WorkDate = @WorkDate,
        a.ShiftStartUtc = @ShiftStartUtc, a.ShiftEndUtc = @ShiftEndUtc,
        a.PunchInUtc = @FirstInUtc, a.PunchOutUtc = @LastOutUtc,
        a.UpdatedAt = SYSUTCDATETIME()
    FROM attendance.ATTENDANCE_ANOMALY a
    JOIN @want w ON w.[Type] = a.[Type]
    WHERE a.AttendanceId = @AttendanceId;

    /* new */
    INSERT INTO attendance.ATTENDANCE_ANOMALY (AttendanceId, EmployeeId, WorkDate, [Type], [Minutes], ShiftStartUtc, ShiftEndUtc, PunchInUtc, PunchOutUtc)
    SELECT @AttendanceId, @EmployeeId, @WorkDate, w.[Type], w.[Minutes], @ShiftStartUtc, @ShiftEndUtc, @FirstInUtc, @LastOutUtc
    FROM @want w
    WHERE NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_ANOMALY a WHERE a.AttendanceId = @AttendanceId AND a.[Type] = w.[Type]);

    /* an approved exit permission that covers the early departure decides it: Excused */
    IF @AutoExcuseEarly = 1
        UPDATE attendance.ATTENDANCE_ANOMALY
        SET Decision = 'Excused', DecidedAt = SYSUTCDATETIME(), DecidedByUserId = NULL,
            Note = ISNULL(@AutoExcuseNote, N'Covered by an approved exit permission.'), UpdatedAt = SYSUTCDATETIME()
        WHERE AttendanceId = @AttendanceId AND [Type] = 'EarlyDeparture' AND Decision IS NULL;
END;
GO

/* ============================================================================
   3. THE WRITER for machine days (script 76, with the tolerance and the decisions as inputs)
   ============================================================================ */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_ComputeDay
    @EmployeeId INT,
    @WorkDate   DATE,
    @Outcome    VARCHAR(10) = NULL OUTPUT      -- 'Inserted' | 'Updated' | 'Skipped' (manual) | 'None' (nothing to say)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Outcome = 'None';

    IF @EmployeeId IS NULL OR @WorkDate IS NULL
    BEGIN RAISERROR('EmployeeId and WorkDate are required.', 16, 1); RETURN; END

    /* ---- the record as it stands (HR's stored decisions are inputs, never recomputed) ---- */
    DECLARE @AttId BIGINT, @IsManual BIT = 0, @Disposition VARCHAR(20), @HrApproved INT,
            @LeaveOverride INT, @ExistingPermissionId INT;
    SELECT @AttId = AttendanceId, @IsManual = IsManual, @Disposition = ExitVarianceDisposition,
           @HrApproved = ExitHrApprovedMinutes, @LeaveOverride = ExitLeaveOverrideMinutes,
           @ExistingPermissionId = ExitPermissionId
    FROM attendance.ATTENDANCE_RECORD
    WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate;

    IF @IsManual = 1 BEGIN SET @Outcome = 'Skipped'; RETURN; END

    /* HR's decisions on the day's anomalies are inputs of the rule */
    DECLARE @LateDecision VARCHAR(10), @EarlyDecision VARCHAR(10);
    SELECT @LateDecision  = MAX(CASE WHEN [Type] = 'LateArrival'    THEN Decision END),
           @EarlyDecision = MAX(CASE WHEN [Type] = 'EarlyDeparture' THEN Decision END)
    FROM attendance.ATTENDANCE_ANOMALY WHERE AttendanceId = @AttId;

    DECLARE @EmpBranch INT, @EmpDeleted BIT;
    SELECT @EmpBranch = BranchId, @EmpDeleted = IsDeleted FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId;
    IF @EmpBranch IS NULL AND @EmpDeleted IS NULL RETURN;              -- no such employee

    /* ---- settings ---- */
    DECLARE @StdDefault INT = core.fn_StandardDayMinutes();
    DECLARE @LeaveBasis VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'ExitLeaveBasis'), 'Actual');
    DECLARE @ToleranceSetting INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'AttendanceToleranceMinutes') AS INT), 10);
    DECLARE @FullDayThreshold DECIMAL(5,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'FullDayThreshold') AS DECIMAL(5,2)), 1.00);
    DECLARE @Mode VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'PunchDirectionMode'), 'Device');
    DECLARE @DebounceSec INT = 60 * ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'PunchDebounceMinutes') AS INT), 0);

    /* ---- the rostered shift: the roster is INERT until its month is Approved ---- */
    DECLARE @Sa INT, @IsRest BIT = 0, @ShiftStart TIME, @ShiftEnd TIME, @ShiftGrace INT, @Break INT = 0, @Crosses BIT = 0;
    SELECT @Sa = sa.ShiftAssignmentId, @IsRest = ISNULL(sa.IsRestDay, 0),
           @ShiftStart = s.StartTime, @ShiftEnd = s.EndTime,
           @ShiftGrace = s.GraceMinutes, @Break = ISNULL(s.BreakMinutes, 0), @Crosses = ISNULL(s.CrossesMidnight, 0)
    FROM attendance.SHIFT_ASSIGNMENT sa
    LEFT JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
    WHERE sa.EmployeeId = @EmployeeId AND sa.WorkDate = @WorkDate
      AND EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                  WHERE rm.BranchId = @EmpBranch
                    AND rm.MonthDate = DATEFROMPARTS(YEAR(@WorkDate), MONTH(@WorkDate), 1)
                    AND rm.[Status] = 'Approved');
    IF @IsRest = 1 SELECT @ShiftStart = NULL, @ShiftEnd = NULL, @ShiftGrace = NULL, @Break = 0;
    DECLARE @Tolerance INT = COALESCE(@ShiftGrace, @ToleranceSetting);

    DECLARE @ShiftStartUtc DATETIME2 = CASE WHEN @ShiftStart IS NULL THEN NULL
                                            ELSE DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @ShiftStart), CAST(@WorkDate AS DATETIME2)) END;
    DECLARE @ShiftEndUtc DATETIME2 = CASE WHEN @ShiftEnd IS NULL THEN NULL
                                          ELSE DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @ShiftEnd) + CASE WHEN @Crosses = 1 THEN 1440 ELSE 0 END, CAST(@WorkDate AS DATETIME2)) END;
    DECLARE @Standard INT = CASE WHEN @IsRest = 1 THEN 0
                                 WHEN @ShiftStart IS NULL THEN @StdDefault
                                 ELSE DATEDIFF(MINUTE, @ShiftStartUtc, @ShiftEndUtc) - @Break END;

    /* ---- the punches attributed to this day, exactly as the machine sent them ---- */
    DECLARE @src TABLE (RawLogId BIGINT, PunchTimeUtc DATETIME2, PunchType SMALLINT, [Source] VARCHAR(20), DeviceId INT);
    INSERT INTO @src (RawLogId, PunchTimeUtc, PunchType, [Source], DeviceId)
    SELECT r.RawLogId, r.PunchTimeUtc, r.PunchType, r.[Source], r.DeviceId
    FROM attendance.RAW_DEVICE_LOG r
    WHERE r.EmployeeId = @EmployeeId
      AND r.PunchTimeUtc >= CAST(@WorkDate AS DATETIME2)
      AND r.PunchTimeUtc <  CAST(DATEADD(DAY, 2, @WorkDate) AS DATETIME2)
      AND attendance.fn_AttributedWorkDate(@EmployeeId, r.PunchTimeUtc) = @WorkDate;

    DECLARE @HasPunches BIT = CASE WHEN EXISTS (SELECT 1 FROM @src) THEN 1 ELSE 0 END;

    /* nothing rostered, nothing punched, nothing recorded → nothing to say (no absence) */
    IF @HasPunches = 0 AND @Sa IS NULL AND @AttId IS NULL RETURN;

    /* debounce: a gap greater than the window starts a new press-group; only the first press of a group is kept */
    DECLARE @kept TABLE (RawLogId BIGINT, PunchTimeUtc DATETIME2, PunchType SMALLINT, [Source] VARCHAR(20), DeviceId INT, Seq INT);
    INSERT INTO @kept (RawLogId, PunchTimeUtc, PunchType, [Source], DeviceId, Seq)
    SELECT k.RawLogId, k.PunchTimeUtc, k.PunchType, k.[Source], k.DeviceId,
           ROW_NUMBER() OVER (ORDER BY k.PunchTimeUtc, k.RawLogId)
    FROM (
        SELECT g.*, ROW_NUMBER() OVER (PARTITION BY g.GrpNo ORDER BY g.PunchTimeUtc, g.RawLogId) AS RnInGrp
        FROM (
            SELECT x.*, SUM(x.NewGrp) OVER (ORDER BY x.PunchTimeUtc, x.RawLogId ROWS UNBOUNDED PRECEDING) AS GrpNo
            FROM (
                SELECT s.*,
                       CASE WHEN LAG(s.PunchTimeUtc) OVER (ORDER BY s.PunchTimeUtc, s.RawLogId) IS NULL
                              OR DATEDIFF(SECOND, LAG(s.PunchTimeUtc) OVER (ORDER BY s.PunchTimeUtc, s.RawLogId), s.PunchTimeUtc) > @DebounceSec
                            THEN 1 ELSE 0 END AS NewGrp
                FROM @src s
            ) x
        ) g
    ) k
    WHERE k.RnInGrp = 1;

    /* effective direction: 'Alternate' = In, Out, In, Out… ; 'Device' = the terminal's own key */
    DECLARE @punch TABLE (Seq INT, PunchTimeUtc DATETIME2, PunchType SMALLINT, PrevType SMALLINT);
    INSERT INTO @punch (Seq, PunchTimeUtc, PunchType, PrevType)
    SELECT e.Seq, e.PunchTimeUtc, e.EffType, LAG(e.EffType) OVER (ORDER BY e.Seq)
    FROM (SELECT k.Seq, k.PunchTimeUtc,
                 CASE WHEN @Mode = 'Alternate' THEN CAST((k.Seq - 1) % 2 AS SMALLINT) ELSE k.PunchType END AS EffType
          FROM @kept k) e;

    /* pair each opening In with the next Out; number the intervals; the gap after each */
    DECLARE @ivl TABLE (SeqNo INT, InTimeUtc DATETIME2, OutTimeUtc DATETIME2, [Minutes] INT, GapAfterMins INT);
    INSERT INTO @ivl (SeqNo, InTimeUtc, OutTimeUtc, [Minutes], GapAfterMins)
    SELECT ROW_NUMBER() OVER (ORDER BY p.InTimeUtc), p.InTimeUtc, p.OutTimeUtc,
           DATEDIFF(MINUTE, p.InTimeUtc, p.OutTimeUtc),
           ISNULL(DATEDIFF(MINUTE, p.OutTimeUtc, LEAD(p.InTimeUtc) OVER (ORDER BY p.InTimeUtc)), 0)
    FROM (
        SELECT i.PunchTimeUtc AS InTimeUtc,
               (SELECT MIN(o.PunchTimeUtc) FROM @punch o WHERE o.PunchType = 1 AND o.PunchTimeUtc > i.PunchTimeUtc) AS OutTimeUtc
        FROM @punch i
        WHERE i.PunchType = 0 AND (i.PrevType IS NULL OR i.PrevType = 1)
    ) p
    WHERE p.OutTimeUtc IS NOT NULL;

    DECLARE @FirstIn DATETIME2, @LastOut DATETIME2, @InCount INT = 0, @OutCount INT = 0,
            @SourceName VARCHAR(20), @DeviceId INT, @Pairs INT = 0, @Gross INT = 0, @Gap INT = 0;
    SELECT @FirstIn = MIN(PunchTimeUtc), @InCount = COUNT(*) FROM @punch WHERE PunchType = 0;
    SELECT @LastOut = MAX(PunchTimeUtc), @OutCount = COUNT(*) FROM @punch WHERE PunchType = 1;
    SELECT TOP 1 @SourceName = [Source], @DeviceId = DeviceId FROM @kept WHERE DeviceId IS NOT NULL ORDER BY Seq;
    IF @SourceName IS NULL SELECT TOP 1 @SourceName = [Source] FROM @kept ORDER BY Seq;
    SELECT @Pairs = COUNT(*), @Gross = ISNULL(SUM([Minutes]), 0), @Gap = ISNULL(SUM(GapAfterMins), 0) FROM @ivl;

    /* ---- the day's kind and the approvals — read fresh on every run ---- */
    DECLARE @OnLeave BIT = CASE WHEN EXISTS (
        SELECT 1 FROM workflow.LEAVE_REQUEST lr
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
        WHERE lr.EmployeeId = @EmployeeId AND ri.[Status] = 'Approved'
          AND @WorkDate BETWEEN lr.FromDate AND lr.ToDate) THEN 1 ELSE 0 END;

    DECLARE @Holiday BIT = 0;
    IF OBJECT_ID('hr.PUBLIC_HOLIDAY') IS NOT NULL AND COL_LENGTH('hr.PUBLIC_HOLIDAY', 'HolidayDate') IS NOT NULL
        EXEC sp_executesql N'SELECT @h = CASE WHEN EXISTS (SELECT 1 FROM hr.PUBLIC_HOLIDAY WHERE HolidayDate = @d) THEN 1 ELSE 0 END',
                           N'@d DATE, @h BIT OUTPUT', @d = @WorkDate, @h = @Holiday OUTPUT;

    DECLARE @PermApproved INT, @PermissionId INT;
    SELECT @PermApproved = SUM(ISNULL(ep.ApprovedMinutes, 0)), @PermissionId = MAX(ep.ExitPermissionId)
    FROM workflow.EXIT_PERMISSION ep
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ep.RequestInstanceId
    WHERE ep.EmployeeId = @EmployeeId AND ep.ExitDate = @WorkDate AND ri.[Status] = 'Approved';
    DECLARE @Approved INT = COALESCE(@HrApproved, @PermApproved, 0);

    DECLARE @OtApproved INT = ISNULL((
        SELECT SUM(ISNULL(o.ApprovedMinutes, 0))
        FROM workflow.OVERTIME_REQUEST o
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = o.RequestInstanceId
        WHERE o.EmployeeId = @EmployeeId AND o.WorkDate = @WorkDate AND ri.[Status] = 'Approved'), 0);

    /* ---- the rule ---- */
    DECLARE @r TABLE ([Status] VARCHAR(20), LateMinutes INT, LateDeductMinutes INT, EarlyExitMinutes INT, MidDayGapMinutes INT,
                      ExitActualMinutes INT, ExitApprovedMinutes INT, ExitVarianceMinutes INT, OvertimeMinutes INT, WorkedMinutes INT,
                      CoveredMinutes INT, DayFraction DECIMAL(5,2), IsFullDay BIT, ShortfallMinutes INT, BreakApplied INT, StandardMinutes INT,
                      EarlyDeductMinutes INT);
    INSERT INTO @r
    SELECT [Status], LateMinutes, LateDeductMinutes, EarlyExitMinutes, MidDayGapMinutes,
           ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes, OvertimeMinutes, WorkedMinutes,
           CoveredMinutes, DayFraction, IsFullDay, ShortfallMinutes, BreakApplied, StandardMinutes, EarlyDeductMinutes
    FROM attendance.fn_AttendanceDayRule(@ShiftStartUtc, @ShiftEndUtc, @Break, @Tolerance, @Standard,
                                         @FirstIn, @LastOut, @Gap, @Approved, @Disposition, @OtApproved,
                                         @LateDecision, @EarlyDecision, @FullDayThreshold, @IsRest, @OnLeave, @Holiday);

    DECLARE @Status VARCHAR(20) = (SELECT [Status] FROM @r);
    DECLARE @HasAnomaly BIT = CASE WHEN @HasPunches = 1 AND @Status IN ('Present', 'RestDay')
                                    AND (@InCount <> @OutCount OR @FirstIn IS NULL OR @LastOut IS NULL) THEN 1 ELSE 0 END;
    DECLARE @BranchId INT = COALESCE((SELECT BranchId FROM attendance.DEVICE WHERE DeviceId = @DeviceId), @EmpBranch);
    DECLARE @ExitActual INT = (SELECT ExitActualMinutes FROM @r);
    DECLARE @ExitLeave INT = COALESCE(@LeaveOverride, CASE WHEN @LeaveBasis = 'Approved' THEN @Approved ELSE @ExitActual END);

    BEGIN TRAN;

    IF @AttId IS NULL
    BEGIN
        INSERT INTO attendance.ATTENDANCE_RECORD
            (EmployeeId, ShiftAssignmentId, WorkDate, FirstInUtc, LastOutUtc, PunchPairs, GrossMinutes, GapMinutes, BreakApplied,
             WorkedMinutes, StandardMinutes, DayFraction, IsFullDay, ShortfallMinutes, LateMinutes, LateDeductMinutes, EarlyExitMinutes,
             EarlyDeductMinutes, CoveredMinutes, OvertimeMinutes, ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes, ExitLeaveMinutes,
             ExitPermissionId, [Status], [Source], DeviceId, BranchId, HasAnomaly, IsManual, ProcessedUtc)
        SELECT @EmployeeId, @Sa, @WorkDate, @FirstIn, @LastOut, @Pairs, @Gross, @Gap, r.BreakApplied,
               r.WorkedMinutes, r.StandardMinutes, r.DayFraction, r.IsFullDay, r.ShortfallMinutes, r.LateMinutes, r.LateDeductMinutes, r.EarlyExitMinutes,
               r.EarlyDeductMinutes, r.CoveredMinutes, r.OvertimeMinutes, r.ExitActualMinutes, r.ExitApprovedMinutes, r.ExitVarianceMinutes, @ExitLeave,
               @PermissionId, r.[Status], ISNULL(@SourceName, 'Device'), @DeviceId, @BranchId, @HasAnomaly, 0, SYSUTCDATETIME()
        FROM @r r;
        SET @AttId = SCOPE_IDENTITY();
        SET @Outcome = 'Inserted';
    END
    ELSE
    BEGIN
        UPDATE a
        SET a.ShiftAssignmentId = @Sa, a.FirstInUtc = @FirstIn, a.LastOutUtc = @LastOut, a.PunchPairs = @Pairs,
            a.GrossMinutes = @Gross, a.GapMinutes = @Gap, a.BreakApplied = r.BreakApplied,
            a.WorkedMinutes = r.WorkedMinutes, a.StandardMinutes = r.StandardMinutes, a.DayFraction = r.DayFraction,
            a.IsFullDay = r.IsFullDay, a.ShortfallMinutes = r.ShortfallMinutes, a.LateMinutes = r.LateMinutes,
            a.LateDeductMinutes = r.LateDeductMinutes, a.EarlyExitMinutes = r.EarlyExitMinutes, a.EarlyDeductMinutes = r.EarlyDeductMinutes,
            a.CoveredMinutes = r.CoveredMinutes,
            a.OvertimeMinutes = r.OvertimeMinutes, a.ExitActualMinutes = r.ExitActualMinutes,
            a.ExitApprovedMinutes = r.ExitApprovedMinutes, a.ExitVarianceMinutes = r.ExitVarianceMinutes, a.ExitLeaveMinutes = @ExitLeave,
            a.ExitPermissionId = COALESCE(@PermissionId, a.ExitPermissionId),
            a.[Status] = r.[Status],
            a.[Source] = CASE WHEN @HasPunches = 1 THEN ISNULL(@SourceName, a.[Source]) ELSE a.[Source] END,
            a.DeviceId = @DeviceId, a.BranchId = @BranchId, a.HasAnomaly = @HasAnomaly, a.ProcessedUtc = SYSUTCDATETIME()
        FROM attendance.ATTENDANCE_RECORD a
        CROSS JOIN @r r
        WHERE a.AttendanceId = @AttId;
        SET @Outcome = 'Updated';
    END

    DELETE FROM attendance.ATTENDANCE_INTERVAL WHERE AttendanceId = @AttId;
    INSERT INTO attendance.ATTENDANCE_INTERVAL (AttendanceId, SeqNo, InTimeUtc, OutTimeUtc, [Minutes], GapAfterMins)
    SELECT @AttId, SeqNo, InTimeUtc, OutTimeUtc, [Minutes], GapAfterMins FROM @ivl;

    /* ---- the anomalies of the day; an approved permission left over after the mid-day gap excuses the early departure ---- */
    DECLARE @Late INT = (SELECT LateMinutes FROM @r), @Early INT = (SELECT EarlyExitMinutes FROM @r),
            @MidDay INT = (SELECT MidDayGapMinutes FROM @r);
    DECLARE @PermRemaining INT = @Approved - CASE WHEN @MidDay < @Approved THEN @MidDay ELSE @Approved END;
    DECLARE @AutoExcuse BIT = CASE WHEN @Early > 0 AND @PermRemaining >= @Early AND (@PermissionId IS NOT NULL OR @HrApproved IS NOT NULL) THEN 1 ELSE 0 END;
    DECLARE @AutoNote NVARCHAR(300) = CASE WHEN @PermissionId IS NOT NULL THEN CONCAT(N'Covered by exit permission #', @PermissionId, N' (', @Approved, N' min approved).')
                                           ELSE CONCAT(N'Covered by HR exit approval (', @Approved, N' min).') END;
    EXEC attendance.usp_Attendance_SyncAnomalies
        @AttendanceId = @AttId, @EmployeeId = @EmployeeId, @WorkDate = @WorkDate,
        @LateMinutes = @Late, @EarlyExitMinutes = @Early, @HasAnomaly = @HasAnomaly,
        @ShiftStartUtc = @ShiftStartUtc, @ShiftEndUtc = @ShiftEndUtc, @FirstInUtc = @FirstIn, @LastOutUtc = @LastOut,
        @AutoExcuseEarly = @AutoExcuse, @AutoExcuseNote = @AutoNote;

    COMMIT TRAN;
END;
GO

/* ============================================================================
   4. the manual paths — measured by the SAME rule
   ============================================================================ */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_ManualUpsert
    @EmployeeId       INT,
    @WorkDate         DATE,
    @FirstInUtc       DATETIME2 = NULL,
    @LastOutUtc       DATETIME2 = NULL,
    @ExitMinutes      INT = 0,                 -- a mid-day absence HR knows about (beyond the break)
    @ExitApprovedMins INT = 0,                 -- how much of it was authorised
    @Status           VARCHAR(20) = NULL,      -- NULL = the rule decides (roster, approved leave, punches)
    @BranchId         INT = NULL,
    @HrNote           NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @EmployeeId IS NULL OR @WorkDate IS NULL
    BEGIN RAISERROR('EmployeeId and WorkDate are required.', 16, 1); RETURN; END
    IF @FirstInUtc IS NOT NULL AND @LastOutUtc IS NOT NULL AND @LastOutUtc < @FirstInUtc
    BEGIN RAISERROR('The out time must not be before the in time.', 16, 1); RETURN; END
    IF @Status IS NOT NULL AND @Status NOT IN ('Present', 'Absent', 'RestDay', 'Leave', 'Holiday')
    BEGIN RAISERROR('Status must be Present, Absent, RestDay, Leave or Holiday.', 16, 1); RETURN; END

    DECLARE @LeaveBasis VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'ExitLeaveBasis'), 'Actual');
    DECLARE @FullDayThreshold DECIMAL(5,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'FullDayThreshold') AS DECIMAL(5,2)), 1.00);
    DECLARE @ToleranceSetting INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'AttendanceToleranceMinutes') AS INT), 10);
    DECLARE @StdDefault INT = core.fn_StandardDayMinutes();

    /* the record as it stands: HR's stored decisions are inputs */
    DECLARE @AttId BIGINT, @Disposition VARCHAR(20), @LeaveOverride INT;
    SELECT @AttId = AttendanceId, @Disposition = ExitVarianceDisposition, @LeaveOverride = ExitLeaveOverrideMinutes
    FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate;

    DECLARE @LateDecision VARCHAR(10), @EarlyDecision VARCHAR(10);
    SELECT @LateDecision  = MAX(CASE WHEN [Type] = 'LateArrival'    THEN Decision END),
           @EarlyDecision = MAX(CASE WHEN [Type] = 'EarlyDeparture' THEN Decision END)
    FROM attendance.ATTENDANCE_ANOMALY WHERE AttendanceId = @AttId;

    /* the rostered shift (a manual entry is measured against the roster as it stands) */
    DECLARE @Sa INT, @ShiftGrace INT, @Break INT = 0, @IsRest BIT = 0, @ShiftStart TIME, @ShiftEnd TIME, @Crosses BIT = 0;
    SELECT @Sa = sa.ShiftAssignmentId, @IsRest = ISNULL(sa.IsRestDay, 0),
           @ShiftStart = s.StartTime, @ShiftEnd = s.EndTime,
           @ShiftGrace = s.GraceMinutes, @Break = ISNULL(s.BreakMinutes, 0), @Crosses = ISNULL(s.CrossesMidnight, 0)
    FROM attendance.SHIFT_ASSIGNMENT sa
    LEFT JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
    WHERE sa.EmployeeId = @EmployeeId AND sa.WorkDate = @WorkDate;
    IF @Status = 'RestDay' SET @IsRest = 1;
    IF @IsRest = 1 SELECT @ShiftStart = NULL, @ShiftEnd = NULL, @ShiftGrace = NULL, @Break = 0;
    DECLARE @Tolerance INT = COALESCE(@ShiftGrace, @ToleranceSetting);

    DECLARE @ShiftStartUtc DATETIME2 = CASE WHEN @ShiftStart IS NULL THEN NULL
                                            ELSE DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @ShiftStart), CAST(@WorkDate AS DATETIME2)) END;
    DECLARE @ShiftEndUtc DATETIME2 = CASE WHEN @ShiftEnd IS NULL THEN NULL
                                          ELSE DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @ShiftEnd) + CASE WHEN @Crosses = 1 THEN 1440 ELSE 0 END, CAST(@WorkDate AS DATETIME2)) END;
    DECLARE @Standard INT = CASE WHEN @IsRest = 1 THEN 0
                                 WHEN @ShiftStart IS NULL THEN @StdDefault
                                 ELSE DATEDIFF(MINUTE, @ShiftStartUtc, @ShiftEndUtc) - @Break END;

    DECLARE @OnLeave BIT = CASE WHEN @Status = 'Leave' THEN 1
                                WHEN @Status IS NOT NULL THEN 0
                                WHEN EXISTS (SELECT 1 FROM workflow.LEAVE_REQUEST lr
                                             JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
                                             WHERE lr.EmployeeId = @EmployeeId AND ri.[Status] = 'Approved'
                                               AND @WorkDate BETWEEN lr.FromDate AND lr.ToDate) THEN 1 ELSE 0 END;
    DECLARE @Holiday BIT = CASE WHEN @Status = 'Holiday' THEN 1 ELSE 0 END;
    DECLARE @Exit INT = ISNULL(@ExitMinutes, 0), @Approved INT = ISNULL(@ExitApprovedMins, 0);
    DECLARE @Gross INT = CASE WHEN @FirstInUtc IS NULL OR @LastOutUtc IS NULL THEN 0 ELSE DATEDIFF(MINUTE, @FirstInUtc, @LastOutUtc) END;
    /* @ExitMinutes is the absence BEYOND the break; the rule takes the raw gap and absorbs the break itself */
    DECLARE @Gap INT = CASE WHEN @Exit > 0 THEN @Exit + @Break ELSE 0 END;

    DECLARE @r TABLE ([Status] VARCHAR(20), LateMinutes INT, LateDeductMinutes INT, EarlyExitMinutes INT, MidDayGapMinutes INT,
                      ExitActualMinutes INT, ExitApprovedMinutes INT, ExitVarianceMinutes INT, OvertimeMinutes INT, WorkedMinutes INT,
                      CoveredMinutes INT, DayFraction DECIMAL(5,2), IsFullDay BIT, ShortfallMinutes INT, BreakApplied INT, StandardMinutes INT,
                      EarlyDeductMinutes INT);
    INSERT INTO @r
    SELECT [Status], LateMinutes, LateDeductMinutes, EarlyExitMinutes, MidDayGapMinutes,
           ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes, OvertimeMinutes, WorkedMinutes,
           CoveredMinutes, DayFraction, IsFullDay, ShortfallMinutes, BreakApplied, StandardMinutes, EarlyDeductMinutes
    FROM attendance.fn_AttendanceDayRule(@ShiftStartUtc, @ShiftEndUtc, @Break, @Tolerance, @Standard,
                                         @FirstInUtc, @LastOutUtc, @Gap, @Approved, @Disposition, 0,
                                         @LateDecision, @EarlyDecision, @FullDayThreshold, @IsRest, @OnLeave, @Holiday);

    DECLARE @FinalStatus VARCHAR(20) = COALESCE(@Status, (SELECT [Status] FROM @r));
    DECLARE @FinalBranch INT = COALESCE(@BranchId, (SELECT BranchId FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId));
    DECLARE @ExitLeave INT = COALESCE(@LeaveOverride, CASE WHEN @LeaveBasis = 'Approved' THEN @Approved ELSE @Exit END);
    DECLARE @Pairs INT = CASE WHEN @FirstInUtc IS NOT NULL AND @LastOutUtc IS NOT NULL THEN 1 ELSE 0 END;

    BEGIN TRAN;

    IF @AttId IS NOT NULL
        UPDATE a
        SET a.FirstInUtc = @FirstInUtc, a.LastOutUtc = @LastOutUtc, a.PunchPairs = @Pairs,
            a.GrossMinutes = @Gross, a.GapMinutes = @Exit, a.BreakApplied = r.BreakApplied,
            a.WorkedMinutes = r.WorkedMinutes, a.StandardMinutes = r.StandardMinutes, a.DayFraction = r.DayFraction,
            a.IsFullDay = r.IsFullDay, a.ShortfallMinutes = r.ShortfallMinutes,
            a.LateMinutes = r.LateMinutes, a.LateDeductMinutes = r.LateDeductMinutes,
            a.EarlyExitMinutes = r.EarlyExitMinutes, a.EarlyDeductMinutes = r.EarlyDeductMinutes, a.CoveredMinutes = r.CoveredMinutes,
            a.OvertimeMinutes = r.OvertimeMinutes,
            a.ExitActualMinutes = r.ExitActualMinutes, a.ExitApprovedMinutes = @Approved,
            a.ExitVarianceMinutes = r.ExitVarianceMinutes, a.ExitLeaveMinutes = @ExitLeave,
            a.[Status] = @FinalStatus, a.[Source] = 'Manual', a.IsManual = 1, a.HasAnomaly = 0,
            a.ShiftAssignmentId = @Sa, a.BranchId = @FinalBranch, a.DeviceId = NULL,
            a.HrNote = COALESCE(@HrNote, a.HrNote), a.ProcessedUtc = SYSUTCDATETIME()
        FROM attendance.ATTENDANCE_RECORD a CROSS JOIN @r r
        WHERE a.AttendanceId = @AttId;
    ELSE
    BEGIN
        INSERT INTO attendance.ATTENDANCE_RECORD
            (EmployeeId, ShiftAssignmentId, WorkDate, FirstInUtc, LastOutUtc, PunchPairs,
             GrossMinutes, GapMinutes, BreakApplied, WorkedMinutes, StandardMinutes,
             DayFraction, IsFullDay, ShortfallMinutes, LateMinutes, LateDeductMinutes, EarlyExitMinutes, EarlyDeductMinutes, CoveredMinutes,
             OvertimeMinutes, ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes, ExitLeaveMinutes,
             [Status], [Source], DeviceId, BranchId, HasAnomaly, IsManual, HrNote, ProcessedUtc)
        SELECT @EmployeeId, @Sa, @WorkDate, @FirstInUtc, @LastOutUtc, @Pairs,
               @Gross, @Exit, r.BreakApplied, r.WorkedMinutes, r.StandardMinutes,
               r.DayFraction, r.IsFullDay, r.ShortfallMinutes, r.LateMinutes, r.LateDeductMinutes, r.EarlyExitMinutes, r.EarlyDeductMinutes, r.CoveredMinutes,
               r.OvertimeMinutes, r.ExitActualMinutes, @Approved, r.ExitVarianceMinutes, @ExitLeave,
               @FinalStatus, 'Manual', NULL, @FinalBranch, 0, 1, @HrNote, SYSUTCDATETIME()
        FROM @r r;
        SET @AttId = SCOPE_IDENTITY();
    END

    /* a manual day has no intervals to show; the paired stretch is the entry itself */
    DELETE FROM attendance.ATTENDANCE_INTERVAL WHERE AttendanceId = @AttId;

    DECLARE @Late INT = (SELECT LateMinutes FROM @r), @Early INT = (SELECT EarlyExitMinutes FROM @r),
            @MidDay INT = (SELECT MidDayGapMinutes FROM @r);
    DECLARE @PermRemaining INT = @Approved - CASE WHEN @MidDay < @Approved THEN @MidDay ELSE @Approved END;
    DECLARE @AutoExcuse BIT = CASE WHEN @Early > 0 AND @Approved > 0 AND @PermRemaining >= @Early THEN 1 ELSE 0 END;
    DECLARE @AutoNote NVARCHAR(300) = CONCAT(N'Covered by the approved exit minutes of the manual entry (', @Approved, N' min).');
    EXEC attendance.usp_Attendance_SyncAnomalies
        @AttendanceId = @AttId, @EmployeeId = @EmployeeId, @WorkDate = @WorkDate,
        @LateMinutes = @Late, @EarlyExitMinutes = @Early, @HasAnomaly = 0,
        @ShiftStartUtc = @ShiftStartUtc, @ShiftEndUtc = @ShiftEndUtc, @FirstInUtc = @FirstInUtc, @LastOutUtc = @LastOutUtc,
        @AutoExcuseEarly = @AutoExcuse, @AutoExcuseNote = @AutoNote;

    COMMIT TRAN;

    SELECT AttendanceId, WorkedMinutes, StandardMinutes, DayFraction, IsFullDay,
           LateMinutes, OvertimeMinutes, ExitActualMinutes, ExitApprovedMinutes,
           ExitVarianceMinutes, ExitLeaveMinutes, [Status],
           CoveredMinutes, EarlyExitMinutes, LateDeductMinutes, EarlyDeductMinutes, HasAnomaly, IsManual, ShortfallMinutes
    FROM attendance.ATTENDANCE_RECORD
    WHERE AttendanceId = @AttId;
END;
GO

/* re-runs the manual entry with the row's own stored inputs (after a decision on a manual day) */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_RecomputeManualDay
    @AttendanceId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Emp INT, @D DATE, @In DATETIME2, @Out DATETIME2, @Exit INT, @Approved INT, @Status VARCHAR(20), @Branch INT;
    SELECT @Emp = EmployeeId, @D = WorkDate, @In = FirstInUtc, @Out = LastOutUtc, @Exit = ExitActualMinutes,
           @Approved = ExitApprovedMinutes, @Status = [Status], @Branch = BranchId
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId AND IsManual = 1;
    IF @Emp IS NULL RETURN;
    EXEC attendance.usp_Attendance_ManualUpsert @EmployeeId = @Emp, @WorkDate = @D, @FirstInUtc = @In, @LastOutUtc = @Out,
         @ExitMinutes = @Exit, @ExitApprovedMins = @Approved, @Status = @Status, @BranchId = @Branch, @HrNote = NULL;
END;
GO

/* a workflow correction is applied through the manual path: same rule, IsManual = 1, anomaly cleared */
CREATE OR ALTER PROCEDURE attendance.usp_Correction_Approve
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

    DECLARE @EmployeeId INT, @WorkDate DATE, @InT DATETIME2, @OutT DATETIME2, @Exit INT, @Approved INT, @Branch INT, @Note NVARCHAR(300);
    SELECT @EmployeeId = EmployeeId, @WorkDate = WorkDate,
           @InT = COALESCE(@ni, FirstInUtc), @OutT = COALESCE(@no, LastOutUtc),
           @Exit = COALESCE(@ne, ExitActualMinutes), @Approved = ExitApprovedMinutes, @Branch = BranchId, @Note = HrNote
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
    IF @EmployeeId IS NULL BEGIN RAISERROR('Attendance record not found.', 16, 1); RETURN; END

    /* the MissingPunch anomaly, if any, is what this correction answers */
    UPDATE attendance.ATTENDANCE_ANOMALY
    SET Decision = 'Corrected', DecidedByUserId = @ApprovedBy, DecidedAt = SYSUTCDATETIME(),
        Note = CONCAT(N'Correction #', @CorrectionId, N' approved.'), UpdatedAt = SYSUTCDATETIME()
    WHERE AttendanceId = @AttendanceId AND [Type] = 'MissingPunch' AND Decision IS NULL;

    DECLARE @m TABLE (AttendanceId BIGINT, WorkedMinutes INT, StandardMinutes INT, DayFraction DECIMAL(5,2), IsFullDay BIT,
                      LateMinutes INT, OvertimeMinutes INT, ExitActualMinutes INT, ExitApprovedMinutes INT,
                      ExitVarianceMinutes INT, ExitLeaveMinutes INT, [Status] VARCHAR(20),
                      CoveredMinutes INT, EarlyExitMinutes INT, LateDeductMinutes INT, EarlyDeductMinutes INT, HasAnomaly BIT, IsManual BIT, ShortfallMinutes INT);
    INSERT INTO @m EXEC attendance.usp_Attendance_ManualUpsert
        @EmployeeId = @EmployeeId, @WorkDate = @WorkDate, @FirstInUtc = @InT, @LastOutUtc = @OutT,
        @ExitMinutes = @Exit, @ExitApprovedMins = @Approved, @Status = @ns, @BranchId = @Branch, @HrNote = @Note;

    UPDATE attendance.ATTENDANCE_CORRECTION
    SET ApprovalStatus = 'Approved', ApprovedBy = @ApprovedBy, ActedUtc = SYSUTCDATETIME()
    WHERE CorrectionId = @CorrectionId;

    SELECT AttendanceId, WorkedMinutes, DayFraction, LateMinutes FROM @m;
END;
GO

/* HR overrode the day's figures: nothing on it is left to decide */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_HrAdjustDay
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
    IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId)
    BEGIN RAISERROR('Attendance record not found.', 16, 1); RETURN; END

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
        CoveredMinutes   = 0,
        [Status]         = COALESCE(@Status, [Status]),
        HrNote           = @HrNote,
        IsManual         = 1,
        HasAnomaly       = 0,
        ProcessedUtc     = SYSUTCDATETIME()
    WHERE AttendanceId = @AttendanceId;

    UPDATE attendance.ATTENDANCE_RECORD
    SET IsFullDay = CASE WHEN DayFraction >= @FullDayThreshold THEN 1 ELSE 0 END
    WHERE AttendanceId = @AttendanceId;

    UPDATE attendance.ATTENDANCE_ANOMALY
    SET Decision = 'Corrected', DecidedByUserId = @ModifiedBy, DecidedAt = SYSUTCDATETIME(),
        Note = LEFT(CONCAT(N'Day adjusted by HR: ', @HrNote), 300), UpdatedAt = SYSUTCDATETIME()
    WHERE AttendanceId = @AttendanceId AND Decision IS NULL;

    COMMIT TRAN;

    SELECT AttendanceId, WorkedMinutes, StandardMinutes, DayFraction, IsFullDay,
           ShortfallMinutes, OvertimeMinutes, [Status], HrNote
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
END;
GO

/* ============================================================================
   5. the list and the decisions
   ============================================================================ */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_GetAnomalies
    @FromDate DATE, @ToDate DATE, @OnlyUndecided BIT = 0, @BranchId INT = NULL
AS BEGIN SET NOCOUNT ON;
    SELECT a.AttendanceId, a.EmployeeId, e.FullName, a.WorkDate,
           a.FirstInUtc, a.LastOutUtc, a.PunchPairs, a.[Status], a.[Source],
           an.AnomalyId, an.[Type], an.[Minutes],
           an.ShiftStartUtc AS ShiftStart, an.ShiftEndUtc AS ShiftEnd,
           an.PunchInUtc AS PunchIn, an.PunchOutUtc AS PunchOut,
           an.Decision, an.DecidedByUserId,
           COALESCE(de.FullName, u.Username) AS DecidedBy,
           an.DecidedAt, an.Note,
           a.DayFraction, a.WorkedMinutes, a.CoveredMinutes, a.StandardMinutes, a.IsManual, a.HasAnomaly,
           ISNULL(a.BranchId, e.BranchId) AS BranchId, b.Name AS BranchName
    FROM attendance.ATTENDANCE_ANOMALY an
    JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = an.AttendanceId
    JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
    LEFT JOIN security.[USER] u ON u.UserId = an.DecidedByUserId
    LEFT JOIN hr.EMPLOYEE de ON de.UserId = an.DecidedByUserId AND de.IsDeleted = 0
    LEFT JOIN hr.BRANCH b ON b.BranchId = ISNULL(a.BranchId, e.BranchId)
    WHERE a.WorkDate BETWEEN @FromDate AND @ToDate
      AND (@OnlyUndecided = 0 OR an.Decision IS NULL)
      AND (@BranchId IS NULL OR ISNULL(a.BranchId, e.BranchId) = @BranchId)
    ORDER BY a.WorkDate, e.FullName, an.[Type]; END;
GO

CREATE OR ALTER PROCEDURE attendance.usp_Anomaly_Decide
    @AnomalyId        BIGINT,
    @Decision         VARCHAR(10),            -- Excuse | Deduct | Correct
    @CorrectedTimeUtc DATETIME2 = NULL,       -- Correct: the punch as it should have been
    @Note             NVARCHAR(300) = NULL,
    @DecidedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Decision NOT IN ('Excuse', 'Deduct', 'Correct')
    BEGIN RAISERROR('Decision must be Excuse, Deduct or Correct.', 16, 1); RETURN; END

    DECLARE @AttId BIGINT, @Emp INT, @D DATE, @Type VARCHAR(20), @Current VARCHAR(10), @IsManual BIT,
            @In DATETIME2, @Out DATETIME2, @Exit INT, @Approved INT, @Branch INT, @HrNote NVARCHAR(300);
    SELECT @AttId = an.AttendanceId, @Emp = an.EmployeeId, @D = an.WorkDate, @Type = an.[Type], @Current = an.Decision,
           @IsManual = a.IsManual, @In = a.FirstInUtc, @Out = a.LastOutUtc, @Exit = a.ExitActualMinutes,
           @Approved = a.ExitApprovedMinutes, @Branch = a.BranchId, @HrNote = a.HrNote
    FROM attendance.ATTENDANCE_ANOMALY an
    JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = an.AttendanceId
    WHERE an.AnomalyId = @AnomalyId;
    IF @AttId IS NULL BEGIN RAISERROR('Anomaly not found.', 16, 1); RETURN; END
    IF @Current = 'Corrected'
    BEGIN RAISERROR('This anomaly was already corrected; the day is manual. Adjust the day itself if it must change again.', 16, 1); RETURN; END
    IF @Type = 'MissingPunch' AND @Decision <> 'Correct'
    BEGIN RAISERROR('A missing punch has no minutes to excuse or deduct: enter the missing time (Correct).', 16, 1); RETURN; END

    IF @Decision IN ('Excuse', 'Deduct')
    BEGIN
        BEGIN TRAN;
        UPDATE attendance.ATTENDANCE_ANOMALY
        SET Decision = CASE @Decision WHEN 'Excuse' THEN 'Excused' ELSE 'Deducted' END,
            DecidedByUserId = @DecidedByUserId, DecidedAt = SYSUTCDATETIME(),
            Note = COALESCE(@Note, Note), UpdatedAt = SYSUTCDATETIME()
        WHERE AnomalyId = @AnomalyId;

        IF @IsManual = 1 EXEC attendance.usp_Attendance_RecomputeManualDay @AttendanceId = @AttId;
        ELSE             EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @D;
        COMMIT TRAN;
    END
    ELSE
    BEGIN
        IF @CorrectedTimeUtc IS NULL
        BEGIN RAISERROR('Correct needs the corrected time.', 16, 1); RETURN; END
        IF CAST(@CorrectedTimeUtc AS DATE) NOT BETWEEN @D AND DATEADD(DAY, 1, @D)
        BEGIN RAISERROR('The corrected time must fall on the work date (or the next day for an overnight shift).', 16, 1); RETURN; END

        DECLARE @NewIn DATETIME2 = @In, @NewOut DATETIME2 = @Out;
        IF @Type = 'LateArrival' SET @NewIn = @CorrectedTimeUtc;
        ELSE IF @Type = 'EarlyDeparture' SET @NewOut = @CorrectedTimeUtc;
        ELSE IF @In IS NULL SET @NewIn = @CorrectedTimeUtc;       -- MissingPunch: fill the missing side
        ELSE SET @NewOut = @CorrectedTimeUtc;
        IF @NewIn IS NOT NULL AND @NewOut IS NOT NULL AND @NewOut <= @NewIn
        BEGIN RAISERROR('The corrected time leaves the out time at or before the in time.', 16, 1); RETURN; END

        BEGIN TRAN;
        /* the decision first, so the manual entry's anomaly sync keeps the row as 'Corrected' */
        UPDATE attendance.ATTENDANCE_ANOMALY
        SET Decision = 'Corrected', DecidedByUserId = @DecidedByUserId, DecidedAt = SYSUTCDATETIME(),
            Note = COALESCE(@Note, CONCAT(N'Punch corrected to ', CONVERT(VARCHAR(16), @CorrectedTimeUtc, 120), N'.')), UpdatedAt = SYSUTCDATETIME()
        WHERE AnomalyId = @AnomalyId;

        DECLARE @ManualNote NVARCHAR(300) = LEFT(COALESCE(@Note, @HrNote, CONCAT(N'Corrected from anomaly #', @AnomalyId, N'.')), 300);
        DECLARE @m TABLE (AttendanceId BIGINT, WorkedMinutes INT, StandardMinutes INT, DayFraction DECIMAL(5,2), IsFullDay BIT,
                          LateMinutes INT, OvertimeMinutes INT, ExitActualMinutes INT, ExitApprovedMinutes INT,
                          ExitVarianceMinutes INT, ExitLeaveMinutes INT, [Status] VARCHAR(20),
                          CoveredMinutes INT, EarlyExitMinutes INT, LateDeductMinutes INT, EarlyDeductMinutes INT, HasAnomaly BIT, IsManual BIT, ShortfallMinutes INT);
        INSERT INTO @m EXEC attendance.usp_Attendance_ManualUpsert
            @EmployeeId = @Emp, @WorkDate = @D, @FirstInUtc = @NewIn, @LastOutUtc = @NewOut,
            @ExitMinutes = @Exit, @ExitApprovedMins = @Approved, @Status = NULL, @BranchId = @Branch, @HrNote = @ManualNote;
        COMMIT TRAN;
    END

    SELECT an.AnomalyId, an.AttendanceId, an.EmployeeId, an.WorkDate, an.[Type], an.[Minutes],
           an.Decision, an.DecidedByUserId, an.DecidedAt, an.Note,
           a.FirstInUtc, a.LastOutUtc, a.WorkedMinutes, a.CoveredMinutes, a.StandardMinutes, a.DayFraction, a.IsFullDay,
           a.LateMinutes, a.LateDeductMinutes, a.EarlyExitMinutes, a.EarlyDeductMinutes, a.IsManual, a.HasAnomaly, a.[Status]
    FROM attendance.ATTENDANCE_ANOMALY an
    JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = an.AttendanceId
    WHERE an.AnomalyId = @AnomalyId;
END;
GO

CREATE OR ALTER PROCEDURE attendance.usp_Anomaly_DecideAll
    @PeriodYearMonth CHAR(7),
    @Decision        VARCHAR(10),             -- Excuse | Deduct
    @BranchId        INT = NULL,
    @Note            NVARCHAR(300) = NULL,
    @DecidedByUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @from DATE = TRY_CAST(@PeriodYearMonth + '-01' AS DATE);
    IF @from IS NULL BEGIN RAISERROR('The month must look like 2026-08.', 16, 1); RETURN; END
    DECLARE @to DATE = EOMONTH(@from);
    IF @Decision NOT IN ('Excuse', 'Deduct')
    BEGIN RAISERROR('Decide-all takes Excuse or Deduct; a correction needs a time for each anomaly.', 16, 1); RETURN; END

    DECLARE @rows TABLE (AnomalyId BIGINT PRIMARY KEY, AttendanceId BIGINT, EmployeeId INT, WorkDate DATE, IsManual BIT);
    INSERT INTO @rows (AnomalyId, AttendanceId, EmployeeId, WorkDate, IsManual)
    SELECT an.AnomalyId, an.AttendanceId, an.EmployeeId, an.WorkDate, a.IsManual
    FROM attendance.ATTENDANCE_ANOMALY an
    JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = an.AttendanceId
    JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
    WHERE an.WorkDate BETWEEN @from AND @to AND an.Decision IS NULL
      AND an.[Type] IN ('LateArrival', 'EarlyDeparture')
      AND (@BranchId IS NULL OR ISNULL(a.BranchId, e.BranchId) = @BranchId);

    DECLARE @Skipped INT = (SELECT COUNT(*) FROM attendance.ATTENDANCE_ANOMALY an
                            JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = an.AttendanceId
                            JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
                            WHERE an.WorkDate BETWEEN @from AND @to AND an.Decision IS NULL AND an.[Type] = 'MissingPunch'
                              AND (@BranchId IS NULL OR ISNULL(a.BranchId, e.BranchId) = @BranchId));

    BEGIN TRAN;

    UPDATE an
    SET an.Decision = CASE @Decision WHEN 'Excuse' THEN 'Excused' ELSE 'Deducted' END,
        an.DecidedByUserId = @DecidedByUserId, an.DecidedAt = SYSUTCDATETIME(),
        an.Note = COALESCE(@Note, an.Note), an.UpdatedAt = SYSUTCDATETIME()
    FROM attendance.ATTENDANCE_ANOMALY an
    JOIN @rows r ON r.AnomalyId = an.AnomalyId;
    DECLARE @Decided INT = @@ROWCOUNT;

    DECLARE @Att BIGINT, @Emp INT, @D DATE, @Manual BIT, @Days INT = 0;
    DECLARE day_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT AttendanceId, EmployeeId, WorkDate, IsManual FROM @rows ORDER BY WorkDate, EmployeeId;
    OPEN day_cur; FETCH NEXT FROM day_cur INTO @Att, @Emp, @D, @Manual;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @Manual = 1 EXEC attendance.usp_Attendance_RecomputeManualDay @AttendanceId = @Att;
        ELSE           EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @D;
        SET @Days += 1;
        FETCH NEXT FROM day_cur INTO @Att, @Emp, @D, @Manual;
    END
    CLOSE day_cur; DEALLOCATE day_cur;

    COMMIT TRAN;

    SELECT @Decided AS Decided, @Skipped AS Skipped, @Days AS DaysRecomputed;
END;
GO

/* ============================================================================
   6. the readiness gate: undecided anomalies block payroll
   ============================================================================ */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_PayrollReadiness
    @PeriodYearMonth CHAR(7)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATE = CAST(@PeriodYearMonth + '-01' AS DATE);
    DECLARE @to   DATE = EOMONTH(@from);

    DECLARE @Unprocessed INT = (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG
        WHERE IsProcessed = 0 AND EmployeeId IS NOT NULL AND CAST(PunchTimeUtc AS DATE) BETWEEN @from AND @to);

    DECLARE @Unresolved INT = (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG
        WHERE EmployeeId IS NULL AND CAST(PunchTimeUtc AS DATE) BETWEEN @from AND @to);

    DECLARE @Anomalies INT = (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD
        WHERE HasAnomaly = 1 AND WorkDate BETWEEN @from AND @to);

    DECLARE @PendingCorr INT = (SELECT COUNT(*)
        FROM attendance.ATTENDANCE_CORRECTION c
        JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = c.AttendanceId
        WHERE c.ApprovalStatus = 'Pending' AND a.WorkDate BETWEEN @from AND @to);

    /* a rostered day is one of an APPROVED roster month — the same gate the day rule applies */
    DECLARE @MissingDays INT = (SELECT COUNT(*)
        FROM attendance.SHIFT_ASSIGNMENT sa
        JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId AND e.IsDeleted = 0
        WHERE sa.WorkDate BETWEEN @from AND @to
          AND EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                      WHERE rm.BranchId = e.BranchId
                        AND rm.MonthDate = DATEFROMPARTS(YEAR(sa.WorkDate), MONTH(sa.WorkDate), 1)
                        AND rm.[Status] = 'Approved')
          AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a
                          WHERE a.EmployeeId = sa.EmployeeId AND a.WorkDate = sa.WorkDate));

    DECLARE @OpenVariances INT = (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD
        WHERE WorkDate BETWEEN @from AND @to
          AND ExitVarianceMinutes > 0
          AND ExitVarianceDisposition IS NULL);

    /* late arrivals / early departures at or beyond the tolerance (and missing punches) HR has not decided */
    DECLARE @Undecided INT = (SELECT COUNT(*) FROM attendance.ATTENDANCE_ANOMALY
        WHERE WorkDate BETWEEN @from AND @to AND Decision IS NULL);

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
        @Undecided       AS UndecidedAnomalies,
        CASE WHEN @Unprocessed = 0 AND @Unresolved = 0 AND @Anomalies = 0
                  AND @PendingCorr = 0 AND @MissingDays = 0 AND @OpenVariances = 0 AND @Undecided = 0
             THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsReady;
END;
GO

/* the list read: expose the new figure (additive) */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_GetByDateRange
    @FromDate DATE, @ToDate DATE, @EmployeeId INT = NULL, @BranchId INT = NULL
AS BEGIN SET NOCOUNT ON;
    SELECT a.AttendanceId, a.EmployeeId, e.FullName, a.WorkDate,
           a.FirstInUtc, a.LastOutUtc, a.PunchPairs,
           a.WorkedMinutes, a.StandardMinutes, a.DayFraction, a.IsFullDay,
           a.LateMinutes, a.OvertimeMinutes, a.ShortfallMinutes,
           a.ExitActualMinutes, a.ExitApprovedMinutes, a.ExitVarianceMinutes,
           a.ExitLeaveMinutes, a.ExitVarianceDisposition,
           a.[Status], a.[Source], a.IsManual, a.HasAnomaly,
           a.BranchId, b.Name AS BranchName, a.HrNote,
           a.LateDeductMinutes, a.EarlyExitMinutes, a.CoveredMinutes, a.EarlyDeductMinutes,
           UndecidedAnomalies = (SELECT COUNT(*) FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId AND an.Decision IS NULL)
    FROM attendance.ATTENDANCE_RECORD a
    JOIN hr.EMPLOYEE e    ON e.EmployeeId = a.EmployeeId
    LEFT JOIN hr.BRANCH b ON b.BranchId = a.BranchId
    WHERE a.WorkDate BETWEEN @FromDate AND @ToDate
      AND (@EmployeeId IS NULL OR a.EmployeeId = @EmployeeId)
      AND (@BranchId  IS NULL OR a.BranchId  = @BranchId)
    ORDER BY a.WorkDate, e.FullName; END;
GO

/* ============================================================================
   7. payroll.usp_PayrollRun_Create — the INSERT-EXEC capture of the readiness gains the
      UndecidedAnomalies column; the refusal names the count. Body otherwise as live.
   ============================================================================ */
/* ── CREATE v3: type-aware ── */
CREATE OR ALTER PROCEDURE payroll.usp_PayrollRun_Create
    @PeriodYearMonth CHAR(7), @CreatedByUserId INT,
    @Notes NVARCHAR(500)=NULL, @RunType VARCHAR(12)='Primary'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF payroll.fn_UserHasRole(@CreatedByUserId, N'HR') = 0
       AND payroll.fn_UserHasRole(@CreatedByUserId, N'Admin') = 0
    BEGIN RAISERROR('Payroll runs are prepared by HR.',16,1); RETURN; END
    IF @RunType NOT IN ('Primary','Supplemental')
    BEGIN RAISERROR('RunType is Primary or Supplemental.',16,1); RETURN; END
    IF @PeriodYearMonth NOT LIKE '[12][0-9][0-9][0-9]-[01][0-9]'
    BEGIN RAISERROR('The period must look like 2026-08.',16,1); RETURN; END

    DECLARE @Start DATE = CAST(@PeriodYearMonth + '-01' AS DATE);
    DECLARE @End   DATE = EOMONTH(@Start);

    IF @RunType = 'Primary'
    BEGIN
        IF EXISTS (SELECT 1 FROM payroll.PAYROLL_RUN
                   WHERE PeriodYearMonth=@PeriodYearMonth
                     AND RunType='Primary' AND [Status] <> 'Cancelled')
        BEGIN
            DECLARE @P1 CHAR(7)=@PeriodYearMonth;
            RAISERROR('A primary run for %s already exists. Cancel it first if it must be redone.',16,1,@P1);
            RETURN;
        END
        DECLARE @Ready TABLE (PeriodYearMonth CHAR(7), PeriodStart DATE, PeriodEnd DATE,
            UnprocessedPunches INT, UnresolvedPinPunches INT, OpenAnomalies INT,
            PendingCorrections INT, RosteredDaysWithNoRecord INT, UndecidedExitVariances INT,
            UndecidedAnomalies INT, IsReady BIT);
        INSERT INTO @Ready EXEC attendance.usp_Attendance_PayrollReadiness @PeriodYearMonth;
        /* script 77: undecided late / early / missing-punch anomalies are named first, with their count */
        DECLARE @Undecided INT = (SELECT UndecidedAnomalies FROM @Ready);
        IF @Undecided > 0
        BEGIN
            DECLARE @P2a CHAR(7)=@PeriodYearMonth;
            DECLARE @Plural VARCHAR(3) = CASE WHEN @Undecided = 1 THEN 'y' ELSE 'ies' END;
            RAISERROR('Attendance for %s has %d undecided anomal%s (late arrival, early departure or missing punch). Decide them in Attendance > Anomalies before running payroll.',16,1,@P2a,@Undecided,@Plural);
            RETURN;
        END
        IF (SELECT IsReady FROM @Ready) = 0
        BEGIN
            DECLARE @P2 CHAR(7)=@PeriodYearMonth;
            RAISERROR('Attendance for %s is not ready for payroll. Open the readiness check and clear the counts.',16,1,@P2);
            RETURN;
        END
    END
    ELSE
    BEGIN
        /* a supplemental follows a LOCKED primary, and pays only signed corrections */
        IF NOT EXISTS (SELECT 1 FROM payroll.PAYROLL_RUN
                       WHERE PeriodYearMonth=@PeriodYearMonth
                         AND RunType='Primary' AND [Status]='Approved')
        BEGIN
            DECLARE @P3 CHAR(7)=@PeriodYearMonth;
            RAISERROR('A supplemental follows an approved primary. The %s primary is not locked yet - put the money in it and regenerate.',16,1,@P3);
            RETURN;
        END
        IF EXISTS (SELECT 1 FROM payroll.PAYROLL_RUN
                   WHERE PeriodYearMonth=@PeriodYearMonth
                     AND RunType='Supplemental' AND [Status] IN ('Draft','Review'))
        BEGIN RAISERROR('An open supplemental for this period already exists - finish or cancel it first.',16,1); RETURN; END
        IF NOT EXISTS (SELECT 1 FROM payroll.PAYROLL_ADJUSTMENT
                       WHERE TargetPeriod=@PeriodYearMonth AND AppliedToPayslipId IS NULL)
        BEGIN RAISERROR('No approved, unconsumed adjustments target this period - there is nothing for a supplemental to pay.',16,1); RETURN; END
    END

    DECLARE @Primary CHAR(3) = ISNULL((SELECT SettingValue FROM core.SETTING
                                       WHERE SettingKey='PayrollPrimaryCurrency'),'USD');
    DECLARE @RateType VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING
                                            WHERE SettingKey='PayrollRateType'),'Official');

    BEGIN TRAN;
    INSERT INTO payroll.PAYROLL_RUN
        (PeriodYearMonth,PeriodStart,PeriodEnd,PrimaryCurrency,Notes,CreatedByUserId,RunType)
    VALUES (@PeriodYearMonth,@Start,@End,@Primary,@Notes,@CreatedByUserId,@RunType);
    DECLARE @RunId INT = SCOPE_IDENTITY();

    ;WITH ccy AS (
        SELECT DISTINCT CurrencyCode FROM hr.SALARY_COMPONENT WHERE EffectiveTo IS NULL
        UNION SELECT CurrencyCode FROM workflow.TIP_DISTRIBUTION_AMOUNT
        UNION SELECT CurrencyCode FROM workflow.EXPENSE_REIMBURSEMENT
        UNION SELECT CurrencyCode FROM payroll.SALARY_ADVANCE WHERE IsSettled=0
        UNION SELECT CurrencyCode FROM payroll.PAYROLL_ADJUSTMENT WHERE AppliedToPayslipId IS NULL
        UNION SELECT @Primary
    )
    INSERT INTO payroll.PAYROLL_RUN_RATE
        (PayrollRunId,FromCurrency,ToCurrency,Rate,RateType,SourceEffectiveDate)
    SELECT @RunId, c.CurrencyCode, @Primary, x.Rate, x.RateType, x.EffectiveDate
    FROM ccy c
    CROSS APPLY (
        SELECT TOP 1
               CASE WHEN er.FromCurrency=c.CurrencyCode THEN er.Rate ELSE 1.0/er.Rate END AS Rate,
               er.RateType, er.EffectiveDate
        FROM core.EXCHANGE_RATE er
        WHERE ((er.FromCurrency=c.CurrencyCode AND er.ToCurrency=@Primary)
            OR (er.FromCurrency=@Primary AND er.ToCurrency=c.CurrencyCode))
          AND er.RateType=@RateType AND er.EffectiveDate <= @End
        ORDER BY er.EffectiveDate DESC, er.ExchangeRateId DESC
    ) x
    WHERE c.CurrencyCode <> @Primary;

    IF @RunType='Primary'
    BEGIN
        DECLARE @NoRate CHAR(3) = (
            SELECT TOP 1 sc.CurrencyCode FROM hr.SALARY_COMPONENT sc
            WHERE sc.EffectiveTo IS NULL AND sc.CurrencyCode <> @Primary
              AND NOT EXISTS (SELECT 1 FROM payroll.PAYROLL_RUN_RATE r
                              WHERE r.PayrollRunId=@RunId AND r.FromCurrency=sc.CurrencyCode));
        IF @NoRate IS NOT NULL
        BEGIN
            ROLLBACK TRAN;
            DECLARE @P4 CHAR(3)=@NoRate; DECLARE @P5 VARCHAR(20)=@RateType;
            RAISERROR('No %s rate of type %s is on file. Add the rate, then create the run.',16,1,@P4,@P5);
            RETURN;
        END
    END

    INSERT INTO payroll.PAYROLL_RUN_EVENT (PayrollRunId,[Action],ActedByUserId,Detail)
    VALUES (@RunId,'Created',@CreatedByUserId,
            CONCAT(@RunType,N' run for ',@PeriodYearMonth,N', rates frozen'));
    COMMIT TRAN;

    SELECT @RunId AS PayrollRunId, @PeriodYearMonth AS PeriodYearMonth,
           'Draft' AS [Status], @Primary AS PrimaryCurrency, @RunType AS RunType;
END;
GO

/* ============================================================================
   8. MIGRATION — MissingPunch rows for every HasAnomaly record; the previous and current
      month re-derived so the tolerance classification lands in the anomaly table; an early
      departure HR had already dispositioned as an exit variance keeps that decision. Prints
      every employee-day that gained an anomaly row. Idempotent: a second run changes nothing.
   ============================================================================ */
SET NOCOUNT ON;
DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);
DECLARE @From DATE = DATEADD(MONTH, -1, DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1));
DECLARE @To   DATE = EOMONTH(@Today);

/* the existing kind: an unpaired / missing punch, on any date */
INSERT INTO attendance.ATTENDANCE_ANOMALY (AttendanceId, EmployeeId, WorkDate, [Type], [Minutes], PunchInUtc, PunchOutUtc)
SELECT a.AttendanceId, a.EmployeeId, a.WorkDate, 'MissingPunch', 0, a.FirstInUtc, a.LastOutUtc
FROM attendance.ATTENDANCE_RECORD a
WHERE a.HasAnomaly = 1
  AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId AND an.[Type] = 'MissingPunch');
PRINT CONCAT('MIGRATION | MissingPunch rows created for existing HasAnomaly records: ', @@ROWCOUNT);

/* HR's exit-variance dispositions of early departures under script 76 (the variance was the early exit) */
IF OBJECT_ID('tempdb..#disp') IS NOT NULL DROP TABLE #disp;
SELECT a.AttendanceId, a.ExitVarianceDisposition AS Disposition
INTO #disp
FROM attendance.ATTENDANCE_RECORD a
WHERE a.WorkDate BETWEEN @From AND @To AND a.IsManual = 0
  AND a.ExitVarianceDisposition IS NOT NULL AND a.EarlyExitMinutes > 0;

IF OBJECT_ID('tempdb..#before') IS NOT NULL DROP TABLE #before;
SELECT AnomalyId, AttendanceId, [Type], [Minutes], Decision INTO #before FROM attendance.ATTENDANCE_ANOMALY;

DECLARE @D DATE = @From, @Days INT = 0, @n INT;
WHILE @D <= @To
BEGIN
    EXEC attendance.usp_Attendance_ReprocessDay @WorkDate = @D, @Quiet = 1, @DaysOut = @n OUTPUT;
    SET @Days += ISNULL(@n, 0);
    SET @D = DATEADD(DAY, 1, @D);
END

/* carry HR's earlier ruling over to the anomaly it now is, then re-derive those days once more */
UPDATE an
SET an.Decision = CASE WHEN d.Disposition = 'UnpaidAbsence' THEN 'Deducted' ELSE 'Excused' END,
    an.DecidedAt = SYSUTCDATETIME(),
    an.Note = CONCAT(N'Carried over from the exit-variance disposition ', d.Disposition, N' (script 77).'),
    an.UpdatedAt = SYSUTCDATETIME()
FROM attendance.ATTENDANCE_ANOMALY an
JOIN #disp d ON d.AttendanceId = an.AttendanceId
WHERE an.[Type] = 'EarlyDeparture' AND an.Decision IS NULL;
DECLARE @Carried INT = @@ROWCOUNT;
IF @Carried > 0
BEGIN
    DECLARE @Emp INT, @WD DATE;
    DECLARE c_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT a.EmployeeId, a.WorkDate FROM attendance.ATTENDANCE_RECORD a JOIN #disp d ON d.AttendanceId = a.AttendanceId;
    OPEN c_cur; FETCH NEXT FROM c_cur INTO @Emp, @WD;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @WD;
        FETCH NEXT FROM c_cur INTO @Emp, @WD;
    END
    CLOSE c_cur; DEALLOCATE c_cur;
END

DECLARE @CntBefore INT = (SELECT COUNT(*) FROM #before), @CntAfter INT = (SELECT COUNT(*) FROM attendance.ATTENDANCE_ANOMALY);
PRINT CONCAT('MIGRATION | window ', CONVERT(VARCHAR(10), @From, 23), ' .. ', CONVERT(VARCHAR(10), @To, 23),
             ' | employee-days re-derived: ', @Days,
             ' | anomaly rows before: ', @CntBefore, ' after: ', @CntAfter,
             ' | early-departure decisions carried over from exit-variance dispositions: ', @Carried);

DECLARE @line NVARCHAR(400);
DECLARE g_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT CONCAT('MIGRATION | anomaly gained: ', e.FullName, ' (', an.EmployeeId, ') ', CONVERT(VARCHAR(10), an.WorkDate, 23),
                  ' | ', an.[Type], ' ', an.[Minutes], ' min | decision ', ISNULL(an.Decision, 'undecided'),
                  CASE WHEN an.Note IS NOT NULL THEN CONCAT(' | ', an.Note) ELSE '' END)
    FROM attendance.ATTENDANCE_ANOMALY an
    JOIN hr.EMPLOYEE e ON e.EmployeeId = an.EmployeeId
    WHERE NOT EXISTS (SELECT 1 FROM #before b WHERE b.AnomalyId = an.AnomalyId)
    ORDER BY an.WorkDate, e.FullName, an.[Type];
OPEN g_cur; FETCH NEXT FROM g_cur INTO @line;
IF @@FETCH_STATUS <> 0 PRINT 'MIGRATION | no employee-day gained an anomaly row';
WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM g_cur INTO @line; END
CLOSE g_cur; DEALLOCATE g_cur;

DECLARE @Lost INT = (SELECT COUNT(*) FROM #before b WHERE NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AnomalyId = b.AnomalyId));
PRINT CONCAT('MIGRATION | anomaly rows removed by the re-derivation: ', @Lost);
DROP TABLE #before; DROP TABLE #disp;
GO
