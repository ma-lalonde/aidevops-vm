#!/bin/bash
# Creates or repairs an Incus VM that only runs aidevops with OpenCode, and drives it with `incus exec`.
#
#   aidevops-vm.sh [up|rebuild|reset-home|pulse-stop|pulse-start|check]
#
# up (default) is idempotent: each step checks state first. /home is a block volume that up and rebuild
# never delete. Settings come from .env next to this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found." >&2
  echo "Copy .env.example to .env, adjust it for your setup, and re-run:" >&2
  echo "  cp $SCRIPT_DIR/.env.example $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck source=.env.example
source "$ENV_FILE"
set +a

VM_NAME="${VM_NAME:-aidevops-vm}"
POOL="${POOL:-default}"
VM_CPU="${VM_CPU:-4}"
VM_MEMORY="${VM_MEMORY:-8GiB}"
ROOT_SIZE="${ROOT_SIZE:-16GiB}"
HOME_SIZE="${HOME_SIZE:-40GiB}"
NODE_MAJOR="${NODE_MAJOR:-26}"
VALE_VERSION="${VALE_VERSION:-}"
PULSE="${PULSE:-on}"
MAX_WORKERS="${MAX_WORKERS:-3}"
RAM_RESERVE_MB="${RAM_RESERVE_MB:-2048}"
REBOOT_TIME="${REBOOT_TIME:-04:00}"
REPOS="${REPOS:-}"
INSTRUCTIONS_REPO="${INSTRUCTIONS_REPO:-}"
INSTRUCTIONS_FILES="${INSTRUCTIONS_FILES:-}"
BASE_IMAGE_REMOTE="${BASE_IMAGE_REMOTE:-images:debian/13/cloud}"
BASE_IMAGE_ALIAS="aidevops-vm-base"
GUEST_USER=debian
GUEST_UID=1000
GUEST_HOME="/home/$GUEST_USER"
HOME_VOLUME="${VM_NAME}-home"
ACL="${VM_NAME}-egress"
GUEST_DIR=/opt/aidevops-vm
MARKER=/var/lib/cloud/aidevops-vm-bootstrap-done

# Private, LAN, tailnet, link-local, loopback, multicast and reserved ranges the VM must not reach.
DROP_RANGES="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16,127.0.0.0/8,0.0.0.0/8,224.0.0.0/4,240.0.0.0/4,fc00::/7,fe80::/10,ff00::/8"

die() { echo "ERROR: $*" >&2; exit 1; }

# Command in the VM as root.
gexec() { incus exec "$VM_NAME" -- "$@"; }

# Command in the VM as the VM user, with the user's systemd manager reachable.
uexec() {
  incus exec "$VM_NAME" --user "$GUEST_UID" --group "$GUEST_UID" --cwd "$GUEST_HOME" \
    --env "HOME=$GUEST_HOME" \
    --env "XDG_RUNTIME_DIR=/run/user/$GUEST_UID" \
    --env "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$GUEST_UID/bus" \
    --env "PATH=$GUEST_HOME/.npm-global/bin:$GUEST_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    "$@"
}

# aidevops CLI as the VM user.
uaidevops() {
  uexec -- bash -c 'a="$(command -v aidevops || true)"; [ -n "$a" ] || a="$HOME/Git/aidevops/aidevops.sh"; exec "$a" "$@"' _ "$@"
}

vm_exists() { incus info "$VM_NAME" >/dev/null 2>&1; }
vm_running() { [ "$(incus list "^${VM_NAME}\$" -f csv -c s 2>/dev/null)" = "RUNNING" ]; }

