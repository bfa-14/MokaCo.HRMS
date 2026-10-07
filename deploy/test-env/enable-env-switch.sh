#!/usr/bin/env bash
# deploy/test-env/enable-env-switch.sh — the login page's "Test environment" switch, on the VM.
#
# One address for both. The switch sends the browser to /env/test or /env/prod; nginx sets or clears
# the cookie mokaco_env and redirects to /login. With mokaco_env=test:
#   /api, /hubs, /health -> the test API, 127.0.0.1:5079 (MokaCo_HRMS_Test)
#   the pages            -> /var/www/mokaco-web-test
# Without it, everything goes where it goes today. /iclock ALWAYS goes to production: the
# fingerprint terminals send no cookie and their punches belong to production. The public website's
# booking calls go through its own site (mokanco-site), which this does not touch.
#
#   sudo deploy/test-env/enable-env-switch.sh          # turn it on
#   sudo deploy/test-env/enable-env-switch.sh --undo   # put the site back exactly as it was
#
# Edits /etc/nginx/sites-available/mokaco (production's proxy_pass and root become cookie-driven,
# and the two /env/ locations are added), keeps the original as mokaco.before-env-switch, and adds
# /etc/nginx/conf.d/mokaco-env.conf. If nginx -t fails, both are put back before it exits.
set -euo pipefail

SITE=/etc/nginx/sites-available/mokaco
SAVED=$SITE.before-env-switch
MAP=/etc/nginx/conf.d/mokaco-env.conf
PROD_PORT=5078
TEST_PORT=5079
PROD_WEB=/var/www/mokaco-web
TEST_WEB=/var/www/mokaco-web-test

die() { echo "enable-env-switch: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run it with sudo."
[ -f "$SITE" ] || die "$SITE not found."

if [ "${1:-}" = "--undo" ]; then
  [ -f "$SAVED" ] || die "nothing to undo: $SAVED not found."
  cp -p "$SAVED" "$SITE"
  rm -f "$MAP"
  nginx -t
  systemctl reload nginx
  rm -f "$SAVED"
  echo "Switch removed; the site is as it was."
  exit 0
fi

grep -q 'mokaco_api_upstream' "$SITE" && die "already on. To take it off: sudo $0 --undo"
[ -e "$SAVED" ] && die "$SAVED already exists from an earlier run; check it, then remove it."

api=$(grep -cE "proxy_pass[[:space:]]+http://127\.0\.0\.1:$PROD_PORT;" "$SITE" || true)
roots=$(grep -cE "^[[:space:]]*root[[:space:]]+$PROD_WEB;" "$SITE" || true)
locs=$(grep -cE '^[[:space:]]*location[[:space:]]+~[[:space:]]+\^/\(api\|hubs' "$SITE" || true)
[ "$api" -ge 1 ] || die "no 'proxy_pass http://127.0.0.1:$PROD_PORT;' in $SITE. Nothing changed."
[ "$roots" -ge 1 ] || die "no 'root $PROD_WEB;' in $SITE. Nothing changed."
[ "$locs" -ge 1 ] || die "no 'location ~ ^/(api|hubs...' block in $SITE. Nothing changed."
[ -f "$TEST_WEB/index.html" ] || die "$TEST_WEB/index.html missing: copy the front end first (README step 7). Nothing changed."

cp -p "$SITE" "$SAVED"
restore() { cp -p "$SAVED" "$SITE"; rm -f "$MAP" "$SAVED"; }

cat > "$MAP" <<EOF
# Written by deploy/test-env/enable-env-switch.sh (MokaCo.HRMS). Undo: enable-env-switch.sh --undo
# The login page's switch sets mokaco_env=test: the API paths then go to the test API and the pages
# to the test copy of the front end. /iclock is deliberately not in the list: the terminals'
# punches always go to production.
map "\$cookie_mokaco_env:\$uri" \$mokaco_api_upstream {
    default                            127.0.0.1:$PROD_PORT;
    "~^test:/(api|hubs|health)(/|\$)"   127.0.0.1:$TEST_PORT;
}
map \$cookie_mokaco_env \$mokaco_webroot {
    default  $PROD_WEB;
    test     $TEST_WEB;
}
EOF

tmp=$(mktemp)
sed -E \
  -e "s#proxy_pass([[:space:]]+)http://127\.0\.0\.1:$PROD_PORT;#proxy_pass\1http://\$mokaco_api_upstream;#" \
  -e "s#^([[:space:]]*)root([[:space:]]+)$PROD_WEB;#\1root\2\$mokaco_webroot;#" \
  "$SITE" \
| awk '
  /^[[:space:]]*location[[:space:]]+~[[:space:]]+\^\/\(api\|hubs/ {
    ind = $0; sub(/[^[:space:]].*$/, "", ind)
    print ind "# The login page'"'"'s Test environment switch (deploy/test-env/enable-env-switch.sh)."
    print ind "location = /env/test {"
    print ind "    add_header Set-Cookie \"mokaco_env=test; Path=/; Max-Age=31536000; SameSite=Lax\" always;"
    print ind "    add_header Cache-Control \"no-store\" always;"
    print ind "    return 302 /login;"
    print ind "}"
    print ind "location = /env/prod {"
    print ind "    add_header Set-Cookie \"mokaco_env=; Path=/; Max-Age=0; SameSite=Lax\" always;"
    print ind "    add_header Cache-Control \"no-store\" always;"
    print ind "    return 302 /login;"
    print ind "}"
    print ""
  }
  { print }
' > "$tmp"
cat "$tmp" > "$SITE"
rm -f "$tmp"

if ! nginx -t; then
  restore
  die "nginx -t failed with the switch; the site is back as it was."
fi
systemctl reload nginx

echo "Switch on. What changed in $SITE:"
diff "$SAVED" "$SITE" || true
echo "Undo at any time: sudo $0 --undo"
