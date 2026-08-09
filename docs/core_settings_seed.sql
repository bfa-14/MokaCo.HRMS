/* ============================================================================
   CORE SETTINGS - SYSTEM-WIDE  -  RE-RUNNABLE
   SQL Server 2025  -  database MokaCo_HRMS
   ----------------------------------------------------------------------------
   Run AFTER docs/attendance_full_v3.sql (which creates core.SETTING).

   core.SETTING is NOT an attendance table. It is the system's global key/value
   configuration, so policy can change without a code deploy. Attendance happens to
   have been the first feature to need it; payroll and workflow will add their own
   keys here.

   ADDING A NEW SETTING LATER: insert a row here and it appears on the Settings page
   automatically - the page is data-driven and renders whatever the API returns, using
   [Description] as its label. No frontend change is needed to surface a new key. Only
   give it a DataType the UI understands: 'bool', 'int', 'decimal' or 'string'.
   ============================================================================ */
USE MokaCo_HRMS;
GO

/* -- UI preferences --------------------------------------------------------
   ShowPageHelp controls the "What is this page for?" panel at the top of every
   screen. It is SYSTEM-WIDE, not per-user: there is no per-user preference store,
   and the alternative (localStorage) was ruled out. So switching it off switches it
   off for everybody, including the next person who joins and has never seen these
   screens before. That is the trade, and it is why it is worded as a system default
   rather than as "hide help".

   It is READABLE BY ANY SIGNED-IN USER (GET /api/settings/ui) but only writable with
   SETTING_MANAGE - otherwise an HR user could not even find out whether help is on. */
INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, [Description])
SELECT v.SettingKey, v.SettingValue, v.DataType, v.[Description]
FROM (VALUES
    ('ShowPageHelp', 'true', 'bool',
     N'Show the "What is this page for?" help panel at the top of each page. Turn it off once the team knows the system.')
) AS v (SettingKey, SettingValue, DataType, [Description])
WHERE NOT EXISTS (SELECT 1 FROM core.SETTING s WHERE s.SettingKey = v.SettingKey);
GO

SELECT SettingKey, SettingValue, DataType, [Description]
FROM core.SETTING
ORDER BY SettingKey;
GO