validate_config() {
  command -v incus >/dev/null || die "incus not found"
  command -v jq >/dev/null || die "jq not found"
  case "$PULSE" in on | off) ;; *) die "PULSE must be on or off" ;; esac
  local entry
  for entry in $REPOS; do
    [[ "$entry" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(:pulse(:[A-Za-z0-9._/-]+)?|:[A-Za-z0-9._/-]+)?$ ]] \
      || die "REPOS entry '$entry' is not owner/repo[:pulse][:base-branch]"
  done
  [[ -z "$VALE_VERSION" || "$VALE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VALE_VERSION '$VALE_VERSION' is not x.y.z"
  [[ -z "$INSTRUCTIONS_REPO" || "$INSTRUCTIONS_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
    || die "INSTRUCTIONS_REPO '$INSTRUCTIONS_REPO' is not owner/repo"
  [ -z "$INSTRUCTIONS_FILES" ] || [ -n "$INSTRUCTIONS_REPO" ] || die "INSTRUCTIONS_FILES needs INSTRUCTIONS_REPO"
  local file
  for file in $INSTRUCTIONS_FILES; do
    [[ "$file" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ && "$file" != *..* ]] || die "INSTRUCTIONS_FILES entry '$file' is not a path inside the repository"
  done
}

# GITHUB_TOKEN_FILE is optional: without it, the token is asked for on the terminal when the VM's gh login is
# missing or rejected.
validate_token_and_git() {
  if [ -n "${GITHUB_TOKEN_FILE:-}" ]; then
    [ -s "$GITHUB_TOKEN_FILE" ] || die "token file $GITHUB_TOKEN_FILE is missing or empty"
    local mode
    mode="$(stat -c %a "$GITHUB_TOKEN_FILE")"
    [ $((8#$mode & 8#077)) -eq 0 ] || die "token file $GITHUB_TOKEN_FILE is readable by group or others (mode $mode); chmod 600 it"
  fi
  [ -n "${GIT_USER_NAME:-}" ] || die "GIT_USER_NAME is not set in .env"
  [ -n "${GIT_USER_EMAIL:-}" ] || die "GIT_USER_EMAIL is not set in .env"
}

# ---- up steps ---------------------------------------------------------------

ensure_image() {
  if incus image info "$BASE_IMAGE_ALIAS" >/dev/null 2>&1; then
    echo "-- base image $BASE_IMAGE_ALIAS already cached --"
  else
    echo "-- caching $BASE_IMAGE_REMOTE as $BASE_IMAGE_ALIAS --"
    incus image copy "$BASE_IMAGE_REMOTE" local: --vm --alias "$BASE_IMAGE_ALIAS" --auto-update
  fi
}

# Egress ACL: drop the ranges, the host's own IPv4 addresses and the host's on-link IPv6 networks, allow the
# rest, no ingress rule. The rules' hash is kept in the ACL's config, so the ACL is rewritten only when it differs.
ensure_acl() {
  local host_v4 host_v6 host_addrs rules want have
  host_v4="$(ip -j -4 addr show scope global | jq -r '[.[].addr_info[] | .local + "/32"] | unique | join(",")')"
  host_v6="$(ip -j -6 route show proto kernel | jq -r '
    [.[].dst | select(test("^(fe80|ff)") | not) | select(. != "default")] | unique | join(",")')"
  host_addrs="${host_v4}${host_v4:+${host_v6:+,}}${host_v6}"
  rules="egress:
- action: drop
  destination: ${DROP_RANGES}${host_addrs:+,$host_addrs}
  state: enabled
- action: allow
  state: enabled
ingress: []"
  want="$(printf '%s' "$rules" | sha256sum | cut -d' ' -f1)"
  incus network acl show "$ACL" >/dev/null 2>&1 || incus network acl create "$ACL"
  have="$(incus network acl get "$ACL" user.rules-hash 2>/dev/null || true)"
  if [ "$have" = "$want" ]; then
    echo "-- ACL $ACL up to date --"
  else
    echo "-- writing ACL $ACL --"
    printf '%s\nconfig:\n  user.rules-hash: %s\n' "$rules" "$want" | incus network acl edit "$ACL"
  fi
}

ensure_volume() {
  if incus storage volume show "$POOL" "$HOME_VOLUME" >/dev/null 2>&1; then
    echo "-- volume $HOME_VOLUME exists --"
  else
    echo "-- creating block volume $HOME_VOLUME ($HOME_SIZE) --"
    incus storage volume create "$POOL" "$HOME_VOLUME" --type=block size="$HOME_SIZE"
  fi
}

# Devices are added while the VM is stopped (cold-plug).
ensure_vm() {
  if vm_exists; then
    echo "-- VM $VM_NAME exists --"
    incus config device show "$VM_NAME" | grep -q '^home:' || die "VM $VM_NAME has no home volume device; run rebuild"
  else
    echo "-- creating $VM_NAME (stopped) --"
    incus init "$BASE_IMAGE_ALIAS" "$VM_NAME" --vm -s "$POOL" \
      -c limits.cpu="$VM_CPU" \
      -c limits.memory="$VM_MEMORY" \
      -c "cloud-init.user-data=$(cat "$SCRIPT_DIR/cloud-init.yaml")" \
      -d root,size="$ROOT_SIZE"
    incus config device add "$VM_NAME" home disk pool="$POOL" source="$HOME_VOLUME"
  fi
  if [ "$(incus config device get "$VM_NAME" eth0 security.acls 2>/dev/null || true)" != "$ACL" ]; then
    echo "-- attaching $ACL to eth0 --"
    if incus config device get "$VM_NAME" eth0 type >/dev/null 2>&1; then
      incus config device set "$VM_NAME" eth0 security.acls="$ACL" security.acls.default.egress.action=reject
    else
      incus config device override "$VM_NAME" eth0 security.acls="$ACL" security.acls.default.egress.action=reject
    fi
  fi
  if vm_running; then
    echo "-- $VM_NAME already running --"
  else
    echo "-- starting $VM_NAME --"
    incus start "$VM_NAME"
  fi
  echo "-- waiting for cloud-init --"
  local _
  for _ in $(seq 1 120); do
    gexec test -f "$MARKER" 2>/dev/null && break
    sleep 5
  done
  gexec test -f "$MARKER" || die "cloud-init bootstrap did not complete in time"
}

push_guest() {
  gexec rm -rf "$GUEST_DIR/guest"
  gexec mkdir -p "$GUEST_DIR"
  incus file push -r "$SCRIPT_DIR/guest" "$VM_NAME$GUEST_DIR/"
  gexec chmod -R a+rX "$GUEST_DIR"
}

run_root_setup() {
  echo "-- guest root setup --"
  incus exec "$VM_NAME" --env "NODE_MAJOR=$NODE_MAJOR" --env "REBOOT_TIME=$REBOOT_TIME" \
    --env "VALE_VERSION=$VALE_VERSION" -- bash "$GUEST_DIR/guest/setup-root.sh"
}

# token_check: the token on stdin, judged by guest/token-check.sh (its exit codes apply).
token_check() { uexec -- bash "$GUEST_DIR/guest/token-check.sh"; }

# The token goes in on stdin, never in argv. A token file is applied on every run so a rotated token takes
# effect. Without one, the stored login is kept while GitHub accepts it; otherwise the token is read from the
# terminal, checked, and asked again until GitHub accepts it. gh validates a token when storing it, which fails
# while the account's budget is spent, so the run stops then with the reset time.
login_github() {
  local status rc token
  echo "-- gh login and git identity --"
  if [ -n "${GITHUB_TOKEN_FILE:-}" ]; then
    rc=0; status="$(token_check < "$GITHUB_TOKEN_FILE")" || rc=$?
    echo "-- token file: $status --"
    [ "$rc" -eq 0 ] || die "token file not usable now"
    uexec -- gh auth login --hostname github.com --with-token < "$GITHUB_TOKEN_FILE"
  else
    rc=0; status="$(gh_login)" || rc=$?
    echo "-- stored gh login: $status --"
    case "$rc" in
      2) die "cannot check the stored login now" ;;
      3) die "stop the pulse (pulse-stop) and re-run after the reset" ;;
    esac
    if [ "$rc" -ne 0 ]; then
      [ -t 0 ] || die "the VM has no valid gh login: run from a terminal to type the token, or set GITHUB_TOKEN_FILE"
      while :; do
        read -r -s -p "GitHub token for the VM's account (classic: repo, read:org, gist): " token
        echo
        token="${token//[$' \t\r\n']/}"
        rc=0; status="$(token_check <<< "$token")" || rc=$?
        echo "-- new token: $status --"
        case "$rc" in
          0) break ;;
          2) die "cannot check the token now" ;;
          3) die "token is good; stop the pulse (pulse-stop) and re-run after the reset to store it" ;;
        esac
      done
      uexec -- gh auth login --hostname github.com --with-token <<< "$token"
      unset token
    fi
  fi
  uexec -- gh auth setup-git
  uexec -- git config --global user.name "$GIT_USER_NAME"
  uexec -- git config --global user.email "$GIT_USER_EMAIL"
}

run_user_setup() {
  echo "-- guest user setup --"
  uexec --env "PULSE=$PULSE" --env "MAX_WORKERS=$MAX_WORKERS" --env "RAM_RESERVE_MB=$RAM_RESERVE_MB" \
    --env "REPOS=$REPOS" --env "INSTRUCTIONS_REPO=$INSTRUCTIONS_REPO" --env "INSTRUCTIONS_FILES=$INSTRUCTIONS_FILES" \
    -- bash "$GUEST_DIR/guest/setup-user.sh" </dev/null
}

# One line per failure; exits 1 when there is any.
probe() {
  local lan_gw host_ip host_ip6
  lan_gw="$(ip -j route show default | jq -r '.[0].gateway // empty')"
  host_ip="$(ip -j addr show scope global | jq -r '[.[].addr_info[] | select(.family == "inet" and .scope == "global") | .local][0] // empty')"
  host_ip6="$(ip -j addr show scope global | jq -r '[.[].addr_info[] | select(.family == "inet6" and .scope == "global") | .local][0] // empty')"
  incus exec "$VM_NAME" \
    --env "PROBE_BLOCKED=${lan_gw:+$lan_gw:22 }100.100.100.100:53${host_ip:+ $host_ip:22}" \
    --env "PROBE_BLOCKED6=${host_ip6:+$host_ip6:22}" \
    -- bash "$GUEST_DIR/guest/probe.sh"
}

cmd_up() {
  validate_token_and_git
  echo "== aidevops VM: $VM_NAME =="
  ensure_image
  ensure_acl
  ensure_volume
  ensure_vm
  push_guest
  run_root_setup
  login_github
  run_user_setup
  echo "-- egress probe --"
  probe
  echo "== done. Sign-ins: see README, \"One-time sign-ins\" =="
}

cmd_rebuild() {
  validate_token_and_git
  if vm_exists; then
    echo "-- deleting $VM_NAME (volume $HOME_VOLUME is kept) --"
    incus delete --force "$VM_NAME"
  fi
  cmd_up
}

cmd_reset_home() {
  local typed
  read -r -p "This deletes VM $VM_NAME and its home volume. Type the VM name to confirm: " typed
  [ "$typed" = "$VM_NAME" ] || die "name did not match, nothing deleted"
  if vm_exists; then incus delete --force "$VM_NAME"; fi
  if incus storage volume show "$POOL" "$HOME_VOLUME" >/dev/null 2>&1; then
    incus storage volume delete "$POOL" "$HOME_VOLUME"
  fi
  echo "-- deleted; run up to start from nothing --"
}

# check_step <label> <command...>: runs the command, prints ok or FAIL with its last lines, and counts failures.
failures=0
check_step() {
  local label="$1" out
  shift
  if out="$("$@" 2>&1)"; then
    echo "ok   $label"
  else
    echo "FAIL $label"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/     /'
    failures=$((failures + 1))
  fi
}

user_timers_have() {
  local name
  for name in "$@"; do
    uexec -- systemctl --user list-timers --all --no-legend | grep -q "$name" || { echo "missing timer $name"; return 1; }
  done
}

apt_timers() {
  [ "$(gexec systemctl list-timers apt-daily.timer apt-daily-upgrade.timer --no-legend | grep -c timer)" -ge 2 ]
}

allowed_origins() {
  local origins
  origins="$(gexec unattended-upgrade --dry-run --debug 2>&1 | grep -i 'allowed origins')"
  grep -q 'cli.github.com' <<< "$origins" && grep -q 'nodesource' <<< "$origins"
}

no_cron_line() { ! uexec -- crontab -l 2>/dev/null | grep -qi aidevops; }

tools_installed() {
  uexec -- go version >/dev/null && uexec -- uv --version >/dev/null \
    && gexec systemctl is-enabled --quiet aidevops-uv-update.timer \
    && { [ -z "$VALE_VERSION" ] || [ "$(uexec -- vale --version | cut -d' ' -f3)" = "$VALE_VERSION" ]; }
}

gh_login() { uexec -- bash -c 'gh auth token 2>/dev/null | bash "$1"' _ "$GUEST_DIR/guest/token-check.sh"; }

linger() { [ "$(gexec loginctl show-user "$GUEST_USER" -p Linger --value)" = yes ]; }

source_access() {
  gexec mountpoint -q /etc/aidevops \
    && gexec python3 -I -B /etc/aidevops/source-access/source-access-helper.py trust-check
}

cmd_check() {
  vm_running || die "VM $VM_NAME is not running"
  check_step "apt timers scheduled" apt_timers
  check_step "unattended-upgrades allows gh and NodeSource origins" allowed_origins
  check_step "user timers: auto-update, repo-sync, pulse watchdog" \
    user_timers_have aidevops-auto-update aidevops-repo-sync aidevops-pulse-watchdog
  if [ "$PULSE" = on ]; then check_step "user timer: supervisor pulse" user_timers_have aidevops-supervisor-pulse; fi
  check_step "no aidevops cron line" no_cron_line
  check_step "gh login accepted by GitHub, budget left" gh_login
  check_step "linger enabled" linger
  check_step "source-access broker trusted (README, one-time sign-ins)" source_access
  check_step "go, uv (with its update timer) and vale installed" tools_installed
  check_step "auto-update health-check" uaidevops auto-update health-check
  check_step "aidevops status" uaidevops status
  check_step "pulse status" uaidevops pulse status
  check_step "auto-update service runs" uexec -- timeout 900 systemctl --user start aidevops-auto-update.service
  check_step "egress probe" probe
  [ "$failures" -eq 0 ] || die "$failures check(s) failed"
  echo "all checks passed"
}

case "${1:-up}" in
  up) validate_config; cmd_up ;;
  rebuild) validate_config; cmd_rebuild ;;
  reset-home) validate_config; cmd_reset_home ;;
  pulse-stop) validate_config; uaidevops pulse stop ;;
  pulse-start) validate_config; uaidevops pulse start ;;
  check) validate_config; cmd_check ;;
  *) die "usage: $0 [up|rebuild|reset-home|pulse-stop|pulse-start|check]" ;;
esac
