/* ============================================================================
   100_qa3_attendance.sql - the attendance fixes of the QA3 deep test (unit B).
   PREREQUISITES: 82-87 and 99 (99_qa3_leave.sql: workflow.LEAVE_REQUEST.ApprovedToDate and
   hr.usp_LeaveLedger_Reprice). The first batch stops the script when 99 is missing.

   THE EMPLOYMENT WINDOW (ROS-1, ATT-2, REL-1)
     A day before HireDate or after TerminationDate is not a working day for anyone.
     usp_Attendance_ComputeDay returns 'None' there and removes a non-manual record of an open period (with the
     day's exit-permission ledger posting); usp_Attendance_MarkAbsentees skips those days; usp_Attendance_ManualUpsert
     and usp_Correction_Create refuse them with a sentence. (Payroll and readiness: unit E; usp_Employee_Update: unit C.)
   PARTIAL LEAVE (ATT-8, LEV-2, REL-6)
     An approved leave covers FromDate..ISNULL(ApprovedToDate, ToDate): ComputeDay, ManualUpsert, MarkLeaveDays.
     The days beyond are judged from the punches. MarkLeaveDays also re-derives a non-manual 'Leave' day that no
     approved leave covers any more. (RecomputeLeaveRange already walks the whole requested range and lets
     ComputeDay decide each day, so it needs no change.)
   SHIFTS ARE VERSIONED (ATT-7, ROS-9, REL-10)
     usp_Shift_Update refuses to change the start, end, break, grace or overnight flag of a shift used by a past
     day or by recorded attendance (create a new shift and roster it from a date); the name and Active still change.
     Both shift writers refuse a shift that starts and ends at the same time. A Late/Early decision is withdrawn
     (with a note) when the shift start/end it was made against changes (usp_Anomaly_ClearIfPunchChanged).
   THE PROCESSOR (ATT-6)
     usp_Attendance_ProcessRawLogs marks as processed only the raw rows it read (a snapshot of their ids) and runs
     under an application lock: a second concurrent run waits up to 15 s, then skips cleanly (0 days); whatever it
     left is processed by the next run. ComputeDay re-reads the record under UPDLOCK before inserting, so two
     writers of one employee-day can no longer collide on UQ_Attendance.
   CORRECTIONS (ATT-10)
     usp_Correction_Create validates what the correction would write (out after in; a time on the next day only for
     an overnight shift; status; minutes; employment). usp_Correction_Approve runs in ONE transaction: the manual
     writer through INSERT...EXEC with a row check; a refusal rolls everything back (the correction stays Pending,
     the anomaly undecided). usp_Anomaly_Decide (Correct) checks the manual writer's row the same way.
   HOLIDAYS (ATT-14, ROS-5, REL-12)
     core.usp_Holiday_RecomputeDays re-derives only days up to today in Beirut. Upsert and Delete run the holiday
     row, the re-derivation and (NEW core.usp_Holiday_RepriceLeave) hr.usp_LeaveLedger_Reprice (unit D) for every
     employee whose approved leave request spans the date, in one transaction.
   VARIANCE RULINGS (ATT-9)
     The 'Overtime' ruling ("offset overtime") absorbs the uncovered mid-day minutes from the overtime measured that
     day (new rule output OvertimeAbsorbedMinutes); the variance stays covered (handoff 7.2). On the Actual basis
     ExitLeaveMinutes = the permission minutes used in the mid-day gap + at the edges of the day (new output
     PermGapMinutes + PermEdgeMinutes): minutes ruled UnpaidAbsence, Overtime or Ignore are never converted to leave.
   POSTING FOLLOWS THE DAY (REL-13; ATT-15, LEV-15, CON-6)
     NEW workflow.usp_ExitPermission_PostDay posts one day (no result set); usp_ExitPermission_PostLeaveUsage loops
     over it and returns ONE result set with its real count. NEW workflow.usp_ExitPermission_RepostDay: when a
     posted day's leave minutes change (re-derivation, manual edit, ruling, removal), the posting is taken back and
     the day is posted again (never in a paid period). ExitUnpaidDays is reset with it.
   DEVICES (ATT-12, REL-8)
     usp_EmployeeDevice_Map refuses a PIN enrolled for another employee, naming them (409 in the API).
     NEW attendance.usp_DevicePunchQuarantine_Dismiss: HR sets aside the punches of a PIN that belongs to nobody
     (RAW_DEVICE_LOG.DismissedUtc/By/Note; the quarantine view leaves them out; mapping the PIN later takes them back).
   THE MANUAL WRITER MIRRORS THE MACHINE ONE (ATT-13, CON-4)
     usp_Attendance_ManualUpsert: the roster counts only in an approved roster month; an approved half-day leave
     covers half the day and the other half is measured (HalfDayAbsence as in ComputeDay); refusals RETURN 1;
     @Quiet = 1 sends no result set (usp_Attendance_RecomputeManualDay), so decide / decide-all answer with their
     own row, and a refusal there rolls the decision back.
   SMALLER ONES
     Status precedence follows the handoff: leave, public holiday, rest day, punches (QA2 recorded no decision).
     A holiday worked with a lost punch is a MissingPunch anomaly. usp_ExitPermission_Create and
     usp_Overtime_Create refuse a date outside the employment; the exit-permission overlap check counts OnHold
     requests; usp_Overtime_Create checks the Submit row (CON: convention 4). usp_ExitPermission_Create no longer
     answers with usp_ExitPermission_ApplyToAttendance's count when the request auto-approves (CON-3: @Quiet).
     usp_Attendance_SetExitApproval @ClearHrApproval = 1 removes HR's own approved figure, so the approved exit
     permissions decide the day again (it used to be sticky). SetExitApproval / SetExitDisposition re-run a MANUAL day
     through the manual writer (the approval and the ruling move its cover with the same rule). usp_Attendance_DeleteManual
     refuses a day that carries correction requests (it failed on the foreign key) and re-posts the day's exit leave.
   REFUSAL AFTER A WRITE: Correction_Approve, Anomaly_Decide / _DecideAll, SetExitApproval / _Disposition and
     Holiday_Upsert / _Delete undo their own work and nothing more when they run inside a caller's transaction
     (SAVE TRAN), and roll back as before when they own it.

   DATA REPAIRS (section 9; guarded, idempotent; never a paid period - ComputeDay leaves paid days as they were paid):
     R1 non-manual records outside the employment are re-derived (= removed, with their exit-permission posting);
     R2 non-manual 'Leave' days beyond an approved leave's ApprovedToDate are re-derived from the punches;
     R3 non-manual records on FUTURE dates with no punch (written by the old holiday re-derivation) are deleted;
     R4 non-manual days with an exit variance are re-derived (the Overtime ruling, the leave minutes; a changed
        posted figure is re-posted); R5 rest days that are public holidays become Holiday; R6 a holiday worked with
        a lost punch gets its MissingPunch anomaly; R7 corrections recorded as Approved whose day never changed
        (the old approve ignored the manual writer's refusal) go back to Pending, with their anomaly undecided.

   STALE-COPY GUARD: attendance.usp_EmployeeDevice_Map's latest repo definition is in attendance_full_v3.sql; the
   batch before its redefinition stops the script if the live procedure has a parameter this one lacks.

   Idempotent (CREATE OR ALTER, IF COL_LENGTH ... IS NULL, IF NOT EXISTS). Pure ASCII. Apply with sqlcmd -I -b.
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------- 0. prerequisites */
/* sqlcmd -b stops at the first RAISERROR; SET NOEXEC ON stops the rest in a tool that does not */
IF COL_LENGTH('workflow.LEAVE_REQUEST', 'ApprovedToDate') IS NULL
BEGIN
    RAISERROR('100_qa3_attendance.sql: workflow.LEAVE_REQUEST.ApprovedToDate is missing - apply 99_qa3_leave.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO
IF OBJECT_ID('hr.usp_LeaveLedger_Reprice', 'P') IS NULL
BEGIN
    RAISERROR('100_qa3_attendance.sql: hr.usp_LeaveLedger_Reprice is missing - apply 99_qa3_leave.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ---------------------------------------------------------------- 1. columns */
/* a quarantined punch HR has set aside (a PIN that belongs to nobody): kept, so the device's re-sent copy stays a
   duplicate, but no longer waiting */
IF COL_LENGTH('attendance.RAW_DEVICE_LOG', 'DismissedUtc') IS NULL
    ALTER TABLE attendance.RAW_DEVICE_LOG ADD DismissedUtc DATETIME2 NULL;
IF COL_LENGTH('attendance.RAW_DEVICE_LOG', 'DismissedByUserId') IS NULL
    ALTER TABLE attendance.RAW_DEVICE_LOG ADD DismissedByUserId INT NULL;
IF COL_LENGTH('attendance.RAW_DEVICE_LOG', 'DismissNote') IS NULL
    ALTER TABLE attendance.RAW_DEVICE_LOG ADD DismissNote NVARCHAR(300) NULL;
GO
/* QA3 (DB-3): EXIT_PERMISSION.Minutes was split into RequestedMinutes / ApprovedMinutes in production
   (workflow_exit_permission_minutes_fix.sql says so) but no repo script does it; a database built from the scripts
   gets it here. A database that has the new columns is not touched. */
IF COL_LENGTH('workflow.EXIT_PERMISSION', 'Minutes') IS NOT NULL AND COL_LENGTH('workflow.EXIT_PERMISSION', 'RequestedMinutes') IS NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_ExitPerm_Minutes' AND parent_object_id = OBJECT_ID('workflow.EXIT_PERMISSION'))
        ALTER TABLE workflow.EXIT_PERMISSION DROP CONSTRAINT CK_ExitPerm_Minutes;
    EXEC sp_rename 'workflow.EXIT_PERMISSION.Minutes', 'RequestedMinutes', 'COLUMN';
    EXEC ('ALTER TABLE workflow.EXIT_PERMISSION ADD CONSTRAINT CK_ExitPerm_Minutes CHECK (RequestedMinutes > 0)');
END
IF COL_LENGTH('workflow.EXIT_PERMISSION', 'ApprovedMinutes') IS NULL
    ALTER TABLE workflow.EXIT_PERMISSION ADD ApprovedMinutes INT NULL;
GO

/* ---------------------------------------------------------------- 2. THE RULE */
/* Changes from script 83: (a) status precedence leave > public holiday > rest day > punches (handoff 7.2);
   (b) the 'Overtime' ruling absorbs the uncovered mid-day minutes from the overtime measured that day
   (OvertimeAbsorbedMinutes) - they were paid twice: covered AND paid as overtime; (c) PermGapMinutes = the approved
   minutes spent on the mid-day gap, so the writers convert to leave only the permission minutes actually used
   (PermGapMinutes + PermEdgeMinutes), never a variance minute. Still no table access. */
CREATE OR ALTER FUNCTION attendance.fn_AttendanceDayRule
(
    @ShiftStartUtc           DATETIME2,     -- NULL = no rostered shift (default standard day; no late / early rule)
    @ShiftEndUtc             DATETIME2,     -- already on the next day for a shift that crosses midnight
    @BreakMinutes            INT,
    @ToleranceMinutes        INT,           -- SHIFT.GraceMinutes if set, else the AttendanceToleranceMinutes setting
    @StandardMinutes         INT,           -- End - Start - Break, or the default standard day when there is no shift
    @FirstInUtc              DATETIME2,
    @LastOutUtc              DATETIME2,
    @GapMinutes              INT,           -- sum of the mid-day out->in gaps between paired intervals
    @ExitApprovedMinutes     INT,           -- HR's figure, else the sum of the approved exit permissions of the day
    @Disposition             VARCHAR(20),   -- HR's ruling on the (mid-day) variance: UnpaidAbsence | Overtime | Ignore | NULL
    @OvertimeApprovedMinutes INT,           -- sum of the approved OVERTIME_REQUEST minutes of the day
    @LateDecision            VARCHAR(10),   -- the LateArrival anomaly's decision: NULL | Excused | Deducted | Corrected
    @EarlyDecision           VARCHAR(10),   -- the EarlyDeparture anomaly's decision: NULL | Excused | Deducted | Corrected
    @FullDayThreshold        DECIMAL(5,2),
    @IsRestDay               BIT,
    @IsOnLeave               BIT,
    @IsHoliday               BIT,
    @PermLateMinutes         INT,           -- approved permission minutes whose window overlaps [shift start, first in)
    @PermEarlyMinutes        INT,           -- ... overlaps (last out, shift end]
    @DstExtraMinutes         INT            -- real - wall minutes of the shift when positive (the autumn DST night)
)
RETURNS @day TABLE
(
    [Status] VARCHAR(20), EffectiveInUtc DATETIME2, EffectiveOutUtc DATETIME2,
    LateMinutes INT, LateDeductMinutes INT, EarlyExitMinutes INT, MidDayGapMinutes INT,
    ExitActualMinutes INT, ExitApprovedMinutes INT, ExitVarianceMinutes INT, OvertimeMinutes INT,
    WorkedMinutes INT, CoveredMinutes INT, DayFraction DECIMAL(5,2), IsFullDay BIT, ShortfallMinutes INT,
    BreakApplied INT, StandardMinutes INT, EarlyDeductMinutes INT, ToleranceMinutes INT, PermEdgeMinutes INT,
    PermGapMinutes INT, OvertimeAbsorbedMinutes INT
)
AS
BEGIN
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

    /* QA3 (ATT-9): the variance ruled 'Overtime' COMES OUT OF the overtime of the day - as far as there is any.
       The minutes stay covered (handoff 7.2), so they are no longer paid twice (covered and paid as overtime). */
    DECLARE @Variance INT = @MidDay - @Pool;
    DECLARE @Absorbed INT = CASE WHEN @Disposition = 'Overtime' AND @Variance > 0
                                 THEN CASE WHEN @Variance < @OtMeasured THEN @Variance ELSE @OtMeasured END
                                 ELSE 0 END;

    DECLARE @Covered INT = @PermForGap
                         + CASE WHEN @Disposition IN ('Ignore', 'Overtime') AND @Variance > 0 THEN @Variance ELSE 0 END
                         + (@RawLate  - @LateDeduct)
                         + (@RawEarly - @EarlyDeduct);

    /* QA3: the handoff's precedence - approved leave, then a public holiday, then a rostered rest day, then the
       punches (script 76 put the rest day before the holiday; no QA report decided it) */
    DECLARE @Status VARCHAR(20) = CASE WHEN @Leave = 1 THEN 'Leave' WHEN @Hol = 1 THEN 'Holiday' WHEN @Rest = 1 THEN 'RestDay'
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
           CASE WHEN @Measured = 1 THEN @Variance ELSE 0 END,
           /* a rest day worked: overtime only as far as it was approved; leave and holidays carry none */
           CASE WHEN @Measured = 1 THEN @OtMeasured - @Absorbed
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
           CASE WHEN @Measured = 1 THEN @LateCov + @EarlyCov + @EarlyCovPool ELSE 0 END,
           CASE WHEN @Measured = 1 THEN @PermForGap ELSE 0 END,
           CASE WHEN @Measured = 1 THEN @Absorbed ELSE 0 END;
    RETURN;
END;
GO

/* ---------------------------------------------------------------- 3. a decision answers a fact */
/* Script 83 withdrew an Excused / Deducted decision when the PUNCH it was made about changed. QA3 (ATT-7): it is
   also withdrawn when the SHIFT time it was measured against changed (a LateArrival against the start, an
   EarlyDeparture against the end) - a roster row changed on a past day, a half-day leave approved later. Callers
   that pass @CheckShift = 1 (both writers) give the shift times the day is measured against now. Runs BEFORE the
   writers read the decisions, so the figures are derived without a withdrawn one. 'Corrected' rows are never touched. */
CREATE OR ALTER PROCEDURE attendance.usp_Anomaly_ClearIfPunchChanged
    @AttendanceId  BIGINT,
    @FirstInUtc    DATETIME2,
    @LastOutUtc    DATETIME2,
    @ShiftStartUtc DATETIME2 = NULL,
    @ShiftEndUtc   DATETIME2 = NULL,
    @CheckShift    BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @AttendanceId IS NULL RETURN;
    DECLARE @Arrow NCHAR(1) = NCHAR(8594), @Dash NCHAR(1) = NCHAR(8212);
    UPDATE an
    SET an.Note = LEFT(CONCAT(
            CASE WHEN x.PunchChanged = 1
                 THEN CONCAT(N'The punch changed after this was decided (was ', an.Decision, N', ', an.[Minutes], N' min, ',
                             CASE WHEN an.[Type] = 'LateArrival'
                                  THEN CONCAT(N'in ', CONVERT(VARCHAR(5), an.PunchInUtc, 108), N' ', @Arrow, N' ', ISNULL(CONVERT(VARCHAR(5), @FirstInUtc, 108), N'none'))
                                  ELSE CONCAT(N'out ', CONVERT(VARCHAR(5), an.PunchOutUtc, 108), N' ', @Arrow, N' ', ISNULL(CONVERT(VARCHAR(5), @LastOutUtc, 108), N'none')) END,
                             N') ', @Dash, N' decide again.')
                 ELSE CONCAT(N'The shift changed after this was decided (was ', an.Decision, N', ', an.[Minutes], N' min, ',
                             CASE WHEN an.[Type] = 'LateArrival'
                                  THEN CONCAT(N'start ', CONVERT(VARCHAR(5), an.ShiftStartUtc, 108), N' ', @Arrow, N' ', ISNULL(CONVERT(VARCHAR(5), @ShiftStartUtc, 108), N'none'))
                                  ELSE CONCAT(N'end ', CONVERT(VARCHAR(5), an.ShiftEndUtc, 108), N' ', @Arrow, N' ', ISNULL(CONVERT(VARCHAR(5), @ShiftEndUtc, 108), N'none')) END,
                             N') ', @Dash, N' decide again.') END,
            CASE WHEN an.Note IS NULL THEN N'' ELSE CONCAT(N' Earlier note: ', an.Note) END), 300),
        an.Decision = NULL, an.DecidedByUserId = NULL, an.DecidedAt = NULL, an.UpdatedAt = SYSUTCDATETIME()
    FROM attendance.ATTENDANCE_ANOMALY an
    CROSS APPLY (SELECT PunchChanged = CASE WHEN (an.[Type] = 'LateArrival'    AND ISNULL(an.PunchInUtc,  '19000101') <> ISNULL(@FirstInUtc, '19000101'))
                                              OR (an.[Type] = 'EarlyDeparture' AND ISNULL(an.PunchOutUtc, '19000101') <> ISNULL(@LastOutUtc, '19000101'))
                                            THEN 1 ELSE 0 END,
                        ShiftChanged = CASE WHEN @CheckShift = 1
                                             AND (   (an.[Type] = 'LateArrival'    AND ISNULL(an.ShiftStartUtc, '19000101') <> ISNULL(@ShiftStartUtc, '19000101'))
                                                  OR (an.[Type] = 'EarlyDeparture' AND ISNULL(an.ShiftEndUtc,   '19000101') <> ISNULL(@ShiftEndUtc,   '19000101')))
                                            THEN 1 ELSE 0 END) x
    WHERE an.AttendanceId = @AttendanceId
      AND an.Decision IN ('Excused', 'Deducted')
      AND (x.PunchChanged = 1 OR x.ShiftChanged = 1);
END;
GO

/* ---------------------------------------------------------------- 4. exit permissions converted to leave, per day */
/* ONE definition of "post the day" (A3j of script 86, unchanged in substance): the day's ExitLeaveMinutes as leave
   days, keyed by its latest approved convert-to-leave permission, never more than the balance holds; the rest is
   recorded on the day (ExitUnpaidDays) for the payslip to deduct, unless the day is already paid. The ledger row is
   written here, the same row hr.usp_LeaveLedger_PostMovement writes (MovementType Usage, SourceType 'ExitPermission'),
   because this runs inside usp_Attendance_ComputeDay, which must send no result set and may itself be inside an
   INSERT...EXEC. The caller makes sure the day is not posted yet. @LeaveTypeId NULL = no balance known: all unpaid. */
CREATE OR ALTER PROCEDURE workflow.usp_ExitPermission_PostDay
    @EmployeeId      INT,
    @WorkDate        DATE,
    @LeaveTypeId     INT,
    @PostedBy        INT = NULL,
    @Note            NVARCHAR(200) = NULL,
    @LedgerRowPosted BIT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @LedgerRowPosted = 0;

    DECLARE @Id INT, @AttId BIGINT, @Days DECIMAL(6,2);
    SELECT @Id = MAX(ep.ExitPermissionId)
    FROM workflow.EXIT_PERMISSION ep
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
    WHERE r.[Status] = 'Approved' AND ep.ConvertToLeave = 1 AND ep.EmployeeId = @EmployeeId AND ep.ExitDate = @WorkDate;
    SELECT @AttId = AttendanceId, @Days = core.fn_MinutesToLeaveDays(ExitLeaveMinutes)
    FROM attendance.ATTENDANCE_RECORD
    WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate AND ExitLeaveMinutes > 0;
    IF @Id IS NULL OR @AttId IS NULL OR ISNULL(@Days, 0) <= 0 RETURN 0;

    DECLARE @Balance DECIMAL(9,2) = CASE WHEN @LeaveTypeId IS NULL THEN 0
                                         ELSE ISNULL((SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @EmployeeId AND LeaveTypeId = @LeaveTypeId), 0) END;
    DECLARE @Use DECIMAL(6,2) = CASE WHEN @Balance <= 0 THEN 0 WHEN @Days <= @Balance THEN @Days ELSE @Balance END;
    DECLARE @Paid BIT = payroll.fn_IsPeriodPaid(@EmployeeId, @WorkDate);

    BEGIN TRAN;
    IF @Use > 0
    BEGIN
        INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, LeaveRequestId, Days, EffectiveDate,
                                     Note, CreatedBy, SourceType, SourceRef)
        VALUES (@EmployeeId, @LeaveTypeId, CONVERT(CHAR(7), @WorkDate, 23), 'Usage', NULL, -@Use, @WorkDate,
                ISNULL(@Note, N'Exit permission converted to leave.'), @PostedBy, 'ExitPermission', @Id);
        SET @LedgerRowPosted = 1;
    END
    IF @Days > @Use AND @Paid = 0
        UPDATE attendance.ATTENDANCE_RECORD SET ExitUnpaidDays = @Days - @Use WHERE AttendanceId = @AttId;
    COMMIT TRAN;
    RETURN 0;
END;
GO

/* QA3 (REL-13): THE POSTING FOLLOWS THE DAY. Once the period close has posted a day (a ledger row, or the unpaid rest
   on the day), a later change of the day's leave minutes - a late punch, a correction, a ruling, a permission taken
   back, the day leaving the employment - used to leave the old posting in place. Called by every writer after it has
   written the day: when the posted figure is no longer the day's, the posting is taken back and the day posted again
   with the same leave type (for a day posted as unpaid only: the type the period close used that month). Never in a
   paid period. No result set. */
CREATE OR ALTER PROCEDURE workflow.usp_ExitPermission_RepostDay
    @EmployeeId INT,
    @WorkDate   DATE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @EmployeeId IS NULL OR @WorkDate IS NULL RETURN 0;
    IF payroll.fn_IsPeriodPaid(@EmployeeId, @WorkDate) = 1 RETURN 0;

    DECLARE @AttId BIGINT, @Unpaid DECIMAL(6,2), @NewDays DECIMAL(6,2);
    SELECT @AttId = AttendanceId, @Unpaid = ExitUnpaidDays, @NewDays = core.fn_MinutesToLeaveDays(ExitLeaveMinutes)
    FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate;

    DECLARE @Posted DECIMAL(9,2), @Type INT, @By INT;
    SELECT @Posted = SUM(-l.Days), @Type = MAX(l.LeaveTypeId), @By = MAX(l.CreatedBy)
    FROM hr.LEAVE_LEDGER l
    JOIN workflow.EXIT_PERMISSION ep ON ep.ExitPermissionId = l.SourceRef
    WHERE l.SourceType = 'ExitPermission' AND ep.EmployeeId = @EmployeeId AND ep.ExitDate = @WorkDate;

    IF @Posted IS NULL AND ISNULL(@Unpaid, 0) = 0 RETURN 0;                          -- not posted: the period close will
    IF ISNULL(@Posted, 0) + ISNULL(@Unpaid, 0) = ISNULL(@NewDays, 0) RETURN 0;        -- posted as it stands

    IF @Type IS NULL
        SELECT TOP (1) @Type = l.LeaveTypeId FROM hr.LEAVE_LEDGER l
        WHERE l.SourceType = 'ExitPermission' AND l.PeriodYearMonth = CONVERT(CHAR(7), @WorkDate, 23)
        ORDER BY l.LeaveLedgerId DESC;
    IF @Type IS NULL
        SELECT TOP (1) @Type = l.LeaveTypeId FROM hr.LEAVE_LEDGER l
        WHERE l.SourceType = 'ExitPermission' AND l.EmployeeId = @EmployeeId
        ORDER BY l.LeaveLedgerId DESC;

    BEGIN TRAN;
    DELETE l
    FROM hr.LEAVE_LEDGER l
    JOIN workflow.EXIT_PERMISSION ep ON ep.ExitPermissionId = l.SourceRef
    WHERE l.SourceType = 'ExitPermission' AND ep.EmployeeId = @EmployeeId AND ep.ExitDate = @WorkDate;
    IF @AttId IS NOT NULL
    BEGIN
        UPDATE attendance.ATTENDANCE_RECORD SET ExitUnpaidDays = NULL WHERE AttendanceId = @AttId;
        EXEC workflow.usp_ExitPermission_PostDay @EmployeeId = @EmployeeId, @WorkDate = @WorkDate, @LeaveTypeId = @Type, @PostedBy = @By,
             @Note = N'Exit permission converted to leave (posted again: the day changed after the period close).';
    END
    COMMIT TRAN;
    RETURN 0;
END;
GO

/* QA3 (ATT-15, LEV-15, CON-6): the nested ledger poster's result sets came first, so the page read "0 posted" (and
   offered to post again). The day is posted by usp_ExitPermission_PostDay, which sends nothing; this procedure sends
   ONE result set, its real count. Selection and order unchanged from script 86. */
CREATE OR ALTER PROCEDURE workflow.usp_ExitPermission_PostLeaveUsage
    @PeriodYearMonth CHAR(7),          -- e.g. '2026-07'
    @LeaveTypeId     INT,              -- which balance it draws from (Annual)
    @PostedBy        INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @from DATE = TRY_CAST(@PeriodYearMonth + '-01' AS DATE);
    IF @from IS NULL BEGIN RAISERROR('The month must look like 2026-08.', 16, 1); RETURN 1; END
    DECLARE @to   DATE = EOMONTH(@from);
    DECLARE @Posted INT = 0, @Row BIT;

    /* ONE posting per employee-day (the day's figure); a day any of whose permissions was already posted is done */
    DECLARE @Emp INT, @Date DATE;
    DECLARE lp_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.EmployeeId, d.ExitDate
        FROM (SELECT ep.EmployeeId, ep.ExitDate
              FROM workflow.EXIT_PERMISSION ep
              JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
              WHERE r.[Status] = 'Approved' AND ep.ConvertToLeave = 1 AND ep.ExitDate BETWEEN @from AND @to
              GROUP BY ep.EmployeeId, ep.ExitDate) d
        JOIN attendance.ATTENDANCE_RECORD a ON a.EmployeeId = d.EmployeeId AND a.WorkDate = d.ExitDate
        WHERE a.ExitLeaveMinutes > 0
          AND NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER l
                          JOIN workflow.EXIT_PERMISSION e2 ON e2.ExitPermissionId = l.SourceRef
                          WHERE l.SourceType = 'ExitPermission' AND e2.EmployeeId = d.EmployeeId AND e2.ExitDate = d.ExitDate)
          AND ISNULL(a.ExitUnpaidDays, 0) = 0
        ORDER BY d.EmployeeId, d.ExitDate;

    OPEN lp_cur;
    FETCH NEXT FROM lp_cur INTO @Emp, @Date;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Row = 0;
        EXEC workflow.usp_ExitPermission_PostDay @EmployeeId = @Emp, @WorkDate = @Date, @LeaveTypeId = @LeaveTypeId,
             @PostedBy = @PostedBy, @LedgerRowPosted = @Row OUTPUT;
        IF @Row = 1 SET @Posted = @Posted + 1;
        FETCH NEXT FROM lp_cur INTO @Emp, @Date;
    END
    CLOSE lp_cur;
    DEALLOCATE lp_cur;

    SELECT @Posted AS LeaveMovementsPosted;
