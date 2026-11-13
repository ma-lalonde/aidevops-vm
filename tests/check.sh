#!/bin/bash
# bash -n on every shell script; shellcheck on each when it is installed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts=("$ROOT/aidevops-vm.sh" "$ROOT/guest/"*.sh "$ROOT/tests/check.sh")

for f in "${scripts[@]}"; do
  bash -n "$f"
  echo "ok   bash -n ${f#"$ROOT"/}"
done

if command -v shellcheck >/dev/null 2>&1; then
  for f in "${scripts[@]}"; do
    shellcheck "$f"
    echo "ok   shellcheck ${f#"$ROOT"/}"
  done
else
  echo "skip shellcheck: not installed"
fi
