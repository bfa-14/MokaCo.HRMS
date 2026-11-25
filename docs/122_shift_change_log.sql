/* ============================================================================
   122_shift_change_log.sql - EVERY CHANGE TO A SHIFT IS WRITTEN DOWN, AND KEPT; THE LAST READERS OF "TODAY'S
   SHIFT" FOR A PAST DAY READ THE HOURS IN FORCE THAT DAY (25 Nov 2026).

   WHAT WAS MISSING. Script 117 made a shift's hours dated (attendance.SHIFT_HOURS) and every day is judged by the
   hours in force on it. But that table is the TIMELINE, not a record of what people did: entering a change again on
   the same date overwrites the version, a change for a period deletes the versions inside it, taking a change back
   deletes it, and a rename or switching a shift off is a plain UPDATE of attendance.SHIFT. Nobody could tell later
   who changed what, when, or what it was before.

   WHAT THIS SCRIPT DOES
   1. attendance.SHIFT_CHANGE - the change log. APPEND-ONLY: a row is never updated by the application and never
      deleted (an INSTEAD OF DELETE trigger refuses it). One row per change, with the before and the after:
        Created          a shift's first hours (usp_Shift_Create)
        HoursChanged     hours written from a date (a new version, or a version overwritten)
        HoursRemoved     a version deleted (a change taken back, or replaced by a change for a period); the "after"
                         is the hours in force from that date once it is gone
        Renamed          the name changed (attendance.SHIFT.Name)
        Deactivated / Activated   attendance.SHIFT.IsActive changed
        DaysNotRederived days a change reached that could not be worked out again (see 4)
      Who: SESSION_CONTEXT(N'UserId') when the caller set it (the API does, before every shift call), else the
      version's CreatedByUserId for hours written; unknown (NULL) for a version deleted or a name/active change made
      outside the API. The log starts now: the versions already in SHIFT_HOURS are their own record of the past.
   2. Written by TRIGGERS, so no procedure of script 117 is redefined for it:
        attendance.tr_SHIFT_HOURS_ChangeLog   AFTER INSERT, UPDATE, DELETE on attendance.SHIFT_HOURS. A row that
                                              changes nothing (the same hours as the version before it, which
                                              usp_Shift_TidyHours then removes) is not logged. The last day of the
                                              hours: for a change entered for a PERIOD, the period's own last day,
                                              which the API puts on the session (SESSION_CONTEXT N'ShiftHoursFrom' /
                                              N'ShiftHoursTo', next to N'UserId'): usp_Shift_SetHours writes the
                                              period's version BEFORE the "back to the hours before" version that ends
                                              it, so the table cannot tell the trigger that end yet. Otherwise the day
                                              before the next later change already recorded (none = until the next
                                              change).
        attendance.tr_SHIFT_ChangeLog         AFTER UPDATE on attendance.SHIFT, only when Name or IsActive really
                                              change: the nightly usp_Shift_SyncCurrent copies today's hours into
                                              attendance.SHIFT and must not fill the log with noise.
   3. attendance.usp_Shift_GetChanges @ShiftId - the log of one shift, newest first (GET api/shifts/{id}/changes).
   4. attendance.usp_Shift_RederiveDays (script 117's body) still leaves a day that fails as it stands, but now COUNTS
      it: @Failed OUTPUT for the caller, a PRINT for whoever reads the output, and a DaysNotRederived row in the change
      log so the Shifts page can say so. Its callers (usp_Shift_SetHours, usp_Shift_DeleteHours) are unchanged.
   5. The last readers of TODAY'S shift for a PAST day read the version in force that day
      (attendance.fn_ShiftHoursOn(ShiftId, WorkDate)) to know whether the shift crosses midnight:
        attendance.usp_Correction_Create   script 100's body, only that change
        attendance.usp_DayReport_Create    script 110's body, only that change

   NOT COVERED: attendance.fn_AttributedWorkDate exists only in production (its text is not in the repo), so it is
   left as it is: it still reads an OVERNIGHT shift's present end time when it attributes a small-hours punch to the
   night before. After changing the hours of an overnight shift, check the nights around the change on Daily
   attendance.

   Each redefined procedure must be the version this script was written from (parameters and text), and an object
   that already carries one of the NEW names (the table, the three triggers, usp_Shift_GetChanges) must be this
   script's own; otherwise the script refuses before changing anything. MARKER for the deploy guard: attendance.usp_Shift_GetChanges, the LAST
   object the script creates. Needs 100, 110 and 117. Pure ASCII; QUOTED_IDENTIFIER ON; re-runnable.
   Apply with: sqlcmd -S <server> -U <login> -C -I -b -d <database> -i docs/122_shift_change_log.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID('attendance.SHIFT_HOURS') IS NULL OR OBJECT_ID('attendance.fn_ShiftHoursOn') IS NULL
   OR OBJECT_ID('attendance.usp_Shift_SetHours') IS NULL OR OBJECT_ID('attendance.usp_Shift_RederiveDays') IS NULL
   OR OBJECT_ID('attendance.usp_Correction_Create') IS NULL OR OBJECT_ID('attendance.usp_DayReport_Create') IS NULL
BEGIN
    RAISERROR('122_shift_change_log.sql needs scripts 100, 110 and 117 (attendance.SHIFT_HOURS, fn_ShiftHoursOn, usp_Shift_SetHours, usp_Shift_RederiveDays, usp_Correction_Create, usp_DayReport_Create). Apply them first. Nothing was applied.', 16, 1);
    SET NOEXEC ON;
END
GO

/* PRODUCTION HOLDS OBJECTS THE REPOSITORY NEVER HAD. Nothing below may replace one of them, or hang a trigger or an
   index on one: an object that already carries one of this script's NEW names must be this script's own - the table
   with its columns, a trigger on its own table whose text says "script 122", the procedure whose text says so.
   Anything else stops the script here, naming it, with nothing applied. (The three procedures it redefines are
   checked in section 0.) tr_SHIFT_CHANGE_KeepForever was first written without the words "script 122": its first
   text, "kept for good", is recognised too. */
