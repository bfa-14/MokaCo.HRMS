/* ============================================================================
   114_worked_time_punch_days.sql - THE WORKED TIME REPORT COUNTS EVERY PUNCHED DAY, ON THE ROSTER OR NOT.

   The report (script 113) reads worked time from the attendance days. One kind of punched day has none: a day of a
   month whose roster is APPROVED but that is missing from it (script 108, "not on roster") - the processor leaves it
   for HR or the branch manager to decide. Its only figure so far was the first-to-last punch span, breaks included.
   So the report showed those days apart and left them out of the totals: in a branch whose roster is approved but
   incomplete, the report depended on the roster after all.

   report.usp_Report_WorkedTime_PunchDays @From, @To, @EmployeeId NULL
     one row per not-on-roster day of the period that is not dismissed (a dismissed day is one somebody decided was
     not work): EmployeeId, WorkDate, BranchId, FirstIn, LastOut, PunchCount (after double presses are removed),
     WorkedMinutes and MissingPunch - measured EXACTLY as attendance.usp_Attendance_ComputeDay measures a day with no
     shift (docs/100): the punches attributed to the day (fn_AttributedWorkDate), repeats within PunchDebounceMinutes
     dropped, direction by PunchDirectionMode ('Alternate' = in, out, in, out; 'Device' = the terminal's key), each
     opening In paired with the next Out, worked = last out - first in - the gaps between the pairs (never below 0),
     a missing punch when the ins and outs do not pair. So such a day counts the same as it will once it is decided.
   Read-only.

   Idempotent. Apply: sqlcmd -C -I -b -d <database> -i docs/114_worked_time_punch_days.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('report.usp_Report_WorkedTime_Days') IS NULL OR OBJECT_ID('attendance.fn_UnrosteredDays') IS NULL
   OR OBJECT_ID('attendance.fn_AttributedWorkDate') IS NULL
BEGIN RAISERROR('114_worked_time_punch_days.sql: apply scripts 108 and 113 first (attendance.fn_UnrosteredDays, report.usp_Report_WorkedTime_Days, attendance.fn_AttributedWorkDate). Nothing was applied.', 16, 1); SET NOEXEC ON; END
GO

CREATE OR ALTER PROCEDURE report.usp_Report_WorkedTime_PunchDays
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

    SELECT d.EmployeeId, d.WorkDate, d.BranchId, a.FirstIn, a.LastOut, ISNULL(a.PunchCount, 0) AS PunchCount,
           CASE WHEN a.FirstIn IS NULL OR a.LastOut IS NULL THEN 0
                WHEN DATEDIFF(MINUTE, a.FirstIn, a.LastOut) - ISNULL(gp.Gap, 0) > 0 THEN DATEDIFF(MINUTE, a.FirstIn, a.LastOut) - ISNULL(gp.Gap, 0)
                ELSE 0 END AS WorkedMinutes,
           CAST(CASE WHEN a.InCount <> a.OutCount OR a.FirstIn IS NULL OR a.LastOut IS NULL THEN 1 ELSE 0 END AS BIT) AS MissingPunch
    FROM @days d
    OUTER APPLY (SELECT MIN(CASE WHEN p.EffType = 0 THEN p.PunchTimeUtc END) AS FirstIn,
                        MAX(CASE WHEN p.EffType = 1 THEN p.PunchTimeUtc END) AS LastOut,
                        SUM(CASE WHEN p.EffType = 0 THEN 1 ELSE 0 END) AS InCount,
                        SUM(CASE WHEN p.EffType = 1 THEN 1 ELSE 0 END) AS OutCount,
                        COUNT(*) AS PunchCount
                 FROM @punch p WHERE p.EmployeeId = d.EmployeeId AND p.WorkDate = d.WorkDate) a
    OUTER APPLY (SELECT SUM(v.GapAfterMins) AS Gap FROM @ivl v WHERE v.EmployeeId = d.EmployeeId AND v.WorkDate = d.WorkDate) gp
    ORDER BY d.EmployeeId, d.WorkDate;
END;
GO

PRINT '114_worked_time_punch_days.sql: report.usp_Report_WorkedTime_PunchDays - in place.';
GO

SET NOEXEC OFF;
GO
