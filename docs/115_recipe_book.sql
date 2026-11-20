/* ============================================================================
   115_recipe_book.sql - THE DRINK RECIPES ("Recipes" page): STORED IN THE DATABASE, UPLOADED BY AN ADMIN.

   The bar's Drink Preparation Guide and the MC MIX labels become a page of HRMS: search a drink, read its ingredients
   and steps, open the original guide page.

   THE GUIDE IS CONFIDENTIAL ("copying, photographing or any reproduction is strictly prohibited"), and the source
   code is not a private place. So the recipes and the scanned pages are NOT in the code or in the website's files:
   an admin uploads the recipe book (one .zip: recipes.json + the scans) on the Recipes page, it is kept here, and it
   leaves only through the API, to a signed-in user who holds the permission. Uploading again replaces the whole
   book - that is how a new version of the guide is published.

   Two permissions (Security > Role permissions, card Recipes):
     PREP_BOOK_VIEW     see the drink recipes
     PREP_BOOK_MANAGE   upload or replace the recipe book
   DEFAULT GRANTS, made once - on the run that creates each code, never again (the Role permissions page deletes an
   un-ticked row, so a re-run must not hand back what was taken away):
     VIEW   -> every role that may raise its own requests (REQUEST_RAISE_SELF: the people who work in a branch) and
               the roles that manage roles or users (Admin)
     MANAGE -> the roles that manage roles or users (Admin) and the roles named Owner or General Manager
   The OWNER CHECK line at the end names the roles that hold each code now.

   Tables
     core.PREP_BOOK        one row: the book as the page reads it (JSON, thumbnails inside), its tag, who uploaded it
     core.PREP_BOOK_SCAN   the scanned guide pages ('page') and MIX labels ('label'), by number
   Procedures (the API calls these; core.usp_PrepBook_Get is the MARKER of this script for the deploy guard)
     core.usp_PrepBook_Get      @IfNoneMatch -> the tag, the upload facts and the JSON (NULL when the caller's tag is current, or '*')
     core.usp_PrepBook_GetScan  @Kind, @Number -> the image
     core.usp_PrepBook_Replace  @Json, @ETag, @RecipeCount, @UploadedByUserId -> replaces the book and empties the scans
     core.usp_PrepBook_PutScan  @Kind, @Number, @Bytes -> one scan (the API calls Replace and every PutScan in ONE transaction)

   Idempotent. Apply: sqlcmd -C -I -b -d <database> -i docs/115_recipe_book.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('security.PERMISSION') IS NULL OR OBJECT_ID('security.ROLE_PERMISSION') IS NULL OR SCHEMA_ID('core') IS NULL
BEGIN RAISERROR('115_recipe_book.sql: security.PERMISSION / ROLE_PERMISSION or the core schema not found. Nothing was applied.', 16, 1); SET NOEXEC ON; END
GO

/* ------------------------- 1. the permissions, granted once ------------------------- */
IF NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'PREP_BOOK_VIEW')
BEGIN
    INSERT INTO security.PERMISSION (Code, Name, Module) VALUES ('PREP_BOOK_VIEW', N'See the drink recipes', 'Recipes');
    PRINT 'permission PREP_BOOK_VIEW created';

    INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
    SELECT DISTINCT rp.RoleId, p.PermissionId
    FROM security.ROLE_PERMISSION rp
    JOIN security.PERMISSION q ON q.PermissionId = rp.PermissionId AND q.Code IN ('REQUEST_RAISE_SELF', 'ROLE_MANAGE', 'USER_MANAGE')
    CROSS JOIN security.PERMISSION p
    WHERE p.Code = 'PREP_BOOK_VIEW'
      AND NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION x WHERE x.RoleId = rp.RoleId AND x.PermissionId = p.PermissionId);
    PRINT CONCAT('PREP_BOOK_VIEW: default role grants made now: ', @@ROWCOUNT);
END
ELSE PRINT 'permission PREP_BOOK_VIEW already there (its role grants are left as they are)';

IF NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'PREP_BOOK_MANAGE')
BEGIN
    INSERT INTO security.PERMISSION (Code, Name, Module) VALUES ('PREP_BOOK_MANAGE', N'Upload or replace the recipe book', 'Recipes');
    PRINT 'permission PREP_BOOK_MANAGE created';

    INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
    SELECT r.RoleId, p.PermissionId
    FROM security.[ROLE] r
    CROSS JOIN security.PERMISSION p
    WHERE p.Code = 'PREP_BOOK_MANAGE'
      AND NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION x WHERE x.RoleId = r.RoleId AND x.PermissionId = p.PermissionId)
      AND (   r.Name IN (N'Owner', N'General Manager')
           OR EXISTS (SELECT 1 FROM security.ROLE_PERMISSION rp JOIN security.PERMISSION q ON q.PermissionId = rp.PermissionId
                      WHERE rp.RoleId = r.RoleId AND q.Code IN ('ROLE_MANAGE', 'USER_MANAGE')));
    PRINT CONCAT('PREP_BOOK_MANAGE: default role grants made now: ', @@ROWCOUNT);
END
ELSE PRINT 'permission PREP_BOOK_MANAGE already there (its role grants are left as they are)';
GO

