/* deploy/rename-usernames.sql - give employees' accounts a login made from their full name. Data change, no schema.
   Run PREVIEW first (APPLY=0), read the list, then APPLY=1. Test database first, then production after a backup.
     sqlcmd -S 127.0.0.1 -U sa -C -I -b -W -d <database> -v STYLE=dot APPLY=0 -i deploy/rename-usernames.sql
*/
/* Rename the login names of employees' accounts from their full name.
   $(STYLE): dot  -> ali.serhan     emp -> AliS.Emp
   $(APPLY): 0 = preview only (nothing changes), 1 = rename.
   Left alone: accounts with no employee, accounts that can manage users or roles (admin / owner), names that are not
   in Latin letters, and accounts whose name already matches. A name taken twice gets 2, 3... Passwords, roles and
   sessions are not touched; only the name typed at sign-in changes. */
SET NOCOUNT ON; SET XACT_ABORT ON;
DECLARE @Style VARCHAR(5) = '$(STYLE)', @Apply BIT = $(APPLY);
DECLARE @c TABLE (UserId INT PRIMARY KEY, OldName NVARCHAR(200), FullName NVARCHAR(200), Base NVARCHAR(200), NewName NVARCHAR(200), Note NVARCHAR(100));

INSERT INTO @c (UserId, OldName, FullName, Base, Note)
SELECT u.UserId, u.Username, e.FullName,
       CASE WHEN n.First = n.Last THEN NULL
            WHEN @Style = 'emp' THEN CONCAT(UPPER(LEFT(n.First, 1)), LOWER(SUBSTRING(n.First, 2, 100)), UPPER(LEFT(n.Last, 1)), '.Emp')
            ELSE LOWER(CONCAT(n.First, '.', n.Last)) END,
       CASE WHEN EXISTS (SELECT 1 FROM security.USER_ROLE ur JOIN security.ROLE_PERMISSION rp ON rp.RoleId = ur.RoleId
                         JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
                         WHERE ur.UserId = u.UserId AND p.Code IN ('USER_MANAGE', 'ROLE_MANAGE')) THEN N'kept: admin account'
            WHEN e.FullName LIKE N'%[^a-zA-Z .''-]%' THEN N'kept: name is not in Latin letters'
            WHEN n.First = n.Last THEN N'kept: only one name'
            ELSE NULL END
FROM security.[USER] u
JOIN hr.EMPLOYEE e ON e.UserId = u.UserId AND e.IsDeleted = 0
CROSS APPLY (SELECT LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(e.FullName, '''', ''), '-', ''), '  ', ' '))) AS N) c
CROSS APPLY (SELECT LEFT(c.N, CHARINDEX(' ', c.N + ' ') - 1) AS First,
                    RIGHT(c.N, CHARINDEX(' ', REVERSE(c.N) + ' ') - 1) AS Last) n;

/* the new names: unique among themselves and against every account left as it is */
;WITH r AS (
    SELECT UserId, Base, ROW_NUMBER() OVER (PARTITION BY Base ORDER BY UserId) AS k FROM @c WHERE Note IS NULL)
UPDATE c SET NewName = CASE WHEN r.k = 1 THEN r.Base ELSE CONCAT(r.Base, r.k) END
FROM @c c JOIN r ON r.UserId = c.UserId;
UPDATE c SET NewName = CONCAT(c.NewName, 'x')            -- taken by an account that is not renamed
FROM @c c
WHERE c.NewName IS NOT NULL AND EXISTS (SELECT 1 FROM security.[USER] u WHERE u.Username = c.NewName AND u.UserId <> c.UserId
                                        AND NOT EXISTS (SELECT 1 FROM @c o WHERE o.UserId = u.UserId AND o.NewName IS NOT NULL));
UPDATE @c SET Note = N'kept: already this name', NewName = NULL WHERE NewName = OldName COLLATE Latin1_General_CS_AS;

DECLARE @n INT = (SELECT COUNT(*) FROM @c WHERE NewName IS NOT NULL);
SELECT FullName, OldName AS [current login], ISNULL(NewName, N'-') AS [new login], ISNULL(Note, N'') AS note
FROM @c ORDER BY CASE WHEN NewName IS NULL THEN 1 ELSE 0 END, FullName;

IF @Apply = 1
BEGIN
    BEGIN TRAN;
    -- two steps, so a swap between two accounts never hits the unique index halfway
    UPDATE u SET Username = CONCAT(N'~rename~', u.UserId) FROM security.[USER] u JOIN @c c ON c.UserId = u.UserId WHERE c.NewName IS NOT NULL;
    UPDATE u SET Username = c.NewName, ModifiedAt = SYSUTCDATETIME() FROM security.[USER] u JOIN @c c ON c.UserId = u.UserId WHERE c.NewName IS NOT NULL;
    COMMIT;
    PRINT CONCAT('Renamed ', @n, ' account(s). Tell each person their new login; passwords are unchanged.');
END
ELSE
    PRINT CONCAT('PREVIEW ONLY: ', @n, ' account(s) would be renamed. Run again with APPLY=1 to do it.');
