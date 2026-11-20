/* ============================================================================
   117_shift_hours_by_date.sql - A SHIFT'S HOURS CAN CHANGE FROM A DATE (AND COME BACK), AND THE LENGTH OF A WORKING
   DAY COMES FROM THE SHIFTS, NOT FROM A SETTING.

   WHAT WAS WRONG. A day is judged against its shift's times, read LIVE from attendance.SHIFT. So script 100 had to
   FREEZE the times of any shift already worked ("create a new shift and roster it from the date it starts"): winter
   hours, Ramadan hours, a trial of a later opening all meant new shifts and re-rostering, and going back meant doing
   it again. And a day with no rostered shift was measured against one figure typed in Settings (StandardWorkDayHours),
   whatever shift the person actually worked.

   WHAT THIS SCRIPT DOES
   1. attendance.SHIFT_HOURS - the HISTORY of each shift's hours: a row says "from this date the shift runs
      start-end, with this break, grace and overnight flag". The hours of a day are the row in force on that day
      (attendance.fn_ShiftHoursOn). attendance.SHIFT keeps the hours in force TODAY (usp_Shift_SyncCurrent, run by
      every change and by the nightly job), so everything that only shows a shift reads on as before.
   2. Changing hours: attendance.usp_Shift_SetHours (@EffectiveFrom, optional @EffectiveTo). With an end date the
      hours that were in force come back the day after - "change the shift, then return it" is one entry. A change
      that reaches back re-derives the days it touches; a day already PAID is never touched, so a change may not
      start inside a paid period. usp_Shift_Update takes the same dates; usp_Shift_GetHours lists the history;
      usp_Shift_DeleteHours takes one change back.
   (the Worked time report measures a punched day missing from the roster the same way:
      report.usp_Report_WorkedTime_PunchDaysByShift, which the API reads instead of script 114's procedure)
   3. Both writers of a day (usp_Attendance_ComputeDay, usp_Attendance_ManualUpsert) read the hours in force ON THAT
      DAY. A day WITHOUT a rostered shift is measured against the shift its first punch fits (the active shift whose
      start is nearest, attendance.fn_ShiftByPunch): that shift gives the day its length and its break - still no
      late or early rule without a roster. The record remembers it (ATTENDANCE_RECORD.RelatedShiftId).
   4. core.fn_StandardDayMinutes no longer reads a setting: it is the length of the DEFAULT shift (the active shift
      most rostered in the last 90 days; else the first active shift; else 8 hours) and is only the fallback for a
      day no shift can be related to.
   5. Money that was priced per hour of the Settings figure is priced per hour of THE DAY'S OWN SHIFT:
      - payroll: an hour of overtime = the day rate over the hours of that day's shift (payroll.fn_DayStandardMinutes),
        and a public holiday worked on a rest day is a share of the employee's own day;
      - leave: the minutes of an exit permission converted to leave are a share of that day's shift
        (core.fn_MinutesToLeaveDaysOn; workflow.usp_ExitPermission_PostDay / _RepostDay).
   6. The setting StandardWorkDayHours is REMOVED (the Settings page no longer shows it).

   PAST DAYS keep the figures they were computed with until something re-derives them (Roster > Re-derive month).
   A payroll run in Review reads as out of date once (its hour basis changed): regenerate it.

   The numbered bodies re-issued here are the current ones (scripts 100, 103, 87, 114) with the changes marked
   'script 117'. MARKER for the deploy guard: attendance.usp_Shift_SetHours.

   Idempotent. Apply: sqlcmd -C -I -b -d <database> -i docs/117_shift_hours_by_date.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('attendance.SHIFT') IS NULL OR OBJECT_ID('attendance.fn_AttendanceDayRule') IS NULL
   OR OBJECT_ID('payroll.fn_IsPeriodPaid') IS NULL OR OBJECT_ID('report.usp_Report_WorkedTime_PunchDays') IS NULL
   OR OBJECT_ID('attendance.usp_Attendance_RecomputeManualDay') IS NULL
BEGIN
    RAISERROR('117_shift_hours_by_date.sql: attendance.SHIFT, the day rule (script 100), payroll.fn_IsPeriodPaid or the worked time report (script 114) is missing. Apply the earlier numbered scripts first. Nothing was applied.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ---------------------------------------------------------------- 1. the history of a shift's hours */
IF OBJECT_ID('attendance.SHIFT_HOURS') IS NULL
BEGIN
    CREATE TABLE attendance.SHIFT_HOURS (
        ShiftHoursId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SHIFT_HOURS PRIMARY KEY,
        ShiftId         INT           NOT NULL CONSTRAINT FK_SHIFT_HOURS_Shift REFERENCES attendance.SHIFT (ShiftId),
        EffectiveFrom   DATE          NOT NULL,          -- the first day these hours apply (the first row of a shift: 2000-01-01)
        StartTime       TIME          NOT NULL,
        EndTime         TIME          NOT NULL,
        CrossesMidnight BIT           NOT NULL CONSTRAINT DF_SHIFT_HOURS_Cross DEFAULT 0,
        BreakMinutes    INT           NOT NULL CONSTRAINT DF_SHIFT_HOURS_Break DEFAULT 0,
        GraceMinutes    INT           NULL,              -- NULL = the AttendanceToleranceMinutes setting
        Note            NVARCHAR(200) NULL,
        CreatedByUserId INT           NULL,
        CreatedAtUtc    DATETIME2(0)  NOT NULL CONSTRAINT DF_SHIFT_HOURS_Created DEFAULT SYSUTCDATETIME(),
        CONSTRAINT UQ_SHIFT_HOURS UNIQUE (ShiftId, EffectiveFrom)
    );
    PRINT 'table attendance.SHIFT_HOURS created';
END
GO

/* every shift starts its history with the hours it has now, for all the past */
INSERT INTO attendance.SHIFT_HOURS (ShiftId, EffectiveFrom, StartTime, EndTime, CrossesMidnight, BreakMinutes, GraceMinutes, Note)
SELECT s.ShiftId, '2000-01-01', s.StartTime, s.EndTime, ISNULL(s.CrossesMidnight, 0), ISNULL(s.BreakMinutes, 0), s.GraceMinutes,
       N'The hours the shift had when its history began'
FROM attendance.SHIFT s
WHERE NOT EXISTS (SELECT 1 FROM attendance.SHIFT_HOURS h WHERE h.ShiftId = s.ShiftId);
IF @@ROWCOUNT > 0 PRINT 'attendance.SHIFT_HOURS: the history of the existing shifts started from their present hours';
GO

IF COL_LENGTH('attendance.ATTENDANCE_RECORD', 'RelatedShiftId') IS NULL
BEGIN
    ALTER TABLE attendance.ATTENDANCE_RECORD ADD RelatedShiftId INT NULL;   -- the shift a day without a rostered shift was measured against
    PRINT 'attendance.ATTENDANCE_RECORD.RelatedShiftId added';
END
GO

/* ---------------------------------------------------------------- 2. the hours of a shift on a day */
/* One row: the hours in force on @Date (the latest row starting on or before it). A shift with no history row yet
   (created by an older procedure) answers with its own row. StandardMinutes = end - start - break. */
CREATE OR ALTER FUNCTION attendance.fn_ShiftHoursOn (@ShiftId INT, @Date DATE)
RETURNS TABLE
AS RETURN
SELECT TOP 1 x.StartTime, x.EndTime, x.CrossesMidnight, x.BreakMinutes, x.GraceMinutes, x.EffectiveFrom,
       DATEDIFF(MINUTE, x.StartTime, x.EndTime) + CASE WHEN x.CrossesMidnight = 1 THEN 1440 ELSE 0 END - x.BreakMinutes AS StandardMinutes
FROM (
    SELECT h.StartTime, h.EndTime, h.CrossesMidnight, h.BreakMinutes, h.GraceMinutes, h.EffectiveFrom, 0 AS Fallback
    FROM attendance.SHIFT_HOURS h
    WHERE h.ShiftId = @ShiftId AND h.EffectiveFrom <= ISNULL(@Date, '9999-12-31')
    UNION ALL
    SELECT s.StartTime, s.EndTime, ISNULL(s.CrossesMidnight, 0), ISNULL(s.BreakMinutes, 0), s.GraceMinutes, CAST(NULL AS DATE), 1
    FROM attendance.SHIFT s
    WHERE s.ShiftId = @ShiftId
) x
ORDER BY x.Fallback, x.EffectiveFrom DESC;
GO

/* The shift a day WITHOUT a rostered shift is measured against: the active shift whose start, by its hours in force
   that day, is nearest to the first in (two as near: the longer one, then the older one). No row when there is no
   punch or no active shift - the caller then keeps the default day. Punch times are wall-clock, like the shift's. */
CREATE OR ALTER FUNCTION attendance.fn_ShiftByPunch (@WorkDate DATE, @FirstInUtc DATETIME2)
RETURNS TABLE
AS RETURN
SELECT TOP 1 s.ShiftId, h.StandardMinutes, h.BreakMinutes
FROM attendance.SHIFT s
CROSS APPLY attendance.fn_ShiftHoursOn(s.ShiftId, @WorkDate) h
WHERE s.IsActive = 1 AND @WorkDate IS NOT NULL AND @FirstInUtc IS NOT NULL AND h.StandardMinutes > 0
ORDER BY ABS(DATEDIFF(MINUTE, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, h.StartTime), CAST(@WorkDate AS DATETIME2)), @FirstInUtc)),
         h.StandardMinutes DESC, s.ShiftId;
GO

/* THE DEFAULT DAY, in minutes. It was the setting StandardWorkDayHours; it is now a shift's length too: the active
   shift most rostered in the last 90 days (by its hours today), else the first active shift, else 8 hours. Only the
   fallback for a day no shift can be related to - every other day has its own shift's length. */
CREATE OR ALTER FUNCTION core.fn_StandardDayMinutes ()
RETURNS INT
AS
BEGIN
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @ShiftId INT = (
        SELECT TOP 1 s.ShiftId
        FROM attendance.SHIFT s
        LEFT JOIN (SELECT sa.ShiftId, COUNT(*) AS Days
                   FROM attendance.SHIFT_ASSIGNMENT sa
                   WHERE sa.WorkDate BETWEEN DATEADD(DAY, -90, @Today) AND @Today
                     AND sa.ShiftId IS NOT NULL AND ISNULL(sa.IsRestDay, 0) = 0
                   GROUP BY sa.ShiftId) u ON u.ShiftId = s.ShiftId
        WHERE s.IsActive = 1
        ORDER BY ISNULL(u.Days, 0) DESC, s.ShiftId);
    DECLARE @Minutes INT = (SELECT h.StandardMinutes FROM attendance.fn_ShiftHoursOn(@ShiftId, @Today) h);
    RETURN CASE WHEN @Minutes > 0 THEN @Minutes ELSE 480 END;
END;
GO

/* Minutes of exit-permission leave as a share of THE DAY THEY FALL ON: over that day's standard (its shift's length);
   over the default day when the day has none. core.fn_MinutesToLeaveDays (no day given) still divides by the default
   day - the lists that only show a figure read it. */
CREATE OR ALTER FUNCTION core.fn_MinutesToLeaveDaysOn (@Minutes INT, @StandardMinutes INT)
RETURNS DECIMAL(6,2)
AS
BEGIN
    DECLARE @std INT = CASE WHEN @StandardMinutes > 0 THEN @StandardMinutes ELSE core.fn_StandardDayMinutes() END;
    IF @std IS NULL OR @std = 0 RETURN 0;
    RETURN CAST(ROUND(CAST(ISNULL(@Minutes, 0) AS DECIMAL(12,4)) / @std, 2) AS DECIMAL(6,2));
END;
GO

/* The length of ONE employee's day, for an hour of pay on it (overtime): the standard the day was measured against;
   on a rest day (no standard of its own) the hours of the shift rostered there, else the employee's last working day
   in the two months before; else the default day. */
CREATE OR ALTER FUNCTION payroll.fn_DayStandardMinutes (@EmployeeId INT, @WorkDate DATE)
RETURNS INT
AS
BEGIN
    DECLARE @m INT = (SELECT TOP 1 a.StandardMinutes FROM attendance.ATTENDANCE_RECORD a
                      WHERE a.EmployeeId = @EmployeeId AND a.WorkDate = @WorkDate AND a.StandardMinutes > 0);
    IF @m IS NULL
        SELECT TOP 1 @m = h.StandardMinutes
        FROM attendance.SHIFT_ASSIGNMENT sa
        CROSS APPLY attendance.fn_ShiftHoursOn(sa.ShiftId, sa.WorkDate) h
        WHERE sa.EmployeeId = @EmployeeId AND sa.WorkDate = @WorkDate AND sa.ShiftId IS NOT NULL AND h.StandardMinutes > 0;
    IF @m IS NULL
        SELECT TOP 1 @m = a.StandardMinutes FROM attendance.ATTENDANCE_RECORD a
        WHERE a.EmployeeId = @EmployeeId AND a.WorkDate < @WorkDate AND a.WorkDate >= DATEADD(DAY, -60, @WorkDate) AND a.StandardMinutes > 0
        ORDER BY a.WorkDate DESC;
    RETURN ISNULL(@m, core.fn_StandardDayMinutes());
END;
GO

/* ---------------------------------------------------------------- 3. keeping attendance.SHIFT at today's hours */
/* attendance.SHIFT shows the hours in force TODAY. A change dated ahead takes its place on its day: every change calls
   this, and so does the nightly job. @Quiet = 1: no result set. */
