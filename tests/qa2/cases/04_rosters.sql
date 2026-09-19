/* ============================================================================
   cases/04_rosters.sql — A4: rosters. QA2 E1 (morning) and E2 (evening) in QA2 Branch 1, E12 (transferred to
   QA2 Branch 2 on the 16th of M). The roster months M-1 .. M+2 of both branches are Approved (seed).
   "Future" days are taken from the roster at run time: the first working days at least 3 days ahead.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO

/* ---------------------------------------------------------------- A4a: a future day of an approved month is edited ---- */
DECLARE @E2 INT = dbo.QA2_Emp(N'E2'), @Hr INT = dbo.QA2_User(N'hr'), @HrEmp INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA2 HR Officer');
DECLARE @B1 INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA2 Branch 1');
DECLARE @Morning INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'QA2 Morning'), @Evening INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'QA2 Evening');
DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
DECLARE @act NVARCHAR(700), @ok BIT, @err NVARCHAR(400), @t DATETIME2(0), @rid INT;
DECLARE @F DATE = (SELECT MIN(WorkDate) FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E2 AND IsRestDay = 0 AND WorkDate >= DATEADD(DAY, 3, @Today));
DECLARE @FMonth DATE = DATEFROMPARTS(YEAR(@F), MONTH(@F), 1);
DECLARE @rm TABLE (RosterMonthId INT, BranchId INT, MonthDate DATE, [Status] VARCHAR(20), ApprovedAt DATETIME2, RequestInstanceId INT, RequestStatus VARCHAR(20),
                   OpenRequestId INT, OpenRequestStatus VARCHAR(20), LastApprovedAt DATETIME2, ChangedSinceApproval BIT, LastChangedUtc DATETIME2);
INSERT INTO @rm EXEC attendance.usp_RosterMonth_Get @BranchId = @B1, @MonthDate = @FMonth;
DECLARE @before NVARCHAR(100) = (SELECT CONCAT([Status], ', changed=', ChangedSinceApproval) FROM @rm); DELETE FROM @rm;
WAITFOR DELAY '00:00:01';                                   -- the change must be later than the approval stamp of the seed
BEGIN TRY
    EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @E2, @WorkDate = @F, @ShiftId = @Morning, @IsRestDay = 0;    -- evening -> morning
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @err = ERROR_MESSAGE(); END CATCH;
INSERT INTO @rm EXEC attendance.usp_RosterMonth_Get @BranchId = @B1, @MonthDate = @FMonth;
DECLARE @after NVARCHAR(100) = (SELECT CONCAT([Status], ', changed=', ChangedSinceApproval) FROM @rm); DELETE FROM @rm;
/* "the next day": the employee works the NEW shift (07:00-15:00) and the day is derived */
SET @t = DATEADD(HOUR, 7, CAST(@F AS DATETIME2(0)));  EXEC dbo.QA2_Punch @E2, @t, 0;
SET @t = DATEADD(HOUR, 15, CAST(@F AS DATETIME2(0))); EXEC dbo.QA2_Punch @E2, @t, 1;
EXEC dbo.QA2_Process;
DECLARE @day NVARCHAR(200) = (SELECT CONCAT(a.[Status], ' fraction ', a.DayFraction, ' standard ', a.StandardMinutes, ' shift ', s.Name, ' anomalies ',
                                     ISNULL((SELECT STRING_AGG(CONCAT(an.[Type], ' ', an.[Minutes]), ',') FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId), 'none'))
                              FROM attendance.ATTENDANCE_RECORD a LEFT JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.ShiftAssignmentId = a.ShiftAssignmentId LEFT JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
                              WHERE a.EmployeeId = @E2 AND a.WorkDate = @F);
