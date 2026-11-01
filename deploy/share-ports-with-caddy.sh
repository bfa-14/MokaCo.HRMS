#!/usr/bin/env bash
#
# deploy/share-ports-with-caddy.sh — run the HRMS (nginx) and the "sis" stack (Docker, fronted by Caddy) on
# the same VM. Run ON THE VM:
#
#   bash ~/src/MokaCo.HRMS/deploy/share-ports-with-caddy.sh            # do it
#   bash ~/src/MokaCo.HRMS/deploy/share-ports-with-caddy.sh --check    # only show what it would do
#   bash ~/src/MokaCo.HRMS/deploy/share-ports-with-caddy.sh --undo     # give 80/443 back to Caddy (HRMS down)
#
# WHY. Only one program can listen on 80/443. The sis stack's Caddy took them (1 Nov 2026), nginx could not
# start, and the HRMS and the website went down. Now nginx owns 80/443 again and hands sis's domains to Caddy:
#   - Caddy is published on 127.0.0.1:8080 (http) and 127.0.0.1:8443 (https) instead of 80/443 — the only
#     change to sis: a docker-compose.override.yml beside its compose file (sis's own file is not edited);
#   - port 80: nginx passes sis's domains to Caddy as they are (its own redirects and ACME challenges);
#   - port 443: nginx answers sis's domains with a Let's Encrypt certificate of its own (certbot, cert name
#     mokaco-sis) and passes the request on to Caddy over https, so nothing in sis's own setup changes.
# sis's domains are read from Caddy's Caddyfile (DOMAINS="a.com b.com" overrides). A domain of the HRMS is
# never handed over.
#
# Stops before changing anything if a check fails; if a step after a change fails it puts the previous
# state back. It does NOT touch sshd, the firewall, netplan, Bitdefender or the shared account.
#
set -euo pipefail
CONTAINER=${CADDY_CONTAINER:-sis-caddy-1}
SITE=/etc/nginx/sites-available/mokaco-sis
CERT=mokaco-sis
OURS='^(mokanco\.com\.lb|www\.mokanco\.com\.lb|hrms\.mokanco\.com\.lb|test\.hrms\.mokanco\.com\.lb|api\.mokanco\.com\.lb)$'
IP=82.146.175.34
STAMP=$(date +%Y%m%d-%H%M%S)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

mode=${1:-}
case "$mode" in ''|--check|--undo) ;; *) echo "usage: bash $0 [--check | --undo]" >&2; exit 2 ;; esac

# ---- the Caddy container and the compose project it belongs to ---------------------------------------
sudo docker inspect "$CONTAINER" >/dev/null 2>&1 || die "no container $CONTAINER (CADDY_CONTAINER=... names another)"
label() { sudo docker inspect "$CONTAINER" --format "{{index .Config.Labels \"com.docker.compose.$1\"}}"; }
WORKDIR=$(label project.working_dir); PROJECT=$(label project); SERVICE=$(label service); FILES=$(label project.config_files)
[[ -n "$WORKDIR" && -n "$SERVICE" && -n "$FILES" ]] || die "$CONTAINER was not started by docker compose; move its ports by hand"
IFS=',' read -r -a COMPOSE_FILES <<< "$FILES"
FARGS=(); for f in "${COMPOSE_FILES[@]}"; do FARGS+=(-f "$f"); done
compose() { (cd "$WORKDIR" && sudo docker compose -p "$PROJECT" "${FARGS[@]}" "$@"); }
echo "    $CONTAINER: compose project $PROJECT, service $SERVICE, files: ${COMPOSE_FILES[*]}"

# Caddy's ports are REPLACED by an override file next to sis's compose file, which is never edited:
# docker-compose.override.yml is read automatically with docker-compose.yml, so sis's own
# `docker compose up` keeps Caddy on 127.0.0.1 too. `!override` swaps the whole list, whatever form
# the original uses (an ${ENV} port, the long syntax, 443/udp).
OVERRIDE="$(dirname "${COMPOSE_FILES[0]}")/docker-compose.override.yml"
MARK='# Written by MokaCo.HRMS deploy/share-ports-with-caddy.sh'
ours_override() { sudo test -f "$OVERRIDE" && sudo grep -qF "$MARK" "$OVERRIDE"; }
if [[ ! " ${COMPOSE_FILES[*]} " == *" $OVERRIDE "* ]]; then
  if sudo test -f "$OVERRIDE" && ! ours_override; then
    die "$OVERRIDE exists and is sis's own: add Caddy's ports to it by hand (127.0.0.1:8080:80, 127.0.0.1:8443:443)"
  fi
  sudo test -f "$OVERRIDE" && FARGS+=(-f "$OVERRIDE")
