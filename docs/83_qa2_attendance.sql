/* ============================================================================
   83_qa2_attendance.sql — the attendance fixes and features of the QA2 scenario suite (tests/qa2, cases A1 / A2).
   Needs 82_qa2_foundation.sql.

   THE DAY RULE (attendance.fn_AttendanceDayRule — still pure arithmetic, no table access; three new inputs, one new
   output; now a multi-statement function: inlined into its caller it crossed SQL Server's expression limit, Msg 8632)
     · EXIT PERMISSIONS COVER THE EDGES OF THE DAY. @PermLateMinutes / @PermEarlyMinutes are the approved permission
       minutes whose WINDOW overlaps the late window [shift start, first in) / the early window (last out, shift end]
       (the writer works them out). They reduce the lateness / early departure BEFORE the tolerance is applied, so
       late 25 with a 07:00-07:30 permission is no anomaly (A1a), and early 40 with a 14:30-15:00 permission is an
       anomaly of 10 (A1b). What is left of the approved total covers the mid-day gap, then (as before) an early
       departure. Minutes a permission covered can never be deducted. New output PermEdgeMinutes = the permission
       minutes actually used at the edges; the writer adds them to ExitLeaveMinutes on the Actual basis, so they
       reach the period-close leave conversion. ExitActualMinutes keeps its meaning (the mid-day exit).
     · A REST DAY WORKED is overtime only as far as an overtime request was approved: min(worked, approved) (A1g).
       It used to be 0 always, so an approved call-in was never paid.
     · THE AUTUMN DST NIGHT: @DstExtraMinutes = real minus wall length of the shift when positive; it is overtime only
       within what an approved overtime request leaves after the post- and pre-shift minutes (A2b). Spring needs
       nothing: times are wall-clock, the wall day is complete.
   THE WRITERS (usp_Attendance_ComputeDay, usp_Attendance_ManualUpsert)
     · D1 holidays from core.fn_IsHoliday(date, branch that day) (A1h); the dormant hr.PUBLIC_HOLIDAY hook is gone.
     · D3 half-day leave: the rule measures the other half as its own little day; fraction = 0.5 + half/2; no punch in
       the measured half = anomaly HalfDayAbsence (new Type), Excused covers it.
     · D7 the branch of the day = hr.fn_EmployeeBranchOn; ATTENDANCE_RECORD.BranchId is the employee's branch that day.
     · D10 a day already paid for the employee is never re-derived (ComputeDay: Outcome 'Locked', no error) and every
       HR-facing writer refuses it: "This period is paid — raise a payroll adjustment instead." — ManualUpsert,
       DeleteManual, HrAdjustDay, SetExitApproval, SetExitDisposition, Correction_Create / _Approve, Anomaly_Decide;
       Anomaly_DecideAll leaves paid days out.
     · An unrostered day of an APPROVED roster month has no record (A1i): listed by usp_Attendance_GetWorkedWithoutRoster.
     · A decision answers a fact: when the punch it was made about changes (correction, late punch) the decision is
       cleared with a note and HR sees the anomaly again (A1k) — usp_Anomaly_ClearIfPunchChanged. A reprocess or a
       tolerance change with the same punches keeps every decision (A1j).
   D9 unknown device users: attendance.DEVICE_PUNCH_QUARANTINE (a VIEW over the punches stored with no employee — they
      were never lost: usp_RawLog_Insert keeps them; a second copy would only be a second truth) + _GetAll +
      _MapToEmployee, which enrols the PIN, gives the punches to the employee and REPLAYS them (derives their days).
   D6 late punches: usp_Attendance_ProcessRawLogs already re-derives every day that has a new punch from ALL its
      punches; it now also reports how many of those days had been processed before (@LateDaysOut) so the worker logs it.
   Requests: several exit permissions per day when their windows do not overlap (A1c); overtime "not in the past" is
      judged on Beirut's date, not the server clock.

   Idempotent: CREATE OR ALTER throughout. Apply with sqlcmd -C -I.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ───────────────────────── 1. the anomaly types ───────────────────────── */
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_AttAnomaly_Type' AND definition NOT LIKE '%HalfDayAbsence%')
    ALTER TABLE attendance.ATTENDANCE_ANOMALY DROP CONSTRAINT CK_AttAnomaly_Type;
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_AttAnomaly_Type')
    ALTER TABLE attendance.ATTENDANCE_ANOMALY ADD CONSTRAINT CK_AttAnomaly_Type
        CHECK ([Type] IN ('MissingPunch', 'EarlyDeparture', 'LateArrival', 'HalfDayAbsence'));
GO

/* ───────────────────────── 2. THE RULE ───────────────────────── */
/* an inline function cannot be ALTERed into a multi-statement one */
IF EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID('attendance.fn_AttendanceDayRule') AND type = 'IF')
    DROP FUNCTION attendance.fn_AttendanceDayRule;
