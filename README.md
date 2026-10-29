# Deterministic Simulation Testing — a guide through TigerBeetle

This guide has three parts:
1. What DST is, why it exists, and where it helps.
2. How TigerBeetle's simulator (the **VOPR**) works, from its source code at commit `0450c32b2`.
3. Ten runnable Zig 0.17 projects, ordered from easy to hard. Each one adds one idea.

Every number in this guide comes from a real run in this orb.

## Visual site

`site/` is a static, interactive version of this guide: an overview, a page on TigerBeetle's VOPR, and one
page per example with step-through replays, charts and in-browser mini-simulations. Every number on it is
parsed from real program output stored in `site/data/`.

```sh
cd site && python3 -m http.server 8000      # then open http://localhost:8000
site/tools/capture.sh                       # re-run all programs and refresh the data (Zig 0.17)
```

---

## Part 1 — What, why, where

### What
**Deterministic Simulation Testing** runs your *real* production code inside a fake
world: fake clock, fake network, fake disk, and a fake scheduler. The whole fake world is
driven by **one random seed**. The simulator throws faults at the system (packet loss,
crashes, torn writes, partitions, bit flips), and checkers assert invariants after every
step.

There are three properties, and you need all of them:

| Property | Means | Gives you |
|---|---|---|
| **Simulation** | Every nondeterministic dependency (time, IO, threads, randomness) sits behind an interface, and a simulated version is plugged in | Faults on demand, with time running far faster than real time |
| **Determinism** | Same seed + same code ⇒ the exact same execution, byte for byte | Any failure can be replayed and debugged with a debugger and print statements |
| **Testing** | Invariants and oracles are checked *continuously*, not just at the end | Bugs are caught at the step where they happen, not millions of steps later |

### Why
Distributed and storage systems fail in combinations: a crash *during* an fsync, *while*
a partition is healing, *after* a retried request. You can't write those cases by
hand, real-world chaos testing reaches them slowly, and when it does find one you can't
reproduce it. DST turns these rare combinations into something you can search,
cheaply and reproducibly:
- **Speed:** time is a counter. Example 02 simulates about 400 years of clock time per real second.
- **Coverage:** millions of seeds, each with different fault settings (swarm testing).
- **Reproducibility:** a failure is one integer. It never becomes "flaky, can't reproduce".
- **Fearless refactoring:** TigerBeetle rewrites core parts of the system and relies on the VOPR to catch regressions.

### Where it helps (and where it doesn't)
- Strong fit: consensus and replication, storage engines and WALs, crash recovery, exactly-once
  delivery, schedulers, caches with TTLs, and any concurrent state machine.
- Weak fit: code that depends on a large nondeterministic platform you can't stub out (GPU drivers,
  browsers), or performance tuning. A simulator models latency; it doesn't measure it.
- Cost: you must design for it. Single-threaded event loops, injected `Time`/`IO`/`Storage`,
  and no hidden global randomness. It is much cheaper to do from day one than to retrofit,
  which is why TigerBeetle built it in from the start.

---

## Part 2 — How TigerBeetle does it

### Setup used here
- **Zig 0.17.0** (the latest release) is installed at `~/tools/zig-0.17.0`, with a symlink in `~/.local/bin/zig`.
- TigerBeetle pins **Zig 0.16.0** in `zig/download.sh`, and `build.zig` refuses any other version:
  `error: unsupported zig version: expected 0.16.0, found 0.17.0`. So the repo uses its own
  `./zig/zig` (0.16.0), and the examples in this guide use 0.17.0.
- A single-replica TigerBeetle runs as the orb service `tigerbeetle` on port 3000. Accounts 1 and 2
  were created and a transfer of 10 was posted: `debits_posted=10` / `credits_posted=10`.

### The architecture that makes DST possible
TigerBeetle's replica is *generic* over its dependencies:

```zig
// src/vsr/replica.zig
pub fn ReplicaType(StateMachine, MessageBus, Storage, AOF) type
```

