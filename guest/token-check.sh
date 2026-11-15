#!/bin/bash
# Reads a GitHub token on stdin and prints one line saying what GitHub makes of it, without printing the token.
# GitHub is asked through /rate_limit, which answers even when the account's budget is spent and uses none of it.
# Exit: 0 accepted with budget left, 1 rejected or malformed, 2 GitHub not reachable, 3 accepted but budget spent.
set -euo pipefail

IFS= read -r token || true
token="${token//[$' \t\r\n']/}"
shape="${#token} chars, ends ...${token: -4}"
case "$token" in
  "") echo "empty token"; exit 1 ;;
  ghp_*) [[ "$token" =~ ^ghp_[A-Za-z0-9]{36}$ ]] || { echo "malformed classic token ($shape; expected ghp_ + 36 letters/digits, 40 chars): bad copy"; exit 1; } ;;
  *) echo "not a classic token ($shape; expected it to start with ghp_)"; exit 1 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
code="$(printf 'Authorization: Bearer %s\n' "$token" \
  | curl -sS -o "$work/body" -D "$work/headers" -w '%{http_code}' -H @- https://api.github.com/rate_limit 2>"$work/err")" \
  || { echo "GitHub not reachable: $(tail -n 1 "$work/err")"; exit 2; }

case "$code" in
  200) ;;
  401) echo "rejected by GitHub (401 Bad credentials; $shape): mistyped, expired or revoked"; exit 1 ;;
  *) echo "GitHub answered HTTP $code: $(jq -r '.message // empty' "$work/body" 2>/dev/null)"; exit 2 ;;
esac

scopes="$(sed -n 's/^x-oauth-scopes: *//Ip' "$work/headers" | tr -d '\r')"
missing=""
for need in repo read:org gist; do
  [[ ",${scopes// /}," == *",$need,"* ]] || missing="$missing $need"
done
[ -z "$missing" ] || { echo "accepted, but missing scopes:$missing (has: ${scopes:-none}; $shape)"; exit 1; }

read -r remaining limit reset < <(jq -r '.resources.core | "\(.remaining) \(.limit) \(.reset)"' "$work/body")
reset_at="$(date -u -d "@$reset" '+%H:%M UTC')"
if [ "$remaining" -eq 0 ]; then
  echo "accepted ($shape; scopes $scopes), but the account's budget is spent: 0/$limit left until $reset_at"
  exit 3
fi
login="$(printf 'Authorization: Bearer %s\n' "$token" | curl -sS -H @- https://api.github.com/user | jq -r '.login // "?"')"
echo "accepted for $login ($shape; scopes $scopes; $remaining/$limit requests left, resets $reset_at)"
