# Example 03 — deterministic scheduler. cwd = site/data/03, $BIN = ReleaseSafe binary.
"$BIN" run 0 --bug > run0-bug.txt 2>&1 || true
"$BIN" run 0 --bug > run0-bug-again.txt 2>&1 || true
"$BIN" run 1 --bug-deadlock > run1-deadlock.txt 2>&1 || true
"$BIN" run 1 --bug-deadlock > run1-deadlock-again.txt 2>&1 || true
"$BIN" run 0 > run0.txt 2>&1 || true
"$BIN" run 1 > run1.txt 2>&1 || true
( time "$BIN" sweep 1000000 ) > sweep.txt 2>&1 || true
"$BIN" sweep 1000000 --bug > sweep-bug.txt 2>&1 || true
"$BIN" sweep 1000000 --bug-deadlock > sweep-deadlock.txt 2>&1 || true
# Per-seed outcome for the first 1000 seeds of each design.
# Columns: seed, flag, accounts, tasks, ticks, result, failure (or -)
for flag in none --bug --bug-deadlock; do
  f=$([ $flag = none ] || echo $flag)
  for s in $(seq 0 999); do
    "$BIN" run $s $f 2>&1 | awk -v s=$s -v fl=$flag '
      /^accounts=/ { split($1, a, "="); acc = a[2]; split($5, t, "="); tasks = t[2] }
      /^FAILURE:/ { fail = $2 }
      /^seed=/ { split($2, k, "="); printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", s, fl, acc, tasks, k[2], $4, (fail == "" ? "-" : fail) }'
  done
done > per-seed.tsv
