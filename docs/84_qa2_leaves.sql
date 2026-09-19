/* ============================================================================
   84_qa2_leaves.sql — the leave fixes and features of the QA2 scenario suite (tests/qa2, cases A3). Needs 82 and 83.

   D2  WHAT A LEAVE COSTS = the employee's WORKING days in the range (hr.fn_LeaveWorkingDays): a rest day of their roster
       costs nothing (setting LeaveCountsRestDays = 0; 1 = every calendar day), a public holiday of their branch never
       does, a day with no roster row counts as a working day. The request stores that figure, its title says
       "N working days", and the ledger is posted with it. A type with a FIXED entitlement (maternity: 70 days) is a
       span of the calendar and keeps counting calendar days. Attendance still marks EVERY calendar day of the leave.
   D3  HALF-DAY LEAVE: @HalfDay 'AM' | 'PM' on a one-day request = 0.5 day (LEAVE_REQUEST.HalfDay; the attendance side is in 83).
       THE LEDGER IS POSTED PER MONTH: a leave over a month end used to land whole in the month it started, so the
       monthly balance reports were wrong on both sides. One poster for both places that post
       (usp_LeaveRequest_Decide and usp_Request_ApplyApprovalEffects): hr.usp_LeaveLedger_PostRequest.
       THE BALANCE: a paid, accruing type cannot be requested beyond what is left (less what is already promised to
       pending requests) unless LeaveAllowNegativeBalance = 1. A discretionary grant still works: its days come back.
   REVERSALS  taking an approval back (same-day retract; reopen by GM + Owner) now removes EVERY ledger row of the request —
       the discretionary give-back was left behind, making the balance richer by the length of the leave — and gives
       the attendance days back to the punches (attendance.usp_Attendance_RecomputeLeaveRange). Approval re-derives
       them too, so a leave approved after the days were processed no longer waits for the nightly job.
   D4  CARRY-OVER: usp_LeaveYear_Open caps what is carried (setting LeaveCarryOverMaxDays, or @CarryOverMaxDays) — the rest
       lapses with the year — and can open ONE employee (@EmployeeId). hr.usp_LeaveCarryOver_Expire posts ONE 'Expiry'
       ledger line per employee, type and year for the carried days still unused on LeaveCarryOverExpiresOn (MM-DD; usage
       consumes the carried days first); the nightly job calls it; running it again adds nothing. vw_LEAVE_BALANCE shows
       an Expiry with the adjustments so Remaining = Accrued + CarriedOver − Used + Adjusted still holds on screen.
   Beirut's date replaces GETDATE() in the year guard and the notice check.

   Idempotent: CREATE OR ALTER throughout. Apply with sqlcmd -C -I.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ───────────────────────── 1. what a leave costs ───────────────────────── */
/* every calendar day of a range for one employee, and whether it COSTS a day of leave */
CREATE OR ALTER FUNCTION hr.fn_LeaveDays (@EmployeeId INT, @FromDate DATE, @ToDate DATE)
RETURNS @d TABLE (WorkDate DATE PRIMARY KEY, IsRestDay BIT, IsHoliday BIT, Counts BIT)
AS
BEGIN
    IF @FromDate IS NULL OR @ToDate IS NULL OR @ToDate < @FromDate OR DATEDIFF(DAY, @FromDate, @ToDate) > 1500 RETURN;
    DECLARE @CountRest BIT = CASE WHEN (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'LeaveCountsRestDays') = '1' THEN 1 ELSE 0 END;
    DECLARE @day DATE = @FromDate, @rest BIT, @hol BIT;
    WHILE @day <= @ToDate
    BEGIN
        SET @rest = ISNULL((SELECT TOP 1 sa.IsRestDay FROM attendance.SHIFT_ASSIGNMENT sa WHERE sa.EmployeeId = @EmployeeId AND sa.WorkDate = @day), 0);
        SET @hol = core.fn_IsHoliday(@day, hr.fn_EmployeeBranchOn(@EmployeeId, @day));
        INSERT INTO @d VALUES (@day, @rest, @hol, CASE WHEN @hol = 1 THEN 0 WHEN @rest = 1 AND @CountRest = 0 THEN 0 ELSE 1 END);
        SET @day = DATEADD(DAY, 1, @day);
    END
    RETURN;
END;
GO
CREATE OR ALTER FUNCTION hr.fn_LeaveWorkingDays (@EmployeeId INT, @FromDate DATE, @ToDate DATE)
RETURNS NUMERIC(20,1)
AS
BEGIN
    RETURN ISNULL((SELECT SUM(CAST(Counts AS INT)) FROM hr.fn_LeaveDays(@EmployeeId, @FromDate, @ToDate)), 0);
END;
GO
/* the leave form's preview: "N working days" before the request is raised */
CREATE OR ALTER PROCEDURE hr.usp_Leave_CountWorkingDays
    @EmployeeId INT, @LeaveTypeId INT = NULL, @FromDate DATE, @ToDate DATE, @HalfDay CHAR(2) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @ToDate < @FromDate BEGIN RAISERROR('The end date is before the start date.', 16, 1); RETURN; END
    DECLARE @Calendar BIT = CASE WHEN EXISTS (SELECT 1 FROM hr.LEAVE_TYPE WHERE LeaveTypeId = @LeaveTypeId AND FixedEntitlementDays IS NOT NULL) THEN 1 ELSE 0 END;
    SELECT CalendarDays = DATEDIFF(DAY, @FromDate, @ToDate) + 1,
           WorkingDays  = CAST(CASE WHEN NULLIF(LTRIM(RTRIM(@HalfDay)), '') IS NOT NULL AND @FromDate = @ToDate AND SUM(CAST(Counts AS INT)) > 0 THEN 0.5
                                    WHEN @Calendar = 1 THEN DATEDIFF(DAY, @FromDate, @ToDate) + 1
                                    ELSE SUM(CAST(Counts AS INT)) END AS NUMERIC(20,1)),
           RestDays     = SUM(CASE WHEN IsRestDay = 1 AND IsHoliday = 0 THEN 1 ELSE 0 END),
           Holidays     = SUM(CAST(IsHoliday AS INT)),
           CountsCalendarDays = @Calendar,
           Balance      = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @EmployeeId AND LeaveTypeId = @LeaveTypeId)
    FROM hr.fn_LeaveDays(@EmployeeId, @FromDate, @ToDate);
END;
GO

/* ───────────────────────── 2. the attendance days of a leave follow its decision ───────────────────────── */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_RecomputeLeaveRange
    @RequestInstanceId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Emp INT, @From DATE, @To DATE;
    SELECT @Emp = EmployeeId, @From = FromDate, @To = ToDate FROM workflow.LEAVE_REQUEST WHERE RequestInstanceId = @RequestInstanceId;
    IF @Emp IS NULL RETURN;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    IF @To > @Today SET @To = @Today;                       -- the days still to come have nothing to derive yet
    DECLARE @d DATE = @From;
    WHILE @d <= @To
    BEGIN
        /* only days that have something to say: a record, or a roster row. ComputeDay skips manual and paid days itself. */
        IF EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @Emp AND WorkDate = @d)
           OR EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @Emp AND WorkDate = @d)
            EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @Emp, @WorkDate = @d;
        SET @d = DATEADD(DAY, 1, @d);
    END
END;
GO