/* ------------------------- 2. the tables ------------------------- */
IF OBJECT_ID('core.PREP_BOOK') IS NULL
BEGIN
    CREATE TABLE core.PREP_BOOK (
        BookId           INT           NOT NULL CONSTRAINT PK_PREP_BOOK PRIMARY KEY
                                       CONSTRAINT CK_PREP_BOOK_One CHECK (BookId = 1),      -- one book
        Json             NVARCHAR(MAX) NOT NULL,          -- the book as the page reads it, thumbnails inside
        ETag             VARCHAR(40)   NOT NULL,          -- changes when the book does
        RecipeCount      INT           NOT NULL,
        UploadedAtUtc    DATETIME2(3)  NOT NULL CONSTRAINT DF_PREP_BOOK_UploadedAt DEFAULT SYSUTCDATETIME(),
        UploadedByUserId INT           NULL
    );
    PRINT 'table core.PREP_BOOK created';
END
IF OBJECT_ID('core.PREP_BOOK_SCAN') IS NULL
BEGIN
    CREATE TABLE core.PREP_BOOK_SCAN (
        Kind     VARCHAR(10)    NOT NULL CONSTRAINT CK_PREP_BOOK_SCAN_Kind CHECK (Kind IN ('page', 'label')),
        [Number] INT            NOT NULL CONSTRAINT CK_PREP_BOOK_SCAN_Number CHECK ([Number] BETWEEN 1 AND 999),
        Bytes    VARBINARY(MAX) NOT NULL,                 -- a JPEG
        CONSTRAINT PK_PREP_BOOK_SCAN PRIMARY KEY (Kind, [Number])
    );
    PRINT 'table core.PREP_BOOK_SCAN created';
END
GO

/* ------------------------- 3. the procedures ------------------------- */
CREATE OR ALTER PROCEDURE core.usp_PrepBook_Get
    @IfNoneMatch VARCHAR(40) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    /* No row = no book uploaded yet. The JSON is left out when the caller's copy is the current one, and for '*'
       (any book: the caller wants the facts only). */
    SELECT b.ETag, b.RecipeCount, b.UploadedAtUtc, u.Username AS UploadedBy,
           (SELECT COUNT(*) FROM core.PREP_BOOK_SCAN) AS ScanCount,
           CASE WHEN @IfNoneMatch IS NOT NULL AND @IfNoneMatch IN (b.ETag, '*') THEN NULL ELSE b.Json END AS Json
    FROM core.PREP_BOOK b
    LEFT JOIN security.[USER] u ON u.UserId = b.UploadedByUserId
    WHERE b.BookId = 1;
END;
GO

CREATE OR ALTER PROCEDURE core.usp_PrepBook_GetScan
    @Kind   VARCHAR(10),
    @Number INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.Bytes FROM core.PREP_BOOK_SCAN s WHERE s.Kind = @Kind AND s.[Number] = @Number;
END;
GO

/* Replaces the book and empties the scans. The API calls this and then usp_PrepBook_PutScan for every scan inside ONE
   transaction, so readers see the old book whole or the new book whole, never a mixture. */
CREATE OR ALTER PROCEDURE core.usp_PrepBook_Replace
    @Json             NVARCHAR(MAX),
    @ETag             VARCHAR(40),
    @RecipeCount      INT,
    @UploadedByUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF @Json IS NULL OR LEN(@Json) < 2 OR ISJSON(@Json) <> 1
    BEGIN RAISERROR('The recipe book is not valid JSON.', 16, 1); RETURN 1; END
    IF @ETag IS NULL OR LEN(@ETag) = 0 OR ISNULL(@RecipeCount, 0) < 1
    BEGIN RAISERROR('The recipe book needs a tag and at least one recipe.', 16, 1); RETURN 1; END

    DELETE FROM core.PREP_BOOK_SCAN;
    DELETE FROM core.PREP_BOOK;
    INSERT INTO core.PREP_BOOK (BookId, Json, ETag, RecipeCount, UploadedAtUtc, UploadedByUserId)
    VALUES (1, @Json, @ETag, @RecipeCount, SYSUTCDATETIME(), @UploadedByUserId);
END;
GO

CREATE OR ALTER PROCEDURE core.usp_PrepBook_PutScan
    @Kind   VARCHAR(10),
    @Number INT,
    @Bytes  VARBINARY(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF @Kind NOT IN ('page', 'label') OR @Number IS NULL OR @Number NOT BETWEEN 1 AND 999 OR @Bytes IS NULL OR DATALENGTH(@Bytes) = 0
    BEGIN RAISERROR('A scan needs a kind (page or label), a number and an image.', 16, 1); RETURN 1; END
    INSERT INTO core.PREP_BOOK_SCAN (Kind, [Number], Bytes) VALUES (@Kind, @Number, @Bytes);
END;
GO

/* ------------------------- 4. OWNER CHECK ------------------------- */
DECLARE @view NVARCHAR(MAX) = (SELECT STRING_AGG(r.Name, N', ') FROM security.[ROLE] r JOIN security.ROLE_PERMISSION rp ON rp.RoleId = r.RoleId
                               JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId WHERE p.Code = 'PREP_BOOK_VIEW');
DECLARE @manage NVARCHAR(MAX) = (SELECT STRING_AGG(r.Name, N', ') FROM security.[ROLE] r JOIN security.ROLE_PERMISSION rp ON rp.RoleId = r.RoleId
                                 JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId WHERE p.Code = 'PREP_BOOK_MANAGE');
PRINT CONCAT('OWNER CHECK (115): see the recipes: ', ISNULL(@view, N'(no role)'), ' | upload the recipe book: ', ISNULL(@manage, N'(no role)'),
             '. Change it on Security > Role permissions (card Recipes).');
IF NOT EXISTS (SELECT 1 FROM core.PREP_BOOK)
    PRINT 'No recipe book is uploaded yet: sign in as an admin, open Recipes and upload the recipe book (.zip).';
PRINT '115_recipe_book.sql: the recipe book - in place.';
GO

SET NOEXEC OFF;
GO
