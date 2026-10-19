#!/usr/bin/env bash
# deploy/enable-google-gate.sh — the nginx part of the Google sign-in gate, on the VM
# (docs/GOOGLE_SIGNIN_GATE.md §5).
#
# nginx asks the API (GET /api/gate/check) before each request to the HRMS site. The API answers 204
# (go on) or 401 (not signed in with Google). On a 401 a page gets the gate page in its place
# (/gate/index.html, status 200, no-store) and /api or /hubs get 401 with "X-Mokaco-Gate: required".
# While the switch in Settings -> Google sign-in is off, the API answers 204 to everything and the site
# works as before. The API always lets /health, /gate/, /api/gate/, /iclock and /api/attendance/punch
# through. The bare IP (terminals), mokanco.com.lb and the booking calls are other blocks: not touched.
#
#   sudo bash deploy/enable-google-gate.sh --test     # only browsers on the login page's Test switch; the test API (5079) decides
#   sudo bash deploy/enable-google-gate.sh --all      # everyone; production's API (5078) decides; test.hrms... too when enabled
#   sudo bash deploy/enable-google-gate.sh --off      # take the nginx part away
#   bash deploy/enable-google-gate.sh --status        # which mode is on
#
# Writes /etc/nginx/conf.d/mokaco-gate.conf (which API is asked) and /etc/nginx/snippets/mokaco-gate.conf
# (the gate), and adds one line tagged "# mokaco-gate" to the HTTPS block of sites-available/mokaco
# (with --all also to mokaco-test's, when that site is enabled). Nothing else in the sites changes;
# --off removes exactly those (and the line from mokaco.before-env-switch, which
# enable-env-switch.sh --undo would put back). A second run changes nothing; --test <-> --all
# rewrites the maps. It changes nothing while the API that decides cannot read its settings
# (docs/97_google_signin_gate.sql not applied): that API keeps the gate closed for everyone.
# If nginx -t or the checks after the reload fail, everything is put back before it exits.
#
# Locked out (Google down, a wrong client ID)? deploy/google-gate-emergency-off.sh turns the switch off
# in SQL; the site opens again within 20 seconds. --off here takes nginx out of it as well.
#
# For a scratch nginx (tests): NGINX_DIR (default /etc/nginx) and GATE_TEST_MODE=1 (no sudo check;
# nginx -p NGINX_DIR -c NGINX_DIR/nginx.conf for -t and reload, no systemctl).
set -euo pipefail

NGINX_DIR="${NGINX_DIR:-/etc/nginx}"
SITE=$NGINX_DIR/sites-available/mokaco
SAVED=$SITE.before-env-switch                # enable-env-switch.sh's copy; --undo puts it back
TEST_SITE=$NGINX_DIR/sites-available/mokaco-test
MAPS=$NGINX_DIR/conf.d/mokaco-gate.conf
SNIPPET=$NGINX_DIR/snippets/mokaco-gate.conf
LINE="include $SNIPPET;   # mokaco-gate"
PROD_PORT=5078
TEST_PORT=5079
HOST=hrms.mokanco.com.lb
TEST_HOST=test.hrms.mokanco.com.lb

die()  { echo "enable-google-gate: $*" >&2; exit 1; }
warn() { echo "enable-google-gate: warning: $*" >&2; }

if [ "${GATE_TEST_MODE:-0}" = 1 ]; then
  ngx()    { nginx -p "$NGINX_DIR/" -c "$NGINX_DIR/nginx.conf" "$@"; }
  reload() { ngx -s reload; }
else
  ngx()    { nginx "$@"; }
  reload() { systemctl reload nginx; }
fi

same_file() { [ "$(readlink -f "$1")" = "$(readlink -f "$2")" ]; }
enabled()   { [ -e "$NGINX_DIR/sites-enabled/$1" ] || [ -L "$NGINX_DIR/sites-enabled/$1" ]; }

