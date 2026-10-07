#!/usr/bin/env bash
#
# Run ON THE VM:  bash ~/install-db-backup.sh
#
# Installs a nightly full backup of MokaCo_HRMS (SETUP_NOTES.md: "the booking
# ledger will live here — it needs one before go-live").
#
#   02:30 UTC daily  ->  /var/opt/mssql/backup/MokaCo_HRMS_<date>.bak
#                        compressed, checksummed, then RESTORE VERIFYONLY
#   a copy of the newest file in /var/backups/mokaco/ that the `user` account
#   can read WITHOUT sudo, so it can be pulled off the box:
#       rsync -avP mokanco-vm:/var/backups/mokaco/ ~/mokanco-backups/
#   14 days kept on the VM. A backup on the same disk as the database is not a
#   disaster-recovery plan — pull the copies somewhere else regularly.
#
# Uses the mokaco_api login from /etc/mokaco/db.env (db_owner may back up).
# Safe to re-run. Runs a first backup immediately so you see it work.
#
set -euo pipefail
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

sudo test -f /etc/mokaco/db.env || die "/etc/mokaco/db.env missing — restore-db.sh has not been run"
[[ -x /opt/mssql-tools18/bin/sqlcmd ]] || die "sqlcmd not found at /opt/mssql-tools18/bin/sqlcmd"

# --- the backup program ---------------------------------------------------------
log "installing /usr/local/sbin/mokaco-db-backup"
sudo tee /usr/local/sbin/mokaco-db-backup >/dev/null <<'EOF'
#!/usr/bin/env bash
# Nightly full backup of MokaCo_HRMS. Run by mokaco-db-backup.timer as root.
set -euo pipefail
DB=MokaCo_HRMS
DIR=/var/opt/mssql/backup
SHARE=/var/backups/mokaco
KEEP_DAYS=14
SQLCMD=/opt/mssql-tools18/bin/sqlcmd

# credentials: the API's own login, parsed from the root-only env file
cs=$(grep '^ConnectionStrings__MokaCo=' /etc/mokaco/db.env | cut -d= -f2-)
user=$(sed -E 's/.*User Id=([^;]+);.*/\1/' <<<"$cs")
pass=$(sed -E 's/.*Password=([^;]+);.*/\1/' <<<"$cs")
export SQLCMDPASSWORD="$pass"

stamp=$(date -u +%Y%m%d_%H%M)
file="$DIR/${DB}_${stamp}.bak"
mkdir -p "$DIR"; chown mssql:mssql "$DIR"

echo "backup -> $file"
"$SQLCMD" -S localhost -U "$user" -C -b -Q \
  "BACKUP DATABASE [$DB] TO DISK='$file' WITH INIT, COMPRESSION, CHECKSUM, STATS=25"
"$SQLCMD" -S localhost -U "$user" -C -b -Q \
  "RESTORE VERIFYONLY FROM DISK='$file' WITH CHECKSUM"
echo "verified: $(du -h "$file" | cut -f1)"

# a copy the shared 'user' account can read without sudo, for pulling off-box
mkdir -p "$SHARE"; chown root:user "$SHARE"; chmod 750 "$SHARE"
cp "$file" "$SHARE/"; chown root:user "$SHARE/$(basename "$file")"; chmod 640 "$SHARE/$(basename "$file")"

# retention, both places
find "$DIR"   -name "${DB}_*.bak" -mtime +$KEEP_DAYS -delete
find "$SHARE" -name "${DB}_*.bak" -mtime +$KEEP_DAYS -delete
echo "kept: $(ls "$DIR"/${DB}_*.bak | wc -l) backups in $DIR"
EOF
sudo chmod 750 /usr/local/sbin/mokaco-db-backup

# --- service + timer ----------------------------------------------------------------
log "installing mokaco-db-backup.service + .timer (daily 02:30 UTC)"
sudo tee /etc/systemd/system/mokaco-db-backup.service >/dev/null <<'EOF'
[Unit]
Description=Nightly full backup of MokaCo_HRMS
After=mssql-server.service
Requires=mssql-server.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mokaco-db-backup
SyslogIdentifier=mokaco-db-backup
EOF

sudo tee /etc/systemd/system/mokaco-db-backup.timer >/dev/null <<'EOF'
[Unit]
Description=Run the MokaCo_HRMS backup every night

[Timer]
OnCalendar=*-*-* 02:30:00 UTC
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now mokaco-db-backup.timer >/dev/null 2>&1

# --- first run, right now, so the mechanism is proven ---------------------------------
log "running the first backup now"
sudo systemctl start mokaco-db-backup.service
sudo journalctl -u mokaco-db-backup -n 8 --no-pager -o cat | sed 's/^/    /'
echo
log "schedule"
systemctl list-timers mokaco-db-backup.timer --no-pager | sed 's/^/    /'
echo
echo "Pull copies to your laptop any time (no sudo needed):"
echo "    rsync -avP mokanco-vm:/var/backups/mokaco/ ~/mokanco-backups/"