/* ───────────────────────── 3. the one poster ───────────────────────── */
CREATE OR ALTER PROCEDURE hr.usp_LeaveLedger_PostRequest
    @RequestInstanceId INT, @ActorUserId INT = NULL, @UsageNote NVARCHAR(300) = N'Approved leave request.'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @LrId INT, @Emp INT, @Type INT, @From DATE, @To DATE, @Days NUMERIC(20,1), @Half CHAR(2), @Disc BIT, @Calendar BIT;
    SELECT @LrId = lr.LeaveRequestId, @Emp = lr.EmployeeId, @Type = lr.LeaveTypeId, @From = lr.FromDate, @To = lr.ToDate,
           @Days = ISNULL(lr.DaysApproved, lr.DaysRequested), @Half = lr.HalfDay, @Disc = ISNULL(lr.IsDiscretionary, 0),
           @Calendar = CASE WHEN lt.FixedEntitlementDays IS NOT NULL THEN 1 ELSE 0 END
    FROM workflow.LEAVE_REQUEST lr JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId = lr.LeaveTypeId
    WHERE lr.RequestInstanceId = @RequestInstanceId AND lr.AppliedToLedgerAt IS NULL;
    IF @LrId IS NULL RETURN;                                -- not a leave, or already posted

    /* the days the leave is made of, in order; the approved figure is taken from the front (a partial approval keeps the
       first days), one day at a time, the last one possibly a half */
    DECLARE @alloc TABLE (WorkDate DATE PRIMARY KEY, Part NUMERIC(20,1));
    IF @Half IS NOT NULL
        INSERT INTO @alloc VALUES (@From, @Days);
    ELSE
        INSERT INTO @alloc (WorkDate, Part)
        SELECT x.WorkDate, CASE WHEN x.n <= FLOOR(@Days) THEN 1.0 ELSE @Days - FLOOR(@Days) END
        FROM (SELECT d.WorkDate, ROW_NUMBER() OVER (ORDER BY d.WorkDate) AS n
              FROM hr.fn_LeaveDays(@Emp, @From, @To) d WHERE @Calendar = 1 OR d.Counts = 1) x
        WHERE x.n <= CEILING(@Days);
    /* whatever the days on the calendar no longer account for (the roster changed since the request) stays on the first day */
    DECLARE @Placed NUMERIC(20,1) = ISNULL((SELECT SUM(Part) FROM @alloc), 0);
    IF @Placed < @Days
    BEGIN
        IF EXISTS (SELECT 1 FROM @alloc WHERE WorkDate = @From) UPDATE @alloc SET Part = Part + (@Days - @Placed) WHERE WorkDate = @From;
        ELSE INSERT INTO @alloc VALUES (@From, @Days - @Placed);
    END

    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, LeaveRequestId, Days, EffectiveDate, Note, CreatedBy)
    SELECT @Emp, @Type, CONVERT(CHAR(7), MIN(WorkDate), 23), 'Usage', @LrId, -SUM(Part), MIN(WorkDate), @UsageNote, @ActorUserId
    FROM @alloc GROUP BY CONVERT(CHAR(7), WorkDate, 23) HAVING SUM(Part) > 0;
    IF @Disc = 1
        INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, LeaveRequestId, Days, EffectiveDate, Note, CreatedBy)
        SELECT @Emp, @Type, CONVERT(CHAR(7), MIN(WorkDate), 23), 'Adjustment', @LrId, SUM(Part), MIN(WorkDate),
               N'Discretionary grant — days returned to the balance by the approver.', @ActorUserId
        FROM @alloc GROUP BY CONVERT(CHAR(7), WorkDate, 23) HAVING SUM(Part) > 0;

    UPDATE workflow.LEAVE_REQUEST SET AppliedToLedgerAt = SYSUTCDATETIME() WHERE RequestInstanceId = @RequestInstanceId;

    /* the days already processed become Leave now, not at the next nightly run */
    EXEC attendance.usp_Attendance_RecomputeLeaveRange @RequestInstanceId = @RequestInstanceId;
END;
GO