END;
GO

/* ---------------------------------------------------------------- 5. THE WRITER for machine days */
/* Script 83's body; QA3 changes are marked. The signature and the absence of any result set are a contract
   (units C and D call it from their own procedures). */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_ComputeDay
    @EmployeeId INT,
    @WorkDate   DATE,
    @Outcome    VARCHAR(10) = NULL OUTPUT      -- 'Inserted' | 'Updated' | 'Skipped' (manual) | 'Locked' (paid) | 'None' (nothing to say)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Outcome = 'None';

    IF @EmployeeId IS NULL OR @WorkDate IS NULL
    BEGIN RAISERROR('EmployeeId and WorkDate are required.', 16, 1); RETURN; END

    /* ---- the record as it stands (HR's stored decisions are inputs, never recomputed) ---- */
    DECLARE @AttId BIGINT, @IsManual BIT = 0, @Disposition VARCHAR(20), @HrApproved INT,
            @LeaveOverride INT, @ExistingPermissionId INT, @OldExitLeave INT;
    SELECT @AttId = AttendanceId, @IsManual = IsManual, @Disposition = ExitVarianceDisposition,
           @HrApproved = ExitHrApprovedMinutes, @LeaveOverride = ExitLeaveOverrideMinutes,
           @ExistingPermissionId = ExitPermissionId, @OldExitLeave = ExitLeaveMinutes
    FROM attendance.ATTENDANCE_RECORD
    WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate;

    IF @IsManual = 1 BEGIN SET @Outcome = 'Skipped'; RETURN; END

    /* script 83 (D10): a day already PAID for this employee is never re-derived */
    IF payroll.fn_IsPeriodPaid(@EmployeeId, @WorkDate) = 1 BEGIN SET @Outcome = 'Locked'; RETURN; END

    DECLARE @EmpBranch INT, @EmpDeleted BIT, @Hire DATE, @Term DATE;
    SELECT @EmpBranch = BranchId, @EmpDeleted = IsDeleted, @Hire = HireDate, @Term = TerminationDate
    FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId;
    IF @EmpBranch IS NULL AND @EmpDeleted IS NULL RETURN;              -- no such employee

    /* QA3 (ROS-1, ATT-2, REL-1): A DAY OUTSIDE THE EMPLOYMENT IS NOT A WORKING DAY FOR ANYONE - before the hire date or
       after the termination date there is nothing to derive, and a non-manual record left from before (an absence
       marked after the employee left, a hire date corrected later) is removed with the exit-permission leave posted
       for it. A record that carries a correction request stays for HR (the correction references it). */
    IF @WorkDate < @Hire OR @WorkDate > @Term
    BEGIN
        IF @AttId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_CORRECTION c WHERE c.AttendanceId = @AttId)
        BEGIN
            BEGIN TRAN;
            DELETE FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttId AND IsManual = 0;   -- intervals and anomalies cascade
            EXEC workflow.usp_ExitPermission_RepostDay @EmployeeId = @EmployeeId, @WorkDate = @WorkDate;
            COMMIT TRAN;
        END
        RETURN;
    END

    /* script 83 (D7): the branch the employee belonged to ON that day */
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

    /* nothing rostered, nothing punched, nothing recorded -> nothing to say (no absence) */
    IF @HasPunches = 0 AND @Sa IS NULL AND @AttId IS NULL RETURN;

    /* script 83: an unrostered day of an APPROVED roster has no attendance record (listed as worked without roster) */
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

    /* effective direction: 'Alternate' = In, Out, In, Out... ; 'Device' = the terminal's own key */
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

    /* ---- the day's kind and the approvals - read fresh on every run ---- */
    /* QA3 (ATT-8, LEV-2, REL-6): an approved leave covers its APPROVED days only - a partial approval keeps the first
       days (FromDate..ApprovedToDate, script 99); the days beyond are judged from the punches */
    DECLARE @OnLeave BIT = CASE WHEN EXISTS (
        SELECT 1 FROM workflow.LEAVE_REQUEST lr
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
        WHERE lr.EmployeeId = @EmployeeId AND ri.[Status] = 'Approved'
          AND lr.HalfDay IS NULL
          AND @WorkDate BETWEEN lr.FromDate AND ISNULL(lr.ApprovedToDate, lr.ToDate)) THEN 1 ELSE 0 END;
    /* script 83 (D3): an approved HALF-day leave covers half the standard; the other half follows the punches */
    DECLARE @Half CHAR(2) = (SELECT TOP 1 lr.HalfDay FROM workflow.LEAVE_REQUEST lr
                             JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
                             WHERE lr.EmployeeId = @EmployeeId AND ri.[Status] = 'Approved' AND lr.HalfDay IS NOT NULL
                               AND lr.FromDate = @WorkDate AND lr.ToDate = @WorkDate
                               AND ISNULL(lr.ApprovedToDate, lr.ToDate) >= @WorkDate);
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

    /* script 83: WHERE the approved exit permissions lie matters (late window, early window, then the pool) */
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

    /* script 83: the DST nights - the extra real hour of the autumn night is overtime only within an approved request */
    DECLARE @DstExtra INT = 0;
    IF @ShiftStartUtc IS NOT NULL AND @ShiftEndUtc IS NOT NULL
        SET @DstExtra = DATEDIFF(MINUTE, @ShiftStartUtc AT TIME ZONE 'Middle East Standard Time', @ShiftEndUtc AT TIME ZONE 'Middle East Standard Time')
                      - DATEDIFF(MINUTE, @ShiftStartUtc, @ShiftEndUtc);
    IF @DstExtra < 0 SET @DstExtra = 0;

    /* script 83 (D3): with a half-day leave the rule measures the OTHER half as a little day of its own -
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

    /* a decision answers a FACT: withdrawn (with a note) when the punch - QA3 (ATT-7): or the shift time - it was
       made about has changed since */
    EXEC attendance.usp_Anomaly_ClearIfPunchChanged @AttendanceId = @AttId, @FirstInUtc = @FirstIn, @LastOutUtc = @LastOut,
         @ShiftStartUtc = @ShiftStartUtc, @ShiftEndUtc = @ShiftEndUtc, @CheckShift = 1;
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
                      EarlyDeductMinutes INT, PermEdgeMinutes INT, PermGapMinutes INT);
    INSERT INTO @r
    SELECT [Status], LateMinutes, LateDeductMinutes, EarlyExitMinutes, MidDayGapMinutes,
           ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes, OvertimeMinutes, WorkedMinutes,
           CoveredMinutes, DayFraction, IsFullDay, ShortfallMinutes, BreakApplied, StandardMinutes, EarlyDeductMinutes,
           PermEdgeMinutes, PermGapMinutes
    FROM attendance.fn_AttendanceDayRule(@ShiftStartUtc, @ShiftEndUtc, @Break, @Tolerance, @Standard,
                                         @FirstIn, @LastOut, @Gap, @Approved, @Disposition, @OtApproved,
                                         @LateDecision, @EarlyDecision, @FullDayThreshold, @IsRest, @OnLeave, @Holiday,
                                         @PermLate, @PermEarly, @DstExtra);

    /* script 83 (D3): put the two halves together (the leave half covered, the measured half counts for half a day;
       no punch at all in the measured half is a HalfDayAbsence anomaly) */
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
    /* QA3: a public holiday worked with a lost punch is a missing punch too (the holiday-work premium is paid on the
       worked minutes, which a lost out-punch leaves at 0) */
    DECLARE @HasAnomaly BIT = CASE WHEN @HasPunches = 1 AND @Status IN ('Present', 'RestDay', 'Holiday')
                                    AND (@InCount <> @OutCount OR @FirstIn IS NULL OR @LastOut IS NULL) THEN 1 ELSE 0 END;
    DECLARE @BranchId INT = @EmpBranch;
    /* QA3 (ATT-9): on the Actual basis the leave conversion takes the permission minutes the day USED - in the mid-day
       gap and at its edges - never the variance beyond them (ruled unpaid, offset against overtime or ignored) */
    DECLARE @ExitLeave INT = COALESCE(@LeaveOverride, CASE WHEN @LeaveBasis = 'Approved' THEN @Approved
                                                           ELSE (SELECT PermGapMinutes + PermEdgeMinutes FROM @r) END);

    BEGIN TRAN;

    /* QA3 (ATT-6): two writers of the same employee-day (a pull and a push, a reprocess and a replay) no longer both
       insert: the record is read again under an update lock; one HR entered meanwhile is left alone */
    IF @AttId IS NULL
    BEGIN
        DECLARE @NowManual BIT;
        SELECT @AttId = AttendanceId, @NowManual = IsManual, @OldExitLeave = ExitLeaveMinutes
        FROM attendance.ATTENDANCE_RECORD WITH (UPDLOCK, HOLDLOCK)
        WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate;
        IF @NowManual = 1 BEGIN COMMIT TRAN; SET @Outcome = 'Skipped'; RETURN; END
    END

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

    /* ---- the anomalies of the day ---- */
    DECLARE @Late INT = (SELECT LateMinutes FROM @r), @Early INT = (SELECT EarlyExitMinutes FROM @r);
    DECLARE @AutoNote NVARCHAR(300) = CASE WHEN @PermissionId IS NOT NULL THEN CONCAT(N'Covered by exit permission #', @PermissionId, N' (', @Approved, N' min approved).')
                                           ELSE CONCAT(N'Covered by HR exit approval (', @Approved, N' min).') END;
    EXEC attendance.usp_Attendance_SyncAnomalies
        @AttendanceId = @AttId, @EmployeeId = @EmployeeId, @WorkDate = @WorkDate,
        @LateMinutes = @Late, @EarlyExitMinutes = @Early, @HasAnomaly = @HasAnomaly,
        @ShiftStartUtc = @ShiftStartUtc, @ShiftEndUtc = @ShiftEndUtc, @FirstInUtc = @FirstIn, @LastOutUtc = @LastOut,
        @AutoExcuseEarly = 0, @AutoExcuseNote = @AutoNote, @HalfDayAbsenceMinutes = @HalfAbsMinutes;

    /* QA3 (REL-13): the leave minutes moved - a posting made at the period close follows them */
    IF ISNULL(@OldExitLeave, 0) <> ISNULL(@ExitLeave, 0)
        EXEC workflow.usp_ExitPermission_RepostDay @EmployeeId = @EmployeeId, @WorkDate = @WorkDate;

    COMMIT TRAN;
