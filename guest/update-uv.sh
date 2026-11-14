#!/bin/bash
# Installs the latest uv release into /usr/local/bin when it differs from the installed one. Run as root by
# setup-root.sh when uv is absent and daily by aidevops-uv-update.timer.
set -euo pipefail

# shellcheck source=guest/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

case "$(dpkg --print-architecture)" in
  amd64) uv_arch=x86_64 ;;
  arm64) uv_arch=aarch64 ;;
  *) echo "ERROR: no uv build for this architecture" >&2; exit 1 ;;
esac

base=https://github.com/astral-sh/uv/releases
latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$base/latest")"
latest="${latest##*/}"
[[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: cannot read the latest uv version from $base/latest" >&2; exit 1; }

if [ "$(uv --version 2>/dev/null | cut -d' ' -f2)" = "$latest" ]; then
  echo "uv $latest already installed"
  exit 0
fi
file="uv-$uv_arch-unknown-linux-gnu.tar.gz"
install_release "$base/download/$latest/$file" "$base/download/$latest/$file.sha256" uv uvx
echo "uv $latest installed"
