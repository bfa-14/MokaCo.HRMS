# Test environment on the production VM

A second API (`mokaco-api-test`, 127.0.0.1:5079) on the database `MokaCo_HRMS_Test`. It uses the same VM,
SQL Server and nginx as production, with no Docker. It is reached at the **same address** through the
**Test environment switch on the login page**: on, nginx sends the API and the pages to the test copy; off,
to production. In test, the login page and the header turn red with a TEST tag.

| | Production | Test |
|---|---|---|
| systemd unit | `mokaco-api` | `mokaco-api-test` (capped at 1 CPU, 2 GB) |
| port | 127.0.0.1:5078 | 127.0.0.1:5079 |
| API folder | `/opt/mokaco/api` | `/opt/mokaco/api-test` |
| settings | `/etc/mokaco/api.env` | `/etc/mokaco/api-test.env` |
| database / login | `MokaCo_HRMS` / `mokaco_api` | `MokaCo_HRMS_Test` / `mokaco_api_test` (no access to production) |
| documents | `/var/lib/mokaco/documents` | `/var/lib/mokaco-test/documents` |
| front end | `/var/www/mokaco-web` | `/var/www/mokaco-web-test` |
| routing | default | cookie `mokaco_env=test`, set by the login switch (`/iclock` always production) |
| JWT issuer/audience/key | production's | different, so tokens do not cross |
| card gateway | `MOKANDCO` | `TESTMOKANDCO` only |

## The one rule: neutralise before the test API starts

`MokaCo_HRMS_Test` is a copy of production. Without `neutralise-test-db.sql`, a test API started on it would:

- **e-mail and WhatsApp real staff and guests.** EmailWorker runs every minute.
- **erase the real fingerprint terminals.** "Pull now" and "Clear machine log" ignore `MachinePullEnabled` and
  `IsActive`; only an empty `PullIp` stops them. Clear reads a terminal into the *test* database and then deletes
  the terminal's own log, so production loses those punches for good.
- **take website bookings.** A missing `BookingWebsiteEnabled` row means *on*.

`refresh-test-db.sh` always runs the neutralise script, so use it rather than restoring by hand.

## Files

| File | Goes to | What it does |
|---|---|---|
| `neutralise-test-db.sql` | run, not installed | Mail, WhatsApp, terminal and booking settings off; pending outbox marked Failed; device addresses removed. Refuses any database but `MokaCo_HRMS_Test`. |
| `refresh-test-db.sh` | run with sudo | Restores a production backup over `MokaCo_HRMS_Test`, then neutralises it and maps the test login. `--in-place` skips the restore. |
| `setup-test-api.sh` | run with sudo | Steps 2, 4, 5 and 6 below in one run: login, files, settings, service, then checks it. |
| `apply-sql-test.sh` | run | Applies `docs/*.sql` to the test DB with the `USE MokaCo_HRMS;` line removed. |
| `mokaco-api-test.service` | `/etc/systemd/system/` | The unit. |
| `api-test.env.example` | `/etc/mokaco/api-test.env` | Settings template; fill it in on the VM. |
| `enable-env-switch.sh` | run with sudo | Turns the login switch on in nginx; `--undo` puts the site back exactly. |
| `nginx-mokaco-test.conf` | `/etc/nginx/sites-available/mokaco-test` | Optional: a separate address instead (step 8). |

## Setting it up

Read `~/SETUP_NOTES.md` on the VM first. This setup does not touch sshd, the firewall, the `user`
password, netplan or Bitdefender. It adds an SQL login, a systemd unit and an nginx site. Ports 80/443 are
already open.

### 0. Before you start

- **Ask IDM for the DNS record** `test.hrms.mokanco.com.lb  A  82.146.175.34`.
- **Check there is room:** `free -h`, `df -h /var/opt/mssql /var/lib`. SQL Server Express caps each
  database at 10 GB, and the test copy takes as much disk as production.
- **Keep the pre-wipe data safe.** Apart from `MokaCo_HRMS_Test`, which testing will change, the backups
  taken before the 3 Oct wipe are the only copies of that data. The backup timer keeps 14 days, so they are
  disappearing now, and the last one goes around 17 Oct. Copy the newest pre-wipe `.bak` out of
  `/var/opt/mssql/backup` and `/var/backups/mokaco`, and off the VM.

### 1. Put the kit on the VM

With the VPN on:
```bash
scp -r deploy/test-env mokanco-vm:~/test-env
ssh mokanco-vm 'chmod +x ~/test-env/*.sh'
```

