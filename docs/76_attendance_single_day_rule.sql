/* ============================================================================
   76_attendance_single_day_rule.sql — ONE rule for an attendance day.

   Five procedures used to compute the same employee-day (ProcessRawLogs,
   ReprocessDay, SetExitApproval, MarkLeaveDays, MarkAbsentees) and disagreed.
   The rule now lives in ONE place and every path calls it:

     attendance.fn_AttendanceDayRule (inline TVF, pure arithmetic, unit-tested)
       in : the rostered shift (start/end/break/grace/standard), FirstIn, LastOut,
            the mid-day gaps, the approved exit minutes, HR's disposition, the
            approved overtime, the LateDeductionBasis and FullDayThreshold
            settings, and the day's kind (rest day / leave / holiday)
       out: Status, EffectiveIn, LateMinutes, LateDeductMinutes, EarlyExitMinutes,
            MidDayGapMinutes, ExitActualMinutes, ExitVarianceMinutes,
            OvertimeMinutes, WorkedMinutes, CoveredMinutes, DayFraction,
            IsFullDay, ShortfallMinutes, BreakApplied
     attendance.usp_Attendance_ComputeDay (@EmployeeId, @WorkDate) — the ONE writer
       gathers the inputs (punches attributed to the day by fn_AttributedWorkDate,
       debounced and directed exactly as before; the roster — only when its month
       is Approved; the approved LEAVE_REQUEST covering the day; the approved
       EXIT_PERMISSION minutes; HR's stored figures on the record) and upserts the
       record and its ATTENDANCE_INTERVAL rows. A manual row (IsManual = 1) is
       never touched. No punches + no rostered shift + no record → nothing.

   The rule (Standard = End − Start − Break):
     EffectiveIn         = max(FirstIn, ShiftStart)               (BUG-16: early arrival never counts)
                           pre-shift minutes count as OVERTIME only as far as an
                           approved OVERTIME request is not already used up by
                           post-shift minutes
     LateMinutes         = FirstIn > ShiftStart + Grace ? FirstIn − ShiftStart : 0   (BUG-15: grace is a threshold)
     LateDeductMinutes   = LateDeductionBasis: BeyondGrace (default) → max(0, FirstIn − (ShiftStart + Grace))
                                               Full → LateMinutes | None → 0
     EarlyExitMinutes    = max(0, ShiftEnd − LastOut)             (BUG-12: leaving early IS an exit variance)
     MidDayGapMinutes    = max(0, Σ gaps − Break)
     ExitActualMinutes   = MidDayGapMinutes + EarlyExitMinutes
     ExitApprovedMinutes = HR's own figure if HR set one (ExitHrApprovedMinutes), else
                           Σ approved EXIT_PERMISSION minutes for the day — recomputed on
                           EVERY run (BUG-11), never stored once and lost
     ExitVarianceMinutes = ExitActualMinutes − ExitApprovedMinutes  (queued when > 0 and undecided)
     OvertimeMinutes     = max(0, LastOut − ShiftEnd) (+ covered pre-shift minutes, above)
     WorkedMinutes       = (min(LastOut, ShiftEnd) − EffectiveIn) − Break − MidDayGapMinutes
                           presence inside the shift; NEVER reduced by an approval (BUG-13)
     CoveredMinutes      = min(ExitActualMinutes, ExitApprovedMinutes)     approved permission protects pay
                         + (arrival minutes after ShiftStart − LateDeductMinutes)  grace protects pay
                         + the variance when HR's disposition is Ignore or Overtime (BUG-14;
                           UnpaidAbsence adds nothing)
     DayFraction         = min(1, (WorkedMinutes + CoveredMinutes) / Standard), IsFullDay by FullDayThreshold
     Status              : approved LEAVE_REQUEST covering the day → 'Leave', DayFraction NULL, whatever
                           the punches say (BUG-08/BUG-09); rostered rest day → 'RestDay', NULL (BUG-06);
                           public holiday (table hr.PUBLIC_HOLIDAY(HolidayDate) if it exists) → 'Holiday',
                           NULL; no shift rostered → no record and no absence; else Present / Absent.

   Callers:
     usp_Attendance_ProcessRawLogs   — the affected employee-days → ComputeDay; marks punches consumed.
     usp_Attendance_ReprocessDay     — flips and re-derives the punches whose ATTRIBUTED day is
                                       @WorkDate (BUG-10: overnight out-punches were stranded), and
                                       re-derives the day's existing non-manual records too.
     usp_Attendance_SetExitApproval  — stores HR's approved minutes (+ disposition, note) and re-runs
                                       ComputeDay; never touches WorkedMinutes (BUG-13). @AlsoSetActual
                                       is accepted for compatibility and ignored.
     usp_Attendance_SetExitDisposition — stores the disposition (and HR's leave-minutes override) and
                                       re-runs ComputeDay; no longer flags the row IsManual.
     workflow.usp_ExitPermission_ApplyToAttendance — idempotent: re-runs ComputeDay for the permission's
                                       day and stamps AppliedToAttendanceAt (BUG-11).
     usp_Attendance_MarkLeaveDays    — every day of every approved range in the month (BUG-08),
                                       overriding Present as well as Absent (BUG-09).
     usp_Attendance_MarkAbsentees    — rostered employee-days without a record → ComputeDay
                                       (RestDay rows get DayFraction NULL).
   Schema: ATTENDANCE_RECORD.DayFraction is NULLable; new columns EarlyExitMinutes,
   LateDeductMinutes, CoveredMinutes, ExitHrApprovedMinutes, ExitLeaveOverrideMinutes.
   Setting: LateDeductionBasis = 'BeyondGrace' (DataType enum:BeyondGrace|Full|None, which the
   Settings page renders as a select; core.SETTING.DataType widened to VARCHAR(60)).
   Migration at the end: re-derives the previous and current month for every employee
   (ReprocessDay loop) and prints what changed. Nothing else is rewritten.
   Every refusal is RAISERROR(msg,16,1) + RETURN. Idempotent. Run with sqlcmd -I.
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ============================================================================
   0. schema
   ============================================================================ */
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('attendance.ATTENDANCE_RECORD') AND name = 'DayFraction' AND is_nullable = 0)
    ALTER TABLE attendance.ATTENDANCE_RECORD ALTER COLUMN DayFraction DECIMAL(5,2) NULL;