/* ───────────────────────── 4. raising a leave ───────────────────────── */
CREATE OR ALTER PROCEDURE workflow.usp_LeaveRequest_Create
    @EmployeeId INT, @RaisedByUserId INT, @LeaveTypeId INT,
    @FromDate DATE, @ToDate DATE, @Reason NVARCHAR(500)=NULL,
    @Title NVARCHAR(150)=NULL, @RelationToEmployee NVARCHAR(30)=NULL,
    @HalfDay CHAR(2)=NULL              -- script 84 (D3): 'AM' | 'PM' for a ONE-day request = half a day
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF @ToDate < @FromDate
    BEGIN RAISERROR('The end date is before the start date.',16,1); RETURN; END
    SET @HalfDay = NULLIF(UPPER(LTRIM(RTRIM(@HalfDay))), '');
    IF @HalfDay IS NOT NULL AND @HalfDay NOT IN ('AM','PM')
    BEGIN RAISERROR('A half day is AM or PM.',16,1); RETURN; END
    IF @HalfDay IS NOT NULL AND @FromDate <> @ToDate
    BEGIN RAISERROR('A half day is for a one-day request: the start and end dates must be the same.',16,1); RETURN; END

    DECLARE @LtName NVARCHAR(60), @MinSvc INT, @Notice INT, @FixedDays NUMERIC(20,1),
            @NeedsRelation BIT = 0;
    SELECT @LtName=Name, @MinSvc=MinServiceMonthsToUse, @Notice=NoticePreferredDays,
           @FixedDays=FixedEntitlementDays
    FROM hr.LEAVE_TYPE WHERE LeaveTypeId=@LeaveTypeId;
    IF @LtName IS NULL BEGIN RAISERROR('That leave type does not exist.',16,1); RETURN; END

    SET @NeedsRelation = CASE WHEN EXISTS (SELECT 1 FROM hr.LEAVE_RELATION_ENTITLEMENT
                                           WHERE LeaveTypeId=@LeaveTypeId) THEN 1 ELSE 0 END;

    DECLARE @Hire DATE = (SELECT HireDate FROM hr.EMPLOYEE WHERE EmployeeId=@EmployeeId);
    DECLARE @SvcMonths INT = DATEDIFF(MONTH, @Hire, @FromDate);

    /* service gate: accrual runs from day one; USE is gated.
       %d is fine here - both substitutions are genuine ints. */
    IF @SvcMonths < @MinSvc
    BEGIN
        RAISERROR('%s leave can be used after %d months of service; this employee will have %d at the start date. The balance keeps accruing meanwhile.',
                  16,1,@LtName,@MinSvc,@SvcMonths);
        RETURN;
    END

    /* script 84 (D2): what a leave COSTS is the employee's working days in the range — rest days and public holidays
       inside it cost nothing (setting LeaveCountsRestDays = 0; holidays never count). A type with a fixed entitlement
       (maternity: 70 days) is a span of the calendar and keeps counting calendar days. A half day costs 0.5. */
    DECLARE @CalendarType BIT = CASE WHEN @FixedDays IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @Days NUMERIC(20,1) = CASE WHEN @CalendarType = 1 THEN DATEDIFF(DAY,@FromDate,@ToDate)+1
                                       ELSE hr.fn_LeaveWorkingDays(@EmployeeId,@FromDate,@ToDate) END;
    IF @Days <= 0
    BEGIN RAISERROR('These dates contain no working day for this employee (rest days and public holidays only) - there is nothing to take as leave.',16,1); RETURN; END
    IF @HalfDay IS NOT NULL SET @Days = 0.5;

    /* Day counts as text, for the messages below. RAISERROR cannot substitute a
       numeric, and a whole number should not read as "5.0" to a human. */
    DECLARE @DaysText VARCHAR(20) =
        CASE WHEN @Days = FLOOR(@Days) THEN CONVERT(VARCHAR(20), CAST(@Days AS INT))
             ELSE CONVERT(VARCHAR(20), @Days) END;

    /* relation-capped types (bereavement) */
    IF @NeedsRelation = 1
    BEGIN
        IF @RelationToEmployee IS NULL
        BEGIN RAISERROR('State the relation (Parent, Sibling, Child, Spouse, Grandparent, Aunt, Uncle).',16,1); RETURN; END
        DECLARE @Cap NUMERIC(20,1) = (SELECT Days FROM hr.LEAVE_RELATION_ENTITLEMENT
                                     WHERE LeaveTypeId=@LeaveTypeId AND Relation=@RelationToEmployee);
        IF @Cap IS NULL
        BEGIN RAISERROR('Bereavement leave does not cover that relation.',16,1); RETURN; END
        IF @Days > @Cap
        BEGIN
            DECLARE @CapText VARCHAR(20) =
                CASE WHEN @Cap = FLOOR(@Cap) THEN CONVERT(VARCHAR(20), CAST(@Cap AS INT))
                     ELSE CONVERT(VARCHAR(20), @Cap) END;
            RAISERROR('%s allows %s day(s) for a %s; %s were requested.',
                      16,1,@LtName,@CapText,@RelationToEmployee,@DaysText);
            RETURN;
        END
    END

    /* fixed-entitlement types (maternity): cap at the entitlement */
    IF @FixedDays IS NOT NULL AND @Days > @FixedDays
    BEGIN
        DECLARE @FixedText VARCHAR(20) =
            CASE WHEN @FixedDays = FLOOR(@FixedDays) THEN CONVERT(VARCHAR(20), CAST(@FixedDays AS INT))
                 ELSE CONVERT(VARCHAR(20), @FixedDays) END;
        RAISERROR('%s leave is %s days; %s were requested.',16,1,@LtName,@FixedText,@DaysText);
        RETURN;
    END

    /* script 84: THE BALANCE. A paid, accruing type cannot be requested beyond what is left unless the setting allows a
       negative balance. (A discretionary GRANT is the approver's decision and gives its days back, so it is not
       affected; a discretionary leave TYPE has no balance to exceed.) */
    DECLARE @AllowNegative BIT = CASE WHEN (SELECT SettingValue FROM core.SETTING WHERE SettingKey='LeaveAllowNegativeBalance') = '1' THEN 1 ELSE 0 END;
    IF @AllowNegative = 0
       AND EXISTS (SELECT 1 FROM hr.LEAVE_TYPE lt WHERE lt.LeaveTypeId=@LeaveTypeId AND lt.IsPaid=1 AND ISNULL(lt.IsDiscretionary,0)=0)
       AND EXISTS (SELECT 1 FROM hr.LEAVE_ACCRUAL_TIER a WHERE a.LeaveTypeId=@LeaveTypeId)
    BEGIN
        DECLARE @Balance NUMERIC(20,1) = ISNULL((SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId=@EmployeeId AND LeaveTypeId=@LeaveTypeId),0);
        /* days already promised by requests still waiting for a decision */
        DECLARE @Pending NUMERIC(20,1) = ISNULL((SELECT SUM(ISNULL(lr.DaysApproved, lr.DaysRequested))
                                                 FROM workflow.LEAVE_REQUEST lr
                                                 JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId=lr.RequestInstanceId
                                                 WHERE lr.EmployeeId=@EmployeeId AND lr.LeaveTypeId=@LeaveTypeId AND r.[Status] IN ('Pending','OnHold')),0);
        IF @Days > @Balance - @Pending
        BEGIN
            DECLARE @LeftText VARCHAR(20) = CASE WHEN @Balance-@Pending = FLOOR(@Balance-@Pending) THEN CONVERT(VARCHAR(20), CAST(@Balance-@Pending AS INT)) ELSE CONVERT(VARCHAR(20), @Balance-@Pending) END;
            RAISERROR('The %s leave balance has %s day(s) left; %s were requested.',16,1,@LtName,@LeftText,@DaysText);
            RETURN;
        END
    END
    /* overlap guard, unchanged */
    DECLARE @Clash NVARCHAR(200);
    SELECT TOP 1 @Clash = CONCAT(N'from ',CONVERT(char(10),lr.FromDate,23),
                                 N' to ',CONVERT(char(10),lr.ToDate,23),N' (',r.[Status],N')')
    FROM workflow.LEAVE_REQUEST lr
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId=lr.RequestInstanceId
    WHERE lr.EmployeeId=@EmployeeId AND r.[Status] IN ('Pending','OnHold','Approved')
      AND lr.FromDate<=@ToDate AND lr.ToDate>=@FromDate;
    IF @Clash IS NOT NULL
    BEGIN RAISERROR('These dates overlap an existing leave request %s. Cancel or change it first.',16,1,@Clash); RETURN; END

    IF @Title IS NULL OR LTRIM(RTRIM(@Title))=''
        SET @Title = CASE WHEN @HalfDay IS NOT NULL
                          THEN CONCAT(@LtName,N' leave ',CONVERT(char(10),@FromDate,23),N' (half day, ',@HalfDay,N')')
                          ELSE CONCAT(@LtName,N' leave ',CONVERT(char(10),@FromDate,23),
                                      N' to ',CONVERT(char(10),@ToDate,23),N' (',@DaysText,
                                      CASE WHEN @CalendarType = 1 THEN N' days)' WHEN @Days = 1 THEN N' working day)' ELSE N' working days)' END) END;

    BEGIN TRAN;
    DECLARE @Submitted TABLE (RequestInstanceId INT,[Status] VARCHAR(20),CurrentStepNo INT,
                              WorkflowDefinitionId INT,WorkflowVersion INT,MinRequesterTier INT);
    INSERT INTO @Submitted
    EXEC workflow.usp_Request_Submit @RequestTypeCode='LEAVE_REQUEST',
         @EmployeeId=@EmployeeId, @RaisedByUserId=@RaisedByUserId, @Title=@Title;

    DECLARE @ReqId INT = (SELECT TOP 1 RequestInstanceId FROM @Submitted);
    INSERT INTO workflow.LEAVE_REQUEST
        (RequestInstanceId,EmployeeId,LeaveTypeId,FromDate,ToDate,DaysRequested,Reason,RelationToEmployee,HalfDay)
    VALUES (@ReqId,@EmployeeId,@LeaveTypeId,@FromDate,@ToDate,@Days,@Reason,@RelationToEmployee,@HalfDay);

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

    SELECT s.RequestInstanceId, s.[Status], s.CurrentStepNo, s.WorkflowVersion,
           @Days AS DaysRequested,
           CAST(CASE WHEN @Notice>0 AND DATEDIFF(DAY,CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE),@FromDate)<@Notice
                THEN 1 ELSE 0 END AS BIT) AS NoticeShorterThanPreferred,
           @Notice AS NoticePreferredDays
    FROM @Submitted s;
END;
GO