**Steps 2 to 6 in one run** (after step 3's test database exists):
```bash
sudo ~/test-env/setup-test-api.sh       # or: sudo MPGS_TEST_PASSWORD='...' ~/test-env/setup-test-api.sh
```
It creates the login with a generated password, copies production's build and front end, writes
`/etc/mokaco/api-test.env` once, installs the service with production's `ExecStart`, starts it, and stops
it again unless `/health` says Staging and the log says mail and the machine pull are OFF. The steps below
are what it does, for doing them by hand.

### 2. Create the test API's SQL login (once)

```bash
openssl rand -base64 24          # the password; it goes into api-test.env in step 5, nowhere else
/opt/mssql-tools18/bin/sqlcmd -S 127.0.0.1 -U sa -C -I
```
```sql
CREATE LOGIN mokaco_api_test WITH PASSWORD = '<that password>', CHECK_POLICY = ON;
GO
```
The login has no user in `MokaCo_HRMS`, so it cannot open production. The next step makes it db_owner in
`MokaCo_HRMS_Test` only.

### 3. Neutralise the test database

**First time: keep the copy you have.** Today's `MokaCo_HRMS_Test` holds the pre-wipe data, and production's
newest backup is the wiped database. So neutralise the copy in place:
```bash
~/test-env/refresh-test-db.sh --in-place
```
**Later, for a fresh copy of production** (this replaces everything in `MokaCo_HRMS_Test`):
```bash
sudo ~/test-env/refresh-test-db.sh                       # newest MokaCo_HRMS_<date>.bak
sudo ~/test-env/refresh-test-db.sh /path/to/backup.bak   # a given one
```
Both modes end by printing the settings. `PendingOutbox` and `DevicesWithAddress` must both be 0.

### 4. Folders, build and front end

To start with, the test instance runs the same build as production:
```bash
sudo rsync -a --delete /opt/mokaco/api/ /opt/mokaco/api-test/        # keeps production's owner and mode 750
sudo install -d -o mokaco -g mokaco -m 750 /var/lib/mokaco-test /var/lib/mokaco-test/documents
sudo rsync -a --delete /var/www/mokaco-web/ /var/www/mokaco-web-test/
```
The front end calls a relative `/api` because it is built with an empty `VITE_API_BASE_URL`, so the same
build works on either host.

Optional: to open old documents in test, copy them too:
`sudo rsync -a /var/lib/mokaco/documents/ /var/lib/mokaco-test/documents/`.

### 5. Settings

```bash
sudo install -o root -g root -m 600 ~/test-env/api-test.env.example /etc/mokaco/api-test.env
sudo nano /etc/mokaco/api-test.env            # fill the three <...> values
sudo grep -c 'Database=MokaCo_HRMS_Test;User Id=mokaco_api_test;' /etc/mokaco/api-test.env   # must print 1
```
For the JWT key, use `openssl rand -base64 48`. Ask Reda for the TESTMOKANDCO API password, and never use the
live MOKANDCO one.

### 6. The service

```bash
systemctl cat mokaco-api                      # compare ExecStart with the test unit (see its header)
sudo install -m 644 ~/test-env/mokaco-api-test.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mokaco-api-test
curl -s http://127.0.0.1:5079/health          # "environment":"Staging"
sleep 30; sudo journalctl -u mokaco-api-test -n 60 --no-pager
```
About 20 seconds after startup, the journal must say **"Notifications are OFF"** and **"Machine pull is OFF"**. If
either line is missing, stop the service and go back to step 3.

### 7. The login switch

The front end must be a build that has the switch (mokaco-web-mantine, Oct 2026 or later) in **both**
folders: deploy it to production as usual (`deploy-web.sh`), then copy it to the test folder:
```bash
sudo rsync -a --delete /var/www/mokaco-web/ /var/www/mokaco-web-test/
sudo ~/test-env/enable-env-switch.sh            # shows what it changed; undo: --undo
```
Then on the login page: **Test environment** on → the page reloads with a red TEST tag, and everything
after sign-in uses `MokaCo_HRMS_Test`. Off → production. Switching signs that tab out; other open tabs
follow when they are next looked at.

### 8. Optional: a separate address instead

Only if you also want `test.hrms.mokanco.com.lb` (needs the DNS record from IDM).
Use a self-signed certificate until DNS is live:
```bash
sudo openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -subj "/CN=test.hrms.mokanco.com.lb" -addext "subjectAltName=DNS:test.hrms.mokanco.com.lb" \
  -keyout /etc/mokaco/tls/test.key -out /etc/mokaco/tls/test.crt
sudo chmod 600 /etc/mokaco/tls/test.key
sudo install -m 644 ~/test-env/nginx-mokaco-test.conf /etc/nginx/sites-available/mokaco-test
sudo ln -s /etc/nginx/sites-available/mokaco-test /etc/nginx/sites-enabled/mokaco-test
sudo nginx -t && sudo systemctl reload nginx
```
Before DNS exists, test from the laptop with the **VPN off**:
`curl -k --resolve test.hrms.mokanco.com.lb:443:82.146.175.34 https://test.hrms.mokanco.com.lb/health`.

Once IDM's record resolves: `sudo certbot --nginx -d test.hrms.mokanco.com.lb`.

## Using it

- **Try a new API build:** publish it into `/opt/mokaco/api-test`, as `deploy-api.sh` does for `/opt/mokaco/api`,
  then run `sudo systemctl restart mokaco-api-test`. For a new front end, copy its `dist/` into `/var/www/mokaco-web-test`.
- **Apply a `docs/` script to test:** `~/test-env/apply-sql-test.sh docs/NN_name.sql`. **Never** run
  `sqlcmd -d MokaCo_HRMS_Test -i docs/...` directly: 29 of those scripts start with `USE MokaCo_HRMS;` and
  would run in production.
- **Sign in:** the copy has production's users and passwords.
- **Stop it when nobody is testing:** `sudo systemctl stop mokaco-api-test`. Check memory with
  `systemctl status mokaco-api-test` and disk with `df -h`.

## Never on test

- A real mail server or WhatsApp token. Once the test API has a channel, it queues mail for every closed request
  in the copy. To test e-mail, point `SmtpHost` at a local catcher such as Mailpit on 127.0.0.1.
- An address (`PullIp`) on a device that is a real terminal.
- The live merchant `MOKANDCO`, or production's JWT key.
- An `/iclock` location in the test site.
