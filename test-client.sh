#!/usr/bin/env bash
#
# test-client.sh — exercise the Bookstride server the way the watch does,
# without needing a Garmin device or the simulator.
#
# It walks the same three flows SyncDelegate.mc / OauthView.mc use:
#   1. login    POST /auth            (form) -> 303 redirect to /success?token=...
#   2. library  GET  /v0/lib/<page>   (Bearer) -> { res:[...], more:bool }
#   3. download POST /v0/book/<isbn>/download        -> 202 { tracks:N }
#               GET  /v0/book/<isbn>/<track>/track.mp3 (per track, 429 = not ready yet)
#
# Usage:
#   ./test-client.sh login                 # print an access token
#   ./test-client.sh list                  # list every audiobook in the account
#   ./test-client.sh download <isbn> [dir] # download all tracks of a book
#   ./test-client.sh all <isbn> [dir]      # login + list + download in one go
#
# Config (env vars):
#   BASE_URL          server to hit          (default http://localhost:8000)
#   BOOKSTRIDE_USER   libro.fm email
#   BOOKSTRIDE_PASS   libro.fm password
#   BOOKSTRIDE_TOKEN  reuse a token instead of logging in again
#
# Missing credentials are prompted for interactively.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
BASE_URL="${BASE_URL%/}"   # strip trailing slash

die()  { echo "error: $*" >&2; exit 1; }
info() { echo ">> $*" >&2; }

urldecode() { python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read()),end="")'; }

# ---------------------------------------------------------------------------
# 1. login: POST /auth, follow the redirect, pull ?token= out of Location.
# ---------------------------------------------------------------------------
login() {
  local user="${BOOKSTRIDE_USER:-}" pass="${BOOKSTRIDE_PASS:-}"
  if [[ -z "$user" ]]; then read -r -p "libro.fm email: " user; fi
  if [[ -z "$pass" ]]; then read -r -s -p "libro.fm password: " pass; echo >&2; fi

  info "logging in as $user via $BASE_URL/auth"

  # Ask curl for the status and the redirect target directly, without following
  # it (-L off) and without dragging the response body through a pipe. Parsing
  # the raw Location header instead risked SIGPIPE killing the script under
  # pipefail; %{redirect_url} sidesteps that.
  local out status location
  out=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -X POST \
             --data-urlencode "username=$user" \
             --data-urlencode "password=$pass" \
             "$BASE_URL/auth") || die "could not reach $BASE_URL (is the server running?)"

  status="${out%% *}"      # first field
  location="${out#* }"     # everything after the first space

  if [[ "$status" != 30* || -z "$location" ]]; then
    die "login failed (HTTP $status). Check credentials, or that libro.fm accepted them."
  fi

  local token
  token=$(printf '%s' "$location" | sed -nE 's/.*[?&]token=([^&]*).*/\1/p' | urldecode)
  [[ -n "$token" ]] || die "logged in but no token in redirect: $location"
  printf '%s\n' "$token"
}

# Resolve a token: explicit env override, else perform a login.
get_token() {
  if [[ -n "${BOOKSTRIDE_TOKEN:-}" ]]; then
    printf '%s\n' "$BOOKSTRIDE_TOKEN"
  else
    login
  fi
}

# ---------------------------------------------------------------------------
# 2. list: page through /v0/lib/<page> until "more" is false.
# ---------------------------------------------------------------------------
list_books() {
  local token="$1" page=1
  info "listing library"
  while :; do
    local body status
    body=$(curl -sS -w $'\n%{http_code}' \
                -H "Authorization: Bearer $token" \
                "$BASE_URL/v0/lib/$page") || die "could not reach $BASE_URL (is the server running?)"
    status="${body##*$'\n'}"
    body="${body%$'\n'*}"
    [[ "$status" == "200" ]] || die "library request failed (HTTP $status) on page $page"

    # tab-separated: isbn, author, title — easy to eyeball and to grep for an isbn.
    printf '%s' "$body" | jq -r '.res[] | "\(.isbn)\t\(.author1)\t\(.title)"'

    [[ "$(printf '%s' "$body" | jq -r '.more')" == "true" ]] || break
    page=$((page + 1))
  done
}

# ---------------------------------------------------------------------------
# 3. download: kick off conversion, then poll each track (429 => retry).
# ---------------------------------------------------------------------------
download_book() {
  local token="$1" isbn="$2" outdir="${3:-./download-$2}"
  mkdir -p "$outdir"

  info "requesting download manifest for isbn $isbn"
  local body status tracks
  body=$(curl -sS -w $'\n%{http_code}' -X POST \
              -H "Authorization: Bearer $token" \
              "$BASE_URL/v0/book/$isbn/download") || die "could not reach $BASE_URL (is the server running?)"
  status="${body##*$'\n'}"
  body="${body%$'\n'*}"
  [[ "$status" == "202" ]] || die "download request failed (HTTP $status)"

  tracks=$(printf '%s' "$body" | jq -r '.tracks')
  info "$tracks track(s) queued; server is fetching from libro.fm"

  local t
  for (( t=0; t<tracks; t++ )); do
    local out="$outdir/track-$(printf '%03d' "$t").mp3"
    info "track $t -> $out"
    while :; do
      local code
      code=$(curl -sS -o "$out" -w '%{http_code}' \
                  -H "Authorization: Bearer $token" \
                  "$BASE_URL/v0/book/$isbn/$t/track.mp3") \
        || { rm -f "$out"; die "could not reach $BASE_URL (is the server running?)"; }
      case "$code" in
        200) info "  saved $(wc -c <"$out") bytes"; break ;;
        429) info "  not ready, retrying in 5s"; sleep 5 ;;
        *)   rm -f "$out"; die "track $t failed (HTTP $code)" ;;
      esac
    done
  done
  info "done: $outdir"
}

# ---------------------------------------------------------------------------
usage() {
  # Print the leading comment block (skip the shebang, stop at the first
  # non-comment line), with the leading "# " stripped.
  awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next}{exit}' "$0"
  exit "${1:-0}"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    login) get_token ;;
    list)  list_books "$(get_token)" ;;
    download)
      [[ $# -ge 1 ]] || usage 1
      download_book "$(get_token)" "$1" "${2:-}" ;;
    all)
      [[ $# -ge 1 ]] || usage 1
      local token; token=$(get_token)
      list_books "$token"
      download_book "$token" "$1" "${2:-}" ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command: $cmd (try --help)" ;;
  esac
}

main "$@"