DECLARE @foreign NVARCHAR(MAX) = NULL;
DECLARE @own TABLE (Name NVARCHAR(128) NOT NULL, OnTable NVARCHAR(128) NULL, AlsoKnownBy NVARCHAR(100) NULL);
INSERT INTO @own (Name, OnTable, AlsoKnownBy) VALUES
    (N'attendance.SHIFT_CHANGE', NULL, NULL),                                  -- a table: known by its columns below
    (N'attendance.tr_SHIFT_CHANGE_KeepForever', N'attendance.SHIFT_CHANGE', N'%kept for good%'),
    (N'attendance.tr_SHIFT_HOURS_ChangeLog', N'attendance.SHIFT_HOURS', NULL),
    (N'attendance.tr_SHIFT_ChangeLog', N'attendance.SHIFT', NULL),
    (N'attendance.usp_Shift_GetChanges', NULL, NULL);

SELECT @foreign = STRING_AGG(o.Name, N', ')
FROM @own o
WHERE OBJECT_ID(o.Name) IS NOT NULL
  AND CASE
        WHEN o.Name = N'attendance.SHIFT_CHANGE'
            THEN IIF(OBJECTPROPERTY(OBJECT_ID(o.Name), 'IsUserTable') = 1
                     AND COL_LENGTH(o.Name, N'ShiftId') IS NOT NULL AND COL_LENGTH(o.Name, N'DaysCount') IS NOT NULL
                     AND COL_LENGTH(o.Name, N'OldGraceMinutes') IS NOT NULL, 0, 1)
        WHEN o.OnTable IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM sys.triggers t WHERE t.object_id = OBJECT_ID(o.Name) AND t.parent_id = OBJECT_ID(o.OnTable))
            THEN 1
        WHEN ISNULL(OBJECT_DEFINITION(OBJECT_ID(o.Name)), N'') LIKE N'%script 122%'
             OR (o.AlsoKnownBy IS NOT NULL AND ISNULL(OBJECT_DEFINITION(OBJECT_ID(o.Name)), N'') LIKE o.AlsoKnownBy)
            THEN 0
        ELSE 1
      END = 1;

IF NULLIF(@foreign, N'') IS NOT NULL
BEGIN
    RAISERROR('122_shift_change_log.sql: this database already has object(s) with a name this script uses, which it did not create: %s. Nothing was applied; the script must be renamed around them first.', 16, 1, @foreign);
    SET NOEXEC ON;
END
GO

/* ---------------------------------------------------------------- 0. the procedures redefined here are the versions this script was written from */
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('attendance.usp_Shift_RederiveDays')
           AND name NOT IN (N'@ShiftId', N'@From', N'@To', N'@Days', N'@Failed'))
   OR ISNULL(OBJECT_DEFINITION(OBJECT_ID('attendance.usp_Shift_RederiveDays')), N'') NOT LIKE N'%Only the days really derived are counted%'
