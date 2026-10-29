# Captures for 07-linearizability-checker. cwd = site/data/07, $BIN = ReleaseSafe binary.
( time "$BIN" sweep ) > sweep.txt 2>&1 || true
( time "$BIN" sweep --bug ) > sweep-bug.txt 2>&1 || true
"$BIN" run 1 --bug > run1-bug.txt 2>&1 || true
"$BIN" run 1 --bug > run1-bug-again.txt 2>&1 || true
"$BIN" run 3 --bug > run3-bug.txt 2>&1 || true
"$BIN" run 3 --bug > run3-bug-again.txt 2>&1 || true
"$BIN" run 1 > run1.txt 2>&1 || true
"$BIN" run 3 > run3.txt 2>&1 || true
# Seeds 0..1999 with --bug: one line per seed: seed, PASS/FAIL, ops, minimal size, key ops, key.
for s in $(seq 0 1999); do
  out=$("$BIN" run "$s" --bug 2>&1 || true)
  res=$(printf '%s\n' "$out" | sed -n 's/^seed=[0-9]* ops=\([0-9]*\) trace=[0-9a-f]* \(PASS\|FAIL\)$/\2\t\1/p')
  min=$(printf '%s\n' "$out" | sed -n "s/^NON-LINEARIZABLE history on key '\(.\)'. Minimal sub-history (\([0-9]*\) of \([0-9]*\) ops.*/\2\t\3\t\1/p")
  [ -n "$min" ] || min=$(printf -- '-\t-\t-')
  printf '%s\t%s\t%s\n' "$s" "$res" "$min"
done > per-seed-bug.tsv
