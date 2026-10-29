# 12 — Coverage marks and exhaustive generation

## Concept introduced

A sweep that passes tells you nothing about code it never reached. This example adds two tools
TigerBeetle uses to find out what a test actually exercised, and to reach what it missed:

- **Coverage marks.** Production code names its interesting branches (`marks.hit(.insert_fill_gap)`),
  and a test or a sweep checks that a *specific* branch was reached. The `coverage` mode prints how
  many seeds hit each mark, and `--require-all` fails when a mark was never hit.
- **Exhaustive generation of small inputs.** A port of `src/testing/exhaustigen.zig`, which
  follows matklad's *Generate All the Things*. Code written as "generate a random op sequence"
  is run against a `Gen` that, instead of returning random numbers, steps through **every**
  sequence of choices within the given bounds. On a tiny domain (7 blocks, 3 slots), every
  boundary case is reachable in 4 ops, and since sequences come out shortest first, the first
  failure is a minimal one.

Marks are about **traceability**, not coverage percentage. In matklad's words (in the
`marks.zig` header): "the important part is not that a log line is covered at all, but that we
can trace production code to a single minimal hand-written test which explains why the code
needs to exist." Here that loop closes: `exhaust` prints the minimal failing sequence for the
fill-gap fast path, and that sequence is the body of the `zig test` that checks
`marks.check(.insert_fill_gap)`.

```
zig run main.zig -- run      <seed>     [--bug-fill-gap] [--gen-boundaries]
zig run main.zig -- sweep    <count>    [--bug-fill-gap] [--gen-boundaries]   # default 100000
zig run main.zig -- coverage <count>    [--require-all] [--bug-fill-gap] [--gen-boundaries]
zig run main.zig -- exhaust  <max_len>  [--bug-fill-gap]
zig test main.zig
```

## What is simulated vs real

| Real (the code under test)                                   | Simulated / test harness                                     |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| `IntervalSet`: an extent set (the free-space map of a block allocator). It stores sorted, disjoint, non-touching `[lo, hi)` ranges in a fixed-capacity array, like a B-tree node, and must open slots, close slots (in-place compaction), coalesce neighbours, and split ranges | The workload: a seeded random generator (`random_op`), or the exhaustive `Gen` (`gen_op`) |
| The `marks` module and its 10 `marks.hit(...)` calls          | The model: a bitset over the whole block domain               |
| `error.NoSpace` when a new range or a split needs a slot and none is free | Configuration: random = 2^20 blocks (4 GiB of 4 KiB blocks), 32 slots, extents of 1..256 blocks, 100 ops/seed, 65% inserts. Exhaustive = blocks 0..7, 3 slots, ranges of 1..3 blocks |

The marks, each one placed at one branch of `insert` or `remove`:

| mark                | branch                                                                 |
| ------------------- | ---------------------------------------------------------------------- |
| `insert_disjoint`   | the new range touches nothing, so a slot is opened                     |
| `insert_full`       | ...but no slot is free: `error.NoSpace`                                |
| `insert_extend`     | it touches or overlaps exactly one range, which grows                  |
| `insert_coalesce`   | it touches several ranges, which merge (compaction)                    |
| `insert_fill_gap`   | **fast path**: it exactly plugs the hole between two neighbours         |
| `remove_miss`       | the removed range overlaps nothing                                     |
| `remove_trim`       | it cuts the ends off one or two ranges                                 |
| `remove_delete`     | it deletes whole ranges (compaction)                                   |
| `remove_split`      | it punches a hole in one range, so one slot becomes two                |
| `remove_split_full` | ...but no slot is free: `error.NoSpace`                                |

Determinism: each seed drives one `DefaultPrng`. `Gen` is deterministic by construction.
Every op, its result, and the resulting `len` are folded into a Wyhash trace. Exhaustive mode
hashes every op of every sequence into one `exhaust trace=`.

## Invariants

Checked after **every** operation in `Harness.check`:

1. **Shape.** `len <= capacity`, and every live slot holds a non-empty range inside the domain.
   Slots are sorted with a gap of at least one block between neighbours: touching ranges must
   have been fused, so the representation is canonical.
2. **Contents vs the model.** The number of blocks in the set equals the model's count, and
   `contains(x)` agrees with the model at the op's edges `lo-1, lo, hi-1, hi`, which is where
   off-by-ones live. In exhaustive mode the domain is tiny, so every block is compared after
   every op.
3. **Rejections.** `error.NoSpace` only happens when every slot is used, and it leaves the set
   unchanged.

At the end of each random seed, `check_final` checks that every range is fully present in the
model. Together with equal counts, that makes set == model exactly.

## The planted bug and why normal tests miss it