BEGIN RAISERROR('122_shift_change_log.sql: the live attendance.usp_Shift_RederiveDays is not the copy of script 117 (a parameter this script does not know, or its text differs). Merge by hand; nothing was applied.', 16, 1); SET NOEXEC ON; END
GO
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('attendance.usp_Correction_Create')
           AND name NOT IN (N'@AttendanceId', N'@RequestedBy', N'@NewFirstInUtc', N'@NewLastOutUtc', N'@NewExitMinutes', N'@NewStatus', N'@Reason'))
   OR ISNULL(OBJECT_DEFINITION(OBJECT_ID('attendance.usp_Correction_Create')), N'') NOT LIKE N'%is not one of their working days%'
   OR (ISNULL(OBJECT_DEFINITION(OBJECT_ID('attendance.usp_Correction_Create')), N'') NOT LIKE N'%JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId%'
       AND ISNULL(OBJECT_DEFINITION(OBJECT_ID('attendance.usp_Correction_Create')), N'') NOT LIKE N'%script 122%')
BEGIN RAISERROR('122_shift_change_log.sql: the live attendance.usp_Correction_Create is not the copy of script 100 (a parameter this script does not know, or its text differs). Merge by hand; nothing was applied.', 16, 1); SET NOEXEC ON; END
GO
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('attendance.usp_DayReport_Create')
           AND name NOT IN (N'@EmployeeId', N'@WorkDate', N'@ClaimedIn', N'@ClaimedOut', N'@Message', N'@CallerUserId'))
   OR ISNULL(OBJECT_DEFINITION(OBJECT_ID('attendance.usp_DayReport_Create')), N'') NOT LIKE N'%already waiting for HR. Withdraw it first%'
   OR (ISNULL(OBJECT_DEFINITION(OBJECT_ID('attendance.usp_DayReport_Create')), N'') NOT LIKE N'%JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId%'
       AND ISNULL(OBJECT_DEFINITION(OBJECT_ID('attendance.usp_DayReport_Create')), N'') NOT LIKE N'%script 122%')
BEGIN RAISERROR('122_shift_change_log.sql: the live attendance.usp_DayReport_Create is not the copy of script 110 (a parameter this script does not know, or its text differs). Merge by hand; nothing was applied.', 16, 1); SET NOEXEC ON; END
GO

/* ---------------------------------------------------------------- 1. the change log */
IF OBJECT_ID('attendance.SHIFT_CHANGE') IS NULL
BEGIN
    CREATE TABLE attendance.SHIFT_CHANGE (
        ShiftChangeId      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SHIFT_CHANGE PRIMARY KEY,
        ShiftId            INT           NOT NULL,    -- no foreign key: the log outlives anything done to the shift
        ChangedAtUtc       DATETIME2(0)  NOT NULL CONSTRAINT DF_SHIFT_CHANGE_At DEFAULT SYSUTCDATETIME(),
        ChangedByUserId    INT           NULL,        -- NULL = not known
        [Action]           VARCHAR(20)   NOT NULL CONSTRAINT CK_SHIFT_CHANGE_Action
                           CHECK ([Action] IN ('Created', 'HoursChanged', 'HoursRemoved', 'Renamed', 'Deactivated', 'Activated', 'DaysNotRederived')),
        EffectiveFrom      DATE          NULL,        -- hours: the first day they apply (2000-01-01 = all days); NULL for a name or active change
        EffectiveTo        DATE          NULL,        -- hours: the last day they apply when that was known at the change; NULL = until the next change
        OldStartTime       TIME          NULL,
        NewStartTime       TIME          NULL,
        OldEndTime         TIME          NULL,
        NewEndTime         TIME          NULL,
        OldCrossesMidnight BIT           NULL,
        NewCrossesMidnight BIT           NULL,
        OldBreakMinutes    INT           NULL,
        NewBreakMinutes    INT           NULL,
        OldGraceMinutes    INT           NULL,        -- NULL on an hours row = the AttendanceToleranceMinutes setting
        NewGraceMinutes    INT           NULL,
        OldName            NVARCHAR(100) NULL,
        NewName            NVARCHAR(100) NULL,
        DaysCount          INT           NULL,        -- DaysNotRederived: how many days
        Note               NVARCHAR(400) NULL
    );
    PRINT 'table attendance.SHIFT_CHANGE created';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_SHIFT_CHANGE_Shift' AND object_id = OBJECT_ID('attendance.SHIFT_CHANGE'))
    CREATE INDEX IX_SHIFT_CHANGE_Shift ON attendance.SHIFT_CHANGE (ShiftId, ShiftChangeId DESC);
GO

/* The log is never deleted. (A deliberate clean-up disables this trigger first, like the admin renumbering tools do.) */
CREATE OR ALTER TRIGGER attendance.tr_SHIFT_CHANGE_KeepForever
ON attendance.SHIFT_CHANGE
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;
    /* script 122 */
    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    RAISERROR('The shift change log is kept for good: its rows are never deleted.', 16, 1);
END;
GO

/* ---------------------------------------------------------------- 2. the triggers that write it */
/* Every version of a shift's hours written, overwritten or deleted, with its before and after. A version is
   "the same" as another when start, end, overnight, break and grace are all equal. */
