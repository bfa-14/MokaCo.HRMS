/* ============================================================================
   110_day_reports.sql - "SOMETHING IS WRONG WITH THIS DAY": THE PERSON WHO KNOWS SAYS SO, HR ACCEPTS IN ONE CLICK.

   The employee (their own days) or their branch manager (the days of the branches they manage) reports the real
   times of a day - "I left at 23:00, I forgot to punch out" - with a message. HR sees the reports in one queue
   (Attendance > Anomalies > Reported days) beside what the day says now, and:
     Accept  the API raises a correction with the reported times (requested by the person who reported, the reason
             naming the report) and approves it, then marks the report Accepted - one transaction. The correction is
             the ordinary one (attendance.usp_Correction_Create / _Approve): logged old-to-new, the machine's punches
             kept, the day re-derived, a missing-punch anomaly answered.
     Reject  with a note the reporter reads.
   The reporter may withdraw an open report. Nothing changes pay until HR accepts.

   attendance.DAY_REPORT                    one row per report (history kept; one OPEN report per employee-day)
   attendance.usp_DayReport_Create          @EmployeeId, @WorkDate, @ClaimedIn, @ClaimedOut, @Message, @CallerUserId
   attendance.usp_DayReport_GetList         @Scope 'Mine' (about me or by me) | 'Queue' (what this caller may decide)
   attendance.usp_DayReport_Get             @ReportId: one report, for the accept path
   attendance.usp_DayReport_Withdraw        @ReportId, @CallerUserId (the reporter, while open)
   attendance.usp_DayReport_Decide          @ReportId, @Accept, @Note, @CorrectionId, @CallerUserId - the MARKER

   Who may decide: the API asks ATTENDANCE_CORRECT; the procedure adds the branch scope (EMP_VIEW_ALL, or the branch
   of the day is one the caller manages) and that nobody decides a report about their own day.
   Every refusal is RAISERROR(msg, 16, 1) + RETURN 1; the API maps "You can only ..." / "Somebody else ..." to 403 and
   "This report is no longer open" / "already waiting" to 409.

   Needs: 87 (hr.fn_CallerScope), 100 (corrections as QA3 left them), 83 (payroll.usp_AssertPeriodOpen). Idempotent.
   Apply: sqlcmd -C -I -b -d <database> -i docs/110_day_reports.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('hr.fn_CallerScope') IS NULL OR OBJECT_ID('attendance.usp_Correction_Approve') IS NULL
   OR OBJECT_ID('payroll.usp_AssertPeriodOpen') IS NULL OR OBJECT_ID('hr.fn_EmployeeBranchOn') IS NULL
BEGIN RAISERROR('110_day_reports.sql needs scripts 83, 87, 100 and 103 (payroll.usp_AssertPeriodOpen, hr.fn_CallerScope, attendance.usp_Correction_Approve, hr.fn_EmployeeBranchOn). Nothing was applied.', 16, 1); SET NOEXEC ON; END
GO

/* ------------------------- 1. the table ------------------------- */
IF OBJECT_ID('attendance.DAY_REPORT') IS NULL
BEGIN
    CREATE TABLE attendance.DAY_REPORT
    (
        ReportId          INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_DAY_REPORT PRIMARY KEY,
        EmployeeId        INT NOT NULL CONSTRAINT FK_DAY_REPORT_Employee REFERENCES hr.EMPLOYEE (EmployeeId),
        WorkDate          DATE NOT NULL,
        ClaimedIn         DATETIME2 NULL,      -- the terminal's wall clock, like every punch
        ClaimedOut        DATETIME2 NULL,
        [Message]         NVARCHAR(400) NOT NULL,
        ReportedByUserId  INT NOT NULL,
        ReportedAtUtc     DATETIME2 NOT NULL CONSTRAINT DF_DAY_REPORT_At DEFAULT SYSUTCDATETIME(),
        [Status]          VARCHAR(12) NOT NULL CONSTRAINT DF_DAY_REPORT_Status DEFAULT 'Open'
                          CONSTRAINT CK_DAY_REPORT_Status CHECK ([Status] IN ('Open', 'Accepted', 'Rejected', 'Withdrawn')),
        DecidedByUserId   INT NULL,
        DecidedAtUtc      DATETIME2 NULL,
        DecisionNote      NVARCHAR(400) NULL,
        CorrectionId      INT NULL
    );
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_DAY_REPORT_OpenDay' AND object_id = OBJECT_ID('attendance.DAY_REPORT'))
    CREATE UNIQUE INDEX UX_DAY_REPORT_OpenDay ON attendance.DAY_REPORT (EmployeeId, WorkDate) WHERE [Status] = 'Open';
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DAY_REPORT_Status' AND object_id = OBJECT_ID('attendance.DAY_REPORT'))
    CREATE INDEX IX_DAY_REPORT_Status ON attendance.DAY_REPORT ([Status], WorkDate);
GO