# What nginx on this box answers: code HOST PATH [curl options] -> "200", or "200 gate" when the
# answer carries X-Mokaco-Gate (the gate answered, not the app or the API).
code() {
  local host=$1 path=$2 h; shift 2
  h=$(curl --noproxy '*' -sk -o /dev/null -D - -m 10 --resolve "$host:443:127.0.0.1" "$@" \
        "https://$host$path" 2>/dev/null || true)
  printf '%s' "$(awk 'NR == 1 { print $2 }' <<< "$h")"
  if grep -qi '^x-mokaco-gate:' <<< "$h"; then printf ' gate'; fi
  echo
}

# The API's own answer to the gate's question for an exempt path: 204 = it has the gate endpoint.
api_check() {
  curl --noproxy '*' -s -o /dev/null -m 5 -w '%{http_code}' -H 'X-Original-URI: /health' \
    "http://127.0.0.1:$1/api/gate/check" 2>/dev/null || true
}

# Settings -> Google sign-in as an API reports it (GET /api/gate/config; curl options, URL last):
# on, off, unread or "?" (no answer). unread = on with no client ID, which is what the API serves
# until it has read its settings (docs/97 not applied, SQL down): it then keeps the gate closed for
# everyone. Settings never saves "on" without a client ID, so a database that was read never says it.
gate_state() {
  curl --noproxy '*' -sfk -m 10 "$@" 2>/dev/null | python3 -c '
import json, sys
c = json.load(sys.stdin)
on, cid = c["required"], c.get("clientId")
assert isinstance(on, bool)
print("on" if on and isinstance(cid, str) and cid.strip() else "unread" if on else "off")' 2>/dev/null || echo "?"
}
api_state() { gate_state "http://127.0.0.1:$1/api/gate/config"; }
say_state() {
  case "$1" in
    on|off) echo "$1" ;;
    unread) echo "CANNOT READ ITS SETTINGS" ;;
    *)      echo "no answer" ;;
  esac
}

