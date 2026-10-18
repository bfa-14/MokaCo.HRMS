# Google sign-in gate — spec

An optional front door for `https://hrms.mokanco.com.lb`. When the owner or an admin turns it on
(Settings → Google sign-in), anyone who opens the HRMS first sees a small "Sign in with Google" page.
Only a Google account whose verified email is the Gmail on an **active employee who has an active HRMS
login** (or an address on a short "extra" list) gets through. The normal HRMS login follows, unchanged.
Off = open as today.

Nothing public changes: the booking website, card payments (`mokanco.com.lb`) and the attendance
terminals (`/iclock` on the bare IP, port 80) are other nginx blocks and never see the gate.

## 1. Decisions

| # | Decision |
|---|---|
| G1 | The gate is enforced by **nginx `auth_request`** on the HRMS 443 block, asking the API (`GET /api/gate/check`). Strangers get no app files, no API, no HRMS login page. |
| G2 | Identity = a Google **ID token** from Google Identity Services (button on the gate page), verified by the API (signature from Google's published keys, issuer, audience = our client ID, lifetime, `email_verified`). No client secret. No new NuGet package (`Microsoft.IdentityModel.*` is already there via JwtBearer). |
| G3 | Who passes: an employee with `IsDeleted = 0`, not left (`TerminationDate IS NULL OR >= Beirut today`), linked HRMS user `IsActive = 1`, not blocked, whose `Email` matches; **or** an active address on `security.GATE_EXTRA_EMAIL`. Matching is on a normalised email (lower-case, trimmed; for gmail.com/googlemail.com dots and `+tag` in the local part are ignored, googlemail.com = gmail.com). |
| G4 | After Google, a **gate cookie** `mokaco_gate` (HMAC-signed, `HttpOnly; Secure; SameSite=Lax; Path=/`) is valid for `GoogleSignInDays` (default 30). It is re-checked on every request against the current settings and the current allowed list (cached ≤ 20 s), so blocking someone or "sign everyone out" works within seconds. |
| G5 | The switch and the client ID live in `core.SETTING` (Section `Security`), but they are changed **only** through `PUT /api/access/settings` (permission `ACCESS_MANAGE`, granted to Admin and Owner). The generic `PUT /api/settings/{key}` refuses these keys. |
| G6 | **No lock-out:** turning the gate on is refused unless the client ID is set and the caller's own browser already holds a valid gate cookie of a person who is allowed right now ("Test Google sign-in" first). A user cannot block themself. Emergency off on the VM: `deploy/google-gate-emergency-off.sh` (sets the setting to 0 in SQL) and `deploy/enable-google-gate.sh --off` (removes the nginx part). |
| G7 | Exemptions (always pass): `/health`, `/gate/…` (the gate page files), `/api/gate/…` (sign-in endpoints), `/iclock…`, `/api/attendance/punch` (device-key protected). Decided by the API from the raw `X-Original-URI`, fail-closed: any path containing `%`, `\`, `//`, a `.` or `..` segment is never exempt. |
| G8 | Gated page loads get the gate page **in place with status 200** (`Cache-Control: no-store`) — never a redirect (deploy health checks need `/` = 200; `deploy-site.sh` must never see a 301 from it). Gated `/api…` and `/hubs…` get **401 with header `X-Mokaco-Gate: required`** (a `fetch` must never follow a redirect into HTML). |
| G9 | Test environment. Mode `--test` of the nginx script gates **only** requests carrying the cookie `mokaco_env=test` and asks the **test API** (5079): production users are untouched while it is tried. Mode `--all` (after "to production") gates everyone and always asks the **production API** (5078) — one front door for the host, production's switch decides; the test copy's own switch then has no effect. The gate never follows `$mokaco_api_upstream` (it would be computed for the subrequest's URI). |
| G10 | A sign-in log (`security.GATE_SIGNIN_LOG`, 180 days) shows allowed and refused attempts, so the admin can see who tried with which Gmail. |

## 2. SQL — `docs/97_google_signin_gate.sql`

Idempotent, `SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;`, refusals `RAISERROR(msg,16,1); RETURN 1;`,
no `USE` line (apply-sql-test.sh rule), Beirut today =
`CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE)`.

**Column** `hr.EMPLOYEE.GoogleSignInBlocked BIT NOT NULL CONSTRAINT DF_Employee_GoogleSignInBlocked DEFAULT 0`.

**Tables**
- `security.GATE_EXTRA_EMAIL (GateExtraEmailId INT IDENTITY PK, Email NVARCHAR(254) NOT NULL, EmailNorm NVARCHAR(320) NOT NULL, Note NVARCHAR(200) NULL, IsActive BIT NOT NULL DF 1, CreatedAt DATETIME2(3) NOT NULL DF SYSUTCDATETIME(), CreatedBy INT NULL, ModifiedAt DATETIME2(3) NULL, ModifiedBy INT NULL)`, unique index `UQ_GateExtraEmail_EmailNorm`.
- `security.GATE_SIGNIN_LOG (GateSignInLogId BIGINT IDENTITY PK, AttemptedAt DATETIME2(3) NOT NULL DF SYSUTCDATETIME(), Email NVARCHAR(320) NOT NULL, GoogleSub VARCHAR(255) NULL, Outcome VARCHAR(20) NOT NULL, EmployeeId INT NULL, GateExtraEmailId INT NULL, Ip VARCHAR(45) NULL, UserAgent NVARCHAR(300) NULL)`, index on `AttemptedAt`. No foreign keys (wipe/reset scripts delete employees).

**Settings** (Section `Security`, pattern of 96: insert if missing, keep the value, refresh type/description/section/sort):
`GoogleSignInRequired` `'0'` bool (10) · `GoogleClientId` `''` string (20) · `GoogleSignInDays` `'30'` int (30) · `GoogleSignInEpoch` `'1'` int (40).
A bool is on when the value is one of `1/true/yes/on` (case-insensitive).

**Permission** `ACCESS_MANAGE` — N'Turn Google sign-in on or off and manage who can open the HRMS', Module `'Security'`, granted to roles `Admin` and `Owner` (idempotent, prints who was granted).

**Function** `security.fn_GateNormalizeEmail(@Email NVARCHAR(320)) RETURNS NVARCHAR(320) WITH SCHEMABINDING` — NULL/blank → NULL; trim + lower; split at the **last** `@` (none → return as is); if the domain is `gmail.com` or `googlemail.com`: local part = text before the first `+`, dots removed, domain `gmail.com`. Returns `local@domain`.

**Procedures** (caller last, `@CallerUserId INT = NULL`)

| Procedure | Parameters | Result |
|---|---|---|
| `security.usp_Gate_GetState` | — | RS1 one row `Required BIT, ClientId NVARCHAR(200), Days INT, Epoch INT` (Days: TRY_CAST, default 30, clamped 1..365; Epoch default 1; ClientId trimmed, '' when missing). RS2 `Kind CHAR(1), PersonId INT`: every allowed person now — `'e'`+EmployeeId per G3, `'x'`+GateExtraEmailId for active extras. |
| `security.usp_Gate_SignIn` | `@Email NVARCHAR(320), @GoogleSub VARCHAR(255), @Ip VARCHAR(45), @UserAgent NVARCHAR(300)` | one row `Outcome VARCHAR(20), Kind CHAR(1) NULL, PersonId INT NULL, DisplayName NVARCHAR(150) NULL`. Order: active extra with the same norm → `Allowed` x (DisplayName = Note or Email). Else employees (`IsDeleted = 0`) with the same norm: none → `NotFound`; any eligible (not left, user active) and not blocked → `Allowed` e (lowest EmployeeId, DisplayName = FullName); any eligible but all blocked → `Blocked`; any not left (no active user) → `NoUser`; else `Left`. Writes one log row (Email as given, trimmed, cut to 320) and deletes log rows older than 180 days. |
| `security.usp_Gate_GetAdmin` | `@CallerUserId` | RS1 `Required, ClientId, Days, Epoch, ModifiedAt DATETIME2 NULL` (ModifiedAt of `GoogleSignInRequired`). RS2 people — every employee with `IsDeleted = 0`: `EmployeeId, FullName, BranchName NVARCHAR NULL, Email, UserId INT NULL, Username NVARCHAR NULL, UserIsActive BIT NULL, TerminationDate DATE NULL, IsBlocked BIT, Status VARCHAR(20), LastSignInAt DATETIME2 NULL` with Status one of `Allowed, Blocked, NoEmail, NoUser, UserDisabled, Left` (Left wins, then NoEmail, NoUser, UserDisabled, Blocked, Allowed); LastSignInAt = latest `Allowed` log row for that employee; ordered by FullName. RS3 extras `GateExtraEmailId, Email, Note, IsActive, CreatedAt, LastSignInAt` ordered by Email. RS4 recent log, newest first, top 100: `GateSignInLogId, AttemptedAt, Email, Outcome, EmployeeId, FullName NULL, Ip`. |
| `security.usp_Gate_SaveSettings` | `@Required BIT, @ClientId NVARCHAR(200), @Days INT, @CallerUserId` | refusals: `'Keep a Google sign-in between 1 and 365 days.'`; client ID not blank and not `LIKE '%_.apps.googleusercontent.com'` → `'That is not a Google client ID — it ends with .apps.googleusercontent.com.'`; `@Required = 1` with blank ID → `'Enter the Google client ID before turning Google sign-in on.'`. Writes the three values (value `'1'/'0'` for Required), `ModifiedAt/By`. No result set. |
| `security.usp_Gate_SetBlocked` | `@EmployeeId INT, @Blocked BIT, @CallerUserId` | `'Employee not found.'`; blocking the employee linked to the caller → `'You can''t block yourself — you would lose access.'` |
| `security.usp_Gate_ExtraEmail_Save` | `@GateExtraEmailId INT = NULL, @Email NVARCHAR(254), @Note NVARCHAR(200), @IsActive BIT, @CallerUserId` | insert (NULL id) or update; `'Enter a full Google email address.'` (needs one `@` with text before and a dot after); same norm on another row → `'This Gmail is already on the list.'`; unknown id → `'That address is not on the list.'`. Returns one row `GateExtraEmailId INT`. |
| `security.usp_Gate_ExtraEmail_Delete` | `@GateExtraEmailId INT, @CallerUserId` | `'That address is not on the list.'` |
| `security.usp_Gate_SignOutEveryone` | `@CallerUserId` | Epoch + 1; one row `Epoch INT`. |

`deploy/test-env/neutralise-test-db.sql` also sets `GoogleSignInRequired = '0'` on the test copy.

## 3. API

**Config** (`appsettings`/env, optional): `Google:MetadataAddress` (default
`https://accounts.google.com/.well-known/openid-configuration`; tests point it at a local fake).
Cookie key = `HMACSHA256(key: UTF8(Jwt:SecretKey), data: UTF8("mokaco-gate-cookie-v1"))` — production
and test differ, so a cookie from one is refused by the other.

**Pure pieces** (`MokaCo.HRMS.Services/Security/Gate/`)
- `GateCookie` — value `v1.<b64url(json)>.<b64url(HMACSHA256(key, "v1." + b64json))>`, json
  `{"k":"e"|"x","id":int,"em":string,"iat":unix,"exp":unix,"ep":int}`. `TryRead(value, key, nowUnix, days, epoch, out payload)`
  is valid only if: format, constant-time signature, `now < exp`, `now < iat + days*86400`, `ep == epoch`.
- `GatePaths.IsExempt(string? rawUri)` — G7.
- `GateCookieOptions` — name `mokaco_gate`, always `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`, `Max-Age = days*86400`; clear = `Max-Age=0`.

**Services**
- `IGateState` (singleton, pattern of `PublicBookingGate`): snapshot `{Required, ClientId, Days, Epoch, Allowed: set of (Kind, PersonId)}` from `usp_Gate_GetState`, cached 20 s, `SemaphoreSlim`, a failed read keeps the last good snapshot and logs a warning; **before the first good read the gate is treated as closed**. `Invalidate()` after every admin write. `GetFreshAsync()` bypasses the cache (used by the turn-on guard).
- `IGoogleTokenValidator` → `GoogleTokenValidator` (singleton): `ConfigurationManager<OpenIdConnectConfiguration>` over `Google:MetadataAddress` (HttpClient from the factory, 10 s timeout, HTTPS required except a loopback metadata address), `JsonWebTokenHandler`, `ValidIssuers = {accounts.google.com, https://accounts.google.com}`, `ValidAudience = clientId`, RS256 only, lifetime with 2 min skew; one `RequestRefresh()` + retry on an unknown signing key. Result: `Ok(email, sub, name)` / `Invalid` / `Unverified` (`email_verified` missing or not true, bool or string) / `Unreachable`.
- `IGateService` → `GateService`: `IsAllowedAsync(cookieValue)` (check), `GetConfigAsync(cookieValue)`, `SignInAsync(credential, ip, userAgent)`, admin operations (wrap SQL refusals with `WorkflowSqlErrors.MapAsync`).

**`GateController`** `api/gate`, `[AllowAnonymous]`, every response `Cache-Control: no-store`.

| Endpoint | Behaviour |
|---|---|
| `GET` (and `HEAD`) `check` | `204` when `IsExempt(X-Original-URI)` or the gate is off or the cookie is valid and its person is in the allowed set; otherwise `401`, **no body**. Never another status: any exception → `401` (logged). Excluded from `UseHttpsRedirection`. |
| `GET config` | `200 {required, clientId (null when blank), days, signedIn, email, name}` (`signedIn` = the cookie is valid now). |
| `POST google` `{credential}` | rate limit policy `gate-signin`: 10/min per client IP, rejected with **429** (extend `OnRejected`). Not configured (blank client ID) → `503 {error:"Google sign-in is not set up yet. Ask the administrator."}`. Validator: Invalid → `400 "Google could not confirm this sign-in — try again."`; Unverified → `403 "This Google account's email is not verified."`; Unreachable → `503 "Google could not be reached — try again in a minute."`. Then `usp_Gate_SignIn`: `Allowed` → set cookie, `200 {email, name, days}`; `NotFound` → `403 "{email} is not on the HRMS list. Ask the administrator to put this Gmail on your employee record."`; `Blocked` → `403 "Google sign-in is switched off for {email}. Ask the administrator."`; `NoUser` → `403 "{email} belongs to an employee without an active HRMS login. Ask the administrator."`; `Left` → `403 "{email} belongs to an employee who has left."`. Works whether the gate is on or off (used by "Test Google sign-in"). |
| `POST signout` | clears the cookie, `204`. |

**`AccessController`** `api/access`, every action `[HasPermission("ACCESS_MANAGE")]`.

| Endpoint | Behaviour |
|---|---|
| `GET` | `200 {settings:{required, clientId, days, epoch, modifiedAt}, caller:{verified, email, name}, people:[…RS2], extras:[…RS3], recent:[…RS4]}` — `caller` from this browser's gate cookie against a fresh state. |
| `PUT settings` `{required, clientId, days}` | when `required` is true: blank client ID → `400` (SQL sentence); caller not verified now → `409 "Sign in with Google in this browser first (Test Google sign-in), so turning this on can't lock you out."`. Then `usp_Gate_SaveSettings`, `Invalidate()`, `204`. |
| `PUT people/{employeeId}/blocked` `{blocked}` | `usp_Gate_SetBlocked`, `Invalidate()`, `204`. |
| `POST extras` `{email, note}` | `201 {gateExtraEmailId}`. |
| `PUT extras/{id}` `{email, note, isActive}` | `204`. |
| `DELETE extras/{id}` | `204`. |
| `POST signout-everyone` | `usp_Gate_SignOutEveryone`, `Invalidate()`; if the caller's cookie was valid it is re-issued with the new epoch (the admin stays in); `200 {epoch}`. |

`SettingsController.PUT /api/settings/{key}` refuses the four `Google*` keys:
`400 "Change this on Settings → Google sign-in."`.
DI: repository scoped, `GateService` scoped, `IGateState` / `IGoogleTokenValidator` singletons.

## 4. Web (`mokaco-web-mantine`)

- **Gate page** `public/gate/` (copied as-is by Vite): `index.html` (absolute URLs `/gate/…`), `gate.css`, `gate.js` (ES module), `next.js` (pure, unit-tested: `safeNextPath`), logo copy. English + Arabic in the page (toggle, remembered in `localStorage` guarded by try/catch, `dir` switches). Flow: `GET /api/gate/config` → if not required: go to `next` → if no client ID: "not set up yet" → load `https://accounts.google.com/gsi/client`, `initialize({client_id, callback, ux_mode:'popup'})`, `renderButton` → `POST /api/gate/google` → success: if the page sits at its own URL `/gate/…` go to the safe `?next=` (default `/`), else `location.reload()` (it is shown in place of the requested page); 403/400/503/429: show the server's sentence and keep the button. Tells people to open the HRMS in Chrome/Safari, not inside WhatsApp.
- **API client** (`src/api/client.ts`): a `401` carrying `X-Mokaco-Gate` reloads the page once (latched) instead of the refresh/login path. Pure helper `isGateResponse` unit-tested.
- **Settings → new tab "Google sign-in"** (visible with `ACCESS_MANAGE`), hand-built like `DangerZone`:
  1. *Google sign-in* — switch "Require Google sign-in to open the HRMS" (turning on asks for confirmation; refusals shown), Google client ID, days, Save; status "Verified in this browser as …" / "Not verified in this browser" with **Test Google sign-in** (modal with Google's button) and "Sign this browser out of Google"; a short how-to-set-up note.
  2. *Who can open the HRMS* — employees: name, Gmail, status badge, last Google sign-in, an "Allowed" switch (block/unblock; disabled unless Allowed/Blocked); search box.
  3. *Extra Google accounts* — people who are not employees (owner, accountant): add (email + note), active switch, edit, remove.
  4. *Recent sign-ins* — last 100 attempts with the result.
  5. *Sign everyone out* (confirm).
  The four `Google*` keys are filtered out of the generic settings list.
- `src/types/access.ts`, `src/services/accessService.ts` (+ gate calls), i18n `googleGate.*` in `en.json` and `ar.json` (same keys), RTL-safe, Employee form email hint mentions Google sign-in.

## 5. nginx — `deploy/enable-google-gate.sh` (on the VM, sudo)

`--test` | `--all` | `--off` | `--status`. Writes `/etc/nginx/conf.d/mokaco-gate.conf` (maps) and
`/etc/nginx/snippets/mokaco-gate.conf`, and puts one tagged line
`include /etc/nginx/snippets/mokaco-gate.conf;   # mokaco-gate` in the HRMS 443 block of
`/etc/nginx/sites-available/mokaco` (just before the `location ~ ^/(api|hubs|iclock|health)` line), and with
`--all` also in the 443 block of `mokaco-test` when that site is enabled. Never a new file in `sites-enabled`.

Snippet (server level): `auth_request /__mokaco_gate; error_page 401 = @mokaco_gate;`
- `location = /__mokaco_gate` — `internal`; when `$mokaco_gate_upstream` is empty `return 204`; else
  `proxy_pass http://$mokaco_gate_upstream/api/gate/check` with `proxy_pass_request_body off`,
  `Content-Length ""`, `Host $host`, `X-Original-URI $request_uri`, `X-Forwarded-For $mokaco_client_ip`,
  `X-Forwarded-Proto $mokaco_proto`.
- `location ^~ /api/gate/` — `auth_request off`; `proxy_pass http://$mokaco_gate_api` with the usual proxy headers.
- `location @mokaco_gate` — `auth_request off`; `add_header Cache-Control "no-store" always`;
  `add_header X-Mokaco-Gate "required" always`; `/api…` or `/hubs…` (map `$mokaco_gate_api_path` on `$uri`)
  → `return 401`; otherwise serve `/gate/index.html` from the site root with status 200.

Maps (`conf.d/mokaco-gate.conf`, keyed on `$cookie_mokaco_env` only):
- `--test`: `$mokaco_gate_upstream` = `127.0.0.1:5079` for `test`, empty otherwise; `$mokaco_gate_api` = `127.0.0.1:5079` for `test`, `127.0.0.1:5078` otherwise.
- `--all`: both `127.0.0.1:5078` always.

Preconditions (nothing changes on failure): root; nginx has `http_auth_request_module`; the site file and
its API location exist; the API that will answer (`--test`: 5079, `--all`: 5078) returns `204` for
`curl -H 'X-Original-URI: /health' http://127.0.0.1:PORT/api/gate/check`. Backup, write, `nginx -t`,
restore on failure, reload, smoke tests (`/health` 200, `/` 200, `/__mokaco_gate` 404 from outside).
Warns when `sites-enabled/mokaco-api` exists (it would expose the whole API without the gate).
`--off` deletes the tagged lines and both files, then `nginx -t` and reload.

`deploy/google-gate-emergency-off.sh [--test]` — `sqlcmd` sets `GoogleSignInRequired = '0'` in `MokaCo_HRMS`
(or `MokaCo_HRMS_Test`); takes effect within 20 s.

## 6. Roll-out

1. `dev` → test: deploy (Ctrl+Shift+B), apply `docs/97_google_signin_gate.sql` with `apply-sql-test.sh`,
   `sudo bash ~/src-test/MokaCo.HRMS/deploy/enable-google-gate.sh --test`. Create the Google client ID
   (docs/GOOGLE_SIGNIN_SETUP.md). On the login page switch to test, Settings → Google sign-in: client ID,
   Test Google sign-in, turn on. Production is untouched.
2. "to production": merge, deploy the API and web, apply 97 on `MokaCo_HRMS`, then
   `sudo bash ~/src/MokaCo.HRMS/deploy/enable-google-gate.sh --all`. Nothing changes until the owner turns the
   switch on in production's Settings.

## 7. As built — where the code is stricter than the sections above

Review found ways to lock yourself out or keep an old address passing; these close them.

- **The cookie is tied to the address and the client ID.** It carries `en` (normalised email) and `aud`
  (client ID) as well. It passes only while (Kind, PersonId, `en`) is in the allowed set and `aud` is the
  current client ID. So correcting an employee's Gmail, or editing an extra address, ends the old cookie
  within the 20 s cache, with no admin action. `usp_Gate_GetState` RS2 is `Kind, PersonId, EmailNorm` and
  the `usp_Gate_SignIn` row has a fifth column `EmailNorm` (Allowed only).
- **More lock-out guards (409):** switching off, re-addressing or removing the extra address this browser
  passes with; blocking the employee this browser passes as; changing the client ID while the gate is on;
  turning on with a client ID that is not saved yet. The turn-on guard checks the cookie against the shorter
  of the current and requested days.
  Not guarded: an admin who changes **their own** employee Gmail on the Employee form to one they cannot
  sign in with. Recovery: another admin, or `deploy/google-gate-emergency-off.sh`.
- `PUT /api/settings/{key}` also refuses any key that is not plain ASCII (`"That is not a setting key."`):
  SQL Server would turn a look-alike letter into the gate key.
- **Exempt paths are exact:** `/health` and `/api/attendance/punch` match exactly; the query string is
  ignored; `#`, spaces, control and non-ASCII characters are never exempt.
- A failed state read is retried after 5 s (not on every request). The validator waits up to 3 s for
  Google's refreshed keys.
- **SQL details:** a blank Days or Epoch counts as missing; the extra-address check refuses `a@.com` and
  `a@b.`; blocking a deleted employee gives "Employee not found."; a refused sign-in returns NULL
  Kind/PersonId/DisplayName (the log still names the employee); SaveSettings and SignOutEveryone recreate
  rows deleted by hand.
- **Web:** `isGateResponse` is in `src/api/gateResponse.ts`; `restoreSession` and the live socket handle the
  gate too (a gated 401 never clears the HRMS tokens); a 10 s guard stops repeat reloads; the gate page has
  `strings.js` and `favicon.png` and loads its files with `?v=1`; Test sign-in uses the saved client ID; the
  in-app how-to includes publishing the Google app.
- **nginx script:**
  - More preconditions: the API must say it has read its settings (refuses before 97 is applied), the API
    location must be in an HTTPS block, `--test` needs the test switch, the gate page must exist in each web
    root, and `sites-enabled` must hold links.
  - The snippet adds `location ^~ /gate/` (404 for a missing file) and a `Cache-Control` map (`no-cache` on
    the app's HTML and `/gate/*`, so a cached app page cannot skip the gate). `/api/gate/` sends
    `X-Forwarded-For $remote_addr` (the shared `$mokaco_client_ip` trusts a client-sent `CF-Connecting-IP`).
  - `--off` also cleans `mokaco.before-env-switch`; `--test` removes a line an earlier `--all` left in
    `mokaco-test`. Smoke tests roll everything back on failure. Emergency-off exits 1 when 97 is missing.
- **Operations to remember:** `--test` needs `mokaco-api-test` running; apply 97 again after every
  `refresh-test-db.sh`; run `--off` before deploying a build without the gate.