IF COL_LENGTH('attendance.ATTENDANCE_RECORD', 'EarlyExitMinutes') IS NULL
    ALTER TABLE attendance.ATTENDANCE_RECORD ADD EarlyExitMinutes INT NOT NULL CONSTRAINT DF_AttRec_EarlyExit DEFAULT (0);
IF COL_LENGTH('attendance.ATTENDANCE_RECORD', 'LateDeductMinutes') IS NULL
    ALTER TABLE attendance.ATTENDANCE_RECORD ADD LateDeductMinutes INT NOT NULL CONSTRAINT DF_AttRec_LateDeduct DEFAULT (0);
IF COL_LENGTH('attendance.ATTENDANCE_RECORD', 'CoveredMinutes') IS NULL
    ALTER TABLE attendance.ATTENDANCE_RECORD ADD CoveredMinutes INT NOT NULL CONSTRAINT DF_AttRec_Covered DEFAULT (0);
IF COL_LENGTH('attendance.ATTENDANCE_RECORD', 'ExitHrApprovedMinutes') IS NULL
BEGIN
    ALTER TABLE attendance.ATTENDANCE_RECORD ADD ExitHrApprovedMinutes INT NULL;      -- HR's own approval (SetExitApproval); NULL = use the permissions
    /* carry over the approvals HR typed in by hand (an approved figure with no approved permission
       behind it) so the re-derivation below does not lose them */
    EXEC sp_executesql N'
        UPDATE a SET a.ExitHrApprovedMinutes = a.ExitApprovedMinutes
        FROM attendance.ATTENDANCE_RECORD a
        WHERE a.ExitApprovedMinutes > 0
          AND NOT EXISTS (SELECT 1 FROM workflow.EXIT_PERMISSION ep
                          JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ep.RequestInstanceId
                          WHERE ep.EmployeeId = a.EmployeeId AND ep.ExitDate = a.WorkDate AND ri.[Status] = ''Approved'')';
END
IF COL_LENGTH('attendance.ATTENDANCE_RECORD', 'ExitLeaveOverrideMinutes') IS NULL
    ALTER TABLE attendance.ATTENDANCE_RECORD ADD ExitLeaveOverrideMinutes INT NULL;   -- HR's override of the leave minutes (SetExitDisposition)
GO

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('core.SETTING') AND name = 'DataType' AND max_length < 60)
    ALTER TABLE core.SETTING ALTER COLUMN DataType VARCHAR(60) NOT NULL;
GO

CREATE OR ALTER PROCEDURE core.usp_Setting_Upsert
    @SettingKey VARCHAR(60), @SettingValue NVARCHAR(200),
    @DataType VARCHAR(60) = 'string', @Description NVARCHAR(300) = NULL,
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

/* the setting: how a late arrival reduces the paid day */
IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'LateDeductionBasis')
    INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, [Description], Section, SortOrder, ModifiedAt)
    VALUES ('LateDeductionBasis', 'BeyondGrace', 'enum:BeyondGrace|Full|None',
            N'How a late arrival reduces the paid day. BeyondGrace = only the minutes after the grace period are deducted (default). Full = every minute after the shift start is deducted once the grace is exceeded. None = lateness is recorded but never deducted. Arrivals inside the grace are never deducted.',
            'Attendance', 21, SYSUTCDATETIME());
ELSE
    UPDATE core.SETTING
    SET DataType = 'enum:BeyondGrace|Full|None', Section = 'Attendance'
    WHERE SettingKey = 'LateDeductionBasis' AND (DataType <> 'enum:BeyondGrace|Full|None' OR Section <> 'Attendance');
GO

/* ============================================================================
   1. THE RULE — pure arithmetic, no table access, so every line has a unit test
      (MokaCo.HRMS.Tests/Attendance/AttendanceDayRuleTests.cs).
   ============================================================================ */