/* resubmit: a new request for the month */
DECLARE @resub NVARCHAR(200);
BEGIN TRY
    EXEC workflow.usp_RosterApproval_Create @EmployeeId = @HrEmp, @RaisedByUserId = @Hr, @BranchId = @B1, @MonthDate = @FMonth, @Title = N'QA2 A4a roster changed';
    SET @rid = (SELECT MAX(ra.RequestInstanceId) FROM workflow.ROSTER_APPROVAL ra WHERE ra.BranchId = @B1 AND ra.MonthDate = @FMonth);
    INSERT INTO @rm EXEC attendance.usp_RosterMonth_Get @BranchId = @B1, @MonthDate = @FMonth;
    SET @resub = (SELECT CONCAT('open request ', OpenRequestId, ' (', OpenRequestStatus, '), month ', [Status]) FROM @rm); DELETE FROM @rm;
    EXEC dbo.QA2_Approve @rid, 'Generic';
    INSERT INTO @rm EXEC attendance.usp_RosterMonth_Get @BranchId = @B1, @MonthDate = @FMonth;
    SET @resub = CONCAT(@resub, ' -> after approval: month ', (SELECT CONCAT([Status], ', request ', RequestInstanceId, ' ', RequestStatus, ', open=', ISNULL(CAST(OpenRequestId AS VARCHAR(10)), 'none'), ', changed=', ChangedSinceApproval) FROM @rm));
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @resub = CONCAT(@resub, ' | resubmit error: ', ERROR_MESSAGE()); END CATCH;
SET @act = CONCAT(ISNULL('edit: ' + @err + ' | ', ''), 'future day ', CONVERT(CHAR(10), @F, 23), ': month before ', @before, ' -> after the edit ', @after, ' | the day worked on the new shift: ', ISNULL(@day, 'no record'), ' | resubmitted: ', @resub);
SET @ok = CASE WHEN @err IS NULL AND @before = 'Approved, changed=0' AND @after = 'Approved, changed=1'
                AND @day LIKE 'Present fraction 1.00 standard 450 shift QA2 Morning anomalies none'
                AND EXISTS (SELECT 1 FROM @rm WHERE [Status] = 'Approved' AND RequestInstanceId = @rid AND RequestStatus = 'Approved' AND OpenRequestId IS NULL AND ChangedSinceApproval = 0) THEN 1 ELSE 0 END;
EXEC dbo.QA2_Check 'A4a', 'an approved month: HR edits a FUTURE day (evening -> morning), the day is then worked, and the month is resubmitted',
     'the edit is accepted; the month stays Approved and reports ChangedSinceApproval; processing uses the new shift (07:00-15:00 = full day, no anomaly); the new request supersedes: once approved it is the month''s request and the change flag is cleared', @act, @ok;
GO

/* ---------------------------------------------------------------- A4b: an approved swap, then one of the two is absent ---- */
DECLARE @E1 INT = dbo.QA2_Emp(N'E1'), @E2 INT = dbo.QA2_Emp(N'E2'), @Hr INT = dbo.QA2_User(N'hr');
DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
DECLARE @act NVARCHAR(700), @ok BIT, @err NVARCHAR(400), @t DATETIME2(0), @rid INT;
/* a future day both work, other than the one A4a used */
DECLARE @S DATE = (SELECT MIN(a.WorkDate) FROM attendance.SHIFT_ASSIGNMENT a JOIN attendance.SHIFT_ASSIGNMENT b ON b.WorkDate = a.WorkDate AND b.EmployeeId = @E2 AND b.IsRestDay = 0
                   JOIN attendance.SHIFT sb ON sb.ShiftId = b.ShiftId AND sb.Name = N'QA2 Evening'
                   WHERE a.EmployeeId = @E1 AND a.IsRestDay = 0 AND a.WorkDate >= DATEADD(DAY, 5, @Today));
BEGIN TRY
    EXEC workflow.usp_ShiftSwap_Create @EmployeeId = @E1, @RaisedByUserId = @Hr, @CounterpartEmployeeId = @E2, @RequesterDate = @S, @CounterpartDate = @S, @CounterpartHasAgreed = 1;
    SET @rid = dbo.QA2_LastRequest(@E1); EXEC dbo.QA2_Approve @rid, 'Swap';
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @err = ERROR_MESSAGE(); END CATCH;
DECLARE @roster NVARCHAR(200) = (SELECT STRING_AGG(CONCAT(e.FullName, '=', s.Name), ', ') WITHIN GROUP (ORDER BY e.FullName)
                                 FROM attendance.SHIFT_ASSIGNMENT sa JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
                                 WHERE sa.WorkDate = @S AND sa.EmployeeId IN (@E1, @E2));