GO
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
    @IsHoliday               BIT,
    @PermLateMinutes         INT,           -- script 83: approved permission minutes whose window overlaps [shift start, first in)
    @PermEarlyMinutes        INT,           -- script 83: … overlaps (last out, shift end]
    @DstExtraMinutes         INT            -- script 83: real − wall minutes of the shift when positive (the autumn DST night)
)
RETURNS @day TABLE
(
    [Status] VARCHAR(20), EffectiveInUtc DATETIME2, EffectiveOutUtc DATETIME2,
    LateMinutes INT, LateDeductMinutes INT, EarlyExitMinutes INT, MidDayGapMinutes INT,
    ExitActualMinutes INT, ExitApprovedMinutes INT, ExitVarianceMinutes INT, OvertimeMinutes INT,
    WorkedMinutes INT, CoveredMinutes INT, DayFraction DECIMAL(5,2), IsFullDay BIT, ShortfallMinutes INT,
    BreakApplied INT, StandardMinutes INT, EarlyDeductMinutes INT, ToleranceMinutes INT, PermEdgeMinutes INT
)
AS
BEGIN
    /* A MULTI-STATEMENT function since script 83, on purpose: written as one inline expression the rule is expanded
       into its caller, and with the permission windows it crossed SQL Server's expression limit (Msg 8632) inside
       usp_Attendance_ComputeDay. Step by step it is also easier to hold each line to its arithmetic. It still touches
       no table: every figure is a function of the arguments. */
    DECLARE @BreakMin INT = ISNULL(@BreakMinutes, 0), @Tol INT = ISNULL(@ToleranceMinutes, 0),
            @Approved INT = ISNULL(@ExitApprovedMinutes, 0), @OtApproved INT = ISNULL(@OvertimeApprovedMinutes, 0),
            @Gap INT = ISNULL(@GapMinutes, 0),
            @PermLate  INT = CASE WHEN ISNULL(@PermLateMinutes, 0)  > 0 THEN @PermLateMinutes  ELSE 0 END,
            @PermEarly INT = CASE WHEN ISNULL(@PermEarlyMinutes, 0) > 0 THEN @PermEarlyMinutes ELSE 0 END,
            @DstExtra  INT = CASE WHEN ISNULL(@DstExtraMinutes, 0)  > 0 THEN @DstExtraMinutes  ELSE 0 END,
            @HasShift BIT = CASE WHEN @ShiftStartUtc IS NOT NULL AND @ShiftEndUtc IS NOT NULL THEN 1 ELSE 0 END,
            @Rest BIT = ISNULL(@IsRestDay, 0), @Leave BIT = ISNULL(@IsOnLeave, 0), @Hol BIT = ISNULL(@IsHoliday, 0);
    DECLARE @Standard INT = CASE WHEN @Rest = 1 THEN 0 ELSE ISNULL(@StandardMinutes, 0) END;

    /* the arrival minutes after the shift start and the minutes before its end (inside or beyond the tolerance) */
    DECLARE @RawLate INT = CASE WHEN @FirstInUtc IS NULL OR @HasShift = 0 OR @FirstInUtc <= @ShiftStartUtc THEN 0
                                ELSE DATEDIFF(MINUTE, @ShiftStartUtc, @FirstInUtc) END;
    DECLARE @PreShift INT = CASE WHEN @FirstInUtc IS NULL OR @HasShift = 0 OR @FirstInUtc >= @ShiftStartUtc THEN 0
                                 ELSE DATEDIFF(MINUTE, @FirstInUtc, @ShiftStartUtc) END;
    DECLARE @PostShift INT = CASE WHEN @LastOutUtc IS NULL OR @HasShift = 0 OR @LastOutUtc <= @ShiftEndUtc THEN 0
                                  ELSE DATEDIFF(MINUTE, @ShiftEndUtc, @LastOutUtc) END;
    DECLARE @EffIn DATETIME2 = CASE WHEN @FirstInUtc IS NULL THEN NULL
                                    WHEN @HasShift = 1 AND @FirstInUtc < @ShiftStartUtc THEN @ShiftStartUtc ELSE @FirstInUtc END;
    DECLARE @EffOut DATETIME2 = CASE WHEN @LastOutUtc IS NULL THEN NULL
                                     WHEN @HasShift = 1 AND @LastOutUtc > @ShiftEndUtc THEN @ShiftEndUtc ELSE @LastOutUtc END;
    DECLARE @RawEarly INT = CASE WHEN @LastOutUtc IS NULL OR @HasShift = 0 OR @LastOutUtc >= @ShiftEndUtc THEN 0
                                 WHEN DATEDIFF(MINUTE, @LastOutUtc, @ShiftEndUtc) > DATEDIFF(MINUTE, @ShiftStartUtc, @ShiftEndUtc)
                                      THEN DATEDIFF(MINUTE, @ShiftStartUtc, @ShiftEndUtc)      -- capped at the shift length
                                 ELSE DATEDIFF(MINUTE, @LastOutUtc, @ShiftEndUtc) END;
    DECLARE @MidDay INT = CASE WHEN @Gap - @BreakMin > 0 THEN @Gap - @BreakMin ELSE 0 END;

    /* what the permissions' own windows cover of the lateness and of the early departure */
    DECLARE @LateCov  INT = CASE WHEN @RawLate  < @PermLate  THEN @RawLate  ELSE @PermLate  END;
    DECLARE @EarlyCov INT = CASE WHEN @RawEarly < @PermEarly THEN @RawEarly ELSE @PermEarly END;
    /* the approved minutes not spent at the edges: for the mid-day gap first, then (as before) an early departure */
    DECLARE @Pool INT = CASE WHEN @Approved - @LateCov - @EarlyCov > 0 THEN @Approved - @LateCov - @EarlyCov ELSE 0 END;
    DECLARE @PermForGap INT = CASE WHEN @MidDay < @Pool THEN @MidDay ELSE @Pool END;
    DECLARE @EarlyCovPool INT = CASE WHEN @RawEarly - @EarlyCov < @Pool - @PermForGap THEN @RawEarly - @EarlyCov ELSE @Pool - @PermForGap END;
    DECLARE @LateUncovered  INT = @RawLate  - @LateCov;
    DECLARE @EarlyUncovered INT = @RawEarly - @EarlyCov - @EarlyCovPool;

    /* at or beyond the tolerance what is NOT covered is an anomaly and is reported whole; below it, nothing */
    DECLARE @Late  INT = CASE WHEN @LateUncovered  > 0 AND @LateUncovered  >= @Tol THEN @LateUncovered  ELSE 0 END;
    DECLARE @Early INT = CASE WHEN @EarlyUncovered > 0 AND @EarlyUncovered >= @Tol THEN @EarlyUncovered ELSE 0 END;
    DECLARE @Worked INT = CASE WHEN @EffIn IS NULL OR @EffOut IS NULL THEN 0
                               WHEN DATEDIFF(MINUTE, @EffIn, @EffOut) - @BreakMin - @MidDay > 0 THEN DATEDIFF(MINUTE, @EffIn, @EffOut) - @BreakMin - @MidDay
                               ELSE 0 END;
    DECLARE @LateDeduct  INT = CASE WHEN @Late  > 0 AND @LateDecision  = 'Deducted' THEN @Late  ELSE 0 END;
    DECLARE @EarlyDeduct INT = CASE WHEN @Early > 0 AND @EarlyDecision = 'Deducted' THEN @Early ELSE 0 END;

    /* overtime on a shift: everything after the shift, the minutes before it as far as an approved request allows,
       and the repeated hour of the autumn DST night within what that request still leaves */
    DECLARE @OtLeft INT = CASE WHEN @OtApproved - @PostShift > 0 THEN @OtApproved - @PostShift ELSE 0 END;
    DECLARE @PrePart INT = CASE WHEN @PreShift < @OtLeft THEN @PreShift ELSE @OtLeft END;
    SET @OtLeft = @OtLeft - @PrePart;
    DECLARE @DstPart INT = CASE WHEN @DstExtra = 0 OR @FirstInUtc IS NULL OR @LastOutUtc IS NULL THEN 0
                                WHEN @DstExtra < @OtLeft THEN @DstExtra ELSE @OtLeft END;
    DECLARE @OtMeasured INT = CASE WHEN @HasShift = 0 THEN CASE WHEN @Worked - @Standard > 0 THEN @Worked - @Standard ELSE 0 END
                                   ELSE @PostShift + @PrePart + @DstPart END;

    DECLARE @Covered INT = @PermForGap
                         + CASE WHEN @Disposition IN ('Ignore', 'Overtime') AND @MidDay - @Pool > 0 THEN @MidDay - @Pool ELSE 0 END
                         + (@RawLate  - @LateDeduct)
                         + (@RawEarly - @EarlyDeduct);

    DECLARE @Status VARCHAR(20) = CASE WHEN @Leave = 1 THEN 'Leave' WHEN @Rest = 1 THEN 'RestDay' WHEN @Hol = 1 THEN 'Holiday'
                                       WHEN @FirstInUtc IS NOT NULL THEN 'Present' ELSE 'Absent' END;
    DECLARE @Measured BIT = CASE WHEN @Leave = 1 OR @Rest = 1 OR @Hol = 1 THEN 0 ELSE 1 END;
    DECLARE @Fraction DECIMAL(5,2) = CASE WHEN @Measured = 0 THEN NULL
                                          WHEN @Standard <= 0 THEN CAST(0 AS DECIMAL(5,2))
                                          WHEN @Worked + @Covered >= @Standard THEN CAST(1.00 AS DECIMAL(5,2))
                                          ELSE CAST(ROUND(CAST(@Worked + @Covered AS DECIMAL(12,4)) / @Standard, 2) AS DECIMAL(5,2)) END;

    INSERT INTO @day
    SELECT @Status, @EffIn, @EffOut,
           CASE WHEN @Measured = 1 THEN @Late ELSE 0 END,
           CASE WHEN @Measured = 1 THEN @LateDeduct ELSE 0 END,
           CASE WHEN @Measured = 1 THEN @Early ELSE 0 END,
           CASE WHEN @Measured = 1 THEN @MidDay ELSE 0 END,
           CASE WHEN @Measured = 1 THEN @MidDay ELSE 0 END,                                   -- ExitActualMinutes: the mid-day exit
           @Approved,
           CASE WHEN @Measured = 1 THEN @MidDay - @Pool ELSE 0 END,
           /* a rest day worked: overtime only as far as it was approved; leave and holidays carry none */
           CASE WHEN @Measured = 1 THEN @OtMeasured
                WHEN @Status = 'RestDay' THEN CASE WHEN @Worked < @OtApproved THEN @Worked ELSE @OtApproved END
                ELSE 0 END,
           @Worked,                                                                           -- informational on a rest / leave / holiday day
           CASE WHEN @Measured = 1 THEN @Covered ELSE 0 END,
           @Fraction,
           CAST(CASE WHEN @Fraction IS NOT NULL AND @Fraction >= ISNULL(@FullDayThreshold, 1.00) THEN 1 ELSE 0 END AS BIT),
           CASE WHEN @Measured = 1 AND @Standard - @Worked - @Covered > 0 THEN @Standard - @Worked - @Covered ELSE 0 END,
           CASE WHEN @FirstInUtc IS NOT NULL THEN @BreakMin ELSE 0 END,
           @Standard,
           CASE WHEN @Measured = 1 THEN @EarlyDeduct ELSE 0 END,
           @Tol,
           CASE WHEN @Measured = 1 THEN @LateCov + @EarlyCov + @EarlyCovPool ELSE 0 END;
    RETURN;