/* ───────────────────────── 5. the two places that post it ───────────────────────── */
CREATE OR ALTER PROCEDURE [workflow].[usp_LeaveRequest_Decide]
    @RequestInstanceId INT, @ActedByUserId INT,
    @ApprovedDays NUMERIC(20,1)=NULL, @Comment NVARCHAR(1000)=NULL,
    @SignedWithPassword BIT=0,
    @MakeDiscretionary BIT=0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF @MakeDiscretionary = 1 AND LTRIM(RTRIM(ISNULL(@Comment, N''))) = N''
    BEGIN
        RAISERROR('A note is required when granting as discretionary — say why the days are not deducted.', 16, 1);
        RETURN;
    END

    DECLARE @EmpId INT,@LtId INT,@Requested NUMERIC(20,1),@From DATE,@NeedsCert BIT,
            @Standing NUMERIC(20,1);

    SELECT @EmpId=lr.EmployeeId,@LtId=lr.LeaveTypeId,@Requested=lr.DaysRequested,
           @From=lr.FromDate,@NeedsCert=lt.RequiresCertificate,
           @Standing=ISNULL(lr.DaysApproved, lr.DaysRequested)
    FROM workflow.LEAVE_REQUEST lr
    JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId=lr.LeaveTypeId
    WHERE lr.RequestInstanceId=@RequestInstanceId;
    IF @EmpId IS NULL BEGIN RAISERROR('This is not a leave request.',16,1); RETURN; END

    IF @NeedsCert=1 AND NOT EXISTS (SELECT 1 FROM workflow.REQUEST_ATTACHMENT
                                    WHERE RequestInstanceId=@RequestInstanceId)
    BEGIN RAISERROR('This leave type requires a certificate. Attach it to the request before approving.',16,1); RETURN; END

    DECLARE @Granted NUMERIC(20,1)=ISNULL(@ApprovedDays,@Standing);
    IF @Granted<=0 OR @Granted>@Standing
    BEGIN
        DECLARE @StandingText VARCHAR(20) =
            CASE WHEN @Standing = FLOOR(@Standing) THEN CONVERT(VARCHAR(20), CAST(@Standing AS INT))
                 ELSE CONVERT(VARCHAR(20), @Standing) END;
        RAISERROR('Approved days must be more than 0 and no more than the %s currently approved.',
                  16,1,@StandingText);
        RETURN;
    END

    DECLARE @ChangeSummary NVARCHAR(300)=
        CASE WHEN @Granted<>@Standing
             THEN CONCAT(N'Days: ',CONVERT(VARCHAR(20),@Standing),N' -> ',CONVERT(VARCHAR(20),@Granted)) END;
    IF @MakeDiscretionary=1
        SET @ChangeSummary = CONCAT(ISNULL(@ChangeSummary + N' · ', N''),
                                    N'Discretionary — days returned to balance');

    DECLARE @Result TABLE (RequestInstanceId INT,[Status] VARCHAR(20),CurrentStepNo INT,
                           ClosedReason NVARCHAR(300),Decision VARCHAR(25),
                           SignedAsDeputy BIT,SignedWithPassword BIT);
    INSERT INTO @Result
    EXEC workflow.usp_Request_Approve @RequestInstanceId=@RequestInstanceId,
         @ActedByUserId=@ActedByUserId,@Comment=@Comment,
         @ChangeSummary=@ChangeSummary,@SignedWithPassword=@SignedWithPassword;
    IF NOT EXISTS (SELECT 1 FROM @Result) RETURN;

    UPDATE workflow.LEAVE_REQUEST
    SET DaysApproved=@Granted, IsDiscretionary=@MakeDiscretionary
    WHERE RequestInstanceId=@RequestInstanceId;

    /* script 84: one place posts a leave to the ledger (per month, working days, half days, the discretionary give-back)
       and re-derives the attendance days it covers: hr.usp_LeaveLedger_PostRequest. Idempotent (AppliedToLedgerAt). */
    IF (SELECT TOP 1 [Status] FROM @Result)='Approved'
        EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId=@RequestInstanceId, @ActorUserId=@ActedByUserId,
             @UsageNote=N'Approved leave request.';

    DECLARE @Balance DECIMAL(6,2)=(SELECT ISNULL(SUM(Days),0) FROM hr.LEAVE_LEDGER
                                   WHERE EmployeeId=@EmpId AND LeaveTypeId=@LtId);
    SELECT r.*,@Granted AS DaysApproved,@Balance AS BalanceAfter,
           CAST(CASE WHEN @Balance<0 THEN 1 ELSE 0 END AS BIT) AS BalanceIsNegative,
           CAST(@MakeDiscretionary AS BIT) AS DiscretionaryGranted
    FROM @Result r;
END;
GO

CREATE OR ALTER PROCEDURE [workflow].[usp_Request_ApplyApprovalEffects]
    @RequestInstanceId INT,
    @ActorUserId       INT = NULL      -- recorded as the ledger/row creator
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Code VARCHAR(40), @Status VARCHAR(20), @RaisedBy INT, @ClosedAt DATETIME2;
    SELECT @Code = rt.Code, @Status = ri.[Status], @RaisedBy = ri.RaisedByUserId, @ClosedAt = ri.ClosedAt
    FROM workflow.REQUEST_INSTANCE ri
    JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = ri.RequestTypeId
    WHERE ri.RequestInstanceId = @RequestInstanceId;

    IF @Status <> 'Approved' RETURN;            -- effects follow approval only
    SET @ActorUserId = ISNULL(@ActorUserId, @RaisedBy);

    /* ---- LEAVE: post Usage once; discretionary adds the give-back rows (script 84: through the one poster) ---- */
    IF @Code = 'LEAVE_REQUEST'
        EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId=@RequestInstanceId, @ActorUserId=@ActorUserId,
             @UsageNote=N'Approved leave request (applied on approval).';

    /* ---- SALARY ADVANCE: create the payroll advance once ---- */
    IF @Code = 'SALARY_ADVANCE'
       AND EXISTS (SELECT 1 FROM workflow.SALARY_ADVANCE_REQUEST
                   WHERE RequestInstanceId = @RequestInstanceId AND CreatedAdvanceId IS NULL)
    BEGIN
        DECLARE @Amt DECIMAL(18,2), @Mon DECIMAL(18,2);
        SELECT @Amt = ISNULL(ApprovedAmount, Amount),
               @Mon = ISNULL(ApprovedMonthlyDeduction,
                             IIF(MonthlyDeduction > ISNULL(ApprovedAmount, Amount),
                                 ISNULL(ApprovedAmount, Amount), MonthlyDeduction))
        FROM workflow.SALARY_ADVANCE_REQUEST WHERE RequestInstanceId = @RequestInstanceId;

        INSERT INTO payroll.SALARY_ADVANCE
            (EmployeeId, RequestInstanceId, Amount, CurrencyCode, AdvanceDate,
             MonthlyDeduction, RemainingAmount, FirstDeductionPeriod, Reason, CreatedByUserId)
        SELECT EmployeeId, @RequestInstanceId, @Amt, CurrencyCode, CAST(GETDATE() AS DATE),
               @Mon, @Amt, FirstDeductionPeriod, Reason, @ActorUserId
        FROM workflow.SALARY_ADVANCE_REQUEST WHERE RequestInstanceId = @RequestInstanceId;

        UPDATE workflow.SALARY_ADVANCE_REQUEST
        SET CreatedAdvanceId = SCOPE_IDENTITY(), AdvanceCreatedAt = SYSUTCDATETIME()
        WHERE RequestInstanceId = @RequestInstanceId;
    END

    /* ---- PAYROLL ADJUSTMENT: create the adjustment once ---- */
    IF @Code = 'PAYROLL_ADJUSTMENT'
       AND EXISTS (SELECT 1 FROM workflow.PAYROLL_ADJUSTMENT_REQUEST
                   WHERE RequestInstanceId = @RequestInstanceId AND CreatedAdjustmentId IS NULL)
    BEGIN
        INSERT INTO payroll.PAYROLL_ADJUSTMENT
            (EmployeeId, ComponentTypeId, Amount, CurrencyCode, TargetPeriod,
             CorrectsRunId, Reason, CreatedByUserId, RequestInstanceId)
        SELECT EmployeeId, ComponentTypeId, ISNULL(ApprovedAmount, Amount), CurrencyCode,
               TargetPeriod, CorrectsRunId, Reason, @ActorUserId, @RequestInstanceId
        FROM workflow.PAYROLL_ADJUSTMENT_REQUEST WHERE RequestInstanceId = @RequestInstanceId;

        UPDATE workflow.PAYROLL_ADJUSTMENT_REQUEST
        SET CreatedAdjustmentId = SCOPE_IDENTITY(), AdjustmentCreatedAt = SYSUTCDATETIME()
        WHERE RequestInstanceId = @RequestInstanceId;
    END

    /* ---- OVERTIME: settle the figure, then link to attendance (no rowset —
            inlined from usp_Overtime_ApplyToAttendance, which SELECTs). Guarded by
            its marker like every other arm; the marker is stamped only once the
            worked day exists, which is why the reconciler leaves this type out. ---- */
    IF @Code = 'OVERTIME'
       AND EXISTS (SELECT 1 FROM workflow.OVERTIME_REQUEST
                   WHERE RequestInstanceId = @RequestInstanceId AND AppliedToAttendanceAt IS NULL)
    BEGIN
        UPDATE workflow.OVERTIME_REQUEST
        SET ApprovedMinutes = ISNULL(ApprovedMinutes, RequestedMinutes)
        WHERE RequestInstanceId = @RequestInstanceId;

        UPDATE ar
        SET ar.OvertimeApprovedMinutes = o.ApprovedMinutes,
            ar.OvertimeRequestId       = o.OvertimeRequestId
        FROM attendance.ATTENDANCE_RECORD ar
        JOIN workflow.OVERTIME_REQUEST o
          ON o.EmployeeId = ar.EmployeeId AND o.WorkDate = ar.WorkDate
        WHERE o.RequestInstanceId = @RequestInstanceId
          AND (ar.OvertimeRequestId IS NULL OR ar.OvertimeRequestId = o.OvertimeRequestId);

        UPDATE o SET AppliedToAttendanceAt = SYSUTCDATETIME()
        FROM workflow.OVERTIME_REQUEST o
        JOIN attendance.ATTENDANCE_RECORD ar ON ar.OvertimeRequestId = o.OvertimeRequestId
        WHERE o.RequestInstanceId = @RequestInstanceId AND o.AppliedToAttendanceAt IS NULL;
    END

    /* ---- SHIFT SWAP: apply the exchange once (same-date rule as F5).
            A missing roster row skips silently; the reconciler sweeps it. ---- */
    IF @Code = 'SHIFT_SWAP'
       AND EXISTS (SELECT 1 FROM workflow.SHIFT_SWAP
                   WHERE RequestInstanceId = @RequestInstanceId AND AppliedAt IS NULL)
    BEGIN
        DECLARE @E1 INT,@E2 INT,@D1 DATE,@D2 DATE;
        SELECT @E1=RequesterEmployeeId,@E2=CounterpartEmployeeId,
               @D1=RequesterDate,@D2=CounterpartDate
        FROM workflow.SHIFT_SWAP WHERE RequestInstanceId=@RequestInstanceId;

        DECLARE @S1 INT=(SELECT ShiftId FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId=@E1 AND WorkDate=@D1);
        DECLARE @S2 INT=(SELECT ShiftId FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId=@E2 AND WorkDate=@D2);

        IF @S1 IS NOT NULL AND @S2 IS NOT NULL
        BEGIN
            MERGE attendance.SHIFT_ASSIGNMENT t
            USING (VALUES (@E1,@D2,@S2),(@E2,@D1,@S1)) s(EmployeeId,WorkDate,ShiftId)
               ON t.EmployeeId=s.EmployeeId AND t.WorkDate=s.WorkDate
            WHEN MATCHED THEN UPDATE SET ShiftId=s.ShiftId, IsRestDay=0
            WHEN NOT MATCHED THEN INSERT (EmployeeId,ShiftId,WorkDate,IsRestDay)
                 VALUES (s.EmployeeId,s.ShiftId,s.WorkDate,0);

            IF @D1 <> @D2
                UPDATE attendance.SHIFT_ASSIGNMENT SET ShiftId=NULL, IsRestDay=1
                WHERE (EmployeeId=@E1 AND WorkDate=@D1) OR (EmployeeId=@E2 AND WorkDate=@D2);

            UPDATE workflow.SHIFT_SWAP SET AppliedAt=SYSUTCDATETIME()
            WHERE RequestInstanceId=@RequestInstanceId;
        END
    END

    /* ---- ROSTER_APPROVAL: the month's roster becomes ACTIVE only here. Applied
            once (AppliedAt); a later approval of the same branch-month supersedes
            the previous one — the header follows the request that approved last. ---- */
    IF @Code = 'ROSTER_APPROVAL'
       AND EXISTS (SELECT 1 FROM workflow.ROSTER_APPROVAL
                   WHERE RequestInstanceId = @RequestInstanceId AND AppliedAt IS NULL)
    BEGIN
        DECLARE @RaBranch INT, @RaMonth DATE;
        SELECT @RaBranch = BranchId, @RaMonth = MonthDate
        FROM workflow.ROSTER_APPROVAL WHERE RequestInstanceId = @RequestInstanceId;

        DECLARE @ApprovedAt DATETIME2 = ISNULL(@ClosedAt, SYSUTCDATETIME());

        MERGE attendance.ROSTER_MONTH AS t
        USING (SELECT @RaBranch AS BranchId, @RaMonth AS MonthDate) AS s
           ON t.BranchId = s.BranchId AND t.MonthDate = s.MonthDate
        WHEN MATCHED THEN UPDATE SET [Status] = 'Approved', ApprovedAt = @ApprovedAt,
                                     RequestInstanceId = @RequestInstanceId
        WHEN NOT MATCHED THEN INSERT (BranchId, MonthDate, [Status], RequestInstanceId, ApprovedAt)
                              VALUES (s.BranchId, s.MonthDate, 'Approved', @RequestInstanceId, @ApprovedAt);

        UPDATE workflow.ROSTER_APPROVAL
        SET AppliedAt = SYSUTCDATETIME()
        WHERE RequestInstanceId = @RequestInstanceId AND AppliedAt IS NULL;
    END;