END;
GO

/* ---------------------------------------------------------------- 6. the manual writer */
/* Script 83's body. QA3 (ATT-13): it now mirrors the machine writer - the roster counts only in an approved roster
   month (an unapproved roster is inert for both), an approved HALF-day leave covers half the day and the other half
   is measured (it used to make the whole day 'Leave'), a partial leave covers its approved days only. QA3 (ROS-1): a
   day outside the employment is refused. QA3 (ATT-9): the Actual-basis leave minutes are the permission minutes the
   day used. QA3 (CON-4): @Quiet = 1 sends no result set; every refusal RETURNs 1, so a caller can tell. */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_ManualUpsert
    @EmployeeId       INT,
    @WorkDate         DATE,
    @FirstInUtc       DATETIME2 = NULL,
    @LastOutUtc       DATETIME2 = NULL,
    @ExitMinutes      INT = 0,                 -- a mid-day absence HR knows about (beyond the break)
    @ExitApprovedMins INT = 0,                 -- how much of it was authorised
    @Status           VARCHAR(20) = NULL,      -- NULL = the rule decides (roster, approved leave, punches)
    @BranchId         INT = NULL,
    @HrNote           NVARCHAR(300) = NULL,
    @Quiet            BIT = 0                  -- QA3: 1 = no result set (usp_Attendance_RecomputeManualDay)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @EmployeeId IS NULL OR @WorkDate IS NULL
    BEGIN RAISERROR('EmployeeId and WorkDate are required.', 16, 1); RETURN 1; END
    IF @FirstInUtc IS NOT NULL AND @LastOutUtc IS NOT NULL AND @LastOutUtc < @FirstInUtc
    BEGIN RAISERROR('The out time must not be before the in time.', 16, 1); RETURN 1; END
    IF @Status IS NOT NULL AND @Status NOT IN ('Present', 'Absent', 'RestDay', 'Leave', 'Holiday')
    BEGIN RAISERROR('Status must be Present, Absent, RestDay, Leave or Holiday.', 16, 1); RETURN 1; END
    /* script 83 (D10): a day that is already PAID for this employee is changed by a payroll adjustment, not here */
    DECLARE @PaidRc INT;
    EXEC @PaidRc = payroll.usp_AssertPeriodOpen @EmployeeId, @WorkDate;
    IF @PaidRc <> 0 RETURN 1;

    /* QA3 (ROS-1): outside the employment there is no working day to record */
    DECLARE @Hire DATE, @Term DATE, @EmpName NVARCHAR(150);
    SELECT @Hire = HireDate, @Term = TerminationDate, @EmpName = FullName FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId;
    IF @EmpName IS NULL BEGIN RAISERROR('Employee not found.', 16, 1); RETURN 1; END
    IF @WorkDate < @Hire OR @WorkDate > @Term
    BEGIN
        DECLARE @OutsideMsg NVARCHAR(400) =
            CASE WHEN @WorkDate < @Hire
                 THEN CONCAT(@EmpName, N' was hired on ', CONVERT(CHAR(10), @Hire, 23), N': ', CONVERT(CHAR(10), @WorkDate, 23), N' is not one of their working days.')
                 ELSE CONCAT(@EmpName, N' left on ', CONVERT(CHAR(10), @Term, 23), N': ', CONVERT(CHAR(10), @WorkDate, 23), N' is not one of their working days.') END;
        RAISERROR('%s', 16, 1, @OutsideMsg);
        RETURN 1;
    END

    DECLARE @LeaveBasis VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'ExitLeaveBasis'), 'Actual');
    DECLARE @FullDayThreshold DECIMAL(5,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'FullDayThreshold') AS DECIMAL(5,2)), 1.00);
    DECLARE @ToleranceSetting INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'AttendanceToleranceMinutes') AS INT), 10);
    DECLARE @StdDefault INT = core.fn_StandardDayMinutes();

    /* the record as it stands: HR's stored decisions are inputs */
    DECLARE @AttId BIGINT, @Disposition VARCHAR(20), @LeaveOverride INT, @OldExitLeave INT;
    SELECT @AttId = AttendanceId, @Disposition = ExitVarianceDisposition, @LeaveOverride = ExitLeaveOverrideMinutes,
           @OldExitLeave = ExitLeaveMinutes
    FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate;

    /* the rostered shift - QA3 (ATT-13): like the machine writer, only a roster whose month is APPROVED counts */
    DECLARE @EmpBranchOn INT = hr.fn_EmployeeBranchOn(@EmployeeId, @WorkDate);
    DECLARE @Sa INT, @ShiftGrace INT, @Break INT = 0, @IsRest BIT = 0, @ShiftStart TIME, @ShiftEnd TIME, @Crosses BIT = 0;
    SELECT @Sa = sa.ShiftAssignmentId, @IsRest = ISNULL(sa.IsRestDay, 0),
           @ShiftStart = s.StartTime, @ShiftEnd = s.EndTime,
           @ShiftGrace = s.GraceMinutes, @Break = ISNULL(s.BreakMinutes, 0), @Crosses = ISNULL(s.CrossesMidnight, 0)
    FROM attendance.SHIFT_ASSIGNMENT sa
    LEFT JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
    WHERE sa.EmployeeId = @EmployeeId AND sa.WorkDate = @WorkDate
      AND EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                  WHERE rm.BranchId = @EmpBranchOn
                    AND rm.MonthDate = DATEFROMPARTS(YEAR(@WorkDate), MONTH(@WorkDate), 1)
                    AND rm.[Status] = 'Approved');
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

    /* QA3 (ATT-13, ATT-8): a FULL-day approved leave covering its approved days; a half-day one is handled below */
    DECLARE @OnLeave BIT = CASE WHEN @Status = 'Leave' THEN 1
                                WHEN @Status IS NOT NULL THEN 0
                                WHEN EXISTS (SELECT 1 FROM workflow.LEAVE_REQUEST lr
                                             JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
                                             WHERE lr.EmployeeId = @EmployeeId AND ri.[Status] = 'Approved'
                                               AND lr.HalfDay IS NULL
                                               AND @WorkDate BETWEEN lr.FromDate AND ISNULL(lr.ApprovedToDate, lr.ToDate)) THEN 1 ELSE 0 END;
    DECLARE @Half CHAR(2) = (SELECT TOP 1 lr.HalfDay FROM workflow.LEAVE_REQUEST lr
                             JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
                             WHERE lr.EmployeeId = @EmployeeId AND ri.[Status] = 'Approved' AND lr.HalfDay IS NOT NULL
                               AND lr.FromDate = @WorkDate AND lr.ToDate = @WorkDate
                               AND ISNULL(lr.ApprovedToDate, lr.ToDate) >= @WorkDate);
    /* script 83 (D1 / D7): with no status given, a public holiday of the employee's branch that day decides it */
    DECLARE @Holiday BIT = CASE WHEN @Status = 'Holiday' THEN 1
                                WHEN @Status IS NOT NULL THEN 0
                                ELSE core.fn_IsHoliday(@WorkDate, @EmpBranchOn) END;

    /* QA3 (ATT-13): the half-day leave, exactly as the machine writer does it - the other half is measured */
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

    /* script 83: a decision answers a fact; a correction that moves the punch (QA3: or the shift) clears it */
    EXEC attendance.usp_Anomaly_ClearIfPunchChanged @AttendanceId = @AttId, @FirstInUtc = @FirstInUtc, @LastOutUtc = @LastOutUtc,
         @ShiftStartUtc = @ShiftStartUtc, @ShiftEndUtc = @ShiftEndUtc, @CheckShift = 1;
    DECLARE @LateDecision VARCHAR(10), @EarlyDecision VARCHAR(10), @HalfAbsDecision VARCHAR(10);
    SELECT @LateDecision    = MAX(CASE WHEN [Type] = 'LateArrival'    THEN Decision END),
           @EarlyDecision   = MAX(CASE WHEN [Type] = 'EarlyDeparture' THEN Decision END),
           @HalfAbsDecision = MAX(CASE WHEN [Type] = 'HalfDayAbsence' THEN Decision END)
    FROM attendance.ATTENDANCE_ANOMALY WHERE AttendanceId = @AttId;

    DECLARE @Exit INT = ISNULL(@ExitMinutes, 0), @Approved INT = ISNULL(@ExitApprovedMins, 0);
    DECLARE @Gross INT = CASE WHEN @FirstInUtc IS NULL OR @LastOutUtc IS NULL THEN 0 ELSE DATEDIFF(MINUTE, @FirstInUtc, @LastOutUtc) END;
    /* @ExitMinutes is the absence BEYOND the break; the rule takes the raw gap and absorbs the break itself */
    DECLARE @Gap INT = CASE WHEN @Exit > 0 THEN @Exit + @Break ELSE 0 END;

    DECLARE @r TABLE ([Status] VARCHAR(20), LateMinutes INT, LateDeductMinutes INT, EarlyExitMinutes INT, MidDayGapMinutes INT,
                      ExitActualMinutes INT, ExitApprovedMinutes INT, ExitVarianceMinutes INT, OvertimeMinutes INT, WorkedMinutes INT,
                      CoveredMinutes INT, DayFraction DECIMAL(5,2), IsFullDay BIT, ShortfallMinutes INT, BreakApplied INT, StandardMinutes INT,
                      EarlyDeductMinutes INT, PermEdgeMinutes INT, PermGapMinutes INT);
    INSERT INTO @r
    SELECT [Status], LateMinutes, LateDeductMinutes, EarlyExitMinutes, MidDayGapMinutes,
           ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes, OvertimeMinutes, WorkedMinutes,
           CoveredMinutes, DayFraction, IsFullDay, ShortfallMinutes, BreakApplied, StandardMinutes, EarlyDeductMinutes,
           PermEdgeMinutes, PermGapMinutes
    FROM attendance.fn_AttendanceDayRule(@ShiftStartUtc, @ShiftEndUtc, @Break, @Tolerance, @Standard,
                                         @FirstInUtc, @LastOutUtc, @Gap, @Approved, @Disposition, 0,
                                         @LateDecision, @EarlyDecision, @FullDayThreshold, @IsRest, @OnLeave, @Holiday,
                                         0, 0, 0);      -- a manual entry states its exit minutes itself: no permission windows, no DST hour

    /* QA3 (ATT-13): the two halves together, as in the machine writer */
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

    DECLARE @FinalStatus VARCHAR(20) = COALESCE(@Status, (SELECT [Status] FROM @r));
    DECLARE @FinalBranch INT = COALESCE(@BranchId, @EmpBranchOn);
    DECLARE @ExitLeave INT = COALESCE(@LeaveOverride, CASE WHEN @LeaveBasis = 'Approved' THEN @Approved
                                                           ELSE (SELECT PermGapMinutes + PermEdgeMinutes FROM @r) END);
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
        @AutoExcuseEarly = @AutoExcuse, @AutoExcuseNote = @AutoNote, @HalfDayAbsenceMinutes = @HalfAbsMinutes;

    /* QA3 (REL-13): a posting made at the period close follows the day's leave minutes */
    IF ISNULL(@OldExitLeave, 0) <> ISNULL(@ExitLeave, 0)
        EXEC workflow.usp_ExitPermission_RepostDay @EmployeeId = @EmployeeId, @WorkDate = @WorkDate;

    COMMIT TRAN;

    IF ISNULL(@Quiet, 0) = 0
        SELECT AttendanceId, WorkedMinutes, StandardMinutes, DayFraction, IsFullDay,
               LateMinutes, OvertimeMinutes, ExitActualMinutes, ExitApprovedMinutes,
               ExitVarianceMinutes, ExitLeaveMinutes, [Status],
               CoveredMinutes, EarlyExitMinutes, LateDeductMinutes, EarlyDeductMinutes, HasAnomaly, IsManual, ShortfallMinutes
        FROM attendance.ATTENDANCE_RECORD
        WHERE AttendanceId = @AttId;
    RETURN 0;
