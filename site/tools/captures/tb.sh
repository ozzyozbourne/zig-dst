# Captures for site/tigerbeetle.html. Runs with cwd = site/data/tb/, env $TB_DIR = TigerBeetle checkout.
# The VOPR is the prebuilt ReleaseSafe binary $TB_DIR/zig-out/bin/vopr (built with the pinned Zig 0.16).
# Runs are sequential on purpose: one VOPR can use >3 GB RSS (seed 2024), and parallel runs OOM the orb.
V="$TB_DIR/zig-out/bin/vopr"
TIMEFORMAT='%R'

# 1. Seed 42, twice: the full log (header + status lines + PASSED) and the determinism proof.
{ time timeout 60 "$V" 42 > seed42-a.txt 2>&1 || true; } 2> wall42.txt
timeout 60 "$V" 42 > seed42-b.txt 2>&1 || true
{ sha256sum seed42-a.txt seed42-b.txt; cmp seed42-a.txt seed42-b.txt && echo "cmp: identical ($(wc -c < seed42-a.txt) bytes, $(wc -l < seed42-a.txt) lines)"; } > determinism.txt 2>&1 || true

# 2. A seed with crashes, recoveries, state sync, a reformat and upgrades (≈20 s).
{ time timeout 120 "$V" 1337 > seed1337.txt 2>&1 || true; } 2> wall1337.txt

# 3. Ticks + wall-clock seconds for several seeds (seed 42 and 1337 reuse the runs above).
{
  printf 'seed\tresult\tticks\twall_s\n'
  for s in 42 1337 7 99 2024; do
    if [ "$s" = 42 ] || [ "$s" = 1337 ]; then f="seed$s.txt"; [ "$s" = 42 ] && f=seed42-a.txt; w=$(cat "wall$s.txt")
    else { time timeout 120 "$V" "$s" > "tmp-$s.txt" 2>&1 || true; } 2> "wall$s.txt"; f="tmp-$s.txt"; w=$(cat "wall$s.txt"); fi
    r=$(grep -oE 'PASSED \([0-9]+ ticks\)' "$f" | grep -oE '[0-9]+' || true)
    printf '%s\t%s\t%s\t%s\n' "$s" "$([ -n "$r" ] && echo PASSED || echo TIMEOUT/FAIL)" "${r:--}" "$w"
  done
} > ticks.tsv
rm -f tmp-*.txt wall*.txt

# 4. Swarm parameters for seeds 0..499: only the SEED= header, which vopr prints before Cluster.init.
#    `timeout 1` is the hard cap; we stop each run as soon as the last header line appears (~10 ms).
for s in $(seq 0 499); do
  timeout 1 "$V" "$s" > hdr.tmp 2>&1 & p=$!
  while ! grep -q restart_stability hdr.tmp 2>/dev/null && kill -0 "$p" 2>/dev/null; do sleep 0.005; done
  kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true
  sed -n '/SEED=/,/restart_stability/p' hdr.tmp | sed 's/^ *//' | grep -v '^$' | paste -sd '\t'
done > swarm.tsv
rm -f hdr.tmp

# 5. The live single-replica TigerBeetle (orb service "tigerbeetle", port 3000) and the Zig pin.
( cd "$TB_DIR" && echo '$ ./tigerbeetle version' && ./tigerbeetle version ) > tb-version.txt 2>&1 || true
( cd "$TB_DIR" && echo '$ ./tigerbeetle repl --cluster=0 --addresses=3000 --command="lookup_accounts id=1, id=2;"' &&
  timeout 20 ./tigerbeetle repl --cluster=0 --addresses=3000 --command="lookup_accounts id=1, id=2;" ) > repl.txt 2>&1 || true
( cd "$TB_DIR" && echo '$ ./zig/zig version' && ./zig/zig version && echo '$ /home/user/tools/zig-0.17.0/zig version' &&
  /home/user/tools/zig-0.17.0/zig version && echo '$ /home/user/tools/zig-0.17.0/zig build' &&
  timeout 30 /home/user/tools/zig-0.17.0/zig build; echo "exit code: $?" ) > zig-pin.txt 2>&1 || true

# 6. Source excerpts quoted on the page, extracted from the checkout (not hand-copied).
S="$TB_DIR/src"
fn() { awk -v start="$2" -v end="$3" 'index($0, start) == 1 { on = 1 } on { print } on && $0 == end { exit }' "$1"; }
fn "$S/vopr.zig" '    pub fn tick(simulator: *Simulator) void {' '    }' > src-sim-tick.txt
fn "$S/testing/cluster.zig" '        pub fn tick(cluster: *Cluster) void {' '        }' > src-cluster-tick.txt
fn "$S/vopr.zig" '    fn tick_crash(simulator: *Simulator) void {' '    }' > src-tick-crash.txt
fn "$S/vopr.zig" '    fn tick_crash_up(' '    }' >> src-tick-crash.txt
fn "$S/vopr.zig" '    pub fn transition_to_liveness_mode(' '    }' > src-liveness.txt
fn "$S/vopr.zig" '    pub fn cluster_recoverable(' '    }' > src-recoverable.txt
fn "$S/vopr.zig" 'fn options_swarm(' '}' > src-options-swarm.txt
fn "$S/testing/cluster/state_checker.zig" '        pub fn check_state(' '        }' > src-check-state.txt
fn "$S/testing/cluster/storage_checker.zig" '    pub fn replica_compact(' '    }' > src-storage-compact.txt
fn "$S/testing/packet_simulator.zig" '        fn submit_packet_finish(' '        }' > src-packet-finish.txt
fn "$S/stdx/time.zig" '    pub fn tick(self: *TimeSim) void {' '    }' > src-timesim-tick.txt
fn "$S/stdx/prng.zig" 'pub fn from_seed(seed: u64) PRNG {' '}' > src-prng.txt
fn "$S/stdx/prng.zig" 'fn split_mix_64(' '}' >> src-prng.txt
fn "$S/stdx/prng.zig" 'fn next(prng: *PRNG) u64 {' '}' >> src-prng.txt
fn "$S/stdx/prng.zig" 'pub fn int_inclusive(' '}' > src-prng-int.txt
{ echo "// src/config.zig"; grep -n 'tick_ms: u63' "$S/config.zig"; } > src-tick-ms.txt
sed -n '/^\/\/!/p' "$S/testing/storage.zig" > src-storage-header.txt
fn "$S/testing/storage.zig" 'pub const ClusterFaultAtlas = struct {' '        return atlas;' > src-fault-atlas.txt
fn "$S/vsr.zig" 'pub fn quorums(' '}' | head -20 > src-quorums.txt
sed -n '/^### Columns/,/^### Example/p' "$TB_DIR/docs/internals/testing.md" | sed '$d' > doc-columns.txt
sed -n '/^\/\/!/p' "$S/testing/cluster/storage_checker.zig" > src-storage-checker-header.txt
{ echo "// src/tigerbeetle/main.zig (production)"; grep -nE '^(pub )?const (IO|Storage|AOF|MessageBus|Replica|TimeOS) = ' "$S/tigerbeetle/main.zig"
  echo "// src/testing/cluster.zig (simulation)"; grep -nE '^ *(pub )?const (IO|AOF|TimeSim|Storage|MessageBus|Replica|Network) = ' "$S/testing/cluster.zig"
  echo "// src/vsr/replica.zig"; grep -n -A5 '^pub fn ReplicaType(' "$S/vsr/replica.zig"; } > src-replica-type.txt