END;
GO

/* ───────────────────────── 6. taking an approval back ───────────────────────── */
CREATE OR ALTER PROCEDURE [workflow].[usp_Reversal_UndoEffects]
    @RequestInstanceId INT
AS
BEGIN
    SET NOCOUNT ON;

    /* payroll adjustment: unchanged */
    DELETE a FROM payroll.PAYROLL_ADJUSTMENT a
    JOIN workflow.PAYROLL_ADJUSTMENT_REQUEST q ON q.CreatedAdjustmentId=a.PayrollAdjustmentId
    WHERE q.RequestInstanceId=@RequestInstanceId AND a.AppliedToPayslipId IS NULL;
    UPDATE workflow.PAYROLL_ADJUSTMENT_REQUEST
        SET CreatedAdjustmentId=NULL, AdjustmentCreatedAt=NULL
        WHERE RequestInstanceId=@RequestInstanceId;

    /* salary advance: unchanged */
    DELETE a FROM payroll.SALARY_ADVANCE a
    JOIN workflow.SALARY_ADVANCE_REQUEST q ON q.CreatedAdvanceId=a.SalaryAdvanceId
    WHERE q.RequestInstanceId=@RequestInstanceId
      AND a.RemainingAmount=a.Amount AND a.IsSettled=0;
    UPDATE workflow.SALARY_ADVANCE_REQUEST
        SET CreatedAdvanceId=NULL, AdvanceCreatedAt=NULL
        WHERE RequestInstanceId=@RequestInstanceId;

    /* NEW — leave: take the Usage row back off the ledger and unmark the
       request, so the balance reflects a decision that no longer stands.
       Keyed by LeaveRequestId, so only THIS request's posting is touched. */
    /* script 84: EVERY ledger row of the request goes — the usage (one row per month now) AND, for a discretionary
       grant, the days given back. Removing the usage alone left the give-back behind: a retracted discretionary
       leave made the balance RICHER by its own length. */
    DECLARE @LvEmp INT, @LvFrom DATE, @LvTo DATE;
    SELECT @LvEmp = EmployeeId, @LvFrom = FromDate, @LvTo = ToDate FROM workflow.LEAVE_REQUEST WHERE RequestInstanceId = @RequestInstanceId;
    DELETE l
    FROM hr.LEAVE_LEDGER l
    JOIN workflow.LEAVE_REQUEST lr ON lr.LeaveRequestId = l.LeaveRequestId
    WHERE lr.RequestInstanceId = @RequestInstanceId
      AND l.MovementType IN ('Usage', 'Adjustment');
    UPDATE workflow.LEAVE_REQUEST
        SET AppliedToLedgerAt = NULL
        WHERE RequestInstanceId = @RequestInstanceId;
    /* and the attendance days go back to what the punches say. The request is still 'Approved' at this point of the
       caller's transaction, so the days are named here and re-derived by the caller's last step — see
       attendance.usp_Attendance_RecomputeLeaveRange, called by the three reversal procedures once the status moved. */
END;
GO