CREATE OR ALTER FUNCTION attendance.fn_AttendanceDayRule
(
    @ShiftStartUtc           DATETIME2,     -- NULL = no rostered shift (default standard day; no late / early-exit rule)
    @ShiftEndUtc             DATETIME2,     -- already on the next day for a shift that crosses midnight
    @BreakMinutes            INT,
    @GraceMinutes            INT,
    @StandardMinutes         INT,           -- End − Start − Break, or the default standard day when there is no shift
    @FirstInUtc              DATETIME2,
    @LastOutUtc              DATETIME2,
    @GapMinutes              INT,           -- Σ mid-day out→in gaps between paired intervals
    @ExitApprovedMinutes     INT,           -- HR's figure, else Σ approved exit permissions for the day
    @Disposition             VARCHAR(20),   -- HR's disposition of the variance: UnpaidAbsence | Overtime | Ignore | NULL
    @OvertimeApprovedMinutes INT,           -- Σ approved OVERTIME_REQUEST minutes for the day
    @LateBasis               VARCHAR(20),   -- BeyondGrace | Full | None
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
        LateMinutes        = CASE WHEN s4.Measured = 1 THEN s3.LateMinutes ELSE 0 END,
        LateDeductMinutes  = CASE WHEN s4.Measured = 1 THEN s3.LateDeductMinutes ELSE 0 END,
        EarlyExitMinutes   = CASE WHEN s4.Measured = 1 THEN s2.EarlyExitMinutes ELSE 0 END,
        MidDayGapMinutes   = CASE WHEN s4.Measured = 1 THEN s2.MidDayGapMinutes ELSE 0 END,
        ExitActualMinutes  = CASE WHEN s4.Measured = 1 THEN s3.ExitActualMinutes ELSE 0 END,
        ExitApprovedMinutes = s0.Approved,
        ExitVarianceMinutes = CASE WHEN s4.Measured = 1 THEN s3.ExitVarianceMinutes ELSE 0 END,
        OvertimeMinutes    = CASE WHEN s4.Measured = 1 THEN s3.OvertimeMinutes ELSE 0 END,
        WorkedMinutes      = s3.WorkedMinutes,                          -- informational on a rest / leave day
        CoveredMinutes     = CASE WHEN s4.Measured = 1 THEN s3.CoveredMinutes ELSE 0 END,
        DayFraction        = s4.DayFraction,
        IsFullDay          = CAST(CASE WHEN s4.DayFraction IS NOT NULL AND s4.DayFraction >= ISNULL(@FullDayThreshold, 1.00) THEN 1 ELSE 0 END AS BIT),
        ShortfallMinutes   = CASE WHEN s4.Measured = 1 AND s0.Standard - s3.WorkedMinutes - s3.CoveredMinutes > 0
                                  THEN s0.Standard - s3.WorkedMinutes - s3.CoveredMinutes ELSE 0 END,
        BreakApplied       = CASE WHEN @FirstInUtc IS NOT NULL THEN s0.BreakMin ELSE 0 END,
        StandardMinutes    = s0.Standard
    FROM (SELECT
              BreakMin   = ISNULL(@BreakMinutes, 0),
              Grace      = ISNULL(@GraceMinutes, 0),
              Approved   = ISNULL(@ExitApprovedMinutes, 0),
              OtApproved = ISNULL(@OvertimeApprovedMinutes, 0),
              Gap        = ISNULL(@GapMinutes, 0),
              Basis      = ISNULL(@LateBasis, 'BeyondGrace'),
              HasShift   = CASE WHEN @ShiftStartUtc IS NOT NULL AND @ShiftEndUtc IS NOT NULL THEN 1 ELSE 0 END,
              Standard   = CASE WHEN ISNULL(@IsRestDay, 0) = 1 THEN 0 ELSE ISNULL(@StandardMinutes, 0) END
         ) s0
    CROSS APPLY (SELECT
              /* the arrival minutes after the shift start (inside or beyond the grace) */
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
              EarlyExitMinutes = CASE WHEN @LastOutUtc IS NULL OR s0.HasShift = 0 OR @LastOutUtc >= @ShiftEndUtc THEN 0
                                      WHEN DATEDIFF(MINUTE, @LastOutUtc, @ShiftEndUtc) > DATEDIFF(MINUTE, @ShiftStartUtc, @ShiftEndUtc)
                                           THEN DATEDIFF(MINUTE, @ShiftStartUtc, @ShiftEndUtc)
                                      ELSE DATEDIFF(MINUTE, @LastOutUtc, @ShiftEndUtc) END,
              MidDayGapMinutes = CASE WHEN s0.Gap - s0.BreakMin > 0 THEN s0.Gap - s0.BreakMin ELSE 0 END
         ) s2
    CROSS APPLY (SELECT
              LateMinutes = CASE WHEN s2.RawLate > s0.Grace THEN s2.RawLate ELSE 0 END,
              LateDeductMinutes = CASE WHEN s2.RawLate <= s0.Grace THEN 0
                                       WHEN s0.Basis = 'Full' THEN s2.RawLate
                                       WHEN s0.Basis = 'None' THEN 0
                                       ELSE s2.RawLate - s0.Grace END,
              WorkedMinutes = CASE WHEN s2.EffectiveInUtc IS NULL OR s2.EffectiveOutUtc IS NULL THEN 0
                                   WHEN DATEDIFF(MINUTE, s2.EffectiveInUtc, s2.EffectiveOutUtc) - s0.BreakMin - s2.MidDayGapMinutes > 0
                                        THEN DATEDIFF(MINUTE, s2.EffectiveInUtc, s2.EffectiveOutUtc) - s0.BreakMin - s2.MidDayGapMinutes
                                   ELSE 0 END,
              ExitActualMinutes = s2.MidDayGapMinutes + s2.EarlyExitMinutes
         ) s3a
    CROSS APPLY (SELECT
              s3a.LateMinutes, s3a.LateDeductMinutes, s3a.WorkedMinutes, s3a.ExitActualMinutes,
              ExitVarianceMinutes = s3a.ExitActualMinutes - s0.Approved,
              OvertimeMinutes = CASE WHEN s0.HasShift = 0
                                     THEN CASE WHEN s3a.WorkedMinutes - s0.Standard > 0 THEN s3a.WorkedMinutes - s0.Standard ELSE 0 END
                                     ELSE s2.PostShift
                                          + CASE WHEN s0.OtApproved - s2.PostShift <= 0 THEN 0
                                                 WHEN s2.PreShift < s0.OtApproved - s2.PostShift THEN s2.PreShift
                                                 ELSE s0.OtApproved - s2.PostShift END
                                END,
              CoveredMinutes = CASE WHEN s3a.ExitActualMinutes < s0.Approved THEN s3a.ExitActualMinutes ELSE s0.Approved END
                             + CASE WHEN @Disposition IN ('Ignore', 'Overtime') AND s3a.ExitActualMinutes - s0.Approved > 0
                                    THEN s3a.ExitActualMinutes - s0.Approved ELSE 0 END
                             + (s2.RawLate - s3a.LateDeductMinutes)
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
                                 WHEN s3.WorkedMinutes + s3.CoveredMinutes >= s0.Standard THEN CAST(1.00 AS DECIMAL(5,2))
                                 ELSE CAST(ROUND(CAST(s3.WorkedMinutes + s3.CoveredMinutes AS DECIMAL(12,4)) / s0.Standard, 2) AS DECIMAL(5,2)) END
         ) s4;
GO

/* ============================================================================
   2. THE WRITER — gathers the inputs for one employee-day, applies the rule,
      upserts the record and its intervals. Manual rows are never touched.
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

    DECLARE @EmpBranch INT, @EmpDeleted BIT;
    SELECT @EmpBranch = BranchId, @EmpDeleted = IsDeleted FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId;
    IF @EmpBranch IS NULL AND @EmpDeleted IS NULL RETURN;              -- no such employee

    /* ---- settings ---- */
    DECLARE @StdDefault INT = core.fn_StandardDayMinutes();
    DECLARE @LeaveBasis VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'ExitLeaveBasis'), 'Actual');
    DECLARE @LateBasis  VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'LateDeductionBasis'), 'BeyondGrace');
    DECLARE @FullDayThreshold DECIMAL(5,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'FullDayThreshold') AS DECIMAL(5,2)), 1.00);
    DECLARE @Mode VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'PunchDirectionMode'), 'Device');
    DECLARE @DebounceSec INT = 60 * ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'PunchDebounceMinutes') AS INT), 0);

    /* ---- the rostered shift: the roster is INERT until its month is Approved ---- */
    DECLARE @Sa INT, @IsRest BIT = 0, @ShiftStart TIME, @ShiftEnd TIME, @Grace INT = 0, @Break INT = 0, @Crosses BIT = 0;
    SELECT @Sa = sa.ShiftAssignmentId, @IsRest = ISNULL(sa.IsRestDay, 0),
           @ShiftStart = s.StartTime, @ShiftEnd = s.EndTime,
           @Grace = ISNULL(s.GraceMinutes, 0), @Break = ISNULL(s.BreakMinutes, 0), @Crosses = ISNULL(s.CrossesMidnight, 0)
    FROM attendance.SHIFT_ASSIGNMENT sa
    LEFT JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
    WHERE sa.EmployeeId = @EmployeeId AND sa.WorkDate = @WorkDate
      AND EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                  WHERE rm.BranchId = @EmpBranch
                    AND rm.MonthDate = DATEFROMPARTS(YEAR(@WorkDate), MONTH(@WorkDate), 1)
                    AND rm.[Status] = 'Approved');
    IF @IsRest = 1 SELECT @ShiftStart = NULL, @ShiftEnd = NULL, @Grace = 0, @Break = 0;

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
                      CoveredMinutes INT, DayFraction DECIMAL(5,2), IsFullDay BIT, ShortfallMinutes INT, BreakApplied INT, StandardMinutes INT);
    INSERT INTO @r
    SELECT [Status], LateMinutes, LateDeductMinutes, EarlyExitMinutes, MidDayGapMinutes,
           ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes, OvertimeMinutes, WorkedMinutes,
           CoveredMinutes, DayFraction, IsFullDay, ShortfallMinutes, BreakApplied, StandardMinutes
    FROM attendance.fn_AttendanceDayRule(@ShiftStartUtc, @ShiftEndUtc, @Break, @Grace, @Standard,
                                         @FirstIn, @LastOut, @Gap, @Approved, @Disposition, @OtApproved,
                                         @LateBasis, @FullDayThreshold, @IsRest, @OnLeave, @Holiday);

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
             CoveredMinutes, OvertimeMinutes, ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes, ExitLeaveMinutes,
             ExitPermissionId, [Status], [Source], DeviceId, BranchId, HasAnomaly, IsManual, ProcessedUtc)
        SELECT @EmployeeId, @Sa, @WorkDate, @FirstIn, @LastOut, @Pairs, @Gross, @Gap, r.BreakApplied,
               r.WorkedMinutes, r.StandardMinutes, r.DayFraction, r.IsFullDay, r.ShortfallMinutes, r.LateMinutes, r.LateDeductMinutes, r.EarlyExitMinutes,
               r.CoveredMinutes, r.OvertimeMinutes, r.ExitActualMinutes, r.ExitApprovedMinutes, r.ExitVarianceMinutes, @ExitLeave,
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
            a.LateDeductMinutes = r.LateDeductMinutes, a.EarlyExitMinutes = r.EarlyExitMinutes, a.CoveredMinutes = r.CoveredMinutes,
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

    COMMIT TRAN;