/* the day comes: E2 works the MORNING shift he swapped into; E1 (now on the evening shift) does not come */
SET @t = DATEADD(HOUR, 7, CAST(@S AS DATETIME2(0)));  EXEC dbo.QA2_Punch @E2, @t, 0;
SET @t = DATEADD(HOUR, 15, CAST(@S AS DATETIME2(0))); EXEC dbo.QA2_Punch @E2, @t, 1;
EXEC dbo.QA2_Process;
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E1, @WorkDate = @S;
SELECT @act = CONCAT(ISNULL('swap: ' + @err + ' | ', ''), 'request ', (SELECT [Status] FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid), '; roster on ', CONVERT(CHAR(10), @S, 23), ': ', @roster,
       ' | E1 (absent): ', ISNULL((SELECT CONCAT(a.[Status], ' on ', s.Name, ', fraction ', a.DayFraction) FROM attendance.ATTENDANCE_RECORD a JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.ShiftAssignmentId = a.ShiftAssignmentId JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId WHERE a.EmployeeId = @E1 AND a.WorkDate = @S), 'no record'),
       ' | E2 (worked 07:00-15:00): ', ISNULL((SELECT CONCAT(a.[Status], ' on ', s.Name, ', fraction ', a.DayFraction, ', anomalies ', ISNULL((SELECT STRING_AGG(CONCAT(an.[Type], ' ', an.[Minutes]), ',') FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId), 'none'))
                                               FROM attendance.ATTENDANCE_RECORD a JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.ShiftAssignmentId = a.ShiftAssignmentId JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId WHERE a.EmployeeId = @E2 AND a.WorkDate = @S), 'no record'));
SET @ok = CASE WHEN @err IS NULL AND @roster = N'QA2 E1=QA2 Evening, QA2 E2=QA2 Morning'
                AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.ShiftAssignmentId = a.ShiftAssignmentId JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
                            WHERE a.EmployeeId = @E1 AND a.WorkDate = @S AND a.[Status] = 'Absent' AND s.Name = N'QA2 Evening')
                AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E2 AND a.WorkDate = @S AND a.[Status] = 'Present' AND a.DayFraction = 1.00
                                   AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId)) THEN 1 ELSE 0 END;
EXEC dbo.QA2_Check 'A4b', 'a shift swap (E1 morning <-> E2 evening, same future date) is approved; on the day E2 works the morning and E1 does not come',
     'the roster carries the swapped shifts; E1''s absence is on the EVENING shift he swapped into (not the morning one he gave away); E2 is measured against the morning shift: full day, no anomaly', @act, @ok;
GO

/* ---------------------------------------------------------------- A4c: transfer to branch 2 on the 16th (D7) ---- */
DECLARE @E12 INT = dbo.QA2_Emp(N'E12'), @Hr INT = dbo.QA2_User(N'hr');
DECLARE @B1 INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA2 Branch 1'), @B2 INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA2 Branch 2');
DECLARE @M DATE = CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month') + '-01' AS DATE);
DECLARE @The16 DATE = DATEADD(DAY, 15, @M), @MEnd DATE = EOMONTH(@M), @MChar CHAR(7) = CONVERT(CHAR(7), @M, 23);
DECLARE @act NVARCHAR(700), @ok BIT, @err NVARCHAR(400);
/* the whole month is derived while E12 is still in branch 1 — the transfer must move the days from the 16th, not these */
EXEC dbo.QA2_ComputeRange @E12, @M, @MEnd;
DECLARE @dep INT, @pos INT, @name NVARCHAR(150), @hire DATE;
SELECT @dep = DepartmentId, @pos = PositionId, @name = FullName, @hire = HireDate FROM hr.EMPLOYEE WHERE EmployeeId = @E12;
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('hr.usp_Employee_Update') AND name = '@BranchEffectiveFrom')
BEGIN TRY
    EXEC hr.usp_Employee_Update @EmployeeId = @E12, @BranchId = @B2, @DepartmentId = @dep, @PositionId = @pos, @FullName = @name, @HireDate = @hire, @ModifiedBy = @Hr, @BranchEffectiveFrom = @The16;
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @err = ERROR_MESSAGE(); END CATCH;
ELSE
BEGIN
    SET @err = 'usp_Employee_Update has no @BranchEffectiveFrom parameter (the branch is simply overwritten)';
    EXEC hr.usp_Employee_Update @EmployeeId = @E12, @BranchId = @B2, @DepartmentId = @dep, @PositionId = @pos, @FullName = @name, @HireDate = @hire, @ModifiedBy = @Hr;
    EXEC dbo.QA2_ComputeRange @E12, @M, @MEnd;
END
DECLARE @hist NVARCHAR(300) = NULL;
IF OBJECT_ID('hr.EMPLOYEE_BRANCH_HISTORY') IS NOT NULL
    SET @hist = (SELECT STRING_AGG(CONCAT(b.Name, ' from ', CONVERT(CHAR(10), h.EffectiveFrom, 23)), '; ') WITHIN GROUP (ORDER BY h.EffectiveFrom)
                 FROM hr.EMPLOYEE_BRANCH_HISTORY h JOIN hr.BRANCH b ON b.BranchId = h.BranchId WHERE h.EmployeeId = @E12);
