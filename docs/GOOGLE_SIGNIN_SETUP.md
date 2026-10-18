# Google sign-in: setting it up

What the gate does: `docs/GOOGLE_SIGNIN_GATE.md`. This page covers the one-time steps: the Google client ID,
putting it in the HRMS, the roll-out and the emergency off.

You need:
- a Google account that the company keeps (the owner's, not a staff member who may leave);
- an Admin or Owner login in the HRMS;
- the VM (VPN on) for the roll-out.

## A. Create the Google client ID (Google Cloud, once)

1. Open <https://console.cloud.google.com> and sign in with that Google account. Accept the terms if asked.
2. In the project list at the top, press **New project**. Name it `MokaCo HRMS`, press **Create**, and check
   that it is the selected project.
3. Open the menu ☰ → **Google Auth Platform** (or type "Google Auth Platform" in the search bar).
   Press **Get started** and fill in:
   - **App information**: App name `MokaCo HRMS`, User support email = your Gmail. **Next**.
   - **Audience**: **External**. **Next**.
   - **Contact information**: your Gmail. **Next**.
   - **Finish**: tick the agreement to the Google API Services: User Data Policy, then **Continue** and **Create**.
4. **Branding**: under **Authorized domains**, add `mokanco.com.lb`. Leave the logo empty: Google must check a
   logo before it shows, and sign-in works without one. **Save**.
5. **Data Access**: add nothing. Sign-in only uses `openid`, `email` and `profile`, which need no verification.
   Do not submit anything for verification.
6. **Audience**: the publishing status says **Testing**. Press **Publish app**, then **Confirm**. It now says
   **In production**. (In Testing, only the listed test users could sign in.)
7. **Clients** → **Create client**:
   - Application type: **Web application**
   - Name: `MokaCo HRMS web`
   - **Authorized JavaScript origins** → **Add URI**: `https://hrms.mokanco.com.lb`
   - **Add URI** again: `https://test.hrms.mokanco.com.lb`
     (exactly so: `https://`, no `/` at the end, no path)
   - **Authorized redirect URIs**: leave empty.
   - Press **Create**.
8. Copy the **Client ID**. It ends with `.apps.googleusercontent.com`, and you can see it again under
   **Clients** at any time. The client secret is not needed: do not copy it anywhere.
9. Wait about 5 minutes. Google can take a while to accept new origins. Until then, Google's button may show
   an error such as `origin_mismatch`.

## B. Put the client ID in the HRMS

As Admin or Owner:

1. Open the HRMS → **Settings** → **Google sign-in**.
2. Paste the ID into **Google client ID** and press **Save**.
3. Press **Test Google sign-in** and sign in with your own Gmail. The page must then say
   "Verified in this browser as …". If it refuses, the message says why.
4. Check **Who can open the HRMS**. Each person needs their Gmail on their employee record and an active
   HRMS login. Add people who are not employees (owner, accountant) under **Extra Google accounts**.
5. Turn on **Require Google sign-in to open the HRMS** and confirm.

This only has an effect once nginx asks the API (part C).

## C. Roll-out

**1. On test first** (production users see nothing new):

1. Laptop, on `dev` with everything pushed: deploy to test (Ctrl+Shift+B in VS Code, or
   `bash deploy/deploy.sh`).
2. VM, the database changes on the test copy:
   ```bash
   cd ~/src-test/MokaCo.HRMS && bash deploy/test-env/apply-sql-test.sh docs/97_google_signin_gate.sql
   ```
   Do it again after every `refresh-test-db.sh`: the fresh copy comes from production, which has no 97 yet.
3. VM, the nginx part, for browsers on the Test switch only:
   ```bash
   sudo bash ~/src-test/MokaCo.HRMS/deploy/enable-google-gate.sh --test
   ```
   It refuses, changing nothing, until the test API can read its Google sign-in settings (step 2).
   While it is on, keep `mokaco-api-test` running. If it stops, browsers on the Test switch get a 500 page
   (`/env/prod` still takes them back to production).
4. Create the Google client ID (part A) if it is not done yet.
5. Browser: on the login page, turn on **Test environment** and sign in. Then do part B there.
6. To see what others will see, open `https://hrms.mokanco.com.lb/env/test` in another browser: the
   Google page appears. Open `/env/prod` to leave test again.

**2. To production** (after "to production"):

1. Merge `dev` into `main`, push, and deploy from `main` (Ctrl+Shift+B, or `bash deploy/deploy.sh`; it asks
   you to type `yes`).
2. VM, the database changes on production. This must come before step 3: until 97 is in, production's API
   cannot read its Google sign-in settings and would keep everyone at the gate page.
   ```bash
   /opt/mssql-tools18/bin/sqlcmd -S 127.0.0.1 -U sa -C -I -b -d MokaCo_HRMS -i ~/src/MokaCo.HRMS/docs/97_google_signin_gate.sql
   ```
3. VM, the nginx part, for everyone:
   ```bash
   sudo bash ~/src/MokaCo.HRMS/deploy/enable-google-gate.sh --all
   ```
   It refuses, changing nothing, if step 2 is missing or failed.
4. Nothing changes until the owner does part B in production (Test environment off). From now on only
   production's switch counts. The test copy's switch has no effect.

Check the mode at any time: `bash ~/src/MokaCo.HRMS/deploy/enable-google-gate.sh --status`. It also warns
when the API that decides does not answer or cannot read its settings, and when `test.hrms` is outside the
gate (enabled after `--all`: run `--all` again).

While the gate is in nginx, the API that decides must answer, or nginx gives a 500 page. Before you deploy a
production build without the gate (a revert), run `enable-google-gate.sh --off`.

## D. If nobody can get in

On the VM:

1. Turn the switch off in the database. It asks for the SQL password (`sa`):
   ```bash
   bash ~/src/MokaCo.HRMS/deploy/google-gate-emergency-off.sh
   ```
   Within 20 seconds the HRMS opens with its normal login. (Add `--test` for the test copy. That only helps
   while nginx is in `--test` mode.) If it says 97 is not applied, the switch cannot help: go to step 2.
2. If the site still does not open, remove the nginx part as well:
   ```bash
   sudo bash ~/src/MokaCo.HRMS/deploy/enable-google-gate.sh --off
   ```
3. To turn it back on later: `enable-google-gate.sh --all`, then the switch in Settings.

## Good to know

- People sign in with the Gmail on their employee record. Dots and `+tags` in a Gmail address do not matter.
- A Google sign-in lasts 30 days (Settings → Google sign-in → Days a Google sign-in lasts).
- Blocking someone or **Sign everyone out** takes effect within 20 seconds.
- Google refuses to sign in inside the WhatsApp or Instagram browser. Tell staff to open the HRMS in Chrome
  or Safari.
- Add a second owner to the Google Cloud project (☰ → **IAM & Admin** → **IAM** → **Grant access**, role
  **Owner**), so the setup does not depend on one account.
- Deleting the client in Google Cloud locks everyone out. Use part D, then create a new client ID.
