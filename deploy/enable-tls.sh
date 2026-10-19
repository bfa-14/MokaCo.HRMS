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
#   - HSTS (Strict-Transport-Security: max-age one year) on the HTTPS block of
#     each site it manages — certbot does not add it (QA3). Only that step:
#       HSTS_ONLY=1 bash ~/enable-tls.sh
#
# Safe to re-run.
#
set -euo pipefail
HRMS=${HRMS_HOST:-hrms.mokanco.com.lb}
API=${API_HOST:-api.mokanco.com.lb}
IP=82.146.175.34
PORT=5078
NGINX_DIR=${NGINX_DIR:-/etc/nginx}        # another directory only for tests of add_hsts
SITE=$NGINX_DIR/sites-available/mokaco
API_SITE=$NGINX_DIR/sites-available/mokaco-api
EMAIL=${CERTBOT_EMAIL:-}     # optional: renewal-failure notices go here

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
resolves_here() { [[ "$(getent hosts "$1" | awk '{print $1}' | head -1)" == "$IP" ]]; }

# --- HSTS ----------------------------------------------------------------------------------------
# add_hsts FILE: one line
#     add_header Strict-Transport-Security "max-age=31536000" always;   # mokaco-hsts
# at server level in every HTTPS server block of FILE that has none, and in every location of such
# a block that sets headers of its own (nginx gives a location that has any add_header none of the
# server's). No includeSubDomains: test.hrms... may run on a self-signed certificate, which HSTS
# would make impossible to click through. No preload. Brace-aware (comments and quotes as nginx
# reads them); a one-line location is reported, not edited. Prints what it added; a second run adds
# nothing. Writes FILE in place (owner and mode kept) only when something changed.
add_hsts() {
  local file=$1 tmp
  tmp=$(mktemp)
  python3 - "$file" "$tmp" <<'PY' || { rm -f "$tmp"; return 1; }
import re, sys

src, out = sys.argv[1], sys.argv[2]
HSTS = 'add_header Strict-Transport-Security "max-age=31536000" always;   # mokaco-hsts'
with open(src, 'rb') as f:
    lines = f.read().decode('utf-8', 'surrogateescape').split('\n')

def scan(lines):
    """Top-level blocks; each block: words, open/last line, statements (words, first/end line) and
    child blocks, in order. Comments and quoted strings are read as nginx reads them."""
    top, stack = [], []
    words, word, quote, first = [], '', None, None
    for n, line in enumerate(lines):
        i, space = 0, True
        while i < len(line):
            c = line[i]
            if quote:
                if c == '\\':
                    word += line[i:i + 2]; i += 2; continue
                if c == quote:
                    quote = None
                else:
                    word += c
            elif c in ' \t\r':
                if word:
                    words.append(word); word = ''
                space = True; i += 1; continue
            elif c == '#' and space:
                break
            elif c in '"\'' and not word:
                quote = c
                first = n if first is None else first
            elif c in '{};':
                if word:
                    words.append(word); word = ''
                if c == '{':
                    stack.append({'words': words, 'first': n if first is None else first, 'open': n, 'items': []})
                elif c == '}':
                    if not stack:
                        sys.exit('add_hsts: %s: a "}" too many on line %d' % (src, n + 1))
                    block = stack.pop()
                    block['last'] = n
                    (stack[-1]['items'] if stack else top).append(('block', block))
                elif stack:
                    stack[-1]['items'].append(('stmt', {'words': words, 'first': n if first is None else first, 'end': n}))
                words, first = [], None
                space = True; i += 1; continue
            else:
                word += c
                first = n if first is None else first
            space = False
            i += 1
        if quote:
            word += '\n'
        elif word:
            words.append(word); word = ''
    if stack:
        sys.exit('add_hsts: %s: the braces do not balance' % src)
    return [b for kind, b in top if kind == 'block']

def stmts(block, name):
    return [s for kind, s in block['items'] if kind == 'stmt' and s['words'][:1] == [name]]

def sends_hsts(block):
    return any(len(s['words']) > 1 and s['words'][1].lower() == 'strict-transport-security' for s in stmts(block, 'add_header'))

def https(server):
    return any('ssl' in s['words'][1:] or (len(s['words']) > 1 and re.fullmatch(r'(\S*:)?443', s['words'][1]))
               for s in stmts(server, 'listen'))

def indent(n):
    return re.match(r'[ \t]*', lines[n]).group(0)

inserts = []     # (after line, text, what)
for server in scan(lines):
    if server['words'] != ['server'] or not https(server):
        continue
    names = stmts(server, 'server_name')
    label = ' '.join(names[0]['words'][1:]) if names else '(no server_name)'
    if not sends_hsts(server):
        at = names[0]['end'] if names else server['open']
        pad = indent(names[0]['first']) if names else indent(server['open']) + '    '
        inserts.append((at, pad + HSTS, 'server ' + label))
    for kind, loc in server['items']:
        if kind != 'block' or loc['words'][:1] != ['location'] or not stmts(loc, 'add_header') or sends_hsts(loc):
            continue
        where = '%s location %s' % (label, ' '.join(loc['words'][1:]))
        if loc['open'] == loc['last']:
            print('NOT EDITED (one-line block, add HSTS by hand): %s, line %d' % (where, loc['open'] + 1))
            continue
        inner = [s['first'] for k, s in loc['items']]
        pad = indent(inner[0]) if inner else indent(loc['open']) + '    '
        inserts.append((loc['open'], pad + HSTS, where))

inserts.sort(key=lambda x: x[0])
for k, (at, text, what) in enumerate(inserts):
    print('added: %s, line %d' % (what, at + 2 + k))     # its line in the edited file
for at, text, what in reversed(inserts):
    lines.insert(at + 1, text)
with open(out, 'wb') as f:
    f.write('\n'.join(lines).encode('utf-8', 'surrogateescape'))
PY
  if ! cmp -s "$tmp" "$file"; then
    # shellcheck disable=SC2024   # $tmp is ours to read; only the write needs root
    sudo tee "$file" >/dev/null < "$tmp"
  fi
  rm -f "$tmp"
}

