# 06 — Swarm testing and shrinking

## Concept introduced

**Swarm testing.** A plain random test draws every operation from one fixed mix, for example
20% each of push, pop, peek, clear, and resize. So every seed explores the same "average"
part of the state space. In swarm testing, each seed first picks its own configuration:
how many operation kinds to enable (1..5), which ones (a random combination), and a random
weight 1..100 for each enabled kind. Seed 21 rolls `push=85 pop=3 peek=0 clear=0 resize=1`.
It almost never pops and never clears, so the queue fills up within 50 operations. The
uniform mix never gets close: with pop and clear at 40% combined, the queue stays shallow.
Many seeds with one lopsided config each cover more ground than one "fair" mix.

**Shrinking.** Seed 21 fails at operation 69 of 1000, and most of those operations do not
matter. The simulation is deterministic and the test case is an explicit list of operations
(generated up front, independent of queue state). So we can edit the list and replay it. The
shrinker:

1. truncates everything after the failing op,
2. deletes chunks of size len/2, len/4, …, 1 while the failure still reproduces,
3. simplifies arguments (push value → 0, resize capacity → minimum, initial capacity →
   minimum, then halfway) while the failure still reproduces,
4. repeats 2–3 until nothing changes.

"Still reproduces" means the **same failure kind** (`count_mismatch` here). Without that
rule, the shrinker can slide to a different, shallower bug and report a "minimal" example
of the wrong problem. The shrinker uses no randomness, so the same seed always shrinks to
the same output.

## What is simulated vs real

- Real: the ring-buffer code (`RingQueue`: push, pop, peek, clear, resize, get) and the
  oracle `Model`, a plain array that shifts on pop and has no indices to get wrong.
- Simulated: the workload. One `DefaultPrng` seeded from the seed number produces the swarm
  weights, the initial capacity (32..64), and 1000 operations with their arguments. Storage
  is a fixed `[64]u32` array, so there is no allocator, IO, clock, or thread.
- Every op, its argument, and its return value go into a Wyhash trace. The hashed value is a
  `[3]u64` array, not a tuple: a mixed-width tuple has undefined padding bytes, and an early
  draft of this example got different trace hashes for identical op lists because of that.

## Invariants

These are checked after every operation, not only at the end:

- **Return values:** push accepted/rejected, the value from pop and peek, and resize
  accepted/rejected must all match the model.
- **Refinement:** `queue.count == model.len`, and every element `queue.get(i)` equals
  `model.items[i]`, in order.
- **Structure:** `count <= cap`, `head < cap`, and `tail == (head + count) % cap`.

## The planted bug and why normal tests miss it

With `--bug`, `resize` recomputes the element count from the indices, as many ring buffers
without a `count` field do:

```zig
const n = if (bug_enabled) (q.tail + q.cap - q.head) % q.cap else q.count;
```

The formula is right in every state except a **completely full** queue. There
`tail == head`, so "full" looks exactly like "empty", and resize silently drops every element.
Capacity is never below 32, so the bug needs at least 32 net pushes with no clear in between,
followed by a resize that is not rejected.

- Hand-written unit tests use small queues or "push a few, pop a few". They pass.
- A uniform random mix is a random walk that a clear resets 20% of the time and a pop pulls
  down 20% of the time. In 1,000,000 seeds (10^9 operations), the deepest queue it ever
  reached was 21 items.
- Swarm finds it at seed 21, the 22nd seed. In the passing swarm sweep, 3272 of 20000 seeds
  reached 32 or more queued items.

## How TigerBeetle does this

- `options_swarm` in `src/vopr.zig` (line 374) draws every fault and workload probability per
  seed. For example, `.packet_loss_probability = ratio(prng.int_inclusive(u8, 30), 100)`
  gives anywhere from 0% to 30% packet loss, and `cache_entries_accounts` is
  `if (prng.boolean()) 256 else 0`. Some seeds run with no cache and some with no packet loss.
- `random_enum_weights` in `src/testing/fuzz.zig` (line 34) and `enum_weights` in
  `src/stdx/prng.zig` (line 516) work the same way: "some variants are disabled completely,
  and the rest have wildly different probabilities". `PRNG.Combination` (prng.zig line 540)
  picks a uniformly random subset of k kinds. `gen_weights` in this example is a direct port.
- They are used on data structures: in `src/queue.zig` (around lines 330–337) the fuzzer
  builds an enum of the queue's public API with `fuzz.DeclEnumExcludingType`, gets weights
  from `random_enum_weights`, and picks each step with `prng.enum_weighted`.
  `src/message_bus_fuzz.zig:58` does the same for message commands.