END;
GO

/* ───────────────────────── 3. the anomaly rows of one day ───────────────────────── */
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
    @AutoExcuseEarly  BIT = 0,                 -- HR's own exit approval covers the early departure
    @AutoExcuseNote   NVARCHAR(300) = NULL,
    @HalfDayAbsenceMinutes INT = 0             -- script 83 (D3): no punch in the measured half of a half-day-leave day
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @want TABLE ([Type] VARCHAR(20) PRIMARY KEY, [Minutes] INT);
    IF ISNULL(@LateMinutes, 0) > 0           INSERT INTO @want VALUES ('LateArrival',    @LateMinutes);
    IF ISNULL(@EarlyExitMinutes, 0) > 0      INSERT INTO @want VALUES ('EarlyDeparture', @EarlyExitMinutes);
    IF ISNULL(@HasAnomaly, 0) = 1            INSERT INTO @want VALUES ('MissingPunch',   0);
    IF ISNULL(@HalfDayAbsenceMinutes, 0) > 0 INSERT INTO @want VALUES ('HalfDayAbsence', @HalfDayAbsenceMinutes);

    /* gone: the condition no longer holds (a 'Corrected' row stays as the record of the correction) */
    DELETE FROM attendance.ATTENDANCE_ANOMALY
    WHERE AttendanceId = @AttendanceId
      AND [Type] NOT IN (SELECT [Type] FROM @want)
      AND ISNULL(Decision, '') <> 'Corrected';

    /* still there: the minutes and the times move; the decision does not (usp_Anomaly_ClearIfPunchChanged is the one
       place a decision is withdrawn, and it runs before the rule so the figures are derived without it) */
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

    IF @AutoExcuseEarly = 1
        UPDATE attendance.ATTENDANCE_ANOMALY
        SET Decision = 'Excused', DecidedAt = SYSUTCDATETIME(), DecidedByUserId = NULL,
            Note = ISNULL(@AutoExcuseNote, N'Covered by an approved exit permission.'), UpdatedAt = SYSUTCDATETIME()
        WHERE AttendanceId = @AttendanceId AND [Type] = 'EarlyDeparture' AND Decision IS NULL;
END;
GO

/* A decision answers a FACT: "he arrived at 07:20 and that is deducted". When that punch is no longer the punch
   (HR corrected the out time, the terminal delivered a punch late), the decision is about something that did not
   happen: it is withdrawn, with a note that says what it was, and HR decides the anomaly as it now stands.
   Called by both writers BEFORE they read the decisions. Same punches = nothing happens: a plain reprocess, a changed
   tolerance or a newly approved permission never withdraws a decision. 'Corrected' rows are the record of a correction
   and are never touched. */
CREATE OR ALTER PROCEDURE attendance.usp_Anomaly_ClearIfPunchChanged
    @AttendanceId BIGINT, @FirstInUtc DATETIME2, @LastOutUtc DATETIME2
AS
BEGIN
    SET NOCOUNT ON;
    IF @AttendanceId IS NULL RETURN;
    UPDATE an
    SET an.Note = LEFT(CONCAT(N'The punch changed after this was decided (was ', an.Decision, N', ', an.[Minutes], N' min, ',
                              CASE WHEN an.[Type] = 'LateArrival' THEN CONCAT(N'in ', CONVERT(VARCHAR(5), an.PunchInUtc, 108), N' → ', ISNULL(CONVERT(VARCHAR(5), @FirstInUtc, 108), N'none'))
                                   ELSE CONCAT(N'out ', CONVERT(VARCHAR(5), an.PunchOutUtc, 108), N' → ', ISNULL(CONVERT(VARCHAR(5), @LastOutUtc, 108), N'none')) END,
                              N') — decide again.', CASE WHEN an.Note IS NULL THEN N'' ELSE CONCAT(N' Earlier note: ', an.Note) END), 300),
        an.Decision = NULL, an.DecidedByUserId = NULL, an.DecidedAt = NULL, an.UpdatedAt = SYSUTCDATETIME()
    FROM attendance.ATTENDANCE_ANOMALY an
    WHERE an.AttendanceId = @AttendanceId
      AND an.Decision IN ('Excused', 'Deducted')
      AND (   (an.[Type] = 'LateArrival'    AND ISNULL(an.PunchInUtc,  '19000101') <> ISNULL(@FirstInUtc, '19000101'))
           OR (an.[Type] = 'EarlyDeparture' AND ISNULL(an.PunchOutUtc, '19000101') <> ISNULL(@LastOutUtc, '19000101')));
END;
GO

