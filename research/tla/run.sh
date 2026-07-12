#!/usr/bin/env bash
# Model-check KEP-0002's SharedChannel protocol (P2 in research/open-problems.md).
#
# Usage:  ./run.sh [config-name ...]     default: all seven configs
#
# Three configs are EXPECTED to fail (they demonstrate Findings 1-3, see
# README.md); the script asserts each config's expected outcome and exits
# nonzero only on a deviation. Needs Java 17+; fetches tla2tools.jar on
# first run (verified with TLC 2.19).
set -euo pipefail
cd "$(dirname "$0")"

JAR="${TLA2TOOLS_JAR:-.cache/tla2tools.jar}"
if [ ! -f "$JAR" ]; then
  mkdir -p "$(dirname "$JAR")"
  echo "Fetching tla2tools.jar ..."
  curl -fsSL -o "$JAR" \
    https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
fi

expected() {
  case "$1" in
    core_cap4_selective)     echo fail ;;  # Finding 1: selective sweep loses wakeups
    strand_flipall)          echo fail ;;  # Finding 2: admitted task abandoned across close
    core_cap4_waitres_naive) echo fail ;;  # Finding 3: naive repair strands receivers
    *)                       echo pass ;;
  esac
}

configs=("$@")
if [ ${#configs[@]} -eq 0 ]; then
  configs=(core_cap1_flipall core_cap4_flipall core_cap4_selective
           strand_flipall strand_waitres core_cap4_waitres_naive
           core_cap1_waitres)
fi

rc=0
for c in "${configs[@]}"; do
  want=$(expected "$c")
  printf '=== %s (expected: %s) ===\n' "$c" "$want"
  out=$(mktemp)
  if java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto \
       -config "$c.cfg" shared_channel.tla >"$out" 2>&1; then
    got=pass
  else
    got=fail
  fi
  grep -E '^(Error: |Model checking completed|[0-9]+ states generated)' "$out" | head -3
  if [ "$got" != "$want" ]; then
    echo "UNEXPECTED OUTCOME for $c: got $got, expected $want"
    tail -60 "$out"
    rc=1
  fi
  rm -f "$out"
done
exit $rc