/* ------------------------- 2. may this caller act on this employee-day? -------------------------
   1 when the caller sees every branch (EMP_VIEW_ALL), manages the branch of the day, or (@OwnDayCounts = 1) the day
   is the caller's own. A NULL caller is the system itself. */
CREATE OR ALTER FUNCTION attendance.fn_DayReportScope (@CallerUserId INT, @EmployeeId INT, @WorkDate DATE, @OwnDayCounts BIT)
RETURNS BIT
AS
BEGIN
    IF @CallerUserId IS NULL RETURN 1;
    DECLARE @SeesAll BIT, @Me INT;
    SELECT @SeesAll = SeesAll, @Me = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    IF @SeesAll = 1 RETURN 1;
    IF @OwnDayCounts = 1 AND @Me = @EmployeeId RETURN 1;
    IF @Me IS NOT NULL AND EXISTS (SELECT 1 FROM hr.BRANCH b
                                   WHERE b.BranchId = hr.fn_EmployeeBranchOn(@EmployeeId, @WorkDate) AND b.ManagerEmployeeId = @Me)
        RETURN 1;
    RETURN 0;
END;
GO

/* ------------------------- 3. report a day ------------------------- */
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

    /* the times: on the work date, or the next morning for a shift that crosses midnight (the correction's own rule) */
    DECLARE @Overnight BIT = ISNULL((SELECT TOP 1 s.CrossesMidnight FROM attendance.SHIFT_ASSIGNMENT sa
                                     JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
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

/* ------------------------- 4. the lists -------------------------
   'Mine'  : reports about the caller's own days or sent by the caller (any status)
   'Queue' : reports this caller may decide (scope; never their own days), @Status NULL = every status */
CREATE OR ALTER PROCEDURE attendance.usp_DayReport_GetList
    @Scope        VARCHAR(10) = 'Queue',
    @Status       VARCHAR(12) = NULL,
    @FromDate     DATE = NULL,
    @ToDate       DATE = NULL,
    @CallerUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Me INT = (SELECT CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId));
    SELECT r.ReportId, r.EmployeeId, e.FullName AS EmployeeName, b.BranchId, b.Name AS BranchName, r.WorkDate,
           r.ClaimedIn, r.ClaimedOut, r.[Message], r.ReportedByUserId,
           COALESCE(re.FullName, ru.Username) AS ReportedBy, r.ReportedAtUtc, r.[Status],
           COALESCE(de.FullName, du.Username) AS DecidedBy, r.DecidedAtUtc, r.DecisionNote, r.CorrectionId,
           a.AttendanceId, a.FirstInUtc AS CurrentFirstIn, a.LastOutUtc AS CurrentLastOut, a.[Status] AS CurrentStatus,
           a.WorkedMinutes AS CurrentWorkedMinutes, ISNULL(a.HasAnomaly, 0) AS CurrentHasAnomaly,
           CAST(CASE WHEN r.EmployeeId = @Me THEN 1 ELSE 0 END AS BIT) AS IsAboutMe,
           CAST(CASE WHEN r.[Status] = 'Open' AND r.EmployeeId <> ISNULL(@Me, -1)
                      AND attendance.fn_DayReportScope(@CallerUserId, r.EmployeeId, r.WorkDate, 0) = 1 THEN 1 ELSE 0 END AS BIT) AS CanDecide
    FROM attendance.DAY_REPORT r
    JOIN hr.EMPLOYEE e ON e.EmployeeId = r.EmployeeId
    LEFT JOIN hr.BRANCH b ON b.BranchId = hr.fn_EmployeeBranchOn(r.EmployeeId, r.WorkDate)
    LEFT JOIN security.[USER] ru ON ru.UserId = r.ReportedByUserId
    LEFT JOIN hr.EMPLOYEE re ON re.UserId = r.ReportedByUserId AND re.IsDeleted = 0
    LEFT JOIN security.[USER] du ON du.UserId = r.DecidedByUserId
    LEFT JOIN hr.EMPLOYEE de ON de.UserId = r.DecidedByUserId AND de.IsDeleted = 0
    LEFT JOIN attendance.ATTENDANCE_RECORD a ON a.EmployeeId = r.EmployeeId AND a.WorkDate = r.WorkDate
    WHERE (@Status IS NULL OR r.[Status] = @Status)
      AND (@FromDate IS NULL OR r.WorkDate >= @FromDate)
      AND (@ToDate IS NULL OR r.WorkDate <= @ToDate)
      AND (   (@Scope = 'Mine' AND (r.EmployeeId = @Me OR r.ReportedByUserId = @CallerUserId))
           OR (@Scope = 'Queue' AND r.EmployeeId <> ISNULL(@Me, -1)
               AND attendance.fn_DayReportScope(@CallerUserId, r.EmployeeId, r.WorkDate, 0) = 1))
    ORDER BY CASE WHEN r.[Status] = 'Open' THEN 0 ELSE 1 END, r.WorkDate DESC, r.ReportId DESC;
END;
GO

/* ------------------------- 5. one report (the accept path reads it first) ------------------------- */
CREATE OR ALTER PROCEDURE attendance.usp_DayReport_Get
    @ReportId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.ReportId, r.EmployeeId, r.WorkDate, r.ClaimedIn, r.ClaimedOut, r.[Message], r.ReportedByUserId, r.[Status],
           a.AttendanceId, COALESCE(re.FullName, ru.Username) AS ReportedBy
    FROM attendance.DAY_REPORT r
    LEFT JOIN attendance.ATTENDANCE_RECORD a ON a.EmployeeId = r.EmployeeId AND a.WorkDate = r.WorkDate
    LEFT JOIN security.[USER] ru ON ru.UserId = r.ReportedByUserId
    LEFT JOIN hr.EMPLOYEE re ON re.UserId = r.ReportedByUserId AND re.IsDeleted = 0
    WHERE r.ReportId = @ReportId;
END;
GO

/* ------------------------- 6. withdraw (the reporter, while open) ------------------------- */
CREATE OR ALTER PROCEDURE attendance.usp_DayReport_Withdraw
    @ReportId     INT,
    @CallerUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @By INT, @Status VARCHAR(12);
    SELECT @By = ReportedByUserId, @Status = [Status] FROM attendance.DAY_REPORT WHERE ReportId = @ReportId;
    IF @Status IS NULL BEGIN RAISERROR('Report not found.', 16, 1); RETURN 1; END
    IF @By <> @CallerUserId BEGIN RAISERROR('You can only withdraw a report you sent.', 16, 1); RETURN 1; END
    IF @Status <> 'Open' BEGIN RAISERROR('This report is no longer open: HR has decided it.', 16, 1); RETURN 1; END
    UPDATE attendance.DAY_REPORT SET [Status] = 'Withdrawn', DecidedByUserId = @CallerUserId, DecidedAtUtc = SYSUTCDATETIME()
    WHERE ReportId = @ReportId AND [Status] = 'Open';
    SELECT @ReportId AS ReportId, CAST('Withdrawn' AS VARCHAR(12)) AS [Status];
END;
GO

/* ------------------------- 7. decide (the MARKER of this script) -------------------------
   Accept: @CorrectionId is the correction the API raised and approved, in the same transaction, for this report's day.
   Reject: a note is required (the reporter reads it). */
CREATE OR ALTER PROCEDURE attendance.usp_DayReport_Decide
    @ReportId     INT,
    @Accept       BIT,
    @Note         NVARCHAR(400) = NULL,
    @CorrectionId INT = NULL,
    @CallerUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Emp INT, @Day DATE, @Status VARCHAR(12), @Me INT = (SELECT CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId));
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');
    SELECT @Emp = EmployeeId, @Day = WorkDate, @Status = [Status] FROM attendance.DAY_REPORT WITH (UPDLOCK, HOLDLOCK) WHERE ReportId = @ReportId;
    IF @Status IS NULL BEGIN RAISERROR('Report not found.', 16, 1); RETURN 1; END
    IF @Status <> 'Open' BEGIN RAISERROR('This report is no longer open. Reload the list.', 16, 1); RETURN 1; END
    IF @Me = @Emp BEGIN RAISERROR('Somebody else decides a report about your own day.', 16, 1); RETURN 1; END
    IF attendance.fn_DayReportScope(@CallerUserId, @Emp, @Day, 0) = 0
    BEGIN RAISERROR('You can only decide reports of the branches you manage.', 16, 1); RETURN 1; END
    IF @Accept = 0 AND @Note IS NULL
    BEGIN RAISERROR('Say why the report is rejected. The person who reported reads it.', 16, 1); RETURN 1; END
    IF @Accept = 1 AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_CORRECTION c
                                   JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = c.AttendanceId
                                   WHERE c.CorrectionId = @CorrectionId AND c.ApprovalStatus = 'Approved'
                                     AND a.EmployeeId = @Emp AND a.WorkDate = @Day)
    BEGIN RAISERROR('Accepting a report needs the approved correction of that day.', 16, 1); RETURN 1; END

    UPDATE attendance.DAY_REPORT
    SET [Status] = CASE WHEN @Accept = 1 THEN 'Accepted' ELSE 'Rejected' END,
        DecidedByUserId = @CallerUserId, DecidedAtUtc = SYSUTCDATETIME(), DecisionNote = @Note,
        CorrectionId = CASE WHEN @Accept = 1 THEN @CorrectionId END
    WHERE ReportId = @ReportId AND [Status] = 'Open';
    SELECT @ReportId AS ReportId, CAST(CASE WHEN @Accept = 1 THEN 'Accepted' ELSE 'Rejected' END AS VARCHAR(12)) AS [Status], @CorrectionId AS CorrectionId;
END;
GO

PRINT '110_day_reports.sql: a day can be reported to HR, and accepted (as an approved correction) or rejected - in place.';
GO

SET NOEXEC OFF;
GO
