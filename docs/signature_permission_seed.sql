/* ============================================================================
   SIGNATURE_MANAGE PERMISSION SEED  -  RE-RUNNABLE
   SQL Server 2025  -  database MokaCo_HRMS
   ----------------------------------------------------------------------------
   Run AFTER docs/signature_images.sql.

   signature_images.sql adds the tables and procedures but does NOT seed the
   permission that guards writing a signature — permissions live in the security
   seed, which it does not own. Without this row, POST/DELETE on a user's signature
   return 403, because the JWT carries one "perm" claim per code and the policy
   provider demands a matching one.

   WHO GETS IT, AND WHY ONLY THEM
     A signature is stamped onto an audit trail. Whoever can upload one for a user
     can make that user's mark appear on a document. That is an owner-level trust, so
     it goes to Admin and Owner and nobody else — NOT to HR, who administer people but
     do not get to mint their signatures.
   ============================================================================ */
USE MokaCo_HRMS;
GO

/* -- the permission code (guarded on Code, which is UNIQUE) ----------------- */
INSERT INTO security.PERMISSION (Code, Name, Module)
SELECT 'SIGNATURE_MANAGE', N'Manage user signature images', 'Security'
WHERE NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'SIGNATURE_MANAGE');
GO

/* -- grant to Admin and Owner only ----------------------------------------- */
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
SELECT r.RoleId, p.PermissionId
FROM security.[ROLE] r
CROSS JOIN security.PERMISSION p
WHERE p.Code = 'SIGNATURE_MANAGE'
  AND r.Name IN ('Admin', 'Owner')
  AND NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION rp
                  WHERE rp.RoleId = r.RoleId AND rp.PermissionId = p.PermissionId);
GO

/* -- verify ---------------------------------------------------------------- */
SELECT r.Name AS RoleName, p.Code
FROM security.ROLE_PERMISSION rp
JOIN security.[ROLE] r     ON r.RoleId = rp.RoleId
JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
WHERE p.Code = 'SIGNATURE_MANAGE'
ORDER BY r.Name;
GO