CREATE OR ALTER PROCEDURE attendance.usp_Shift_SyncCurrent
    @ShiftId INT = NULL,
    @Quiet   BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    UPDATE s
    SET s.StartTime = h.StartTime, s.EndTime = h.EndTime, s.CrossesMidnight = h.CrossesMidnight,
        s.BreakMinutes = h.BreakMinutes, s.GraceMinutes = h.GraceMinutes
    FROM attendance.SHIFT s
    CROSS APPLY attendance.fn_ShiftHoursOn(s.ShiftId, @Today) h
    WHERE (@ShiftId IS NULL OR s.ShiftId = @ShiftId)
      AND h.EffectiveFrom IS NOT NULL
      AND (s.StartTime <> h.StartTime OR s.EndTime <> h.EndTime OR ISNULL(s.CrossesMidnight, 0) <> h.CrossesMidnight
           OR ISNULL(s.BreakMinutes, 0) <> h.BreakMinutes OR ISNULL(s.GraceMinutes, -1) <> ISNULL(h.GraceMinutes, -1));
    DECLARE @n INT = @@ROWCOUNT;
    IF @Quiet = 0 SELECT @n AS ShiftsUpdated;
END;
GO

/* The days a change of hours touches are derived again: the days of [@From, @To] up to today that are rostered on the
   shift, and the days with no rostered shift (which shift their punch fits may change). A paid day is left alone by
   the writers themselves; a day HR entered by hand goes through its own writer. */
CREATE OR ALTER PROCEDURE attendance.usp_Shift_RederiveDays
    @ShiftId INT, @From DATE, @To DATE = NULL,
    @Days INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @Last DATE = CASE WHEN @To IS NULL OR @To > @Today THEN @Today ELSE @To END;
    SET @Days = 0;
    IF @From IS NULL OR @From > @Last RETURN;

    DECLARE @day TABLE (AttendanceId BIGINT PRIMARY KEY, EmployeeId INT, WorkDate DATE, IsManual BIT);
    INSERT INTO @day (AttendanceId, EmployeeId, WorkDate, IsManual)
    SELECT a.AttendanceId, a.EmployeeId, a.WorkDate, a.IsManual
    FROM attendance.ATTENDANCE_RECORD a
    WHERE a.WorkDate BETWEEN @From AND @Last
      AND (a.ShiftAssignmentId IS NULL
           OR EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                      WHERE sa.EmployeeId = a.EmployeeId AND sa.WorkDate = a.WorkDate AND sa.ShiftId = @ShiftId))
      AND payroll.fn_IsPeriodPaid(a.EmployeeId, a.WorkDate) = 0;

    DECLARE @a BIGINT, @e INT, @d DATE, @m BIT;
    DECLARE sh_cur CURSOR LOCAL FAST_FORWARD FOR SELECT AttendanceId, EmployeeId, WorkDate, IsManual FROM @day ORDER BY WorkDate, EmployeeId;
    OPEN sh_cur; FETCH NEXT FROM sh_cur INTO @a, @e, @d, @m;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @m = 1 EXEC attendance.usp_Attendance_RecomputeManualDay @AttendanceId = @a;
        ELSE      EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @e, @WorkDate = @d;
        SET @Days = @Days + 1;
        FETCH NEXT FROM sh_cur INTO @a, @e, @d, @m;
    END
    CLOSE sh_cur; DEALLOCATE sh_cur;
END;
GO

/* ---------------------------------------------------------------- 4. changing a shift's hours */
/* A row that only repeats the one before it says nothing (a change taken back, hours set to what they already were):
   the history keeps the real changes. */
CREATE OR ALTER PROCEDURE attendance.usp_Shift_TidyHours
    @ShiftId INT
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH v AS (
        SELECT h.ShiftHoursId, h.StartTime, h.EndTime, h.CrossesMidnight, h.BreakMinutes, h.GraceMinutes,
               ROW_NUMBER() OVER (ORDER BY h.EffectiveFrom) AS Rn,
               LAG(h.StartTime)       OVER (ORDER BY h.EffectiveFrom) AS pStart,
               LAG(h.EndTime)         OVER (ORDER BY h.EffectiveFrom) AS pEnd,
               LAG(h.CrossesMidnight) OVER (ORDER BY h.EffectiveFrom) AS pCross,
               LAG(h.BreakMinutes)    OVER (ORDER BY h.EffectiveFrom) AS pBreak,
               LAG(h.GraceMinutes)    OVER (ORDER BY h.EffectiveFrom) AS pGrace
        FROM attendance.SHIFT_HOURS h WHERE h.ShiftId = @ShiftId)
    DELETE FROM v
    WHERE v.Rn > 1 AND v.StartTime = v.pStart AND v.EndTime = v.pEnd AND v.CrossesMidnight = v.pCross
      AND v.BreakMinutes = v.pBreak AND ISNULL(v.GraceMinutes, -1) = ISNULL(v.pGrace, -1);
END;
GO

/* NEW HOURS FROM A DATE. Open-ended (@EffectiveTo NULL): the hours apply from @EffectiveFrom until the next change
   already recorded after it. With @EffectiveTo: the hours apply for that period and THE HOURS THAT WERE IN FORCE COME
   BACK the day after (changes recorded inside the period are replaced by it). Result: DaysRederived. */
CREATE OR ALTER PROCEDURE attendance.usp_Shift_SetHours
    @ShiftId         INT,
    @EffectiveFrom   DATE,
    @EffectiveTo     DATE = NULL,
    @StartTime       TIME,
    @EndTime         TIME,
    @CrossesMidnight BIT = 0,
    @BreakMinutes    INT = 0,
    @GraceMinutes    INT = NULL,
    @Note            NVARCHAR(200) = NULL,
    @CallerUserId    INT = NULL,
    @Quiet           BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @CrossesMidnight = ISNULL(@CrossesMidnight, 0);
    SET @BreakMinutes = ISNULL(@BreakMinutes, 0);
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');

    DECLARE @Name NVARCHAR(50) = (SELECT Name FROM attendance.SHIFT WHERE ShiftId = @ShiftId);
    IF @Name IS NULL BEGIN RAISERROR('Shift not found.', 16, 1); RETURN 1; END
    IF @StartTime IS NULL OR @EndTime IS NULL BEGIN RAISERROR('Give the start and the end of the shift.', 16, 1); RETURN 1; END
    IF @StartTime = @EndTime
    BEGIN RAISERROR('A shift cannot start and end at the same time.', 16, 1); RETURN 1; END
    IF @EndTime < @StartTime AND @CrossesMidnight = 0
    BEGIN RAISERROR('This shift ends before it starts. Tick ''crosses midnight'' if it is an overnight shift.', 16, 1); RETURN 1; END
    IF @GraceMinutes IS NOT NULL AND @GraceMinutes < 0
    BEGIN RAISERROR('GraceMinutes must be zero or more, or empty to use the AttendanceToleranceMinutes setting.', 16, 1); RETURN 1; END
    IF @BreakMinutes < 0
       OR @BreakMinutes >= DATEDIFF(MINUTE, @StartTime, @EndTime) + CASE WHEN @CrossesMidnight = 1 THEN 1440 ELSE 0 END
    BEGIN RAISERROR('The break must be zero or more, and shorter than the shift.', 16, 1); RETURN 1; END
    IF @EffectiveFrom IS NULL BEGIN RAISERROR('Choose the day the new hours start.', 16, 1); RETURN 1; END
    IF @EffectiveFrom < '2000-01-01' BEGIN RAISERROR('The day the new hours start cannot be before the year 2000.', 16, 1); RETURN 1; END
    IF @EffectiveTo IS NOT NULL AND @EffectiveTo < @EffectiveFrom
    BEGIN RAISERROR('The last day of the new hours is before their first day.', 16, 1); RETURN 1; END

    /* a paid day keeps the hours it was paid on */
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @PaidDay DATE = (
        SELECT MAX(sa.WorkDate)
        FROM attendance.SHIFT_ASSIGNMENT sa
        WHERE sa.ShiftId = @ShiftId AND sa.WorkDate >= @EffectiveFrom AND sa.WorkDate <= @Today
          AND (@EffectiveTo IS NULL OR sa.WorkDate <= @EffectiveTo)
          AND payroll.fn_IsPeriodPaid(sa.EmployeeId, sa.WorkDate) = 1);
    IF @PaidDay IS NOT NULL
    BEGIN
        DECLARE @PaidMsg NVARCHAR(400) = CONCAT(N'Days on the shift ', @Name, N' up to ', CONVERT(CHAR(10), @PaidDay, 23),
            N' are already paid, and a paid day keeps the hours it was paid on. Start the new hours after that day.');
        RAISERROR('%s', 16, 1, @PaidMsg);
        RETURN 1;
    END

    BEGIN TRAN;

    /* a shift that has no history yet (made by an older procedure) first gets its present hours for all the past -
       or the days before this change would be read from attendance.SHIFT, which is about to show the new hours */
    IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_HOURS WITH (UPDLOCK, HOLDLOCK) WHERE ShiftId = @ShiftId)
        INSERT INTO attendance.SHIFT_HOURS (ShiftId, EffectiveFrom, StartTime, EndTime, CrossesMidnight, BreakMinutes, GraceMinutes, Note)
        SELECT s.ShiftId, '2000-01-01', s.StartTime, s.EndTime, ISNULL(s.CrossesMidnight, 0), ISNULL(s.BreakMinutes, 0), s.GraceMinutes,
               N'The hours the shift had when its history began'
        FROM attendance.SHIFT s WHERE s.ShiftId = @ShiftId;

    /* the hours to come back to: what is in force the day after the period, as things stand before this change */
    DECLARE @BackFrom DATE = DATEADD(DAY, 1, @EffectiveTo);
    DECLARE @bStart TIME, @bEnd TIME, @bCross BIT, @bBreak INT, @bGrace INT;
    IF @EffectiveTo IS NOT NULL
    BEGIN
        SELECT @bStart = h.StartTime, @bEnd = h.EndTime, @bCross = h.CrossesMidnight, @bBreak = h.BreakMinutes, @bGrace = h.GraceMinutes
        FROM attendance.fn_ShiftHoursOn(@ShiftId, @BackFrom) h;
        DELETE FROM attendance.SHIFT_HOURS WITH (HOLDLOCK)
        WHERE ShiftId = @ShiftId AND EffectiveFrom > @EffectiveFrom AND EffectiveFrom <= @BackFrom;
    END

    IF EXISTS (SELECT 1 FROM attendance.SHIFT_HOURS WITH (UPDLOCK, HOLDLOCK) WHERE ShiftId = @ShiftId AND EffectiveFrom = @EffectiveFrom)
        UPDATE attendance.SHIFT_HOURS
        SET StartTime = @StartTime, EndTime = @EndTime, CrossesMidnight = @CrossesMidnight, BreakMinutes = @BreakMinutes,
            GraceMinutes = @GraceMinutes, Note = @Note, CreatedByUserId = @CallerUserId, CreatedAtUtc = SYSUTCDATETIME()
        WHERE ShiftId = @ShiftId AND EffectiveFrom = @EffectiveFrom;
    ELSE
        INSERT INTO attendance.SHIFT_HOURS (ShiftId, EffectiveFrom, StartTime, EndTime, CrossesMidnight, BreakMinutes, GraceMinutes, Note, CreatedByUserId)
        VALUES (@ShiftId, @EffectiveFrom, @StartTime, @EndTime, @CrossesMidnight, @BreakMinutes, @GraceMinutes, @Note, @CallerUserId);

    IF @EffectiveTo IS NOT NULL AND @bStart IS NOT NULL
        INSERT INTO attendance.SHIFT_HOURS (ShiftId, EffectiveFrom, StartTime, EndTime, CrossesMidnight, BreakMinutes, GraceMinutes, Note, CreatedByUserId)
        VALUES (@ShiftId, @BackFrom, @bStart, @bEnd, @bCross, @bBreak, @bGrace,
                CONCAT(N'Back to the hours before the change of ', CONVERT(CHAR(10), @EffectiveFrom, 103)), @CallerUserId);

    EXEC attendance.usp_Shift_TidyHours @ShiftId = @ShiftId;

    EXEC attendance.usp_Shift_SyncCurrent @ShiftId = @ShiftId, @Quiet = 1;
    COMMIT TRAN;

    DECLARE @Days INT = 0;
    EXEC attendance.usp_Shift_RederiveDays @ShiftId = @ShiftId, @From = @EffectiveFrom, @To = @EffectiveTo, @Days = @Days OUTPUT;
    IF @Quiet = 0 SELECT @Days AS DaysRederived;
    RETURN 0;
END;
GO