/* workflow.usp_Request_RetractLastDecision */
CREATE OR ALTER PROCEDURE [workflow].[usp_Request_RetractLastDecision]
    @RequestInstanceId  INT,
    @ActedByUserId      INT,
    @Reason             NVARCHAR(300),
    @SignedWithPassword BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason))=''
    BEGIN RAISERROR('A reason is required to retract a decision.',16,1); RETURN; END

    DECLARE @SigId INT,@SigUser INT,@SigAt DATETIME2,@StepNo INT,@WasSigned BIT;
    /* StepNo IS NOT NULL excludes the 'Submitted' row. A submission is not a
       decision, and treating it as one left the request Pending with no step. */
    SELECT TOP 1 @SigId=SignatureId,@SigUser=ActedByUserId,
                 @SigAt=ActedAt,@StepNo=StepNo,@WasSigned=ISNULL(SignedWithPassword,0)
    FROM workflow.WORKFLOW_SIGNATURE
    WHERE RequestInstanceId=@RequestInstanceId AND RetractedAt IS NULL
      AND StepNo IS NOT NULL AND [Action] IN ('Approved','Rejected')
    ORDER BY ActedAt DESC, SignatureId DESC;
    IF @SigId IS NULL BEGIN RAISERROR('There is no decision to retract.',16,1); RETURN; END
    IF @SigUser<>@ActedByUserId
    BEGIN RAISERROR('Only the person who signed the LAST decision may retract it, and only same-day. Later than that, reopening needs the GM and the Owner together.',16,1); RETURN; END
    IF CAST(@SigAt AS DATE)<>CAST(SYSUTCDATETIME() AS DATE)
    BEGIN RAISERROR('Same-day only: this decision is from an earlier day. Reopening now needs the GM and the Owner together.',16,1); RETURN; END

    /* THE FIX — the signature gate, fails closed like approve/reject/withdraw */
    DECLARE @NeedsSignature BIT =
        CASE WHEN @WasSigned = 1
               OR EXISTS (SELECT 1 FROM security.USER_ROLE ur
                          JOIN security.[ROLE] r ON r.RoleId = ur.RoleId
                          WHERE ur.UserId = @ActedByUserId AND r.RequiresSignaturePassword = 1)
             THEN 1 ELSE 0 END;
    IF @NeedsSignature = 1 AND @SignedWithPassword = 0
    BEGIN RAISERROR('Retracting this decision must be signed with your password.',16,1); RETURN; END

    DECLARE @Block NVARCHAR(300)=workflow.fn_ReversalBlockReason(@RequestInstanceId);
    IF @Block IS NOT NULL BEGIN RAISERROR(@Block,16,1); RETURN; END

    BEGIN TRAN;
    EXEC workflow.usp_Reversal_UndoEffects @RequestInstanceId;
    UPDATE workflow.WORKFLOW_SIGNATURE
        SET RetractedAt=SYSUTCDATETIME(), RetractedReason=@Reason
        WHERE SignatureId=@SigId;

    /* Unsign the step, exactly as usp_Request_WithdrawDecision does. Without
       this the chain keeps showing the struck decision as the standing one. */
    UPDATE workflow.REQUEST_STEP_INSTANCE
        SET [Status]='Pending', Decision=NULL,
            ActedByUserId=NULL, ActedAt=NULL, Comment=NULL, ValueBefore=NULL,
            SignedWithPassword=0,
            HoldReason=NULL, HoldSetAt=NULL, HoldSetByUserId=NULL, WaitingOnRequester=0
        WHERE RequestInstanceId=@RequestInstanceId AND StepNo=@StepNo;

    UPDATE workflow.REQUEST_INSTANCE
        SET [Status]='Pending', CurrentStepNo=@StepNo,
            ClosedAt=NULL, ClosedReason=NULL
        WHERE RequestInstanceId=@RequestInstanceId;
    INSERT INTO workflow.REQUEST_REVERSAL
        (RequestInstanceId,Kind,Reason,FirstSignUserId,FirstSignRole,CompletedAt)
    VALUES (@RequestInstanceId,'Retract',@Reason,@ActedByUserId,N'Self',SYSUTCDATETIME());
    COMMIT TRAN;
    /* script 84: a leave whose approval no longer stands gives its attendance days back to the punches */
    EXEC attendance.usp_Attendance_RecomputeLeaveRange @RequestInstanceId = @RequestInstanceId;
    SELECT @RequestInstanceId AS RequestInstanceId,'Pending' AS [Status],@StepNo AS CurrentStepNo;
END;
GO

/* workflow.usp_Request_Reopen */
CREATE OR ALTER PROCEDURE workflow.usp_Request_Reopen
    @RequestInstanceId INT, @ActedByUserId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* BOTH spellings. The seeded role is 'General Manager' with a space; the
       original literal had none, so the GM silently failed this gate. */
    DECLARE @IsGm BIT=CASE WHEN payroll.fn_UserHasRole(@ActedByUserId,N'GeneralManager')=1
                             OR payroll.fn_UserHasRole(@ActedByUserId,N'General Manager')=1
                           THEN 1 ELSE 0 END;
    DECLARE @IsOwner BIT=payroll.fn_UserHasRole(@ActedByUserId,N'Owner');
    IF @IsGm=0 AND @IsOwner=0
    BEGIN RAISERROR('Reopening a closed request needs the General Manager and the Owner.',16,1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE
                   WHERE RequestInstanceId=@RequestInstanceId AND [Status] IN ('Approved','Rejected'))
    BEGIN RAISERROR('Only a closed (approved or rejected) request can be reopened.',16,1); RETURN; END
    DECLARE @Block NVARCHAR(300)=workflow.fn_ReversalBlockReason(@RequestInstanceId);
    IF @Block IS NOT NULL BEGIN RAISERROR(@Block,16,1); RETURN; END

    DECLARE @Role NVARCHAR(30)=IIF(@IsOwner=1,N'Owner',N'GeneralManager');
    DECLARE @Open INT=(SELECT TOP 1 ReversalId FROM workflow.REQUEST_REVERSAL
        WHERE RequestInstanceId=@RequestInstanceId AND Kind='Reopen' AND CompletedAt IS NULL
        ORDER BY ReversalId DESC);

    IF @Open IS NULL
    BEGIN
        IF @Reason IS NULL OR LTRIM(RTRIM(@Reason))=''
        BEGIN RAISERROR('A reason is required to reopen.',16,1); RETURN; END
        INSERT INTO workflow.REQUEST_REVERSAL
            (RequestInstanceId,Kind,Reason,FirstSignUserId,FirstSignRole)
        VALUES (@RequestInstanceId,'Reopen',@Reason,@ActedByUserId,@Role);
        SELECT 'AwaitingSecond' AS [State], @Role AS FirstSignRole;
        RETURN;
    END
    IF EXISTS (SELECT 1 FROM workflow.REQUEST_REVERSAL
               WHERE ReversalId=@Open AND FirstSignRole=@Role)
    BEGIN RAISERROR('This role already signed the reopen - the OTHER of GM/Owner must sign.',16,1); RETURN; END

    DECLARE @LastStep INT=(SELECT MAX(s.StepNo) FROM workflow.WORKFLOW_SIGNATURE s
        WHERE s.RequestInstanceId=@RequestInstanceId AND s.RetractedAt IS NULL
          AND s.StepNo IS NOT NULL AND s.[Action] IN ('Approved','Rejected'));
    IF @LastStep IS NULL
    BEGIN RAISERROR('There is no decision to reverse on this request.',16,1); RETURN; END

    BEGIN TRAN;
    EXEC workflow.usp_Reversal_UndoEffects @RequestInstanceId;
    UPDATE workflow.WORKFLOW_SIGNATURE
        SET RetractedAt=SYSUTCDATETIME(),
            RetractedReason=N'Reopened by GM + Owner'
        WHERE RequestInstanceId=@RequestInstanceId AND StepNo=@LastStep AND RetractedAt IS NULL;

    /* Unsign the step the struck signature belonged to — see the retract note. */
    UPDATE workflow.REQUEST_STEP_INSTANCE
        SET [Status]='Pending', Decision=NULL,
            ActedByUserId=NULL, ActedAt=NULL, Comment=NULL, ValueBefore=NULL,
            SignedWithPassword=0,
            HoldReason=NULL, HoldSetAt=NULL, HoldSetByUserId=NULL, WaitingOnRequester=0
        WHERE RequestInstanceId=@RequestInstanceId AND StepNo=@LastStep;

    UPDATE workflow.REQUEST_REVERSAL
        SET SecondSignUserId=@ActedByUserId, SecondSignRole=@Role, CompletedAt=SYSUTCDATETIME()
        WHERE ReversalId=@Open;
    UPDATE workflow.REQUEST_INSTANCE
        SET [Status]='Pending', CurrentStepNo=@LastStep,
            ClosedAt=NULL, ClosedReason=NULL
        WHERE RequestInstanceId=@RequestInstanceId;
    COMMIT TRAN;
    /* script 84: a leave whose approval no longer stands gives its attendance days back to the punches */
    EXEC attendance.usp_Attendance_RecomputeLeaveRange @RequestInstanceId = @RequestInstanceId;
    SELECT @RequestInstanceId AS RequestInstanceId,'Pending' AS [Status],@LastStep AS CurrentStepNo;
