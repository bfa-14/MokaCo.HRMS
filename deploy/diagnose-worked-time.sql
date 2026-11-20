/* ============================================================================
   deploy/diagnose-worked-time.sql - WHY DOES THE WORKED TIME REPORT SHOW 0? (read-only: it changes nothing)

   Run on the VM (sqlcmd asks for the password; never type it on the command line or paste it anywhere):
     sqlcmd -S 127.0.0.1 -U sa -C -W -s "|" -d MokaCo_HRMS -v FROM=2026-11-01 TO=2026-11-14 -i ~/src/MokaCo.HRMS/deploy/diagnose-worked-time.sql

   It prints, for the period:
     1. the settings that decide how punches become worked time
     2. per employee: hire date, mapped device PINs, punches (all / still unprocessed / In / Out / other keys /
        before the hire date), attendance days (all / with a first in / with worked time / worked minutes /
        missing punch) and days not on the roster
     3. punches on PINs mapped to nobody (they wait on Attendance > Unresolved PINs and count for nobody)
     4. the roster months of the period, per branch
     5. a sample of days: each punch with its key (0 = In, 1 = Out, other = another key) and the day built from them
   ============================================================================ */
SET NOCOUNT ON;
DECLARE @From DATE = '$(FROM)', @To DATE = '$(TO)';

PRINT '--- 1. settings';
SELECT SettingKey, SettingValue FROM core.SETTING
WHERE SettingKey IN ('PunchDirectionMode', 'PunchDebounceMinutes', 'StandardWorkDayHours', 'StandardWorkingDaysPerMonth',
                     'MachinePullAutoProcess', 'OvernightAttributionHours')
ORDER BY SettingKey;

PRINT '--- 2. per employee (Punches = all, Unproc = not processed yet, In/Out/Other = the key sent, BeforeHire = punched before the hire date; Days = attendance days, WithIn = with a first in, Worked = with worked time, Minutes = worked minutes, Missing = missing punch; NotOnRoster = punched days missing from an approved roster)';
SELECT e.EmployeeId AS Id, LEFT(e.FullName, 22) AS Employee, CONVERT(CHAR(10), e.HireDate, 23) AS Hired,
       CASE WHEN e.IsDeleted = 1 THEN 'removed' WHEN e.TerminationDate IS NOT NULL THEN CONVERT(CHAR(10), e.TerminationDate, 23) ELSE '' END AS Left_,
       (SELECT COUNT(*) FROM attendance.EMPLOYEE_DEVICE m WHERE m.EmployeeId = e.EmployeeId) AS Pins,
       p.Punches, p.Unproc, p.InKey, p.OutKey, p.Other, p.BeforeHire,
       a.Days, a.WithIn, a.Worked, a.Minutes, a.Missing,
       (SELECT COUNT(*) FROM attendance.fn_UnrosteredDays(@From, @To) u WHERE u.EmployeeId = e.EmployeeId AND u.IsDismissed = 0) AS NotOnRoster
FROM hr.EMPLOYEE e
OUTER APPLY (SELECT COUNT(*) AS Punches,
                    SUM(CASE WHEN q.IsProcessed = 0 THEN 1 ELSE 0 END) AS Unproc,
                    SUM(CASE WHEN q.PunchType = 0 THEN 1 ELSE 0 END) AS InKey,
                    SUM(CASE WHEN q.PunchType = 1 THEN 1 ELSE 0 END) AS OutKey,
                    SUM(CASE WHEN q.PunchType NOT IN (0, 1) OR q.PunchType IS NULL THEN 1 ELSE 0 END) AS Other,
                    SUM(q.BeforeHire) AS BeforeHire
             FROM (SELECT r.IsProcessed, r.PunchType,
                          CASE WHEN CAST(r.PunchTimeUtc AS DATE) < CAST(e.HireDate AS DATE) THEN 1 ELSE 0 END AS BeforeHire
                   FROM attendance.RAW_DEVICE_LOG r
                   WHERE r.EmployeeId = e.EmployeeId
                     AND r.PunchTimeUtc >= CAST(@From AS DATETIME2) AND r.PunchTimeUtc < CAST(DATEADD(DAY, 1, @To) AS DATETIME2)) q) p
OUTER APPLY (SELECT COUNT(*) AS Days,
                    SUM(CASE WHEN x.FirstInUtc IS NOT NULL THEN 1 ELSE 0 END) AS WithIn,
                    SUM(CASE WHEN x.WorkedMinutes > 0 THEN 1 ELSE 0 END) AS Worked,
                    ISNULL(SUM(x.WorkedMinutes), 0) AS Minutes,
                    SUM(CASE WHEN x.HasAnomaly = 1 THEN 1 ELSE 0 END) AS Missing
             FROM attendance.ATTENDANCE_RECORD x
             WHERE x.EmployeeId = e.EmployeeId AND x.WorkDate BETWEEN @From AND @To) a
WHERE e.IsDeleted = 0 OR p.Punches > 0
ORDER BY e.FullName;

PRINT '--- 3. punches on PINs mapped to nobody';
SELECT r.DeviceId, r.EnrollPin AS Pin, COUNT(*) AS Punches,
       CONVERT(CHAR(16), MIN(r.PunchTimeUtc), 120) AS First, CONVERT(CHAR(16), MAX(r.PunchTimeUtc), 120) AS Last
FROM attendance.RAW_DEVICE_LOG r
WHERE r.EmployeeId IS NULL
  AND r.PunchTimeUtc >= CAST(@From AS DATETIME2) AND r.PunchTimeUtc < CAST(DATEADD(DAY, 1, @To) AS DATETIME2)
GROUP BY r.DeviceId, r.EnrollPin
ORDER BY Punches DESC;

PRINT '--- 4. roster months of the period';
SELECT b.Name AS Branch, CONVERT(CHAR(7), rm.MonthDate, 120) AS Month, rm.[Status]
FROM attendance.ROSTER_MONTH rm JOIN hr.BRANCH b ON b.BranchId = rm.BranchId
WHERE rm.MonthDate BETWEEN DATEFROMPARTS(YEAR(@From), MONTH(@From), 1) AND @To
ORDER BY b.Name, rm.MonthDate;

PRINT '--- 5. a sample of days: the punches (time key) and the day built from them';
SELECT TOP 25 LEFT(e.FullName, 18) AS Employee, d.D AS Day,
       (SELECT STRING_AGG(CONCAT(CONVERT(CHAR(5), r2.PunchTimeUtc, 108), ' ', r2.PunchType), ', ') WITHIN GROUP (ORDER BY r2.PunchTimeUtc)
        FROM attendance.RAW_DEVICE_LOG r2
        WHERE r2.EmployeeId = d.EmployeeId AND CAST(r2.PunchTimeUtc AS DATE) = d.D) AS Punches,
       ISNULL(x.[Status], '(no day)') AS DayStatus, x.WorkedMinutes AS Minutes, x.HasAnomaly AS Missing
FROM (SELECT DISTINCT r.EmployeeId, CAST(r.PunchTimeUtc AS DATE) AS D
      FROM attendance.RAW_DEVICE_LOG r
      WHERE r.EmployeeId IS NOT NULL
        AND r.PunchTimeUtc >= CAST(@From AS DATETIME2) AND r.PunchTimeUtc < CAST(DATEADD(DAY, 1, @To) AS DATETIME2)) d
JOIN hr.EMPLOYEE e ON e.EmployeeId = d.EmployeeId
LEFT JOIN attendance.ATTENDANCE_RECORD x ON x.EmployeeId = d.EmployeeId AND x.WorkDate = d.D
ORDER BY d.D DESC, e.FullName;