/* The history of one shift, oldest first: each row with the last day it applies (the day before the next row). */
CREATE OR ALTER PROCEDURE attendance.usp_Shift_GetHours
    @ShiftId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    SELECT h.ShiftHoursId, h.ShiftId, h.EffectiveFrom,
           DATEADD(DAY, -1, LEAD(h.EffectiveFrom) OVER (ORDER BY h.EffectiveFrom)) AS EffectiveTo,
           h.StartTime, h.EndTime, h.CrossesMidnight, h.BreakMinutes, h.GraceMinutes,
           DATEDIFF(MINUTE, h.StartTime, h.EndTime) + CASE WHEN h.CrossesMidnight = 1 THEN 1440 ELSE 0 END - h.BreakMinutes AS StandardMinutes,
           h.Note, u.Username AS CreatedBy, h.CreatedAtUtc,
           CAST(CASE WHEN ROW_NUMBER() OVER (ORDER BY h.EffectiveFrom) = 1 THEN 1 ELSE 0 END AS BIT) AS IsFirst,
           CAST(CASE WHEN h.EffectiveFrom <= @Today
                      AND ISNULL(LEAD(h.EffectiveFrom) OVER (ORDER BY h.EffectiveFrom), '9999-12-31') > @Today THEN 1 ELSE 0 END AS BIT) AS IsCurrent
    FROM attendance.SHIFT_HOURS h
    LEFT JOIN security.[USER] u ON u.UserId = h.CreatedByUserId
    WHERE h.ShiftId = @ShiftId
    ORDER BY h.EffectiveFrom;
END;
GO

/* Takes ONE change back: the hours before it then run on until the next change. The first row of a shift stays (a
   shift always has hours). The same rule for paid days, and the days it covered are derived again. */
CREATE OR ALTER PROCEDURE attendance.usp_Shift_DeleteHours
    @ShiftHoursId INT,
    @CallerUserId INT = NULL,
    @Quiet        BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ShiftId INT, @From DATE;
    SELECT @ShiftId = ShiftId, @From = EffectiveFrom FROM attendance.SHIFT_HOURS WHERE ShiftHoursId = @ShiftHoursId;
    IF @ShiftId IS NULL BEGIN RAISERROR('That change of hours was not found (it may already be gone).', 16, 1); RETURN 1; END
    IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_HOURS WHERE ShiftId = @ShiftId AND EffectiveFrom < @From)
    BEGIN RAISERROR('These are the shift''s first hours: they cannot be removed. Change them from a date instead.', 16, 1); RETURN 1; END

    DECLARE @Next DATE = (SELECT MIN(EffectiveFrom) FROM attendance.SHIFT_HOURS WHERE ShiftId = @ShiftId AND EffectiveFrom > @From);
    DECLARE @To DATE = DATEADD(DAY, -1, @Next);
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @PaidDay DATE = (
        SELECT MAX(sa.WorkDate)
        FROM attendance.SHIFT_ASSIGNMENT sa
        WHERE sa.ShiftId = @ShiftId AND sa.WorkDate >= @From AND sa.WorkDate <= @Today
          AND (@To IS NULL OR sa.WorkDate <= @To)
          AND payroll.fn_IsPeriodPaid(sa.EmployeeId, sa.WorkDate) = 1);
    IF @PaidDay IS NOT NULL
    BEGIN
        DECLARE @PaidMsg NVARCHAR(400) = CONCAT(N'Days under these hours up to ', CONVERT(CHAR(10), @PaidDay, 23),
            N' are already paid, and a paid day keeps the hours it was paid on. This change cannot be taken back.');
        RAISERROR('%s', 16, 1, @PaidMsg);
        RETURN 1;
    END

    BEGIN TRAN;
    DELETE FROM attendance.SHIFT_HOURS WHERE ShiftHoursId = @ShiftHoursId;
    EXEC attendance.usp_Shift_TidyHours @ShiftId = @ShiftId;      -- e.g. the "back to the hours before" row that came with it
    EXEC attendance.usp_Shift_SyncCurrent @ShiftId = @ShiftId, @Quiet = 1;
    COMMIT TRAN;

    DECLARE @Days INT = 0;
    EXEC attendance.usp_Shift_RederiveDays @ShiftId = @ShiftId, @From = @From, @To = @To, @Days = @Days OUTPUT;
    IF @Quiet = 0 SELECT @Days AS DaysRederived;
    RETURN 0;
END;
GO

/* A new shift starts its history with the hours it is created with. */
CREATE OR ALTER PROCEDURE attendance.usp_Shift_Create
    @Name NVARCHAR(50), @StartTime TIME, @EndTime TIME,
    @GraceMinutes INT = NULL, @CrossesMidnight BIT = 0, @BreakMinutes INT = 0,
    @CallerUserId INT = NULL
AS BEGIN SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @StartTime = @EndTime
    BEGIN RAISERROR('A shift cannot start and end at the same time.', 16, 1); RETURN 1; END
    IF @EndTime < @StartTime AND ISNULL(@CrossesMidnight, 0) = 0
    BEGIN RAISERROR('This shift ends before it starts. Tick ''crosses midnight'' if it is an overnight shift.', 16, 1); RETURN 1; END
    IF @GraceMinutes IS NOT NULL AND @GraceMinutes < 0
    BEGIN RAISERROR('GraceMinutes must be zero or more, or empty to use the AttendanceToleranceMinutes setting.', 16, 1); RETURN 1; END
    BEGIN TRAN;
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes)
    VALUES (@Name, @StartTime, @EndTime, @GraceMinutes, ISNULL(@CrossesMidnight, 0), ISNULL(@BreakMinutes, 0));
    DECLARE @Id INT = CAST(SCOPE_IDENTITY() AS INT);
    INSERT INTO attendance.SHIFT_HOURS (ShiftId, EffectiveFrom, StartTime, EndTime, CrossesMidnight, BreakMinutes, GraceMinutes, Note, CreatedByUserId)
    VALUES (@Id, '2000-01-01', @StartTime, @EndTime, ISNULL(@CrossesMidnight, 0), ISNULL(@BreakMinutes, 0), @GraceMinutes,
            N'The hours the shift was created with', @CallerUserId);
    COMMIT TRAN;
    SELECT @Id AS ShiftId; END;
GO

/* Script 100 FROZE the hours of a shift once it had been worked. They are dated now, so they can change:
     - the name and Active change as before;
     - hours that differ from the present ones go through usp_Shift_SetHours from @EffectiveFrom (today when none is
       given), until @EffectiveTo when one is given. A shift never rostered on a past day and never worked has no
       day to protect: with no date given its present hours are simply corrected in place. */
CREATE OR ALTER PROCEDURE attendance.usp_Shift_Update
    @ShiftId INT, @Name NVARCHAR(50), @StartTime TIME, @EndTime TIME,
    @GraceMinutes INT = NULL, @CrossesMidnight BIT, @BreakMinutes INT, @IsActive BIT,
    @EffectiveFrom DATE = NULL, @EffectiveTo DATE = NULL, @Note NVARCHAR(200) = NULL, @CallerUserId INT = NULL
AS BEGIN SET NOCOUNT ON; SET XACT_ABORT ON;
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

    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @HoursDiffer BIT = CASE WHEN @OldStart <> @StartTime OR @OldEnd <> @EndTime OR ISNULL(@OldBreak, 0) <> ISNULL(@BreakMinutes, 0)
                                         OR ISNULL(@OldCross, 0) <> ISNULL(@CrossesMidnight, 0) OR ISNULL(@OldGrace, -1) <> ISNULL(@GraceMinutes, -1)
                                    THEN 1 ELSE 0 END;
    DECLARE @rc INT = 0;

    IF @EffectiveFrom IS NOT NULL OR @EffectiveTo IS NOT NULL OR @HoursDiffer = 1
    BEGIN
        DECLARE @Used BIT = CASE WHEN EXISTS (
            SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
            WHERE sa.ShiftId = @ShiftId
              AND (sa.WorkDate < @Today
                   OR EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = sa.EmployeeId AND a.WorkDate = sa.WorkDate)))
            OR EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.RelatedShiftId = @ShiftId)
            THEN 1 ELSE 0 END;

        IF @EffectiveFrom IS NULL AND @EffectiveTo IS NULL AND @Used = 0
           AND (SELECT COUNT(*) FROM attendance.SHIFT_HOURS WHERE ShiftId = @ShiftId) <= 1
        BEGIN
            /* never worked, one row of history: the hours are corrected where they stand */
            UPDATE attendance.SHIFT_HOURS
            SET StartTime = @StartTime, EndTime = @EndTime, CrossesMidnight = ISNULL(@CrossesMidnight, 0),
                BreakMinutes = ISNULL(@BreakMinutes, 0), GraceMinutes = @GraceMinutes
            WHERE ShiftId = @ShiftId;
            IF @@ROWCOUNT = 0
                INSERT INTO attendance.SHIFT_HOURS (ShiftId, EffectiveFrom, StartTime, EndTime, CrossesMidnight, BreakMinutes, GraceMinutes, Note, CreatedByUserId)
                VALUES (@ShiftId, '2000-01-01', @StartTime, @EndTime, ISNULL(@CrossesMidnight, 0), ISNULL(@BreakMinutes, 0), @GraceMinutes,
                        N'The hours the shift was created with', @CallerUserId);
            EXEC attendance.usp_Shift_SyncCurrent @ShiftId = @ShiftId, @Quiet = 1;
        END
        ELSE
        BEGIN
            DECLARE @From DATE = ISNULL(@EffectiveFrom, @Today);
            EXEC @rc = attendance.usp_Shift_SetHours @ShiftId = @ShiftId, @EffectiveFrom = @From, @EffectiveTo = @EffectiveTo,
                 @StartTime = @StartTime, @EndTime = @EndTime, @CrossesMidnight = @CrossesMidnight, @BreakMinutes = @BreakMinutes,
                 @GraceMinutes = @GraceMinutes, @Note = @Note, @CallerUserId = @CallerUserId, @Quiet = 1;
            IF ISNULL(@rc, 0) <> 0 RETURN 1;
        END
    END

    UPDATE attendance.SHIFT SET Name = @Name, IsActive = @IsActive WHERE ShiftId = @ShiftId;
    RETURN 0;
END;
GO

/* ---------------------------------------------------------------- 4b. the leave an exit permission costs is a share of that day's own shift (script 100's two bodies) */
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
    /* script 117: a share of THAT day - the minutes over the length of the shift the day was measured against */
    SELECT @AttId = AttendanceId, @Days = core.fn_MinutesToLeaveDaysOn(ExitLeaveMinutes, StandardMinutes)
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
    /* script 117: a share of THAT day - the minutes over the length of the shift the day was measured against */
    SELECT @AttId = AttendanceId, @Unpaid = ExitUnpaidDays, @NewDays = core.fn_MinutesToLeaveDaysOn(ExitLeaveMinutes, StandardMinutes)
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

/* ---------------------------------------------------------------- 5. the machine writer (script 100's body; the changes are marked 'script 117') */
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
    /* script 117: the shift's hours IN FORCE ON THAT DAY (attendance.SHIFT_HOURS), not the hours it has now */
    OUTER APPLY attendance.fn_ShiftHoursOn(sa.ShiftId, sa.WorkDate) s
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

    /* script 117: A DAY WITHOUT A ROSTERED SHIFT IS MEASURED AGAINST THE SHIFT ITS FIRST PUNCH FITS - the active shift
       whose start (its hours in force that day) is nearest to the first in. That shift gives the day its LENGTH and
       its break, nothing more: with no roster there is still no late or early rule. No punch, or no active shift:
       the default day (core.fn_StandardDayMinutes - a shift's length too, no longer a setting). */
    DECLARE @RelatedShiftId INT;
    IF @IsRest = 0 AND @ShiftStart IS NULL
        SELECT @RelatedShiftId = rs.ShiftId, @Standard = rs.StandardMinutes, @Break = rs.BreakMinutes
        FROM attendance.fn_ShiftByPunch(@WorkDate, @FirstIn) rs;

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
             ExitPermissionId, [Status], [Source], DeviceId, BranchId, HasAnomaly, IsManual, ProcessedUtc, RelatedShiftId)
        SELECT @EmployeeId, @Sa, @WorkDate, @FirstIn, @LastOut, @Pairs, @Gross, @Gap, r.BreakApplied,
               r.WorkedMinutes, r.StandardMinutes, r.DayFraction, r.IsFullDay, r.ShortfallMinutes, r.LateMinutes, r.LateDeductMinutes, r.EarlyExitMinutes,
               r.EarlyDeductMinutes, r.CoveredMinutes, r.OvertimeMinutes, r.ExitActualMinutes, r.ExitApprovedMinutes, r.ExitVarianceMinutes, @ExitLeave,
               @PermissionId, r.[Status], ISNULL(@SourceName, 'Device'), @DeviceId, @BranchId, @HasAnomaly, 0, SYSUTCDATETIME(), @RelatedShiftId
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
            a.DeviceId = @DeviceId, a.BranchId = @BranchId, a.HasAnomaly = @HasAnomaly, a.ProcessedUtc = SYSUTCDATETIME(),
            a.RelatedShiftId = @RelatedShiftId
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

/* ---------------------------------------------------------------- 6. the manual writer (script 100's body; the changes are marked 'script 117') */
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
    /* script 117: the shift's hours IN FORCE ON THAT DAY (attendance.SHIFT_HOURS), not the hours it has now */
    OUTER APPLY attendance.fn_ShiftHoursOn(sa.ShiftId, sa.WorkDate) s
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
    /* script 117: like the machine writer, a day without a rostered shift takes its length and break from the shift
       the first in fits (the default day when there is none) */
    IF @IsRest = 0 AND @ShiftStart IS NULL
        SELECT @Standard = rs.StandardMinutes, @Break = rs.BreakMinutes
        FROM attendance.fn_ShiftByPunch(@WorkDate, @FirstInUtc) rs;

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

