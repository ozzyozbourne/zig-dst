# Captures for 08-leader-election-partitions. cwd = site/data/08, $BIN = ReleaseSafe binary.
( time "$BIN" sweep ) > sweep.txt 2>&1 || true
( time "$BIN" sweep 5000 --bug-volatile-vote ) > sweep-volatile.txt 2>&1 || true
( time "$BIN" sweep 5000 --bug-no-quorum ) > sweep-noquorum.txt 2>&1 || true
"$BIN" run 86 --bug-volatile-vote > run86-volatile.txt 2>&1 || true
"$BIN" run 86 --bug-volatile-vote > run86-volatile-again.txt 2>&1 || true
"$BIN" run 86 > run86.txt 2>&1 || true
"$BIN" run 0 --bug-no-quorum > run0-noquorum.txt 2>&1 || true
"$BIN" run 0 --bug-no-quorum > run0-noquorum-again.txt 2>&1 || true
# Correct code, seeds 0..1999: seed, nodes, mode, symmetry, result, ticks to agreed leader after heal.
for s in $(seq 0 1999); do
  "$BIN" run "$s" 2>&1 | awk -v s="$s" '
    /^seed=.*nodes=/ { split($2,a,"="); split($3,b,"="); split($4,c,"="); n=a[2]; m=b[2]; y=c[2] }
    /^liveness:/ { lt=$(NF-3) }
    /^seed=.*trace=/ { r=$NF }
    END { printf "%s\t%s\t%s\t%s\t%s\t%s\n", s, n, m, y, r, (lt==""?"-":lt) }'
done > per-seed-ok.tsv
# Each bug, seeds 0..499: seed, nodes, symmetry, result, failure line.
for flag in volatile-vote no-quorum; do
  for s in $(seq 0 499); do
    "$BIN" run "$s" --bug-$flag 2>&1 | awk -v s="$s" '
      /^seed=.*nodes=/ { split($2,a,"="); split($4,c,"="); n=a[2]; y=c[2] }
      /VIOLATED|REGRESSED/ { f=$0 }
      /^seed=.*trace=/ { r=$NF }
      END { printf "%s\t%s\t%s\t%s\t%s\n", s, n, y, r, (f==""?"-":f) }'
  done > per-seed-$flag.tsv
done