# Site edits: brace-aware, so the line lands in the HTTPS server block and nowhere else.
#   gate_py strip SITE OUT                       SITE without the tagged lines
#   gate_py plan prod|test SITE OUT want CONF_D  SITE with exactly one tagged line, before the API
#                                                location of its HTTPS block; prints that block's web
#                                                root(s) (want: test = the Test switch's, all = every one)
gate_py() {
  python3 - "$LINE" "$@" <<'PY'
import os, re, sys

TAG = re.compile(r'^[ \t]*include[ \t]+\S*mokaco-gate\.conf;[ \t]*# mokaco-gate[ \t]*$')
ANCHORS = {
    # sites-available/mokaco: the API location (enable-env-switch.sh anchors on it too)
    'prod': re.compile(r'^\s*location\s+~\s+\^/\(api\|hubs'),
    # sites-available/mokaco-test (test-env/nginx-mokaco-test.conf): its /api/ location
    'test': re.compile(r'^\s*location\s+(\^~\s+)?/api/\s*\{'),
}

def fail(msg):
    sys.stderr.write('enable-google-gate: %s Nothing changed.\n' % msg)
    sys.exit(3)

def read(path):
    with open(path, 'rb') as f:
        return f.read().decode('utf-8', 'surrogateescape').split('\n')

def write(path, lines):
    with open(path, 'wb') as f:
        f.write('\n'.join(lines).encode('utf-8', 'surrogateescape'))

def scan(lines, path):
    """The brace depth at the start of each line, and the top-level server blocks with their
    listen arguments, root and line range. Comments and quoted strings are skipped as nginx does."""
    depth, starts, blocks, cur = 0, [], [], None
    words, word, quote = [], '', None
    for n, line in enumerate(lines):
        starts.append(depth)
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
            elif c in '{};':
                if word:
                    words.append(word); word = ''
                if c == '{':
                    if depth == 0 and words[:1] == ['server']:
                        cur = {'first': n, 'listen': [], 'root': None}
                    depth += 1
                elif c == '}':
                    depth -= 1
                    if depth < 0:
                        fail('%s: a "}" too many on line %d.' % (path, n + 1))
                    if depth == 0 and cur is not None:
                        cur['last'] = n; blocks.append(cur); cur = None
                elif cur is not None and depth == 1 and words:
                    if words[0] == 'listen':
                        cur['listen'].append(words[1:])
                    elif words[0] == 'root' and len(words) > 1:
                        cur['root'] = words[1]
                words = []
                space = True; i += 1; continue
            else:
                word += c
            space = False
            i += 1
        if quote:
            word += '\n'
        elif word:
            words.append(word); word = ''
    if depth != 0:
        fail('%s: the braces do not balance.' % path)
    return starts, blocks

def https(block):
    return any('ssl' in a or (a and re.fullmatch(r'(\S*:)?443', a[0])) for a in block['listen'])

def webroots(root, want, conf_d, path):
    if root is None:
        fail('%s: no root in its HTTPS block.' % path)
    if not root.startswith('$'):
        return [root]
    for fn in sorted(os.listdir(conf_d)):
        if not fn.endswith('.conf') or fn == 'mokaco-gate.conf':
            continue
        with open(os.path.join(conf_d, fn), encoding='utf-8', errors='replace') as f:
            m = re.search(r'\bmap\s+\S+\s+\$' + re.escape(root[1:]) + r'\s*\{([^}]*)\}', f.read())
        if m:
            values = {k.strip('"\''): v.strip('"\'')
                      for k, v in re.findall(r'^\s*(\S+)\s+([^;\s]+)\s*;', m.group(1), re.M)}
            if want == 'test':
                return [values.get('test', values.get('default'))]
            return sorted(set(values.values()))
    fail('%s: root %s, but no map for it in %s.' % (path, root, conf_d))

line, cmd = sys.argv[1], sys.argv[2]
if cmd == 'strip':
    src, out = sys.argv[3:5]
    write(out, [l for l in read(src) if not TAG.match(l)])
    sys.exit(0)

kind, src, out, want, conf_d = sys.argv[3:8]
lines = [l for l in read(src) if not TAG.match(l)]
if any('mokaco-gate.conf' in l and not l.lstrip().startswith('#') for l in lines):
    fail('%s includes mokaco-gate.conf on a line without the "# mokaco-gate" tag: remove it by hand.' % src)
starts, blocks = scan(lines, src)
anchor = ANCHORS[kind]
found = [(b, [n for n in range(b['first'], b['last'] + 1) if starts[n] == 1 and anchor.match(lines[n])])
         for b in blocks]
found = [(b, ns) for b, ns in found if ns]
if not found:
    fail('%s: no API location (%s) in a server block.' % (src, anchor.pattern))
secure = [(b, ns) for b, ns in found if https(b)]
if not secure:
    fail('%s: the API location is not in an HTTPS (443) block. Turn HTTPS on first (deploy/enable-tls.sh).' % src)
if len(secure) > 1:
    fail('%s: %d HTTPS blocks have the API location; this script expects one.' % (src, len(secure)))
block, ns = secure[0]
indent = re.match(r'[ \t]*', lines[ns[0]]).group(0)
lines.insert(ns[0], indent + line)
write(out, lines)
for r in webroots(block['root'], want, conf_d, src):
    print(r)
PY
}

write_maps() {
  echo "# Written by deploy/enable-google-gate.sh (MokaCo.HRMS), mode $1. Off: enable-google-gate.sh --off"
  if [ "$1" = --test ]; then
    cat <<EOF
# --test: only requests carrying the login page's Test switch (cookie mokaco_env=test) go through the
# gate, and the test API ($TEST_PORT) decides. Everyone else passes as before.
EOF
  else
    cat <<EOF
# --all: every request to the HRMS site (and test.hrms..., when enabled) goes through the gate, and
# production's API ($PROD_PORT) decides, Test switch or not: production's Settings are the front door.
EOF
  fi
  cat <<'EOF'
# Keyed on the cookie only: the check is a subrequest, and a map on $uri (like $mokaco_api_upstream)
# would be worked out for its URI, /__mokaco_gate, not the request's.
#   $mokaco_gate_upstream  the API asked before each request ("" = nobody: the request goes on)
#   $mokaco_gate_api       the API behind /api/gate/ (the gate page's own calls)
EOF
  if [ "$1" = --test ]; then
    cat <<EOF
map \$cookie_mokaco_env \$mokaco_gate_upstream {
    default  "";
    test     127.0.0.1:$TEST_PORT;
}
map \$cookie_mokaco_env \$mokaco_gate_api {
    default  127.0.0.1:$PROD_PORT;
    test     127.0.0.1:$TEST_PORT;
}
EOF
  else
    cat <<EOF
map \$cookie_mokaco_env \$mokaco_gate_upstream {
    default  127.0.0.1:$PROD_PORT;
}
map \$cookie_mokaco_env \$mokaco_gate_api {
    default  127.0.0.1:$PROD_PORT;
}
EOF
  fi
  cat <<'EOF'
# A request the gate stops: /api and /hubs get a 401, a page gets the gate page.
map $uri $mokaco_gate_api_path {
    volatile;
    default               0;
    "~^/(api|hubs)(/|$)"  1;
}
# The app's index.html (where every page route ends) and the gate's files: "Cache-Control: no-cache",
# so the browser asks nginx on every visit. A copy it reused without asking would skip the gate and
# show the HRMS login page. "" adds no header (/assets and the API keep theirs).
map $uri $mokaco_gate_revalidate {
    volatile;
    default        "";
    /index.html    no-cache;
    "~^/gate/"     no-cache;
}
EOF
}