/* ───────────────────────── 4. THE WRITER for machine days ───────────────────────── */
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

    /* script 83 (D10): a day already PAID for this employee is never re-derived. Not an error — the processor
       meets such days when a punch arrives late, and must carry on with the others; the punch is kept and marked
       consumed, and what it would have changed is settled by a payroll adjustment. */
    IF payroll.fn_IsPeriodPaid(@EmployeeId, @WorkDate) = 1 BEGIN SET @Outcome = 'Locked'; RETURN; END

    DECLARE @EmpBranch INT, @EmpDeleted BIT;
    SELECT @EmpBranch = BranchId, @EmpDeleted = IsDeleted FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId;
    IF @EmpBranch IS NULL AND @EmpDeleted IS NULL RETURN;              -- no such employee
    /* script 83 (D7): the branch the employee belonged to ON that day — a transfer does not rewrite the days before it */
    SET @EmpBranch = hr.fn_EmployeeBranchOn(@EmployeeId, @WorkDate);

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
    DECLARE @MonthApproved BIT = CASE WHEN EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                                                   WHERE rm.BranchId = @EmpBranch
                                                     AND rm.MonthDate = DATEFROMPARTS(YEAR(@WorkDate), MONTH(@WorkDate), 1)
                                                     AND rm.[Status] = 'Approved') THEN 1 ELSE 0 END;
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

    /* script 83: AN UNROSTERED DAY OF AN APPROVED ROSTER HAS NO ATTENDANCE RECORD. The month's roster is signed
       off and gives this employee no row for the day (not even a rest day), so there is nothing to measure the
       punches against: no record, therefore no deduction. The punches are not lost — they are listed for HR by
       attendance.usp_Attendance_GetWorkedWithoutRoster, who either adds the day to the roster or leaves it.
       (A month whose roster is NOT approved is a different thing: the roster is inert there and every day keeps
       its record on the default standard day, as before.) A record that already exists is still maintained. */
    IF @MonthApproved = 1 AND @Sa IS NULL AND @AttId IS NULL RETURN;

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
          AND lr.HalfDay IS NULL
          AND @WorkDate BETWEEN lr.FromDate AND lr.ToDate) THEN 1 ELSE 0 END;
    /* script 83 (D3): an approved HALF-day leave covers half the standard; the other half follows the punches */
    DECLARE @Half CHAR(2) = (SELECT TOP 1 lr.HalfDay FROM workflow.LEAVE_REQUEST lr
                             JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
                             WHERE lr.EmployeeId = @EmployeeId AND ri.[Status] = 'Approved' AND lr.HalfDay IS NOT NULL
                               AND lr.FromDate = @WorkDate AND lr.ToDate = @WorkDate);
    /* script 83 (D1): a public holiday of every branch, or of the employee's branch that day */
    DECLARE @Holiday BIT = core.fn_IsHoliday(@WorkDate, @EmpBranch);
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

    /* script 83: WHERE the approved exit permissions lie matters. The minutes of a permission that overlap the late
       window [shift start, first in) cover the lateness (a "late permission"), those that overlap the early window
       (last out, shift end] cover the early departure; what is left of the approved total covers the mid-day gap and
       then, as before, an early departure. Each permission counts for no more than its approved minutes. HR's own
       figure (ExitHrApprovedMinutes) has no window: it is pooled, as before. */
    DECLARE @PermLate INT = 0, @PermEarly INT = 0;
    IF @HrApproved IS NULL AND @ShiftStartUtc IS NOT NULL AND @FirstIn IS NOT NULL
        SELECT @PermLate = ISNULL(SUM(x.LateOverlap), 0), @PermEarly = ISNULL(SUM(x.EarlyOverlap), 0)
        FROM (
            SELECT LateOverlap  = CASE WHEN w.LateRaw  > w.Cap THEN w.Cap ELSE w.LateRaw END,
                   EarlyOverlap = CASE WHEN w.EarlyRaw > w.Cap - CASE WHEN w.LateRaw > w.Cap THEN w.Cap ELSE w.LateRaw END
                                       THEN w.Cap - CASE WHEN w.LateRaw > w.Cap THEN w.Cap ELSE w.LateRaw END ELSE w.EarlyRaw END
            FROM (
                SELECT Cap = ISNULL(ep.ApprovedMinutes, 0),
                       LateRaw = CASE WHEN @FirstIn <= @ShiftStartUtc THEN 0
                                      ELSE (SELECT CASE WHEN o.e > o.s THEN DATEDIFF(MINUTE, o.s, o.e) ELSE 0 END
                                            FROM (SELECT s = CASE WHEN p.FromAt > @ShiftStartUtc THEN p.FromAt ELSE @ShiftStartUtc END,
                                                         e = CASE WHEN p.ToAt < @FirstIn THEN p.ToAt ELSE @FirstIn END) o) END,
                       EarlyRaw = CASE WHEN @LastOut IS NULL OR @LastOut >= @ShiftEndUtc THEN 0
                                       ELSE (SELECT CASE WHEN o.e > o.s THEN DATEDIFF(MINUTE, o.s, o.e) ELSE 0 END
                                             FROM (SELECT s = CASE WHEN p.FromAt > @LastOut THEN p.FromAt ELSE @LastOut END,
                                                          e = CASE WHEN p.ToAt < @ShiftEndUtc THEN p.ToAt ELSE @ShiftEndUtc END) o) END
                FROM workflow.EXIT_PERMISSION ep
                JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ep.RequestInstanceId
                /* the window as wall-clock moments of this day; past midnight for the small hours of an overnight shift */
                CROSS APPLY (SELECT FromAt = DATEADD(MINUTE, DATEDIFF(MINUTE, 0, ep.FromTime)
                                                     + CASE WHEN @Crosses = 1 AND ep.FromTime < @ShiftStart THEN 1440 ELSE 0 END, CAST(@WorkDate AS DATETIME2)),
                                    ToAt   = DATEADD(MINUTE, DATEDIFF(MINUTE, 0, ep.ToTime)
                                                     + CASE WHEN @Crosses = 1 AND ep.ToTime <= @ShiftStart THEN 1440 ELSE 0 END, CAST(@WorkDate AS DATETIME2))) p
                WHERE ep.EmployeeId = @EmployeeId AND ep.ExitDate = @WorkDate AND ri.[Status] = 'Approved'
            ) w
        ) x;

    /* script 83: the DST nights. Punches and shifts are wall-clock, so a shift over the autumn change is one REAL hour
       longer than its wall length (the spring one is an hour shorter and needs nothing: the wall day is complete).
       The extra hour is overtime only when an overtime request was approved for the day — the rule caps it. */
    DECLARE @DstExtra INT = 0;
    IF @ShiftStartUtc IS NOT NULL AND @ShiftEndUtc IS NOT NULL
        SET @DstExtra = DATEDIFF(MINUTE, @ShiftStartUtc AT TIME ZONE 'Middle East Standard Time', @ShiftEndUtc AT TIME ZONE 'Middle East Standard Time')
                      - DATEDIFF(MINUTE, @ShiftStartUtc, @ShiftEndUtc);
    IF @DstExtra < 0 SET @DstExtra = 0;

    /* script 83 (D3): with a half-day leave the rule measures the OTHER half as a little day of its own —
       AM leave: from the middle of the shift to its end; PM leave: from its start to the middle. */
    DECLARE @FullStandard INT = @Standard, @HalfApplies BIT = 0;
    IF @Half IS NOT NULL AND @IsRest = 0 AND @OnLeave = 0 AND @Holiday = 0
    BEGIN
        SET @HalfApplies = 1;
        IF @ShiftStartUtc IS NOT NULL
        BEGIN
            DECLARE @Mid DATETIME2 = DATEADD(MINUTE, DATEDIFF(MINUTE, @ShiftStartUtc, @ShiftEndUtc) / 2, @ShiftStartUtc);
            IF @Half = 'AM' SET @ShiftStartUtc = @Mid; ELSE SET @ShiftEndUtc = @Mid;
        END
        SET @Break = @Break / 2;
        SET @Standard = @FullStandard / 2;
    END

    /* script 83: a decision answers a FACT. When the punch it was made about has changed since (a correction, a punch
       that arrived late), the decision is cleared with a note and HR sees the anomaly again. */
    EXEC attendance.usp_Anomaly_ClearIfPunchChanged @AttendanceId = @AttId, @FirstInUtc = @FirstIn, @LastOutUtc = @LastOut;
    /* HR's decisions on the day's anomalies are inputs of the rule */
    DECLARE @LateDecision VARCHAR(10), @EarlyDecision VARCHAR(10), @HalfAbsDecision VARCHAR(10);
    SELECT @LateDecision    = MAX(CASE WHEN [Type] = 'LateArrival'    THEN Decision END),
           @EarlyDecision   = MAX(CASE WHEN [Type] = 'EarlyDeparture' THEN Decision END),
           @HalfAbsDecision = MAX(CASE WHEN [Type] = 'HalfDayAbsence' THEN Decision END)
    FROM attendance.ATTENDANCE_ANOMALY WHERE AttendanceId = @AttId;

    /* ---- the rule ---- */
    DECLARE @r TABLE ([Status] VARCHAR(20), LateMinutes INT, LateDeductMinutes INT, EarlyExitMinutes INT, MidDayGapMinutes INT,
                      ExitActualMinutes INT, ExitApprovedMinutes INT, ExitVarianceMinutes INT, OvertimeMinutes INT, WorkedMinutes INT,
                      CoveredMinutes INT, DayFraction DECIMAL(5,2), IsFullDay BIT, ShortfallMinutes INT, BreakApplied INT, StandardMinutes INT,
                      EarlyDeductMinutes INT, PermEdgeMinutes INT);
    INSERT INTO @r
    SELECT [Status], LateMinutes, LateDeductMinutes, EarlyExitMinutes, MidDayGapMinutes,
           ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes, OvertimeMinutes, WorkedMinutes,
           CoveredMinutes, DayFraction, IsFullDay, ShortfallMinutes, BreakApplied, StandardMinutes, EarlyDeductMinutes, PermEdgeMinutes
    FROM attendance.fn_AttendanceDayRule(@ShiftStartUtc, @ShiftEndUtc, @Break, @Tolerance, @Standard,
                                         @FirstIn, @LastOut, @Gap, @Approved, @Disposition, @OtApproved,
                                         @LateDecision, @EarlyDecision, @FullDayThreshold, @IsRest, @OnLeave, @Holiday,
                                         @PermLate, @PermEarly, @DstExtra);

    /* script 83 (D3): put the two halves together. The leave half is covered; the measured half counts for half a day.
       No punch at all in the measured half is a HALF-DAY ABSENCE: an anomaly for HR (Excused = the half is covered). */
    DECLARE @HalfAbsMinutes INT = 0;
    IF @HalfApplies = 1
    BEGIN
        SET @HalfAbsMinutes = CASE WHEN (SELECT [Status] FROM @r) = 'Absent' THEN @Standard ELSE 0 END;
        UPDATE @r
        SET DayFraction = CAST(0.50 + CASE WHEN [Status] = 'Absent' THEN CASE WHEN @HalfAbsDecision = 'Excused' THEN 0.50 ELSE 0.00 END
                                           ELSE ISNULL(DayFraction, 0) / 2 END AS DECIMAL(5,2)),
            CoveredMinutes = CoveredMinutes + (@FullStandard - @Standard)
                           + CASE WHEN [Status] = 'Absent' AND @HalfAbsDecision = 'Excused' THEN @Standard ELSE 0 END,
            StandardMinutes = @FullStandard;
        UPDATE @r SET IsFullDay = CASE WHEN DayFraction >= @FullDayThreshold THEN 1 ELSE 0 END,
                      ShortfallMinutes = CASE WHEN DayFraction >= 1 THEN 0 ELSE ShortfallMinutes END;
    END

    DECLARE @Status VARCHAR(20) = (SELECT [Status] FROM @r);
    DECLARE @HasAnomaly BIT = CASE WHEN @HasPunches = 1 AND @Status IN ('Present', 'RestDay')
                                    AND (@InCount <> @OutCount OR @FirstIn IS NULL OR @LastOut IS NULL) THEN 1 ELSE 0 END;
    /* script 83 (D7): the day belongs to the branch the EMPLOYEE belonged to that day (the terminal that took the punch
       is already in DeviceId) — so lists and reports by branch follow a transfer from its effective date */
    DECLARE @BranchId INT = @EmpBranch;
    DECLARE @ExitActual INT = (SELECT ExitActualMinutes FROM @r);
    /* Actual basis: the mid-day exit the punches show PLUS the permission minutes actually used at the edges of the day */
    DECLARE @ExitLeave INT = COALESCE(@LeaveOverride, CASE WHEN @LeaveBasis = 'Approved' THEN @Approved
                                                           ELSE @ExitActual + (SELECT PermEdgeMinutes FROM @r) END);

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
    DECLARE @AutoExcuse BIT = 0;      -- script 83: a covered early departure is no longer reported at all, so there is nothing left to auto-excuse
    DECLARE @AutoNote NVARCHAR(300) = CASE WHEN @PermissionId IS NOT NULL THEN CONCAT(N'Covered by exit permission #', @PermissionId, N' (', @Approved, N' min approved).')
                                           ELSE CONCAT(N'Covered by HR exit approval (', @Approved, N' min).') END;
    EXEC attendance.usp_Attendance_SyncAnomalies
        @AttendanceId = @AttId, @EmployeeId = @EmployeeId, @WorkDate = @WorkDate,
        @LateMinutes = @Late, @EarlyExitMinutes = @Early, @HasAnomaly = @HasAnomaly,
        @ShiftStartUtc = @ShiftStartUtc, @ShiftEndUtc = @ShiftEndUtc, @FirstInUtc = @FirstIn, @LastOutUtc = @LastOut,
        @AutoExcuseEarly = @AutoExcuse, @AutoExcuseNote = @AutoNote, @HalfDayAbsenceMinutes = @HalfAbsMinutes;

    COMMIT TRAN;
