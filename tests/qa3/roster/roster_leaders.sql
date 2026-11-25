/* ============================================================================
   tests/qa3/roster/roster_leaders.sql -- script 123 (docs/123_roster_leaders.sql).
   - The setting RosterNewHireSixDayMonths is there (int, Section Roster, 3 unless HR chose another value).
   - usp_AutoRoster_GetShiftHours gives every version of a shift in force during a period (the one in force on the
     first day and each one starting inside), and a shift without any version its own hours from 2000-01-01.
   - usp_AutoRoster_SaveLeaders replaces the branch's own list (a leader kept keeps who added them, duplicates count
     once, an empty list clears it); usp_AutoRoster_GetLeaders gives that list UNION the rotation list's Lead 1 /
     Lead 2, one row per person. A leader moved to another branch may be kept, not added; somebody of another branch
     is refused by name, and so is somebody who has left the company. usp_AutoRoster_GetLeaderCandidates lists exactly
     the people a save accepts as new leaders: the branch's people today, still employed - so the drawer's picker never
     offers somebody the save refuses. The scope is the auto-roster's: EMP_VIEW_ALL or the branch's manager.
   Runs on a real dev database: everything inside one transaction that is rolled back; seeded rows start with 'QA3 '
   (users 'qa3.lead.*'). The refusals come last (a refused save leaves the transaction uncommittable, trap 21).
   Prints 'ok roster_leaders', or raises the first wrong result. Needs 116, 117 and 123.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
BEGIN TRAN;
BEGIN TRY
    DECLARE @msg NVARCHAR(2000), @err NVARCHAR(2000), @n INT;
    DECLARE @NotYours NVARCHAR(200) = N'You can only plan rosters for the branches you manage.';
    DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
    DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);

    /* ---- the setting ---- */
    IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'RosterNewHireSixDayMonths' AND DataType = 'int' AND Section = 'Roster'
                   AND TRY_CAST(SettingValue AS INT) IS NOT NULL AND [Description] LIKE N'%6 days every week%')
        RAISERROR('FAIL roster_leaders: the setting RosterNewHireSixDayMonths is missing or not an int of the Roster section.', 16, 1);

    /* ---- the dated hours over a period ---- */
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
    VALUES (N'QA3 Lead Dated', '08:00', '16:00', NULL, 0, 30, 1);
    DECLARE @S INT = SCOPE_IDENTITY();
    INSERT INTO attendance.SHIFT_HOURS (ShiftId, EffectiveFrom, StartTime, EndTime, CrossesMidnight, BreakMinutes)
    VALUES (@S, '2000-01-01', '08:00', '16:00', 0, 30), (@S, '2026-03-01', '09:00', '17:00', 0, 30),
           (@S, '2026-06-01', '10:00', '18:00', 0, 45), (@S, '2026-09-01', '22:00', '06:00', 1, 30);
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
    VALUES (N'QA3 Lead No history', '11:00', '19:00', NULL, 0, 15, 0);       -- inactive, and no SHIFT_HOURS row
    DECLARE @S2 INT = SCOPE_IDENTITY();

    DECLARE @h TABLE (ShiftId INT, EffectiveFrom DATE, StartTime TIME, EndTime TIME, CrossesMidnight BIT, BreakMinutes INT);
    INSERT INTO @h EXEC attendance.usp_AutoRoster_GetShiftHours @FromDate = '2026-04-15', @ToDate = '2026-08-31';
    SET @msg = (SELECT STRING_AGG(CONVERT(CHAR(10), EffectiveFrom, 120), ',') WITHIN GROUP (ORDER BY EffectiveFrom) FROM @h WHERE ShiftId = @S);
    IF ISNULL(@msg, '') <> '2026-03-01,2026-06-01'
    BEGIN SET @msg = CONCAT('FAIL roster_leaders: 15 Apr - 31 Aug should give the versions of 1 Mar and 1 Jun, got ', ISNULL(@msg, 'none')); RAISERROR(@msg, 16, 1); END
    IF NOT EXISTS (SELECT 1 FROM @h WHERE ShiftId = @S AND EffectiveFrom = '2026-06-01' AND StartTime = '10:00' AND EndTime = '18:00' AND CrossesMidnight = 0 AND BreakMinutes = 45)
        RAISERROR('FAIL roster_leaders: the version of 1 Jun does not carry its own hours.', 16, 1);
    IF NOT EXISTS (SELECT 1 FROM @h WHERE ShiftId = @S2 AND EffectiveFrom = '2000-01-01' AND StartTime = '11:00' AND EndTime = '19:00' AND BreakMinutes = 15)
        RAISERROR('FAIL roster_leaders: a shift without any version should answer with its own hours from 2000-01-01.', 16, 1);
    IF EXISTS (SELECT 1 FROM @h GROUP BY ShiftId, EffectiveFrom HAVING COUNT(*) > 1)
        RAISERROR('FAIL roster_leaders: a version of a shift is listed twice.', 16, 1);
    IF EXISTS (SELECT 1 FROM attendance.SHIFT s WHERE NOT EXISTS (SELECT 1 FROM @h x WHERE x.ShiftId = s.ShiftId))
        RAISERROR('FAIL roster_leaders: a shift has no hours in force for the period.', 16, 1);

    DELETE FROM @h;
    INSERT INTO @h EXEC attendance.usp_AutoRoster_GetShiftHours @FromDate = '2026-06-01', @ToDate = '2026-09-01';
    SET @msg = (SELECT STRING_AGG(CONVERT(CHAR(10), EffectiveFrom, 120), ',') WITHIN GROUP (ORDER BY EffectiveFrom) FROM @h WHERE ShiftId = @S);
    IF ISNULL(@msg, '') <> '2026-06-01,2026-09-01'
    BEGIN SET @msg = CONCAT('FAIL roster_leaders: 1 Jun - 1 Sep should give the versions of 1 Jun and 1 Sep, got ', ISNULL(@msg, 'none')); RAISERROR(@msg, 16, 1); END
    IF NOT EXISTS (SELECT 1 FROM @h WHERE ShiftId = @S AND EffectiveFrom = '2026-09-01' AND CrossesMidnight = 1)
        RAISERROR('FAIL roster_leaders: the overnight version lost its flag.', 16, 1);

    DELETE FROM @h;
    INSERT INTO @h EXEC attendance.usp_AutoRoster_GetShiftHours @FromDate = '2026-03-01', @ToDate = '2026-03-01';
    SET @msg = (SELECT STRING_AGG(CONVERT(CHAR(10), EffectiveFrom, 120), ',') FROM @h WHERE ShiftId = @S);
    IF ISNULL(@msg, '') <> '2026-03-01'
    BEGIN SET @msg = CONCAT('FAIL roster_leaders: the single day 1 Mar should give only its own version, got ', ISNULL(@msg, 'none')); RAISERROR(@msg, 16, 1); END

    /* ---- two branches, their managers, HR, and the people ---- */
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Lead Branch A', 1);
    DECLARE @BA INT = SCOPE_IDENTITY();
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Lead Branch B', 1);
    DECLARE @BB INT = SCOPE_IDENTITY();
    INSERT INTO security.[USER] (Username, PasswordHash, IsActive)
    VALUES (N'qa3.lead.mgra', N'x', 1), (N'qa3.lead.mgrb', N'x', 1), (N'qa3.lead.hr', N'x', 1);
    DECLARE @UMgrA INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.lead.mgra');
    DECLARE @UMgrB INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.lead.mgrb');
    DECLARE @UHr   INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.lead.hr');
    INSERT INTO security.[ROLE] (Name) VALUES (N'QA3 Lead HR');
    DECLARE @RoleHr INT = SCOPE_IDENTITY();
    INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId) SELECT @RoleHr, PermissionId FROM security.PERMISSION WHERE Code = 'EMP_VIEW_ALL';
    INSERT INTO security.USER_ROLE (UserId, RoleId) VALUES (@UHr, @RoleHr);
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate)
    VALUES (@UMgrA, @BA, @Dep, @Pos, N'QA3 Lead Manager A', '2020-01-01'),
           (@UMgrB, @BB, @Dep, @Pos, N'QA3 Lead Manager B', '2020-01-01'),
           (@UHr,   @BA, @Dep, @Pos, N'QA3 Lead HR Officer', '2020-01-01'),
           (NULL,   @BA, @Dep, @Pos, N'QA3 Lead Amal', '2020-01-01'),
           (NULL,   @BA, @Dep, @Pos, N'QA3 Lead Bilal', '2020-01-01'),
           (NULL,   @BA, @Dep, @Pos, N'QA3 Lead Carla', '2020-01-01'),
           (NULL,   @BB, @Dep, @Pos, N'QA3 Lead Dina of B', '2020-01-01');
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate)
    VALUES (NULL, @BA, @Dep, @Pos, N'QA3 Lead Elie left', '2020-01-01', DATEADD(DAY, -1, @Today)),
           (NULL, @BA, @Dep, @Pos, N'QA3 Lead Fadi leaving', '2020-01-01', DATEADD(DAY, 30, @Today));
    DECLARE @MgrA INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Lead Manager A');
    DECLARE @MgrB INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Lead Manager B');
    DECLARE @A1 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Lead Amal');
    DECLARE @A2 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Lead Bilal');
    DECLARE @A3 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Lead Carla');
    DECLARE @B1 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Lead Dina of B');
    DECLARE @Left INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Lead Elie left');
    UPDATE hr.BRANCH SET ManagerEmployeeId = @MgrA WHERE BranchId = @BA;
    UPDATE hr.BRANCH SET ManagerEmployeeId = @MgrB WHERE BranchId = @BB;

    DECLARE @r TABLE (Leaders INT);
    DECLARE @l TABLE (EmployeeId INT, FullName NVARCHAR(150), IsStored BIT, LeadSlot VARCHAR(2));
    DECLARE @list NVARCHAR(MAX);
    DECLARE @c TABLE (EmployeeId INT, FullName NVARCHAR(150));

    /* ---- who the picker may add: the branch's people today, still employed (Elie left yesterday; Fadi leaves next month) ---- */
    INSERT INTO @c EXEC attendance.usp_AutoRoster_GetLeaderCandidates @BranchId = @BA, @CallerUserId = @UMgrA;
    SET @msg = (SELECT STRING_AGG(FullName, ' | ') WITHIN GROUP (ORDER BY FullName) FROM @c);
    IF ISNULL(@msg, '') <> 'QA3 Lead Amal | QA3 Lead Bilal | QA3 Lead Carla | QA3 Lead Fadi leaving | QA3 Lead HR Officer | QA3 Lead Manager A'
    BEGIN SET @msg = CONCAT('FAIL roster_leaders: branch A''s candidates should be its people today who still work here; got ', ISNULL(@msg, 'none')); RAISERROR(@msg, 16, 1); END
    DELETE FROM @c;
    INSERT INTO @c EXEC attendance.usp_AutoRoster_GetLeaderCandidates @BranchId = @BB, @CallerUserId = @UHr;
    SET @msg = (SELECT STRING_AGG(FullName, ' | ') WITHIN GROUP (ORDER BY FullName) FROM @c);
    IF ISNULL(@msg, '') <> 'QA3 Lead Dina of B | QA3 Lead Manager B'
    BEGIN SET @msg = CONCAT('FAIL roster_leaders: branch B''s candidates should be only its own people; got ', ISNULL(@msg, 'none')); RAISERROR(@msg, 16, 1); END

    /* ---- nothing stored and no rotation: nobody ---- */
    INSERT INTO @l EXEC attendance.usp_AutoRoster_GetLeaders @BranchId = @BA, @CallerUserId = @UMgrA;
    IF EXISTS (SELECT 1 FROM @l)
        RAISERROR('FAIL roster_leaders: a branch with no list and no rotation already has leaders.', 16, 1);

    /* ---- the manager saves two leaders, one of them twice ---- */
    SET @list = CONCAT(N'[', @A1, N',', @A2, N',', @A2, N']');
    INSERT INTO @r EXEC attendance.usp_AutoRoster_SaveLeaders @BranchId = @BA, @EmployeeIdsJson = @list, @CallerUserId = @UMgrA;
    IF (SELECT TOP 1 Leaders FROM @r) <> 2 OR (SELECT COUNT(*) FROM attendance.ROSTER_SHIFT_LEADER WHERE BranchId = @BA) <> 2
        RAISERROR('FAIL roster_leaders: saving Amal, Bilal and Bilal again should store two leaders.', 16, 1);
    IF EXISTS (SELECT 1 FROM attendance.ROSTER_SHIFT_LEADER WHERE BranchId = @BA AND ISNULL(CreatedByUserId, -1) <> @UMgrA)
        RAISERROR('FAIL roster_leaders: a stored leader does not say who added them.', 16, 1);

    /* ---- the rotation list's leads count too: Carla is Lead 1, Amal Lead 2 ---- */
    INSERT INTO attendance.ROSTER_ROTATION_MEMBER (EmployeeId, RotationGroup, SingleRestDay, PairRestDay, LeadSlot, SortOrder)
    VALUES (@A3, 0, 0, 1, 'L1', 1), (@A1, 1, 2, 3, 'L2', 2), (@MgrA, 0, 4, 5, NULL, 3), (@B1, 0, 0, 1, 'L1', 1);
    DELETE FROM @l;
    INSERT INTO @l EXEC attendance.usp_AutoRoster_GetLeaders @BranchId = @BA, @CallerUserId = @UMgrA;
    SET @msg = (SELECT STRING_AGG(CONCAT(FullName, ':', IIF(IsStored = 1, 'stored', '-'), ':', ISNULL(LeadSlot, '-')), ' | ')
                       WITHIN GROUP (ORDER BY FullName) FROM @l);
    IF ISNULL(@msg, '') <> 'QA3 Lead Amal:stored:L2 | QA3 Lead Bilal:stored:- | QA3 Lead Carla:-:L1'
    BEGIN SET @msg = CONCAT('FAIL roster_leaders: the leaders should be the stored list and the rotation''s leads, one row each; got ', ISNULL(@msg, 'none')); RAISERROR(@msg, 16, 1); END

    /* ---- HR replaces the list: Amal goes (still Lead 2 of the rotation), Bilal stays as the manager added him ---- */
    SET @list = CONCAT(N'[', @A2, N']');
    DELETE FROM @r;
    INSERT INTO @r EXEC attendance.usp_AutoRoster_SaveLeaders @BranchId = @BA, @EmployeeIdsJson = @list, @CallerUserId = @UHr;
    IF EXISTS (SELECT 1 FROM attendance.ROSTER_SHIFT_LEADER WHERE BranchId = @BA AND EmployeeId = @A1)
        RAISERROR('FAIL roster_leaders: a leader taken off the list is still stored.', 16, 1);
    IF NOT EXISTS (SELECT 1 FROM attendance.ROSTER_SHIFT_LEADER WHERE BranchId = @BA AND EmployeeId = @A2 AND CreatedByUserId = @UMgrA)
        RAISERROR('FAIL roster_leaders: a leader kept on the list lost who added them.', 16, 1);
    DELETE FROM @l;
    INSERT INTO @l EXEC attendance.usp_AutoRoster_GetLeaders @BranchId = @BA, @CallerUserId = @UHr;
    IF NOT EXISTS (SELECT 1 FROM @l WHERE EmployeeId = @A1 AND IsStored = 0 AND LeadSlot = 'L2') OR (SELECT COUNT(*) FROM @l) <> 3
        RAISERROR('FAIL roster_leaders: Lead 2 of the rotation should stay a leader when taken off the list.', 16, 1);

    /* ---- the other branch's leader is not this branch's ---- */
    DELETE FROM @l;
    INSERT INTO @l EXEC attendance.usp_AutoRoster_GetLeaders @BranchId = @BB, @CallerUserId = @UMgrB;
    IF (SELECT COUNT(*) FROM @l) <> 1 OR NOT EXISTS (SELECT 1 FROM @l WHERE EmployeeId = @B1 AND LeadSlot = 'L1' AND IsStored = 0)
        RAISERROR('FAIL roster_leaders: branch B should have only its own Lead 1.', 16, 1);

    /* ---- a leader moved to branch B may be kept on A's list (the days still worked there), not added again ---- */
    UPDATE hr.EMPLOYEE SET BranchId = @BB WHERE EmployeeId = @A2;
    SET @list = CONCAT(N'[', @A2, N',', @A3, N']');
    INSERT INTO @r EXEC attendance.usp_AutoRoster_SaveLeaders @BranchId = @BA, @EmployeeIdsJson = @list, @CallerUserId = @UMgrA;
    IF (SELECT COUNT(*) FROM attendance.ROSTER_SHIFT_LEADER WHERE BranchId = @BA AND EmployeeId IN (@A2, @A3)) <> 2
        RAISERROR('FAIL roster_leaders: a leader who moved to another branch could not be kept with a new one.', 16, 1);

    /* ---- the candidates follow the move: Bilal is B's now, not A's ---- */
    DELETE FROM @c;
    INSERT INTO @c EXEC attendance.usp_AutoRoster_GetLeaderCandidates @BranchId = @BA, @CallerUserId = @UMgrA;
    IF EXISTS (SELECT 1 FROM @c WHERE EmployeeId = @A2) OR (SELECT COUNT(*) FROM @c) <> 5
        RAISERROR('FAIL roster_leaders: somebody who moved to another branch is still a candidate of the old one.', 16, 1);
    DELETE FROM @c;
    INSERT INTO @c EXEC attendance.usp_AutoRoster_GetLeaderCandidates @BranchId = @BB, @CallerUserId = @UMgrB;
    IF NOT EXISTS (SELECT 1 FROM @c WHERE EmployeeId = @A2)
        RAISERROR('FAIL roster_leaders: somebody who moved in is not a candidate of the new branch.', 16, 1);

    /* ---- every candidate is accepted: the picker never offers somebody the save refuses ---- */
    DELETE FROM @c;
    INSERT INTO @c EXEC attendance.usp_AutoRoster_GetLeaderCandidates @BranchId = @BA, @CallerUserId = @UMgrA;
    SET @list = (SELECT CONCAT(N'[', STRING_AGG(CAST(EmployeeId AS NVARCHAR(12)), N','), N']') FROM @c);
    DELETE FROM @r;
    INSERT INTO @r EXEC attendance.usp_AutoRoster_SaveLeaders @BranchId = @BA, @EmployeeIdsJson = @list, @CallerUserId = @UMgrA;
    IF (SELECT TOP 1 Leaders FROM @r) <> 5
        OR EXISTS (SELECT 1 FROM @c x WHERE NOT EXISTS (SELECT 1 FROM attendance.ROSTER_SHIFT_LEADER l WHERE l.BranchId = @BA AND l.EmployeeId = x.EmployeeId))
        RAISERROR('FAIL roster_leaders: saving every candidate of branch A should store all five.', 16, 1);

    /* ---- an empty list clears the branch's own leaders; the rotation's leads remain ---- */
    INSERT INTO @r EXEC attendance.usp_AutoRoster_SaveLeaders @BranchId = @BA, @EmployeeIdsJson = N'[]', @CallerUserId = @UMgrA;
    IF EXISTS (SELECT 1 FROM attendance.ROSTER_SHIFT_LEADER WHERE BranchId = @BA)
        RAISERROR('FAIL roster_leaders: an empty list did not clear the branch''s leaders.', 16, 1);
    DELETE FROM @l;
    INSERT INTO @l EXEC attendance.usp_AutoRoster_GetLeaders @BranchId = @BA, @CallerUserId = NULL;     -- the system itself sees all
    SET @msg = (SELECT STRING_AGG(CONCAT(FullName, ':', ISNULL(LeadSlot, '-')), ' | ') WITHIN GROUP (ORDER BY FullName) FROM @l);
    IF ISNULL(@msg, '') <> 'QA3 Lead Amal:L2 | QA3 Lead Carla:L1'
    BEGIN SET @msg = CONCAT('FAIL roster_leaders: after clearing, only the rotation''s leads should remain; got ', ISNULL(@msg, 'none')); RAISERROR(@msg, 16, 1); END

    /* ---- refusals (last: a refused save leaves the transaction uncommittable) ---- */
    DECLARE @doors TABLE (Door VARCHAR(60), Expected NVARCHAR(400), Got NVARCHAR(2000));
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_AutoRoster_GetLeaders @BranchId = @BA, @CallerUserId = @UMgrB; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('read another branch', @NotYours, @err);
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_AutoRoster_GetLeaders @BranchId = -1, @CallerUserId = @UHr; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('read no branch', N'Branch not found.', @err);
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_AutoRoster_GetShiftHours @FromDate = '2026-05-02', @ToDate = '2026-05-01'; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('hours, upside-down period', N'Give a real period: a first day on or before the last day.', @err);
    SET @list = CONCAT(N'[', @A3, N']');
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_AutoRoster_SaveLeaders @BranchId = @BA, @EmployeeIdsJson = @list, @CallerUserId = @UMgrB; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('save another branch', @NotYours, @err);
    SET @list = CONCAT(N'[', @A3, N',', @A2, N']');     -- Bilal is in branch B now and no longer on A's list
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_AutoRoster_SaveLeaders @BranchId = @BA, @EmployeeIdsJson = @list, @CallerUserId = @UMgrA; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('somebody of another branch', N'QA3 Lead Bilal is not in this branch: only its own people can be its shift leaders.', @err);
    SET @list = CONCAT(N'[', @Left, N']');              -- Elie left the company yesterday and was never on the list
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_AutoRoster_SaveLeaders @BranchId = @BA, @EmployeeIdsJson = @list, @CallerUserId = @UMgrA; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('somebody who left', N'QA3 Lead Elie left is not in this branch: only its own people can be its shift leaders.', @err);
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_AutoRoster_GetLeaderCandidates @BranchId = @BA, @CallerUserId = @UMgrB; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('candidates of another branch', @NotYours, @err);
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_AutoRoster_GetLeaderCandidates @BranchId = -1, @CallerUserId = @UHr; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('candidates of no branch', N'Branch not found.', @err);
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_AutoRoster_SaveLeaders @BranchId = @BA, @EmployeeIdsJson = N'[-5]', @CallerUserId = @UMgrA; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('nobody', N'Somebody on the shift leaders list was not found.', @err);
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_AutoRoster_SaveLeaders @BranchId = @BA, @EmployeeIdsJson = N'["x"]', @CallerUserId = @UMgrA; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('not a number', N'Every line of the shift leaders list needs its employee.', @err);
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_AutoRoster_SaveLeaders @BranchId = @BA, @EmployeeIdsJson = N'{"employeeId": 3}', @CallerUserId = @UMgrA; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('not a list', N'The shift leaders list could not be read.', @err);
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_AutoRoster_SaveLeaders @BranchId = -1, @EmployeeIdsJson = N'[]', @CallerUserId = @UHr; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('save no branch', N'Branch not found.', @err);

    DECLARE @door VARCHAR(60), @expected NVARCHAR(400);
    SELECT TOP 1 @door = Door, @expected = Expected, @err = Got FROM @doors WHERE Got IS NULL OR Got <> Expected ORDER BY Door;
    IF @door IS NOT NULL
    BEGIN SET @msg = CONCAT('FAIL roster_leaders: ', @door, ': expected "', @expected, '", got ', ISNULL(@err, 'no refusal')); RAISERROR(@msg, 16, 1); END
    IF EXISTS (SELECT 1 FROM attendance.ROSTER_SHIFT_LEADER WHERE BranchId = @BA)
        RAISERROR('FAIL roster_leaders: a refused save still wrote the list.', 16, 1);

    ROLLBACK;
    PRINT 'ok roster_leaders';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    DECLARE @failure NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR(@failure, 16, 1);
END CATCH;