fi
move_ports() {   # in: Caddy on 127.0.0.1:8080/8443; out: back to what sis's own file says
  if [[ "$1" == in ]]; then
    printf '%s\n%s\n' "$MARK" "# Caddy on the loopback; nginx owns 80/443 and hands sis's domains to it. Undo: --undo" \
      | sudo tee "$OVERRIDE" >/dev/null
    printf 'services:\n  %s:\n    ports: !override\n      - "127.0.0.1:8080:80"\n      - "127.0.0.1:8443:443"\n' "$SERVICE" \
      | sudo tee -a "$OVERRIDE" >/dev/null
    [[ " ${FARGS[*]} " == *" $OVERRIDE "* ]] || FARGS+=(-f "$OVERRIDE")
  else
    ours_override && sudo rm -f "$OVERRIDE"
    local keep=() i
    for ((i = 0; i < ${#FARGS[@]}; i += 2)); do [[ "${FARGS[i+1]}" == "$OVERRIDE" ]] || keep+=(-f "${FARGS[i+1]}"); done
    FARGS=("${keep[@]}")
  fi
}
published() { sudo docker port "$CONTAINER" 2>/dev/null | sed 's/^/      /'; }

# Site addresses of a Caddyfile (stdin, then '#--ENV--' and the container's environment): the top-level
# lines that open a block, minus the global options block and snippets; {$VAR} / {$VAR:default} resolved.
CADDY_SITES='
import re, sys
text, _, envtext = sys.stdin.read().partition("#--ENV--")
env = dict(l.split("=", 1) for l in envtext.splitlines() if "=" in l)
sub = lambda m: env.get(m.group(1), m.group(2) or "")
names = set()
for line in text.splitlines():
    line = re.sub(r"\{\$([A-Za-z0-9_]+)(?::([^}]*))?\}", sub, line)
    if not line or line[0].isspace() or line[0] in "#({" or not line.rstrip().endswith("{"):
        continue
    for a in re.split(r"[,\s]+", line.rstrip()[:-1]):
        a = re.sub(r"^[a-z]+://", "", a).split("/")[0]
        a = re.sub(r":[0-9]+$", "", a)
        if re.fullmatch(r"[A-Za-z0-9.-]+\.[A-Za-z]{2,}", a):
            names.add(a.lower())
print(" ".join(sorted(names)))
'

if [[ "$mode" == --undo ]]; then
  log "giving 80/443 back to Caddy: the HRMS and the website go down"
  sudo rm -f /etc/nginx/sites-enabled/mokaco-sis
  sudo systemctl stop nginx
  move_ports out
  compose up -d --no-deps "$SERVICE"
  published
  log "done: Caddy on 80/443, nginx stopped"
  exit 0
fi

# ---- sis's domains -----------------------------------------------------------------------------------
if [[ -z "${DOMAINS:-}" ]]; then
  DOMAINS=$( { sudo docker exec "$CONTAINER" cat /etc/caddy/Caddyfile; echo '#--ENV--'; sudo docker exec "$CONTAINER" env; } \
    | python3 -c "$CADDY_SITES")
fi
DOMAINS=$(echo "$DOMAINS" | xargs)
[[ -n "$DOMAINS" ]] || die "found no domain in Caddy's Caddyfile; give them: DOMAINS=\"sis.example.com\" bash $0"
for d in $DOMAINS; do
  [[ "$d" =~ $OURS ]] && die "$d is an HRMS domain and also in Caddy's Caddyfile: decide which system serves it first"
  [[ "$(getent hosts "$d" | awk '{print $1}' | head -1)" == "$IP" ]] || warn "$d does not resolve to $IP (its certificate will fail until it does)"
done
echo "    sis domains (from Caddy): $DOMAINS"
command -v certbot >/dev/null || die "certbot is not installed"

if [[ "$mode" == --check ]]; then
  log "--check: nothing changed. The compose port lines that would move:"
  echo "    Caddy publishes now:"; published
  echo "    after: 127.0.0.1:8080 -> 80 and 127.0.0.1:8443 -> 443, through $OVERRIDE"
  exit 0
fi

# ---- 1. backups --------------------------------------------------------------------------------------
log "backups"
sudo tar -czf "/root/nginx-before-sis-$STAMP.tgz" -C / etc/nginx
echo "    /root/nginx-before-sis-$STAMP.tgz (sis's compose file is not edited)"

restore() {
  warn "putting the previous state back"
  sudo rm -f /etc/nginx/sites-enabled/mokaco-sis "$SITE"
  sudo systemctl stop nginx || true
  move_ports out
  compose up -d --no-deps "$SERVICE" || true
}

# ---- 2. Caddy off 80/443 -----------------------------------------------------------------------------
log "moving Caddy to 127.0.0.1:8080 / 127.0.0.1:8443"
move_ports in
compose up -d --no-deps "$SERVICE" || { restore; die "docker compose could not restart $SERVICE"; }
published
if sudo docker port "$CONTAINER" | grep -qE '0\.0\.0\.0:(80|443)$|\[::\]:(80|443)$'; then
  restore; die "Caddy still publishes 80/443 (above): the override was not applied"
fi

# ---- 3. port 80 for sis, then nginx up -----------------------------------------------------------------
proxy_headers='        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $mokaco_client_ip;
        proxy_set_header X-Forwarded-For   $mokaco_client_ip;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;
        proxy_read_timeout 300s;
        client_max_body_size 50m;'
write_site() {   # $1 = with https (1) or not (0)
  {
    echo "# Written by deploy/share-ports-with-caddy.sh. The sis stack's domains, handed to its Caddy container"
    echo "# (127.0.0.1:8080 http, 127.0.0.1:8443 https). Undo: share-ports-with-caddy.sh --undo"
    echo "server {"
    echo "    listen 80;"
    echo "    server_name $DOMAINS;"
    echo "    location / {"
    echo "        proxy_pass http://127.0.0.1:8080;"
    echo "$proxy_headers"
    echo "    }"
    echo "}"
    if [[ "$1" == 1 ]]; then
      echo "server {"
      echo "    listen 443 ssl http2;"
      echo "    server_name $DOMAINS;"
      echo "    ssl_certificate     /etc/letsencrypt/live/$CERT/fullchain.pem;"
      echo "    ssl_certificate_key /etc/letsencrypt/live/$CERT/privkey.pem;"
      echo "    include /etc/letsencrypt/options-ssl-nginx.conf;"
      echo "    location / {"
      echo "        proxy_pass https://127.0.0.1:8443;"
      echo "        proxy_ssl_server_name on;"
      echo "        proxy_ssl_name \$host;"
      echo "$proxy_headers"
      echo "        proxy_set_header X-Forwarded-Proto https;"
      echo "    }"
      echo "}"
    fi
  } | sudo tee "$SITE" >/dev/null
  sudo ln -sf "$SITE" /etc/nginx/sites-enabled/mokaco-sis
}
log "nginx: sis's domains on port 80 -> Caddy; starting nginx"
write_site 0
sudo nginx -t || { restore; die "nginx -t failed (above)"; }
sudo systemctl enable nginx >/dev/null 2>&1
sudo systemctl restart nginx || { sudo journalctl -u nginx -n 15 --no-pager; restore; die "nginx did not start (above)"; }
sleep 2
for h in hrms.mokanco.com.lb mokanco.com.lb; do
  echo "    https://$h -> HTTP $(curl -s -o /dev/null -m 10 -w '%{http_code}' --resolve "$h:443:127.0.0.1" "https://$h/" || true)"
done

# ---- 4. a certificate for sis's domains, then https --------------------------------------------------
log "certificate for $DOMAINS (certbot, name $CERT)"
# shellcheck disable=SC2046   # one -d per domain
if sudo certbot certonly --nginx --non-interactive --agree-tos --keep-until-expiring --cert-name "$CERT" $(printf -- '-d %s ' $DOMAINS); then
  write_site 1
  if sudo nginx -t; then
    sudo systemctl reload nginx
  else
    write_site 0; sudo nginx -t && sudo systemctl reload nginx
    warn "nginx refused the https part (above); sis answers on http only. The HRMS is up."
  fi
else
  warn "certbot could not get a certificate (above): sis answers on http only for now. The HRMS is up."
  warn "When the domains resolve to $IP, run this script again."
fi
sleep 2
for h in $DOMAINS; do
  echo "    https://$h -> HTTP $(curl -s -o /dev/null -m 10 -w '%{http_code}' --resolve "$h:443:127.0.0.1" "https://$h/" || true)"
done
log "done: nginx on 80/443 (HRMS, website, and sis's domains via Caddy). Undo: bash $0 --undo"