END;
GO

/* ============================================================================
   3. the processor and the re-processor
   ============================================================================ */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_ProcessRawLogs
    @WorkDate DATE = NULL,                     -- NULL = every unprocessed punch
    @Quiet    BIT  = 0,                        -- 1 = no result set (internal callers)
    @DaysOut  INT  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* the employee-days that have anything NEW, by ATTRIBUTED date; each is then re-derived from ALL its punches */
    DECLARE @day TABLE (EmployeeId INT, WorkDate DATE, PRIMARY KEY (EmployeeId, WorkDate));
    INSERT INTO @day (EmployeeId, WorkDate)
    SELECT DISTINCT r.EmployeeId, attendance.fn_AttributedWorkDate(r.EmployeeId, r.PunchTimeUtc)
    FROM attendance.RAW_DEVICE_LOG r
    WHERE r.IsProcessed = 0 AND r.EmployeeId IS NOT NULL
      AND (@WorkDate IS NULL OR attendance.fn_AttributedWorkDate(r.EmployeeId, r.PunchTimeUtc) = @WorkDate);

    DECLARE @Emp INT, @D DATE, @n INT = 0;
    DECLARE day_cur CURSOR LOCAL FAST_FORWARD FOR SELECT EmployeeId, WorkDate FROM @day ORDER BY WorkDate, EmployeeId;
    OPEN day_cur; FETCH NEXT FROM day_cur INTO @Emp, @D;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @D;
        SET @n += 1;
        FETCH NEXT FROM day_cur INTO @Emp, @D;
    END
    CLOSE day_cur; DEALLOCATE day_cur;

    /* mark exactly the raw rows consumed (debounced ones included — they were part of the day just derived) */
    UPDATE r SET r.IsProcessed = 1
    FROM attendance.RAW_DEVICE_LOG r
    JOIN @day d ON d.EmployeeId = r.EmployeeId AND d.WorkDate = attendance.fn_AttributedWorkDate(r.EmployeeId, r.PunchTimeUtc)
    WHERE r.IsProcessed = 0;

    SET @DaysOut = @n;
    IF @Quiet = 0 SELECT @n AS EmployeeDaysProcessed;