write_snippet() {
  cat <<'EOF'
# Written by deploy/enable-google-gate.sh (MokaCo.HRMS). Off: enable-google-gate.sh --off
# The Google sign-in gate (docs/GOOGLE_SIGNIN_GATE.md), included at server level in the HRMS HTTPS
# block. Each request first asks the API whether it may go on (204) or not (401). The API decides
# which paths always pass; conf.d/mokaco-gate.conf decides which API is asked.
auth_request /__mokaco_gate;
error_page 401 = @mokaco_gate;

# The app's pages and the gate's files are asked for again on every visit (the map in
# conf.d/mokaco-gate.conf picks them). Reaches every location without an add_header of its own.
add_header Cache-Control $mokaco_gate_revalidate;

# The question. Never $mokaco_api_upstream here: it would be worked out for this location's URI.
location = /__mokaco_gate {
    internal;
    if ($mokaco_gate_upstream = "") {
        return 204;
    }
    proxy_pass              http://$mokaco_gate_upstream/api/gate/check;
    proxy_pass_request_body off;
    proxy_set_header        Content-Length    "";
    proxy_set_header        Host              $host;
    proxy_set_header        X-Original-URI    $request_uri;
    proxy_set_header        X-Forwarded-For   $mokaco_client_ip;
    proxy_set_header        X-Forwarded-Proto $mokaco_proto;
}

# The gate page's own calls (config, Google sign-in, sign-out) always pass, to the API that decides.
# X-Forwarded-For is $mokaco_client_ip like everywhere else: since QA3 SEC-4 it believes a
# CF-Connecting-IP header only from a Cloudflare edge (conf.d/mokaco-client-ip.conf, deploy-api.sh),
# so a caller cannot pick the address that the sign-in limit (10 a minute) counts and the sign-in log
# shows, and behind Cloudflare the limit counts visitors, not Cloudflare's edges.
location ^~ /api/gate/ {
    auth_request off;
    proxy_pass         http://$mokaco_gate_api;
    proxy_http_version 1.1;
    proxy_set_header   Host              $host;
    proxy_set_header   X-Real-IP         $remote_addr;
    proxy_set_header   X-Forwarded-For   $mokaco_client_ip;
    proxy_set_header   X-Forwarded-Proto $mokaco_proto;
}

# The gate page's files, and only those: a missing one is a 404, not the app's index.html.
location ^~ /gate/ {
    try_files $uri $uri/ =404;
}

# Stopped: a fetch gets a 401 it can recognise (never a redirect into HTML); a page gets the gate
# page in its place with 200 (deploy-web.sh needs / = 200, deploy-site.sh must never see a 301).
# This location sets headers of its own, so it does not inherit the site's: HSTS is repeated here
# (the snippet only ever sits in an HTTPS block; same value as enable-tls.sh puts on the site).
location @mokaco_gate {
    auth_request off;
    add_header Cache-Control "no-store" always;
    add_header X-Mokaco-Gate "required" always;
    add_header Strict-Transport-Security "max-age=31536000" always;
    if ($mokaco_gate_api_path) {
        return 401;
    }
    try_files /gate/index.html =404;
}
EOF
}