CREATE OR ALTER TRIGGER attendance.tr_SHIFT_HOURS_ChangeLog
ON attendance.SHIFT_HOURS
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    /* script 122 */
    DECLARE @HasIns BIT = CASE WHEN EXISTS (SELECT 1 FROM inserted) THEN 1 ELSE 0 END;
    DECLARE @HasDel BIT = CASE WHEN EXISTS (SELECT 1 FROM deleted) THEN 1 ELSE 0 END;
    IF @HasIns = 0 AND @HasDel = 0 RETURN;
    DECLARE @Who INT = TRY_CONVERT(INT, SESSION_CONTEXT(N'UserId'));
    DECLARE @Now DATETIME2(0) = SYSUTCDATETIME();

    /* the last day a version's hours run. A change entered for a PERIOD: the period's last day, as the caller typed it
       (the API puts the change's dates on the session; no first day = today, as usp_Shift_Update does). It cannot be
       read from the table: usp_Shift_SetHours writes the period's version BEFORE the "back to the hours before"
       version on the day after the period. Any other version: the day before the next LATER version with other hours
       (a later version with the same hours only repeats it, and usp_Shift_TidyHours removes it); none = until the
       next change. */
    DECLARE @PeriodTo DATE = TRY_CONVERT(DATE, SESSION_CONTEXT(N'ShiftHoursTo'));
    DECLARE @PeriodFrom DATE = CASE WHEN @PeriodTo IS NOT NULL
                                    THEN ISNULL(TRY_CONVERT(DATE, SESSION_CONTEXT(N'ShiftHoursFrom')),
                                                CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE)) END;
    IF @HasIns = 1 AND @HasDel = 0
    BEGIN
        /* a NEW version. Before: the version in force on its date until now; for a shift's first version, the hours
           attendance.SHIFT still shows when they differ (a shift made outside script 117's procedures, corrected in
           place); none for a shift just created - that is 'Created'. */
        INSERT INTO attendance.SHIFT_CHANGE
            (ShiftId, ChangedAtUtc, ChangedByUserId, [Action], EffectiveFrom, EffectiveTo,
             OldStartTime, NewStartTime, OldEndTime, NewEndTime, OldCrossesMidnight, NewCrossesMidnight,
             OldBreakMinutes, NewBreakMinutes, OldGraceMinutes, NewGraceMinutes, OldName, NewName, Note)
        SELECT x.ShiftId, @Now, COALESCE(@Who, x.CreatedByUserId),
               CASE WHEN x.OldFrom = 0 AND x.IsFirst = 1 THEN 'Created' ELSE 'HoursChanged' END,
               x.EffectiveFrom,
               CASE WHEN x.EffectiveFrom = @PeriodFrom AND NOT (x.OldFrom = 0 AND x.IsFirst = 1) THEN @PeriodTo ELSE nx.LastDay END,
               CASE x.OldFrom WHEN 1 THEN x.pStart WHEN 2 THEN x.sStart END, x.StartTime,
               CASE x.OldFrom WHEN 1 THEN x.pEnd   WHEN 2 THEN x.sEnd   END, x.EndTime,
               CASE x.OldFrom WHEN 1 THEN x.pCross WHEN 2 THEN x.sCross END, x.CrossesMidnight,
               CASE x.OldFrom WHEN 1 THEN x.pBreak WHEN 2 THEN x.sBreak END, x.BreakMinutes,
               CASE x.OldFrom WHEN 1 THEN x.pGrace WHEN 2 THEN x.sGrace END, x.GraceMinutes,
               NULL, CASE WHEN x.OldFrom = 0 AND x.IsFirst = 1 THEN x.ShiftName END,
               x.Note
        FROM (
            SELECT i.ShiftHoursId, i.ShiftId, i.EffectiveFrom, i.StartTime, i.EndTime, i.CrossesMidnight, i.BreakMinutes, i.GraceMinutes,
                   i.Note, i.CreatedByUserId, s.Name AS ShiftName,
                   p.StartTime AS pStart, p.EndTime AS pEnd, p.CrossesMidnight AS pCross, p.BreakMinutes AS pBreak, p.GraceMinutes AS pGrace,
                   s.StartTime AS sStart, s.EndTime AS sEnd, ISNULL(s.CrossesMidnight, 0) AS sCross, ISNULL(s.BreakMinutes, 0) AS sBreak,
                   s.GraceMinutes AS sGrace,
                   f.IsFirst,
                   CASE WHEN p.ShiftHoursId IS NOT NULL THEN 1
                        WHEN f.IsFirst = 1 AND (s.StartTime <> i.StartTime OR s.EndTime <> i.EndTime
                                                OR ISNULL(s.CrossesMidnight, 0) <> i.CrossesMidnight OR ISNULL(s.BreakMinutes, 0) <> i.BreakMinutes
                                                OR ISNULL(s.GraceMinutes, -1) <> ISNULL(i.GraceMinutes, -1)) THEN 2
                        ELSE 0 END AS OldFrom      -- 1 the version before it, 2 attendance.SHIFT's own hours, 0 none
            FROM inserted i
            JOIN attendance.SHIFT s ON s.ShiftId = i.ShiftId
            OUTER APPLY (SELECT TOP 1 h.ShiftHoursId, h.StartTime, h.EndTime, h.CrossesMidnight, h.BreakMinutes, h.GraceMinutes
                         FROM attendance.SHIFT_HOURS h
                         WHERE h.ShiftId = i.ShiftId AND h.EffectiveFrom < i.EffectiveFrom
                           AND NOT EXISTS (SELECT 1 FROM inserted n WHERE n.ShiftHoursId = h.ShiftHoursId)
                         ORDER BY h.EffectiveFrom DESC) p
            CROSS APPLY (SELECT CASE WHEN EXISTS (SELECT 1 FROM attendance.SHIFT_HOURS h
                                                  WHERE h.ShiftId = i.ShiftId AND h.ShiftHoursId <> i.ShiftHoursId)
                                     THEN 0 ELSE 1 END AS IsFirst) f
        ) x
        OUTER APPLY (SELECT DATEADD(DAY, -1, MIN(h.EffectiveFrom)) AS LastDay
                     FROM attendance.SHIFT_HOURS h
                     WHERE h.ShiftId = x.ShiftId AND h.EffectiveFrom > x.EffectiveFrom
                       AND NOT (h.StartTime = x.StartTime AND h.EndTime = x.EndTime AND h.CrossesMidnight = x.CrossesMidnight
                                AND h.BreakMinutes = x.BreakMinutes AND ISNULL(h.GraceMinutes, -1) = ISNULL(x.GraceMinutes, -1))) nx
        /* the same hours as the version before: nothing changed */
        WHERE NOT (x.OldFrom = 1 AND x.pStart = x.StartTime AND x.pEnd = x.EndTime AND x.pCross = x.CrossesMidnight
                   AND x.pBreak = x.BreakMinutes AND ISNULL(x.pGrace, -1) = ISNULL(x.GraceMinutes, -1));
    END
    ELSE IF @HasIns = 1 AND @HasDel = 1
    BEGIN
        /* a version OVERWRITTEN (the same date entered again, or a never-worked shift corrected in place) */
        INSERT INTO attendance.SHIFT_CHANGE
            (ShiftId, ChangedAtUtc, ChangedByUserId, [Action], EffectiveFrom, EffectiveTo,
             OldStartTime, NewStartTime, OldEndTime, NewEndTime, OldCrossesMidnight, NewCrossesMidnight,
             OldBreakMinutes, NewBreakMinutes, OldGraceMinutes, NewGraceMinutes, Note)
        SELECT i.ShiftId, @Now, COALESCE(@Who, i.CreatedByUserId), 'HoursChanged', i.EffectiveFrom,
               CASE WHEN i.EffectiveFrom = @PeriodFrom THEN @PeriodTo ELSE nx.LastDay END,
               d.StartTime, i.StartTime, d.EndTime, i.EndTime, d.CrossesMidnight, i.CrossesMidnight,
               d.BreakMinutes, i.BreakMinutes, d.GraceMinutes, i.GraceMinutes, i.Note
        FROM inserted i
        JOIN deleted d ON d.ShiftHoursId = i.ShiftHoursId
        OUTER APPLY (SELECT DATEADD(DAY, -1, MIN(h.EffectiveFrom)) AS LastDay
                     FROM attendance.SHIFT_HOURS h
                     WHERE h.ShiftId = i.ShiftId AND h.EffectiveFrom > i.EffectiveFrom
                       AND NOT (h.StartTime = i.StartTime AND h.EndTime = i.EndTime AND h.CrossesMidnight = i.CrossesMidnight
                                AND h.BreakMinutes = i.BreakMinutes AND ISNULL(h.GraceMinutes, -1) = ISNULL(i.GraceMinutes, -1))) nx
        WHERE d.StartTime <> i.StartTime OR d.EndTime <> i.EndTime OR d.CrossesMidnight <> i.CrossesMidnight
           OR d.BreakMinutes <> i.BreakMinutes OR ISNULL(d.GraceMinutes, -1) <> ISNULL(i.GraceMinutes, -1)
           OR d.EffectiveFrom <> i.EffectiveFrom OR d.ShiftId <> i.ShiftId;
    END
    ELSE
    BEGIN
        /* a version DELETED. After: the version now in force from its date (the one before it). A version that only
           repeated the one before it (usp_Shift_TidyHours) changed nothing when it went. */
        INSERT INTO attendance.SHIFT_CHANGE
            (ShiftId, ChangedAtUtc, ChangedByUserId, [Action], EffectiveFrom, EffectiveTo,
             OldStartTime, NewStartTime, OldEndTime, NewEndTime, OldCrossesMidnight, NewCrossesMidnight,
             OldBreakMinutes, NewBreakMinutes, OldGraceMinutes, NewGraceMinutes, Note)
        SELECT d.ShiftId, @Now, @Who, 'HoursRemoved', d.EffectiveFrom, nx.LastDay,
               d.StartTime, p.StartTime, d.EndTime, p.EndTime, d.CrossesMidnight, p.CrossesMidnight,
               d.BreakMinutes, p.BreakMinutes, d.GraceMinutes, p.GraceMinutes, d.Note
        FROM deleted d
        OUTER APPLY (SELECT TOP 1 h.ShiftHoursId, h.StartTime, h.EndTime, h.CrossesMidnight, h.BreakMinutes, h.GraceMinutes
                     FROM attendance.SHIFT_HOURS h
                     WHERE h.ShiftId = d.ShiftId AND h.EffectiveFrom < d.EffectiveFrom
                     ORDER BY h.EffectiveFrom DESC) p
        OUTER APPLY (SELECT DATEADD(DAY, -1, MIN(h.EffectiveFrom)) AS LastDay
                     FROM attendance.SHIFT_HOURS h
                     WHERE h.ShiftId = d.ShiftId AND h.EffectiveFrom > d.EffectiveFrom AND p.ShiftHoursId IS NOT NULL
                       AND NOT (h.StartTime = p.StartTime AND h.EndTime = p.EndTime AND h.CrossesMidnight = p.CrossesMidnight
                                AND h.BreakMinutes = p.BreakMinutes AND ISNULL(h.GraceMinutes, -1) = ISNULL(p.GraceMinutes, -1))) nx
        WHERE NOT (p.ShiftHoursId IS NOT NULL AND p.StartTime = d.StartTime AND p.EndTime = d.EndTime AND p.CrossesMidnight = d.CrossesMidnight
                   AND p.BreakMinutes = d.BreakMinutes AND ISNULL(p.GraceMinutes, -1) = ISNULL(d.GraceMinutes, -1));
    END
