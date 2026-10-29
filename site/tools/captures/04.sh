# Example 04 — simulated disk crashes. cwd = site/data/04, $BIN = ReleaseSafe binary.
( time "$BIN" sweep 2000 ) > sweep.txt 2>&1 || true
"$BIN" sweep 2000 --bug-ack-before-fsync > sweep-ack.txt 2>&1 || true
"$BIN" sweep 2000 --bug-no-checksum > sweep-nocrc.txt 2>&1 || true
# Plain replays (the documented output), twice each for the determinism proof.
"$BIN" run 0 --bug-ack-before-fsync > run0-ack.txt 2>&1 || true
"$BIN" run 0 --bug-ack-before-fsync > run0-ack-again.txt 2>&1 || true
"$BIN" run 0 --bug-no-checksum > run0-nocrc.txt 2>&1 || true
"$BIN" run 0 --bug-no-checksum > run0-nocrc-again.txt 2>&1 || true
"$BIN" run 0 > run0.txt 2>&1 || true
# Sector-level replays (--sectors only adds "  |" lines; everything else is identical).
"$BIN" run 0 --sectors > run0-sectors.txt 2>&1 || true
"$BIN" run 0 --bug-ack-before-fsync --sectors > run0-ack-sectors.txt 2>&1 || true
"$BIN" run 0 --bug-no-checksum --sectors > run0-nocrc-sectors.txt 2>&1 || true
# Per-seed stats of the correct code, seeds 0..199.
# Columns: seed, crashes, acked, result, stop_seq, stop_checksum, stop_parent, stop_other,
#          sectors_kept, sectors_dropped
for s in $(seq 0 199); do
  "$BIN" run $s 2>&1 | awk -v s=$s '
    /crash #/ { split($0, a, "applied="); split(a[2], b, " "); kept += b[1];
                split($0, c, "dropped="); split(c[2], d, ";"); dropped += d[1] }
    /stop: unexpected seq/ { sq++ } /stop: checksum mismatch/ { ck++ } /stop: parent mismatch/ { pa++ }
    /stop: (bad len|record past|end of disk)/ { ot++ }
    /^seed=/ { split($2, x, "="); split($3, y, "=");
               printf "%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", s, x[2], y[2], $5, sq, ck, pa, ot, kept, dropped }'
done > per-seed.tsv