status() {
  local mode=off s state prod tst db who start
  [ -f "$MAPS" ] && mode=$(sed -n 's/.*, mode \(--[a-z]*\)\..*/\1/p' "$MAPS" | head -1)
  case "$mode" in
    --test) echo "Google sign-in gate in nginx: --test. Only browsers on the login page's Test switch go through it; the test API ($TEST_PORT) decides." ;;
    --all)  echo "Google sign-in gate in nginx: --all. Every request goes through it; production's API ($PROD_PORT) decides." ;;
    off)    echo "Google sign-in gate in nginx: off." ;;
    *)      echo "Google sign-in gate in nginx: $MAPS is not one this script wrote." ;;
  esac
  for s in mokaco mokaco-test; do
    [ -f "$NGINX_DIR/sites-available/$s" ] || continue
    if grep -q '# mokaco-gate$' "$NGINX_DIR/sites-available/$s"; then state="gate line in it"; else state="no gate line"; fi
    enabled "$s" || state="$state (site not enabled)"
    printf '  %-28s %s\n' "sites-available/$s" "$state"
  done
  for s in conf.d/mokaco-gate.conf snippets/mokaco-gate.conf; do
    if [ -f "$NGINX_DIR/$s" ]; then state=present; else state=absent; fi
    printf '  %-28s %s\n' "$s" "$state"
  done
  if [ "$mode" != off ] && ! grep -q '# mokaco-gate$' "$SITE" 2>/dev/null; then
    echo "  The line is missing from $SITE (enable-env-switch.sh --undo puts the whole site back):"
    echo "  run this script again with $mode, or --off."
  fi
  if [ "$mode" = --all ] && enabled mokaco-test && ! grep -q '# mokaco-gate$' "$TEST_SITE" 2>/dev/null; then
    echo "  Warning: $TEST_HOST is NOT behind the gate (mokaco-test was enabled or rewritten"
    echo "  after --all): run this script again with --all."
  fi
  prod=$(api_state $PROD_PORT) tst=$(api_state $TEST_PORT)
  echo "  Settings -> Google sign-in: production $(say_state "$prod"), test $(say_state "$tst")"
  case "$mode" in
    --test) s=$tst db=MokaCo_HRMS_Test who="Browsers on the Test switch get"
            start="sudo systemctl start mokaco-api-test" ;;
    --all)  s=$prod db=MokaCo_HRMS who="Everyone gets"
            start="sudo systemctl start mokaco-api" ;;
    *)      s=on ;;
  esac
  case "$s" in
    unread) echo "  Warning: the API that decides cannot read its settings, so it keeps the gate closed."
            echo "  $who the gate page and cannot sign in. Apply docs/97_google_signin_gate.sql to $db,"
            echo "  or run this script with --off." ;;
    \?)     echo "  Warning: the API that decides does not answer. $who a 500 page from nginx."
            echo "  Start it ($start), or run this script with --off." ;;
  esac
}

mode=${1:-}
case "$mode" in
  --test|--all|--off) ;;
  --status) status; exit 0 ;;
  *) echo "usage: sudo bash $0 --test | --all | --off | --status" >&2; exit 2 ;;
esac

[ "${GATE_TEST_MODE:-0}" = 1 ] || [ "$(id -u)" -eq 0 ] || die "run it with sudo."
[ -f "$SITE" ] || die "$SITE not found. Nothing changed."

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# The wanted state, as "<file in $tmp, or - for none>|<target>".
plan=()
if [ "$mode" = --off ]; then
  gate_py strip "$SITE" "$tmp/mokaco"
  plan+=("$tmp/mokaco|$SITE")
  if [ -f "$TEST_SITE" ]; then
    gate_py strip "$TEST_SITE" "$tmp/mokaco-test"
    plan+=("$tmp/mokaco-test|$TEST_SITE")
  fi
  # A copy taken while the gate was on still has the line: --undo would put back an include of a
  # file deleted here, and nginx would not start again.
  if [ -f "$SAVED" ]; then
    gate_py strip "$SAVED" "$tmp/saved"
    plan+=("$tmp/saved|$SAVED")
  fi
  plan+=("-|$MAPS" "-|$SNIPPET")
