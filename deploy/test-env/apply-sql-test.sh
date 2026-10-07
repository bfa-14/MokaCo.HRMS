#!/usr/bin/env bash
# deploy/test-env/apply-sql-test.sh — apply docs/*.sql scripts to MokaCo_HRMS_Test, never to production.
#
# 29 scripts in docs/ carry "USE MokaCo_HRMS;", which beats sqlcmd's -d: run as they are against the
# test database they switch to PRODUCTION and change it there. This removes that line from a
# temporary copy, refuses a script that still names another database, and runs the copy with
# -d MokaCo_HRMS_Test behind a first batch that stops unless the connection really is in the test DB.
#
#   deploy/test-env/apply-sql-test.sh docs/90_currency_delete_unused.sql [more.sql ...]
#
# SQL connection: SQLCMDSERVER / SQLCMDUSER / SQLCMDPASSWORD from the environment, as in tests/qa
# (defaults 127.0.0.1 and sa); the password is asked for once when it is not set.
set -euo pipefail

TEST_DB=MokaCo_HRMS_Test
SQLCMD="${SQLCMD:-/opt/mssql-tools18/bin/sqlcmd}"

die() { echo "apply-sql-test: $*" >&2; exit 1; }

[ $# -ge 1 ] || { echo "usage: $0 script.sql [script.sql ...]" >&2; exit 2; }
for f in "$@"; do [ -f "$f" ] || die "$f: no such file. Nothing applied."; done

export SQLCMDSERVER="${SQLCMDSERVER:-127.0.0.1}" SQLCMDUSER="${SQLCMDUSER:-sa}"
if [ -z "${SQLCMDPASSWORD:-}" ]; then
  read -rsp "SQL password for $SQLCMDUSER: " SQLCMDPASSWORD; echo
fi
export SQLCMDPASSWORD

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

# Every copy is made and checked before the first one runs: one refused file stops them all.
n=0
for f in "$@"; do
  n=$((n + 1))
  {
    printf ':on error exit\n'
    printf "IF DB_NAME() <> N'%s' THROW 50000, N'apply-sql-test.sh: not connected to %s. Nothing applied.', 1;\nGO\n" \
      "$TEST_DB" "$TEST_DB"
    sed -E '/^[[:space:]]*USE[[:space:]]+\[?MokaCo_HRMS\]?[[:space:]]*;?[[:space:]]*$/Id' "$f"
  } > "$tmp/$n.sql"

  # Whatever is left that could leave the test database: another USE, a three-part name into
  # production, or a sqlcmd command that opens a new connection or pulls in another file.
  if grep -nEi '^[[:space:]]*USE[[:space:]]|\[?MokaCo_HRMS\]?\.\[?[A-Za-z_]|^[[:space:]]*:(connect|r)[[:space:]]' "$tmp/$n.sql" >&2; then
    die "$f still points outside $TEST_DB (lines above, numbered in the copy). Nothing applied."
  fi
done

n=0
for f in "$@"; do
  n=$((n + 1))
  echo "== $f -> $TEST_DB"
  "$SQLCMD" -S "$SQLCMDSERVER" -U "$SQLCMDUSER" -C -I -b -d "$TEST_DB" -i "$tmp/$n.sql"
done