END;
GO

/* ───────────────────────── 5. the manual writer ───────────────────────── */
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
    /* script 83 (D10): a day that is already PAID for this employee is changed by a payroll adjustment, not here */
    DECLARE @PaidRc INT;
    EXEC @PaidRc = payroll.usp_AssertPeriodOpen @EmployeeId, @WorkDate;
    IF @PaidRc <> 0 RETURN;

    DECLARE @LeaveBasis VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'ExitLeaveBasis'), 'Actual');
    DECLARE @FullDayThreshold DECIMAL(5,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'FullDayThreshold') AS DECIMAL(5,2)), 1.00);
    DECLARE @ToleranceSetting INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'AttendanceToleranceMinutes') AS INT), 10);
    DECLARE @StdDefault INT = core.fn_StandardDayMinutes();

    /* the record as it stands: HR's stored decisions are inputs */
    DECLARE @AttId BIGINT, @Disposition VARCHAR(20), @LeaveOverride INT;
    SELECT @AttId = AttendanceId, @Disposition = ExitVarianceDisposition, @LeaveOverride = ExitLeaveOverrideMinutes
    FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate;

    /* script 83: a decision answers a fact; a correction that moves the punch clears it (with a note) so HR decides again */
    EXEC attendance.usp_Anomaly_ClearIfPunchChanged @AttendanceId = @AttId, @FirstInUtc = @FirstInUtc, @LastOutUtc = @LastOutUtc;
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
    /* script 83 (D1 / D7): with no status given, a public holiday of the employee's branch that day decides it */
    DECLARE @EmpBranchOn INT = hr.fn_EmployeeBranchOn(@EmployeeId, @WorkDate);
    DECLARE @Holiday BIT = CASE WHEN @Status = 'Holiday' THEN 1
                                WHEN @Status IS NOT NULL THEN 0
                                ELSE core.fn_IsHoliday(@WorkDate, @EmpBranchOn) END;
    DECLARE @Exit INT = ISNULL(@ExitMinutes, 0), @Approved INT = ISNULL(@ExitApprovedMins, 0);
    DECLARE @Gross INT = CASE WHEN @FirstInUtc IS NULL OR @LastOutUtc IS NULL THEN 0 ELSE DATEDIFF(MINUTE, @FirstInUtc, @LastOutUtc) END;
    /* @ExitMinutes is the absence BEYOND the break; the rule takes the raw gap and absorbs the break itself */
    DECLARE @Gap INT = CASE WHEN @Exit > 0 THEN @Exit + @Break ELSE 0 END;

    DECLARE @r TABLE ([Status] VARCHAR(20), LateMinutes INT, LateDeductMinutes INT, EarlyExitMinutes INT, MidDayGapMinutes INT,
                      ExitActualMinutes INT, ExitApprovedMinutes INT, ExitVarianceMinutes INT, OvertimeMinutes INT, WorkedMinutes INT,
                      CoveredMinutes INT, DayFraction DECIMAL(5,2), IsFullDay BIT, ShortfallMinutes INT, BreakApplied INT, StandardMinutes INT,
                      EarlyDeductMinutes INT, PermEdgeMinutes INT);
    INSERT INTO @r
    SELECT [Status], LateMinutes, LateDeductMinutes, EarlyExitMinutes, MidDayGapMinutes,
           ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes, OvertimeMinutes, WorkedMinutes,
           CoveredMinutes, DayFraction, IsFullDay, ShortfallMinutes, BreakApplied, StandardMinutes, EarlyDeductMinutes, PermEdgeMinutes
    FROM attendance.fn_AttendanceDayRule(@ShiftStartUtc, @ShiftEndUtc, @Break, @Tolerance, @Standard,
                                         @FirstInUtc, @LastOutUtc, @Gap, @Approved, @Disposition, 0,
                                         @LateDecision, @EarlyDecision, @FullDayThreshold, @IsRest, @OnLeave, @Holiday,
                                         0, 0, 0);      -- a manual entry states its exit minutes itself: no permission windows, no DST hour

    DECLARE @FinalStatus VARCHAR(20) = COALESCE(@Status, (SELECT [Status] FROM @r));
    DECLARE @FinalBranch INT = COALESCE(@BranchId, @EmpBranchOn);
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

