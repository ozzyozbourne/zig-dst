# Example 10 — Mini-VOPR. Runs with cwd = site/data/10, $BIN = ReleaseSafe build of main.zig.
# Replays use --events (print-only: adds "@" lines, same trace hash) so the page can animate packets.
"$BIN" run 3 --bug-commit-early --events > run3-commit-early.txt 2>&1 || true
"$BIN" run 3 --bug-view-change-log --events > run3-view-change-log.txt 2>&1 || true
"$BIN" run 3 --events > run3-correct.txt 2>&1 || true
"$BIN" run 0 --events > run0.txt 2>&1 || true
# Determinism: the plain verbose replay, twice (same command as NOTES.md), plus checksums.
"$BIN" run 3 --bug-commit-early > replay-a.txt 2>&1 || true
"$BIN" run 3 --bug-commit-early > replay-b.txt 2>&1 || true
sha256sum replay-a.txt replay-b.txt > replay-sha.txt
( time "$BIN" sweep 20000 ) > sweep.txt 2>&1 || true
( time "$BIN" sweep 20000 --bug-commit-early ) > sweep-commit-early.txt 2>&1 || true
( time "$BIN" sweep 20000 --bug-view-change-log ) > sweep-view-change-log.txt 2>&1 || true
# Per-seed statistics for seeds 0..199, parsed from the real verbose output of each run.
stats='
/^ *replicas=/ { split($1, a, "="); replicas = a[2] }
/^ *clients=/ { split($1, a, "="); clients = a[2] }
/^ *requests_per_client=/ { split($1, a, "="); requests = a[2] }
/partition side=/ { partitions++ }
/liveness mode: core=/ { live = $1; split($4, a, "="); core = a[2] }
/^ *[0-9]+ +[0-9] [ !^v\/>=] [\/\\#] / {
  ev = substr($0, 11, 1)
  if (ev == "!") { crashes++; w = $NF + 0; if (w > 0) { lossy++; lost += w } }
  if (ev == "^") restarts++
  if (ev == "v") svc++
  if (ev == "/") primaries++
  if (ev == ">") installs++
}
/ FAIL: / { fail_tick = $1 }
/^reason: / { reason = /divergence/ ? "divergence" : /no liveness/ ? "liveness" : /money/ ? "money" : /client/ ? "reply" : "other" }
/^seed=/ {
  for (i = 1; i <= NF; i++) { split($i, a, "="); kv[a[1]] = a[2] }
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\n", kv["seed"], $NF, kv["ticks"], kv["commits"], kv["trace"], replicas, clients, requests, crashes, lossy, lost, restarts, partitions, svc, primaries, (live == "" ? "-" : live), (core == "" ? "-" : core), (fail_tick == "" ? "-" : fail_tick), (reason == "" ? "-" : reason)
}'
for mode in correct commit-early view-change-log; do
  flag=""; [ "$mode" != correct ] && flag="--bug-$mode"
  {
    printf "seed\tresult\tticks\tcommits\ttrace\treplicas\tclients\trequests\tcrashes\tcrashes_losing_writes\twrites_lost\trestarts\tpartitions\tview_change_starts\tprimaries_elected\tliveness_tick\tcore\tfail_tick\treason\n"
    for s in $(seq 0 199); do "$BIN" run "$s" $flag 2>&1 | awk "$stats"; done
  } > "per-seed-$mode.tsv"
done