hsts_step() {
  log "nginx: HSTS on the HTTPS blocks (max-age one year; no includeSubDomains, no preload)"
  local f files=() bak
  for f in "$SITE" "$API_SITE" "$SITE.before-env-switch"; do   # the last: what enable-env-switch.sh --undo puts back
    [[ -f "$f" ]] && files+=("$f")
  done
  bak=$(mktemp -d)
  for f in "${files[@]}"; do sudo cp -p "$f" "$bak/$(basename "$f")"; done
  for f in "${files[@]}"; do
    echo "    $f:"
    add_hsts "$f" | sed 's/^/      /' || { for g in "${files[@]}"; do sudo cp -p "$bak/$(basename "$g")" "$g"; done; rm -rf "$bak"; die "add_hsts failed on $f; nothing changed"; }
  done
  if ! sudo nginx -t; then
    for f in "${files[@]}"; do sudo cp -p "$bak/$(basename "$f")" "$f"; done
    rm -rf "$bak"
    die "nginx -t failed with HSTS added; the sites are back as they were"
  fi
  rm -rf "$bak"
  sudo systemctl reload nginx
}

if [[ "${HSTS_ONLY:-0}" == 1 ]]; then
  [[ -f "$SITE" ]] || die "$SITE missing — deploy-api.sh has not been run"
  hsts_step
  sleep 2
  echo "    https://$HRMS/ -> $(curl -sI -m 10 "https://$HRMS/" | grep -i '^strict-transport-security' | tr -d '\r' || echo 'no Strict-Transport-Security header')"
  exit 0
fi

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

# --- HSTS: after certbot, which is what makes the blocks HTTPS ----------------------------------
hsts_step
sleep 2

# --- verify -----------------------------------------------------------------------------------
log "verifying"
echo "    https://$HRMS/health -> $(curl -s -m 10 "https://$HRMS/health")"
echo "    https://$HRMS/ HSTS  -> $(curl -sI -m 10 "https://$HRMS/" | grep -i '^strict-transport-security' | tr -d '\r' || echo 'MISSING')"
[[ $WITH_API == 1 ]] && echo "    https://$API/health  -> $(curl -s -m 10 "https://$API/health")"
echo "    http://$HRMS/        -> HTTP $(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://$HRMS/")  (301 = redirect to https, correct)"
echo "    http://$IP/     -> $(curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}' -m 10 -H "Host: $IP" http://127.0.0.1/)"
echo "    http://$IP/iclock    -> HTTP $(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Host: $IP" http://127.0.0.1/iclock/cdata)  (anything but 301 = terminals unaffected)"
echo "    renewal timer        -> $(systemctl is-active certbot.timer 2>/dev/null || echo 'check: systemctl list-timers | grep certbot')"

cat <<EOF

Done. The HRMS is live at:   https://$HRMS
EOF
[[ $WITH_API == 1 ]] || echo "(api.mokanco.com.lb skipped — add its A record and re-run this script when the website needs it.)"