/* the roster of each branch for the month */
DECLARE @r1 INT = NULL, @r1bad INT = NULL, @r2 INT = NULL, @r2bad INT = NULL;
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('attendance.usp_ShiftAssignment_GetByDateRange') AND name = '@BranchId')
BEGIN
    DECLARE @ro TABLE (ShiftAssignmentId INT, EmployeeId INT, FullName NVARCHAR(150), ShiftId INT, ShiftName NVARCHAR(100), StartTime TIME, EndTime TIME, WorkDate DATE, IsRestDay BIT, BranchId INT);
    INSERT INTO @ro EXEC attendance.usp_ShiftAssignment_GetByDateRange @FromDate = @M, @ToDate = @MEnd, @EmployeeId = @E12, @BranchId = @B1;
    SELECT @r1 = COUNT(*), @r1bad = SUM(CASE WHEN WorkDate >= @The16 THEN 1 ELSE 0 END) FROM @ro; DELETE FROM @ro;
    INSERT INTO @ro EXEC attendance.usp_ShiftAssignment_GetByDateRange @FromDate = @M, @ToDate = @MEnd, @EmployeeId = @E12, @BranchId = @B2;
    SELECT @r2 = COUNT(*), @r2bad = SUM(CASE WHEN WorkDate < @The16 THEN 1 ELSE 0 END) FROM @ro;
END
/* attendance by branch */
DECLARE @att NVARCHAR(300) = (SELECT STRING_AGG(CONCAT(x.BranchName, ': ', x.n, ' day(s) ', CONVERT(CHAR(5), x.f, 110), '..', CONVERT(CHAR(5), x.l, 110)), '; ') WITHIN GROUP (ORDER BY x.f)
                              FROM (SELECT b.Name AS BranchName, COUNT(*) n, MIN(a.WorkDate) f, MAX(a.WorkDate) l FROM attendance.ATTENDANCE_RECORD a JOIN hr.BRANCH b ON b.BranchId = a.BranchId
                                    WHERE a.EmployeeId = @E12 AND a.WorkDate BETWEEN @M AND @MEnd GROUP BY b.Name) x);
DECLARE @rep TABLE (EmployeeId INT, FullName NVARCHAR(150), BranchId INT, BranchName NVARCHAR(100), Days INT, DaysWorked DECIMAL(9,2), WorkedMinutes INT, OvertimeMinutes INT);
INSERT INTO @rep EXEC attendance.usp_Attendance_MonthlyByBranch @PeriodYearMonth = @MChar, @EmployeeId = @E12;
DECLARE @report NVARCHAR(200) = (SELECT STRING_AGG(CONCAT(BranchName, ' ', Days, ' day(s)'), '; ') WITHIN GROUP (ORDER BY BranchName) FROM @rep);
DECLARE @holiday NVARCHAR(60) = (SELECT TOP 1 CONCAT(CONVERT(CHAR(10), a.WorkDate, 23), ' ', a.[Status]) FROM attendance.ATTENDANCE_RECORD a
                                 WHERE a.EmployeeId = @E12 AND EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID('core.HOLIDAY'))
                                   AND a.WorkDate = DATEADD(DAY, 1, (SELECT TOP 1 WorkDate FROM dbo.QA2_DAY WHERE CaseId = 'A3c')));
SET @act = CONCAT(ISNULL(@err + ' | ', ''), 'history: ', ISNULL(@hist, 'none'), ' | current branch: ', (SELECT b.Name FROM hr.EMPLOYEE e JOIN hr.BRANCH b ON b.BranchId = e.BranchId WHERE e.EmployeeId = @E12),
                  ' | roster read by branch: B1 ', ISNULL(CAST(@r1 AS VARCHAR(10)), 'n/a'), ' row(s) (', ISNULL(@r1bad, -1), ' on/after the 16th), B2 ', ISNULL(CAST(@r2 AS VARCHAR(10)), 'n/a'), ' row(s) (', ISNULL(@r2bad, -1), ' before the 16th)',
                  ' | attendance: ', @att, ' | monthly report by branch: ', @report, ' | branch-2 holiday: ', ISNULL(@holiday, 'n/a'));
SET @ok = CASE WHEN @err IS NULL AND @hist LIKE N'QA2 Branch 1 from %; QA2 Branch 2 from ' + CONVERT(CHAR(10), @The16, 23)
                AND @r1 > 0 AND @r1bad = 0 AND @r2 > 0 AND @r2bad = 0
                AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E12 AND a.WorkDate BETWEEN @M AND @MEnd
                                  AND a.BranchId <> CASE WHEN a.WorkDate < @The16 THEN @B1 ELSE @B2 END)
                AND (SELECT COUNT(*) FROM @rep) = 2 AND @holiday LIKE '% Holiday' THEN 1 ELSE 0 END;
