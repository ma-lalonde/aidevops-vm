#!/bin/bash
# Egress probe, run inside the VM by aidevops-vm.sh. Prints one line per failure and exits 1 when there is any.
# Environment: PROBE_BLOCKED and PROBE_BLOCKED6, space-separated host:port targets (IPv4, IPv6) that must not answer.
# The egress ACL drops those packets, so a blocked target times out; an answer or a refusal means the drop failed.
set -uo pipefail

fail=0

blocked() {
  timeout 5 bash -c 'exec 3<>"/dev/tcp/${1%:*}/${1##*:}"' _ "$1" 2>/dev/null
  [ "$?" -eq 124 ]
}

timeout 5 curl -fsS -o /dev/null https://api.github.com || { echo "FAIL api.github.com is not reachable"; fail=1; }

gateway="$(ip -j route show default | jq -r '.[0].gateway // empty')"
for target in ${gateway:+$gateway:8443} ${PROBE_BLOCKED:-}; do
  blocked "$target" || { echo "FAIL $target answered, expected a dropped connection"; fail=1; }
done

if [ -z "$(ip -6 route show default)" ]; then
  echo "skip IPv6 probe: the VM has no IPv6 default route"
elif [ -z "${PROBE_BLOCKED6:-}" ]; then
  echo "skip IPv6 probe: the host has no global IPv6 address"
else
  for target in $PROBE_BLOCKED6; do
    blocked "$target" || { echo "FAIL $target answered, expected a dropped connection"; fail=1; }
  done
fi

exit "$fail"
