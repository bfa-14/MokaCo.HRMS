#!/usr/bin/env bash
#
# Run ON THE VM once DNS resolves hrms.mokanco.com.lb to 82.146.175.34:
#       CERTBOT_EMAIL=you@company.com bash ~/enable-tls.sh
#
# What it does:
#   - checks DNS itself and stops with a clear message if it is not ready
#   - nginx: names the HRMS site hrms.mokanco.com.lb (the web app AND its /api,
#     same origin — this is all the HRMS needs)
#   - OPTIONAL: if api.mokanco.com.lb ALSO resolves here, adds an API-only site
#     for the public booking website. If it does not resolve yet, it is skipped;
#     re-run this script after adding that record and it gets included.
#   - certbot --nginx: real Let's Encrypt certificate(s), HTTP -> HTTPS redirect,
#     automatic renewal
#   - replaces the interim self-signed certificate if enable-https-ip.sh was used
#   - the bare IP redirects to https://hrms.mokanco.com.lb, except /iclock
#     (fingerprint terminals: plain HTTP, no redirects — see Program.cs)
#
# Safe to re-run.
#
set -euo pipefail
HRMS=${HRMS_HOST:-hrms.mokanco.com.lb}
API=${API_HOST:-api.mokanco.com.lb}
IP=82.146.175.34
PORT=5078
SITE=/etc/nginx/sites-available/mokaco
EMAIL=${CERTBOT_EMAIL:-}     # optional: renewal-failure notices go here

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
resolves_here() { [[ "$(getent hosts "$1" | awk '{print $1}' | head -1)" == "$IP" ]]; }

# --- preconditions ----------------------------------------------------------------
log "precondition 1/2: DNS"
resolves_here "$HRMS" || die "$HRMS resolves to '$(getent hosts "$HRMS" | awk '{print $1}' | head -1)', expected $IP.
     DNS is not ready — the A record must be added at IDM (ns0.idm.net.lb)."
echo "    $HRMS -> $IP"
WITH_API=0
if resolves_here "$API"; then
  WITH_API=1; echo "    $API -> $IP  (API-only site will be added)"
else
  echo "    $API -> not set up (fine: only the public website needs it; skipped)"
fi

log "precondition 2/2: API answering locally"
curl -sf -m 5 "http://127.0.0.1:$PORT/health" >/dev/null || die "the API is not answering on 127.0.0.1:$PORT — fix that first"
[[ -f "$SITE" ]] || die "$SITE missing — deploy-api.sh has not been run"
command -v certbot >/dev/null || die "certbot not installed — sudo apt-get install -y python3-certbot-nginx"

# --- nginx: the HRMS site gets its name ---------------------------------------------------
log "nginx: server_name $HRMS on the HRMS site"
sudo sed -i -e "s/^    server_name .*;$/    server_name $HRMS;/" \
            -e "s/^    listen 80 default_server;$/    listen 80;/" "$SITE"
# after enable-https-ip.sh the site listens on 443 only; certbot needs it on 80
# too (for the challenge, and to put its redirect there)
grep -qE '^    listen 80;$' "$SITE" || sudo sed -i '0,/^server {$/s//server {\n    listen 80;/' "$SITE"
grep -q "server_name $HRMS;" "$SITE" || die "could not set server_name in $SITE"

# anything that is not a known name (above all the bare IP) -> https://$HRMS, except /iclock
log "nginx: bare IP -> https://$HRMS (except /iclock for the terminals)"
sudo tee /etc/nginx/sites-available/mokaco-default >/dev/null <<EOF
server {
    listen 80 default_server;
    server_name _;

    location /iclock {
        proxy_pass         http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Forwarded-For   \$mokaco_client_ip;
        proxy_set_header   X-Forwarded-Proto \$mokaco_proto;
    }

    location / {
        return 301 https://$HRMS\$request_uri;
    }
}
EOF
sudo ln -sf /etc/nginx/sites-available/mokaco-default /etc/nginx/sites-enabled/mokaco-default

if [[ $WITH_API == 1 ]]; then
  log "nginx: API-only site $API (for the public website)"
  sudo tee /etc/nginx/sites-available/mokaco-api >/dev/null <<EOF
# api.mokanco.com.lb — the API alone, for the public website (mokanco-lb).
# Same Kestrel process as the HRMS site.
server {
    listen 80;
    server_name $API;

    client_max_body_size 50m;

    location / {
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
}
EOF
  sudo ln -sf /etc/nginx/sites-available/mokaco-api /etc/nginx/sites-enabled/mokaco-api
fi

sudo nginx -t
sudo systemctl reload nginx
sleep 2

# --- certificates -------------------------------------------------------------------------
DOMAINS=(-d "$HRMS"); [[ $WITH_API == 1 ]] && DOMAINS+=(-d "$API")
log "certbot: certificate for $HRMS$([[ $WITH_API == 1 ]] && echo " and $API")"
args=(--nginx --non-interactive --agree-tos --redirect --expand "${DOMAINS[@]}")
if [[ -n "$EMAIL" ]]; then args+=(--email "$EMAIL"); else args+=(--register-unsafely-without-email); fi
sudo certbot "${args[@]}" || die "certbot failed. If the challenge timed out or was refused, inbound
     port 80 is not reaching this box from the internet (Globalcom's firewall)."

sudo nginx -t && sudo systemctl reload nginx
sleep 2

# --- verify -----------------------------------------------------------------------------------
log "verifying"
echo "    https://$HRMS/health -> $(curl -s -m 10 "https://$HRMS/health")"
[[ $WITH_API == 1 ]] && echo "    https://$API/health  -> $(curl -s -m 10 "https://$API/health")"
echo "    http://$HRMS/        -> HTTP $(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://$HRMS/")  (301 = redirect to https, correct)"
echo "    http://$IP/     -> $(curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}' -m 10 -H "Host: $IP" http://127.0.0.1/)"
echo "    http://$IP/iclock    -> HTTP $(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Host: $IP" http://127.0.0.1/iclock/cdata)  (anything but 301 = terminals unaffected)"
echo "    renewal timer        -> $(systemctl is-active certbot.timer 2>/dev/null || echo 'check: systemctl list-timers | grep certbot')"

cat <<EOF

Done. The HRMS is live at:   https://$HRMS
EOF
[[ $WITH_API == 1 ]] || echo "(api.mokanco.com.lb skipped — add its A record and re-run this script when the website needs it.)"