Production plugs in real io_uring storage and TCP. `src/testing/cluster.zig` plugs in:

| Real | Simulated | File |
|---|---|---|
| Clock | `TimeSim`: a tick counter with linear, periodic, step, and non-ideal drift | `src/stdx/time.zig`, `src/vsr/clock.zig` |
| Network | `PacketSimulator`: exponential delay, loss, replay, capacity, clogging, partitions | `src/testing/packet_simulator.zig`, `src/testing/cluster/network.zig` |
| Disk | In-memory `Storage`: latency, read/write faults, misdirected writes, crash faults, all bounded by a `ClusterFaultAtlas` | `src/testing/storage.zig` |
| Threads | None needed: the system is single-threaded, with callbacks driven by `tick()` | `src/testing/io.zig` |

### The simulator loop (`src/vopr.zig`)
1. `seed` comes from argv (or crypto-random), then `prng = PRNG.from_seed(seed)`.
2. **`options_swarm(prng)`** picks *everything*: 1–6 replicas, standbys, clients,
   packet loss 0–30%, replay 0–50%, partition mode and symmetry, disk latencies, read/write
   fault rates 0–10%, crash and restart probabilities, cache sizes, and batch sizes. Each seed
   is a different world.
3. **Safety phase:** `while (tick < ticks_max_requests) simulator.tick()`. Each tick runs
   `cluster.tick()` (network and storage steps), `tick_requests`, `tick_upgrade`, `tick_crash`, and `tick_pause`.
   Replicas crash, restart, get reformatted, and get upgraded to new releases.
4. **Liveness phase:** `transition_to_liveness_mode(core)` heals a random *core* quorum.
   The core must converge within `ticks_max_convergence`. If it doesn't, `cluster_recoverable()`
   decides whether that's a real bug or a scenario that can't be recovered.
5. **Checkers run continuously:** `state_checker.zig` (every replica commits the same op
   checksums, with no divergence), `storage_checker.zig` (data files are byte-identical at checkpoints),
   `grid_checker`, `journal_checker`, `manifest_checker`, `reply_sequence.zig` (client replies),
   plus thousands of production `assert`s, which stay **on in production**.

### Seeing it run (real output)
```
$ ./zig/zig build vopr:build -Drelease
$ ./zig-out/bin/vopr 42                      # 3.07 s wall clock
          SEED=42
          replicas=4  standbys=3  clients=8
          packet_loss_probability=12/100
          packet_replay_probability=24/100
          read_fault_probability=1/100  write_fault_probability=2/100
          ...
 1   /  .          1V   0/__1/__1C   0:__4Jo  0/_0J!   0:_31Wo <__0:__0> v1:1     0Ga  0G!   0G?   3/4Pp  4/4Rq
 ...
          PASSED (5325 ticks)

$ sha256sum v42a.log v42b.log                # two runs of seed 42
0c242528b435feac...  v42a.log
0c242528b435feac...  v42b.log                # identical, all 888 lines
$ ./zig-out/bin/vopr 1337                    # different world: 4 replicas, 1 client, 7% loss
          PASSED (3162171 ticks)
```
Seeds 7, 99, 2024 and 31337 also passed (1,184,110, 203,984, 59,405 and 3,162,171 ticks).
The column legend is in `docs/internals/testing.md`. To find bugs, TigerBeetle runs the VOPR
continuously on many machines (VOPR Hub/CFO). A failure is filed as `(commit, seed)`.

---

## Part 3 — Ten projects, easy → hard

Each directory has `main.zig` (Zig 0.17, std only) and `NOTES.md`, which covers the concept,
what is simulated, the invariants, why normal tests miss the bug, the TigerBeetle parallel,
real outputs, and exercises. Every example uses the same CLI:

```sh
cd examples/NN-name
zig run -OReleaseSafe main.zig -- sweep <count> [--bug-flag]   # search seeds 0..count-1
zig run -OReleaseSafe main.zig -- run <seed> [--bug-flag]      # replay one seed, verbose
```