END;
GO

/* re-runs the manual entry with the row's own stored inputs (after a decision on a manual day).
   QA3 (CON-4): quietly - the manual writer's row used to reach the client ahead of the decide procedures' own answer
   (decide-all then toasted "0 decided"); its return code tells the caller whether it refused. */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_RecomputeManualDay
    @AttendanceId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Emp INT, @D DATE, @In DATETIME2, @Out DATETIME2, @Exit INT, @Approved INT, @Status VARCHAR(20), @Branch INT, @rc INT;
    SELECT @Emp = EmployeeId, @D = WorkDate, @In = FirstInUtc, @Out = LastOutUtc, @Exit = ExitActualMinutes,
           @Approved = ExitApprovedMinutes, @Status = [Status], @Branch = BranchId
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId AND IsManual = 1;
    IF @Emp IS NULL RETURN 0;
    EXEC @rc = attendance.usp_Attendance_ManualUpsert @EmployeeId = @Emp, @WorkDate = @D, @FirstInUtc = @In, @LastOutUtc = @Out,
         @ExitMinutes = @Exit, @ExitApprovedMins = @Approved, @Status = @Status, @BranchId = @Branch, @HrNote = NULL, @Quiet = 1;
    RETURN ISNULL(@rc, 0);
END;
GO

/* ---------------------------------------------------------------- 7. corrections and decisions */
/* QA3 (ATT-10): a correction is checked when it is RAISED, against what approving it would write: the out time after
   the in time, a time on the work date (or the next day for a shift that crosses midnight), a known status,
   minutes not negative, a day inside the employment. It used to be accepted as typed and refused only at approval. */
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
    IF @PaidRc <> 0 RETURN 1;

    DECLARE @oi DATETIME2, @oo DATETIME2, @oe INT, @os VARCHAR(20);
    SELECT @oi = FirstInUtc, @oo = LastOutUtc, @oe = ExitActualMinutes, @os = [Status]
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;

    IF @os IS NULL
    BEGIN RAISERROR('Attendance record not found.', 16, 1); RETURN 1; END

    IF @NewStatus IS NOT NULL AND @NewStatus NOT IN ('Present', 'Absent', 'RestDay', 'Leave', 'Holiday')
    BEGIN RAISERROR('Status must be Present, Absent, RestDay, Leave or Holiday.', 16, 1); RETURN 1; END
    IF @NewExitMinutes IS NOT NULL AND @NewExitMinutes < 0
    BEGIN RAISERROR('The exit minutes must be zero or more.', 16, 1); RETURN 1; END

    DECLARE @Hire DATE, @Term DATE, @EmpName NVARCHAR(150), @Msg NVARCHAR(400);
    SELECT @Hire = HireDate, @Term = TerminationDate, @EmpName = FullName FROM hr.EMPLOYEE WHERE EmployeeId = @PaidEmp;
    IF @PaidDate < @Hire OR @PaidDate > @Term
    BEGIN
        SET @Msg = CONCAT(@EmpName, CASE WHEN @PaidDate < @Hire THEN CONCAT(N' was hired on ', CONVERT(CHAR(10), @Hire, 23))
                                         ELSE CONCAT(N' left on ', CONVERT(CHAR(10), @Term, 23)) END,
                          N': ', CONVERT(CHAR(10), @PaidDate, 23), N' is not one of their working days.');
        RAISERROR('%s', 16, 1, @Msg); RETURN 1;
    END

    /* the times: on the work date, or the next day only when the day's shift crosses midnight */
    DECLARE @Overnight BIT = ISNULL((SELECT TOP 1 s.CrossesMidnight FROM attendance.SHIFT_ASSIGNMENT sa
                                     JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
                                     WHERE sa.EmployeeId = @PaidEmp AND sa.WorkDate = @PaidDate AND sa.IsRestDay = 0), 0);
    DECLARE @LastDay DATE = CASE WHEN @Overnight = 1 THEN DATEADD(DAY, 1, @PaidDate) ELSE @PaidDate END;
    DECLARE @Where NVARCHAR(200) = CASE WHEN @Overnight = 1
                                        THEN CONCAT(N'on ', CONVERT(CHAR(10), @PaidDate, 23), N' or the next morning (the shift crosses midnight)')
                                        ELSE CONCAT(N'on ', CONVERT(CHAR(10), @PaidDate, 23), N' (the day''s shift does not cross midnight)') END;
    IF @NewFirstInUtc IS NOT NULL AND CAST(@NewFirstInUtc AS DATE) NOT BETWEEN @PaidDate AND @LastDay
    BEGIN SET @Msg = CONCAT(N'The new in time must be ', @Where, N'.'); RAISERROR('%s', 16, 1, @Msg); RETURN 1; END
    IF @NewLastOutUtc IS NOT NULL AND CAST(@NewLastOutUtc AS DATE) NOT BETWEEN @PaidDate AND @LastDay
    BEGIN SET @Msg = CONCAT(N'The new out time must be ', @Where, N'.'); RAISERROR('%s', 16, 1, @Msg); RETURN 1; END
    DECLARE @In DATETIME2 = COALESCE(@NewFirstInUtc, @oi), @Out DATETIME2 = COALESCE(@NewLastOutUtc, @oo);
    IF @In IS NOT NULL AND @Out IS NOT NULL AND @Out <= @In
    BEGIN
        SET @Msg = CONCAT(N'The out time (', CONVERT(CHAR(16), @Out, 120), N') must be after the in time (', CONVERT(CHAR(16), @In, 120), N').');
        RAISERROR('%s', 16, 1, @Msg); RETURN 1;
    END

    INSERT INTO attendance.ATTENDANCE_CORRECTION
        (AttendanceId, RequestedBy, OldFirstInUtc, OldLastOutUtc, OldExitMinutes, OldStatus,
         NewFirstInUtc, NewLastOutUtc, NewExitMinutes, NewStatus, Reason, ApprovalStatus)
    VALUES (@AttendanceId, @RequestedBy, @oi, @oo, @oe, @os,
            @NewFirstInUtc, @NewLastOutUtc, @NewExitMinutes, @NewStatus, @Reason, 'Pending');

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS CorrectionId;
END;
GO

/* QA3 (ATT-10): ONE transaction. The manual writer runs through INSERT...EXEC and its row is checked: when it refuses
   (its sentence is already on its way to the client), everything is rolled back - the correction stays Pending and the
   anomaly undecided. It used to mark the anomaly Corrected and the correction Approved whatever the writer said, and
   leave the day unchanged (and payroll blocked by an anomaly nobody could decide any more). The MissingPunch anomaly is
   stamped before the writer runs, inside the transaction, so the writer's anomaly sync keeps it as the record. */
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
    BEGIN RAISERROR('No pending correction with that id.', 16, 1); RETURN 1; END
    /* script 83 (D10): a day that is already PAID for this employee is changed by a payroll adjustment, not here */
    DECLARE @PaidEmp INT, @PaidDate DATE, @PaidRc INT;
    SELECT @PaidEmp = EmployeeId, @PaidDate = WorkDate FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
    EXEC @PaidRc = payroll.usp_AssertPeriodOpen @PaidEmp, @PaidDate;
    IF @PaidRc <> 0 RETURN 1;

    DECLARE @EmployeeId INT, @WorkDate DATE, @InT DATETIME2, @OutT DATETIME2, @Exit INT, @Approved INT, @Branch INT, @Note NVARCHAR(300);
    SELECT @EmployeeId = EmployeeId, @WorkDate = WorkDate,
           @InT = COALESCE(@ni, FirstInUtc), @OutT = COALESCE(@no, LastOutUtc),
           @Exit = COALESCE(@ne, ExitActualMinutes), @Approved = ExitApprovedMinutes, @Branch = BranchId, @Note = HrNote
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
    IF @EmployeeId IS NULL BEGIN RAISERROR('Attendance record not found.', 16, 1); RETURN 1; END

    DECLARE @m TABLE (AttendanceId BIGINT, WorkedMinutes INT, StandardMinutes INT, DayFraction DECIMAL(5,2), IsFullDay BIT,
                      LateMinutes INT, OvertimeMinutes INT, ExitActualMinutes INT, ExitApprovedMinutes INT,
                      ExitVarianceMinutes INT, ExitLeaveMinutes INT, [Status] VARCHAR(20),
                      CoveredMinutes INT, EarlyExitMinutes INT, LateDeductMinutes INT, EarlyDeductMinutes INT, HasAnomaly BIT, IsManual BIT, ShortfallMinutes INT);

    DECLARE @OuterTran INT = @@TRANCOUNT;   -- inside a caller's transaction a refusal undoes only this procedure's work
    BEGIN TRAN;
    SAVE TRAN qa3_corr_approve;

    /* decided once: a second approver in parallel finds it decided */
    IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_CORRECTION WITH (UPDLOCK, HOLDLOCK)
                   WHERE CorrectionId = @CorrectionId AND ApprovalStatus = 'Pending')
    BEGIN
        IF @OuterTran > 0 AND XACT_STATE() = 1 BEGIN ROLLBACK TRAN qa3_corr_approve; COMMIT TRAN; END ELSE IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        RAISERROR('This correction was already decided.', 16, 1);
        RETURN 1;
    END

    /* the MissingPunch anomaly, if any, is what this correction answers */
    UPDATE attendance.ATTENDANCE_ANOMALY
    SET Decision = 'Corrected', DecidedByUserId = @ApprovedBy, DecidedAt = SYSUTCDATETIME(),
        Note = CONCAT(N'Correction #', @CorrectionId, N' approved.'), UpdatedAt = SYSUTCDATETIME()
    WHERE AttendanceId = @AttendanceId AND [Type] = 'MissingPunch' AND Decision IS NULL;

    INSERT INTO @m EXEC attendance.usp_Attendance_ManualUpsert
        @EmployeeId = @EmployeeId, @WorkDate = @WorkDate, @FirstInUtc = @InT, @LastOutUtc = @OutT,
        @ExitMinutes = @Exit, @ExitApprovedMins = @Approved, @Status = @ns, @BranchId = @Branch, @HrNote = @Note;
    IF NOT EXISTS (SELECT 1 FROM @m)
    BEGIN
        -- the manual writer refused, in its own words: nothing changes
        IF @OuterTran > 0 AND XACT_STATE() = 1 BEGIN ROLLBACK TRAN qa3_corr_approve; COMMIT TRAN; END ELSE IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        RETURN 1;
    END

    UPDATE attendance.ATTENDANCE_CORRECTION
    SET ApprovalStatus = 'Approved', ApprovedBy = @ApprovedBy, ActedUtc = SYSUTCDATETIME()
    WHERE CorrectionId = @CorrectionId AND ApprovalStatus = 'Pending';

    COMMIT TRAN;

    SELECT AttendanceId, WorkedMinutes, DayFraction, LateMinutes FROM @m;
END;
GO

/* Script 83's body; QA3: a refusal of the manual writer (the Correct path, or the re-run of a manual day after an
   Excuse / Deduct) now rolls the decision back instead of committing it over an unchanged day; the manual day is
   re-run quietly (CON-4), so the client reads this procedure's row. */
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
    BEGIN RAISERROR('Decision must be Excuse, Deduct or Correct.', 16, 1); RETURN 1; END

    DECLARE @AttId BIGINT, @Emp INT, @D DATE, @Type VARCHAR(20), @Current VARCHAR(10), @IsManual BIT,
            @In DATETIME2, @Out DATETIME2, @Exit INT, @Approved INT, @Branch INT, @HrNote NVARCHAR(300), @rc INT,
            @OuterTran INT = @@TRANCOUNT;
    SELECT @AttId = an.AttendanceId, @Emp = an.EmployeeId, @D = an.WorkDate, @Type = an.[Type], @Current = an.Decision,
           @IsManual = a.IsManual, @In = a.FirstInUtc, @Out = a.LastOutUtc, @Exit = a.ExitActualMinutes,
           @Approved = a.ExitApprovedMinutes, @Branch = a.BranchId, @HrNote = a.HrNote
    FROM attendance.ATTENDANCE_ANOMALY an
    JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = an.AttendanceId
    WHERE an.AnomalyId = @AnomalyId;
    /* script 83 (D10): a day that is already PAID for this employee is changed by a payroll adjustment, not here */
    DECLARE @PaidRc INT;
    EXEC @PaidRc = payroll.usp_AssertPeriodOpen @Emp, @D;
    IF @PaidRc <> 0 RETURN 1;
    IF @AttId IS NULL BEGIN RAISERROR('Anomaly not found.', 16, 1); RETURN 1; END
    IF @Current = 'Corrected'
    BEGIN RAISERROR('This anomaly was already corrected; the day is manual. Adjust the day itself if it must change again.', 16, 1); RETURN 1; END
    IF @Type = 'MissingPunch' AND @Decision <> 'Correct'
    BEGIN RAISERROR('A missing punch has no minutes to excuse or deduct: enter the missing time (Correct).', 16, 1); RETURN 1; END

    IF @Decision IN ('Excuse', 'Deduct')
    BEGIN
        BEGIN TRAN;
        SAVE TRAN qa3_anomaly_decide;
        UPDATE attendance.ATTENDANCE_ANOMALY
        SET Decision = CASE @Decision WHEN 'Excuse' THEN 'Excused' ELSE 'Deducted' END,
            DecidedByUserId = @DecidedByUserId, DecidedAt = SYSUTCDATETIME(),
            Note = COALESCE(@Note, Note), UpdatedAt = SYSUTCDATETIME()
        WHERE AnomalyId = @AnomalyId;

        IF @IsManual = 1
        BEGIN
            EXEC @rc = attendance.usp_Attendance_RecomputeManualDay @AttendanceId = @AttId;
            IF ISNULL(@rc, 0) <> 0 BEGIN IF @OuterTran > 0 AND XACT_STATE() = 1 BEGIN ROLLBACK TRAN qa3_anomaly_decide; COMMIT TRAN; END ELSE IF @@TRANCOUNT > 0 ROLLBACK TRAN; RETURN 1; END
        END
        ELSE EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @D;
        COMMIT TRAN;
    END
    ELSE
    BEGIN
        IF @CorrectedTimeUtc IS NULL
        BEGIN RAISERROR('Correct needs the corrected time.', 16, 1); RETURN 1; END
        IF CAST(@CorrectedTimeUtc AS DATE) NOT BETWEEN @D AND DATEADD(DAY, 1, @D)
        BEGIN RAISERROR('The corrected time must fall on the work date (or the next day for an overnight shift).', 16, 1); RETURN 1; END

        DECLARE @NewIn DATETIME2 = @In, @NewOut DATETIME2 = @Out;
        IF @Type = 'LateArrival' SET @NewIn = @CorrectedTimeUtc;
        ELSE IF @Type = 'EarlyDeparture' SET @NewOut = @CorrectedTimeUtc;
        ELSE IF @In IS NULL SET @NewIn = @CorrectedTimeUtc;       -- MissingPunch: fill the missing side
        ELSE SET @NewOut = @CorrectedTimeUtc;
        IF @NewIn IS NOT NULL AND @NewOut IS NOT NULL AND @NewOut <= @NewIn
        BEGIN RAISERROR('The corrected time leaves the out time at or before the in time.', 16, 1); RETURN 1; END

        DECLARE @m TABLE (AttendanceId BIGINT, WorkedMinutes INT, StandardMinutes INT, DayFraction DECIMAL(5,2), IsFullDay BIT,
                          LateMinutes INT, OvertimeMinutes INT, ExitActualMinutes INT, ExitApprovedMinutes INT,
                          ExitVarianceMinutes INT, ExitLeaveMinutes INT, [Status] VARCHAR(20),
                          CoveredMinutes INT, EarlyExitMinutes INT, LateDeductMinutes INT, EarlyDeductMinutes INT, HasAnomaly BIT, IsManual BIT, ShortfallMinutes INT);
        BEGIN TRAN;
        SAVE TRAN qa3_anomaly_decide;
        /* the decision first, so the manual entry's anomaly sync keeps the row as 'Corrected' */
        UPDATE attendance.ATTENDANCE_ANOMALY
        SET Decision = 'Corrected', DecidedByUserId = @DecidedByUserId, DecidedAt = SYSUTCDATETIME(),
            Note = COALESCE(@Note, CONCAT(N'Punch corrected to ', CONVERT(VARCHAR(16), @CorrectedTimeUtc, 120), N'.')), UpdatedAt = SYSUTCDATETIME()
        WHERE AnomalyId = @AnomalyId;

        DECLARE @ManualNote NVARCHAR(300) = LEFT(COALESCE(@Note, @HrNote, CONCAT(N'Corrected from anomaly #', @AnomalyId, N'.')), 300);
        INSERT INTO @m EXEC attendance.usp_Attendance_ManualUpsert
            @EmployeeId = @Emp, @WorkDate = @D, @FirstInUtc = @NewIn, @LastOutUtc = @NewOut,
            @ExitMinutes = @Exit, @ExitApprovedMins = @Approved, @Status = NULL, @BranchId = @Branch, @HrNote = @ManualNote;
        /* QA3 (ATT-10): "a corrected punch that fails validation changes nothing" */
        IF NOT EXISTS (SELECT 1 FROM @m)
        BEGIN
            IF @OuterTran > 0 AND XACT_STATE() = 1 BEGIN ROLLBACK TRAN qa3_anomaly_decide; COMMIT TRAN; END ELSE IF @@TRANCOUNT > 0 ROLLBACK TRAN;
            RETURN 1;
        END
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

