#!/usr/bin/env bash
# Checks one example against the results the site shows (site/data/home/sweeps.tsv):
# it builds, is zig-fmt clean, every sweep gives the recorded result and first failing seed,
# and replaying that seed twice gives the recorded trace hash both times.
# Usage: ci/check.sh <NN>      (needs Zig 0.17 on PATH)
set -euo pipefail
id=$1
root=$(cd "$(dirname "$0")/.." && pwd)
dir=$(ls -d "$root"/examples/"$id"-*/)
bin=$(mktemp -d)/ex$id
zig fmt --check "$dir/main.zig"
zig build-exe -OReleaseSafe "$dir/main.zig" -femit-bin="$bin"
if grep -q '^test ' "$dir/main.zig"; then zig test "$dir/main.zig"; fi

failures=0
while IFS=$'\t' read -r row_id flag count result seed trace _ms; do
  [ "$row_id" = "$id" ] || continue
  flags=$([ "$flag" = none ] || echo "$flag" | tr + ' ')
  out=$("$bin" sweep "$count" $flags 2>&1 || true)
  got_seed=$(echo "$out" | sed -n 's/.*FAIL at seed=\([0-9]*\).*/\1/p' | head -1)
  if [ "$result" = PASS ]; then
    if [ -n "$got_seed" ]; then echo "FAIL $id $flag: expected PASS, sweep failed at seed=$got_seed"; failures=$((failures + 1)); continue; fi
    echo "ok   $id $flag: PASS over $count seeds"
    continue
  fi
  if [ "$got_seed" != "$seed" ]; then echo "FAIL $id $flag: expected first failure at seed=$seed, got '${got_seed:-none}'"; failures=$((failures + 1)); continue; fi
  a=$("$bin" run "$seed" $flags 2>&1 || true); b=$("$bin" run "$seed" $flags 2>&1 || true)
  got_trace=$(echo "$a" | grep -o 'trace=[0-9a-f]*' | tail -1 | cut -d= -f2)
  if [ "$a" != "$b" ]; then echo "FAIL $id $flag: two replays of seed=$seed differ"; failures=$((failures + 1)); continue; fi
  if [ "$got_trace" != "$trace" ]; then echo "FAIL $id $flag: seed=$seed trace=$got_trace, expected $trace"; failures=$((failures + 1)); continue; fi
  echo "ok   $id $flag: fails at seed=$seed, replay trace=$trace (x2 identical)"
done < "$root/site/data/home/sweeps.tsv"
[ "$failures" -eq 0 ]
