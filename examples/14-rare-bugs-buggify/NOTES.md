# 14 — Rare bugs and BUGGIFY

## Concept introduced

In the earlier examples almost every planted bug shows up at seed 0–3. Real bugs are rarely
that cooperative. The dangerous ones sit in **error-handling paths that rarely run**, and the
worst of those need **two** rare events in the right order. Under realistic fault rates a
random simulation reaches such a combination about once per hundred thousand seeds.

This example teaches two things:

1. **BUGGIFY: make rare paths common.** FoundationDB puts fault points *into the production
   code* (`if (BUGGIFY) bufferSize = 1;`, `if (BUGGIFY) return error;`). In simulation, each
   point is **active** for a run with probability 1/4, decided once per run. An active point
   **fires** with probability 1/4 each time it is reached. Every seed therefore turns on a
   different random subset of rare behaviours, and turns each one on hard. In this example the
   bug needs 290,088 seeds without BUGGIFY and 41 seeds with it.
2. **Seed stability: a failing seed is not a regression test.** Any change that consumes
   randomness differently (a new option, one more `random.int()`) makes the old seed run a
   completely different scenario. The fix is to pin the failure as a hand-written scenario that
   uses no PRNG, as TigerBeetle does in `src/vsr/replica_test.zig`.

The system under test is a **client-side batching writer**. The app appends numbered records.
The writer buffers them and flushes batches over a connection to a server, which stores record
`seq` at file offset `seq` (a positional write, so any retry is idempotent). The error paths:

| Rare path | What happens | Correct handling |
| --- | --- | --- |
| short write + retry | the disk persists only the first k records; the ack says `written = k` | drop k records from the buffer, retry the rest |
| timeout while a flush is in progress | no ack within 12 ticks (lost or slow request/ack) | resend the in-flight flush; ignore the late ack of the old attempt |
| buffer full while a reconnect is pending | connection reset, backoff 4..20 ticks, the app keeps appending | backpressure: the app blocks, nothing is dropped |

```
zig run main.zig -- run      <seed>  [--bug-stale-offset] [--buggify] [--extra-draw]
zig run main.zig -- sweep    <count> [--bug-stale-offset] [--buggify] [--extra-draw] [--start <seed>]   # default 2000000
zig run main.zig -- scenario         [--bug-stale-offset]
```

`--start S` makes the sweep try seeds S, S+1, …, which gives an independent search order.
`sweep` prints how often each rare path ran (`hits`) and in how many seeds (`seeds`); with
`--buggify` it also prints how often each BUGGIFY point was active and fired.

### Reading the log line

```
 tick event      detail                         | state after the event
   14 send       #4 off=7 n=3 retry             | base=7 buf=7..9 cap=16 flush=#4@6+3 dl=26 conn=up net=- disk=0123456............
```