/* ---------------------------------------------------------------- 7. the overtime form's context reads that day's hours (script 100's body) */
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
           sh.Name AS ShiftName, shh.StartTime, shh.EndTime,          -- script 117: the hours in force that day
           CAST(CASE WHEN sa.ShiftAssignmentId IS NULL OR sa.IsRestDay=1
                     THEN 1 ELSE 0 END AS BIT) AS IsRestDayOrUnrostered
    FROM @Submitted s
    LEFT JOIN attendance.SHIFT_ASSIGNMENT sa
           ON sa.EmployeeId=@EmployeeId AND sa.WorkDate=@WorkDate
    LEFT JOIN attendance.SHIFT sh ON sh.ShiftId=sa.ShiftId
    OUTER APPLY attendance.fn_ShiftHoursOn(sa.ShiftId, sa.WorkDate) shh;
END;
GO

/* ---------------------------------------------------------------- 8. the roster rows of a period carry the hours in force on each day (script 87's body) */
CREATE OR ALTER PROCEDURE attendance.usp_ShiftAssignment_GetByDateRange
    @FromDate DATE, @ToDate DATE, @EmployeeId INT = NULL,
    @BranchId INT = NULL,               -- script 85 (D7): the rows of ONE branch — by the branch each employee belonged to ON the work date
    @CallerUserId INT = NULL      -- script 87 (BUG-04): the signed-in user; without EMP_VIEW_ALL they see their own rows and the branches they manage
AS BEGIN SET NOCOUNT ON;
    /* script 87 (BUG-04): what this caller may see. NULL caller = the system itself (jobs, other procedures): everything. */
    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    SELECT sa.ShiftAssignmentId, sa.EmployeeId, e.FullName, sa.ShiftId, s.Name AS ShiftName,
           ISNULL(h.StartTime, s.StartTime) AS StartTime, ISNULL(h.EndTime, s.EndTime) AS EndTime,   -- script 117: the hours in force that day
           sa.WorkDate, sa.IsRestDay,
           x.BranchId                   -- script 85 (D7): the employee's branch that day (appended: existing readers keep their columns)
    FROM attendance.SHIFT_ASSIGNMENT sa
    JOIN hr.EMPLOYEE e           ON e.EmployeeId = sa.EmployeeId
    LEFT JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
    OUTER APPLY attendance.fn_ShiftHoursOn(sa.ShiftId, sa.WorkDate) h
    CROSS APPLY (SELECT hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate) AS BranchId) x
    WHERE sa.WorkDate BETWEEN @FromDate AND @ToDate
      AND (@EmployeeId IS NULL OR sa.EmployeeId = @EmployeeId)
      AND (@BranchId IS NULL OR x.BranchId = @BranchId)
      AND (@SeesAll = 1 OR sa.EmployeeId = @CallerEmp OR EXISTS (SELECT 1 FROM hr.BRANCH mb WHERE mb.ManagerEmployeeId = @CallerEmp AND mb.BranchId = x.BranchId))
    ORDER BY sa.WorkDate, e.FullName; END;
GO