END;
GO

CREATE OR ALTER PROCEDURE attendance.usp_Attendance_ReprocessDay
    @WorkDate   DATE,
    @EmployeeId INT = NULL,                    -- NULL = every employee with punches or a record on that day
    @Quiet      BIT = 0,
    @DaysOut    INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @WorkDate IS NULL BEGIN RAISERROR('WorkDate is required.', 16, 1); RETURN; END

    /* BUG-10: the punches of the day are the ones ATTRIBUTED to it (an overnight
       shift's out-punch is on the next calendar date), not CAST(PunchTimeUtc AS DATE) */
    DECLARE @raw TABLE (RawLogId BIGINT PRIMARY KEY, EmployeeId INT);
    INSERT INTO @raw (RawLogId, EmployeeId)
    SELECT r.RawLogId, r.EmployeeId
    FROM attendance.RAW_DEVICE_LOG r
    WHERE r.EmployeeId IS NOT NULL
      AND (@EmployeeId IS NULL OR r.EmployeeId = @EmployeeId)
      AND r.PunchTimeUtc >= CAST(@WorkDate AS DATETIME2)
      AND r.PunchTimeUtc <  CAST(DATEADD(DAY, 2, @WorkDate) AS DATETIME2)
      AND attendance.fn_AttributedWorkDate(r.EmployeeId, r.PunchTimeUtc) = @WorkDate;

    UPDATE r SET r.IsProcessed = 0 FROM attendance.RAW_DEVICE_LOG r JOIN @raw x ON x.RawLogId = r.RawLogId;

    DECLARE @emps TABLE (EmployeeId INT PRIMARY KEY);
    INSERT INTO @emps (EmployeeId)
    SELECT EmployeeId FROM @raw
    UNION
    SELECT a.EmployeeId FROM attendance.ATTENDANCE_RECORD a
    WHERE a.WorkDate = @WorkDate AND a.IsManual = 0 AND (@EmployeeId IS NULL OR a.EmployeeId = @EmployeeId);

    DECLARE @Emp INT, @n INT = 0;
    DECLARE emp_cur CURSOR LOCAL FAST_FORWARD FOR SELECT EmployeeId FROM @emps ORDER BY EmployeeId;
    OPEN emp_cur; FETCH NEXT FROM emp_cur INTO @Emp;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @WorkDate;
        SET @n += 1;
        FETCH NEXT FROM emp_cur INTO @Emp;
    END
    CLOSE emp_cur; DEALLOCATE emp_cur;

    UPDATE r SET r.IsProcessed = 1 FROM attendance.RAW_DEVICE_LOG r JOIN @raw x ON x.RawLogId = r.RawLogId;

    SET @DaysOut = @n;
    IF @Quiet = 0 SELECT @n AS EmployeeDaysProcessed;
END;
GO

/* ============================================================================
   4. HR decisions on a day: approval, disposition — stored, then the day is re-derived
   ============================================================================ */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_SetExitApproval
    @AttendanceId        BIGINT,
    @ExitApprovedMinutes INT,
    @ExitPermissionId    INT = NULL,
    @AlsoSetActual       BIT = 0,              -- accepted for compatibility; IGNORED (BUG-13: it subtracted the approval from the worked time)
    @HrNote              NVARCHAR(300) = NULL,
    @Disposition         VARCHAR(20) = NULL    -- optional: decide the remaining variance in the same call
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ExitApprovedMinutes IS NULL OR @ExitApprovedMinutes < 0
    BEGIN RAISERROR('ExitApprovedMinutes must be zero or more.', 16, 1); RETURN; END
    IF @Disposition IS NOT NULL AND @Disposition NOT IN ('UnpaidAbsence', 'Overtime', 'Ignore')
    BEGIN RAISERROR('Disposition must be UnpaidAbsence, Overtime, or Ignore.', 16, 1); RETURN; END

    DECLARE @Emp INT, @D DATE, @IsManual BIT;
    SELECT @Emp = EmployeeId, @D = WorkDate, @IsManual = IsManual FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
    IF @Emp IS NULL BEGIN RAISERROR('Attendance record not found.', 16, 1); RETURN; END

    DECLARE @LeaveBasis VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'ExitLeaveBasis'), 'Actual');

    BEGIN TRAN;

    UPDATE attendance.ATTENDANCE_RECORD
    SET ExitHrApprovedMinutes   = @ExitApprovedMinutes,
        ExitPermissionId        = COALESCE(@ExitPermissionId, ExitPermissionId),
        ExitVarianceDisposition = COALESCE(@Disposition, ExitVarianceDisposition),
        HrNote                  = COALESCE(@HrNote, HrNote),
        ProcessedUtc            = SYSUTCDATETIME()
    WHERE AttendanceId = @AttendanceId;

    IF @IsManual = 1
        /* a manual day keeps HR's figures: only the approval, the variance and the leave minutes move */
        UPDATE attendance.ATTENDANCE_RECORD
        SET ExitApprovedMinutes = @ExitApprovedMinutes,
            ExitVarianceMinutes = ExitActualMinutes - @ExitApprovedMinutes,
            ExitLeaveMinutes    = COALESCE(ExitLeaveOverrideMinutes, CASE WHEN @LeaveBasis = 'Approved' THEN @ExitApprovedMinutes ELSE ExitActualMinutes END)
        WHERE AttendanceId = @AttendanceId;
    ELSE
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @D;

    COMMIT TRAN;

    SELECT AttendanceId, ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes,
           ExitLeaveMinutes, WorkedMinutes, DayFraction, IsFullDay, OvertimeMinutes,
           CoveredMinutes, EarlyExitMinutes, LateDeductMinutes, ExitVarianceDisposition, [Status]
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
END;
GO

