#!/bin/bash
# Root part of the guest setup, run by aidevops-vm.sh on every run. Idempotent.
# Environment: NODE_MAJOR, REBOOT_TIME; VALE_VERSION (optional: no Vale when empty).
set -euo pipefail

GUEST_USER=debian
GUEST_UID=1000
: "${NODE_MAJOR:?}" "${REBOOT_TIME:?}"
VALE_VERSION="${VALE_VERSION:-}"
# shellcheck source=guest/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export DEBIAN_FRONTEND=noninteractive

[ "$(id -u "$GUEST_USER")" = "$GUEST_UID" ] || { echo "ERROR: $GUEST_USER is not uid $GUEST_UID" >&2; exit 1; }

# write_if_changed <path> <mode>: stdin becomes the file when it differs; returns 0 either way.
write_if_changed() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if cmp -s "$tmp" "$1"; then
    rm -f "$tmp"
    return 0
  fi
  install -m "$2" "$tmp" "$1"
  rm -f "$tmp"
}

# ---- home directory on the volume -------------------------------------------
mountpoint -q /home || { echo "ERROR: /home is not mounted" >&2; exit 1; }
if [ ! -d "/home/$GUEST_USER" ]; then
  install -d -m 0755 -o "$GUEST_USER" -g "$GUEST_USER" "/home/$GUEST_USER"
  cp -rn /etc/skel/. "/home/$GUEST_USER/"
  chown -R "$GUEST_USER:$GUEST_USER" "/home/$GUEST_USER"
fi

# /etc/aidevops (the source-access broker and its root-only signing trust) lives on the volume, so the one-time
# interactive `aidevops setup --scope source-access` survives a rebuild. Root-owned, outside the user's home.
install -d -o root -g root -m 0755 /home/.system /home/.system/etc-aidevops /etc/aidevops
grep -q '^/home/.system/etc-aidevops /etc/aidevops ' /etc/fstab \
  || echo '/home/.system/etc-aidevops /etc/aidevops none bind,x-systemd.requires-mounts-for=/home 0 0' >> /etc/fstab
systemctl daemon-reload
mountpoint -q /etc/aidevops || mount /etc/aidevops

# ---- apt sources ------------------------------------------------------------
# apt waits up to 10 minutes for the lock the VM's own first-boot apt run may hold.
APT=(apt-get -q -o DPkg::Lock::Timeout=600)
echo "-- apt: package lists --"
install -d -m 0755 /etc/apt/keyrings
"${APT[@]}" update
"${APT[@]}" install -y curl ca-certificates gnupg

if [ ! -s /etc/apt/keyrings/githubcli-archive-keyring.gpg ]; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
fi
if [ ! -s /etc/apt/keyrings/nodesource.gpg ]; then
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  chmod 0644 /etc/apt/keyrings/nodesource.gpg
fi

arch="$(dpkg --print-architecture)"
write_if_changed /etc/apt/sources.list.d/github-cli.list 0644 <<EOF
deb [arch=$arch signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main
EOF
write_if_changed /etc/apt/sources.list.d/nodesource.list 0644 <<EOF
deb [arch=$arch signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main
EOF

# ---- packages ---------------------------------------------------------------
echo "-- apt: installing packages (several minutes on a new VM) --"
"${APT[@]}" update
"${APT[@]}" install -y git curl ca-certificates gnupg jq ripgrep sqlite3 fd-find python3 python3-venv lsof openssl \
  gh nodejs golang-go shellcheck shfmt unattended-upgrades
[ -e /usr/local/bin/fd ] || ln -s "$(command -v fdfind)" /usr/local/bin/fd

# ---- uv: installed now, then kept at the latest release by a daily timer --------------------------------
echo "-- uv --"
GUEST_LIB="$(dirname "${BASH_SOURCE[0]}")"
write_if_changed /etc/systemd/system/aidevops-uv-update.service 0644 <<EOF
[Unit]
Description=Install the latest uv release
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $GUEST_LIB/update-uv.sh
EOF
write_if_changed /etc/systemd/system/aidevops-uv-update.timer 0644 <<'EOF'
[Unit]
Description=Daily uv update

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now aidevops-uv-update.timer
command -v uv >/dev/null || bash "$GUEST_LIB/update-uv.sh"

# ---- Vale: the pinned release, checked against the checksum the release publishes ----------------------
echo "-- vale --"
if [ -n "$VALE_VERSION" ] && [ "$(vale --version 2>/dev/null | cut -d' ' -f3)" != "$VALE_VERSION" ]; then
  case "$arch" in
    amd64) vale_arch=64-bit ;;
    arm64) vale_arch=arm64 ;;
    *) echo "ERROR: no Vale build for $arch" >&2; exit 1 ;;
  esac
  vale_file="vale_${VALE_VERSION}_Linux_${vale_arch}.tar.gz"
  vale_base="https://github.com/errata-ai/vale/releases/download/v$VALE_VERSION"
  install_release "$vale_base/$vale_file" "$vale_base/vale_${VALE_VERSION}_checksums.txt" vale
fi

# ---- unattended upgrades ----------------------------------------------------
echo "-- unattended upgrades and linger --"
write_if_changed /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
write_if_changed /etc/apt/apt.conf.d/52aidevops-vm 0644 <<EOF
Unattended-Upgrade::Origins-Pattern:: "site=cli.github.com";
Unattended-Upgrade::Origins-Pattern:: "site=deb.nodesource.com";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
EOF
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

# ---- user manager that outlives logins --------------------------------------
loginctl enable-linger "$GUEST_USER"
systemctl start "user@$GUEST_UID.service"