/* ---------------------------------------------------------------- 9. payroll: an hour of overtime is the day rate over the hours of that day's shift (script 103's body) */
CREATE OR ALTER PROCEDURE payroll.usp_PayrollRun_Generate
    @PayrollRunId INT, @ActedByUserId INT,
    @AsOfDate DATE = NULL      -- script 81: the clock. NULL = today in Beirut; a caller passes a date only to test the rule
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    DECLARE @Status VARCHAR(12), @Start DATE, @End DATE, @Primary CHAR(3), @Period CHAR(7), @RunType VARCHAR(12);
    SELECT @Status=[Status], @Start=PeriodStart, @End=PeriodEnd, @Primary=PrimaryCurrency, @Period=PeriodYearMonth, @RunType=RunType
    FROM payroll.PAYROLL_RUN WHERE PayrollRunId=@PayrollRunId;
    IF @Status IS NULL BEGIN RAISERROR('No such payroll run.',16,1); RETURN 1; END
    IF @Status NOT IN ('Draft','Review')
    BEGIN RAISERROR('This run is locked. A locked run is never regenerated - corrections go to the next period.',16,1); RETURN 1; END
    IF @RunType = 'Supplemental'
    BEGIN RAISERROR('A supplemental run pays its signed adjustments only - it has its own generator (usp_PayrollRun_GenerateSupplemental).',16,1); RETURN 1; END

    /* QA3 ATT-11: COMPLETED days only - up to yesterday in Beirut, never past the period's end. Today and later days are
       paid as scheduled: their shifts are still running. */
    DECLARE @Today DATE = ISNULL(@AsOfDate, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));
    DECLARE @UpTo  DATE = CASE WHEN DATEADD(DAY, -1, @Today) < @End THEN DATEADD(DAY, -1, @Today) ELSE @End END;

    /* QA3 PAY-4: the readiness gate of Create, asked again for the days that are complete now */
    DECLARE @rc INT;
    EXEC @rc = payroll.usp_PayrollRun_AssertReady @PeriodYearMonth = @Period, @AsOfDate = @Today;
    IF @rc <> 0 RETURN 1;

    /* QA3 PAY-10: the types payroll writes are found by their SYSTEM CODE - a rename on the Component types page no longer
       silently drops a line */
    SELECT SystemCode AS Code, ComponentTypeId, Name, Category, [Sign] INTO #CT FROM hr.COMPONENT_TYPE WHERE SystemCode IS NOT NULL;
    DECLARE @MissingCode VARCHAR(30) = (
        SELECT TOP 1 v.Code FROM (VALUES ('BASIC'),('OVERTIME'),('HOLIDAY_WORK'),('LATE'),('UNPAID_LEAVE'),('ABSENCE'),('TIPS'),('EXPENSE'),
                                         ('ADVANCE'),('UNUSED_LEAVE'),('INDEMNITY'),('LEAVE_PAYOUT'),('LEAVE_DEDUCTION'),
                                         ('NSSF_EMPLOYEE'),('NSSF_EMPLOYER'),('INCOME_TAX')) v(Code)
        WHERE NOT EXISTS (SELECT 1 FROM #CT c WHERE c.Code = v.Code) ORDER BY v.Code);
    IF @MissingCode IS NOT NULL
    BEGIN
        RAISERROR('Payroll needs the system component type %s and it is missing. Restore it on the Component types page (or re-apply script 103), then generate.',16,1,@MissingCode);
        RETURN 1;
    END

    DECLARE @DaysPerMonth DECIMAL(6,2) = ISNULL(NULLIF(TRY_CAST((SELECT SettingValue FROM core.SETTING
        WHERE SettingKey='StandardWorkingDaysPerMonth') AS DECIMAL(6,2)),0),26);
    /* script 117: THE HOURS OF A DAY COME FROM THE SHIFTS, not from a setting (StandardWorkDayHours is gone). An hour of
       overtime is the day rate over the hours of THAT day's shift (payroll.fn_DayStandardMinutes, section E); this
       figure - the default day - is only what #Rate.HourRate shows when no day is in question. */
    DECLARE @HoursPerDay DECIMAL(6,2) = CAST(core.fn_StandardDayMinutes() / 60.0 AS DECIMAL(6,2));
    DECLARE @Ceiling DECIMAL(18,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING
        WHERE SettingKey='NssfCeilingUsd') AS DECIMAL(18,2)),999999);
    DECLARE @FamilyDed DECIMAL(18,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING
        WHERE SettingKey='TaxFamilyDeductionAnnualUsd') AS DECIMAL(18,2)),0);
    DECLARE @HolidayRate DECIMAL(6,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey='HolidayWorkRate') AS DECIMAL(6,2)), 2.0);
    DECLARE @RateType VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey='PayrollRateType'),'Official');
    DECLARE @DaysInMonth INT = DAY(@End);
    DECLARE @YearStart DATE = DATEFROMPARTS(YEAR(@Start), 1, 1);
    /* QA3 PAY-9: ONE tax table per month - the version in force on the period's last day */
    DECLARE @TaxFrom DATE = (SELECT MAX(EffectiveFrom) FROM hr.TAX_BRACKET
                             WHERE EffectiveFrom <= @End AND (EffectiveTo IS NULL OR EffectiveTo >= @End));

    BEGIN TRAN;

    /* QA3 REL-11: while the run is a Draft its rates are re-read as of the period end (a rate corrected or a currency first
       used after Create is picked up); from Review on the snapshot is frozen (a currency missing from it is added below). */
    IF @Status = 'Draft'
    BEGIN
        DELETE FROM payroll.PAYROLL_RUN_RATE WHERE PayrollRunId=@PayrollRunId;
        INSERT INTO payroll.PAYROLL_RUN_RATE (PayrollRunId,FromCurrency,ToCurrency,Rate,RateType,SourceEffectiveDate)
        SELECT @PayrollRunId, c.CurrencyCode, @Primary, x.Rate, x.RateType, x.EffectiveDate
        FROM core.CURRENCY c
        CROSS APPLY (SELECT TOP 1 CAST(CASE WHEN er.FromCurrency=c.CurrencyCode THEN er.Rate ELSE 1.0/er.Rate END AS DECIMAL(28,12)) AS Rate,
                            er.RateType, er.EffectiveDate
                     FROM core.EXCHANGE_RATE er
                     WHERE ((er.FromCurrency=c.CurrencyCode AND er.ToCurrency=@Primary) OR (er.FromCurrency=@Primary AND er.ToCurrency=c.CurrencyCode))
                       AND er.RateType=@RateType AND er.EffectiveDate <= @End AND er.Rate > 0
                     ORDER BY er.EffectiveDate DESC, er.ExchangeRateId DESC) x
        WHERE c.CurrencyCode <> @Primary;
    END

    DELETE FROM payroll.PAYSLIP WHERE PayrollRunId=@PayrollRunId;   -- lines and fingerprints cascade

    /* -- payslip shells (QA3 REL-5 soft-deleted with activity, PAY-2 settlement-only leavers); the branch is the branch
          OF THE PERIOD - on the employee's last day in it (QA3 PAY-15); no position is no reason to drop a payslip -- */
    INSERT INTO payroll.PAYSLIP
        (PayrollRunId,EmployeeId,EmployeeName,PositionTitle,BranchName,NssfNumber,HireDate)
    SELECT @PayrollRunId, e.EmployeeId, e.FullName, p.Title, b.Name, e.NssfNumber, e.HireDate
    FROM payroll.fn_RunEmployees(@PayrollRunId) re
    JOIN hr.EMPLOYEE e ON e.EmployeeId=re.EmployeeId
    LEFT JOIN hr.[POSITION] p ON p.PositionId=e.PositionId
    LEFT JOIN hr.BRANCH b ON b.BranchId = hr.fn_EmployeeBranchOn(e.EmployeeId,
                               CASE WHEN e.TerminationDate IS NOT NULL AND e.TerminationDate < @End THEN e.TerminationDate ELSE @End END);

    /* the employment inside the period (QA3 REL-1): EmpFrom..EmpTo; attendance counts EmpFrom..AttTo (completed days).
       A settlement-only payslip has EmpTo < EmpFrom: nothing of the month is paid or deducted on it. */
    SELECT ps.PayslipId, ps.EmployeeId, e.HireDate, e.TerminationDate,
           CASE WHEN e.HireDate > @Start THEN e.HireDate ELSE @Start END AS EmpFrom,
           CASE WHEN e.TerminationDate IS NOT NULL AND e.TerminationDate < @End THEN e.TerminationDate ELSE @End END AS EmpTo,
           CASE WHEN e.TerminationDate IS NOT NULL AND e.TerminationDate < @UpTo THEN e.TerminationDate ELSE @UpTo END AS AttTo,
           /* QA3 PAY-13: WHOLE years of service at the period start (DATEDIFF(YEAR) counted calendar boundaries) */
           (DATEDIFF(MONTH, e.HireDate, @Start) - CASE WHEN DAY(e.HireDate) > DAY(@Start) THEN 1 ELSE 0 END) / 12 AS ServiceYears
    INTO #Emp
    FROM payroll.PAYSLIP ps
    JOIN hr.EMPLOYEE e ON e.EmployeeId=ps.EmployeeId
    WHERE ps.PayrollRunId=@PayrollRunId;

    /* -- A. standing components, prorated by the days EACH ONE was in force (script 86, QA2-20) --
          QA3 PAY-6 / REL-2: a row is SUPERSEDED from the day a later-starting row of the same employee, type and currency
          starts - so a raise added without closing the old row (the retired raw path) pays 15/30 + 15/30, never both in
          full. Two rows starting the same day: the later one (higher id) stands. -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(sc.Amount * w.CoverDays / @DaysInMonth, 2), sc.CurrencyCode,
           'Salary', sc.SalaryComponentId, NULL, NULL,
           CASE WHEN w.CoverDays < @DaysInMonth
                THEN CONCAT(N'Prorated ', CAST(w.CoverDays AS INT), N'/', @DaysInMonth, N' of the month (', FORMAT(CAST(w.CoverDays AS DECIMAL(9,4)) / @DaysInMonth, '0.00'),
                            N'): ', CONVERT(NVARCHAR(10), w.FromD, 23), N' to ', CONVERT(NVARCHAR(10), w.ToD, 23)) END,
           10
    FROM #Emp x
    JOIN hr.SALARY_COMPONENT sc ON sc.EmployeeId=x.EmployeeId
    JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId=sc.ComponentTypeId AND ct.IsStanding=1
    OUTER APPLY (SELECT MIN(s2.EffectiveFrom) AS NextFrom
                 FROM hr.SALARY_COMPONENT s2
                 WHERE s2.EmployeeId=sc.EmployeeId AND s2.ComponentTypeId=sc.ComponentTypeId AND s2.CurrencyCode=sc.CurrencyCode
                   AND (s2.EffectiveFrom > sc.EffectiveFrom OR (s2.EffectiveFrom = sc.EffectiveFrom AND s2.SalaryComponentId > sc.SalaryComponentId))) nx
    CROSS APPLY (SELECT FromD = (SELECT MAX(v) FROM (VALUES (@Start), (x.HireDate), (sc.EffectiveFrom)) f(v)),
                        ToD   = (SELECT MIN(v) FROM (VALUES (@End), (ISNULL(x.TerminationDate, @End)), (ISNULL(sc.EffectiveTo, @End)),
                                                            (ISNULL(DATEADD(DAY, -1, nx.NextFrom), @End))) t(v))) r0
    CROSS APPLY (SELECT r0.FromD, r0.ToD, CAST(DATEDIFF(DAY, r0.FromD, r0.ToD) + 1 AS DECIMAL(9,4)) AS CoverDays) w
    WHERE sc.EffectiveFrom <= @End AND (sc.EffectiveTo IS NULL OR sc.EffectiveTo >= @Start)
      AND w.CoverDays > 0;

    /* day and hour rates, per employee: ONE basic row (code BASIC) - the one in force on the employee's last day in the
       period (script 86); for a settlement-only payslip, the one in force on the termination date */
    SELECT x.PayslipId, x.EmployeeId, sc.CurrencyCode,
           CAST(sc.Amount / @DaysPerMonth AS DECIMAL(18,4)) AS DayRate,
           CAST(sc.Amount / @DaysPerMonth / @HoursPerDay AS DECIMAL(18,4)) AS HourRate
    INTO #Rate
    FROM #Emp x
    CROSS APPLY (SELECT TOP 1 s2.Amount, s2.CurrencyCode
                 FROM hr.SALARY_COMPONENT s2
                 JOIN #CT c ON c.ComponentTypeId=s2.ComponentTypeId AND c.Code='BASIC'
                 WHERE s2.EmployeeId=x.EmployeeId AND s2.EffectiveFrom <= x.EmpTo
                   AND (s2.EffectiveTo IS NULL OR s2.EffectiveTo >= CASE WHEN x.EmpTo < @Start THEN x.EmpTo ELSE @Start END)
                 ORDER BY CASE WHEN s2.EffectiveTo IS NULL OR s2.EffectiveTo >= x.EmpTo THEN 0 ELSE 1 END,
                          s2.EffectiveFrom DESC, s2.SalaryComponentId DESC) sc;

    /* -- B. unpaid leave: what the APPROVED leave costs on the days inside the period and the employment, day by day
          as script 99 allocates it (hr.fn_LeaveRequestDays: the working days of FromDate..ApprovedToDate - a partial
          approval keeps the first days, a fractional one costs its fraction on the last day, a half-day request 0.5,
          calendar days for a fixed-entitlement type), unpaid by the type AS APPROVED (QA3 PAY-8: ISNULL(PaidSnapshot,
          IsPaid) - flipping the type later never re-prices an approved leave) -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(d.DaysInPeriod * r.DayRate, 2), r.CurrencyCode,
           'Leave', d.LeaveRequestId, d.DaysInPeriod, r.DayRate,
           CONCAT(d.DaysInPeriod, N' unpaid day(s)'), 20
    FROM #Rate r
    JOIN #Emp x ON x.PayslipId=r.PayslipId
    CROSS APPLY (
        SELECT lr.LeaveRequestId,
               CAST((SELECT ISNULL(SUM(ld.Part), 0) FROM hr.fn_LeaveRequestDays(lr.LeaveRequestId, 0) ld
                     WHERE ld.WorkDate BETWEEN w.F AND w.T) AS DECIMAL(6,2)) AS DaysInPeriod
        FROM workflow.LEAVE_REQUEST lr
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=lr.RequestInstanceId AND ri.[Status]='Approved'
        JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId=lr.LeaveTypeId
        CROSS APPLY (SELECT CASE WHEN lr.FromDate > x.EmpFrom THEN lr.FromDate ELSE x.EmpFrom END AS F,
                            CASE WHEN ISNULL(lr.ApprovedToDate, lr.ToDate) < x.EmpTo THEN ISNULL(lr.ApprovedToDate, lr.ToDate) ELSE x.EmpTo END AS T) w
        WHERE lr.EmployeeId=r.EmployeeId AND ISNULL(lr.PaidSnapshot, lt.IsPaid)=0 AND w.F <= w.T
    ) d
    JOIN #CT ct ON ct.Code='UNPAID_LEAVE'
    WHERE d.DaysInPeriod > 0;

    /* -- C. sick pay tiers (QA3 LEV-16 / LEV-13 / PAY-13): the counted days of the approved leaves of every TIERED type (a
          type with LEAVE_PAY_TIER rows - keyed on its id, not on the name 'Sick') are numbered DAY BY DAY across the year;
          a day inside the full-pay band costs nothing, inside the half-pay band half a day, beyond it a whole day. Each
          period pays for its own days, so a leave crossing a month end is split by day. Tier = whole years of service. -- */
    ;WITH sreq AS (
        SELECT lr.LeaveRequestId, lr.EmployeeId, lr.LeaveTypeId, lr.HalfDay,
               CASE WHEN lr.FromDate > @YearStart THEN lr.FromDate ELSE @YearStart END AS F,
               CASE WHEN ISNULL(lr.ApprovedToDate, lr.ToDate) < x.EmpTo THEN ISNULL(lr.ApprovedToDate, lr.ToDate) ELSE x.EmpTo END AS T
        FROM workflow.LEAVE_REQUEST lr
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=lr.RequestInstanceId AND ri.[Status]='Approved'
        JOIN #Emp x ON x.EmployeeId=lr.EmployeeId
        WHERE EXISTS (SELECT 1 FROM hr.LEAVE_PAY_TIER pt WHERE pt.LeaveTypeId=lr.LeaveTypeId)
          AND lr.FromDate <= @End AND ISNULL(lr.ApprovedToDate, lr.ToDate) >= @YearStart
    ), sday AS (
        /* what each day of the approved leave costs, as script 99 allocates it (half day 0.5, a fractional last day) */
        SELECT s.LeaveRequestId, s.EmployeeId, s.LeaveTypeId, ld.WorkDate, CAST(ld.Part AS DECIMAL(9,2)) AS U
        FROM sreq s
        CROSS APPLY hr.fn_LeaveRequestDays(s.LeaveRequestId, 0) ld
        WHERE s.F <= s.T AND ld.WorkDate BETWEEN s.F AND s.T AND ld.Part > 0
    ), numbered AS (
        SELECT d.LeaveRequestId, d.EmployeeId, d.LeaveTypeId, d.WorkDate, d.U,
               SUM(d.U) OVER (PARTITION BY d.EmployeeId, d.LeaveTypeId ORDER BY d.WorkDate, d.LeaveRequestId ROWS UNBOUNDED PRECEDING) - d.U AS Before
        FROM sday d
    ), costed AS (
        SELECT n.EmployeeId, n.LeaveRequestId,
               /* half-pay band [Full, Full+Half): 0.5 a day; beyond it: 1.0 a day - the overlap of [Before, Before+U) with each */
               0.5 * (CASE WHEN (CASE WHEN n.Before + n.U < t.FullPlusHalf THEN n.Before + n.U ELSE t.FullPlusHalf END)
                                - (CASE WHEN n.Before > t.FullPayDays THEN n.Before ELSE t.FullPayDays END) > 0
                           THEN (CASE WHEN n.Before + n.U < t.FullPlusHalf THEN n.Before + n.U ELSE t.FullPlusHalf END)
                                - (CASE WHEN n.Before > t.FullPayDays THEN n.Before ELSE t.FullPayDays END) ELSE 0 END)
             + 1.0 * (CASE WHEN n.Before + n.U - (CASE WHEN n.Before > t.FullPlusHalf THEN n.Before ELSE t.FullPlusHalf END) > 0
                           THEN n.Before + n.U - (CASE WHEN n.Before > t.FullPlusHalf THEN n.Before ELSE t.FullPlusHalf END) ELSE 0 END) AS CostDays
        FROM numbered n
        JOIN #Emp x ON x.EmployeeId=n.EmployeeId
        CROSS APPLY (SELECT TOP 1 pt.FullPayDays, pt.FullPayDays + pt.HalfPayDays AS FullPlusHalf
                     FROM hr.LEAVE_PAY_TIER pt
                     WHERE pt.LeaveTypeId=n.LeaveTypeId AND pt.MinServiceYears <= x.ServiceYears
                     ORDER BY pt.MinServiceYears DESC) t
        WHERE n.WorkDate BETWEEN @Start AND @End
    )
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(c.CostDays * r.DayRate, 2), r.CurrencyCode,
           'Leave', c.LeaveRequestId, c.CostDays, r.DayRate,
           CONCAT(N'Sick pay tiers: ',FORMAT(c.CostDays,'0.##'),N' day(s) unpaid portion'), 21
    FROM (SELECT EmployeeId, LeaveRequestId, CAST(SUM(CostDays) AS DECIMAL(6,2)) AS CostDays FROM costed GROUP BY EmployeeId, LeaveRequestId) c
    JOIN #Rate r ON r.EmployeeId=c.EmployeeId
    JOIN #CT ct ON ct.Code='ABSENCE'
    WHERE c.CostDays > 0;

    /* -- D. short days (script 78 BUG-06, script 86 QA2-22): a worked or absent day on a rostered shift of an approved
          roster month, not covered by an approved full-day leave (ISNULL(ApprovedToDate, ToDate), QA3 PAY-8), from the
          first day employed to the last COMPLETED day employed (QA3 REL-1, ATT-11) - payroll.fn_ShortDays (QA3 REL-15) -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(sh.MissingDays * r.DayRate, 2), r.CurrencyCode,
           'Attendance', NULL, sh.MissingDays, r.DayRate,
           CONCAT(FORMAT(sh.MissingDays,'0.##'),N' day(s) short across ',sh.DaysAffected,N' date(s)'), 22
    FROM #Rate r
    /* the same function the attendance summaries read (QA3 REL-15): the completed days of the period; the employment
       window is the function's own (HireDate..TerminationDate) */
    JOIN (
        SELECT sd.EmployeeId, sd.MissingDays, sd.DaysAffected
        FROM payroll.fn_ShortDays(@Start, @UpTo) sd
        WHERE sd.MissingDays > 0.0005
    ) sh ON sh.EmployeeId=r.EmployeeId
    JOIN #CT ct ON ct.Code='LATE';

    /* -- D2. HOLIDAY WORK (script 86, D1): worked minutes on a public holiday x (day rate / the day's standard) x
          (HolidayWorkRate - 1), inside the employment and the completed days (QA3 REL-1) -- */
    IF @HolidayRate > 1
        INSERT INTO payroll.PAYSLIP_LINE
            (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
             SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
        SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
               ROUND(hw.PaidShare * r.DayRate * (@HolidayRate - 1), 2), r.CurrencyCode,
               'Attendance', NULL, hw.Minutes, r.DayRate,
               CONCAT(hw.Minutes, N' min worked on ', hw.DaysWorked, N' public holiday(s), premium ', FORMAT(@HolidayRate - 1, '0.##'), N' ', NCHAR(215), N' the day rate'), 23
        FROM #Rate r
        JOIN (SELECT a.EmployeeId, SUM(a.WorkedMinutes) AS Minutes, COUNT(*) AS DaysWorked,
                     /* script 117: a holiday worked on a day with no standard of its own (a rest day) is a share of the
                        employee's own day - the shift rostered there, else their last working day - not of one figure for all */
                     SUM(CAST(a.WorkedMinutes AS DECIMAL(18,8)) / CASE WHEN a.StandardMinutes > 0 THEN a.StandardMinutes ELSE payroll.fn_DayStandardMinutes(a.EmployeeId, a.WorkDate) END) AS PaidShare
              FROM attendance.ATTENDANCE_RECORD a
              JOIN #Emp x ON x.EmployeeId=a.EmployeeId
              WHERE a.WorkDate BETWEEN x.EmpFrom AND x.AttTo AND a.[Status] = 'Holiday' AND a.WorkedMinutes > 0
              GROUP BY a.EmployeeId) hw ON hw.EmployeeId = r.EmployeeId
        JOIN #CT ct ON ct.Code='HOLIDAY_WORK';

    /* an UNPAID public holiday: whoever was rostered to work it - in an APPROVED roster month of the branch of the day
       (QA3: unapproved months no longer count), inside the employment and the completed days - loses the day */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(uh.Days * r.DayRate, 2), r.CurrencyCode, 'Attendance', NULL, uh.Days, r.DayRate,
           CONCAT(uh.Days, N' unpaid public holiday(s)'), 24
    FROM #Rate r
    JOIN (SELECT sa.EmployeeId, CAST(COUNT(*) AS DECIMAL(6,2)) AS Days
          FROM attendance.SHIFT_ASSIGNMENT sa
          JOIN #Emp x ON x.EmployeeId = sa.EmployeeId
          JOIN core.HOLIDAY h ON h.HolidayDate = sa.WorkDate AND h.IsPaid = 0
                             AND (h.BranchId IS NULL OR h.BranchId = hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate))
          WHERE sa.WorkDate BETWEEN x.EmpFrom AND x.AttTo AND sa.IsRestDay = 0 AND sa.ShiftId IS NOT NULL
            AND EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                        WHERE rm.BranchId = hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate)
                          AND rm.MonthDate = DATEFROMPARTS(YEAR(sa.WorkDate), MONTH(sa.WorkDate), 1) AND rm.[Status] = 'Approved')
            AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = sa.EmployeeId AND a.WorkDate = sa.WorkDate AND a.WorkedMinutes > 0)
          GROUP BY sa.EmployeeId) uh ON uh.EmployeeId = r.EmployeeId
    JOIN #CT ct ON ct.Code='ABSENCE';

    /* -- D3. exit permissions beyond the leave balance (script 86), inside the employment -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(xu.Days * r.DayRate, 2), r.CurrencyCode, 'ExitPermission', NULL, xu.Days, r.DayRate,
           CONCAT(FORMAT(xu.Days, '0.##'), N' day(s) of exit permissions beyond the leave balance'), 25
    FROM #Rate r
    JOIN (SELECT a.EmployeeId, CAST(SUM(a.ExitUnpaidDays) AS DECIMAL(6,2)) AS Days
          FROM attendance.ATTENDANCE_RECORD a
          JOIN #Emp x ON x.EmployeeId = a.EmployeeId
          WHERE a.WorkDate BETWEEN x.EmpFrom AND x.EmpTo AND a.ExitUnpaidDays > 0
          GROUP BY a.EmployeeId) xu ON xu.EmployeeId = r.EmployeeId
    JOIN #CT ct ON ct.Code='UNPAID_LEAVE'
    WHERE xu.Days > 0;

    /* -- the unpaid deductions never take more than the basic paid for the month (QA3 decision): a month with more
          working days than StandardWorkingDaysPerMonth would otherwise deduct more than it paid. The lines are cut in
          their order, the line says so. -- */
    ;WITH ded AS (
        SELECT l.PayslipLineId, l.Amount,
               cap.Basic,
               SUM(l.Amount) OVER (PARTITION BY l.PayslipId ORDER BY l.SortOrder, l.PayslipLineId ROWS UNBOUNDED PRECEDING) - l.Amount AS Before
        FROM payroll.PAYSLIP_LINE l
        JOIN #Rate r ON r.PayslipId = l.PayslipId AND r.CurrencyCode = l.CurrencyCode
        CROSS APPLY (SELECT ISNULL(SUM(b.Amount), 0) AS Basic
                     FROM payroll.PAYSLIP_LINE b JOIN #CT c ON c.ComponentTypeId = b.ComponentTypeId AND c.Code = 'BASIC'
                     WHERE b.PayslipId = l.PayslipId AND b.SourceType = 'Salary' AND b.CurrencyCode = l.CurrencyCode) cap
        WHERE l.SourceType IN ('Leave','Attendance','ExitPermission') AND l.Category = 'Deduction'
    )
    UPDATE l SET Amount = CASE WHEN d.Basic - d.Before > 0 THEN d.Basic - d.Before ELSE 0 END,
                 Note = LEFT(CONCAT(l.Note, N' - capped: the month''s unpaid deductions never exceed the basic paid for it'), 400)
    FROM payroll.PAYSLIP_LINE l
    JOIN ded d ON d.PayslipLineId = l.PayslipLineId
    WHERE d.Before + d.Amount > d.Basic;

    /* -- E. overtime: payable = LEAST(cap, detected), at the request's multiplier, inside the employment -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(ot.PayMinutes / 60.0 * dh.HourRate * ot.RateMultiplier, 2), r.CurrencyCode,
           'Overtime', ot.OvertimeRequestId, ot.PayMinutes, dh.HourRate,
           CONCAT(ot.PayMinutes, N' min at ', FORMAT(ot.RateMultiplier,'0.0#'), N'x, a ', FORMAT(dh.DayMinutes / 60.0, '0.##'), N' h day'), 30
    FROM #Rate r
    JOIN #Emp x ON x.PayslipId = r.PayslipId
    JOIN (
        SELECT o.EmployeeId, o.OvertimeRequestId, o.RateMultiplier, o.WorkDate,
               CASE WHEN ISNULL(a.OvertimeMinutes,0) < o.ApprovedMinutes
                    THEN ISNULL(a.OvertimeMinutes,0) ELSE o.ApprovedMinutes END AS PayMinutes
        FROM workflow.OVERTIME_REQUEST o
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=o.RequestInstanceId
        LEFT JOIN attendance.ATTENDANCE_RECORD a
               ON a.EmployeeId=o.EmployeeId AND a.WorkDate=o.WorkDate
        WHERE ri.[Status]='Approved' AND o.ApprovedMinutes IS NOT NULL
          AND o.WorkDate BETWEEN @Start AND @End
    ) ot ON ot.EmployeeId=r.EmployeeId AND ot.WorkDate BETWEEN x.EmpFrom AND x.EmpTo
    /* script 117: the hour of that day = the day rate over the hours of the shift the day was measured against */
    CROSS APPLY (SELECT m.DayMinutes, CAST(r.DayRate * 60.0 / m.DayMinutes AS DECIMAL(18,4)) AS HourRate
                 FROM (SELECT payroll.fn_DayStandardMinutes(ot.EmployeeId, ot.WorkDate) AS DayMinutes) m) dh
    JOIN #CT ct ON ct.Code='OVERTIME'
    WHERE ot.PayMinutes > 0;

    /* -- F. tips: finalized distributions dated in the period - ONE LINE PER DISTRIBUTION and currency, so the line
          names the request that paid it (QA3: one line per currency carried only the lowest distribution id) -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           t.Amount, t.CurrencyCode, 'Tip', t.TipDistributionId,
           NULL, NULL, CONCAT(N'Tips of ', CONVERT(NVARCHAR(10), t.ShiftDate, 23)), 40
    FROM #Emp x
    JOIN (
        SELECT l.EmployeeId, l.CurrencyCode, td.TipDistributionId, td.ShiftDate, SUM(l.Amount) AS Amount
        FROM workflow.TIP_DISTRIBUTION_LINE l
        JOIN workflow.TIP_DISTRIBUTION td ON td.TipDistributionId=l.TipDistributionId
        WHERE td.FinalizedAt IS NOT NULL AND td.ShiftDate BETWEEN @Start AND @End
        GROUP BY l.EmployeeId, l.CurrencyCode, td.TipDistributionId, td.ShiftDate
    ) t ON t.EmployeeId=x.EmployeeId
    JOIN #CT ct ON ct.Code='TIPS'
    WHERE t.Amount <> 0;

    /* -- G. expenses: approved and never reimbursed, not held by an earlier open primary (QA3 PAY-5) -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ISNULL(er.ApprovedAmount, er.Amount), er.CurrencyCode,
           'Expense', er.ExpenseReimbursementId, NULL, NULL,
           CONCAT(er.Category, N' ', CONVERT(char(10),er.ExpenseDate,23)), 45
    FROM #Emp x
    JOIN payroll.fn_RunExpenses(@PayrollRunId) fx ON fx.EmployeeId=x.EmployeeId
    JOIN workflow.EXPENSE_REIMBURSEMENT er ON er.ExpenseReimbursementId=fx.ExpenseReimbursementId
    JOIN #CT ct ON ct.Code='EXPENSE';

    /* -- I. adjustments targeted at this period, not yet applied, not claimed by an open supplemental (script 81) -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           adj.Amount, adj.CurrencyCode, 'Adjustment', adj.PayrollAdjustmentId,
           NULL, NULL, adj.Reason, 55
    FROM #Emp x
    JOIN payroll.fn_RunAdjustments(@PayrollRunId) fa ON fa.EmployeeId=x.EmployeeId
    JOIN payroll.PAYROLL_ADJUSTMENT adj ON adj.PayrollAdjustmentId=fa.PayrollAdjustmentId
    JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId=adj.ComponentTypeId;

    /* -- J. separation settlements this run pays (QA3 PAY-2: also one whose month was locked before it was prepared) -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           v.Amount, s.CurrencyCode, 'Separation', s.SeparationId,
           NULL, NULL, v.Note, 60
    FROM #Emp x
    JOIN payroll.fn_RunSeparations(@PayrollRunId) fs ON fs.EmployeeId=x.EmployeeId
    JOIN workflow.SEPARATION s ON s.SeparationId=fs.SeparationId
    CROSS APPLY (VALUES
        ('UNUSED_LEAVE', s.UnusedLeaveAmount, CONCAT(FORMAT(s.UnusedLeaveDays,'0.##'),N' day(s)')),
        ('INDEMNITY',    s.IndemnityAmount,   CONCAT(FORMAT(s.ServiceYears,'0.##'),N' year(s) of service')),
        ('EXPENSE',      s.OtherDues,         N'Other dues on separation'),
        ('ABSENCE',      s.Deductions,        N'Deductions on separation')
    ) v(Code, Amount, Note)
    JOIN #CT ct ON ct.Code=v.Code
    WHERE v.Amount IS NOT NULL AND v.Amount > 0;
    /* notice pay in lieu, its own line */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           s.NoticePayAmount, s.CurrencyCode, 'Separation', s.SeparationId,
           NULL, NULL, CONCAT(N'Pay in lieu of ',s.NoticeShortfallDays,N' notice day(s)'), 61
    FROM #Emp x
    JOIN payroll.fn_RunSeparations(@PayrollRunId) fs ON fs.EmployeeId=x.EmployeeId
    JOIN workflow.SEPARATION s ON s.SeparationId=fs.SeparationId
    JOIN #CT ct ON ct.Code='BASIC'
    WHERE ISNULL(s.NoticePayAmount,0) > 0;

    /* -- J2. the leave balance on termination (script 86 D5; QA3 PAY-2 / REL-14 / LEV-8): the balance as of the
          termination date, at the day rate in force then; paid by the leaving month or, when that month was locked
          first, by the next open primary. Approving the run posts the settlement to the ledger, so it is paid once. -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(ABS(lp.Balance) * r.DayRate, 2), r.CurrencyCode, 'LeavePayout', NULL, ABS(lp.Balance), r.DayRate,
           CONCAT(CASE WHEN lp.Balance > 0 THEN N'Unused leave on leaving (' ELSE N'Leave taken beyond the balance on leaving (' END,
                  FORMAT(ABS(lp.Balance), '0.##'), N' day(s) ', NCHAR(215), N' the day rate), last day ', CONVERT(NVARCHAR(10), lp.TerminationDate, 23)), 62
    FROM payroll.fn_RunLeavePayouts(@PayrollRunId) lp
    JOIN #Rate r ON r.EmployeeId = lp.EmployeeId
    JOIN #CT ct ON ct.Code = CASE WHEN lp.Balance > 0 THEN 'LEAVE_PAYOUT' ELSE 'LEAVE_DEDUCTION' END;

    /* QA3 REL-11: every line's currency must have a rate in the run. In Review the frozen snapshot is kept and only a
       currency missing from it is added (as of the period end); a currency with no rate on file at all is refused, never
       converted to NULL. */
    INSERT INTO payroll.PAYROLL_RUN_RATE (PayrollRunId,FromCurrency,ToCurrency,Rate,RateType,SourceEffectiveDate)
    SELECT @PayrollRunId, c.CurrencyCode, @Primary, x.Rate, x.RateType, x.EffectiveDate
    FROM (SELECT DISTINCT l.CurrencyCode FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId=l.PayslipId
          WHERE ps.PayrollRunId=@PayrollRunId AND l.CurrencyCode <> @Primary) c
    CROSS APPLY (SELECT TOP 1 CAST(CASE WHEN er.FromCurrency=c.CurrencyCode THEN er.Rate ELSE 1.0/er.Rate END AS DECIMAL(28,12)) AS Rate,
                        er.RateType, er.EffectiveDate
                 FROM core.EXCHANGE_RATE er
                 WHERE ((er.FromCurrency=c.CurrencyCode AND er.ToCurrency=@Primary) OR (er.FromCurrency=@Primary AND er.ToCurrency=c.CurrencyCode))
                   AND er.RateType=@RateType AND er.EffectiveDate <= @End AND er.Rate > 0
                 ORDER BY er.EffectiveDate DESC, er.ExchangeRateId DESC) x
    WHERE payroll.fn_RunRate(@PayrollRunId, c.CurrencyCode, @Primary) IS NULL;
    DECLARE @NoRate CHAR(3) = (SELECT TOP 1 l.CurrencyCode FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId=l.PayslipId
                               WHERE ps.PayrollRunId=@PayrollRunId AND l.CurrencyCode <> @Primary
                                 AND payroll.fn_RunRate(@PayrollRunId, l.CurrencyCode, @Primary) IS NULL);
    IF @NoRate IS NOT NULL
    BEGIN
        ROLLBACK TRAN;
        DECLARE @EndText VARCHAR(10) = CONVERT(VARCHAR(10), @End, 23);
        RAISERROR('No %s rate of type %s is on file for %s (on or before %s). Add it on Exchange rates, then generate the run again.',16,1,@NoRate,@RateType,@Period,@EndText);
        RETURN 1;
    END

    /* -- K. STATUTORY: NSSF then tax, on the wage-like base in primary (script 86).
          QA3 PAY-9: ONE version per scheme per month - the rows in force on the period's last day; one tax table. -- */
    SELECT l.PayslipId,
           SUM(payroll.fn_ToPrimary(@PayrollRunId, l.Amount, l.CurrencyCode) * l.[Sign]) AS BaseP
    INTO #NssfBase
    FROM payroll.PAYSLIP_LINE l
    JOIN payroll.PAYSLIP ps ON ps.PayslipId=l.PayslipId AND ps.PayrollRunId=@PayrollRunId
    WHERE l.SourceType IN ('Salary','Overtime','Leave','Attendance','ExitPermission')
      AND l.Category IN ('Earning','Deduction')
    GROUP BY l.PayslipId;

    /* employee share, ceilinged schemes capped */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT nb.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(SUM(CASE WHEN nr.IsCeilinged=1 AND nb.BaseP > ISNULL(nr.CeilingAmount, @Ceiling)
                          THEN ISNULL(nr.CeilingAmount, @Ceiling) ELSE nb.BaseP END * nr.EmployeeRate), 2),
           @Primary, 'Statutory', NULL, NULL, NULL,
           N'NSSF employee share on the wage base', 70
    FROM #NssfBase nb
    JOIN hr.NSSF_RATE nr ON nr.EffectiveFrom <= @End AND (nr.EffectiveTo IS NULL OR nr.EffectiveTo >= @End)
    JOIN #CT ct ON ct.Code='NSSF_EMPLOYEE'
    WHERE nb.BaseP > 0
    GROUP BY nb.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign]
    HAVING SUM(CASE WHEN nr.IsCeilinged=1 AND nb.BaseP > ISNULL(nr.CeilingAmount, @Ceiling)
                    THEN ISNULL(nr.CeilingAmount, @Ceiling) ELSE nb.BaseP END * nr.EmployeeRate) > 0;

    /* employer cost */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT nb.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(SUM(CASE WHEN nr.IsCeilinged=1 AND nb.BaseP > ISNULL(nr.CeilingAmount, @Ceiling)
                          THEN ISNULL(nr.CeilingAmount, @Ceiling) ELSE nb.BaseP END * nr.EmployerRate), 2),
           @Primary, 'Statutory', NULL, NULL, NULL,
           N'NSSF employer share (all schemes)', 71
    FROM #NssfBase nb
    JOIN hr.NSSF_RATE nr ON nr.EffectiveFrom <= @End AND (nr.EffectiveTo IS NULL OR nr.EffectiveTo >= @End)
    JOIN #CT ct ON ct.Code='NSSF_EMPLOYER'
    WHERE nb.BaseP > 0
    GROUP BY nb.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign]
    HAVING SUM(CASE WHEN nr.IsCeilinged=1 AND nb.BaseP > ISNULL(nr.CeilingAmount, @Ceiling)
                    THEN ISNULL(nr.CeilingAmount, @Ceiling) ELSE nb.BaseP END * nr.EmployerRate) > 0;

    /* income tax: (base - employee NSSF) x 12, family deduction, brackets of the ONE table in force, /12 */
    ;WITH taxable AS (
        SELECT nb.PayslipId,
               (nb.BaseP - ISNULL(nssf.Amt,0)) * 12 - @FamilyDed AS AnnualTaxable
        FROM #NssfBase nb
        OUTER APPLY (SELECT SUM(l.Amount) AS Amt FROM payroll.PAYSLIP_LINE l
                     JOIN #CT c2 ON c2.ComponentTypeId=l.ComponentTypeId AND c2.Code='NSSF_EMPLOYEE'
                     WHERE l.PayslipId=nb.PayslipId AND l.SourceType='Statutory') nssf
    )
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT t.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(SUM(
               (CASE WHEN t.AnnualTaxable > ISNULL(b.MaxAnnual, t.AnnualTaxable)
                     THEN ISNULL(b.MaxAnnual, t.AnnualTaxable) ELSE t.AnnualTaxable END
                - b.MinAnnual) * b.Rate) / 12, 2),
           @Primary, 'Statutory', NULL, NULL, NULL,
           N'Income tax, annualised then divided by 12', 72
    FROM taxable t
    JOIN hr.TAX_BRACKET b ON b.MinAnnual < t.AnnualTaxable
                          AND b.EffectiveFrom = @TaxFrom
                          AND (b.EffectiveTo IS NULL OR b.EffectiveTo >= @End)
    JOIN #CT ct ON ct.Code='INCOME_TAX'
    WHERE t.AnnualTaxable > 0
    GROUP BY t.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign]
    HAVING SUM((CASE WHEN t.AnnualTaxable > ISNULL(b.MaxAnnual, t.AnnualTaxable)
                     THEN ISNULL(b.MaxAnnual, t.AnnualTaxable) ELSE t.AnnualTaxable END
                - b.MinAnnual) * b.Rate) / 12 >= 0.01;

    /* -- H. ADVANCES, LAST (script 86, D8): MIN(monthly, remaining) - and never more than the net -- */
    ;WITH net AS (
        SELECT l.PayslipId, l.CurrencyCode,
               SUM(CASE WHEN l.Category='Earning' THEN l.Amount WHEN l.Category='Deduction' THEN -l.Amount ELSE 0 END) AS NetBefore
        FROM payroll.PAYSLIP_LINE l
        JOIN payroll.PAYSLIP ps ON ps.PayslipId=l.PayslipId AND ps.PayrollRunId=@PayrollRunId
        GROUP BY l.PayslipId, l.CurrencyCode
    ), adv AS (
        SELECT x.PayslipId, a.SalaryAdvanceId, a.CurrencyCode, a.RemainingAmount,
               CASE WHEN a.MonthlyDeduction < a.RemainingAmount THEN a.MonthlyDeduction ELSE a.RemainingAmount END AS Wanted,
               ISNULL(SUM(CASE WHEN a.MonthlyDeduction < a.RemainingAmount THEN a.MonthlyDeduction ELSE a.RemainingAmount END)
                          OVER (PARTITION BY x.PayslipId, a.CurrencyCode ORDER BY a.SalaryAdvanceId ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS WantedBefore
        FROM #Emp x
        JOIN payroll.SALARY_ADVANCE a ON a.EmployeeId=x.EmployeeId
        WHERE a.IsSettled=0 AND a.RemainingAmount > 0 AND a.FirstDeductionPeriod <= @Period
    ), capped AS (
        SELECT v.*, n.NetBefore,
               CASE WHEN ISNULL(n.NetBefore,0) - v.WantedBefore <= 0 THEN CAST(0 AS DECIMAL(18,2))
                    WHEN v.Wanted <= ISNULL(n.NetBefore,0) - v.WantedBefore THEN v.Wanted
                    ELSE CAST(ISNULL(n.NetBefore,0) - v.WantedBefore AS DECIMAL(18,2)) END AS Taken
        FROM adv v LEFT JOIN net n ON n.PayslipId=v.PayslipId AND n.CurrencyCode=v.CurrencyCode
    )
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT c.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           c.Taken, c.CurrencyCode, 'Advance', c.SalaryAdvanceId, NULL, NULL,
           CASE WHEN c.Taken < c.Wanted
                THEN CONCAT(N'Instalment of ', FORMAT(c.Wanted,'0.00'), N' capped at the net: ', FORMAT(c.Wanted - c.Taken,'0.00'),
                            N' carried to the next run. Remaining after this: ', FORMAT(c.RemainingAmount - c.Taken,'0.00'))
                ELSE CONCAT(N'Remaining after this: ', FORMAT(c.RemainingAmount - c.Taken,'0.00')) END, 75
    FROM capped c
    JOIN #CT ct ON ct.Code='ADVANCE'
    WHERE c.Taken > 0;

    /* -- totals, attendance story, comparable net, warnings -- */
    UPDATE ps SET
        GrossUsd = ISNULL(t.GU,0), GrossLbp = ISNULL(t.GL,0),
        DeductionsUsd = ISNULL(t.DU,0), DeductionsLbp = ISNULL(t.DL,0),
        NetUsd = ISNULL(t.GU,0)-ISNULL(t.DU,0), NetLbp = ISNULL(t.GL,0)-ISNULL(t.DL,0),
        EmployerCostUsd = ISNULL(t.EU,0), EmployerCostLbp = ISNULL(t.EL,0)
    FROM payroll.PAYSLIP ps
    LEFT JOIN (
        SELECT l.PayslipId,
            SUM(IIF(l.Category='Earning'      AND l.CurrencyCode='USD', l.Amount,0)) AS GU,
            SUM(IIF(l.Category='Earning'      AND l.CurrencyCode='LBP', l.Amount,0)) AS GL,
            SUM(IIF(l.Category='Deduction'    AND l.CurrencyCode='USD', l.Amount,0)) AS DU,
            SUM(IIF(l.Category='Deduction'    AND l.CurrencyCode='LBP', l.Amount,0)) AS DL,
            SUM(IIF(l.Category='EmployerCost' AND l.CurrencyCode='USD', l.Amount,0)) AS EU,
            SUM(IIF(l.Category='EmployerCost' AND l.CurrencyCode='LBP', l.Amount,0)) AS EL
        FROM payroll.PAYSLIP_LINE l GROUP BY l.PayslipId
    ) t ON t.PayslipId=ps.PayslipId
    WHERE ps.PayrollRunId=@PayrollRunId;

    /* QA3 LEV-17: the payslip's leave days are what the approved leaves cost on the days inside the period and the
       employment (script 99's allocation: working days, half a day = 0.5), paid or unpaid by the type as approved */
    UPDATE ps SET
        NetPrimary = payroll.fn_ToPrimary(@PayrollRunId, ps.NetUsd, 'USD')
                   + CASE WHEN ps.NetLbp = 0 THEN 0 ELSE payroll.fn_ToPrimary(@PayrollRunId, ps.NetLbp, 'LBP') END,
        PaidDayFraction = att.Paid, UnpaidLeaveDays = lv.Unpaid,
        PaidLeaveDays = lv.Paid, OvertimeMinutes = ot.Mins
    FROM payroll.PAYSLIP ps
    JOIN #Emp x ON x.PayslipId = ps.PayslipId
    OUTER APPLY (SELECT CAST(SUM(a.DayFraction) AS DECIMAL(6,2)) AS Paid
                 FROM attendance.ATTENDANCE_RECORD a
                 WHERE a.EmployeeId=ps.EmployeeId AND a.WorkDate BETWEEN x.EmpFrom AND x.EmpTo) att
    OUTER APPLY (SELECT CAST(SUM(IIF(ISNULL(lr.PaidSnapshot, lt.IsPaid)=0, dd.D, 0)) AS DECIMAL(6,2)) AS Unpaid,
                        CAST(SUM(IIF(ISNULL(lr.PaidSnapshot, lt.IsPaid)=1, dd.D, 0)) AS DECIMAL(6,2)) AS Paid
                 FROM workflow.LEAVE_REQUEST lr
                 JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=lr.RequestInstanceId AND ri.[Status]='Approved'
                 JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId=lr.LeaveTypeId
                 CROSS APPLY (SELECT CASE WHEN lr.FromDate > x.EmpFrom THEN lr.FromDate ELSE x.EmpFrom END AS F,
                                     CASE WHEN ISNULL(lr.ApprovedToDate, lr.ToDate) < x.EmpTo THEN ISNULL(lr.ApprovedToDate, lr.ToDate) ELSE x.EmpTo END AS T) w
                 CROSS APPLY (SELECT CAST(ISNULL(SUM(ld.Part), 0) AS DECIMAL(6,2)) AS D
                              FROM hr.fn_LeaveRequestDays(lr.LeaveRequestId, 0) ld WHERE ld.WorkDate BETWEEN w.F AND w.T) dd
                 WHERE lr.EmployeeId=ps.EmployeeId AND w.F <= w.T) lv
    OUTER APPLY (SELECT SUM(l.Quantity) AS Mins FROM payroll.PAYSLIP_LINE l
                 WHERE l.PayslipId=ps.PayslipId AND l.SourceType='Overtime') ot
    WHERE ps.PayrollRunId=@PayrollRunId;

    UPDATE ps SET Notes = NULLIF(LTRIM(CONCAT(
        CASE WHEN x.EmpTo < x.EmpFrom
             THEN CONCAT(N' Settlement only: left on ', CONVERT(NVARCHAR(10), x.TerminationDate, 23), N'.')
             WHEN NOT EXISTS (SELECT 1 FROM payroll.PAYSLIP_LINE l JOIN #CT c ON c.ComponentTypeId=l.ComponentTypeId AND c.Code='BASIC'
                              WHERE l.PayslipId=ps.PayslipId AND l.SourceType='Salary')
             THEN N' NO BASIC SALARY ON FILE.' ELSE N'' END,
        /* a component paid in two currencies over the same days is paid twice: say so (QA3 PAY-6) */
        IIF(EXISTS (SELECT 1 FROM hr.SALARY_COMPONENT s1
                    JOIN hr.SALARY_COMPONENT s2 ON s2.EmployeeId=s1.EmployeeId AND s2.ComponentTypeId=s1.ComponentTypeId
                                               AND s2.CurrencyCode<>s1.CurrencyCode AND s2.SalaryComponentId>s1.SalaryComponentId
                    WHERE s1.EmployeeId=ps.EmployeeId
                      AND s1.EffectiveFrom <= x.EmpTo AND ISNULL(s1.EffectiveTo, x.EmpTo) >= x.EmpFrom
                      AND s2.EffectiveFrom <= x.EmpTo AND ISNULL(s2.EffectiveTo, x.EmpTo) >= x.EmpFrom
                      AND s1.EffectiveFrom <= ISNULL(s2.EffectiveTo, x.EmpTo) AND s2.EffectiveFrom <= ISNULL(s1.EffectiveTo, x.EmpTo)),
            N' THE SAME SALARY COMPONENT RUNS IN TWO CURRENCIES OVER THE SAME DAYS - check the salary tab.', N''),
        IIF(ps.NetUsd < 0 OR ps.NetLbp < 0, N' NEGATIVE NET - review deductions.', N''))), N'')
    FROM payroll.PAYSLIP ps
    JOIN #Emp x ON x.PayslipId = ps.PayslipId
    WHERE ps.PayrollRunId=@PayrollRunId;

    /* QA3 PAY-5: what every payslip was computed from, and the run-wide inputs - Approve compares them */
    INSERT INTO payroll.PAYSLIP_INPUT (PayslipId, Source, RowsCount, Fingerprint)
    SELECT ps.PayslipId, i.Source, i.RowsCount, i.Fingerprint
    FROM payroll.PAYSLIP ps
    CROSS APPLY payroll.fn_PayslipInputs(@PayrollRunId, ps.EmployeeId) i
    WHERE ps.PayrollRunId=@PayrollRunId;

    UPDATE payroll.PAYROLL_RUN
    SET GeneratedAt = SYSUTCDATETIME(), GeneratedUpTo = @UpTo,
        InputsFingerprint = (SELECT c.Fingerprint FROM payroll.fn_RunConfig(@PayrollRunId) c)
    WHERE PayrollRunId=@PayrollRunId;

    DECLARE @Count INT=(SELECT COUNT(*) FROM payroll.PAYSLIP WHERE PayrollRunId=@PayrollRunId);
    DECLARE @Warn INT=(SELECT COUNT(*) FROM payroll.PAYSLIP
                       WHERE PayrollRunId=@PayrollRunId AND Notes IS NOT NULL AND Notes<>N'');
    INSERT INTO payroll.PAYROLL_RUN_EVENT (PayrollRunId,[Action],ActedByUserId,Detail)
    VALUES (@PayrollRunId,'Generated',@ActedByUserId,
            CONCAT(@Count,N' payslip(s), ',@Warn,N' with warnings',
                   CASE WHEN @UpTo < @End THEN CONCAT(N'; attendance counted up to ',CONVERT(NVARCHAR(10),@UpTo,23),N' (completed days), later days as scheduled') ELSE N'' END,
                   CASE WHEN @Status = 'Draft' THEN CONCAT(N'; rates read as of ', CONVERT(NVARCHAR(10), @End, 23)) ELSE N'; rates as frozen at review' END));
    COMMIT TRAN;

    SELECT @PayrollRunId AS PayrollRunId, @Count AS PayslipCount, @Warn AS PayslipsWithWarnings;
END;
GO

/* ---------------------------------------------------------------- 10. worked time: a punched day missing from the roster is measured against the shift it fits (script 114's body under a
   new name - usp_Report_WorkedTime_PunchDays stays as script 114 made it, it is that script's marker; the API reads this one) */
CREATE OR ALTER PROCEDURE report.usp_Report_WorkedTime_PunchDaysByShift
    @From       DATE,
    @To         DATE,
    @EmployeeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @From IS NULL OR @To IS NULL OR @To < @From
    BEGIN RAISERROR('Choose the first and the last day of the period (the last on or after the first).', 16, 1); RETURN; END

    /* the processor's own settings and defaults (usp_Attendance_ComputeDay) */
    DECLARE @Mode VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'PunchDirectionMode'), 'Device');
    DECLARE @DebounceSec INT = 60 * ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'PunchDebounceMinutes') AS INT), 0);

    DECLARE @days TABLE (EmployeeId INT NOT NULL, WorkDate DATE NOT NULL, BranchId INT NULL, PRIMARY KEY (EmployeeId, WorkDate));
    INSERT INTO @days (EmployeeId, WorkDate, BranchId)
    SELECT u.EmployeeId, u.WorkDate, u.BranchId
    FROM attendance.fn_UnrosteredDays(@From, @To) u
    WHERE u.IsDismissed = 0
      AND (@EmployeeId IS NULL OR u.EmployeeId = @EmployeeId);

    /* the punches attributed to each day, exactly as the machine sent them */
    DECLARE @src TABLE (EmployeeId INT, WorkDate DATE, RawLogId BIGINT, PunchTimeUtc DATETIME2, PunchType SMALLINT);
    INSERT INTO @src (EmployeeId, WorkDate, RawLogId, PunchTimeUtc, PunchType)
    SELECT d.EmployeeId, d.WorkDate, r.RawLogId, r.PunchTimeUtc, r.PunchType
    FROM @days d
    JOIN attendance.RAW_DEVICE_LOG r
      ON r.EmployeeId = d.EmployeeId
     AND r.PunchTimeUtc >= CAST(d.WorkDate AS DATETIME2)
     AND r.PunchTimeUtc <  CAST(DATEADD(DAY, 2, d.WorkDate) AS DATETIME2)
    WHERE attendance.fn_AttributedWorkDate(d.EmployeeId, r.PunchTimeUtc) = d.WorkDate;

    /* debounce: a gap greater than the window starts a new press-group; only the first press of a group is kept;
       then the effective direction */
    DECLARE @punch TABLE (EmployeeId INT, WorkDate DATE, Seq INT, PunchTimeUtc DATETIME2, EffType SMALLINT, PrevType SMALLINT);
    ;WITH x AS (
        SELECT s.*,
               CASE WHEN LAG(s.PunchTimeUtc) OVER (PARTITION BY s.EmployeeId, s.WorkDate ORDER BY s.PunchTimeUtc, s.RawLogId) IS NULL
                      OR DATEDIFF(SECOND, LAG(s.PunchTimeUtc) OVER (PARTITION BY s.EmployeeId, s.WorkDate ORDER BY s.PunchTimeUtc, s.RawLogId), s.PunchTimeUtc) > @DebounceSec
                    THEN 1 ELSE 0 END AS NewGrp
        FROM @src s
    ), g AS (
        SELECT x.*, SUM(x.NewGrp) OVER (PARTITION BY x.EmployeeId, x.WorkDate ORDER BY x.PunchTimeUtc, x.RawLogId ROWS UNBOUNDED PRECEDING) AS GrpNo
        FROM x
    ), k AS (
        SELECT g.*, ROW_NUMBER() OVER (PARTITION BY g.EmployeeId, g.WorkDate, g.GrpNo ORDER BY g.PunchTimeUtc, g.RawLogId) AS RnInGrp
        FROM g
    ), kept AS (
        SELECT k.EmployeeId, k.WorkDate, k.PunchTimeUtc, k.PunchType,
               ROW_NUMBER() OVER (PARTITION BY k.EmployeeId, k.WorkDate ORDER BY k.PunchTimeUtc, k.RawLogId) AS Seq
        FROM k WHERE k.RnInGrp = 1
    ), eff AS (
        SELECT kept.EmployeeId, kept.WorkDate, kept.Seq, kept.PunchTimeUtc,
               CASE WHEN @Mode = 'Alternate' THEN CAST((kept.Seq - 1) % 2 AS SMALLINT) ELSE kept.PunchType END AS EffType
        FROM kept
    )
    INSERT INTO @punch (EmployeeId, WorkDate, Seq, PunchTimeUtc, EffType, PrevType)
    SELECT e.EmployeeId, e.WorkDate, e.Seq, e.PunchTimeUtc, e.EffType,
           LAG(e.EffType) OVER (PARTITION BY e.EmployeeId, e.WorkDate ORDER BY e.Seq)
    FROM eff e;

    /* pair each opening In with the next Out; the gap after each pair */
    DECLARE @ivl TABLE (EmployeeId INT, WorkDate DATE, InTimeUtc DATETIME2, OutTimeUtc DATETIME2, GapAfterMins INT);
    INSERT INTO @ivl (EmployeeId, WorkDate, InTimeUtc, OutTimeUtc, GapAfterMins)
    SELECT p.EmployeeId, p.WorkDate, p.InTimeUtc, p.OutTimeUtc,
           ISNULL(DATEDIFF(MINUTE, p.OutTimeUtc, LEAD(p.InTimeUtc) OVER (PARTITION BY p.EmployeeId, p.WorkDate ORDER BY p.InTimeUtc)), 0)
    FROM (
        SELECT i.EmployeeId, i.WorkDate, i.PunchTimeUtc AS InTimeUtc,
               (SELECT MIN(o.PunchTimeUtc) FROM @punch o
                WHERE o.EmployeeId = i.EmployeeId AND o.WorkDate = i.WorkDate AND o.EffType = 1 AND o.PunchTimeUtc > i.PunchTimeUtc) AS OutTimeUtc
        FROM @punch i
        WHERE i.EffType = 0 AND (i.PrevType IS NULL OR i.PrevType = 1)
    ) p
    WHERE p.OutTimeUtc IS NOT NULL;

    /* script 117: measured like the machine writer measures a day without a rostered shift - against the shift the
       first in fits: its break comes off once (a gap up to the break is the break), and its length is the day's
       standard (StandardMinutes; the default day when no shift fits) */
    SELECT d.EmployeeId, d.WorkDate, d.BranchId, a.FirstIn, a.LastOut, ISNULL(a.PunchCount, 0) AS PunchCount,
           CASE WHEN a.FirstIn IS NULL OR a.LastOut IS NULL THEN 0
                WHEN DATEDIFF(MINUTE, a.FirstIn, a.LastOut) - w.BreakMinutes - w.MidDay > 0 THEN DATEDIFF(MINUTE, a.FirstIn, a.LastOut) - w.BreakMinutes - w.MidDay
                ELSE 0 END AS WorkedMinutes,
           CAST(CASE WHEN a.InCount <> a.OutCount OR a.FirstIn IS NULL OR a.LastOut IS NULL THEN 1 ELSE 0 END AS BIT) AS MissingPunch,
           ISNULL(rs.StandardMinutes, core.fn_StandardDayMinutes()) AS StandardMinutes, rs.ShiftId AS RelatedShiftId
    FROM @days d
    OUTER APPLY (SELECT MIN(CASE WHEN p.EffType = 0 THEN p.PunchTimeUtc END) AS FirstIn,
                        MAX(CASE WHEN p.EffType = 1 THEN p.PunchTimeUtc END) AS LastOut,
                        SUM(CASE WHEN p.EffType = 0 THEN 1 ELSE 0 END) AS InCount,
                        SUM(CASE WHEN p.EffType = 1 THEN 1 ELSE 0 END) AS OutCount,
                        COUNT(*) AS PunchCount
                 FROM @punch p WHERE p.EmployeeId = d.EmployeeId AND p.WorkDate = d.WorkDate) a
    OUTER APPLY (SELECT SUM(v.GapAfterMins) AS Gap FROM @ivl v WHERE v.EmployeeId = d.EmployeeId AND v.WorkDate = d.WorkDate) gp
    OUTER APPLY attendance.fn_ShiftByPunch(d.WorkDate, a.FirstIn) rs
    CROSS APPLY (SELECT ISNULL(rs.BreakMinutes, 0) AS BreakMinutes,
                        CASE WHEN ISNULL(gp.Gap, 0) - ISNULL(rs.BreakMinutes, 0) > 0 THEN ISNULL(gp.Gap, 0) - ISNULL(rs.BreakMinutes, 0) ELSE 0 END AS MidDay) w
    ORDER BY d.EmployeeId, d.WorkDate;