`--bug-fill-gap`: in the fast path for a range that exactly fills the hole between two
neighbours, the code fuses them into the right slot and deletes the left slot with a
**swap-remove** (`slots[i] = slots[len-1]; len -= 1`) where an ordered remove was needed. This
is correct whenever the right neighbour is the last interval, because then the last interval
*is* the fused range. A hand test like "insert [0,1), [2,3), then [1,2)" therefore passes. With
any interval after the hole, the array becomes unsorted. Then `search` (a binary search) gives
wrong answers, but the blocks are all still there, so a content-only check would not notice.
The shape check catches it immediately.

Why the random sweep misses it: under the uniform generator the fast path needs `lo` to equal
the left neighbour's `hi` exactly **and** `len` to equal the gap exactly, on a domain of 2^20
blocks. With these realistic weights that happens essentially never:

- `sweep 100000 --bug-fill-gap` **passes**, and `coverage 1000000 --bug-fill-gap` passes too.
  Its table shows `insert_fill_gap 0 0 <-- NEVER HIT`, the warning sign, and `--require-all`
  turns that into a failure.
- `run 3` and `run 3 --bug-fill-gap` give the same trace hash `a247b6028e137c30`. The bug is
  not just undetected, the buggy code never runs.
- `exhaust 4 --bug-fill-gap` finds it at length 4 after 56,200 sequences (175,444 ops, 8 ms),
  with the minimal sequence `insert [0,1), insert [2,3), insert [4,5), insert [1,2)`.
- Fixing the generator (`--gen-boundaries`: a quarter of the time `lo` copies an existing
  endpoint, and a quarter of the time `hi` snaps to the next endpoint above `lo`) makes
  `insert_fill_gap` reached in 82,999 of 100,000 seeds. The random sweep then finds the bug at
  seed 1, and 409 of seeds 0..499 catch it on their own.

Note that exhaustive mode has a blind spot of its own. At length 4 it hits `insert_full` only
42 times and `remove_split_full` only 24 times, out of 6.7M ops. The two tools are
complementary, and the coverage table is how you see which one covers what.

The CONVENTIONS rule "each bug flag must be found by the sweep" is broken on purpose here. The
default (uniform) sweep is *expected* to miss this bug. `exhaust 4` and
`sweep --gen-boundaries` are the modes that find it.

## How TigerBeetle does this

- **Marks:** `src/testing/marks.zig`. Production code wraps its logger,
  `const log = marks.wrap_log(stdx.log.scoped(.replica));` (`src/vsr/replica.zig`), and writes
  `log.mark.debug("{f}: send_commit: primary abdicating (view={})", ...)` in `send_commit`.
  Outside tests `log.mark` is just `base`, the normal logger. Under `builtin.is_test`, `record`
  bumps `global_state.mark_hit_count` when the format string contains the active mark's name.
  `src/vsr/replica_test.zig` pairs it with a single test, *"Cluster: network: partition 1-2
  (isolate primary, asymmetric, send-only)"*:
  `const mark = marks.check("send_commit: primary abdicating"); try c.request(2, 2); try mark.expect_hit();`.
  The receive-only variant asserts `expect_not_hit()` for the same mark. `replica.zig` has 9
  `log.mark` sites and `replica_test.zig` has 13 `marks.check` calls.
- **Exhaustive generation:** `src/testing/exhaustigen.zig` (`Gen.done`, `int_inclusive`,
  `range_inclusive`, `index`, `enum_value`, `shuffle`). It is used in
  `src/lsm/k_way_merge.zig` (`test "k_way_merge: exhaustigen"` enumerates every direction and
  every set of 3 streams with up to 2 keys each, and checks the merge) and in
  `src/trace/event.zig` (every `EventMetric` / `EventTiming` value, checking that no two get the
  same slot). Our `Gen` is a line-for-line port. `gen_op` uses `range_inclusive(lo + 1, ...)`
  so that `hi` depends on `lo`, the same pattern as the segments example in matklad's post.
- **Fuzzers next to exhaustive tests:** `k_way_merge.zig` also has a `FuzzTestContextType` that
  injects `error.Pending` with `prng.chance(ratio(5, 100))`. TigerBeetle runs both a random
  fuzzer and an exhaustive small-scope test on the same code, as this example does.

## Verified run

Built with Zig 0.17.0: `zig build-exe -OReleaseSafe main.zig` (as `site/tools/capture.sh 12`
does). `zig fmt --check main.zig` passes. `zig test main.zig`:

```
1/2 main.test.insert: a range that exactly plugs a hole fuses its neighbours...OK
2/2 main.test.remove: punching a hole in a full set is refused...OK
All 2 tests passed.
```

Sweep without the bug (default count, uniform generator):

```
$ /tmp/dst-bin/12 sweep
PASS: 100000 seeds (10000000 ops)
real	0m1.617s
```

Sweep with the bug. It **passes**, and that is the point:

```
$ /tmp/dst-bin/12 sweep 100000 --bug-fill-gap
PASS: 100000 seeds (10000000 ops)
real	0m1.667s

$ /tmp/dst-bin/12 coverage 1000000 --bug-fill-gap --require-all
PASS: 1000000 seeds (100000000 ops)
coverage: 1000000 seeds, generator=uniform
  mark                 seeds_hit        hits
  insert_disjoint        1000000    32023197
  insert_full            1000000    32593030
  insert_extend           317517      381452
  insert_coalesce            484         484
  insert_fill_gap              0           0   <-- NEVER HIT
  remove_miss            1000000    34797620
  remove_trim             127276      135888
  remove_delete            33856       34459
  remove_split             11033       11090
  remove_split_full        22526       22780
--require-all: FAIL, 1 mark(s) never hit
real	0m16.195s
exit=1
```

Exhaustive mode finds it:

```
$ /tmp/dst-bin/12 exhaust 4 --bug-fill-gap
exhaust: domain=0..7 capacity=3 ranges of 1..3 blocks, max_len=4
len=1 sequences=36 ops=36 hits: insert_disjoint=18 ... insert_fill_gap=0 ...
len=2 sequences=1296 ops=2592 hits: ... insert_fill_gap=0 ...
len=3 sequences=46656 ops=139968 hits: ... insert_fill_gap=115 ...
len=4 sequences=8212 ops=32848 hits: ... insert_fill_gap=89 ...
FAIL at len=4: sequence 8212 of this length, 56200 sequences and 175444 ops in total
minimal failing sequence (every shorter sequence passed), replayed:
  step op              mark                slots (live | stale)
     - start                                | · · ·
     1 insert [0,1)    insert_disjoint     [0,1) | · ·
     2 insert [2,3)    insert_disjoint     [0,1) [2,3) | ·
     3 insert [4,5)    insert_disjoint     [0,1) [2,3) [4,5) |
     4 insert [1,2)    insert_fill_gap     [4,5) [0,3) | [4,5)
INVARIANT VIOLATED: slots 0,1 out of order or touching: [4,5) then [0,3)
replay trace=262a5491113ac8ff
exhaust trace=d4b4290b4d04a09a FAIL
real	0m0.008s
exit=1
```

(The `len=` lines are cut short here. The full lines, with all 10 marks, are in
`site/data/12/exhaust4-bug.txt`.) On the correct code, `exhaust 5` checks all 62,193,780
sequences (309,191,940 ops) in 13.2 s: `PASS ... exhaust trace=5dddad567ca7f562 PASS`.
Running `exhaust 4 --bug-fill-gap` a second time prints byte-identical output (`diff` is empty,
apart from the `time` lines).

With the fixed generator, the correct code reaches every mark, and the sweep finds the bug:

```
$ /tmp/dst-bin/12 coverage 100000 --gen-boundaries --require-all
PASS: 100000 seeds (10000000 ops)
  ...
  insert_fill_gap          82999      174804
  ...
--require-all: every mark hit
real	0m10.569s

$ /tmp/dst-bin/12 sweep 100000 --gen-boundaries --bug-fill-gap
INVARIANT VIOLATED: slots 2,3 out of order or touching: [1040774,1040862) then [214004,319265)
FAIL at seed=1 after 2 seeds (124 ops). Replay with:
  zig run main.zig -- run 1 --gen-boundaries --bug-fill-gap
exit=1
```

Replay, run twice. Both outputs are byte-identical (sha256
`66c78418f6758e35f9706997826b92bfbd9b2b80e647c641106177a97f0cf5c4` for both). The tail:

```
$ /tmp/dst-bin/12 run 1 --gen-boundaries --bug-fill-gap
...
    22 insert [750148,750205)     insert_disjoint     10
    23 insert [214080,319061)     insert_fill_gap      9
INVARIANT VIOLATED: slots 2,3 out of order or touching: [1040774,1040862) then [214004,319265)
  slots: [55128,55143) [91179,131737) [1040774,1040862) [214004,319265) [359200,359376) [362475,362599) [750148,750205) [756918,757193) [777930,778175) | [1040774,1040862) · · · · · · · · · · · · · · · · · · · · · ·
marks: insert_disjoint=10 insert_full=0 insert_extend=5 insert_coalesce=0 insert_fill_gap=1 remove_miss=6 remove_trim=2 remove_delete=0 remove_split=0 remove_split_full=0
seed=1 ops=24 trace=45c5296705eb5176 FAIL
```

Second run: `seed=1 ops=24 trace=45c5296705eb5176 FAIL`.

## Exercises

1. **Make the marks a gate.** Add `coverage 100000 --require-all` (uniform generator) to a
   CI script and watch it fail on `insert_fill_gap`. Then try the other common fix, swarm-style
   small domains: choose `random_domain` per seed from {16, 1024, 2^20}. How many seeds does it
   need before every mark is hit?
2. **Exhaust smarter.** `exhaust 5` takes 13 s, and length 6 would take about 36 times longer.
   Make `gen_op` choose `lo` only among "interesting" points: 0, the domain end, and every
   existing endpoint ±1. How far does `max_len` get in the same time, and does it still find
   the bug at length 4?