/* ───────────────────────── 6. D10 on every HR-facing writer; several exit permissions a day; Beirut's date ───────────────────────── */
/* attendance.usp_Attendance_HrAdjustDay */
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
    /* script 83 (D10): a day that is already PAID for this employee is changed by a payroll adjustment, not here */
    DECLARE @PaidEmp INT, @PaidDate DATE, @PaidRc INT;
    SELECT @PaidEmp = EmployeeId, @PaidDate = WorkDate FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
    EXEC @PaidRc = payroll.usp_AssertPeriodOpen @PaidEmp, @PaidDate;
    IF @PaidRc <> 0 RETURN;

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

/* attendance.usp_Attendance_SetExitApproval */
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
    /* script 83 (D10): a day that is already PAID for this employee is changed by a payroll adjustment, not here */
    DECLARE @PaidEmp INT, @PaidDate DATE, @PaidRc INT;
    SELECT @PaidEmp = EmployeeId, @PaidDate = WorkDate FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
    EXEC @PaidRc = payroll.usp_AssertPeriodOpen @PaidEmp, @PaidDate;
    IF @PaidRc <> 0 RETURN;

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

/* attendance.usp_Attendance_SetExitDisposition */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_SetExitDisposition
    @AttendanceId             BIGINT,
    @Disposition              VARCHAR(20),
    @ExitLeaveMinutesOverride INT = NULL,
    @HrNote                   NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    /* script 83 (D10): a day that is already PAID for this employee is changed by a payroll adjustment, not here */
    DECLARE @PaidEmp INT, @PaidDate DATE, @PaidRc INT;
    SELECT @PaidEmp = EmployeeId, @PaidDate = WorkDate FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
    EXEC @PaidRc = payroll.usp_AssertPeriodOpen @PaidEmp, @PaidDate;
    IF @PaidRc <> 0 RETURN;

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

/* attendance.usp_Attendance_DeleteManual */
CREATE OR ALTER PROCEDURE [attendance].[usp_Attendance_DeleteManual]
    @AttendanceId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    /* script 83 (D10): a day that is already PAID for this employee is changed by a payroll adjustment, not here */
    DECLARE @PaidEmp INT, @PaidDate DATE, @PaidRc INT;
    SELECT @PaidEmp = EmployeeId, @PaidDate = WorkDate FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
    EXEC @PaidRc = payroll.usp_AssertPeriodOpen @PaidEmp, @PaidDate;
    IF @PaidRc <> 0 RETURN;

    DECLARE @EmployeeId INT, @WorkDate DATE, @IsManual BIT;
    SELECT @EmployeeId = EmployeeId, @WorkDate = WorkDate, @IsManual = IsManual
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;

    IF @EmployeeId IS NULL
    BEGIN RAISERROR('Attendance record not found.', 16, 1); RETURN; END
    IF @IsManual = 0
    BEGIN RAISERROR('Only manually added records can be deleted — machine-derived days are corrected, not deleted.', 16, 1); RETURN; END

    BEGIN TRAN;

    DELETE FROM attendance.ATTENDANCE_INTERVAL WHERE AttendanceId = @AttendanceId;
    DELETE FROM attendance.ATTENDANCE_RECORD   WHERE AttendanceId = @AttendanceId;

    /* That day's MANUAL punches go too — otherwise re-processing resurrects the day. */
    DELETE r
    FROM attendance.RAW_DEVICE_LOG r
    WHERE r.EmployeeId = @EmployeeId
      AND CAST(r.PunchTimeUtc AS DATE) = @WorkDate
      AND r.[Source] = 'Manual';

    COMMIT;

    /* Machine punches (if any) rebuild the day honestly. */
    EXEC attendance.usp_Attendance_ReprocessDay @WorkDate = @WorkDate;
END;
GO

/* attendance.usp_Correction_Create */
CREATE OR ALTER PROCEDURE attendance.usp_Correction_Create
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
    /* script 83 (D10): a day that is already PAID for this employee is changed by a payroll adjustment, not here */
    DECLARE @PaidEmp INT, @PaidDate DATE, @PaidRc INT;
    SELECT @PaidEmp = EmployeeId, @PaidDate = WorkDate FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
    EXEC @PaidRc = payroll.usp_AssertPeriodOpen @PaidEmp, @PaidDate;
    IF @PaidRc <> 0 RETURN;

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

/* attendance.usp_Correction_Approve */
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
    /* script 83 (D10): a day that is already PAID for this employee is changed by a payroll adjustment, not here */
    DECLARE @PaidEmp INT, @PaidDate DATE, @PaidRc INT;
    SELECT @PaidEmp = EmployeeId, @PaidDate = WorkDate FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
    EXEC @PaidRc = payroll.usp_AssertPeriodOpen @PaidEmp, @PaidDate;
    IF @PaidRc <> 0 RETURN;

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

/* attendance.usp_Anomaly_Decide */
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
    /* script 83 (D10): a day that is already PAID for this employee is changed by a payroll adjustment, not here */
    DECLARE @PaidRc INT;
    EXEC @PaidRc = payroll.usp_AssertPeriodOpen @Emp, @D;
    IF @PaidRc <> 0 RETURN;
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

/* attendance.usp_Anomaly_DecideAll */
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
      AND an.[Type] IN ('LateArrival', 'EarlyDeparture', 'HalfDayAbsence')
      AND payroll.fn_IsPeriodPaid(a.EmployeeId, a.WorkDate) = 0          -- script 83 (D10): days already paid are left as they were paid
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

/* workflow.usp_ExitPermission_Create */
CREATE OR ALTER PROCEDURE [workflow].[usp_ExitPermission_Create]
    @EmployeeId     INT,
    @RaisedByUserId INT,
    @ExitDate       DATE,
    @FromTime       TIME,
    @ToTime         TIME,
    @Reason         NVARCHAR(300),
    @ConvertToLeave BIT = 1,
    @Title          NVARCHAR(150) = NULL   -- optional override; NULL/blank = auto-compose
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ToTime <= @FromTime
    BEGIN RAISERROR('The return time must be after the leaving time.', 16, 1); RETURN; END
    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = ''
    BEGIN RAISERROR('A reason is required for an exit permission.', 16, 1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId AND IsDeleted = 0)
    BEGIN RAISERROR('Employee not found.', 16, 1); RETURN; END

    DECLARE @Minutes INT = DATEDIFF(MINUTE, @FromTime, @ToTime);

    /* script 83: SEVERAL permissions may be held for one day (a late start and an early finish, two errands), as long
       as their windows do not overlap — the second one used to be refused outright. */
    IF EXISTS (
        SELECT 1 FROM workflow.EXIT_PERMISSION ep
        JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
        WHERE ep.EmployeeId = @EmployeeId AND ep.ExitDate = @ExitDate
          AND r.[Status] IN ('Pending','Approved')
          AND ep.FromTime < @ToTime AND ep.ToTime > @FromTime)
    BEGIN
        RAISERROR('This employee already has a pending or approved exit permission that overlaps those times.', 16, 1);
        RETURN;
    END

    /* The standard title — the ONE definition of the format. The optional override
       wins only when it is a non-blank string. */
    DECLARE @AutoTitle NVARCHAR(150) =
        CONCAT(N'Exit permission ', CONVERT(CHAR(10), @ExitDate, 23), N' ',
               LEFT(CONVERT(VARCHAR(8), @FromTime, 108), 5), N'-',
               LEFT(CONVERT(VARCHAR(8), @ToTime, 108), 5),
               N' (', @Minutes, N' min requested)');

    DECLARE @FinalTitle NVARCHAR(150) =
        COALESCE(NULLIF(LTRIM(RTRIM(@Title)), N''), @AutoTitle);

    DECLARE @Submitted TABLE (RequestInstanceId INT, [Status] VARCHAR(20),
                              CurrentStepNo INT, WorkflowDefinitionId INT, WorkflowVersion INT, MinRequesterTier INT);

    BEGIN TRAN;
 
    INSERT INTO @Submitted
    EXEC workflow.usp_Request_Submit
         @RequestTypeCode = 'EXIT_PERMISSION', @EmployeeId = @EmployeeId,
         @RaisedByUserId = @RaisedByUserId, @Title = @FinalTitle;

    DECLARE @ReqId INT = (SELECT TOP 1 RequestInstanceId FROM @Submitted);

    IF @ReqId IS NULL
    BEGIN
        ROLLBACK TRAN;
        RAISERROR('The request could not be submitted - check that an EXIT_PERMISSION workflow is published.', 16, 1);
        RETURN;
    END

    INSERT INTO workflow.EXIT_PERMISSION
        (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime,
         RequestedMinutes, ApprovedMinutes, Reason, ConvertToLeave)
    VALUES (@ReqId, @EmployeeId, @ExitDate, @FromTime, @ToTime,
            @Minutes, @Minutes, @Reason, @ConvertToLeave);

    DECLARE @NewId INT = CAST(SCOPE_IDENTITY() AS INT);

    COMMIT TRAN;

    IF EXISTS (SELECT 1 FROM @Submitted WHERE [Status] = 'Approved')
        EXEC workflow.usp_ExitPermission_ApplyToAttendance @ExitPermissionId = @NewId;

    SELECT ep.ExitPermissionId, ep.RequestInstanceId, ep.EmployeeId, ep.ExitDate,
           ep.FromTime, ep.ToTime, ep.RequestedMinutes, ep.ApprovedMinutes,
           ep.ConvertToLeave, r.[Status], r.CurrentStepNo, r.Title
    FROM workflow.EXIT_PERMISSION ep
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
    WHERE ep.ExitPermissionId = @NewId;