/* Script 83's body; QA3: manual days are re-run quietly (CON-4: decide-all used to toast "0 decided" because the
   manual writer's row came first), a refusal there rolls the whole decide-all back, and days outside the employee's
   employment are left out (they are not working days). */
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
    IF @from IS NULL BEGIN RAISERROR('The month must look like 2026-08.', 16, 1); RETURN 1; END
    DECLARE @to DATE = EOMONTH(@from);
    IF @Decision NOT IN ('Excuse', 'Deduct')
    BEGIN RAISERROR('Decide-all takes Excuse or Deduct; a correction needs a time for each anomaly.', 16, 1); RETURN 1; END

    DECLARE @rows TABLE (AnomalyId BIGINT PRIMARY KEY, AttendanceId BIGINT, EmployeeId INT, WorkDate DATE, IsManual BIT);
    INSERT INTO @rows (AnomalyId, AttendanceId, EmployeeId, WorkDate, IsManual)
    SELECT an.AnomalyId, an.AttendanceId, an.EmployeeId, an.WorkDate, a.IsManual
    FROM attendance.ATTENDANCE_ANOMALY an
    JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = an.AttendanceId
    JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
    WHERE an.WorkDate BETWEEN @from AND @to AND an.Decision IS NULL
      AND an.[Type] IN ('LateArrival', 'EarlyDeparture', 'HalfDayAbsence')
      AND payroll.fn_IsPeriodPaid(a.EmployeeId, a.WorkDate) = 0          -- script 83 (D10): days already paid are left as they were paid
      AND NOT (a.WorkDate < e.HireDate OR a.WorkDate > ISNULL(e.TerminationDate, '99991231'))   -- QA3 (ROS-1)
      AND (@BranchId IS NULL OR ISNULL(a.BranchId, e.BranchId) = @BranchId);

    DECLARE @Skipped INT = (SELECT COUNT(*) FROM attendance.ATTENDANCE_ANOMALY an
                            JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = an.AttendanceId
                            JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
                            WHERE an.WorkDate BETWEEN @from AND @to AND an.Decision IS NULL AND an.[Type] = 'MissingPunch'
                              AND (@BranchId IS NULL OR ISNULL(a.BranchId, e.BranchId) = @BranchId));

    DECLARE @OuterTran INT = @@TRANCOUNT;
    BEGIN TRAN;
    SAVE TRAN qa3_decide_all;

    UPDATE an
    SET an.Decision = CASE @Decision WHEN 'Excuse' THEN 'Excused' ELSE 'Deducted' END,
        an.DecidedByUserId = @DecidedByUserId, an.DecidedAt = SYSUTCDATETIME(),
        an.Note = COALESCE(@Note, an.Note), an.UpdatedAt = SYSUTCDATETIME()
    FROM attendance.ATTENDANCE_ANOMALY an
    JOIN @rows r ON r.AnomalyId = an.AnomalyId;
    DECLARE @Decided INT = @@ROWCOUNT;

    DECLARE @Att BIGINT, @Emp INT, @D DATE, @Manual BIT, @Days INT = 0, @rc INT;
    DECLARE day_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT AttendanceId, EmployeeId, WorkDate, IsManual FROM @rows ORDER BY WorkDate, EmployeeId;
    OPEN day_cur; FETCH NEXT FROM day_cur INTO @Att, @Emp, @D, @Manual;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @Manual = 1
        BEGIN
            EXEC @rc = attendance.usp_Attendance_RecomputeManualDay @AttendanceId = @Att;
            IF ISNULL(@rc, 0) <> 0
            BEGIN
                CLOSE day_cur; DEALLOCATE day_cur;
                IF @OuterTran > 0 AND XACT_STATE() = 1 BEGIN ROLLBACK TRAN qa3_decide_all; COMMIT TRAN; END ELSE IF @@TRANCOUNT > 0 ROLLBACK TRAN;
                RETURN 1;
            END
        END
        ELSE EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @D;
        SET @Days += 1;
        FETCH NEXT FROM day_cur INTO @Att, @Emp, @D, @Manual;
    END
    CLOSE day_cur; DEALLOCATE day_cur;

    COMMIT TRAN;

    SELECT @Decided AS Decided, @Skipped AS Skipped, @Days AS DaysRecomputed;
END;
GO

/* ---------------------------------------------------------------- 8. requests that touch attendance */
/* Script 76's body; QA3 (CON-3): @Quiet = 1 sends no result set, for a caller that answers with its own row. */
CREATE OR ALTER PROCEDURE workflow.usp_ExitPermission_ApplyToAttendance
    @ExitPermissionId INT  = NULL,             -- one permission (re-applied even if already stamped)
    @WorkDate         DATE = NULL,             -- or every approved, not-yet-applied permission (of that date)
    @Quiet            BIT  = 0
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

    IF ISNULL(@Quiet, 0) = 0 SELECT @Applied AS PermissionsApplied;
END;
GO

/* Script 83's body; QA3: (REL-4) a date outside the employment is refused - there is no working day to leave early
   from; the overlap check counts a request On hold too (it is still open); (CON-3) when the chain approves at
   submission the day is applied QUIETLY, so the client gets this procedure's row (it used to get "0 applied" first
   and opened request 0). */
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

    /* QA3 (REL-4): inside the employment only */
    DECLARE @Hire DATE, @Term DATE, @EmpName NVARCHAR(150), @Msg NVARCHAR(400);
    SELECT @Hire = HireDate, @Term = TerminationDate, @EmpName = FullName FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId;
    IF @ExitDate > @Term OR @ExitDate < @Hire
    BEGIN
        SET @Msg = CONCAT(@EmpName, CASE WHEN @ExitDate > @Term THEN CONCAT(N' leaves on ', CONVERT(CHAR(10), @Term, 23))
                                         ELSE CONCAT(N' starts on ', CONVERT(CHAR(10), @Hire, 23)) END,
                          N': there is no working day on ', CONVERT(CHAR(10), @ExitDate, 23), N' to ask an exit permission for.');
        RAISERROR('%s', 16, 1, @Msg);
        RETURN;
    END

    DECLARE @Minutes INT = DATEDIFF(MINUTE, @FromTime, @ToTime);

    /* script 83: SEVERAL permissions may be held for one day, as long as their windows do not overlap.
       QA3: a request on hold is still open, so it counts. */
    IF EXISTS (
        SELECT 1 FROM workflow.EXIT_PERMISSION ep
        JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
        WHERE ep.EmployeeId = @EmployeeId AND ep.ExitDate = @ExitDate
          AND r.[Status] IN ('Pending', 'OnHold', 'Approved')
          AND ep.FromTime < @ToTime AND ep.ToTime > @FromTime)
    BEGIN
        RAISERROR('This employee already has a pending, on-hold or approved exit permission that overlaps those times.', 16, 1);
        RETURN;
    END

    /* The standard title - the ONE definition of the format. The optional override wins only when it is a non-blank string. */
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
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
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
        EXEC workflow.usp_ExitPermission_ApplyToAttendance @ExitPermissionId = @NewId, @Quiet = 1;

    SELECT ep.ExitPermissionId, ep.RequestInstanceId, ep.EmployeeId, ep.ExitDate,
           ep.FromTime, ep.ToTime, ep.RequestedMinutes, ep.ApprovedMinutes,
           ep.ConvertToLeave, r.[Status], r.CurrentStepNo, r.Title
    FROM workflow.EXIT_PERMISSION ep
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
    WHERE ep.ExitPermissionId = @NewId;
END;
GO

/* Script 83's body; QA3: (REL-4) a date outside the employment is refused; (convention 4) the Submit row is checked -
   a refused submission rolls back instead of storing an overtime request that belongs to no request. */
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

    /* QA3 (REL-4): inside the employment only */
    DECLARE @Hire DATE, @Term DATE, @EmpName NVARCHAR(150), @Msg NVARCHAR(400);
    SELECT @Hire = HireDate, @Term = TerminationDate, @EmpName = FullName FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId;
    IF @WorkDate > @Term OR @WorkDate < @Hire
    BEGIN
        SET @Msg = CONCAT(@EmpName, CASE WHEN @WorkDate > @Term THEN CONCAT(N' leaves on ', CONVERT(CHAR(10), @Term, 23))
                                         ELSE CONCAT(N' starts on ', CONVERT(CHAR(10), @Hire, 23)) END,
                          N': there is no working day on ', CONVERT(CHAR(10), @WorkDate, 23), N' to ask overtime for.');
        RAISERROR('%s', 16, 1, @Msg);
        RETURN;
    END

    /* one open or approved OT per employee per date */
    IF EXISTS (SELECT 1 FROM workflow.OVERTIME_REQUEST o
               JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId=o.RequestInstanceId
               WHERE o.EmployeeId=@EmployeeId AND o.WorkDate=@WorkDate
                 AND r.[Status] IN ('Pending','OnHold','Approved'))
    BEGIN RAISERROR('An overtime request already exists for this employee on that date.',16,1); RETURN; END

    DECLARE @DateS CHAR(10)=CONVERT(char(10),@WorkDate,23);
    IF @Title IS NULL OR LTRIM(RTRIM(@Title))=''
        SET @Title=CONCAT(N'Overtime ',@DateS,N' - ',@EmpName,N' (',@RequestedMinutes,N' min)');

    BEGIN TRAN;
    DECLARE @Submitted TABLE (RequestInstanceId INT,[Status] VARCHAR(20),CurrentStepNo INT,
                              WorkflowDefinitionId INT,WorkflowVersion INT,MinRequesterTier INT);
    INSERT INTO @Submitted
    EXEC workflow.usp_Request_Submit @RequestTypeCode='OVERTIME',
         @EmployeeId=@EmployeeId,@RaisedByUserId=@RaisedByUserId,@Title=@Title;

    DECLARE @ReqId INT=(SELECT TOP 1 RequestInstanceId FROM @Submitted);
    IF @ReqId IS NULL
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        RAISERROR('The request could not be submitted - check that an OVERTIME workflow is published.', 16, 1);
        RETURN;
    END
    INSERT INTO workflow.OVERTIME_REQUEST
        (RequestInstanceId,EmployeeId,WorkDate,RequestedMinutes,Reason)
    VALUES (@ReqId,@EmployeeId,@WorkDate,@RequestedMinutes,@Reason);

    /* FIX 06b (unchanged): the payload row exists only now, so the effects of an approval at submission are applied
       HERE (idempotent and type-guarded) */
    IF EXISTS (SELECT 1 FROM @Submitted WHERE [Status] = 'Approved')
        EXEC workflow.usp_Request_ApplyApprovalEffects
             @RequestInstanceId = @ReqId, @ActorUserId = @RaisedByUserId;

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

/* ---------------------------------------------------------------- 9. the processor and the nightly markers */
/* Script 83's body; QA3 (ATT-6): (a) the raw rows are SNAPSHOT by id first and exactly those are marked processed at
   the end - the old final UPDATE also marked a punch that arrived while the run was going (after its day had been
   derived without it), so that punch was never processed; (b) ONE processor at a time (application lock): a second
   run waits up to 15 seconds and then skips cleanly with 0 days - everything it left is still unprocessed for the next
   run (the nightly job, the next push or pull). The result set and the OUTPUT parameters are unchanged. */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_ProcessRawLogs
    @WorkDate DATE = NULL,                     -- NULL = every unprocessed punch
    @Quiet    BIT  = 0,                        -- 1 = no result set (internal callers)
    @DaysOut  INT  = NULL OUTPUT,
    @LateDaysOut INT = NULL OUTPUT             -- script 83 (D6): of those, the days that ALREADY had a record
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @DaysOut = 0; SET @LateDaysOut = 0;

    DECLARE @lock INT;
    EXEC @lock = sp_getapplock @Resource = N'attendance.usp_Attendance_ProcessRawLogs', @LockMode = 'Exclusive',
                               @LockOwner = 'Session', @LockTimeout = 15000;
    IF @lock < 0
    BEGIN
        /* another run holds it: what is unprocessed now is processed by it or by the next run */
        IF @Quiet = 0 SELECT 0 AS EmployeeDaysProcessed;
        RETURN 0;
    END

    BEGIN TRY
        /* the raw rows this run consumes, by id - a punch inserted after this moment is the next run's */
        DECLARE @raw TABLE (RawLogId BIGINT PRIMARY KEY, EmployeeId INT, WorkDate DATE);
        INSERT INTO @raw (RawLogId, EmployeeId, WorkDate)
        SELECT r.RawLogId, r.EmployeeId, x.WorkDate
        FROM attendance.RAW_DEVICE_LOG r
        CROSS APPLY (SELECT attendance.fn_AttributedWorkDate(r.EmployeeId, r.PunchTimeUtc) AS WorkDate) x
        WHERE r.IsProcessed = 0 AND r.EmployeeId IS NOT NULL
          AND (@WorkDate IS NULL OR x.WorkDate = @WorkDate);

        /* the employee-days that have anything NEW, by ATTRIBUTED date; each is re-derived from ALL its punches */
        DECLARE @day TABLE (EmployeeId INT, WorkDate DATE, HadRecord BIT, PRIMARY KEY (EmployeeId, WorkDate));
        INSERT INTO @day (EmployeeId, WorkDate, HadRecord)
        SELECT x.EmployeeId, x.WorkDate,
               CASE WHEN EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = x.EmployeeId AND a.WorkDate = x.WorkDate) THEN 1 ELSE 0 END
        FROM (SELECT DISTINCT EmployeeId, WorkDate FROM @raw) x;

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

        /* mark exactly the raw rows this run read (debounced ones included - they were part of the day just derived) */
        UPDATE r SET r.IsProcessed = 1
        FROM attendance.RAW_DEVICE_LOG r
        JOIN @raw x ON x.RawLogId = r.RawLogId
        WHERE r.IsProcessed = 0;

        SET @DaysOut = @n;
        SET @LateDaysOut = (SELECT COUNT(*) FROM @day WHERE HadRecord = 1);
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRAN;
        EXEC sp_releaseapplock @Resource = N'attendance.usp_Attendance_ProcessRawLogs', @LockOwner = 'Session';
        THROW;
    END CATCH;

    EXEC sp_releaseapplock @Resource = N'attendance.usp_Attendance_ProcessRawLogs', @LockOwner = 'Session';
    IF @Quiet = 0 SELECT @DaysOut AS EmployeeDaysProcessed;
