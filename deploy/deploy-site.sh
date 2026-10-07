#!/usr/bin/env bash
#
# Run ON THE VM:  bash ~/deploy-site.sh
#
# Builds the public website (mokanco-lb, Astro, static) from ~/src/mokanco-lb and
# serves it through nginx on 80/443 as mokanco.com.lb (www redirects there).
#
#   - The website reaches the HRMS API THROUGH ITS OWN ADDRESS: it is built with
#     PUBLIC_BOOKING_API=https://mokanco.com.lb, and nginx passes /api/public/booking/
#     and /hubs/booking on that site to the API on this server, which reads the
#     database. Same chain as development (site -> API -> DB), no api.* DNS needed.
#     To use a separate API host instead:
#       PUBLIC_BOOKING_API=https://api.mokanco.com.lb bash ~/deploy-site.sh
#   - public/_headers and public/_redirects are Netlify/Cloudflare files that
#     nginx ignores; their rules are reproduced below in nginx form.
#   - If mokanco.com.lb and www already resolve to this server, certbot issues
#     their certificate. If not, the site is installed and waits for DNS.
#
# Safe to re-run (each run = rebuild + atomic swap). Touches only its own nginx
# site file and /var/www/mokanco-site.
#
set -euo pipefail
SRC="$HOME/src/mokanco-lb"
ROOT=/var/www/mokanco-site
HOST=${SITE_HOST:-mokanco.com.lb}
WWW=www.$HOST
IP=82.146.175.34
API=${PUBLIC_BOOKING_API:-https://$HOST}
API_HOST=${API#https://}
API_PORT=5078
SAME_ORIGIN=0; [[ "$API_HOST" == "$HOST" ]] && SAME_ORIGIN=1
EMAIL=${CERTBOT_EMAIL:-}
NGX=/etc/nginx/sites-available/mokanco-site

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
resolves_here() { [[ "$(getent hosts "$1" | awk '{print $1}' | head -1)" == "$IP" ]]; }

[[ -f "$SRC/package.json" ]] || die "$SRC not found — run sync-site.sh on the laptop first"
command -v node >/dev/null || die "node is not installed"
[[ $(node -v | sed -E 's/^v([0-9]+).*/\1/') -ge 22 ]] || die "node $(node -v) is too old; the site's .nvmrc asks for 22"

# --- 1. build -------------------------------------------------------------------------
cd "$SRC"
log "npm ci"
npm ci --no-audit --no-fund 2>&1 | tail -3
log "astro build  (PUBLIC_BOOKING_API=$API)"
rm -rf dist
PUBLIC_BOOKING_API="$API" npm run build 2>&1 | tail -12
[[ -f dist/index.html ]] || die "build produced no dist/index.html — the errors above say why"
grep -rqF "$API" dist || die "the build does not contain $API — PUBLIC_BOOKING_API did not reach the bundle"
if grep -rlE 'localhost:5078' dist >/dev/null 2>&1; then die "the build still points at localhost:5078"; fi
echo "    $(find dist -type f | wc -l) files, $(du -sh dist | cut -f1)"

# --- 2. publish (atomic swap) -------------------------------------------------------------
log "publishing to $ROOT"
sudo rm -rf "$ROOT.new" "$ROOT.old"
sudo cp -a dist "$ROOT.new"
sudo chown -R www-data:www-data "$ROOT.new"
[[ -d "$ROOT" ]] && sudo mv "$ROOT" "$ROOT.old"
sudo mv "$ROOT.new" "$ROOT"
sudo rm -rf "$ROOT.old"

# --- 3. certificate: the real one if certbot already issued it, else self-signed -----------
# The script owns the whole nginx file and only POINTS at a certificate, so a re-deploy never
# undoes HTTPS. certbot is used in "certonly --webroot" mode and never edits nginx itself.
LE=/etc/letsencrypt/live/$HOST
TLSDIR=/etc/mokaco/tls
ACME=/var/www/letsencrypt
sudo mkdir -p "$ACME" "$TLSDIR"
pick_cert() {
  if sudo test -f "$LE/fullchain.pem"; then
    CRT=$LE/fullchain.pem; KEY=$LE/privkey.pem; CERT_KIND="Let's Encrypt (trusted)"
  else
    if ! sudo test -f "$TLSDIR/site.crt"; then
      sudo openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
        -keyout "$TLSDIR/site.key" -out "$TLSDIR/site.crt" \
        -subj "/CN=$HOST/O=Moka & Co (interim)" \
        -addext "subjectAltName=DNS:$HOST,DNS:$WWW" 2>/dev/null
      sudo chmod 600 "$TLSDIR/site.key"
    fi
    CRT=$TLSDIR/site.crt; KEY=$TLSDIR/site.key; CERT_KIND="self-signed (interim — browsers warn)"
  fi
}

# --- 4. nginx: the site on 443, port 80 only redirects (and answers certbot's challenge) ----
# nginx replaces (does not merge) add_header sets per location, so every location repeats the
# headers it needs — which is also exactly the _headers semantics: "/pay/" drops the site CSP
# and Referrer-Policy and brings its own.
CSP_SITE="default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self' https://$API_HOST wss://$API_HOST; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
MPGS=https://test-bobsal.gateway.mastercard.com   # CHANGE AT GO-LIVE (see public/_headers)
CSP_PAY="default-src 'self'; script-src 'self' $MPGS; connect-src 'self' https://$API_HOST $MPGS; frame-src $MPGS; img-src 'self' data: $MPGS; style-src 'self' 'unsafe-inline'; font-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self' $MPGS"

write_nginx() {
  sudo tee "$NGX" >/dev/null <<EOF
# mokanco.com.lb — the public website (static Astro build). Written by deploy-site.sh.
# Headers and redirects mirror public/_headers and public/_redirects in the repo.
# Certificate: $CERT_KIND

# port 80: nothing but the certbot challenge and a redirect to https
server {
    listen 80;
    server_name $HOST $WWW;
    location /.well-known/acme-challenge/ { root $ACME; }
    location / { return 301 https://$HOST\$request_uri; }
}

# www -> bare domain
server {
    listen 443 ssl http2;
    server_name $WWW;
    ssl_certificate     $CRT;
    ssl_certificate_key $KEY;
    ssl_protocols       TLSv1.2 TLSv1.3;
    return 301 https://$HOST\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $HOST;
    ssl_certificate     $CRT;
    ssl_certificate_key $KEY;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root $ROOT;
    index index.html;
    error_page 404 /404.html;

    # --- _headers "/*"
    add_header Content-Security-Policy   "$CSP_SITE" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy        "camera=(), microphone=(), geolocation=()" always;
    add_header X-Content-Type-Options    "nosniff" always;

    # --- _redirects
    location = /learn  { return 301 /our-story; }
    location = /learn/ { return 301 /our-story; }

    # --- _headers "/_astro/*": content-hashed build output, cache forever
    location /_astro/ {
        add_header Content-Security-Policy   "$CSP_SITE" always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
        add_header Permissions-Policy        "camera=(), microphone=(), geolocation=()" always;
        add_header X-Content-Type-Options    "nosniff" always;
        add_header Cache-Control             "public, max-age=31536000, immutable" always;
        try_files \$uri =404;
    }

    # --- _headers "/pay/": its own CSP (payment gateway) and Referrer-Policy, no caching
    location = /pay/ {
        add_header Content-Security-Policy   "$CSP_PAY" always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header Referrer-Policy           "no-referrer" always;
        add_header Permissions-Policy        "camera=(), microphone=(), geolocation=()" always;
        add_header X-Content-Type-Options    "nosniff" always;
        add_header Cache-Control             "no-store" always;
        try_files /pay/index.html =404;
    }

$( [[ $SAME_ORIGIN == 1 ]] && cat <<PROXY
    # --- the booking API, reached through the website's own address (-> API -> database).
    # Only the PUBLIC booking surface; the staff API is not exposed on this site.
    # Origin is set to the site itself: a same-origin GET from the browser carries no
    # Origin header, and the API admits the website by its origin (BookingCorsOrigins).
    location /api/public/booking/ {
        proxy_pass         http://127.0.0.1:$API_PORT;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   Origin            https://$HOST;
        proxy_set_header   X-Forwarded-For   \$mokaco_client_ip;
        proxy_set_header   X-Forwarded-Proto \$mokaco_proto;
    }
    # live confirmation page (SignalR): WebSocket upgrade + long read timeout
    location /hubs/booking {
        proxy_pass         http://127.0.0.1:$API_PORT;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   Origin            https://$HOST;
        proxy_set_header   X-Forwarded-For   \$mokaco_client_ip;
        proxy_set_header   X-Forwarded-Proto \$mokaco_proto;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        \$connection_upgrade;
        proxy_read_timeout 3600s;
        proxy_buffering    off;
    }
PROXY
)

    location / {
        try_files \$uri \$uri/ \$uri.html =404;
    }
}
EOF
  sudo ln -sf "$NGX" /etc/nginx/sites-enabled/mokanco-site
  sudo nginx -t
  sudo systemctl reload nginx
  # reload is asynchronous, and until the new workers take over, https://$HOST is answered by
  # the HRMS (the 443 default). Wait for something only THIS site does: the /learn redirect.
  for i in $(seq 1 20); do
    [[ "$(curl -sk -m 2 --resolve "$HOST:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$HOST/learn")" == 301 ]] && break
    sleep 0.5
  done
}

pick_cert
log "nginx site https://$HOST  (certificate: $CERT_KIND)"
write_nginx

# --- 5. real certificate, if DNS already points here and we do not have one yet -------------
if [[ "$CERT_KIND" != Let* ]] && resolves_here "$HOST" && resolves_here "$WWW"; then
  log "DNS points here — requesting the Let's Encrypt certificate"
  args=(certonly --webroot -w "$ACME" --non-interactive --agree-tos
        --cert-name "$HOST" -d "$HOST" -d "$WWW"
        --deploy-hook "systemctl reload nginx")
  if [[ -n "$EMAIL" ]]; then args+=(--email "$EMAIL"); else args+=(--register-unsafely-without-email); fi
  if sudo certbot "${args[@]}"; then
    pick_cert
    log "switching nginx to the real certificate"
    write_nginx
  else
    warn "certbot failed — the site stays on the self-signed certificate; the message above says why"
  fi
fi

# --- 6. check it locally (works before DNS: asks nginx for the name directly) --------------
log "checking through nginx"
R=(--resolve "$HOST:443:127.0.0.1" --resolve "$WWW:443:127.0.0.1")
chk() { curl -sk "${R[@]}" -o /dev/null -m 5 -w "$2" "https://$HOST$1"; }
echo "    https://$HOST/        -> HTTP $(chk / '%{http_code}')"
echo "    https://$HOST/learn   -> $(chk /learn '%{http_code} %{redirect_url}')"
echo "    https://$HOST/pay/    -> HTTP $(chk /pay/ '%{http_code}')"
echo "    https://$WWW/     -> $(curl -sk "${R[@]}" -o /dev/null -m 5 -w '%{http_code} %{redirect_url}' "https://$WWW/")"
echo "    http://$HOST/         -> $(curl -s -o /dev/null -m 5 -w '%{http_code} %{redirect_url}' -H "Host: $HOST" http://127.0.0.1/)"

if [[ "$CERT_KIND" == Let* ]]; then
  DONE="The website is live at https://$HOST (trusted certificate, renews automatically)."
else
  DONE="Installed on https with a SELF-SIGNED certificate (browsers warn once).
Waiting for DNS: $HOST and $WWW must point to $IP (IDM). Then re-run this script:
it fetches the real certificate and switches to it by itself."
fi

cat <<EOF

$DONE

$( if [[ $SAME_ORIGIN == 1 ]]; then
  echo "Booking: the website calls the API through https://$HOST/api/public/booking/ (same server)."
  echo "  Make sure the API admits it:  bash ~/check-website-link.sh --fix"
else
  echo "Booking: the website calls $API. Needs DNS $API_HOST -> $IP and  bash ~/enable-tls.sh,"
  echo "  then  bash ~/check-website-link.sh --fix"
fi )
EOF