END;
GO

/* workflow.usp_Overtime_Create */
CREATE OR ALTER PROCEDURE workflow.usp_Overtime_Create
    @EmployeeId INT, @RaisedByUserId INT,
    @WorkDate DATE, @RequestedMinutes INT,
    @Reason NVARCHAR(500)=NULL, @Title NVARCHAR(150)=NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    /* pre-approval is the point: no past dates */
    IF @WorkDate < CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE)      -- script 83: today in Beirut, not the server's clock
    BEGIN RAISERROR('Overtime must be approved before it is worked. This date has already passed.',16,1); RETURN; END

    IF @RequestedMinutes <= 0 OR @RequestedMinutes > 720
    BEGIN RAISERROR('Requested overtime must be between 1 and 720 minutes.',16,1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId=@EmployeeId AND IsDeleted=0)
    BEGIN RAISERROR('Employee not found.',16,1); RETURN; END

    /* one open or approved OT per employee per date */
    IF EXISTS (SELECT 1 FROM workflow.OVERTIME_REQUEST o
               JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId=o.RequestInstanceId
               WHERE o.EmployeeId=@EmployeeId AND o.WorkDate=@WorkDate
                 AND r.[Status] IN ('Pending','OnHold','Approved'))
    BEGIN RAISERROR('An overtime request already exists for this employee on that date.',16,1); RETURN; END

    DECLARE @Name NVARCHAR(120)=(SELECT FullName FROM hr.EMPLOYEE WHERE EmployeeId=@EmployeeId);
    DECLARE @DateS CHAR(10)=CONVERT(char(10),@WorkDate,23);
    IF @Title IS NULL OR LTRIM(RTRIM(@Title))=''
        SET @Title=CONCAT(N'Overtime ',@DateS,N' - ',@Name,N' (',@RequestedMinutes,N' min)');

    BEGIN TRAN;
    DECLARE @Submitted TABLE (RequestInstanceId INT,[Status] VARCHAR(20),CurrentStepNo INT,
                              WorkflowDefinitionId INT,WorkflowVersion INT,MinRequesterTier INT);
    INSERT INTO @Submitted
    EXEC workflow.usp_Request_Submit @RequestTypeCode='OVERTIME',
         @EmployeeId=@EmployeeId,@RaisedByUserId=@RaisedByUserId,@Title=@Title;

    DECLARE @ReqId INT=(SELECT TOP 1 RequestInstanceId FROM @Submitted);
    INSERT INTO workflow.OVERTIME_REQUEST
        (RequestInstanceId,EmployeeId,WorkDate,RequestedMinutes,Reason)
    VALUES (@ReqId,@EmployeeId,@WorkDate,@RequestedMinutes,@Reason);

    /* ---- FIX 06b -------------------------------------------------------
       The typed payload row is inserted by THIS procedure, AFTER
       usp_Request_Submit has already returned. So when the chain auto-approved
       at submit (every step skipped), the ApplyApprovalEffects call inside
       Submit ran against a request whose payload did not exist yet, every
       EXISTS guard was false, and no effect was applied -- F6 stayed open on
       exactly the path 06 was written to close.
       Applying them HERE, where the payload exists, closes it. The call is
       idempotent and type-guarded, so it is a no-op for a type whose effect
       is not implemented (or already applied).
       -------------------------------------------------------------------- */
    DECLARE @__ReqId INT = (SELECT TOP 1 RequestInstanceId FROM @Submitted);
    IF EXISTS (SELECT 1 FROM @Submitted WHERE [Status] = 'Approved')
        EXEC workflow.usp_Request_ApplyApprovalEffects
             @RequestInstanceId = @__ReqId, @ActorUserId = @RaisedByUserId;

    COMMIT TRAN;

    /* context for the form: that day's roster */
    SELECT s.RequestInstanceId, s.[Status], s.CurrentStepNo,
           sh.Name AS ShiftName, sh.StartTime, sh.EndTime,
           CAST(CASE WHEN sa.ShiftAssignmentId IS NULL OR sa.IsRestDay=1
                     THEN 1 ELSE 0 END AS BIT) AS IsRestDayOrUnrostered
    FROM @Submitted s
    LEFT JOIN attendance.SHIFT_ASSIGNMENT sa
           ON sa.EmployeeId=@EmployeeId AND sa.WorkDate=@WorkDate
    LEFT JOIN attendance.SHIFT sh ON sh.ShiftId=sa.ShiftId;
END;
GO

/* ───────────────────────── 7. D6: the processor says how many of the days it derived were LATE arrivals ───────────────────────── */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_ProcessRawLogs
    @WorkDate DATE = NULL,                     -- NULL = every unprocessed punch
    @Quiet    BIT  = 0,                        -- 1 = no result set (internal callers)
    @DaysOut  INT  = NULL OUTPUT,
    @LateDaysOut INT = NULL OUTPUT             -- script 83 (D6): of those, the days that ALREADY had a record — a punch arrived after the day was processed
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* the employee-days that have anything NEW, by ATTRIBUTED date; each is then re-derived from ALL its punches —
       which is what makes a late-arriving punch correct the day it belongs to, in the same cycle it arrives in */
    DECLARE @day TABLE (EmployeeId INT, WorkDate DATE, HadRecord BIT, PRIMARY KEY (EmployeeId, WorkDate));
    INSERT INTO @day (EmployeeId, WorkDate, HadRecord)
    SELECT x.EmployeeId, x.WorkDate,
           CASE WHEN EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = x.EmployeeId AND a.WorkDate = x.WorkDate) THEN 1 ELSE 0 END
    FROM (SELECT DISTINCT r.EmployeeId, attendance.fn_AttributedWorkDate(r.EmployeeId, r.PunchTimeUtc) AS WorkDate
          FROM attendance.RAW_DEVICE_LOG r
          WHERE r.IsProcessed = 0 AND r.EmployeeId IS NOT NULL
            AND (@WorkDate IS NULL OR attendance.fn_AttributedWorkDate(r.EmployeeId, r.PunchTimeUtc) = @WorkDate)) x;

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
    SET @LateDaysOut = (SELECT COUNT(*) FROM @day WHERE HadRecord = 1);
    IF @Quiet = 0 SELECT @n AS EmployeeDaysProcessed;
END;
GO