else
  # --- preconditions: nothing changes until all of them hold ---
  v=$(ngx -V 2>&1) || die "nginx -V failed. Nothing changed."
  case "$v" in *http_auth_request_module*) ;; *) die "this nginx has no http_auth_request_module. Nothing changed." ;; esac
  enabled mokaco && same_file "$NGINX_DIR/sites-enabled/mokaco" "$SITE" \
    || die "sites-enabled/mokaco is not a link to $SITE. Nothing changed."
  if [ "$mode" = --test ]; then
    grep -q 'mokaco_api_upstream' "$SITE" \
      || die "--test needs the login page's Test switch (sudo deploy/test-env/enable-env-switch.sh). Nothing changed."
    want=test port=$TEST_PORT apply="docs/97_google_signin_gate.sql to MokaCo_HRMS_Test (test-env/apply-sql-test.sh)"
  else
    want=all port=$PROD_PORT apply="docs/97_google_signin_gate.sql to MokaCo_HRMS"
  fi

  roots=$(gate_py plan prod "$SITE" "$tmp/mokaco" "$want" "$NGINX_DIR/conf.d") || exit 1
  plan+=("$tmp/mokaco|$SITE")
  if [ "$mode" = --all ] && enabled mokaco-test; then
    same_file "$NGINX_DIR/sites-enabled/mokaco-test" "$TEST_SITE" \
      || die "sites-enabled/mokaco-test is not a link to $TEST_SITE. Nothing changed."
    roots="$roots
$(gate_py plan test "$TEST_SITE" "$tmp/mokaco-test" all "$NGINX_DIR/conf.d")" || exit 1
    plan+=("$tmp/mokaco-test|$TEST_SITE")
  elif [ -f "$TEST_SITE" ]; then
    # --test, or the test site not enabled: no gate line there (one left by an earlier --all goes)
    gate_py strip "$TEST_SITE" "$tmp/mokaco-test"
    plan+=("$tmp/mokaco-test|$TEST_SITE")
  fi

  while IFS= read -r r; do
    [ -z "$r" ] || [ -f "$r/gate/index.html" ] \
      || die "$r/gate/index.html missing: deploy the web app with the gate page first. Nothing changed."
  done <<< "$roots"

  c=$(api_check "$port")
  [ "$c" = 204 ] || die "the API on 127.0.0.1:$port answers ${c:-nothing} to /api/gate/check (204 needed):
     deploy the API with the gate first (docs/GOOGLE_SIGNIN_GATE.md §6). Nothing changed."
  # The check above passes on an exempt path before any setting is read, so ask what it has read.
  case "$(api_state "$port")" in
    on|off) ;;
    unread) die "the API on 127.0.0.1:$port cannot read its Google sign-in settings: it reports the gate on
     with no client ID, so it would keep the gate closed. Apply $apply first,
     and check that SQL Server is running. Nothing changed." ;;
    *)      die "the API on 127.0.0.1:$port does not answer /api/gate/config. Nothing changed." ;;
  esac

  if enabled mokaco-api; then
    warn "sites-enabled/mokaco-api exists: api.mokanco.com.lb serves the whole API WITHOUT the gate.
     Disable it unless something still needs it (the website uses mokanco.com.lb/api/public/...)."
  fi

  write_maps "$mode" > "$tmp/maps"
  write_snippet > "$tmp/snippet"
  plan+=("$tmp/maps|$MAPS" "$tmp/snippet|$SNIPPET")
fi

