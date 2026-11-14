#!/bin/bash
# Shared by the guest scripts that run as root; sourced, never run.

# install_release <tarball-url> <checksum-file-url> <binary>...: downloads the tarball, verifies it against the
# line of the checksum file that names it, and installs each binary (found anywhere in the tarball) into
# /usr/local/bin.
install_release() {
  local url="$1" sums_url="$2" file work want bin
  shift 2
  file="${url##*/}"
  work="$(mktemp -d)"
  curl -fsSL "$url" -o "$work/$file"
  curl -fsSL "$sums_url" -o "$work/sums"
  want="$(grep -F "$file" "$work/sums" | head -n 1 | cut -d' ' -f1)"
  [ -n "$want" ] || { echo "ERROR: no checksum for $file in $sums_url" >&2; rm -rf "$work"; exit 1; }
  [ "$(sha256sum "$work/$file" | cut -d' ' -f1)" = "$want" ] \
    || { echo "ERROR: checksum mismatch for $file" >&2; rm -rf "$work"; exit 1; }
  tar -xzf "$work/$file" -C "$work"
  for bin in "$@"; do
    install -m 0755 "$(find "$work" -type f -name "$bin" | head -n 1)" "/usr/local/bin/$bin"
  done
  rm -rf "$work"
}
