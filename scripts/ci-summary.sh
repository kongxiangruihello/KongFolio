#!/bin/bash
# Prints a short, final summary of what failed, so the end of the job log is enough to see the problem:
# compile errors, the failing XCTest assertions and tests, a test that started and never finished, and crashes.
set -uo pipefail
dir="${1:-ci-logs}"
label="${2:-}"
echo "===== CI SUMMARY ${label} ====="
for name in build xctest smoke release; do
  log="$dir/$name.log"
  if [ ! -f "$log" ]; then echo "[$name] no log"; continue; fi
  problems="$(grep -E "error:|Fatal error|Precondition failed|Assertion failed|Trace/BPT|Test Case .* failed" "$log" \
    | grep -vE "Test Suite|^\s*[0-9]+ \|" | sed -E 's#/Users/runner/work/[^/]+/[^/]+/##' | cut -c1-240 | awk '!seen[$0]++' | head -12)"
  last="$(grep -E "Test Case '.*' (started|passed|failed)" "$log" | tail -1)"
  executed="$(grep -E "Executed [0-9]+ tests" "$log" | tail -1 | sed -E 's/^[[:space:]]+//')"
  hung=""
  case "$last" in *started*) hung="HUNG or crashed in: $(printf '%s' "$last" | sed -E "s/Test Case '(.*)' started./\1/")";; esac
  if [ -n "$problems" ] || [ -n "$hung" ]; then
    echo "[$name] FAILED ${executed}"
    [ -n "$hung" ] && echo "  $hung"
    printf '%s\n' "$problems" | sed 's/^/  /'
  else
    echo "[$name] ok ${executed}"
  fi
done
echo "===== END SUMMARY ====="
exit 0
