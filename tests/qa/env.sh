# tests/qa/env.sh — sourced by run.sh and culture-and-pull.sh. NO CREDENTIAL LIVES IN THE REPO:
# SQLCMDSERVER / SQLCMDUSER / SQLCMDPASSWORD come from the environment, or from tests/qa/.env
# (gitignored; copy .env.example). A value already in the environment wins over the file.
_qa_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_qa_dir/.env" ]; then
  while IFS='=' read -r _k _v || [ -n "$_k" ]; do
    case "$_k" in ''|\#*) continue ;; esac
    _v="${_v%$'\r'}"
    case "$_k" in SQLCMDSERVER|SQLCMDUSER|SQLCMDPASSWORD) [ -z "${!_k:-}" ] && export "$_k=$_v" ;; esac
  done < "$_qa_dir/.env"
fi
for _k in SQLCMDSERVER SQLCMDUSER SQLCMDPASSWORD; do
  if [ -z "${!_k:-}" ]; then
    echo "tests/qa: $_k is not set. Export it, or copy tests/qa/.env.example to tests/qa/.env and fill it in." >&2
    exit 2
  fi
done
export SQLCMDSERVER SQLCMDUSER SQLCMDPASSWORD
unset _qa_dir _k _v
