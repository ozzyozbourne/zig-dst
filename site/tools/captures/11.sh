# Captures for 11-liveness-livelock. cwd = site/data/11, $BIN = ReleaseSafe binary.
( time "$BIN" sweep ) > sweep.txt 2>&1 || true
( time "$BIN" sweep 20000 --bug-fixed-timeout ) > sweep-fixed.txt 2>&1 || true
( time "$BIN" sweep 20000 --bug-no-retry-on-leader-change ) > sweep-noretry.txt 2>&1 || true
# The livelock replay (twice, for the determinism proof) and the same seed with the correct code.
"$BIN" run 11 --bug-fixed-timeout > run11-fixed.txt 2>&1 || true
"$BIN" run 11 --bug-fixed-timeout > run11-fixed-again.txt 2>&1 || true
"$BIN" run 11 > run11.txt 2>&1 || true
# The stuck-request replay (twice) and the same seed with the correct code.
"$BIN" run 3 --bug-no-retry-on-leader-change > run3-noretry.txt 2>&1 || true
"$BIN" run 3 --bug-no-retry-on-leader-change > run3-noretry-again.txt 2>&1 || true
"$BIN" run 3 > run3.txt 2>&1 || true
# Per-seed liveness stats (TSV with a header line), 2000 seeds each.
"$BIN" stats 2000 > stats-ok.tsv 2>&1 || true
"$BIN" stats 2000 --bug-fixed-timeout > stats-fixed.tsv 2>&1 || true
"$BIN" stats 2000 --bug-no-retry-on-leader-change > stats-noretry.tsv 2>&1 || true
# Split-vote rate vs. election-timeout randomization range: 500 seeds per spread.
for k in 0 1 2 3 4 6 8 10 14 20 30 40; do
  "$BIN" stats 500 --spread=$k 2>&1 | awk -v k="$k" 'NR>1 { n++; if ($4 != "none") f++; r += $6; s += $7; m += $8; if ($5 != "-") { t += $5; c++ } }
    END { printf "%s\t%d\t%d\t%d\t%d\t%d\t%.1f\n", k, n, f, r, s, m, (c ? t / c : 0) }'
done > spread.tsv