- `base`: records below it are durable (the writer's view). `buf`: buffered seqs. `cap`: buffer capacity.
- `flush=#id@offset+count dl=deadline`: the flush the writer waits on. `-` means none.
- `conn`: `up`, or `rc@T` (reconnect at tick T). `net`: in-flight messages, `qN` = request #N, `aN` = ack #N.
- `disk`: one character per file offset: `.` empty, a digit (seq mod 10) means the right record
  is there, `X` means the wrong record.

## What is simulated vs real

| Real (the code under test) | Simulated |
| --- | --- |
| Writer: buffering, batching, linger, flush state machine (`Flush`), short-write retry, timeout resend, stale-ack filter, reconnect, backpressure | Time: a tick counter |
| Server: positional write, ack with `written` | Network: delay 1..`delay_max`, loss 1/1500, delay spike 15..40 ticks 1/1500, connection reset 1/2000 per request |
| BUGGIFY points inside writer and server code | Disk: short write 1/3000 per multi-record write |

The root PRNG draws the per-seed `Options` (records, append rate, batch size, buffer capacity,
linger, delay) and then four sub-seeds: app, network, disk, and BUGGIFY. BUGGIFY has its own
stream, so `run S` and `run S --buggify` have the same workload and differ only where a point
fires. For example, `run 40 --bug-stale-offset` passes and `run 40 --bug-stale-offset --buggify`
fails. In-flight messages live in a fixed array and are delivered in send order. Each event is
folded into a Wyhash trace.

BUGGIFY points (`enum Point`), each called as `if (sim.buggify(.point))` in production code:

| Point | Where | Effect when it fires |
| --- | --- | --- |
| `short_write` | server write path | persist only 1..n-1 records |
| `tiny_timeout` | writer, when arming the flush timeout | 2-tick timeout instead of 12 (a buggified knob) |
| `delay_ack` | server reply path | ack leaves 10..20 ticks late |
| `drop_connection` | writer send path | connection reset |
| `small_buffer` | writer knob at startup | capacity = one batch |
| `slow_reconnect` | writer reconnect | backoff × 5 |

## Invariants

Checked **during** the run:

1. **Placement** (every disk write, `server_on_request`): file offset p holds record p. A
   record written at the wrong offset fails the run immediately with `CORRUPTION`.
2. **Durability** (every ack, `writer_on_ack`): the writer never moves `base` past the file's
   contiguous written prefix.
3. **Writer shape** (assert): `appended == base + buf_len`, so the buffer is always exactly the
   non-durable suffix.

Checked at the end:

4. **Liveness**: every record is durable within 4000 ticks, and the file holds 0..n-1 in order.

Correct code passes all 2,000,000 seeds of the default sweep and 100,000 seeds with `--buggify`.
Under `--buggify`, 3,582 of those 100,000 seeds hit the dangerous combination (6,198 times in
total). So the
correct code really survives the path the bug needs, and the check is not passing for lack of
coverage.

## The planted bug and why normal tests miss it

`--bug-stale-offset`. After a short write the writer shrinks `flush.count` but does not advance
`flush.offset`:

```zig
// Rare path 1: a short write. Retry the rest of the batch.
flush.count -= written;
if (!bug_stale_offset) flush.offset += written;   // the bug: this line is missing
...
sim.send_request(sim.base, .retry);               // the retry sends from base: still correct
```

The retry itself is fine, because it sends from `base`. The stale field is read only by the
**timeout** path:

```zig
sim.send_request(flush.offset, .resend);          // resend the flush... to the OLD offset
```

So the bug needs rare path 1 and then rare path 2 on the same flush: a short write, then the
retry's request or ack lost or slow for longer than the timeout. Each path alone is correct and
covered: in the default sweep, 4,486 seeds hit a short-write retry and 75,118 hit a timeout
during a flush. Only 18 of the 2,000,000 seeds hit both in that order. A unit test for "short
write" passes, and so does a unit test for "timeout". From seed 0, the sweep first fails at
**seed 290,087**:

```
   13 write      off=6 wrote 1/4 SHORT          | ... flush=#3@6+4 dl=24 ... disk=0123456............
   14 short_ack  #3 written=1 of 4              | base=7 buf=7..9 ... flush=#3@6+4 dl=24
   14 send       #4 off=7 n=3 retry             | base=7 ... flush=#4@6+3 dl=26     <- offset still 6
   16 write      off=7 wrote 3/3                | ... disk=0123456789.........
   17 append     seq=11                         | ... net=a4                        <- ack #4 hit a delay spike
   26 timeout    #4 not acked                   | ...
   26 send       #5 off=6 n=3 resend            | ...                               <- records 7,8,9 sent to offset 6
   27 corrupt    offset 6 <- record 7           | ... disk=012345X789.........
```

### Measured: seeds to first failure, with and without BUGGIFY

Each search order k sweeps from seed `k * 10^12` (`--start`) until the first failure.

| | orders | min | median | mean | max |
| --- | --- | --- | --- | --- | --- |
| realistic rates | 24 | 1,792 | 92,190 | 142,020.7 | 414,065 |
| `--buggify` | 100 | 1 | 22.5 | 32.0 | 116 |

How often each rare path ran, per 1000 seeds (correct code):

| path | realistic (2,000,000 seeds) | `--buggify` (100,000 seeds) |
| --- | --- | --- |
| short_write_retry | 2.24 | 456.1 |
| timeout_in_flush | 38.2 | 1468.4 |
| full_while_reconnect | 0.62 | 168.0 |
| short_retry_then_timeout | 0.009 | 62.0 |

### Seed stability

`--extra-draw` adds one `random.int(u64)` before `Options.generate`, as if someone had added
an option. Nothing else changes, but seed 290,087 now draws different options and sub-seeds:

```
$ run 290087 --bug-stale-offset               -> seed=290087 ticks=28 trace=75ece4944c1a73ff FAIL
$ run 290087 --bug-stale-offset --extra-draw  -> seed=290087 ticks=88 trace=7d78d5b40043be59 PASS
$ run 290087                  (the fix)       -> seed=290087 ticks=39 trace=c47b797ef48655dd PASS
$ sweep 2000000 --bug-stale-offset --extra-draw -> FAIL at seed=229449 (corruption) after 229450 seeds
```

A test that runs "seed 290087 must pass" would keep passing even if the bug came back, because
after any such change that seed no longer reaches the short write. The bug is still there: the
sweep finds it again at seed 229,449, after another 0.7 s of searching.

The pinned version is `scenario` mode. It runs a fixed list of steps against the same production
code, with every delay equal to 1 tick and no PRNG:

```zig
const scenario = [_]Step{
    .{ .append = 4 },
    .{ .short_write_next = 2 },
    .{ .run = 3 },
    .{ .drop_acks = 1 },
    .{ .run = 20 },
    .{ .expect_durable = 4 },
};
```

It fails with the bug and passes without it. Because it uses no randomness, `--extra-draw`
cannot change it: `scenario --bug-stale-offset` and `scenario --bug-stale-offset --extra-draw`
print the same `trace=eb058ab7f2f28465`.

## How TigerBeetle does this

- **Swarm options, not BUGGIFY.** `options_swarm` in `src/vopr.zig` draws the *environment's*
  fault rates per seed, for example
  `.packet_loss_probability = ratio(prng.int_inclusive(u8, 30), 100)`,
  `.write_fault_probability = ratio(prng.range_inclusive(u8, 0, 10), 100)`,
  `.crash_fault_probability = ratio(prng.range_inclusive(u8, 80, 100), 100)`, and
  `.path_clog_probability = ratio(prng.int_inclusive(u8, 2), 100)`. Some seeds are therefore very
  hostile, which makes rare environment events common. FoundationDB goes one step further:
  BUGGIFY makes the *code* take rare branches (tiny timeouts, tiny buffers, slow replies), which
  a swarm over environment knobs cannot reach. This example uses both: realistic environment
  rates plus per-seed BUGGIFY points. The only BUGGIFY reference in TigerBeetle's tree is a
  comment in `src/vsr/replica.zig`: `// TODO(Buggify): skip updating the JV, since it isn't
  required for correctness.`
- **Storage fault injection.** `Storage.write_sectors_finish` in `src/testing/storage.zig` runs
  `if (storage.prng.chance(storage.options.write_fault_probability))` and then calls
  `fault_sector` on a sector chosen by `pick_faulty_sector`. The `StorageFaultAtlas` options
  (`faulty_wal_headers`, `faulty_grid`, …) keep faults within what the cluster can repair. This
  example's `env_write_len` is the same idea at the level of a short write.
- **Pinned scenarios.** `src/vsr/replica_test.zig` builds a `TestContext` with a fixed
  `seed: u64 = 123`, `path_clog_probability = Ratio.zero()`, and every `storage_fault_atlas`
  flag set to `false`. Faults happen only where the test names them:
  `t.replica(.B2).drop_all(.__, .bidirectional)`,
  `t.replica(.R_).drop(.C_, .outgoing, .reply)`, `t.replica(.A0).corrupt(.{ .client_reply = slot })`,
  then `t.run()` and `expectEqual(...)`. An example is "Cluster: repair: corrupt reply". This
  example's `Step` list (`short_write_next`, `drop_acks`, `run`, `expect_durable`) follows that
  style.
- **Coverage marks.** `src/testing/marks.zig` ties a log line in production code to the
  hand-written test that covers it (`marks.check("send_commit: primary abdicating")` …
  `mark.expect_hit()`). A scenario test can assert it really took the rare path. This example's
  scenario prints `short_retry_then_timeout=1` for the same purpose.

## Verified run

Built with Zig 0.17.0, `zig build-exe -OReleaseSafe main.zig` (`site/tools/capture.sh 14`).
`zig fmt --check main.zig` passes. A seed takes about 3 µs, so 2,000,000 seeds take about 6 s.

Sweep without a bug:

```
$ time /tmp/dst-bin/14 sweep
path short_write_retry hits=4489 seeds=4486 of=2000000
path timeout_in_flush hits=76406 seeds=75118 of=2000000
path full_while_reconnect hits=1243 seeds=1243 of=2000000
path short_retry_then_timeout hits=18 seeds=18 of=2000000
PASS: 2000000 seeds (from seed 0)
real	0m6.166s
```

Sweep with the bug at realistic fault rates, then with BUGGIFY:

```
$ /tmp/dst-bin/14 sweep 2000000 --bug-stale-offset
CORRUPTION: file offset 6 now holds record 7 (tick 27, request #5)
path short_write_retry hits=653 seeds=653 of=290088
path timeout_in_flush hits=11202 seeds=11020 of=290088
path full_while_reconnect hits=177 seeds=177 of=290088
path short_retry_then_timeout hits=1 seeds=1 of=290088
FAIL at seed=290087 (corruption) after 290088 seeds. Replay with:
  zig run main.zig -- run 290087 --bug-stale-offset
real	0m0.877s

$ /tmp/dst-bin/14 sweep 2000000 --bug-stale-offset --buggify
CORRUPTION: file offset 2 now holds record 3 (tick 40, request #5)
path short_write_retry hits=20 seeds=12 of=41
path timeout_in_flush hits=48 seeds=14 of=41
path full_while_reconnect hits=12 seeds=6 of=41
path short_retry_then_timeout hits=1 seeds=1 of=41
buggify short_write active_seeds=14 fired=24 of=41
buggify tiny_timeout active_seeds=4 fired=19 of=41
buggify delay_ack active_seeds=11 fired=37 of=41
buggify drop_connection active_seeds=13 fired=54 of=41
buggify small_buffer active_seeds=6 fired=2 of=41
buggify slow_reconnect active_seeds=14 fired=10 of=41
FAIL at seed=40 (corruption) after 41 seeds. Replay with:
  zig run main.zig -- run 40 --bug-stale-offset --buggify
```

In seed 40, the active points are `short_write delay_ack small_buffer`. `short_write` fired at
tick 21 (`wrote 1/3 SHORT`). `delay_ack` fired at tick 25 on the retry's ack. The timeout at
tick 36 resent to offset 2, and the run failed at tick 40 with `CORRUPTION: file offset 2 now
holds record 3`.

Replay, run twice. Both runs exit 1 and their outputs are byte-identical: both have sha256
`afee9e4ddd126af9e058a05cae9b31f049b1784caa97178720078452456107ca`. Full output of run 1:

```
$ /tmp/dst-bin/14 run 290087 --bug-stale-offset
seed=290087 records=19 append_gap=1..3 batch_max=5 capacity=16 linger=2 delay=1..3
  faults: short_write=1/3000 per write, loss=1/1500, spike=1/1500 (15..40 ticks), reset=1/2000 per send, timeout=12 ticks
  buggify: off
 tick event      detail                         | state after the event
    0 append     seq=0                          | base=0 buf=0..0 cap=16 flush=- conn=up net=- disk=...................
    2 append     seq=1                          | base=0 buf=0..1 cap=16 flush=- conn=up net=- disk=...................
    2 send       #1 off=0 n=2 first             | base=0 buf=0..1 cap=16 flush=#1@0+2 dl=14 conn=up net=- disk=...................
    3 append     seq=2                          | base=0 buf=0..2 cap=16 flush=#1@0+2 dl=14 conn=up net=q1 disk=...................
    4 append     seq=3                          | base=0 buf=0..3 cap=16 flush=#1@0+2 dl=14 conn=up net=q1 disk=...................
    5 append     seq=4                          | base=0 buf=0..4 cap=16 flush=#1@0+2 dl=14 conn=up net=q1 disk=...................
    5 write      off=0 wrote 2/2                | base=0 buf=0..4 cap=16 flush=#1@0+2 dl=14 conn=up net=- disk=01.................
    6 append     seq=5                          | base=0 buf=0..5 cap=16 flush=#1@0+2 dl=14 conn=up net=a1 disk=01.................
    6 ack        #1 written=2                   | base=2 buf=2..5 cap=16 flush=- conn=up net=- disk=01.................
    6 send       #2 off=2 n=4 first             | base=2 buf=2..5 cap=16 flush=#2@2+4 dl=18 conn=up net=- disk=01.................
    7 append     seq=6                          | base=2 buf=2..6 cap=16 flush=#2@2+4 dl=18 conn=up net=q2 disk=01.................
    9 append     seq=7                          | base=2 buf=2..7 cap=16 flush=#2@2+4 dl=18 conn=up net=q2 disk=01.................
    9 write      off=2 wrote 4/4                | base=2 buf=2..7 cap=16 flush=#2@2+4 dl=18 conn=up net=- disk=012345.............
   10 append     seq=8                          | base=2 buf=2..8 cap=16 flush=#2@2+4 dl=18 conn=up net=a2 disk=012345.............
   12 append     seq=9                          | base=2 buf=2..9 cap=16 flush=#2@2+4 dl=18 conn=up net=a2 disk=012345.............
   12 ack        #2 written=4                   | base=6 buf=6..9 cap=16 flush=- conn=up net=- disk=012345.............
   12 send       #3 off=6 n=4 first             | base=6 buf=6..9 cap=16 flush=#3@6+4 dl=24 conn=up net=- disk=012345.............
   13 write      off=6 wrote 1/4 SHORT          | base=6 buf=6..9 cap=16 flush=#3@6+4 dl=24 conn=up net=- disk=0123456............
   14 short_ack  #3 written=1 of 4              | base=7 buf=7..9 cap=16 flush=#3@6+4 dl=24 conn=up net=- disk=0123456............
   14 send       #4 off=7 n=3 retry             | base=7 buf=7..9 cap=16 flush=#4@6+3 dl=26 conn=up net=- disk=0123456............
   15 append     seq=10                         | base=7 buf=7..10 cap=16 flush=#4@6+3 dl=26 conn=up net=q4 disk=0123456............
   16 write      off=7 wrote 3/3                | base=7 buf=7..10 cap=16 flush=#4@6+3 dl=26 conn=up net=- disk=0123456789.........
   17 append     seq=11                         | base=7 buf=7..11 cap=16 flush=#4@6+3 dl=26 conn=up net=a4 disk=0123456789.........
   20 append     seq=12                         | base=7 buf=7..12 cap=16 flush=#4@6+3 dl=26 conn=up net=a4 disk=0123456789.........
   21 append     seq=13                         | base=7 buf=7..13 cap=16 flush=#4@6+3 dl=26 conn=up net=a4 disk=0123456789.........
   22 append     seq=14                         | base=7 buf=7..14 cap=16 flush=#4@6+3 dl=26 conn=up net=a4 disk=0123456789.........
   25 append     seq=15                         | base=7 buf=7..15 cap=16 flush=#4@6+3 dl=26 conn=up net=a4 disk=0123456789.........
   26 timeout    #4 not acked                   | base=7 buf=7..15 cap=16 flush=#4@6+3 dl=26 conn=up net=a4 disk=0123456789.........
   26 send       #5 off=6 n=3 resend            | base=7 buf=7..15 cap=16 flush=#5@6+3 dl=38 conn=up net=a4 disk=0123456789.........
   27 corrupt    offset 6 <- record 7           | base=7 buf=7..15 cap=16 flush=#5@6+3 dl=38 conn=up net=a4 disk=012345X789.........
CORRUPTION: file offset 6 now holds record 7 (tick 27, request #5)
paths: short_write_retry=1 timeout_in_flush=1 full_while_reconnect=0 short_retry_then_timeout=1
seed=290087 ticks=28 trace=75ece4944c1a73ff FAIL
```

Last line of run 2:

```
seed=290087 ticks=28 trace=75ece4944c1a73ff FAIL
```

`zig run main.zig -- run 290087 --bug-stale-offset` in the default Debug mode prints the same
`trace=75ece4944c1a73ff`.

Scenario mode:

```
$ /tmp/dst-bin/14 scenario                                   -> scenario=short-write-then-timeout ticks=23 trace=ef8e58044952d8e8 PASS
$ /tmp/dst-bin/14 scenario --bug-stale-offset                -> CORRUPTION: file offset 0 now holds record 2 (tick 15, request #3)
                                                                scenario=short-write-then-timeout ticks=15 trace=eb058ab7f2f28465 FAIL
$ /tmp/dst-bin/14 scenario --bug-stale-offset --extra-draw   -> scenario=short-write-then-timeout ticks=15 trace=eb058ab7f2f28465 FAIL
```

## Exercises

1. **Lazy activation.** FoundationDB decides whether a BUGGIFY line is active the first time
   that line runs, not up front. Change `Sim.buggify` to decide lazily. Does the
   seeds-to-first-failure distribution change? Why does seed 40 no longer fail the same way?
2. **Cheaper search without BUGGIFY.** Keep BUGGIFY off and make only the environment swarm
   like `options_swarm` (short-write rate 0..10%, loss 0..30% per seed). Measure the
   seeds-to-first-failure distribution again with `--start`. How close does it get to BUGGIFY,
   and which rare path does it still miss? (Hint: `tiny_timeout` is a code knob, not an
   environment rate.)
