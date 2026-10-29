# Example 02 captures. cwd = site/data/02, $BIN = ReleaseSafe build of examples/02-simulated-time.
( time "$BIN" sweep 100000 ) > sweep.txt 2>&1 || true
( time "$BIN" sweep 10000 ) > sweep-10k.txt 2>&1 || true
( time "$BIN" sweep 1000 ) > sweep-1k.txt 2>&1 || true
( time "$BIN" sweep 100000 --bug ) > sweep-bug.txt 2>&1 || true
"$BIN" run 1 --bug > run1-bug-a.txt 2>&1 || true
"$BIN" run 1 --bug > run1-bug-b.txt 2>&1 || true
"$BIN" run 1 > run1.txt 2>&1 || true
"$BIN" run 1 --bug --dump > run1-bug-dump.txt 2>&1 || true
"$BIN" run 43 --bug > run43-bug.txt 2>&1 || true
# Every op and clock advance of 2000 passing seeds, aggregated.
#   ops.tsv:      op count total_x          (op 1 put, 2 get, 3 evict, 4..8 advance kinds)
#   advances.tsv: op log2_bucket count      (bucket k = advances of 2^k .. 2^(k+1)-1 ms)
"$BIN" sweep 2000 --dump 2>&1 | awk '/ D / { split($4, o, "="); split($7, x, "="); n[o[2]]++
    if (o[2] >= 4) { s[o[2]] += x[2]; k = 0; for (v = x[2]; v >= 2; v = int(v / 2)) k++; h[o[2] " " k]++ } }
  END { for (k = 1; k <= 8; k++) print k, n[k] + 0, (k >= 4 ? s[k] : 0) > "ops.tsv"; for (b in h) print b, h[b] > "advances.tsv" }' || true
# Per seed, with the bug: seed result steps simulated_ms caught_by kind_of_last_advance | same with --no-target
for s in $(seq 0 999); do
  for flag in "" "--no-target"; do
    "$BIN" run "$s" --bug --dump $flag 2>&1 | awk -v s="$s" '
      / D / { split($4, o, "="); if (o[2] >= 4) last = o[2] }
      /evict kept/ { by = "evict" } /: get\(/ { by = "get" }
      /^seed=/ { split($2, st, "="); split($3, sim, "="); sub("ms", "", sim[2]); printf "%s %s %s %s %s ", $5, st[2], sim[2], (by ? by : "-"), ($5 == "FAIL" ? last : "-") }'
  done
  echo "$s"
done > per-seed.tsv
# A real sleep()-based test on this machine: put at t0, sleep(5 ms), get at t1 (monotonic ns).
python3 -c '
import time
ttl = 5_000_000
print("ttl_ns", ttl)
for _ in range(300):
    t0 = time.monotonic_ns(); time.sleep(ttl / 1e9); t1 = time.monotonic_ns(); print(t0, t1)
' > sleep-test.tsv
