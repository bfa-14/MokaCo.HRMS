#!/usr/bin/env bash
#
# Run ON THE VM:  bash ~/deploy-api.sh
#
# Builds the MokaCo.HRMS API from ~/src/MokaCo.HRMS, installs it under
# /opt/mokaco/api as a systemd service on 127.0.0.1:5078, and puts nginx in
# front of it on port 80. Safe to re-run: a second run is a redeploy (rebuild,
# reinstall, restart) and keeps the existing secrets in /etc/mokaco/api.env.
#
# It does NOT touch: sshd, the firewall, the account password, netplan, or
# Bitdefender. The only nginx change is adding the "mokaco" site and disabling
# the stock "default" placeholder page.
#
set -euo pipefail
SRC="$HOME/src/MokaCo.HRMS"
APP=/opt/mokaco/api
DATA=/var/lib/mokaco
ENVF=/etc/mokaco/api.env
DBENV=/etc/mokaco/db.env
WEBROOT=/var/www/mokaco-web
PORT=5078
SVC=mokaco-api
RUNAS=mokaco

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# =============================================================================
# 0. Preflight — discover the box, stop on anything that needs a human decision
# =============================================================================
log "preflight"
[[ -d "$SRC" ]]        || die "source not found at $SRC — run sync-to-vm.sh on the laptop first"
sudo test -f "$DBENV"  || die "$DBENV missing — restore-db.sh did not finish"
sudo -n true 2>/dev/null && echo "    sudo: passwordless" || echo "    sudo: will prompt for your password"

if [[ -f "$HOME/SETUP_NOTES.md" ]]; then
  echo "    ---- SETUP_NOTES.md (passwords masked) ----"
  sed -E 's/([Pp]assword[^:=]*[:=] *).*/\1<redacted>/' "$HOME/SETUP_NOTES.md" | sed 's/^/    | /'
  echo "    -------------------------------------------"
fi

if ! dotnet --list-sdks 2>/dev/null | grep -q '^10\.'; then
  warn ".NET 10 SDK not present (runtime alone cannot build) — installing dotnet-sdk-10.0"
  sudo apt-get install -y -qq dotnet-sdk-10.0
fi
DOTNET=$(command -v dotnet) || die "dotnet not on PATH"
echo "    dotnet: $($DOTNET --version)   node: $(node -v 2>/dev/null || echo none)   nginx: $(nginx -v 2>&1 | cut -d/ -f2)"

command -v nginx >/dev/null || die "nginx is not installed"
others=$(ls /etc/nginx/sites-enabled/ 2>/dev/null | grep -vE '^(default|mokaco)$' || true)
if [[ -n "$others" ]]; then
  die "nginx already serves other sites on this shared box: $others
     Adding a default_server for the API would fight with them. Show this to Reda before continuing."
fi
if sudo ss -tlnp | grep -q ":$PORT "; then
  sudo ss -tlnp | grep ":$PORT " | grep -q "$SVC\|MokaCo" \
    || die "something other than $SVC is already listening on port $PORT: $(sudo ss -tlnp | grep ":$PORT ")"
fi

# =============================================================================
# 1. The reverse-proxy fix (commit bb201ff) — needed behind nginx
# =============================================================================
if grep -q 'UseForwardedHeaders' "$SRC/MokaCo.HRMS.API/Program.cs"; then
  log "ForwardedHeaders fix already present in Program.cs"
else
  log "applying forwarded-headers.patch"
  (cd "$SRC" && patch -p1 --forward < "$HOME/forwarded-headers.patch")
fi

# =============================================================================
# 2. Build
# =============================================================================
log "publishing the API (Release, framework-dependent)"
PUB=$(mktemp -d)
"$DOTNET" publish "$SRC/MokaCo.HRMS.API" -c Release -o "$PUB" --nologo -v q 2>&1 | grep -vE '^\s*$' | tail -5
[[ -f "$PUB/MokaCo.HRMS.API.dll" ]] || die "publish produced no MokaCo.HRMS.API.dll"
echo "    $(ls "$PUB" | wc -l) files, $(du -sh "$PUB" | cut -f1)"

# =============================================================================
# 3. Service account, directories, files
# =============================================================================
if ! id -u "$RUNAS" >/dev/null 2>&1; then
  log "creating system user $RUNAS"
  sudo useradd --system --home-dir "$DATA" --shell /usr/sbin/nologin "$RUNAS"
fi

log "installing to $APP"
sudo mkdir -p "$APP" "$DATA/documents" /etc/mokaco "$WEBROOT"
sudo rsync -a --delete "$PUB/" "$APP/"
rm -rf "$PUB"
# mktemp -d makes the build folder mode 700 and rsync -a copies that onto $APP,
# which leaves the service user unable to cd into it (systemd: status=200/CHDIR).
# Set the permissions explicitly: owner root, group $RUNAS read-only, nobody else.
sudo chown -R root:"$RUNAS" "$APP"
sudo chmod 750 "$APP"
sudo chmod -R g+rX,o-rwx "$APP"

# uploaded documents live OUTSIDE the app directory so a redeploy never deletes
# them. Seed once from the source tree's App_Data if the target is still empty.
if [[ -z "$(sudo ls -A "$DATA/documents")" && -d "$SRC/MokaCo.HRMS.API/App_Data/documents" ]]; then
  log "seeding $DATA/documents from the source tree"
  sudo cp -a "$SRC/MokaCo.HRMS.API/App_Data/documents/." "$DATA/documents/"
fi
sudo chown -R "$RUNAS":"$RUNAS" "$DATA"
sudo chmod 750 "$DATA"