EXEC dbo.QA2_Check 'A4c', 'E12 is transferred from QA2 Branch 1 to QA2 Branch 2 with effect from the 16th of M (the month was already processed)',
     'a history row from the 16th; the branch-1 roster keeps the days up to the 15th and the branch-2 roster has the days from the 16th; attendance and the monthly report by branch split on that date (the days before it are not rewritten); the branch-2 holiday applies to E12, who was there by then', @act, @ok;
GO

/* ---------------------------------------------------------------- A4d: roster copy into a month that has a holiday ---- */
DECLARE @E2 INT = dbo.QA2_Emp(N'E2'), @Hr INT = dbo.QA2_User(N'hr'), @B1 INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA2 Branch 1');
DECLARE @M DATE = CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month') + '-01' AS DATE);
DECLARE @T DATE = DATEADD(MONTH, 3, @M), @Src CHAR(7) = CONVERT(CHAR(7), @M, 23), @Tgt CHAR(7) = CONVERT(CHAR(7), DATEADD(MONTH, 3, @M), 23);
DECLARE @act NVARCHAR(700), @ok BIT, @err NVARCHAR(400);
/* a holiday of the branch on the second Tuesday of the target month (a working day of E2's pattern) */
DECLARE @H DATE = @T; WHILE DATEDIFF(DAY, '19000102', @H) % 7 <> 0 SET @H = DATEADD(DAY, 1, @H); SET @H = DATEADD(DAY, 7, @H);
IF OBJECT_ID('core.usp_Holiday_Upsert') IS NOT NULL
BEGIN TRY
    EXEC core.usp_Holiday_Upsert @HolidayId = NULL, @HolidayDate = @H, @Name = N'QA2 Copy Holiday', @NameAr = NULL, @IsPaid = 1, @BranchId = @B1, @ActedByUserId = @Hr;
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @err = ERROR_MESSAGE(); END CATCH;
DECLARE @c TABLE (RowsInserted INT);
BEGIN TRY
    INSERT INTO @c EXEC attendance.usp_ShiftAssignment_CopyPeriod @SourceYearMonth = @Src, @TargetYearMonth = @Tgt, @EmployeeId = @E2, @Overwrite = 0;
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @err = CONCAT(@err, ' copy: ', ERROR_MESSAGE()); END CATCH;
DECLARE @rows INT = (SELECT COUNT(*) FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E2 AND WorkDate BETWEEN @T AND EOMONTH(@T));
DECLARE @onHoliday NVARCHAR(100) = ISNULL((SELECT CONCAT('shift ', ISNULL(s.Name, 'none'), ', rest=', sa.IsRestDay) FROM attendance.SHIFT_ASSIGNMENT sa LEFT JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId WHERE sa.EmployeeId = @E2 AND sa.WorkDate = @H), 'no row');
DECLARE @sameWeekdayElsewhere INT = (SELECT COUNT(*) FROM attendance.SHIFT_ASSIGNMENT sa WHERE sa.EmployeeId = @E2 AND sa.WorkDate BETWEEN @T AND EOMONTH(@T) AND sa.WorkDate <> @H
                                       AND DATEDIFF(DAY, '19000102', sa.WorkDate) % 7 = 0 AND sa.IsRestDay = 0 AND sa.ShiftId IS NOT NULL);
/* and what attendance makes of that day, with nobody punching */
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E2, @WorkDate = @H;
DECLARE @dayStatus NVARCHAR(40) = ISNULL((SELECT [Status] FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E2 AND WorkDate = @H), 'no record');
SET @act = CONCAT(ISNULL(@err + ' | ', ''), 'copied ', @Src, ' -> ', @Tgt, ': ', @rows, ' roster row(s); on the holiday ', CONVERT(CHAR(10), @H, 23), ': ', @onHoliday, '; the other Tuesdays with a working shift: ', @sameWeekdayElsewhere,
                  '; attendance of the holiday with no punch: ', @dayStatus);
SET @ok = CASE WHEN @err IS NULL AND @rows > 20 AND @sameWeekdayElsewhere >= 3 AND @onHoliday = 'no row' AND @dayStatus IN ('no record', 'Holiday') THEN 1 ELSE 0 END;
EXEC dbo.QA2_Check 'A4d', 'the roster of M is copied into a month that has a public holiday of the branch on a Tuesday',
     'the other Tuesdays get E2''s shift; the holiday is kept as a holiday — no working shift is rostered on it — and it can never read as an absence', @act, @ok;
GO