END;
GO

/* ───────────────────────── 7. the leave year: carry-over cap, one employee; the balance view ───────────────────────── */
CREATE OR ALTER PROCEDURE [hr].[usp_LeaveYear_Open]
    @Year          INT,
    @ActedByUserId INT = NULL,
    @EmployeeId    INT = NULL,               -- script 84: open ONE employee (a new hire, a test) instead of everybody still unopened
    @CarryOverMaxDays DECIMAL(6,2) = NULL    -- script 84 (D4): NULL = the LeaveCarryOverMaxDays setting (empty = no cap)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now INT = YEAR(CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));      -- script 84: the year in Beirut, not on the server
    IF @Year <> @Now
    BEGIN
        DECLARE @m nvarchar(200) = CONCAT(N'Only the current year (', @Now,
            N') can be opened. Next January, open ', @Now + 1, N'.');
        RAISERROR(@m, 16, 1); RETURN;
    END

    DECLARE @Jan1   DATE    = DATEFROMPARTS(@Year, 1, 1);
    DECLARE @NextJ1 DATE    = DATEADD(YEAR, 1, @Jan1);
    DECLARE @Period CHAR(7) = FORMAT(@Jan1, 'yyyy-MM');
    DECLARE @PrevYr INT     = @Year - 1;
    /* script 84 (D4): the most that is carried; what is left beyond it lapses with the year */
    DECLARE @Cap DECIMAL(6,2) = COALESCE(@CarryOverMaxDays,
                                         TRY_CAST(NULLIF(LTRIM(RTRIM((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'LeaveCarryOverMaxDays'))), '') AS DECIMAL(6,2)));
    IF @Cap IS NOT NULL AND @Cap < 0 SET @Cap = 0;

    SELECT
        e.EmployeeId, e.FullName, e.HireDate,
        lt.LeaveTypeId, lt.Name AS LeaveTypeName, lt.CarryOver,
        CAST(CASE WHEN e.HireDate >= @Jan1
                  THEN ROUND(t.AnnualDays * (13 - MONTH(e.HireDate)) / 12.0 * 2, 0) / 2
                  ELSE t.AnnualDays END AS DECIMAL(6,2)) AS GrantDays,
        CAST(CASE WHEN e.HireDate >= @Jan1 THEN 1 ELSE 0 END AS BIT) AS Prorated,
        ISNULL(prev.Remaining, 0) AS PrevRemaining
    INTO #grant
    FROM hr.EMPLOYEE e
    CROSS JOIN hr.LEAVE_TYPE lt
    CROSS APPLY (
        SELECT TOP 1 a.AnnualDays
        FROM hr.LEAVE_ACCRUAL_TIER a
        WHERE a.LeaveTypeId = lt.LeaveTypeId
          AND a.MinServiceYears <=
              CASE WHEN e.HireDate >= @Jan1 THEN 0
                   ELSE DATEDIFF(MONTH, e.HireDate, @Jan1) / 12 END
        ORDER BY a.MinServiceYears DESC
    ) t
    OUTER APPLY (
        SELECT SUM(l.Days) AS Remaining
        FROM hr.LEAVE_LEDGER l
        WHERE l.EmployeeId = e.EmployeeId AND l.LeaveTypeId = lt.LeaveTypeId
          AND l.PeriodYearMonth < @Period
    ) prev
    WHERE e.IsDeleted = 0
      AND (@EmployeeId IS NULL OR e.EmployeeId = @EmployeeId)
      AND e.HireDate < @NextJ1
      AND (e.TerminationDate IS NULL OR e.TerminationDate >= @Jan1)
      AND EXISTS (SELECT 1 FROM hr.LEAVE_ACCRUAL_TIER a2 WHERE a2.LeaveTypeId = lt.LeaveTypeId)
      AND NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER l2
                      WHERE l2.EmployeeId = e.EmployeeId AND l2.LeaveTypeId = lt.LeaveTypeId
                        AND l2.PeriodYearMonth = @Period
                        AND l2.MovementType = 'Accrual'
                        AND l2.Note LIKE N'Annual entitlement%');

    BEGIN TRAN;

    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType,
                                 Days, EffectiveDate, Note, CreatedBy)
    SELECT EmployeeId, LeaveTypeId, @Period, 'Adjustment',
           -PrevRemaining, @Jan1,
           CASE WHEN CarryOver = 1 AND @Cap IS NOT NULL AND PrevRemaining > @Cap
                THEN CONCAT(N'Year close ', @PrevYr, N' — ', FORMAT(@Cap, '0.##'), N' moved to carry-over; ', FORMAT(PrevRemaining - @Cap, '0.##'), N' beyond the cap lapsed.')
                WHEN CarryOver = 1
                THEN CONCAT(N'Year close ', @PrevYr, N' — moved to carry-over.')
                ELSE CONCAT(N'Unused ', @PrevYr, N' days expired (no carry-over).') END,
           @ActedByUserId
    FROM #grant WHERE PrevRemaining > 0;

    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType,
                                 Days, EffectiveDate, Note, CreatedBy)
    SELECT EmployeeId, LeaveTypeId, @Period, 'CarryOver',
           CASE WHEN @Cap IS NOT NULL AND PrevRemaining > @Cap THEN @Cap ELSE PrevRemaining END, @Jan1,
           CONCAT(N'Carried over from ', @PrevYr, N'.'), @ActedByUserId
    FROM #grant WHERE PrevRemaining > 0 AND CarryOver = 1 AND (@Cap IS NULL OR @Cap > 0);

    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType,
                                 Days, EffectiveDate, Note, CreatedBy)
    SELECT EmployeeId, LeaveTypeId, @Period, 'Accrual',
           GrantDays, @Jan1,
           CASE WHEN Prorated = 1
                THEN CONCAT(N'Annual entitlement ', @Year, N' (prorated from ',
                            FORMAT(HireDate, 'MMM yyyy'), N').')
                ELSE CONCAT(N'Annual entitlement ', @Year, N'.') END,
           @ActedByUserId
    FROM #grant WHERE GrantDays > 0;

    COMMIT;

    SELECT LeaveTypeName,
           COUNT(*)                                          AS EmployeesOpened,
           SUM(GrantDays)                                    AS DaysGranted,
           SUM(CASE WHEN Prorated = 1 THEN 1 ELSE 0 END)     AS ProratedEmployees,
           SUM(CASE WHEN CarryOver = 1 AND PrevRemaining > 0
                    THEN CASE WHEN @Cap IS NOT NULL AND PrevRemaining > @Cap THEN @Cap ELSE PrevRemaining END ELSE 0 END) AS DaysCarriedOver,
           SUM(CASE WHEN CarryOver = 0 AND PrevRemaining > 0 THEN PrevRemaining
                    WHEN CarryOver = 1 AND @Cap IS NOT NULL AND PrevRemaining > @Cap THEN PrevRemaining - @Cap
                    ELSE 0 END)                              AS DaysExpired
    FROM #grant
    GROUP BY LeaveTypeName ORDER BY LeaveTypeName;
END;
GO

