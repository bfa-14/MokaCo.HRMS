#!/usr/bin/env bash
#
# Run ON THE VM, after deploy-api.sh:  bash ~/deploy-web.sh
#
# Builds mokaco-web-mantine from ~/src/mokaco-web-mantine and publishes the
# static result to /var/www/mokaco-web, which nginx already serves at "/".
# Safe to re-run: each run is a fresh build and an atomic swap of the files.
#
# The API address is deliberately EMPTY: src/config.ts then uses relative
# "/api/..." paths, and nginx proxies those to Kestrel on the same origin.
# No CORS, no hostname baked into the bundle — it works on the IP today and on
# a real hostname later without a rebuild.
#
set -euo pipefail
SRC="$HOME/src/mokaco-web-mantine"
WEBROOT=/var/www/mokaco-web

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$SRC/package.json" ]] || die "source not found at $SRC — run sync-to-vm.sh on the laptop first"
[[ -d "$WEBROOT" ]]          || die "$WEBROOT missing — run deploy-api.sh first (it creates the nginx site)"
command -v node >/dev/null   || die "node is not installed on this VM"
major=$(node -v | sed -E 's/^v([0-9]+).*/\1/')
[[ $major -ge 20 ]]          || die "node $(node -v) is too old for a Vite build; need 20+"
echo "    node $(node -v), npm $(npm -v)"

cd "$SRC"
log "installing dependencies (npm ci, from package-lock.json)"
npm ci --no-audit --no-fund 2>&1 | tail -3

log "building (tsc -b && vite build) with VITE_API_BASE_URL empty"
rm -rf dist
VITE_API_BASE_URL= npm run build 2>&1 | tail -15
[[ -f dist/index.html ]] || die "build produced no dist/index.html — the errors above say why"
echo "    $(find dist -type f | wc -l) files, $(du -sh dist | cut -f1)"

# the built bundle must not contain a localhost API address
if grep -rlE 'localhost:(5078|7215)' dist/assets 2>/dev/null | head -1 | grep -q .; then
  die "the bundle references localhost:5078/7215 — VITE_API_BASE_URL was not empty at build time"
fi

log "publishing to $WEBROOT"
# build into a sibling dir and swap, so a visitor never sees a half-copied site
NEW="${WEBROOT}.new"; OLD="${WEBROOT}.old"
sudo rm -rf "$NEW" "$OLD"
sudo cp -a dist "$NEW"
sudo chown -R www-data:www-data "$NEW"
sudo mv "$WEBROOT" "$OLD" && sudo mv "$NEW" "$WEBROOT" && sudo rm -rf "$OLD"

log "verifying"
# Since HTTPS was turned on, port 80 only answers 301 -> https, so check the site where it is
# served. -k: the certificate names the host, not 127.0.0.1.
BASE=http://127.0.0.1
curl -sk -o /dev/null -m 5 https://127.0.0.1/ && BASE=https://127.0.0.1
get() { curl -sk -m 5 "$@"; }
code=$(get -o /dev/null -w '%{http_code}' "$BASE/")
title=$(get "$BASE/" | grep -oE '<title>[^<]*' | head -1)
echo "    GET $BASE/            -> HTTP $code  $title"
echo "    GET $BASE/health      -> $(get "$BASE/health")"
echo "    GET $BASE/some/route  -> HTTP $(get -o /dev/null -w '%{http_code}' "$BASE/employees")  (200 = SPA fallback works)"
asset=$(grep -oE 'assets/[^"]+\.js' "$WEBROOT/index.html" | head -1)
[[ -n "$asset" ]] && echo "    GET $BASE/$asset -> HTTP $(get -o /dev/null -w '%{http_code}' "$BASE/$asset")"

[[ "$code" == 200 ]] || die "the site root is not answering 200"
cat <<EOF

Web app is live: https://hrms.mokanco.com.lb/

Redeploy after changes:  bash ~/sync-to-vm.sh (laptop)  then  bash ~/deploy-web.sh (VM)
EOF
