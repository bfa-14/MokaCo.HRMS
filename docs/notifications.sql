/* ============================================================================
   IN-APP NOTIFICATIONS  -  table + four procedures
   MokaCo_HRMS  |  FEATURE 1, PHASE 1a  |  NOT YET RUN - review, then execute
   ----------------------------------------------------------------------------
   Deploy with:  sqlcmd -S localhost -d MokaCo_HRMS -E -C -I -i docs\notifications.sql
   (-I for QUOTED_IDENTIFIER ON, the house rule since the filtered index on
    hr.EMPLOYEE started refusing procedures created without it.)

   WHAT THIS IS. A notification is a POINTER, not a message: a short title, an
   optional line of body, and a path into the app. It carries no figures and no
   decisions. That keeps it honest when the thing it points at changes — the
   user clicks through and reads the current truth from the page, which is
   permission-gated as it always was. A notification nobody may open is a dead
   link, never a leak.

   WHY IT IS PER USER AND NOT PER ROLE. "Notify the Owner" is resolved at the
   moment of sending, into one row per Owner. Storing a role instead would mean
   re-resolving membership at read time, so somebody promoted next month would
   inherit last month's alerts, and somebody who left would keep receiving them.

   READ STATE IS A TIMESTAMP, NOT A FLAG. ReadAt answers "when", which the UI
   can show and a flag cannot, and NULL is the unread state the index is built
   around.
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

USE MokaCo_HRMS;
GO

/* ══ 1. TABLE ════════════════════════════════════════════════════════════════
   BIGINT identity: this is the highest-volume table in the system by a wide
   margin — every step of every request notifies somebody — and it is the one
   place where an INT ceiling is a real horizon rather than a theoretical one. */
IF OBJECT_ID('core.NOTIFICATION') IS NULL
BEGIN
    CREATE TABLE core.NOTIFICATION
    (
        NotificationId BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_Notification PRIMARY KEY,
        UserId         INT            NOT NULL
            CONSTRAINT FK_Notification_User REFERENCES security.[USER](UserId),
        /* A short machine-readable family - 'RequestAwaitsYou', 'RequestDecided',
           'PayrollReview', 'LedgerRowCreated'. Kept for grouping and for icons;
           the TITLE is what a person reads, so nothing renders the Kind raw. */
        Kind           VARCHAR(30)    NOT NULL,
        Title          NVARCHAR(200)  NOT NULL,
        Body           NVARCHAR(400)  NULL,
        /* An in-app route ('/requests/34'), never an absolute URL: this is a
           pointer within this application, and a stored absolute URL would rot
           the first time the host or the port changed. */
        LinkPath       NVARCHAR(200)  NULL,
        CreatedAt      DATETIME2(7)   NOT NULL
            CONSTRAINT DF_Notification_CreatedAt DEFAULT (SYSUTCDATETIME()),
        /* NULL = unread. UTC, like every other stamp in this database, so it can
           be compared with GeneratedAt and ActedAt without an offset in between. */
        ReadAt         DATETIME2(7)   NULL
    );
END
GO

/* The bell's only two questions, both served by this one index:
     "how many unread for me"        -> UserId, ReadAt
     "my latest 50, newest first"    -> ..., CreatedAt DESC
   The INCLUDE carries the columns the list renders, so the common read never
   leaves the index to touch the table. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Notification_User_Read_Created'
                 AND object_id = OBJECT_ID('core.NOTIFICATION'))
BEGIN
    CREATE INDEX IX_Notification_User_Read_Created
        ON core.NOTIFICATION (UserId, ReadAt, CreatedAt DESC)
        INCLUDE (Kind, Title, Body, LinkPath);
END
GO

/* ══ 2. ADD ══════════════════════════════════════════════════════════════════
   Called by the service AFTER the write it is telling somebody about has
   committed. It deliberately does not check WHETHER the recipient should care —
   who to notify is a decision the caller makes with the request in front of it,
   and duplicating that reasoning here would put it in two places. */
CREATE OR ALTER PROCEDURE core.usp_Notification_Add
    @UserId    INT,
    @Kind      VARCHAR(30),
    @Title     NVARCHAR(200),
    @Body      NVARCHAR(400) = NULL,
    @LinkPath  NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /* A bell that rings with nothing written on it is worse than silence. */
    IF @Title IS NULL OR LTRIM(RTRIM(@Title)) = ''
    BEGIN RAISERROR('A notification needs a title - there is nothing to show without one.',16,1); RETURN; END
    IF @Kind IS NULL OR LTRIM(RTRIM(@Kind)) = ''
    BEGIN RAISERROR('A notification needs a kind.',16,1); RETURN; END

    /* An unlinked account (a device or a service user) cannot be notified. This
       is a real condition rather than an error: the caller resolved a role to a
       set of users and one of them may have been deactivated since. */
    IF NOT EXISTS (SELECT 1 FROM security.[USER] WHERE UserId = @UserId)
    BEGIN RAISERROR('No such user to notify.',16,1); RETURN; END

    INSERT INTO core.NOTIFICATION (UserId, Kind, Title, Body, LinkPath)
    VALUES (@UserId, @Kind, LTRIM(RTRIM(@Title)), @Body, @LinkPath);

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS NotificationId;
END;
GO

/* ══ 3. MY LIST ══════════════════════════════════════════════════════════════
   TOP 50, newest first. The bell shows 20 of these and the /notifications page
   shows the rest; 50 is the ceiling because a notification older than the last
   fifty has been superseded by the page it points at.

   UnreadCount is returned ON EVERY ROW rather than as a second result set: the
   badge and the list must agree, and two round trips can disagree. Zero rows
   therefore means zero unread, which the client reads as `rows[0]?.unreadCount
   ?? 0` — the same contract core.usp_Dashboard_Get already uses. */