- Shrinking: I could not find an automatic shrinker in the TigerBeetle source (`rg -i shrink`
  under `src/testing` and in `vopr.zig` finds nothing). TigerBeetle gets small reproductions
  in two other ways:
  - **Overrides:** VOPR CLI flags (`CLIArgs` in `vopr.zig`: `--requests-max`,
    `--packet-loss-ratio`, `--ticks-max-requests`, `--lite`) let a developer replay a seed with
    less work or fewer faults, which is manual shrinking.
  - **Exhaustigen:** `src/testing/exhaustigen.zig` (used, for example, in the `k_way_merge:
    exhaustigen` test in `src/lsm/k_way_merge.zig`) lists every small input in order, so the
    first failure found is already small. The greedy shrinker here gets a similar small result
    from a large random failure.

## Verified run

Built with `/home/user/tools/zig-0.17.0/zig build-exe main.zig -O ReleaseSafe -femit-bin=/tmp/ex06`.
Each run of 20000 seeds took about 1–1.5 s.

Sweep without the bug (swarm, default):

```
$ /tmp/ex06 sweep 20000
PASS: 20000 seeds (3272 reached >= 32 queued items; deepest queue=64)
exit=0
```

Sweep with the bug, swarm, which finds it:

```
$ /tmp/ex06 sweep 20000 --bug
FAIL at seed=21 after 22 seeds. Replay with:
  zig run main.zig -- run 21 --bug
  zig run main.zig -- shrink 21 --bug
exit=1
```

Sweep with the bug and a uniform mix, which misses it, even with 50× the seeds:

```
$ /tmp/ex06 sweep 20000 --bug --no-swarm
PASS: 20000 seeds (0 reached >= 32 queued items; deepest queue=14)
exit=0

$ time /tmp/ex06 sweep 1000000 --bug --no-swarm
PASS: 1000000 seeds (0 reached >= 32 queued items; deepest queue=21)
real	0m41.631s
exit=0
```

Replaying the failing seed twice gives the same trace:

```
$ /tmp/ex06 run 21 --bug
seed=21 initial_cap=43 weights: push=85 pop=3 peek=0 clear=0 resize=1
  op 46: queue became full (count=cap=43)
  op 65: queue became full (count=cap=43)
  op 69: resize 43 -> 64 while FULL (count=43)
  op 69: count_mismatch: got=0 want=43
seed=21 max_count=43 trace=b3e7bd86bc13f598 FAIL
exit=1
$ /tmp/ex06 run 21 --bug
seed=21 initial_cap=43 weights: push=85 pop=3 peek=0 clear=0 resize=1
  op 46: queue became full (count=cap=43)
  op 65: queue became full (count=cap=43)
  op 69: resize 43 -> 64 while FULL (count=43)
  op 69: count_mismatch: got=0 want=43
seed=21 max_count=43 trace=b3e7bd86bc13f598 FAIL
exit=1
```

`zig run main.zig -- run 21 --bug` (Debug build) also prints `trace=b3e7bd86bc13f598 FAIL`.

Shrinking seed 21:

```
$ /tmp/ex06 shrink 21 --bug
shrink: seed=21 recorded 1000 ops, initial_cap=43
  op 69: count_mismatch: got=0 want=43
  truncate after failing op -> 70 ops
  round 1: delete -> 44 ops, simplified 45 args
  round 2: delete -> 33 ops, simplified 0 args
  round 3: delete -> 33 ops, simplified 0 args
minimal reproduction (33 ops, 360 replays):
  q = RingQueue.init(32)
  push(0) x32
  resize(32)   <- count_mismatch: got=0 want=32
seed=21 shrunk trace=98ce1d6defe82a39 FAIL
exit=1
```

Running the shrink twice gave byte-identical output (md5 `6eb4c00f39f26ac81f60dd894f46cb75`
both times). Other failing seeds (31 and 66) shrink to the same 33-op sequence with the same
trace `98ce1d6defe82a39`, which shows that the shrunk form describes the bug, not the seed. It
cannot get smaller: removing any push leaves the queue not full, and the bug does not fire.

## Extra output flags
These only add output for the visual site (`site/`). They draw nothing from the PRNG and are not hashed, so
sweeps and trace hashes are the same with or without them.

- `--ops`: `run`: print head/tail/count/cap after each op; `shrink`: print each kept deletion and the kept ops.

## Exercises

1. Fix the uniform mix by hand: make it 60% push. Does `--no-swarm` find the bug now? Then
   plant a second bug that needs many *pops* on a wrapped queue (for example in `pop` when
   `head` wraps). Can a single fixed mix find both? Does swarm find both without retuning?
2. Make the shrinker smarter: add a pass that replaces an op with a simpler kind (resize →
   peek, pop → peek) and see how many replays it saves. Or print the minimal sequence as a
   ready-to-paste Zig `test` block.
