# Example 06 — swarm testing and shrinking. cwd = site/data/06, $BIN = ReleaseSafe build of main.zig.
( time "$BIN" sweep 20000 ) > sweep.txt 2>&1 || true
( time "$BIN" sweep 20000 --bug ) > sweep-bug.txt 2>&1 || true
( time "$BIN" sweep 20000 --bug --no-swarm ) > sweep-bug-noswarm.txt 2>&1 || true
( time "$BIN" sweep 200000 --bug --no-swarm ) > sweep-bug-noswarm-200k.txt 2>&1 || true
# The failing seed, every op with ring state (--ops only adds log lines), and twice without it.
"$BIN" run 21 --bug --ops > run21-bug-ops.txt 2>&1 || true
"$BIN" run 21 --bug > run21-bug-a.txt 2>&1 || true
"$BIN" run 21 --bug > run21-bug-b.txt 2>&1 || true
# The shrinker, with every accepted deletion (original op indices), then plain, plus other seeds.
"$BIN" shrink 21 --bug --ops > shrink21-ops.txt 2>&1 || true
"$BIN" shrink 21 --bug > shrink21.txt 2>&1 || true
"$BIN" shrink 31 --bug > shrink31.txt 2>&1 || true
"$BIN" shrink 66 --bug > shrink66.txt 2>&1 || true
# Per-seed swarm weights and max queue depth, swarm vs uniform (correct code), seeds 0..499.
for s in $(seq 0 499); do
  { "$BIN" run "$s" 2>&1; "$BIN" run "$s" --no-swarm 2>&1 | tail -1; } | awk '
    /weights:/ { for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] } }
    /max_count=/ { for (i = 1; i <= NF; i++) { split($i, a, "="); if (a[1] == "max_count") m[++k] = a[2] } }
    END { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", v["seed"], v["initial_cap"], v["push"], v["pop"], v["peek"], v["clear"], v["resize"], m[1], m[2] }'
done > per-seed.tsv
sed -i '1i seed\tinitial_cap\tpush\tpop\tpeek\tclear\tresize\tmax_count_swarm\tmax_count_uniform' per-seed.tsv