END;
GO

/* Script 76's body; QA3 (ROS-1, ATT-2): a day outside the employee's employment is nobody's working day - it is
   not marked absent (ComputeDay would refuse it too). */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_MarkAbsentees
    @WorkDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @WorkDate IS NULL BEGIN RAISERROR('WorkDate is required.', 16, 1); RETURN; END

    /* rostered employee-days with no record; the rule decides Absent / RestDay (DayFraction NULL) /
       Leave, and writes nothing when the roster month is not approved (no shift rostered -> no absence) */
    DECLARE @emps TABLE (EmployeeId INT PRIMARY KEY);
    INSERT INTO @emps (EmployeeId)
    SELECT sa.EmployeeId
    FROM attendance.SHIFT_ASSIGNMENT sa
    JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId AND e.IsDeleted = 0
    WHERE sa.WorkDate = @WorkDate
      AND e.HireDate <= @WorkDate
      AND (e.TerminationDate IS NULL OR e.TerminationDate >= @WorkDate)
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

/* Script 76's body; QA3 (ATT-8, LEV-2, REL-6): the days of an approved leave are FromDate..ApprovedToDate (a partial
   approval keeps the first days); and a non-manual day still marked 'Leave' that no approved full-day leave covers
   any more (a partial approval, an approval taken back) is re-derived from its punches. */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_MarkLeaveDays
    @PeriodYearMonth CHAR(7)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @from DATE = TRY_CAST(@PeriodYearMonth + '-01' AS DATE);
    IF @from IS NULL BEGIN RAISERROR('PeriodYearMonth must be yyyy-MM.', 16, 1); RETURN; END
    DECLARE @to DATE = EOMONTH(@from);

    DECLARE @days TABLE (EmployeeId INT, WorkDate DATE, PRIMARY KEY (EmployeeId, WorkDate));
    ;WITH n AS (SELECT TOP (DATEDIFF(DAY, @from, @to) + 1) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i FROM sys.all_objects),
    d AS (SELECT DATEADD(DAY, i, @from) AS WorkDate FROM n)
    INSERT INTO @days (EmployeeId, WorkDate)
    SELECT DISTINCT lr.EmployeeId, d.WorkDate
    FROM workflow.LEAVE_REQUEST lr
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId AND ri.[Status] = 'Approved'
    JOIN d ON d.WorkDate BETWEEN lr.FromDate AND ISNULL(lr.ApprovedToDate, lr.ToDate)
    JOIN attendance.ATTENDANCE_RECORD a ON a.EmployeeId = lr.EmployeeId AND a.WorkDate = d.WorkDate
    WHERE a.IsManual = 0 AND a.[Status] <> 'Leave';

    /* the other way round: 'Leave' on a day no approved full-day leave covers */
    INSERT INTO @days (EmployeeId, WorkDate)
    SELECT a.EmployeeId, a.WorkDate
    FROM attendance.ATTENDANCE_RECORD a
    WHERE a.WorkDate BETWEEN @from AND @to AND a.IsManual = 0 AND a.[Status] = 'Leave'
      AND NOT EXISTS (SELECT 1 FROM workflow.LEAVE_REQUEST lr
                      JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId AND ri.[Status] = 'Approved'
                      WHERE lr.EmployeeId = a.EmployeeId AND lr.HalfDay IS NULL
                        AND a.WorkDate BETWEEN lr.FromDate AND ISNULL(lr.ApprovedToDate, lr.ToDate))
      AND NOT EXISTS (SELECT 1 FROM @days x WHERE x.EmployeeId = a.EmployeeId AND x.WorkDate = a.WorkDate);

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

/* ---------------------------------------------------------------- 10. shifts are versioned */
/* Script 77's bodies; QA3 (ATT-7, ROS-9, REL-10): every day rostered to a shift is judged against the shift's times
   AS THEY ARE NOW (ComputeDay reads SHIFT live), so editing the times of a shift that has been worked re-judged every
   past day the next time anything re-derived it (a late punch, a holiday, a leave), with the decisions taken against
   the old times. The times, break, grace and overnight flag of a shift used by a past day or by recorded attendance
   are therefore fixed: a new shift is created and rostered from the date it starts. The name and Active may change. */
CREATE OR ALTER PROCEDURE attendance.usp_Shift_Create
    @Name NVARCHAR(50), @StartTime TIME, @EndTime TIME,
    @GraceMinutes INT = NULL, @CrossesMidnight BIT = 0, @BreakMinutes INT = 0
AS BEGIN SET NOCOUNT ON;
    IF @StartTime = @EndTime
    BEGIN RAISERROR('A shift cannot start and end at the same time.', 16, 1); RETURN 1; END
    IF @EndTime < @StartTime AND ISNULL(@CrossesMidnight, 0) = 0
    BEGIN RAISERROR('This shift ends before it starts. Tick ''crosses midnight'' if it is an overnight shift.', 16, 1); RETURN 1; END
    IF @GraceMinutes IS NOT NULL AND @GraceMinutes < 0
    BEGIN RAISERROR('GraceMinutes must be zero or more, or empty to use the AttendanceToleranceMinutes setting.', 16, 1); RETURN 1; END
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes)
    VALUES (@Name, @StartTime, @EndTime, @GraceMinutes, ISNULL(@CrossesMidnight, 0), ISNULL(@BreakMinutes, 0));
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS ShiftId; END;
GO

CREATE OR ALTER PROCEDURE attendance.usp_Shift_Update
    @ShiftId INT, @Name NVARCHAR(50), @StartTime TIME, @EndTime TIME,
    @GraceMinutes INT = NULL, @CrossesMidnight BIT, @BreakMinutes INT, @IsActive BIT
AS BEGIN SET NOCOUNT ON;
    IF @StartTime = @EndTime
    BEGIN RAISERROR('A shift cannot start and end at the same time.', 16, 1); RETURN 1; END
    IF @EndTime < @StartTime AND ISNULL(@CrossesMidnight, 0) = 0
    BEGIN RAISERROR('This shift ends before it starts. Tick ''crosses midnight'' if it is an overnight shift.', 16, 1); RETURN 1; END
    IF @GraceMinutes IS NOT NULL AND @GraceMinutes < 0
    BEGIN RAISERROR('GraceMinutes must be zero or more, or empty to use the AttendanceToleranceMinutes setting.', 16, 1); RETURN 1; END

    DECLARE @OldStart TIME, @OldEnd TIME, @OldGrace INT, @OldCross BIT, @OldBreak INT, @OldName NVARCHAR(50);
    SELECT @OldStart = StartTime, @OldEnd = EndTime, @OldGrace = GraceMinutes, @OldCross = CrossesMidnight,
           @OldBreak = BreakMinutes, @OldName = Name
    FROM attendance.SHIFT WHERE ShiftId = @ShiftId;
    IF @OldName IS NULL BEGIN RAISERROR('Shift not found.', 16, 1); RETURN 1; END

    IF @OldStart <> @StartTime OR @OldEnd <> @EndTime OR ISNULL(@OldBreak, 0) <> ISNULL(@BreakMinutes, 0)
       OR ISNULL(@OldCross, 0) <> ISNULL(@CrossesMidnight, 0) OR ISNULL(@OldGrace, -1) <> ISNULL(@GraceMinutes, -1)
    BEGIN
        DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
        DECLARE @Used INT, @LastUsed DATE;
        SELECT @Used = COUNT(*), @LastUsed = MAX(sa.WorkDate)
        FROM attendance.SHIFT_ASSIGNMENT sa
        WHERE sa.ShiftId = @ShiftId
          AND (sa.WorkDate < @Today
               OR EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = sa.EmployeeId AND a.WorkDate = sa.WorkDate));
        IF @Used > 0
        BEGIN
            DECLARE @Msg NVARCHAR(600) = CONCAT(N'The shift ', @OldName, N' (', LEFT(CONVERT(VARCHAR(8), @OldStart, 108), 5), N'-',
                LEFT(CONVERT(VARCHAR(8), @OldEnd, 108), 5), N') is already in use: ', @Used, N' day(s) up to ', CONVERT(CHAR(10), @LastUsed, 23),
                N' were judged against it. Its times, break, grace and overnight setting stay as they are, or those days would be judged',
                N' again against the new ones. Create a new shift with the new times and roster it from the date it starts',
                N' (the name and Active can still be changed here).');
            RAISERROR('%s', 16, 1, @Msg);
            RETURN 1;
        END
    END

    UPDATE attendance.SHIFT
    SET Name = @Name, StartTime = @StartTime, EndTime = @EndTime,
        GraceMinutes = @GraceMinutes, CrossesMidnight = @CrossesMidnight,
        BreakMinutes = @BreakMinutes, IsActive = @IsActive
    WHERE ShiftId = @ShiftId;
    RETURN 0;
END;
GO

/* ---------------------------------------------------------------- 11. holidays */
/* Script 82's body; QA3 (ATT-14, ROS-5): only the days up to TODAY in Beirut are re-derived. A holiday recorded ahead
   used to write a record on its future date for everyone rostered (a holiday moved away left them 'Absent' on a day
   nobody had worked yet, and the roster locks such days). Future days are derived when they happen. */
CREATE OR ALTER PROCEDURE core.usp_Holiday_RecomputeDays
    @Date1 DATE, @Branch1 INT, @Date2 DATE = NULL, @Branch2 INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @day TABLE (EmployeeId INT, WorkDate DATE, PRIMARY KEY (EmployeeId, WorkDate));
    INSERT INTO @day
    SELECT DISTINCT x.EmployeeId, x.WorkDate
    FROM (SELECT EmployeeId, WorkDate FROM attendance.ATTENDANCE_RECORD WHERE WorkDate IN (@Date1, @Date2)
          UNION
          SELECT EmployeeId, WorkDate FROM attendance.SHIFT_ASSIGNMENT  WHERE WorkDate IN (@Date1, @Date2)) x
    WHERE x.WorkDate <= @Today
      AND (   (x.WorkDate = @Date1 AND (@Branch1 IS NULL OR hr.fn_EmployeeBranchOn(x.EmployeeId, x.WorkDate) = @Branch1))
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

/* QA3 (REL-12, LEV-4): a holiday changes what a leave over it costs (a holiday costs no leave day). After a holiday is
   added, moved or removed, every employee whose approved leave request spans the date (in the branch the holiday
   applies to) is re-priced by unit D's hr.usp_LeaveLedger_Reprice, which skips periods already paid. No result set. */
CREATE OR ALTER PROCEDURE core.usp_Holiday_RepriceLeave
    @Date1 DATE, @Branch1 INT, @Date2 DATE = NULL, @Branch2 INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @emp TABLE (EmployeeId INT, WorkDate DATE, PRIMARY KEY (EmployeeId, WorkDate));
    INSERT INTO @emp
    SELECT DISTINCT lr.EmployeeId, h.D
    FROM (VALUES (@Date1, @Branch1), (@Date2, @Branch2)) h(D, B)
    JOIN workflow.LEAVE_REQUEST lr ON h.D BETWEEN lr.FromDate AND lr.ToDate
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId AND ri.[Status] = 'Approved'
    WHERE h.D IS NOT NULL
      AND (h.B IS NULL OR hr.fn_EmployeeBranchOn(lr.EmployeeId, h.D) = h.B);
    DECLARE @e INT, @d DATE, @rc INT;
    DECLARE rc CURSOR LOCAL FAST_FORWARD FOR SELECT EmployeeId, WorkDate FROM @emp ORDER BY EmployeeId, WorkDate;
    OPEN rc; FETCH NEXT FROM rc INTO @e, @d;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC @rc = hr.usp_LeaveLedger_Reprice @EmployeeId = @e, @FromDate = @d, @ToDate = @d;
        IF ISNULL(@rc, 0) <> 0
        BEGIN
            CLOSE rc; DEALLOCATE rc;
            RAISERROR('The leave over this holiday could not be priced again; nothing was saved.', 16, 1);
            RETURN 1;
        END
        FETCH NEXT FROM rc INTO @e, @d;
    END
    CLOSE rc; DEALLOCATE rc;
    RETURN 0;
END;
GO

/* Script 82's bodies; QA3: the holiday row, the re-derivation of its days (up to today) and the re-pricing of the leave
   over it are ONE transaction - a failure leaves nothing half done. */
CREATE OR ALTER PROCEDURE core.usp_Holiday_Upsert
    @HolidayId INT = NULL, @HolidayDate DATE, @Name NVARCHAR(100), @NameAr NVARCHAR(100) = NULL,
    @IsPaid BIT = 1, @BranchId INT = NULL, @ActedByUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @Name = LTRIM(RTRIM(ISNULL(@Name, N'')));
    IF @HolidayDate IS NULL OR @Name = N''
    BEGIN RAISERROR('A holiday needs a date and a name.', 16, 1); RETURN 1; END
    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM hr.BRANCH WHERE BranchId = @BranchId)
    BEGIN RAISERROR('That branch does not exist.', 16, 1); RETURN 1; END

    DECLARE @OldDate DATE, @OldBranch INT, @rc INT;
    IF @HolidayId IS NOT NULL
    BEGIN
        SELECT @OldDate = HolidayDate, @OldBranch = BranchId FROM core.HOLIDAY WHERE HolidayId = @HolidayId;
        IF @OldDate IS NULL BEGIN RAISERROR('That holiday does not exist.', 16, 1); RETURN 1; END
    END
    IF EXISTS (SELECT 1 FROM core.HOLIDAY h WHERE h.HolidayDate = @HolidayDate
                 AND ISNULL(h.BranchId, -1) = ISNULL(@BranchId, -1) AND h.HolidayId <> ISNULL(@HolidayId, -1))
    BEGIN RAISERROR('A holiday is already recorded on that date for that branch.', 16, 1); RETURN 1; END
    /* D10: a holiday re-prices the day; where that day is already PAID for somebody it touches, that is an adjustment, not an edit */
    IF core.fn_HolidayTouchesPaidDay(@HolidayDate, @BranchId) = 1
       OR (@OldDate IS NOT NULL AND core.fn_HolidayTouchesPaidDay(@OldDate, @OldBranch) = 1)
    BEGIN DECLARE @Dash NCHAR(1) = NCHAR(8212); RAISERROR(N'This period is paid %s raise a payroll adjustment instead.', 16, 1, @Dash); RETURN 1; END

    DECLARE @OuterTran INT = @@TRANCOUNT;
    BEGIN TRAN;
    SAVE TRAN qa3_holiday;
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

    EXEC core.usp_Holiday_RecomputeDays @Date1 = @HolidayDate, @Branch1 = @BranchId, @Date2 = @OldDate, @Branch2 = @OldBranch;
    EXEC @rc = core.usp_Holiday_RepriceLeave @Date1 = @HolidayDate, @Branch1 = @BranchId, @Date2 = @OldDate, @Branch2 = @OldBranch;
    IF ISNULL(@rc, 0) <> 0 BEGIN IF @OuterTran > 0 AND XACT_STATE() = 1 BEGIN ROLLBACK TRAN qa3_holiday; COMMIT TRAN; END ELSE IF @@TRANCOUNT > 0 ROLLBACK TRAN; RETURN 1; END
    COMMIT TRAN;

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
    DECLARE @Date DATE, @Branch INT, @rc INT;
    SELECT @Date = HolidayDate, @Branch = BranchId FROM core.HOLIDAY WHERE HolidayId = @HolidayId;
    IF @Date IS NULL BEGIN RAISERROR('That holiday does not exist.', 16, 1); RETURN 1; END
    IF core.fn_HolidayTouchesPaidDay(@Date, @Branch) = 1
    BEGIN DECLARE @Dash NCHAR(1) = NCHAR(8212); RAISERROR(N'This period is paid %s raise a payroll adjustment instead.', 16, 1, @Dash); RETURN 1; END
    DECLARE @OuterTran INT = @@TRANCOUNT;
    BEGIN TRAN;
    SAVE TRAN qa3_holiday;
    DELETE FROM core.HOLIDAY WHERE HolidayId = @HolidayId;
    EXEC core.usp_Holiday_RecomputeDays @Date1 = @Date, @Branch1 = @Branch;
    EXEC @rc = core.usp_Holiday_RepriceLeave @Date1 = @Date, @Branch1 = @Branch;
    IF ISNULL(@rc, 0) <> 0 BEGIN IF @OuterTran > 0 AND XACT_STATE() = 1 BEGIN ROLLBACK TRAN qa3_holiday; COMMIT TRAN; END ELSE IF @@TRANCOUNT > 0 ROLLBACK TRAN; RETURN 1; END
    COMMIT TRAN;
    SELECT @HolidayId AS HolidayId, CAST(1 AS BIT) AS Deleted;
