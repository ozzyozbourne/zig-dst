# Captures for 13-clock-skew-leases. cwd = site/data/13, $BIN = ReleaseSafe binary.
( time "$BIN" sweep ) > sweep.txt 2>&1 || true
( time "$BIN" sweep 5000 --bug-no-drift-margin ) > sweep-nomargin.txt 2>&1 || true
( time "$BIN" sweep 5000 --bug-wall-clock ) > sweep-wallclock.txt 2>&1 || true

# Per seed, seeds 0..599, for each mode: seed, drift_mode, drift ppm of nodes 0/1/2, result,
# handovers, min_gap (ticks; negative = overlap), pair (old->new), overlap_ticks, stale_reads,
# lease_reads, commits, elections, realtime steps, ticks, expiry_gap (only handovers where the
# old lease ran out), expiry_pair.
for mode in ok nomargin wallclock; do
  case $mode in ok) flag="";; nomargin) flag="--bug-no-drift-margin";; wallclock) flag="--bug-wall-clock";; esac
  for s in $(seq 0 599); do
    "$BIN" run "$s" $flag 2>&1 | awk -v s="$s" '
      /^seed=.*drift_mode=/ { split($2,a,"="); split($3,b,"="); split(b[2],d,","); m=a[2] }
      /^summary:/ { for (i=2;i<=NF;i++) { split($i,kv,"="); v[kv[1]]=kv[2] } }
      /^seed=.*trace=/ { r=$NF; split($2,t,"="); tk=t[2] }
      END { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", s, m, d[1], d[2], d[3], r,
            v["handovers"], v["min_gap"], v["pair"], v["overlap_ticks"], v["stale_reads"], v["lease_reads"], v["commits"],
            v["elections"], v["steps"], tk, v["expiry_gap"], v["expiry_pair"] }'
  done > per-seed-$mode.tsv
done

# Replays. The drift-bug centerpiece is the first seed whose overlap contains a stale read; the
# wall-clock replay is the first failing seed with exactly one realtime step (easy to see).
first_nomargin=$(grep -o 'seed=[0-9]*' sweep-nomargin.txt | head -1 | cut -d= -f2)
first_wallclock=$(grep -o 'seed=[0-9]*' sweep-wallclock.txt | head -1 | cut -d= -f2)
stale=$(awk -F'\t' '$11 > 0 { print $1; exit }' per-seed-nomargin.tsv)
step=$(awk -F'\t' '$6 == "FAIL" && $15 == 1 { print $1; exit }' per-seed-wallclock.tsv)
"$BIN" run "$first_nomargin" --bug-no-drift-margin > first-nomargin.txt 2>&1 || true
"$BIN" run "$first_wallclock" --bug-wall-clock > first-wallclock.txt 2>&1 || true
"$BIN" run "$stale" --bug-no-drift-margin > replay-nomargin.txt 2>&1 || true
"$BIN" run "$stale" --bug-no-drift-margin > replay-nomargin-again.txt 2>&1 || true
"$BIN" run "$step" --bug-wall-clock > replay-wallclock.txt 2>&1 || true
"$BIN" run "$step" --bug-wall-clock > replay-wallclock-again.txt 2>&1 || true
# The same seeds with the correct code. W (commit) lines are dropped from the embedded copy
# except in the 300 ticks after each new leader, to keep the page small; the full log is
# correct-*.full.txt.
"$BIN" run "$stale" > correct-nomargin.full.txt 2>&1 || true
"$BIN" run "$step" > correct-wallclock.full.txt 2>&1 || true
for f in nomargin wallclock; do
  awk '$3 == "*" { lead = $1 } !($3 == "W" && $1 > lead + 300)' correct-$f.full.txt > correct-$f.txt
done
{
  for f in replay-nomargin replay-wallclock; do
    sha256sum "$f.txt" "$f-again.txt"
    if cmp -s "$f.txt" "$f-again.txt"; then echo "cmp $f.txt $f-again.txt: identical"; else echo "cmp $f.txt $f-again.txt: DIFFERENT"; fi
  done
} > determinism.txt