CREATE OR ALTER PROCEDURE attendance.usp_Attendance_SetExitDisposition
    @AttendanceId             BIGINT,
    @Disposition              VARCHAR(20),
    @ExitLeaveMinutesOverride INT = NULL,
    @HrNote                   NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Disposition NOT IN ('UnpaidAbsence', 'Overtime', 'Ignore')
    BEGIN RAISERROR('Disposition must be UnpaidAbsence, Overtime, or Ignore.', 16, 1); RETURN; END

    DECLARE @Emp INT, @D DATE, @IsManual BIT;
    SELECT @Emp = EmployeeId, @D = WorkDate, @IsManual = IsManual FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
    IF @Emp IS NULL BEGIN RAISERROR('Attendance record not found.', 16, 1); RETURN; END

    BEGIN TRAN;

    /* the decision is a stored INPUT of the rule; the row stays computed (no IsManual flag), so a
       reprocess keeps the decision and re-derives the figures with it */
    UPDATE attendance.ATTENDANCE_RECORD
    SET ExitVarianceDisposition  = @Disposition,
        ExitLeaveOverrideMinutes = COALESCE(@ExitLeaveMinutesOverride, ExitLeaveOverrideMinutes),
        ExitLeaveMinutes         = COALESCE(@ExitLeaveMinutesOverride, ExitLeaveMinutes),
        HrNote                   = COALESCE(@HrNote, HrNote),
        ProcessedUtc             = SYSUTCDATETIME()
    WHERE AttendanceId = @AttendanceId;

    IF @IsManual = 0
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @D;

    COMMIT TRAN;

    SELECT AttendanceId, ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes,
           ExitLeaveMinutes, ExitVarianceDisposition, WorkedMinutes, DayFraction, IsFullDay, CoveredMinutes, [Status]
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
END;
GO

/* ============================================================================
   5. approved exit permissions → attendance (idempotent)
   ============================================================================ */
CREATE OR ALTER PROCEDURE workflow.usp_ExitPermission_ApplyToAttendance
    @ExitPermissionId INT  = NULL,             -- one permission (re-applied even if already stamped)
    @WorkDate         DATE = NULL              -- or every approved, not-yet-applied permission (of that date)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Applied INT = 0;
    DECLARE @Id INT, @Emp INT, @Date DATE, @Outcome VARCHAR(10);

    DECLARE ep_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT ep.ExitPermissionId, ep.EmployeeId, ep.ExitDate
        FROM workflow.EXIT_PERMISSION ep
        JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
        WHERE r.[Status] = 'Approved'
          AND (@ExitPermissionId IS NULL OR ep.ExitPermissionId = @ExitPermissionId)
          AND (@ExitPermissionId IS NOT NULL OR ep.AppliedToAttendanceAt IS NULL)
          AND (@WorkDate IS NULL OR ep.ExitDate = @WorkDate)
          AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = ep.EmployeeId AND a.WorkDate = ep.ExitDate);

    OPEN ep_cur;
    FETCH NEXT FROM ep_cur INTO @Id, @Emp, @Date;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        /* the rule reads the approved minutes itself; a manual day is left to HR */
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @Date, @Outcome = @Outcome OUTPUT;

        UPDATE attendance.ATTENDANCE_RECORD
        SET ExitPermissionId = @Id,
            HrNote = CASE WHEN HrNote IS NULL THEN N'Applied from approved exit permission.' ELSE HrNote END
        WHERE EmployeeId = @Emp AND WorkDate = @Date AND ExitPermissionId IS NULL;

        UPDATE workflow.EXIT_PERMISSION SET AppliedToAttendanceAt = SYSUTCDATETIME() WHERE ExitPermissionId = @Id;

        SET @Applied += 1;
        FETCH NEXT FROM ep_cur INTO @Id, @Emp, @Date;
    END
    CLOSE ep_cur; DEALLOCATE ep_cur;

    SELECT @Applied AS PermissionsApplied;
END;
GO

