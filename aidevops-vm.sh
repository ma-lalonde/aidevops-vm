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
PULSE="${PULSE:-on}"
MAX_WORKERS="${MAX_WORKERS:-3}"
RAM_RESERVE_MB="${RAM_RESERVE_MB:-2048}"
REBOOT_TIME="${REBOOT_TIME:-04:00}"
REPOS="${REPOS:-}"
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
    [[ "$entry" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(:pulse(:[A-Za-z0-9._/-]+)?)?$ ]] \
      || die "REPOS entry '$entry' is not owner/repo[:pulse[:base-branch]]"
  done
}

validate_token_and_git() {
  [ -n "${GITHUB_TOKEN_FILE:-}" ] || die "GITHUB_TOKEN_FILE is not set in .env"
  [ -f "$GITHUB_TOKEN_FILE" ] || die "token file $GITHUB_TOKEN_FILE is missing"
  [ -s "$GITHUB_TOKEN_FILE" ] || die "token file $GITHUB_TOKEN_FILE is empty"
  local mode
  mode="$(stat -c %a "$GITHUB_TOKEN_FILE")"
  [ $((8#$mode & 8#077)) -eq 0 ] || die "token file $GITHUB_TOKEN_FILE is readable by group or others (mode $mode); chmod 600 it"
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
  incus exec "$VM_NAME" --env "NODE_MAJOR=$NODE_MAJOR" --env "REBOOT_TIME=$REBOOT_TIME" -- bash "$GUEST_DIR/guest/setup-root.sh"
}

# The token goes in on stdin, never in argv. Applied on every run so a rotated token takes effect:
# gh auth status exits 0 for a stored token GitHub now rejects, so it cannot gate this.
login_github() {
  echo "-- gh login and git identity --"
  uexec -- gh auth login --hostname github.com --with-token < "$GITHUB_TOKEN_FILE"
  uexec -- gh auth setup-git
  uexec -- git config --global user.name "$GIT_USER_NAME"
  uexec -- git config --global user.email "$GIT_USER_EMAIL"
}

run_user_setup() {
  echo "-- guest user setup --"
  uexec --env "PULSE=$PULSE" --env "MAX_WORKERS=$MAX_WORKERS" --env "RAM_RESERVE_MB=$RAM_RESERVE_MB" \
    --env "REPOS=$REPOS" \
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

linger() { [ "$(gexec loginctl show-user "$GUEST_USER" -p Linger --value)" = yes ]; }

cmd_check() {
  vm_running || die "VM $VM_NAME is not running"
  check_step "apt timers scheduled" apt_timers
  check_step "unattended-upgrades allows gh and NodeSource origins" allowed_origins
  check_step "user timers: auto-update, repo-sync, pulse watchdog" \
    user_timers_have aidevops-auto-update aidevops-repo-sync aidevops-pulse-watchdog
  if [ "$PULSE" = on ]; then check_step "user timer: supervisor pulse" user_timers_have aidevops-supervisor-pulse; fi
  check_step "no aidevops cron line" no_cron_line
  check_step "linger enabled" linger
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