END;
GO

/* A rename, or switching a shift off or on. Only real changes: usp_Shift_Update writes Name and IsActive every time,
   and usp_Shift_SyncCurrent (every change, and the nightly job) writes only the hours - neither is logged here. */
CREATE OR ALTER TRIGGER attendance.tr_SHIFT_ChangeLog
ON attendance.SHIFT
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    /* script 122 */
    IF NOT (UPDATE(Name) OR UPDATE(IsActive)) RETURN;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    DECLARE @Who INT = TRY_CONVERT(INT, SESSION_CONTEXT(N'UserId'));
    DECLARE @Now DATETIME2(0) = SYSUTCDATETIME();

    INSERT INTO attendance.SHIFT_CHANGE (ShiftId, ChangedAtUtc, ChangedByUserId, [Action], OldName, NewName)
    SELECT i.ShiftId, @Now, @Who, 'Renamed', d.Name, i.Name
    FROM inserted i
    JOIN deleted d ON d.ShiftId = i.ShiftId
    WHERE ISNULL(d.Name, N'') COLLATE Latin1_General_BIN2 <> ISNULL(i.Name, N'') COLLATE Latin1_General_BIN2;

    INSERT INTO attendance.SHIFT_CHANGE (ShiftId, ChangedAtUtc, ChangedByUserId, [Action], NewName)
    SELECT i.ShiftId, @Now, @Who, CASE WHEN i.IsActive = 1 THEN 'Activated' ELSE 'Deactivated' END, i.Name
    FROM inserted i
    JOIN deleted d ON d.ShiftId = i.ShiftId
    WHERE ISNULL(d.IsActive, 0) <> ISNULL(i.IsActive, 0);