/* ============================================================================
   6. leave days and absentees
   ============================================================================ */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_MarkLeaveDays
    @PeriodYearMonth CHAR(7)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @from DATE = TRY_CAST(@PeriodYearMonth + '-01' AS DATE);
    IF @from IS NULL BEGIN RAISERROR('PeriodYearMonth must be yyyy-MM.', 16, 1); RETURN; END
    DECLARE @to DATE = EOMONTH(@from);

    /* every day of every APPROVED leave request (FromDate..ToDate) inside the month — BUG-08 —
       that has a non-manual record not yet marked Leave (Present as well as Absent — BUG-09) */
    DECLARE @days TABLE (EmployeeId INT, WorkDate DATE, PRIMARY KEY (EmployeeId, WorkDate));
    ;WITH n AS (SELECT TOP (DATEDIFF(DAY, @from, @to) + 1) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i FROM sys.all_objects),
    d AS (SELECT DATEADD(DAY, i, @from) AS WorkDate FROM n)
    INSERT INTO @days (EmployeeId, WorkDate)
    SELECT DISTINCT lr.EmployeeId, d.WorkDate
    FROM workflow.LEAVE_REQUEST lr
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId AND ri.[Status] = 'Approved'
    JOIN d ON d.WorkDate BETWEEN lr.FromDate AND lr.ToDate
    JOIN attendance.ATTENDANCE_RECORD a ON a.EmployeeId = lr.EmployeeId AND a.WorkDate = d.WorkDate
    WHERE a.IsManual = 0 AND a.[Status] <> 'Leave';

    DECLARE @Emp INT, @D DATE, @Marked INT = 0;
    DECLARE lv_cur CURSOR LOCAL FAST_FORWARD FOR SELECT EmployeeId, WorkDate FROM @days ORDER BY WorkDate, EmployeeId;
    OPEN lv_cur; FETCH NEXT FROM lv_cur INTO @Emp, @D;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @D;
        IF EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @Emp AND WorkDate = @D AND [Status] = 'Leave')
            SET @Marked += 1;
        FETCH NEXT FROM lv_cur INTO @Emp, @D;
    END
    CLOSE lv_cur; DEALLOCATE lv_cur;

    SELECT @Marked AS DaysMarkedAsLeave;
END;
GO

CREATE OR ALTER PROCEDURE attendance.usp_Attendance_MarkAbsentees
    @WorkDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @WorkDate IS NULL BEGIN RAISERROR('WorkDate is required.', 16, 1); RETURN; END

    /* rostered employee-days with no record; the rule decides Absent / RestDay (DayFraction NULL) /
       Leave, and writes nothing when the roster month is not approved (no shift rostered → no absence) */
    DECLARE @emps TABLE (EmployeeId INT PRIMARY KEY);
    INSERT INTO @emps (EmployeeId)
    SELECT sa.EmployeeId
    FROM attendance.SHIFT_ASSIGNMENT sa
    JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId AND e.IsDeleted = 0
    WHERE sa.WorkDate = @WorkDate
      AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = sa.EmployeeId AND a.WorkDate = sa.WorkDate);

    DECLARE @Emp INT, @Outcome VARCHAR(10), @Marked INT = 0;
    DECLARE ab_cur CURSOR LOCAL FAST_FORWARD FOR SELECT EmployeeId FROM @emps ORDER BY EmployeeId;
    OPEN ab_cur; FETCH NEXT FROM ab_cur INTO @Emp;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @WorkDate, @Outcome = @Outcome OUTPUT;
        IF @Outcome = 'Inserted' SET @Marked += 1;
        FETCH NEXT FROM ab_cur INTO @Emp;
    END
    CLOSE ab_cur; DEALLOCATE ab_cur;

    SELECT @Marked AS AbsenteesMarked;
END;
GO

/* ============================================================================
   7. the queue and the readiness gate: a variance is a POSITIVE difference; a rostered
      day with no record is one of an APPROVED roster month
   ============================================================================ */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_GetExitVariances
    @FromDate DATE, @ToDate DATE, @OnlyUndecided BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.AttendanceId, a.EmployeeId, e.FullName, a.WorkDate,
           a.ExitActualMinutes, a.ExitApprovedMinutes, a.ExitVarianceMinutes,
           a.ExitLeaveMinutes, a.ExitVarianceDisposition,
           a.OvertimeMinutes,
           core.fn_MinutesToLeaveDays(a.ExitLeaveMinutes) AS LeaveDaysToDeduct,
           a.HrNote,
           a.EarlyExitMinutes, a.CoveredMinutes, a.DayFraction
    FROM attendance.ATTENDANCE_RECORD a
    JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
    WHERE a.WorkDate BETWEEN @FromDate AND @ToDate
      AND (a.ExitVarianceMinutes > 0 OR (@OnlyUndecided = 0 AND a.ExitVarianceMinutes <> 0))
      AND (@OnlyUndecided = 0 OR a.ExitVarianceDisposition IS NULL)
    ORDER BY a.WorkDate, e.FullName;
END;
GO

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

    /* a rostered day is one of an APPROVED roster month — the same gate the day rule applies
       (an unapproved roster is inert: it neither measures a punched day nor creates an absence) */
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

/* the list read: expose the new figures (additive; the old build ignores columns it does not map) */
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
           a.LateDeductMinutes, a.EarlyExitMinutes, a.CoveredMinutes
    FROM attendance.ATTENDANCE_RECORD a
    JOIN hr.EMPLOYEE e    ON e.EmployeeId = a.EmployeeId
    LEFT JOIN hr.BRANCH b ON b.BranchId = a.BranchId
    WHERE a.WorkDate BETWEEN @FromDate AND @ToDate
      AND (@EmployeeId IS NULL OR a.EmployeeId = @EmployeeId)
      AND (@BranchId  IS NULL OR a.BranchId  = @BranchId)
    ORDER BY a.WorkDate, e.FullName; END;
GO

/* ============================================================================
   8. MIGRATION — re-derive the previous and current month for every employee.
      ReprocessDay only re-derives employee-days that have punches or a record, so
      no row is created for a day without punches. Nothing else is rewritten.
   ============================================================================ */
SET NOCOUNT ON;
DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);
DECLARE @From DATE = DATEADD(MONTH, -1, DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1));
DECLARE @To   DATE = EOMONTH(@Today);