# --- what differs ---
changes=()
for p in "${plan[@]}"; do
  new=${p%%|*} target=${p#*|}
  if [ "$new" = - ]; then
    if [ -e "$target" ]; then changes+=("$p"); fi
  elif ! cmp -s "$new" "$target"; then
    changes+=("$p")
  fi
done
if [ ${#changes[@]} -eq 0 ]; then
  if [ "$mode" = --off ]; then echo "Already off: nothing changed."; else echo "Already on ($mode): nothing changed."; fi
  status
  exit 0
fi

# --- backup, write, nginx -t, reload ---
mkdir "$tmp/bak"
i=0
for p in "${changes[@]}"; do
  target=${p#*|}
  if [ -e "$target" ]; then cp -p "$target" "$tmp/bak/$i"; fi
  i=$((i + 1))
done
restore() {
  local i=0 p target
  for p in "${changes[@]}"; do
    target=${p#*|}
    if [ -e "$tmp/bak/$i" ]; then cp -p "$tmp/bak/$i" "$target"; else rm -f "$target"; fi
    i=$((i + 1))
  done
}

for p in "${changes[@]}"; do
  new=${p%%|*} target=${p#*|}
  if [ "$new" = - ]; then
    rm -f "$target"
  elif [ -e "$target" ]; then
    cat "$new" > "$target"                  # keeps the file's owner, mode and links
  else
    mkdir -p "$(dirname "$target")"
    install -m 644 "$new" "$target"
  fi
done

if ! ngx -t; then
  restore
  die "nginx -t failed with the change; everything is back as it was."
fi
if ! reload; then
  restore
  reload || true
  die "nginx did not reload; everything is back as it was."
fi
sleep 2

# --- checks through nginx ---
failed=0
expect() {   # expect WANT HOST PATH [curl options]
  local want=$1 host=$2 path=$3 got ok; shift 3
  got=$(code "$host" "$path" "$@")
  ok=1
  case "$want" in
    *\*) [ "${got%% *}" = "${want%\*}" ] || ok=0 ;;   # 200* = 200 from the app or the gate page
    *)   [ "$got" = "$want" ] || ok=0 ;;               # 200 = 200, not from the gate
  esac
  report "$ok" "https://$host$path${1:+ $*}" "$got" "$want"
}
report() {   # report OK LABEL GOT WANT
  if [ "$1" = 1 ]; then
    printf '  ok    %-44s %s\n' "$2" "$3"
  else
    printf '  FAIL  %-44s %s (expected %s)\n' "$2" "${3:-no answer}" "$4"
    failed=1
  fi
}
expect_read() {   # expect_read HOST [curl options]: the API behind /api/gate/ has read its settings
  local host=$1 got ok; shift
  got=$(gate_state --resolve "$host:443:127.0.0.1" "$@" "https://$host/api/gate/config")
  case "$got" in on|off) ok=1 ;; *) ok=0 ;; esac
  report "$ok" "https://$host/api/gate/config${1:+ $*}" "switch $(say_state "$got")" "switch on or off"
}
echo "Checks:"
expect 200  $HOST /health
if [ "$mode" = --all ]; then
  expect '200*' $HOST /
else
  expect 200  $HOST /                 # --test: nobody without the Test cookie is asked
fi
[ "$mode" = --off ] || expect 404 $HOST /__mokaco_gate
if [ "$mode" = --test ]; then
  expect 200  $HOST /health -b mokaco_env=test
  expect '200*' $HOST / -b mokaco_env=test
  expect 200  $HOST /gate/ -b mokaco_env=test
  expect_read $HOST -b mokaco_env=test
elif [ "$mode" = --all ]; then
  expect 200  $HOST /gate/
  expect_read $HOST
  if [ -f "$tmp/mokaco-test" ] && grep -q '# mokaco-gate$' "$tmp/mokaco-test"; then
    expect '200*' $TEST_HOST /
    expect 404  $TEST_HOST /__mokaco_gate
    expect 200  $TEST_HOST /gate/
  fi
fi

if [ "$failed" = 1 ]; then
  if [ "$mode" = --off ]; then
    warn "the gate is off, but the checks above failed: look at sudo nginx -T and the API."
  else
    restore
    ngx -t && reload && sleep 2 || true
    die "the checks above failed; everything is back as it was."
  fi
fi

echo
echo "What changed:"
i=0
for p in "${changes[@]}"; do
  new=${p%%|*} target=${p#*|}
  if [ "$new" = - ]; then echo "  removed $target"
  elif [ ! -e "$tmp/bak/$i" ]; then echo "  new     $target"
  else echo "  $target:"; diff "$tmp/bak/$i" "$target" | sed 's/^/    /' || true
  fi
  i=$((i + 1))
done
echo
status
[ "$mode" = --off ] || echo "Off again at any time: sudo bash $0 --off"
