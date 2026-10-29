# Chapter "Debugging a failing seed". Runs with cwd = site/data/debug. There is no examples/debug-*
# directory, so capture.sh builds nothing: build example 10 (mini-VOPR) here. capture.sh is run under
# the shared Zig flock (flock /tmp/site-brief/zig.lock site/tools/capture.sh debug), so this build is
# serialized too. Its own binary name avoids overwriting /tmp/dst-bin/10 while another page captures.
B="$BIN_DIR/debug-10"
"$ZIG" build-exe -OReleaseSafe "$ROOT/examples/10-mini-vopr/main.zig" -femit-bin="$B" --cache-dir "$BIN_DIR/cache" >/dev/null
"$ZIG" version > zig-version.txt

# 0. The sweep that started it all.
( time "$B" sweep 20000 --bug-commit-early ) > sweep-bug.txt 2>&1 || true
# 1. Reproduce: the replay twice, byte for byte.
"$B" run 3 --bug-commit-early > replay-a.txt 2>&1 || true
"$B" run 3 --bug-commit-early > replay-b.txt 2>&1 || true
sha256sum replay-a.txt replay-b.txt > replay-sha.txt
# 2-4. Read and narrow: the same replay with per-packet / per-write / per-commit events (print-only).
"$B" run 3 --bug-commit-early --events > events-bug.txt 2>&1 || true
# 5. Fix and verify: the same seed without the bug, then the full sweep.
"$B" run 3 > run3-fixed.txt 2>&1 || true
( time "$B" sweep 20000 ) > sweep-fixed.txt 2>&1 || true
# 6. Seed stability: what seed 3 does under the fixed code, with the same event detail.
"$B" run 3 --events > events-fixed.txt 2>&1 || true
# Which of the first 200 seeds fail with the bug, and how (last two lines of each replay).
for s in $(seq 0 199); do "$B" run "$s" --bug-commit-early 2>&1 | grep -E '^(reason: |seed=)' | tr '\n' '\t'; echo; done > seeds-bug.tsv
# The same 200 seeds under the fixed code: does a seed keep its scenario when the code changes?
for s in $(seq 0 199); do "$B" run "$s" 2>&1 | grep -E '^seed='; done > seeds-fixed.tsv