END;
GO

/* ---------------------------------------------------------------- 12. devices and the punch quarantine */
/* STALE-COPY GUARD (CON-7): the latest repo definition of usp_EmployeeDevice_Map is in the unnumbered
   attendance_full_v3.sql. Checked against the C# (DeviceRepository.MapAsync passes EmployeeId, DeviceId, EnrollPin and
   reads OrphanPunchesResolved). A live version with another parameter or another result column is newer than that copy:
   the script stops here instead of overwriting it. */
IF OBJECT_ID('attendance.usp_EmployeeDevice_Map', 'P') IS NOT NULL
   AND (EXISTS (SELECT 1 FROM sys.parameters p WHERE p.object_id = OBJECT_ID('attendance.usp_EmployeeDevice_Map')
                AND p.name NOT IN ('@EmployeeId', '@DeviceId', '@EnrollPin'))
        OR EXISTS (SELECT 1 FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID('attendance.usp_EmployeeDevice_Map'), 0) f
                   WHERE f.error_number IS NULL AND f.name IS NOT NULL AND f.name NOT IN ('OrphanPunchesResolved')))
BEGIN
    RAISERROR('100_qa3_attendance.sql: the live attendance.usp_EmployeeDevice_Map differs from the repo copy this script rewrites (a parameter or result column it does not know) - merge by hand before applying.', 16, 1);
    SET NOEXEC ON;
END
GO
/* QA3 (ATT-12, REL-8): a PIN already enrolled for ANOTHER employee is refused with a sentence that names them (409 in
   the API). It used to skip the insert silently and answer as if the PIN had been mapped - the punches kept landing on
   the first employee. Mapping the PIN takes back punches HR had set aside on it too (they were somebody's after all). */
CREATE OR ALTER PROCEDURE attendance.usp_EmployeeDevice_Map
    @EmployeeId INT, @DeviceId INT, @EnrollPin VARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Resolved INT = 0, @Msg NVARCHAR(400);

    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId AND IsDeleted = 0)
    BEGIN RAISERROR('Employee not found.', 16, 1); RETURN 1; END
    DECLARE @Serial VARCHAR(60) = (SELECT SerialNumber FROM attendance.DEVICE WHERE DeviceId = @DeviceId);
    IF @Serial IS NULL BEGIN RAISERROR('Device not found.', 16, 1); RETURN 1; END
    IF @EnrollPin IS NULL OR LTRIM(RTRIM(@EnrollPin)) = ''
    BEGIN RAISERROR('The PIN is required.', 16, 1); RETURN 1; END

    DECLARE @Owner INT, @OwnerName NVARCHAR(150);
    SELECT TOP 1 @Owner = ed.EmployeeId, @OwnerName = e.FullName
    FROM attendance.EMPLOYEE_DEVICE ed JOIN hr.EMPLOYEE e ON e.EmployeeId = ed.EmployeeId
    WHERE ed.DeviceId = @DeviceId AND ed.EnrollPin = @EnrollPin;
    IF @Owner IS NOT NULL AND @Owner <> @EmployeeId
    BEGIN
        SET @Msg = CONCAT(N'PIN ', @EnrollPin, N' on device ', @Serial, N' is already enrolled for ', @OwnerName,
                          N'. Remove that enrollment first (the punches already recorded stay theirs), then map the PIN to the right person.');
        RAISERROR('%s', 16, 1, @Msg);
        RETURN 1;
    END

    BEGIN TRAN;
    IF @Owner IS NULL
        INSERT INTO attendance.EMPLOYEE_DEVICE (EmployeeId, DeviceId, EnrollPin)
        VALUES (@EmployeeId, @DeviceId, @EnrollPin);

    UPDATE attendance.RAW_DEVICE_LOG
    SET EmployeeId = @EmployeeId, DismissedUtc = NULL, DismissedByUserId = NULL, DismissNote = NULL
    WHERE DeviceId = @DeviceId AND EnrollPin = @EnrollPin AND EmployeeId IS NULL;
    SET @Resolved = @@ROWCOUNT;          -- capture BEFORE commit
    COMMIT TRAN;

    SELECT @Resolved AS OrphanPunchesResolved;
END;
GO

/* Script 83's view; QA3: a punch HR has set aside (DismissedUtc) is no longer waiting */
CREATE OR ALTER VIEW attendance.DEVICE_PUNCH_QUARANTINE
AS
    SELECT r.RawLogId, r.DeviceId, d.SerialNumber, d.[Name] AS DeviceName, d.BranchId, b.Name AS BranchName,
           r.EnrollPin, r.PunchTimeUtc AS PunchTime, r.PunchType, r.[Source], r.CreatedUtc AS ReceivedUtc
    FROM attendance.RAW_DEVICE_LOG r
    LEFT JOIN attendance.DEVICE d ON d.DeviceId = r.DeviceId
    LEFT JOIN hr.BRANCH b ON b.BranchId = d.BranchId
    WHERE r.EmployeeId IS NULL AND r.DismissedUtc IS NULL;
GO

/* QA3: a PIN that belongs to NOBODY (a visitor tried the terminal, a test enrolment, a person who left years ago) kept
   its punches waiting for ever - and payroll readiness counts waiting punches. HR sets them aside with a reason; they
   stay stored (so the terminal's next copy of them is still a duplicate) and come back if the PIN is mapped later. */
CREATE OR ALTER PROCEDURE attendance.usp_DevicePunchQuarantine_Dismiss
    @DeviceId INT, @EnrollPin VARCHAR(30), @Note NVARCHAR(300), @ActedByUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Msg NVARCHAR(400);
    IF @Note IS NULL OR LTRIM(RTRIM(@Note)) = N''
    BEGIN RAISERROR('Say why these punches are set aside (whose PIN it is, or why it belongs to nobody).', 16, 1); RETURN 1; END
    IF NOT EXISTS (SELECT 1 FROM attendance.DEVICE WHERE DeviceId = @DeviceId)
    BEGIN RAISERROR('Device not found.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM attendance.EMPLOYEE_DEVICE WHERE DeviceId = @DeviceId AND EnrollPin = @EnrollPin)
    BEGIN
        SET @Msg = CONCAT(N'PIN ', @EnrollPin, N' is enrolled for an employee on this device: map its waiting punches instead of setting them aside.');
        RAISERROR('%s', 16, 1, @Msg); RETURN 1;
    END

    UPDATE attendance.RAW_DEVICE_LOG
    SET DismissedUtc = SYSUTCDATETIME(), DismissedByUserId = @ActedByUserId, DismissNote = LEFT(LTRIM(RTRIM(@Note)), 300)
    WHERE DeviceId = @DeviceId AND EnrollPin = @EnrollPin AND EmployeeId IS NULL AND DismissedUtc IS NULL;
    DECLARE @n INT = @@ROWCOUNT;
    IF @n = 0
    BEGIN
        SET @Msg = CONCAT(N'No punch is waiting on PIN ', @EnrollPin, N' of this device (already set aside or mapped).');
        RAISERROR('%s', 16, 1, @Msg); RETURN 1;
    END
    SELECT @n AS PunchesDismissed;
END;
GO

/* Script 83's body; QA3: the punches HR had set aside on the PIN are claimed with the rest */
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
    UPDATE attendance.RAW_DEVICE_LOG
    SET EmployeeId = @EmployeeId, IsProcessed = 0, DismissedUtc = NULL, DismissedByUserId = NULL, DismissNote = NULL
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

/* ---------------------------------------------------------------- 13. exit-permission reads (DB-3) */
/* QA3 (DB-3): the repo copies (workflow_exit_permission.sql) still select ep.Minutes, which no longer exists; the C# reads
   RequestedMinutes / ApprovedMinutes / MinutesReduced / WasReduced / LeaveDaysEquivalent (ExitPermissionDetail) and
   Minutes (PendingApplication). Production carries working versions that are not in the repo: the guards stop the script
   when the live procedure takes a parameter, or returns a column, that the version below does not. */
IF OBJECT_ID('workflow.usp_ExitPermission_GetByRequest', 'P') IS NOT NULL
   AND (EXISTS (SELECT 1 FROM sys.parameters p WHERE p.object_id = OBJECT_ID('workflow.usp_ExitPermission_GetByRequest')
                AND p.name NOT IN ('@RequestInstanceId'))
        OR EXISTS (SELECT 1 FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID('workflow.usp_ExitPermission_GetByRequest'), 0) f
                   WHERE f.error_number IS NULL AND f.name IS NOT NULL
                     AND f.name NOT IN ('ExitPermissionId', 'RequestInstanceId', 'EmployeeId', 'FullName', 'BranchName', 'ExitDate',
                                        'FromTime', 'ToTime', 'RequestedMinutes', 'ApprovedMinutes', 'MinutesReduced', 'WasReduced',
                                        'LeaveDaysEquivalent', 'RequestedLeaveDays', 'Minutes', 'Reason', 'ConvertToLeave',
                                        'AppliedToAttendanceAt', 'CreatedAt', 'AttendanceId', 'ExitActualMinutes', 'ExitApprovedMinutes',
                                        'ExitVarianceMinutes', 'ExitLeaveMinutes', 'ExitVarianceDisposition')))
BEGIN
    RAISERROR('100_qa3_attendance.sql: the live workflow.usp_ExitPermission_GetByRequest differs from this redefinition (a parameter or result column it does not know) - merge by hand before applying.', 16, 1);
    SET NOEXEC ON;
END
GO
CREATE OR ALTER PROCEDURE workflow.usp_ExitPermission_GetByRequest @RequestInstanceId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ep.ExitPermissionId, ep.RequestInstanceId, ep.EmployeeId, e.FullName,
           b.Name AS BranchName, ep.ExitDate, ep.FromTime, ep.ToTime,
           ep.RequestedMinutes,
           ISNULL(ep.ApprovedMinutes, ep.RequestedMinutes) AS ApprovedMinutes,
           ep.RequestedMinutes - ISNULL(ep.ApprovedMinutes, ep.RequestedMinutes) AS MinutesReduced,
           CAST(CASE WHEN ISNULL(ep.ApprovedMinutes, ep.RequestedMinutes) < ep.RequestedMinutes THEN 1 ELSE 0 END AS BIT) AS WasReduced,
           core.fn_MinutesToLeaveDays(ISNULL(ep.ApprovedMinutes, ep.RequestedMinutes)) AS LeaveDaysEquivalent,
           ep.Reason, ep.ConvertToLeave, ep.AppliedToAttendanceAt, ep.CreatedAt,
           /* what attendance ended up recording for that day, if it exists yet */
           a.AttendanceId, a.ExitActualMinutes, a.ExitApprovedMinutes,
           a.ExitVarianceMinutes, a.ExitLeaveMinutes, a.ExitVarianceDisposition
    FROM workflow.EXIT_PERMISSION ep
    JOIN hr.EMPLOYEE e ON e.EmployeeId = ep.EmployeeId
    LEFT JOIN hr.BRANCH b ON b.BranchId = hr.fn_EmployeeBranchOn(ep.EmployeeId, ep.ExitDate)
    LEFT JOIN attendance.ATTENDANCE_RECORD a
           ON a.EmployeeId = ep.EmployeeId AND a.WorkDate = ep.ExitDate
    WHERE ep.RequestInstanceId = @RequestInstanceId;
END;
GO
IF OBJECT_ID('workflow.usp_ExitPermission_GetPendingApplication', 'P') IS NOT NULL
   AND (EXISTS (SELECT 1 FROM sys.parameters p WHERE p.object_id = OBJECT_ID('workflow.usp_ExitPermission_GetPendingApplication'))
        OR EXISTS (SELECT 1 FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID('workflow.usp_ExitPermission_GetPendingApplication'), 0) f
                   WHERE f.error_number IS NULL AND f.name IS NOT NULL
                     AND f.name NOT IN ('ExitPermissionId', 'RequestInstanceId', 'EmployeeId', 'FullName', 'BranchName', 'ExitDate',
                                        'FromTime', 'ToTime', 'Minutes', 'RequestedMinutes', 'ApprovedMinutes', 'ConvertToLeave',
                                        'Status', 'IsOverdue')))
BEGIN
    RAISERROR('100_qa3_attendance.sql: the live workflow.usp_ExitPermission_GetPendingApplication differs from this redefinition (a parameter or result column it does not know) - merge by hand before applying.', 16, 1);
    SET NOEXEC ON;
END
GO
/* Approved permissions still WAITING for their attendance day to exist; a PAST date here means the day was never
   processed. QA3: overdue is judged on Beirut's date (it used the UTC date), the minutes are the approved ones. */
CREATE OR ALTER PROCEDURE workflow.usp_ExitPermission_GetPendingApplication
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    SELECT ep.ExitPermissionId, ep.RequestInstanceId, ep.EmployeeId, e.FullName,
           b.Name AS BranchName, ep.ExitDate, ep.FromTime, ep.ToTime,
           ISNULL(ep.ApprovedMinutes, ep.RequestedMinutes) AS Minutes, ep.RequestedMinutes, ep.ApprovedMinutes,
           ep.ConvertToLeave, r.[Status],
           CASE WHEN ep.ExitDate < @Today THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsOverdue
    FROM workflow.EXIT_PERMISSION ep
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
    JOIN hr.EMPLOYEE e ON e.EmployeeId = ep.EmployeeId
    LEFT JOIN hr.BRANCH b ON b.BranchId = hr.fn_EmployeeBranchOn(ep.EmployeeId, ep.ExitDate)
    WHERE r.[Status] = 'Approved'
      AND ep.AppliedToAttendanceAt IS NULL
    ORDER BY ep.ExitDate;
END;
GO

