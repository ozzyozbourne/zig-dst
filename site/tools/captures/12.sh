# Captures for 12-coverage-marks-exhaustive. cwd = site/data/12, $BIN = ReleaseSafe binary.
# Random sweeps: the bug is NOT found with the uniform generator, even at 1M seeds.
( time "$BIN" sweep ) > sweep.txt 2>&1 || true
( time "$BIN" sweep 100000 --bug-fill-gap ) > sweep-bug.txt 2>&1 || true
( time "$BIN" coverage 1000000 --bug-fill-gap --require-all ) > coverage-uniform-bug.txt 2>&1 || true
# A boundary-biased generator reaches the mark, and then finds the bug.
( time "$BIN" coverage 100000 --gen-boundaries --require-all ) > coverage-boundaries.txt 2>&1 || true
( time "$BIN" sweep 100000 --gen-boundaries --bug-fill-gap ) > sweep-boundaries-bug.txt 2>&1 || true
# Exhaustive: every op sequence up to a length, small scope.
( time "$BIN" exhaust 4 --bug-fill-gap ) > exhaust4-bug.txt 2>&1 || true
"$BIN" exhaust 4 --bug-fill-gap > exhaust4-bug-again.txt 2>&1 || true
( time "$BIN" exhaust 5 ) > exhaust5.txt 2>&1 || true
# Replays.
"$BIN" run 1 --gen-boundaries --bug-fill-gap > run1-boundaries-bug.txt 2>&1 || true
"$BIN" run 1 --gen-boundaries --bug-fill-gap > run1-boundaries-bug-again.txt 2>&1 || true
"$BIN" run 3 > run3.txt 2>&1 || true
"$BIN" run 3 --bug-fill-gap > run3-bug.txt 2>&1 || true
# Per seed, seeds 0..199: generator, seed, result, ops, then the 10 mark hit counts (marks: line).
for gen in uniform boundaries; do
  flag=""; [ "$gen" = boundaries ] && flag="--gen-boundaries"
  for s in $(seq 0 199); do
    "$BIN" run "$s" $flag 2>&1 | awk -v s="$s" -v g="$gen" '
      /^marks:/ { m=""; for (i=2;i<=NF;i++) { split($i,a,"="); m=m "\t" a[2] } }
      /^seed=.*trace=/ { r=$NF; split($2,o,"="); n=o[2] }
      END { printf "%s\t%s\t%s\t%s%s\n", g, s, r, n, m }'
  done
done > per-seed-marks.tsv
# Boundaries generator with the bug, seeds 0..499: does this seed catch it, and after how many ops?
for s in $(seq 0 499); do
  "$BIN" run "$s" --gen-boundaries --bug-fill-gap 2>&1 | awk -v s="$s" '
    /^seed=.*trace=/ { split($2,o,"="); printf "%s\t%s\t%s\n", s, $NF, o[2] }'
done > per-seed-boundaries-bug.tsv
