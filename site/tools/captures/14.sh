# Captures for 14-rare-bugs-buggify. cwd = site/data/14, $BIN = ReleaseSafe binary.
# Default sweep (correct code, 2,000,000 seeds) and the bug sweep with realistic fault rates.
( time "$BIN" sweep ) > sweep.txt 2>&1 || true
( time "$BIN" sweep 2000000 --bug-stale-offset ) > sweep-bug.txt 2>&1 || true
( time "$BIN" sweep 2000000 --bug-stale-offset --buggify ) > sweep-bug-buggify.txt 2>&1 || true
# Rare-path frequency with BUGGIFY on the correct code (sweep.txt has the same counters without).
( time "$BIN" sweep 100000 --buggify ) > sweep-buggify.txt 2>&1 || true
# Seeds-to-first-failure over independent search orders: order k sweeps seeds k*10^12, k*10^12+1, ...
for k in $(seq 0 23); do
  printf "order=%d start=%d " "$k" "$((k * 1000000000000))"
  "$BIN" sweep 5000000 --bug-stale-offset --start $((k * 1000000000000)) 2>&1 | grep '^FAIL at' || echo "no failure"
done > orders-plain.txt
for k in $(seq 0 99); do
  printf "order=%d start=%d " "$k" "$((k * 1000000000000))"
  "$BIN" sweep 5000 --bug-stale-offset --buggify --start $((k * 1000000000000)) 2>&1 | grep '^FAIL at' || echo "no failure"
done > orders-buggify.txt
# Replays of the failing seeds, twice for the determinism proof.
"$BIN" run 290087 --bug-stale-offset > run-plain.txt 2>&1 || true
"$BIN" run 290087 --bug-stale-offset > run-plain-again.txt 2>&1 || true
sha256sum run-plain.txt run-plain-again.txt > run-plain-sha.txt
"$BIN" run 40 --bug-stale-offset --buggify > run-buggify.txt 2>&1 || true
"$BIN" run 40 --bug-stale-offset > run-40-nobuggify.txt 2>&1 || true
# Seed stability: the same seed after one extra PRNG draw, after the fix, and the pinned scenario.
"$BIN" run 290087 --bug-stale-offset --extra-draw > run-extra-draw.txt 2>&1 || true
"$BIN" run 290087 > run-fixed.txt 2>&1 || true
( time "$BIN" sweep 2000000 --bug-stale-offset --extra-draw ) > sweep-bug-extra-draw.txt 2>&1 || true
"$BIN" scenario > scenario.txt 2>&1 || true
"$BIN" scenario --bug-stale-offset > scenario-bug.txt 2>&1 || true
"$BIN" scenario --bug-stale-offset --extra-draw > scenario-bug-extra-draw.txt 2>&1 || true