IF OBJECT_ID('tempdb..#before') IS NOT NULL DROP TABLE #before;
SELECT a.AttendanceId, a.EmployeeId, a.WorkDate, a.[Status], a.WorkedMinutes, a.DayFraction, a.LateMinutes, a.OvertimeMinutes,
       a.ExitActualMinutes, a.ExitApprovedMinutes, a.ExitVarianceMinutes, a.IsManual,
       CHECKSUM(a.[Status], a.FirstInUtc, a.LastOutUtc, a.WorkedMinutes, a.DayFraction, a.LateMinutes, a.OvertimeMinutes,
                a.ExitActualMinutes, a.ExitApprovedMinutes, a.ExitVarianceMinutes, a.HasAnomaly, a.ShiftAssignmentId, a.StandardMinutes) AS Cs
INTO #before
FROM attendance.ATTENDANCE_RECORD a
WHERE a.WorkDate BETWEEN @From AND @To;

DECLARE @StrandedBefore INT = (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG WHERE IsProcessed = 0 AND EmployeeId IS NOT NULL);

DECLARE @D DATE = @From, @Days INT = 0, @n INT;
WHILE @D <= @To
BEGIN
    EXEC attendance.usp_Attendance_ReprocessDay @WorkDate = @D, @Quiet = 1, @DaysOut = @n OUTPUT;
    SET @Days += ISNULL(@n, 0);
    SET @D = DATEADD(DAY, 1, @D);
END

IF OBJECT_ID('tempdb..#after') IS NOT NULL DROP TABLE #after;
SELECT a.AttendanceId, a.EmployeeId, a.WorkDate, a.[Status], a.WorkedMinutes, a.DayFraction, a.LateMinutes, a.OvertimeMinutes,
       a.ExitActualMinutes, a.ExitApprovedMinutes, a.ExitVarianceMinutes, a.IsManual,
       CHECKSUM(a.[Status], a.FirstInUtc, a.LastOutUtc, a.WorkedMinutes, a.DayFraction, a.LateMinutes, a.OvertimeMinutes,
                a.ExitActualMinutes, a.ExitApprovedMinutes, a.ExitVarianceMinutes, a.HasAnomaly, a.ShiftAssignmentId, a.StandardMinutes) AS Cs
INTO #after
FROM attendance.ATTENDANCE_RECORD a
WHERE a.WorkDate BETWEEN @From AND @To;

DECLARE @CntBefore INT = (SELECT COUNT(*) FROM #before), @CntAfter INT = (SELECT COUNT(*) FROM #after);
DECLARE @StrandedAfter INT = (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG WHERE IsProcessed = 0 AND EmployeeId IS NOT NULL);
PRINT CONCAT('MIGRATION | window ', CONVERT(VARCHAR(10), @From, 23), ' .. ', CONVERT(VARCHAR(10), @To, 23),
             ' | employee-days re-derived: ', @Days,
             ' | records before: ', @CntBefore, ' after: ', @CntAfter,
             ' | unprocessed punches before: ', @StrandedBefore, ' after: ', @StrandedAfter);

DECLARE @line NVARCHAR(400);
DECLARE st_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT CONCAT('MIGRATION | status ', x.[Status], ': ', COUNT(*), ' record(s) changed, ', SUM(CASE WHEN b.[Status] <> x.[Status] THEN 1 ELSE 0 END), ' changed status')
    FROM #after x JOIN #before b ON b.AttendanceId = x.AttendanceId
    WHERE b.Cs <> x.Cs
    GROUP BY x.[Status] ORDER BY x.[Status];
OPEN st_cur; FETCH NEXT FROM st_cur INTO @line;
IF @@FETCH_STATUS <> 0 PRINT 'MIGRATION | no record changed';
WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM st_cur INTO @line; END
CLOSE st_cur; DEALLOCATE st_cur;

DECLARE ch_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT CONCAT('MIGRATION | changed: ', e.FullName, ' (', x.EmployeeId, ') ', CONVERT(VARCHAR(10), x.WorkDate, 23),
                  ' | ', b.[Status], ' -> ', x.[Status],
                  ' | worked ', b.WorkedMinutes, ' -> ', x.WorkedMinutes,
                  ' | fraction ', ISNULL(CAST(b.DayFraction AS VARCHAR(6)), 'NULL'), ' -> ', ISNULL(CAST(x.DayFraction AS VARCHAR(6)), 'NULL'),
                  ' | late ', b.LateMinutes, ' -> ', x.LateMinutes,
                  ' | OT ', b.OvertimeMinutes, ' -> ', x.OvertimeMinutes,
                  ' | exit actual/approved/variance ', b.ExitActualMinutes, '/', b.ExitApprovedMinutes, '/', b.ExitVarianceMinutes,
                  ' -> ', x.ExitActualMinutes, '/', x.ExitApprovedMinutes, '/', x.ExitVarianceMinutes)
    FROM #after x JOIN #before b ON b.AttendanceId = x.AttendanceId JOIN hr.EMPLOYEE e ON e.EmployeeId = x.EmployeeId
    WHERE b.Cs <> x.Cs
    ORDER BY x.WorkDate, e.FullName;
OPEN ch_cur; FETCH NEXT FROM ch_cur INTO @line;
WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM ch_cur INTO @line; END
CLOSE ch_cur; DEALLOCATE ch_cur;

DECLARE @NewRows INT = (SELECT COUNT(*) FROM #after x WHERE NOT EXISTS (SELECT 1 FROM #before b WHERE b.AttendanceId = x.AttendanceId));
PRINT CONCAT('MIGRATION | new records created: ', @NewRows, ' (expected 0: only days with punches or a record are re-derived)');
DROP TABLE #before; DROP TABLE #after;
GO