END;
GO

/* ---------------------------------------------------------------- 11. the setting is gone */
/* Nothing reads StandardWorkDayHours any more: the length of a day is its shift's. */
DECLARE @WasHours NVARCHAR(100) = (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'StandardWorkDayHours');
IF @WasHours IS NOT NULL
BEGIN
    DELETE FROM core.SETTING WHERE SettingKey = 'StandardWorkDayHours';
    PRINT CONCAT('setting StandardWorkDayHours removed (it was ', @WasHours, ' hours)');
END
GO

/* ---------------------------------------------------------------- 12. OWNER CHECK */
EXEC attendance.usp_Shift_SyncCurrent @Quiet = 1;
DECLARE @Shifts NVARCHAR(MAX) = (
    SELECT STRING_AGG(CAST(CONCAT(s.Name, N' ', LEFT(CONVERT(VARCHAR(8), s.StartTime, 108), 5), N'-', LEFT(CONVERT(VARCHAR(8), s.EndTime, 108), 5),
                                  N' = ', FORMAT((DATEDIFF(MINUTE, s.StartTime, s.EndTime) + CASE WHEN ISNULL(s.CrossesMidnight, 0) = 1 THEN 1440 ELSE 0 END
                                                  - ISNULL(s.BreakMinutes, 0)) / 60.0, '0.##'), N' h') AS NVARCHAR(MAX)), N'; ')
           WITHIN GROUP (ORDER BY s.ShiftId)
    FROM attendance.SHIFT s WHERE s.IsActive = 1);
PRINT CONCAT('OWNER CHECK (117): the length of a working day now comes from the shifts. Active shifts: ', ISNULL(@Shifts, N'(none)'),
             '. The default day (used only when no shift fits): ', FORMAT(core.fn_StandardDayMinutes() / 60.0, '0.##'),
             ' h. Overtime is paid per hour of the day''s own shift. Change a shift''s hours on Attendance > Shifts.');
PRINT '117_shift_hours_by_date.sql: shift hours by date - in place.';
GO

SET NOEXEC OFF;
GO
