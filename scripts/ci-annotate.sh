#!/bin/bash
# Turns CI logs into check-run annotations so results are readable without downloading log archives.
set -uo pipefail
dir="${1:-ci-logs}"
encode() { python3 -c 'import sys; s=sys.stdin.read()[-6000:]; print(s.replace("%","%25").replace("\r","%0D").replace("\n","%0A"), end="")'; }
for log in "$dir"/*.log; do
  [ -f "$log" ] || continue
  name="$(basename "$log" .log)"
  key="$(grep -nE "error:|Fatal error|Assertion failed|Expected .* at|failed \(|with [1-9][0-9]* failures?|PASS:|Executed [0-9]+ tests|probe:|precondition|Trace/BPT|Build complete" "$log" | tail -40)"
  tail="$(tail -25 "$log")"
  printf '::notice title=%s summary::%s\n' "$name" "$(printf '%s\n----- tail -----\n%s\n' "$key" "$tail" | encode)"
done
exit 0