CREATE OR ALTER VIEW [hr].[vw_LEAVE_BALANCE] AS
SELECT
    EmployeeId,
    LeaveTypeId,
    PeriodYearMonth,
    SUM(CASE WHEN MovementType = 'Accrual'    THEN Days ELSE 0 END) AS Accrued,
    SUM(CASE WHEN MovementType = 'CarryOver'  THEN Days ELSE 0 END) AS CarriedOver,
    SUM(CASE WHEN MovementType = 'Usage'      THEN -Days ELSE 0 END) AS Used,
    /* script 84 (D4): an 'Expiry' of carried-over days is shown with the adjustments, so the identity on screen still adds up:
       Remaining = Accrued + CarriedOver − Used + Adjusted */
    SUM(CASE WHEN MovementType IN ('Adjustment', 'Expiry') THEN Days ELSE 0 END) AS Adjusted,
    SUM(Days)                                                       AS Remaining
FROM hr.LEAVE_LEDGER
GROUP BY EmployeeId, LeaveTypeId, PeriodYearMonth;
GO

/* ───────────────────────── 7b. the half day is part of what a leave request IS: the two reads carry it ───────────────────────── */
CREATE OR ALTER PROCEDURE [workflow].[usp_LeaveRequest_GetPayload]
    @RequestInstanceId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT lr.LeaveRequestId, lr.EmployeeId, e.FullName AS EmployeeName,
           lr.LeaveTypeId, lt.Name AS LeaveTypeName, lt.IsPaid,
           lr.FromDate, lr.ToDate, lr.DaysRequested, lr.DaysApproved,
           lr.Reason, lr.AppliedToLedgerAt,
           lr.RelationToEmployee,
           lt.RequiresCertificate,
           lr.IsDiscretionary,
           att.AttachmentCount,
           bal.CurrentBalance,
           n.NoticeGivenDays,
           lt.NoticePreferredDays,
           CAST(CASE WHEN lt.NoticePreferredDays > 0
                      AND n.NoticeGivenDays < lt.NoticePreferredDays
                     THEN 1 ELSE 0 END AS BIT) AS NoticeShorterThanPreferred,
           lr.HalfDay                       -- script 84 (D3): 'AM' | 'PM' | NULL
    FROM workflow.LEAVE_REQUEST lr
    JOIN hr.EMPLOYEE e    ON e.EmployeeId  = lr.EmployeeId
    JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId = lr.LeaveTypeId
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
    OUTER APPLY (SELECT DATEDIFF(DAY, CAST(ri.SubmittedAt AS DATE), lr.FromDate)
                 AS NoticeGivenDays) n
    OUTER APPLY (SELECT ISNULL(SUM(Days),0) AS CurrentBalance
                 FROM hr.LEAVE_LEDGER ll
                 WHERE ll.EmployeeId = lr.EmployeeId
                   AND ll.LeaveTypeId = lr.LeaveTypeId) bal
    OUTER APPLY (SELECT COUNT(*) AS AttachmentCount
                 FROM workflow.REQUEST_ATTACHMENT ra
                 WHERE ra.RequestInstanceId = lr.RequestInstanceId) att
    WHERE lr.RequestInstanceId = @RequestInstanceId;
END;
GO

CREATE OR ALTER PROCEDURE workflow.usp_LeaveRequest_GetForEmployee
    @EmployeeId INT, @FromDate DATE = NULL, @ToDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT lr.LeaveRequestId, lr.RequestInstanceId, r.[Status],
           lt.Name AS LeaveTypeName, lr.FromDate, lr.ToDate,
           lr.DaysRequested, lr.DaysApproved, lr.Reason, r.SubmittedAt,
           lr.HalfDay                       -- script 84 (D3)
    FROM workflow.LEAVE_REQUEST lr
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = lr.RequestInstanceId
    JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId = lr.LeaveTypeId
    WHERE lr.EmployeeId = @EmployeeId
      AND (@FromDate IS NULL OR lr.ToDate   >= @FromDate)
      AND (@ToDate   IS NULL OR lr.FromDate <= @ToDate)
    ORDER BY lr.FromDate DESC;
END;
GO

/* ───────────────────────── 8. D4: carried-over days expire ───────────────────────── */
CREATE OR ALTER PROCEDURE hr.usp_LeaveCarryOver_Expire
    @AsOfDate      DATE = NULL,              -- NULL = today in Beirut; a caller passes a date only to test the rule
    @ExpiresOn     VARCHAR(5) = NULL,        -- 'MM-DD'; NULL = the LeaveCarryOverExpiresOn setting (empty = never)
    @EmployeeId    INT = NULL,
    @ActedByUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Today DATE = ISNULL(@AsOfDate, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));
    DECLARE @MmDd VARCHAR(5) = NULLIF(LTRIM(RTRIM(ISNULL(@ExpiresOn, (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'LeaveCarryOverExpiresOn')))), '');
    DECLARE @Expiry DATE = TRY_CAST(CONCAT(YEAR(@Today), '-', @MmDd) AS DATE);
    /* nothing configured, not a date, or the day has not passed yet: nothing expires */
    IF @Expiry IS NULL OR @Today <= @Expiry
    BEGIN SELECT CAST(0 AS INT) AS EmployeesExpired, CAST(0 AS DECIMAL(9,2)) AS DaysExpired; RETURN; END

    DECLARE @Year INT = YEAR(@Today);
    DECLARE @x TABLE (EmployeeId INT, LeaveTypeId INT, Unused DECIMAL(9,2));
    /* usage consumes the carried days first: what is unused = carried − the usage of this year up to the expiry date */
    INSERT INTO @x
    SELECT c.EmployeeId, c.LeaveTypeId, c.Carried - ISNULL(u.Used, 0)
    FROM (SELECT EmployeeId, LeaveTypeId, SUM(Days) AS Carried FROM hr.LEAVE_LEDGER
          WHERE MovementType = 'CarryOver' AND YEAR(EffectiveDate) = @Year AND (@EmployeeId IS NULL OR EmployeeId = @EmployeeId)
          GROUP BY EmployeeId, LeaveTypeId) c
    OUTER APPLY (SELECT -SUM(l.Days) AS Used FROM hr.LEAVE_LEDGER l
                 WHERE l.EmployeeId = c.EmployeeId AND l.LeaveTypeId = c.LeaveTypeId AND l.MovementType = 'Usage'
                   AND l.EffectiveDate >= DATEFROMPARTS(@Year, 1, 1) AND l.EffectiveDate <= @Expiry) u
    WHERE c.Carried - ISNULL(u.Used, 0) > 0
      AND NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER e WHERE e.EmployeeId = c.EmployeeId AND e.LeaveTypeId = c.LeaveTypeId
                        AND e.MovementType = 'Expiry' AND YEAR(e.EffectiveDate) = @Year);       -- once per employee, type and year

    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note, CreatedBy)
    SELECT EmployeeId, LeaveTypeId, CONVERT(CHAR(7), @Expiry, 23), 'Expiry', -Unused, @Expiry,
           CONCAT(FORMAT(Unused, '0.##'), N' day(s) carried over from ', @Year - 1, N' were still unused on ', CONVERT(CHAR(10), @Expiry, 23), N' and expired.'),
           @ActedByUserId
    FROM @x;

    SELECT COUNT(*) AS EmployeesExpired, ISNULL(SUM(Unused), 0) AS DaysExpired FROM @x;
END;
GO

/* ───────────────────────── 9. verification ───────────────────────── */
DECLARE @p INT = (SELECT COUNT(*) FROM sys.parameters WHERE (object_id = OBJECT_ID('workflow.usp_LeaveRequest_Create') AND name = '@HalfDay')
                                                         OR (object_id = OBJECT_ID('hr.usp_LeaveYear_Open') AND name IN ('@EmployeeId', '@CarryOverMaxDays')));
PRINT CONCAT('new parameters present = ', @p, ' (expected 3)');
PRINT CONCAT('poster = ', CASE WHEN OBJECT_ID('hr.usp_LeaveLedger_PostRequest') IS NULL THEN 'missing' ELSE 'present' END,
             ', expiry = ', CASE WHEN OBJECT_ID('hr.usp_LeaveCarryOver_Expire') IS NULL THEN 'missing' ELSE 'present' END);
PRINT 'Script 84 applied.';
GO