CREATE OR ALTER PROCEDURE core.usp_Notification_GetMine
    @UserId     INT,
    @UnreadOnly BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Unread INT =
        (SELECT COUNT(*) FROM core.NOTIFICATION
         WHERE UserId = @UserId AND ReadAt IS NULL);

    SELECT TOP (50)
           n.NotificationId, n.Kind, n.Title, n.Body, n.LinkPath,
           n.CreatedAt, n.ReadAt,
           @Unread AS UnreadCount
    FROM core.NOTIFICATION n
    WHERE n.UserId = @UserId
      AND (@UnreadOnly = 0 OR n.ReadAt IS NULL)
    ORDER BY n.CreatedAt DESC, n.NotificationId DESC;
END;
GO

/* ══ 4. MARK ONE READ ════════════════════════════════════════════════════════
   OWN ROWS ONLY, and enforced by the WHERE rather than by a check-then-act:
   one statement, no window in between.

   A FOREIGN OR MISSING ID IS NOT AN ERROR HERE. It marks nothing and reports
   MarkedRead = 0. Raising "that is not yours" would answer a question the
   caller had no right to ask — it would confirm that the id exists — and the
   only honest thing a client can do with either answer is the same: refresh.

   Already-read rows are left alone (ReadAt IS NULL in the filter), so pressing
   the same item twice does not rewrite when it was first seen. */
CREATE OR ALTER PROCEDURE core.usp_Notification_MarkRead
    @NotificationId BIGINT,
    @UserId         INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE core.NOTIFICATION
    SET ReadAt = SYSUTCDATETIME()
    WHERE NotificationId = @NotificationId
      AND UserId = @UserId
      AND ReadAt IS NULL;

    DECLARE @Marked INT = @@ROWCOUNT;

    SELECT @Marked AS MarkedRead,
           (SELECT COUNT(*) FROM core.NOTIFICATION
            WHERE UserId = @UserId AND ReadAt IS NULL) AS UnreadCount;
END;
GO

/* ══ 5. MARK ALL READ ════════════════════════════════════════════════════════
   Scoped to the caller and to UNREAD rows, so "mark all read" on a mostly-read
   list touches only what it needs to and leaves the earlier timestamps intact.
   Returns the new count, which is always 0 — returned anyway so the client has
   one shape to bind to across all three write procedures. */
CREATE OR ALTER PROCEDURE core.usp_Notification_MarkAllRead
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE core.NOTIFICATION
    SET ReadAt = SYSUTCDATETIME()
    WHERE UserId = @UserId AND ReadAt IS NULL;

    SELECT @@ROWCOUNT AS MarkedRead,
           (SELECT COUNT(*) FROM core.NOTIFICATION
            WHERE UserId = @UserId AND ReadAt IS NULL) AS UnreadCount;
END;
GO

/* ══ 6. VERIFY ═══════════════════════════════════════════════════════════════ */
SELECT 'core.NOTIFICATION' AS Object,
       CASE WHEN OBJECT_ID('core.NOTIFICATION') IS NULL THEN 'MISSING' ELSE 'ok' END AS State
UNION ALL SELECT 'usp_Notification_Add',
       CASE WHEN OBJECT_ID('core.usp_Notification_Add') IS NULL THEN 'MISSING' ELSE 'ok' END
UNION ALL SELECT 'usp_Notification_GetMine',
       CASE WHEN OBJECT_ID('core.usp_Notification_GetMine') IS NULL THEN 'MISSING' ELSE 'ok' END
UNION ALL SELECT 'usp_Notification_MarkRead',
       CASE WHEN OBJECT_ID('core.usp_Notification_MarkRead') IS NULL THEN 'MISSING' ELSE 'ok' END
UNION ALL SELECT 'usp_Notification_MarkAllRead',
       CASE WHEN OBJECT_ID('core.usp_Notification_MarkAllRead') IS NULL THEN 'MISSING' ELSE 'ok' END
UNION ALL SELECT 'IX_Notification_User_Read_Created',
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.indexes
                             WHERE name='IX_Notification_User_Read_Created'
                               AND object_id=OBJECT_ID('core.NOTIFICATION'))
            THEN 'MISSING' ELSE 'ok' END;
GO


/* ============================================================================
   ⚠ ONE DECISION FOR YOU, NOT MADE HERE
   ----------------------------------------------------------------------------
   core.usp_System_ResetTestData does not clear this table, and it should.

   Every notification carries a LinkPath like '/requests/34'. That reset ends
   with DBCC CHECKIDENT (...,RESEED,0) on REQUEST_INSTANCE and friends, so ids
   are RECYCLED: after a reset, '/requests/34' is a different request belonging
   to a different person. Surviving notifications would then point confidently
   at somebody else's row — the same recycled-id trap that put the wrong
   signature on approval chains.

   I have NOT edited your reset procedure. If you want it, this is the line, to
   be added beside the other DELETEs (no CHECKIDENT needed — a BIGINT identity
   has nowhere to overflow to, and gaps in it are harmless):

       DELETE FROM core.NOTIFICATION;

   Leaving it out is defensible too, as long as the app treats a dead LinkPath
   as "gone" rather than following it blindly — but then the 404 has to be
   graceful, and that is a frontend decision I would rather you made knowingly
   than discovered.
   ============================================================================ */