END;
GO

/* ---------------------------------------------------------------- 3. the days a change of hours touches (script 117's body, the failures counted) */
/* The days a change of hours touches are derived again: the days of [@From, @To] up to today that are rostered on the
   shift, and the days with no rostered shift (which shift their punch fits may change). A paid day is left alone by
   the writers themselves; a day HR entered by hand goes through its own writer. */
CREATE OR ALTER PROCEDURE attendance.usp_Shift_RederiveDays
    @ShiftId INT, @From DATE, @To DATE = NULL,
    @Days INT = NULL OUTPUT,
    @Failed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @Last DATE = CASE WHEN @To IS NULL OR @To > @Today THEN @Today ELSE @To END;
    SET @Days = 0;
    SET @Failed = 0;
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

    /* The change of hours is already saved when this runs. A day that cannot be derived (a manual entry now outside
       the employment, say) is left as it stands and does not fail the change: it is derived the next time something
       touches it. Only the days really derived are counted. script 122: the others are counted too (@Failed). */
    DECLARE @a BIGINT, @e INT, @d DATE, @m BIT, @rc INT, @Outer INT = @@TRANCOUNT;
    DECLARE sh_cur CURSOR LOCAL FAST_FORWARD FOR SELECT AttendanceId, EmployeeId, WorkDate, IsManual FROM @day ORDER BY WorkDate, EmployeeId;
    OPEN sh_cur; FETCH NEXT FROM sh_cur INTO @a, @e, @d, @m;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @rc = 0;
            IF @m = 1 EXEC @rc = attendance.usp_Attendance_RecomputeManualDay @AttendanceId = @a;
            ELSE      EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @e, @WorkDate = @d;
            IF ISNULL(@rc, 0) = 0 SET @Days = @Days + 1;
            ELSE SET @Failed = @Failed + 1;
        END TRY
        BEGIN CATCH
            /* the day's own transaction, if the writer left one open; a caller's transaction is the caller's */
            IF @Outer = 0 AND @@TRANCOUNT > 0 ROLLBACK TRAN;
            SET @Failed = @Failed + 1;
        END CATCH
        FETCH NEXT FROM sh_cur INTO @a, @e, @d, @m;
    END
    CLOSE sh_cur; DEALLOCATE sh_cur;

    /* script 122: the days left as they stood are SAID - to the caller (@Failed), to whoever reads the output, and in
       the shift's change log (the Shifts page shows it). Writing the log never fails the change. */
    IF @Failed > 0
    BEGIN
        DECLARE @Msg NVARCHAR(400) = CONCAT(@Failed, N' day(s) from ', CONVERT(CHAR(10), @From, 23), N' to ', CONVERT(CHAR(10), @Last, 23),
            N' could not be worked out again with the shift''s hours and keep their old figures. Re-derive them (Roster > Re-derive month) once the cause is fixed.');
        PRINT @Msg;
        IF XACT_STATE() <> -1
        BEGIN
            BEGIN TRY
                INSERT INTO attendance.SHIFT_CHANGE (ShiftId, ChangedByUserId, [Action], EffectiveFrom, EffectiveTo, DaysCount, Note)
                VALUES (@ShiftId, TRY_CONVERT(INT, SESSION_CONTEXT(N'UserId')), 'DaysNotRederived', @From, @Last, @Failed, @Msg);
            END TRY
            BEGIN CATCH
                PRINT N'The change log could not record the days that were not worked out again.';
            END CATCH
        END
    END