/* ───────────────────────── 8. worked without roster ───────────────────────── */
/* Employee-days that have punches but NO attendance record because the approved roster of the month gives the employee
   no row for the day. HR either adds the day to the roster (it is then derived on the next reprocess) or leaves it. */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_GetWorkedWithoutRoster
    @FromDate DATE, @ToDate DATE, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH p AS (
        SELECT r.EmployeeId, attendance.fn_AttributedWorkDate(r.EmployeeId, r.PunchTimeUtc) AS WorkDate, r.PunchTimeUtc
        FROM attendance.RAW_DEVICE_LOG r
        WHERE r.EmployeeId IS NOT NULL
          AND r.PunchTimeUtc >= CAST(@FromDate AS DATETIME2) AND r.PunchTimeUtc < CAST(DATEADD(DAY, 2, @ToDate) AS DATETIME2)
    ), d AS (
        SELECT p.EmployeeId, p.WorkDate, MIN(p.PunchTimeUtc) AS FirstPunch, MAX(p.PunchTimeUtc) AS LastPunch, COUNT(*) AS PunchCount
        FROM p WHERE p.WorkDate BETWEEN @FromDate AND @ToDate
        GROUP BY p.EmployeeId, p.WorkDate
    )
    SELECT d.EmployeeId, e.FullName AS EmployeeName, x.BranchId, b.Name AS BranchName, d.WorkDate,
           d.FirstPunch, d.LastPunch, d.PunchCount,
           DATEDIFF(MINUTE, d.FirstPunch, d.LastPunch) AS WorkedMinutes
    FROM d
    JOIN hr.EMPLOYEE e ON e.EmployeeId = d.EmployeeId AND e.IsDeleted = 0
    CROSS APPLY (SELECT hr.fn_EmployeeBranchOn(d.EmployeeId, d.WorkDate) AS BranchId) x
    JOIN hr.BRANCH b ON b.BranchId = x.BranchId
    WHERE (@BranchId IS NULL OR x.BranchId = @BranchId)
      AND EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                  WHERE rm.BranchId = x.BranchId AND rm.MonthDate = DATEFROMPARTS(YEAR(d.WorkDate), MONTH(d.WorkDate), 1) AND rm.[Status] = 'Approved')
      AND NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa WHERE sa.EmployeeId = d.EmployeeId AND sa.WorkDate = d.WorkDate)
      AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = d.EmployeeId AND a.WorkDate = d.WorkDate)
    ORDER BY d.WorkDate DESC, e.FullName;
END;
GO

/* ───────────────────────── 9. D9: unknown device users ───────────────────────── */
/* A punch whose (device, PIN) is enrolled to nobody was never lost — usp_RawLog_Insert stores it with EmployeeId NULL.
   This VIEW is that quarantine, under the name HR and the API use; a separate table would be a second copy of the same
   punches, to be kept in step for ever. */
CREATE OR ALTER VIEW attendance.DEVICE_PUNCH_QUARANTINE
AS
    SELECT r.RawLogId, r.DeviceId, d.SerialNumber, d.[Name] AS DeviceName, d.BranchId, b.Name AS BranchName,
           r.EnrollPin, r.PunchTimeUtc AS PunchTime, r.PunchType, r.[Source], r.CreatedUtc AS ReceivedUtc
    FROM attendance.RAW_DEVICE_LOG r
    LEFT JOIN attendance.DEVICE d ON d.DeviceId = r.DeviceId
    LEFT JOIN hr.BRANCH b ON b.BranchId = d.BranchId
    WHERE r.EmployeeId IS NULL;
GO
CREATE OR ALTER PROCEDURE attendance.usp_DevicePunchQuarantine_GetAll
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    /* one line per unknown device user: what HR needs to recognise whose PIN it is */
    SELECT q.DeviceId, q.SerialNumber, q.DeviceName, q.BranchId, q.BranchName, q.EnrollPin,
           COUNT(*) AS PunchCount, MIN(q.PunchTime) AS FirstPunch, MAX(q.PunchTime) AS LastPunch
    FROM attendance.DEVICE_PUNCH_QUARANTINE q
    WHERE @BranchId IS NULL OR q.BranchId = @BranchId
    GROUP BY q.DeviceId, q.SerialNumber, q.DeviceName, q.BranchId, q.BranchName, q.EnrollPin
    ORDER BY MAX(q.PunchTime) DESC;
END;
GO
CREATE OR ALTER PROCEDURE attendance.usp_DevicePunchQuarantine_MapToEmployee
    @DeviceId INT, @EnrollPin VARCHAR(30), @EmployeeId INT, @ActedByUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId AND IsDeleted = 0)
    BEGIN RAISERROR('Employee not found.', 16, 1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM attendance.DEVICE WHERE DeviceId = @DeviceId)
    BEGIN RAISERROR('Device not found.', 16, 1); RETURN; END
    DECLARE @Owner INT = (SELECT TOP 1 EmployeeId FROM attendance.EMPLOYEE_DEVICE WHERE DeviceId = @DeviceId AND EnrollPin = @EnrollPin);
    IF @Owner IS NOT NULL AND @Owner <> @EmployeeId
    BEGIN RAISERROR('That PIN is already enrolled to another employee on this device.', 16, 1); RETURN; END

    /* the days the quarantined punches belong to, worked out BEFORE they change hands */
    DECLARE @day TABLE (WorkDate DATE PRIMARY KEY);
    BEGIN TRAN;
    IF @Owner IS NULL
        INSERT INTO attendance.EMPLOYEE_DEVICE (EmployeeId, DeviceId, EnrollPin) VALUES (@EmployeeId, @DeviceId, @EnrollPin);
    UPDATE attendance.RAW_DEVICE_LOG SET EmployeeId = @EmployeeId, IsProcessed = 0
    WHERE DeviceId = @DeviceId AND EnrollPin = @EnrollPin AND EmployeeId IS NULL;
    DECLARE @Resolved INT = @@ROWCOUNT;
    COMMIT TRAN;

    INSERT INTO @day
    SELECT DISTINCT attendance.fn_AttributedWorkDate(@EmployeeId, r.PunchTimeUtc)
    FROM attendance.RAW_DEVICE_LOG r
    WHERE r.DeviceId = @DeviceId AND r.EnrollPin = @EnrollPin AND r.EmployeeId = @EmployeeId AND r.IsProcessed = 0;

    /* REPLAY: each of those days is derived from all its punches; days already paid stay as they were paid */
    DECLARE @d DATE, @Days INT = 0, @Paid INT = 0, @Outcome VARCHAR(10);
    DECLARE qc CURSOR LOCAL FAST_FORWARD FOR SELECT WorkDate FROM @day ORDER BY WorkDate;
    OPEN qc; FETCH NEXT FROM qc INTO @d;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @EmployeeId, @WorkDate = @d, @Outcome = @Outcome OUTPUT;
        IF @Outcome = 'Locked' SET @Paid += 1; ELSE SET @Days += 1;
        FETCH NEXT FROM qc INTO @d;
    END
    CLOSE qc; DEALLOCATE qc;
    UPDATE attendance.RAW_DEVICE_LOG SET IsProcessed = 1
    WHERE DeviceId = @DeviceId AND EnrollPin = @EnrollPin AND EmployeeId = @EmployeeId AND IsProcessed = 0;

    SELECT @Resolved AS PunchesResolved, @Days AS DaysDerived, @Paid AS DaysAlreadyPaid;
END;
GO

/* ───────────────────────── 10. verification ───────────────────────── */
DECLARE @p INT = (SELECT COUNT(*) FROM sys.parameters WHERE object_id = OBJECT_ID('attendance.fn_AttendanceDayRule'));
PRINT CONCAT('fn_AttendanceDayRule parameters = ', @p, ' (expected 20)');
PRINT CONCAT('quarantine view = ', CASE WHEN OBJECT_ID('attendance.DEVICE_PUNCH_QUARANTINE') IS NULL THEN 'missing' ELSE 'present' END,
             ', worked-without-roster = ', CASE WHEN OBJECT_ID('attendance.usp_Attendance_GetWorkedWithoutRoster') IS NULL THEN 'missing' ELSE 'present' END);
PRINT 'Script 83 applied.';
GO
