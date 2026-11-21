#!/usr/bin/env bash
#
# deploy/fetch-code.sh — download the code of both repositories from GitHub onto the VM (no laptop needed).
# Run ON THE VM:
#
#   bash ~/src-test/MokaCo.HRMS/deploy/fetch-code.sh test     # branch dev  -> ~/src-test   (then deploy-test.sh)
#   bash ~/src-test/MokaCo.HRMS/deploy/fetch-code.sh prod     # branch main -> ~/src        (then update-prod.sh)
#   bash ~/src-test/MokaCo.HRMS/deploy/fetch-code.sh token    # save the GitHub token (asked hidden; needed once the repositories are private)
#   bash ~/src-test/MokaCo.HRMS/deploy/fetch-code.sh check    # says whether GitHub answers for both repositories; changes nothing
#
# It does what sync-test.sh / sync-prod.sh do from a laptop: each repository's folder is replaced by the branch's
# latest commit (the previous copy is kept beside it as <name>.old), and .deployed-from says which commit it is.
# Nothing is built, installed or restarted here.
#
# PRIVATE REPOSITORIES. GitHub then answers only with a token. Make one on github.com (Settings > Developer
# settings > Personal access tokens > Fine-grained tokens): only the two repositories, permission
# "Contents: Read-only", nothing else. Save it here with the "token" command: it is typed at a hidden prompt and
# kept in ~/.config/mokaco/github-token, readable by this account only. Never type it on a command line, in a
# chat or in a file of the repositories. It can only READ these two repositories; when it expires, make a new
# one and run "token" again.
#
set -euo pipefail

OWNER="${MOKACO_GITHUB_OWNER:-bfa-14}"
REPOS=(MokaCo.HRMS mokaco-web-mantine)
TOKEN_FILE="${MOKACO_GITHUB_TOKEN_FILE:-$HOME/.config/mokaco/github-token}"
API=https://api.github.com

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# curl against GitHub. The token goes in through a config read from a pipe, never on the command line
# (a command line can be read by everybody on the machine).
gh_curl() {
  if [[ -s "$TOKEN_FILE" ]]; then
    curl -fsSL -K <(printf 'header = "Authorization: Bearer %s"\n' "$(tr -d ' \r\n' < "$TOKEN_FILE")") "$@"
  else
    curl -fsSL "$@"
  fi
}

why_failed() {
  if [[ -s "$TOKEN_FILE" ]]; then
    echo "GitHub refused or did not answer. If the token has expired or does not cover this repository, make a new one and run: bash $0 token"
  else
    echo "GitHub refused or did not answer. If the repositories are private, save a token first: bash $0 token"
  fi
}

save_token() {
  local token
  read -rsp "GitHub token (hidden; paste it and press Enter): " token; echo
  token=$(printf '%s' "$token" | tr -d ' \r\n')
  [[ -n "$token" ]] || die "nothing was typed; the token was not changed."
  ( umask 077; mkdir -p "$(dirname "$TOKEN_FILE")"; printf '%s\n' "$token" > "$TOKEN_FILE" )
  chmod 600 "$TOKEN_FILE"
  log "saved in $TOKEN_FILE (readable by this account only)"
  check
}

check() {
  local repo sha bad=0
  [[ -s "$TOKEN_FILE" ]] && echo "    token: saved" || echo "    token: none (works only while the repositories are public)"
  for repo in "${REPOS[@]}"; do
    if sha=$(gh_curl -H "Accept: application/vnd.github.sha" "$API/repos/$OWNER/$repo/commits/main" 2>/dev/null) && [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "    $repo: ok (main is ${sha:0:8})"
    else
      echo "    $repo: NO ANSWER"; bad=1
    fi
  done
  [[ $bad -eq 0 ]] || die "$(why_failed)"
}

fetch() {
  local branch="$1" dest="$2" repo sha marker
  mkdir -p "$dest"
  for repo in "${REPOS[@]}"; do
    sha=$(gh_curl -H "Accept: application/vnd.github.sha" "$API/repos/$OWNER/$repo/commits/$branch") \
      || die "$repo: could not read the latest commit of $branch. $(why_failed)"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "$repo: GitHub's answer for $branch is not a commit."

    log "$repo: downloading $branch (${sha:0:8})"
    rm -rf "$dest/$repo.new"
    mkdir "$dest/$repo.new"
    # The exact commit just read, so the folder and .deployed-from always agree.
    gh_curl "$API/repos/$OWNER/$repo/tarball/$sha" | tar -xz -C "$dest/$repo.new" --strip-components=1 \
      || { rm -rf "$dest/$repo.new"; die "$repo: the download failed; $dest/$repo was not touched. $(why_failed)"; }

    case "$repo" in
      MokaCo.HRMS) marker=MokaCo.HRMS.slnx ;;
      *)           marker=package.json ;;
    esac
    [[ -f "$dest/$repo.new/$marker" ]] \
      || { rm -rf "$dest/$repo.new"; die "$repo: the download is incomplete ($marker missing); $dest/$repo was not touched."; }

    echo "origin/$branch $sha" > "$dest/$repo.new/.deployed-from"
    rm -rf "$dest/$repo.old"
    [[ ! -e "$dest/$repo" ]] || mv "$dest/$repo" "$dest/$repo.old"
    mv "$dest/$repo.new" "$dest/$repo"
  done
  log "done: $dest holds origin/$branch of both repositories"
}

main() {
  case "${1:-}" in
    test)  fetch dev "$HOME/src-test"
           echo "    next: apply any new docs/NN_*.sql with ~/test-env/apply-sql-test.sh, then: bash ~/test-env/deploy-test.sh" ;;
    prod)  fetch main "$HOME/src"
           echo "    next: bash ~/src/MokaCo.HRMS/deploy/update-prod.sh --web" ;;
    token) save_token ;;
    check) check ;;
    *)     echo "usage: bash $0 test | prod | token | check" >&2; exit 2 ;;
  esac
}

# The whole file is read before anything runs: "test" replaces the very folder this script is in.
main "$@"; exit
