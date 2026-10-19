/* QA3 attendance (unit B) - ATT-12, REL-8 (a PIN enrolled for somebody else is refused, by name) and the quarantine:
   punches of a PIN that belongs to nobody can be set aside, and come back when the PIN is mapped after all.
   Runs on a dev database with docs/100_qa3_attendance.sql applied, inside a transaction that is rolled back. */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
BEGIN TRAN;
DECLARE @fails INT = 0, @msg NVARCHAR(2048);
DECLARE @B INT, @E1 INT, @E2 INT, @Dev INT, @U INT;
DECLARE @m TABLE (OrphanPunchesResolved INT);
DECLARE @dis TABLE (PunchesDismissed INT);
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Att Branch'); SET @B = SCOPE_IDENTITY();
INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate)
SELECT @B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), v.n, '2025-01-01'
FROM (VALUES (N'QA3 Att Pin One'), (N'QA3 Att Pin Two')) v(n);
SELECT @E1 = MIN(EmployeeId), @E2 = MAX(EmployeeId) FROM hr.EMPLOYEE WHERE BranchId = @B;
INSERT INTO attendance.DEVICE (SerialNumber, BranchId, [Name]) VALUES (CONCAT('QA3-ATT-', @B), @B, N'QA3 device'); SET @Dev = SCOPE_IDENTITY();
SET @U = (SELECT TOP 1 UserId FROM security.[USER] ORDER BY UserId);

/* PIN Q105 is E1's; mapping it to E1 again is fine */
INSERT INTO @m EXEC attendance.usp_EmployeeDevice_Map @EmployeeId = @E1, @DeviceId = @Dev, @EnrollPin = 'Q105';
INSERT INTO @m EXEC attendance.usp_EmployeeDevice_Map @EmployeeId = @E1, @DeviceId = @Dev, @EnrollPin = 'Q105';
IF (SELECT COUNT(*) FROM attendance.EMPLOYEE_DEVICE WHERE DeviceId = @Dev AND EnrollPin = 'Q105') <> 1
    BEGIN SET @fails += 1; RAISERROR('07: the enrolment was not recorded once.', 16, 1); END

/* PIN Q999 belongs to nobody: two punches wait; HR sets them aside; then learns it was E2 after all and maps it */
INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
VALUES (@Dev, 'Q999', NULL, '2026-09-21 07:00', 0, 'Device', CONVERT(VARCHAR(64), NEWID())),
       (@Dev, 'Q999', NULL, '2026-09-21 15:00', 1, 'Device', CONVERT(VARCHAR(64), NEWID()));
IF (SELECT COUNT(*) FROM attendance.DEVICE_PUNCH_QUARANTINE WHERE DeviceId = @Dev AND EnrollPin = 'Q999') <> 2
    BEGIN SET @fails += 1; RAISERROR('07: the unknown PIN''s punches are not waiting.', 16, 1); END
INSERT INTO @dis EXEC attendance.usp_DevicePunchQuarantine_Dismiss @DeviceId = @Dev, @EnrollPin = 'Q999', @Note = N'QA3 a visitor tried the terminal', @ActedByUserId = @U;
IF (SELECT PunchesDismissed FROM @dis) <> 2
   OR EXISTS (SELECT 1 FROM attendance.DEVICE_PUNCH_QUARANTINE WHERE DeviceId = @Dev AND EnrollPin = 'Q999')
    BEGIN SET @fails += 1; RAISERROR('07: setting the punches aside did not take them off the quarantine.', 16, 1); END
IF (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG WHERE DeviceId = @Dev AND EnrollPin = 'Q999' AND DismissedUtc IS NOT NULL) <> 2
    BEGIN SET @fails += 1; RAISERROR('07: the set-aside punches are not kept (the device would send them again).', 16, 1); END
DELETE FROM @m;
INSERT INTO @m EXEC attendance.usp_EmployeeDevice_Map @EmployeeId = @E2, @DeviceId = @Dev, @EnrollPin = 'Q999';
IF (SELECT OrphanPunchesResolved FROM @m) <> 2
   OR EXISTS (SELECT 1 FROM attendance.RAW_DEVICE_LOG WHERE DeviceId = @Dev AND EnrollPin = 'Q999' AND (EmployeeId IS NULL OR DismissedUtc IS NOT NULL))
    BEGIN SET @fails += 1; RAISERROR('07: mapping the PIN did not take back the punches set aside.', 16, 1); END

/* the refusals (last): Q105 is E1's - mapping it to E2 names E1; setting aside an enrolled PIN's punches */
SET @msg = NULL;
BEGIN TRY INSERT INTO @m EXEC attendance.usp_EmployeeDevice_Map @EmployeeId = @E2, @DeviceId = @Dev, @EnrollPin = 'Q105';
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%already enrolled for QA3 Att Pin One%'
    BEGIN SET @fails += 1; RAISERROR('07: a PIN enrolled for another employee was not refused by name (%s).', 16, 1, @msg); END
IF NOT EXISTS (SELECT 1 FROM attendance.EMPLOYEE_DEVICE WHERE DeviceId = @Dev AND EnrollPin = 'Q105' AND EmployeeId = @E1)
    BEGIN SET @fails += 1; RAISERROR('07: the refused remap changed the enrolment.', 16, 1); END
SET @msg = NULL;
BEGIN TRY INSERT INTO @dis EXEC attendance.usp_DevicePunchQuarantine_Dismiss @DeviceId = @Dev, @EnrollPin = 'Q105', @Note = N'QA3', @ActedByUserId = @U;
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%is enrolled for an employee%'
    BEGIN SET @fails += 1; RAISERROR('07: an enrolled PIN''s punches could be set aside (%s).', 16, 1, @msg); END

IF @@TRANCOUNT > 0 ROLLBACK TRAN;
IF @fails = 0 PRINT 'ok 07_devices';