| # | Level | Project | New idea | Planted bug(s) → first failing seed |
|---|---|---|---|---|
| 01 | Easy | [Seeded randomness](examples/01-seeded-randomness) | One seed drives everything; biased generators; oracle | integer overflow in `average` → 0 |
| 02 | Easy | [Simulated time](examples/02-simulated-time) | Inject `Time`; jump the clock onto deadlines | TTL `>` vs `>=` → 1 |
| 03 | Easy–Med | [Deterministic scheduler](examples/03-deterministic-scheduler) | Tasks as state machines + a seeded scheduler replace threads | lost update → 0; deadlock → 1 |
| 04 | Medium | [Simulated disk & crashes](examples/04-simulated-disk-crashes) | Volatile write cache, fsync, torn writes, crash/recover loops | ack-before-fsync → 0; no checksum → 0 |
| 05 | Medium | [Simulated network](examples/05-simulated-network) | Packet simulator (delay/loss/dup/reorder), safety then liveness phase | no dedup → 0; stale reply → 0 |
| 06 | Medium | [Swarm testing & shrinking](examples/06-swarm-testing-and-shrinking) | Each seed picks its own op mix; minimize the failing case | resize on full ring → 21 with swarm; **never in 1,000,000 seeds without swarm**; shrinks 1000 ops → 33 |
| 07 | Med–Hard | [Linearizability checker](examples/07-linearizability-checker) | Record invoke/complete history; Wing & Gong search | stale backup reads → 1 |
| 08 | Hard | [Leader election under partitions](examples/08-leader-election-partitions) | Symmetric/asymmetric partitions, crash with persisted state | volatile `votedFor` → 86; reachable-majority quorum → 0 |
| 09 | Hard | [Storage fault atlas](examples/09-storage-fault-atlas) | Bit flips, misdirected writes, repair, scrubber, byte-identical checker; only inject faults that can be recovered | trust local read → 0; checksum without address → 1 |
| 10 | Hardest | [Mini-VOPR](examples/10-mini-vopr) | Everything combined: VSR-style log, swarm faults, canonical-commit checker, safety + liveness | commit before quorum → 3; bad view-change log choice → 3 |

### How the progression builds
- **01–02:** make inputs and time deterministic. That alone fixes most "flaky test" problems.
- **03:** make *concurrency* deterministic. The schedule is data, so a race becomes a printed list of steps.
- **04–05:** simulate the two hostile dependencies, disk and network. Learn the
  **safety phase vs liveness phase** split: under faults you check that nothing *wrong* happens,
  and after the heal you check that everything *eventually* happens.
- **06:** make the *search* better. Swarm testing beats a single fixed operation mix. Shrinking makes failures readable.
- **07:** make the *oracle* better. When ops are concurrent there is no single expected answer, so you check a history.
- **08–09:** the classic distributed-systems failures, with ideas taken straight from TigerBeetle
  (persisting votes/views before acting; checksums that cover the address; the fault atlas).
- **10:** a small version of `src/vopr.zig`. Read it side by side with the real thing.

### Verification done for this guide
Every example was compiled with Zig 0.17.0 (ReleaseSafe). For each one:
- the default sweep passes with no bug flag;
- every one of the 16 bug flags is found by its sweep;
- running the failing seed twice produced byte-identical output (sha256 compared).

See each `NOTES.md` for the full transcripts.

## Further reading
- `tigerbeetle/docs/internals/vopr.md`, `testing.md`, `vsr.md`
- https://sim.tigerbeetle.com, the simulator running in the browser
- TigerBeetle blog: *Simulation Testing for Liveness*; IronBeetle episode debugging a VOPR failure
- FoundationDB testing (https://apple.github.io/foundationdb/testing.html), Antithesis, and Will Wilson's talk *Testing Distributed Systems w/ Deterministic Simulation*