/* ---------------------------------------------------------------- 14. HR's own exit figures, and deleting a manual day */
/* Script 83's body; QA3: (a) @ClearHrApproval = 1 removes HR's own approved figure (ExitHrApprovedMinutes) so the
   approved exit permissions decide the day again - once set it used to win for ever, even over a permission approved
   later; (b) a manual day is re-run through the manual writer with its own inputs (one rule: the approval moves the
   cover, the variance and the leave minutes together - ATT-9), and a refusal rolls back. */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_SetExitApproval
    @AttendanceId        BIGINT,
    @ExitApprovedMinutes INT,
    @ExitPermissionId    INT = NULL,
    @AlsoSetActual       BIT = 0,              -- accepted for compatibility; IGNORED (BUG-13)
    @HrNote              NVARCHAR(300) = NULL,
    @Disposition         VARCHAR(20) = NULL,   -- optional: decide the remaining variance in the same call
    @ClearHrApproval     BIT = 0               -- QA3: 1 = forget HR's figure; the approved exit permissions decide again
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    /* script 83 (D10): a day that is already PAID for this employee is changed by a payroll adjustment, not here */
    DECLARE @PaidEmp INT, @PaidDate DATE, @PaidRc INT, @rc INT;
    SELECT @PaidEmp = EmployeeId, @PaidDate = WorkDate FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
    EXEC @PaidRc = payroll.usp_AssertPeriodOpen @PaidEmp, @PaidDate;
    IF @PaidRc <> 0 RETURN 1;

    SET @ClearHrApproval = ISNULL(@ClearHrApproval, 0);
    IF @ClearHrApproval = 0 AND (@ExitApprovedMinutes IS NULL OR @ExitApprovedMinutes < 0)
    BEGIN RAISERROR('ExitApprovedMinutes must be zero or more.', 16, 1); RETURN 1; END
    IF @Disposition IS NOT NULL AND @Disposition NOT IN ('UnpaidAbsence', 'Overtime', 'Ignore')
    BEGIN RAISERROR('Disposition must be UnpaidAbsence, Overtime, or Ignore.', 16, 1); RETURN 1; END

    DECLARE @Emp INT, @D DATE, @IsManual BIT;
    SELECT @Emp = EmployeeId, @D = WorkDate, @IsManual = IsManual FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
    IF @Emp IS NULL BEGIN RAISERROR('Attendance record not found.', 16, 1); RETURN 1; END
    IF @ClearHrApproval = 1 AND @IsManual = 1
    BEGIN RAISERROR('A manual day carries HR''s own figures and has no exit permissions to fall back on: enter the day again instead.', 16, 1); RETURN 1; END

    DECLARE @OuterTran INT = @@TRANCOUNT;
    BEGIN TRAN;
    SAVE TRAN qa3_exit_approval;

    UPDATE attendance.ATTENDANCE_RECORD
    SET ExitHrApprovedMinutes   = CASE WHEN @ClearHrApproval = 1 THEN NULL ELSE @ExitApprovedMinutes END,
        ExitPermissionId        = COALESCE(@ExitPermissionId, ExitPermissionId),
        ExitVarianceDisposition = COALESCE(@Disposition, ExitVarianceDisposition),
        HrNote                  = COALESCE(@HrNote, HrNote),
        ProcessedUtc            = SYSUTCDATETIME()
    WHERE AttendanceId = @AttendanceId;

    IF @IsManual = 1
    BEGIN
        /* a manual day: HR's approval is the day's approved figure; the day is measured again with its own inputs */
        UPDATE attendance.ATTENDANCE_RECORD SET ExitApprovedMinutes = @ExitApprovedMinutes WHERE AttendanceId = @AttendanceId;
        EXEC @rc = attendance.usp_Attendance_RecomputeManualDay @AttendanceId = @AttendanceId;
        IF ISNULL(@rc, 0) <> 0 BEGIN IF @OuterTran > 0 AND XACT_STATE() = 1 BEGIN ROLLBACK TRAN qa3_exit_approval; COMMIT TRAN; END ELSE IF @@TRANCOUNT > 0 ROLLBACK TRAN; RETURN 1; END
    END
    ELSE
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @D;

    COMMIT TRAN;

    SELECT AttendanceId, ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes,
           ExitLeaveMinutes, WorkedMinutes, DayFraction, IsFullDay, OvertimeMinutes,
           CoveredMinutes, EarlyExitMinutes, LateDeductMinutes, ExitVarianceDisposition, [Status]
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
END;
GO

/* Script 83's body; QA3: a manual day is re-run through the manual writer (the ruling is one of its inputs: it moves the
   cover and, for 'Overtime', the overtime - ATT-9), and the leave minutes it posted follow (REL-13). */
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
    DECLARE @PaidEmp INT, @PaidDate DATE, @PaidRc INT, @rc INT;
    SELECT @PaidEmp = EmployeeId, @PaidDate = WorkDate FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
    EXEC @PaidRc = payroll.usp_AssertPeriodOpen @PaidEmp, @PaidDate;
    IF @PaidRc <> 0 RETURN 1;

    IF @Disposition NOT IN ('UnpaidAbsence', 'Overtime', 'Ignore') OR @Disposition IS NULL
    BEGIN RAISERROR('Disposition must be UnpaidAbsence, Overtime, or Ignore.', 16, 1); RETURN 1; END
    IF @ExitLeaveMinutesOverride IS NOT NULL AND @ExitLeaveMinutesOverride < 0
    BEGIN RAISERROR('The leave minutes must be zero or more.', 16, 1); RETURN 1; END

    DECLARE @Emp INT, @D DATE, @IsManual BIT;
    SELECT @Emp = EmployeeId, @D = WorkDate, @IsManual = IsManual FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
    IF @Emp IS NULL BEGIN RAISERROR('Attendance record not found.', 16, 1); RETURN 1; END

    DECLARE @OuterTran INT = @@TRANCOUNT;
    BEGIN TRAN;
    SAVE TRAN qa3_exit_disposition;

    /* the decision is a stored INPUT of the rule; the row stays computed, so a reprocess keeps the decision */
    UPDATE attendance.ATTENDANCE_RECORD
    SET ExitVarianceDisposition  = @Disposition,
        ExitLeaveOverrideMinutes = COALESCE(@ExitLeaveMinutesOverride, ExitLeaveOverrideMinutes),
        HrNote                   = COALESCE(@HrNote, HrNote),
        ProcessedUtc             = SYSUTCDATETIME()
    WHERE AttendanceId = @AttendanceId;

    IF @IsManual = 0
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @D;
    ELSE
    BEGIN
        EXEC @rc = attendance.usp_Attendance_RecomputeManualDay @AttendanceId = @AttendanceId;
        IF ISNULL(@rc, 0) <> 0 BEGIN IF @OuterTran > 0 AND XACT_STATE() = 1 BEGIN ROLLBACK TRAN qa3_exit_disposition; COMMIT TRAN; END ELSE IF @@TRANCOUNT > 0 ROLLBACK TRAN; RETURN 1; END
    END

    COMMIT TRAN;

    SELECT AttendanceId, ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes,
           ExitLeaveMinutes, ExitVarianceDisposition, WorkedMinutes, DayFraction, IsFullDay, CoveredMinutes, [Status]
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;
END;
GO

/* Script 83's body; QA3: (a) a day that carries correction requests is refused with a sentence (the correction keeps
   the record; the delete failed on the foreign key); (b) the day's exit-permission posting follows (REL-13). */
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
    IF @PaidRc <> 0 RETURN 1;

    DECLARE @EmployeeId INT, @WorkDate DATE, @IsManual BIT;
    SELECT @EmployeeId = EmployeeId, @WorkDate = WorkDate, @IsManual = IsManual
    FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @AttendanceId;

    IF @EmployeeId IS NULL
    BEGIN RAISERROR('Attendance record not found.', 16, 1); RETURN 1; END
    IF @IsManual = 0
    BEGIN DECLARE @Dash NCHAR(1) = NCHAR(8212); RAISERROR(N'Only manually added records can be deleted %s machine-derived days are corrected, not deleted.', 16, 1, @Dash); RETURN 1; END
    IF EXISTS (SELECT 1 FROM attendance.ATTENDANCE_CORRECTION WHERE AttendanceId = @AttendanceId)
    BEGIN RAISERROR('This day carries correction requests, which keep its history: it cannot be deleted. Enter the day again instead.', 16, 1); RETURN 1; END

    BEGIN TRAN;

    DELETE FROM attendance.ATTENDANCE_INTERVAL WHERE AttendanceId = @AttendanceId;
    DELETE FROM attendance.ATTENDANCE_RECORD   WHERE AttendanceId = @AttendanceId;

    /* That day's MANUAL punches go too - otherwise re-processing resurrects the day. */
    DELETE r
    FROM attendance.RAW_DEVICE_LOG r
    WHERE r.EmployeeId = @EmployeeId
      AND CAST(r.PunchTimeUtc AS DATE) = @WorkDate
      AND r.[Source] = 'Manual';

    COMMIT;

    /* Machine punches (if any) rebuild the day honestly; a posting of the day's exit minutes follows what is left. */
    EXEC attendance.usp_Attendance_ReprocessDay @WorkDate = @WorkDate;
    EXEC workflow.usp_ExitPermission_RepostDay @EmployeeId = @EmployeeId, @WorkDate = @WorkDate;
END;
GO

/* ---------------------------------------------------------------- 15. data repairs (guarded, idempotent) */
/* Rows the old rules wrote wrong, in OPEN periods only: every re-derivation goes through usp_Attendance_ComputeDay,
   which leaves a day already paid for the employee exactly as it was paid (and skips manual days). A second run finds
   nothing left to do. Each repair prints what it did. */
SET NOCOUNT ON;
DECLARE @fix TABLE (EmployeeId INT, WorkDate DATE, PRIMARY KEY (EmployeeId, WorkDate));
DECLARE @e INT, @d DATE, @n INT;

/* R1 (ROS-1, ATT-2, REL-1): non-manual records outside the employment (absences after a termination, days before a
   corrected hire date) - ComputeDay removes them with their exit-permission posting */
INSERT INTO @fix (EmployeeId, WorkDate)
SELECT a.EmployeeId, a.WorkDate
FROM attendance.ATTENDANCE_RECORD a
JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
WHERE a.IsManual = 0
  AND (a.WorkDate < e.HireDate OR a.WorkDate > e.TerminationDate)
  AND payroll.fn_IsPeriodPaid(a.EmployeeId, a.WorkDate) = 0;
SET @n = @@ROWCOUNT;
DECLARE fx CURSOR LOCAL FAST_FORWARD FOR SELECT EmployeeId, WorkDate FROM @fix;
OPEN fx; FETCH NEXT FROM fx INTO @e, @d;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @e, @WorkDate = @d; FETCH NEXT FROM fx INTO @e, @d; END
CLOSE fx; DEALLOCATE fx;
PRINT CONCAT('R1 records outside the employment re-derived (removed unless a correction holds them): ', @n);
DELETE FROM @fix;

/* R2 (ATT-8, LEV-2, REL-6): non-manual 'Leave' days no approved full-day leave covers any more (beyond the approved
   part of a partially approved request, or an approval taken back) - judged from the punches */
INSERT INTO @fix (EmployeeId, WorkDate)
SELECT a.EmployeeId, a.WorkDate
FROM attendance.ATTENDANCE_RECORD a
WHERE a.IsManual = 0 AND a.[Status] = 'Leave'
  AND payroll.fn_IsPeriodPaid(a.EmployeeId, a.WorkDate) = 0
  AND NOT EXISTS (SELECT 1 FROM workflow.LEAVE_REQUEST lr
                  JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId AND ri.[Status] = 'Approved'
                  WHERE lr.EmployeeId = a.EmployeeId AND lr.HalfDay IS NULL
                    AND a.WorkDate BETWEEN lr.FromDate AND ISNULL(lr.ApprovedToDate, lr.ToDate));
SET @n = @@ROWCOUNT;
DECLARE fx CURSOR LOCAL FAST_FORWARD FOR SELECT EmployeeId, WorkDate FROM @fix;
OPEN fx; FETCH NEXT FROM fx INTO @e, @d;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @e, @WorkDate = @d; FETCH NEXT FROM fx INTO @e, @d; END
CLOSE fx; DEALLOCATE fx;
PRINT CONCAT('R2 Leave days no approved leave covers, re-derived from the punches: ', @n);
DELETE FROM @fix;

/* R3 (ATT-14, ROS-5): non-manual records on FUTURE dates that hold no punch (the old holiday re-derivation wrote them);
   a future day is derived when it happens. Records holding a punch, a correction or a posting are left. */
DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
DELETE a
FROM attendance.ATTENDANCE_RECORD a
WHERE a.WorkDate > @Today AND a.IsManual = 0
  AND a.FirstInUtc IS NULL AND a.LastOutUtc IS NULL
  AND payroll.fn_IsPeriodPaid(a.EmployeeId, a.WorkDate) = 0
  AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_CORRECTION c WHERE c.AttendanceId = a.AttendanceId)
  AND NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER l JOIN workflow.EXIT_PERMISSION ep ON ep.ExitPermissionId = l.SourceRef
                  WHERE l.SourceType = 'ExitPermission' AND ep.EmployeeId = a.EmployeeId AND ep.ExitDate = a.WorkDate);
PRINT CONCAT('R3 future records without a punch removed: ', @@ROWCOUNT);

/* R4 (ATT-9): non-manual days with an exit variance - the 'Overtime' ruling now absorbs the variance from the overtime,
   and the leave minutes are the permission minutes used; a day already posted at the period close is re-posted */
INSERT INTO @fix (EmployeeId, WorkDate)
SELECT a.EmployeeId, a.WorkDate
FROM attendance.ATTENDANCE_RECORD a
WHERE a.IsManual = 0 AND a.ExitVarianceMinutes > 0
  AND payroll.fn_IsPeriodPaid(a.EmployeeId, a.WorkDate) = 0;
SET @n = @@ROWCOUNT;
DECLARE fx CURSOR LOCAL FAST_FORWARD FOR SELECT EmployeeId, WorkDate FROM @fix;
OPEN fx; FETCH NEXT FROM fx INTO @e, @d;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @e, @WorkDate = @d; FETCH NEXT FROM fx INTO @e, @d; END
CLOSE fx; DEALLOCATE fx;
PRINT CONCAT('R4 days with an exit variance re-derived: ', @n);
DELETE FROM @fix;

/* R5 (precedence) and R6 (a holiday worked with a lost punch): rest days that are public holidays, and holidays with a
   punch but no anomaly - re-derived */
INSERT INTO @fix (EmployeeId, WorkDate)
SELECT a.EmployeeId, a.WorkDate
FROM attendance.ATTENDANCE_RECORD a
WHERE a.IsManual = 0
  AND payroll.fn_IsPeriodPaid(a.EmployeeId, a.WorkDate) = 0
  AND (   (a.[Status] = 'RestDay' AND core.fn_IsHoliday(a.WorkDate, hr.fn_EmployeeBranchOn(a.EmployeeId, a.WorkDate)) = 1)
       OR (a.[Status] = 'Holiday' AND a.HasAnomaly = 0 AND (a.FirstInUtc IS NOT NULL OR a.LastOutUtc IS NOT NULL)));
SET @n = @@ROWCOUNT;
DECLARE fx CURSOR LOCAL FAST_FORWARD FOR SELECT EmployeeId, WorkDate FROM @fix;
OPEN fx; FETCH NEXT FROM fx INTO @e, @d;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @e, @WorkDate = @d; FETCH NEXT FROM fx INTO @e, @d; END
CLOSE fx; DEALLOCATE fx;
PRINT CONCAT('R5/R6 rest days on a holiday and worked holidays re-derived: ', @n);
DELETE FROM @fix;

/* R7 (ATT-10): a correction the old approve recorded as Approved although the manual writer refused it - the day is
   still the machine's (a successful approval makes it manual). Back to Pending; the anomaly it stamped 'Corrected'
   (here or through Anomalies > Correct) back to undecided, with a note. Open periods only. */
UPDATE c
SET c.ApprovalStatus = 'Pending', c.ApprovedBy = NULL, c.ActedUtc = NULL
FROM attendance.ATTENDANCE_CORRECTION c
JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = c.AttendanceId
WHERE c.ApprovalStatus = 'Approved' AND a.IsManual = 0
  AND payroll.fn_IsPeriodPaid(a.EmployeeId, a.WorkDate) = 0;
PRINT CONCAT('R7 corrections that never applied, back to Pending: ', @@ROWCOUNT);
UPDATE an
SET an.Note = LEFT(CONCAT(N'The correction recorded on this anomaly never reached the day (it was refused) ', NCHAR(8212),
                          N' decide again. Earlier note: ', an.Note), 300),
    an.Decision = NULL, an.DecidedByUserId = NULL, an.DecidedAt = NULL, an.UpdatedAt = SYSUTCDATETIME()
FROM attendance.ATTENDANCE_ANOMALY an
JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = an.AttendanceId
WHERE an.Decision = 'Corrected' AND a.IsManual = 0
  AND payroll.fn_IsPeriodPaid(a.EmployeeId, a.WorkDate) = 0;
PRINT CONCAT('R7 Corrected anomalies on days that never changed, undecided again: ', @@ROWCOUNT);
GO

/* ---------------------------------------------------------------- 16. verification */
DECLARE @cols INT = (SELECT COUNT(*) FROM sys.dm_exec_describe_first_result_set(
    N'SELECT * FROM attendance.fn_AttendanceDayRule(NULL,NULL,0,0,0,NULL,NULL,0,0,NULL,0,NULL,NULL,1,0,0,0,0,0,0)', NULL, 0));
PRINT CONCAT('fn_AttendanceDayRule columns = ', @cols, ' (expected 23)');
PRINT CONCAT('posting procedures = ',
             CASE WHEN OBJECT_ID('workflow.usp_ExitPermission_PostDay') IS NOT NULL AND OBJECT_ID('workflow.usp_ExitPermission_RepostDay') IS NOT NULL
                  THEN 'present' ELSE 'MISSING' END,
             ', quarantine dismissal = ', CASE WHEN OBJECT_ID('attendance.usp_DevicePunchQuarantine_Dismiss') IS NULL THEN 'MISSING' ELSE 'present' END);
PRINT '100_qa3_attendance.sql in place';
GO