# =============================================================================
# 4. Environment — written ONCE; later runs keep it (that is where the JWT key
#    lives, and rotating it would log every user out)
# =============================================================================
if sudo test -f "$ENVF"; then
  log "keeping existing $ENVF"
else
  log "writing $ENVF (root-only)"
  JWT=$(openssl rand -base64 48 | tr -d '\n')
  {
    echo "ASPNETCORE_ENVIRONMENT=Production"
    echo "ASPNETCORE_URLS=http://127.0.0.1:$PORT"
    echo "DOTNET_PRINT_TELEMETRY_MESSAGE=false"
    echo "HOME=$DATA"
    echo "Storage__DocumentsPath=$DATA/documents"
    echo "Jwt__SecretKey=$JWT"
    sudo cat "$DBENV"
  } | sudo tee "$ENVF" >/dev/null
  sudo chmod 600 "$ENVF"
fi

# =============================================================================
# 5. systemd unit
# =============================================================================
log "installing $SVC.service"
sudo tee /etc/systemd/system/$SVC.service >/dev/null <<EOF
[Unit]
Description=MokaCo HRMS API
After=network-online.target mssql-server.service
Wants=network-online.target mssql-server.service

[Service]
Type=simple
User=$RUNAS
Group=$RUNAS
WorkingDirectory=$APP
EnvironmentFile=$ENVF
ExecStart=$DOTNET $APP/MokaCo.HRMS.API.dll
Restart=always
RestartSec=5
KillSignal=SIGINT
TimeoutStopSec=30
SyslogIdentifier=$SVC

# The app only ever writes under $DATA (documents, data-protection keys).
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable "$SVC" >/dev/null 2>&1
sudo systemctl restart "$SVC"

# =============================================================================
# 6. nginx — site at /, API paths proxied, WebSockets for the hubs
# =============================================================================
log "configuring nginx"
# the Upgrade→Connection map must live in http{} scope, so it goes in conf.d
sudo tee /etc/nginx/conf.d/mokaco-upgrade-map.conf >/dev/null <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
# Real visitor address and scheme, whether the request arrives directly (VPN)
# or through a proxy in front of nginx that sets CF-Connecting-IP and
# X-Forwarded-Proto. Absent headers fall back to the connection itself.
sudo tee /etc/nginx/conf.d/mokaco-client-ip.conf >/dev/null <<'EOF'
map $http_cf_connecting_ip $mokaco_client_ip {
    ""      $remote_addr;
    default $http_cf_connecting_ip;
}
map $http_x_forwarded_proto $mokaco_proto {
    ""      $scheme;
    default $http_x_forwarded_proto;
}
EOF

sudo tee /etc/nginx/sites-available/mokaco >/dev/null <<EOF
server {
    listen 80 default_server;
    server_name _;

    root $WEBROOT;
    index index.html;

    # employee document uploads go through /api/documents
    client_max_body_size 50m;

    # Everything the API owns. /hubs carries SignalR WebSockets, so the upgrade
    # headers and a long read timeout are required, not optional.
    location ~ ^/(api|hubs|iclock|health)(/|\$) {
        proxy_pass         http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$mokaco_client_ip;
        proxy_set_header   X-Forwarded-Proto \$mokaco_proto;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        \$connection_upgrade;
        proxy_read_timeout 3600s;
        proxy_buffering    off;
    }

    # Vite emits content-hashed files under /assets — cache them hard.
    location /assets/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files \$uri =404;
    }

    # The React app: any other path is a client-side route.
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

# a holding page until the front end is built, so "/" is not a 403
if [[ ! -f "$WEBROOT/index.html" ]]; then
  sudo tee "$WEBROOT/index.html" >/dev/null <<'EOF'
<!doctype html><meta charset="utf-8"><title>MokaCo HRMS</title>
<body style="font-family:system-ui;margin:3rem"><h1>MokaCo HRMS</h1>
<p>API is deployed. The web app has not been built yet.</p>
<p><a href="/health">/health</a></p></body>
EOF
fi
sudo chown -R www-data:www-data "$WEBROOT"

sudo ln -sf /etc/nginx/sites-available/mokaco /etc/nginx/sites-enabled/mokaco
sudo rm -f /etc/nginx/sites-enabled/default        # the stock "Welcome to nginx" page; file stays in sites-available
sudo nginx -t
sudo systemctl reload nginx

# =============================================================================
# 7. Verify
# =============================================================================
log "verifying"
sleep 4
echo "--- service:"; systemctl is-active "$SVC" | sed 's/^/    /'
echo "--- Kestrel direct   :"; curl -s -m 5 "http://127.0.0.1:$PORT/health" | sed 's/^/    /'; echo
echo "--- through nginx    :"; curl -s -m 5 "http://127.0.0.1/health" | sed 's/^/    /'; echo
echo "--- login endpoint answers (400/401 = alive, it just needs a body):"
echo "    HTTP $(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST http://127.0.0.1/api/auth/login -H 'Content-Type: application/json' -d '{}')"
echo "--- last log lines:"; sudo journalctl -u "$SVC" -n 15 --no-pager -o cat | sed 's/^/    /'

if systemctl is-active --quiet "$SVC" && curl -sf -m 5 "http://127.0.0.1/health" >/dev/null; then
  cat <<EOF

API is up. From your laptop (tunnel up):  http://82.146.175.34/health

Day to day:
  sudo systemctl status $SVC          sudo journalctl -u $SVC -f
  bash ~/deploy-api.sh                (redeploy after a new sync)

Next: the front end.
EOF
else
  die "the service is not healthy — the journal lines above say why"
fi