END;
GO

/* ---------------------------------------------------------------- 4. corrections: the overnight flag of THAT day (script 100's body) */
/* QA3 (ATT-10): a correction is checked when it is RAISED, against what approving it would write: the out time after
   the in time, a time on the work date (or the next day for a shift that crosses midnight), a known status,
   minutes not negative, a day inside the employment. It used to be accepted as typed and refused only at approval.
   script 122: whether the day's shift crosses midnight is read from the hours in force ON THAT DAY. */
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

    /* the times: on the work date, or the next day only when the day's shift crosses midnight - script 122: by the
       shift's hours in force on that day, not today's */
    DECLARE @Overnight BIT = ISNULL((SELECT TOP 1 h.CrossesMidnight FROM attendance.SHIFT_ASSIGNMENT sa
                                     CROSS APPLY attendance.fn_ShiftHoursOn(sa.ShiftId, sa.WorkDate) h
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

/* ---------------------------------------------------------------- 5. day reports: the overnight flag of THAT day (script 110's body) */
CREATE OR ALTER PROCEDURE attendance.usp_DayReport_Create
    @EmployeeId   INT,
    @WorkDate     DATE,
    @ClaimedIn    DATETIME2 = NULL,
    @ClaimedOut   DATETIME2 = NULL,
    @Message      NVARCHAR(400),
    @CallerUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @Hire DATE, @Term DATE, @Msg NVARCHAR(400), @rc INT;
    SET @Message = NULLIF(LTRIM(RTRIM(@Message)), N'');

    SELECT @Hire = HireDate, @Term = TerminationDate FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId AND IsDeleted = 0;
    IF @Hire IS NULL BEGIN RAISERROR('Employee not found.', 16, 1); RETURN 1; END
    IF attendance.fn_DayReportScope(@CallerUserId, @EmployeeId, @WorkDate, 1) = 0
    BEGIN RAISERROR('You can only report your own days, or the days of the branches you manage.', 16, 1); RETURN 1; END
    IF @Message IS NULL
    BEGIN RAISERROR('Say what is wrong with the day. HR reads it before deciding.', 16, 1); RETURN 1; END
    IF @WorkDate > @Today
    BEGIN RAISERROR('A day that has not happened yet cannot be reported.', 16, 1); RETURN 1; END
    IF @WorkDate < @Hire OR (@Term IS NOT NULL AND @WorkDate > @Term)
    BEGIN RAISERROR('This day is outside the employment.', 16, 1); RETURN 1; END
    EXEC @rc = payroll.usp_AssertPeriodOpen @EmployeeId, @WorkDate;
    IF @rc <> 0 RETURN 1;

    /* the times: on the work date, or the next morning for a shift that crosses midnight (the correction's own rule) -
       script 122: by the shift's hours in force on that day, not today's */
    DECLARE @Overnight BIT = ISNULL((SELECT TOP 1 h.CrossesMidnight FROM attendance.SHIFT_ASSIGNMENT sa
                                     CROSS APPLY attendance.fn_ShiftHoursOn(sa.ShiftId, sa.WorkDate) h
                                     WHERE sa.EmployeeId = @EmployeeId AND sa.WorkDate = @WorkDate AND sa.IsRestDay = 0), 0);
    DECLARE @LastDay DATE = CASE WHEN @Overnight = 1 THEN DATEADD(DAY, 1, @WorkDate) ELSE @WorkDate END;
    IF (@ClaimedIn IS NOT NULL AND CAST(@ClaimedIn AS DATE) NOT BETWEEN @WorkDate AND @LastDay)
       OR (@ClaimedOut IS NOT NULL AND CAST(@ClaimedOut AS DATE) NOT BETWEEN @WorkDate AND @LastDay)
    BEGIN
        SET @Msg = CASE WHEN @Overnight = 1
                        THEN CONCAT(N'The times must be on ', CONVERT(CHAR(10), @WorkDate, 23), N' or the next morning (the shift crosses midnight).')
                        ELSE CONCAT(N'The times must be on ', CONVERT(CHAR(10), @WorkDate, 23), N'.') END;
        RAISERROR('%s', 16, 1, @Msg); RETURN 1;
    END
    IF @ClaimedIn IS NOT NULL AND @ClaimedOut IS NOT NULL AND @ClaimedOut <= @ClaimedIn
    BEGIN RAISERROR('The time out must be after the time in.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM attendance.DAY_REPORT WHERE EmployeeId = @EmployeeId AND WorkDate = @WorkDate AND [Status] = 'Open')
    BEGIN RAISERROR('A report for this day is already waiting for HR. Withdraw it first to send a new one.', 16, 1); RETURN 1; END

    INSERT INTO attendance.DAY_REPORT (EmployeeId, WorkDate, ClaimedIn, ClaimedOut, [Message], ReportedByUserId)
    VALUES (@EmployeeId, @WorkDate, @ClaimedIn, @ClaimedOut, @Message, @CallerUserId);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS ReportId;
END;
GO

/* ---------------------------------------------------------------- 6. the log of one shift (the MARKER of this script) */
/* Newest first. ChangedOn is the Beirut date of the change; ChangedBy the person's name, else their user name. */
CREATE OR ALTER PROCEDURE attendance.usp_Shift_GetChanges
    @ShiftId INT
AS
BEGIN
    SET NOCOUNT ON;
    /* script 122 */
    SELECT c.ShiftChangeId, c.ShiftId, c.ChangedAtUtc,
           CAST(c.ChangedAtUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Middle East Standard Time' AS DATE) AS ChangedOn,
           c.ChangedByUserId, COALESCE(e.FullName, u.Username) AS ChangedBy,
           c.[Action], c.EffectiveFrom, c.EffectiveTo,
           c.OldStartTime, c.NewStartTime, c.OldEndTime, c.NewEndTime, c.OldCrossesMidnight, c.NewCrossesMidnight,
           c.OldBreakMinutes, c.NewBreakMinutes, c.OldGraceMinutes, c.NewGraceMinutes,
           c.OldName, c.NewName, c.DaysCount, c.Note
    FROM attendance.SHIFT_CHANGE c
    LEFT JOIN security.[USER] u ON u.UserId = c.ChangedByUserId
    OUTER APPLY (SELECT TOP 1 x.FullName FROM hr.EMPLOYEE x
                 WHERE x.UserId = c.ChangedByUserId AND x.IsDeleted = 0 ORDER BY x.EmployeeId) e
    WHERE c.ShiftId = @ShiftId
    ORDER BY c.ShiftChangeId DESC;
END;
GO

PRINT '122_shift_change_log.sql: every change to a shift is logged (attendance.SHIFT_CHANGE); corrections and day reports read the overnight flag of the day itself.';
GO

SET NOEXEC OFF;
GO
