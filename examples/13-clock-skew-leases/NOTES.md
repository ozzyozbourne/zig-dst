# 13 — Clock skew and leader leases

## Concept introduced

**Many clocks that disagree.** Example 02 had a single clock, owned by the simulator. In a real
cluster every machine has its own clock. Each oscillator runs a little fast or slow (*drift*,
measured in parts per million), and the wall clock can also *jump* when NTP or an operator
steps it. A protocol that turns "5 s passed on my clock" into "5 s passed for everyone" is
safe only if it accounts for both.

The system under test is a 3-node cluster with **leader leases** for fast local reads:

- Writes go through the leader to a quorum (the leader plus 1 follower) before they commit.
- The leader stamps each heartbeat with its own clock reading `s`. A follower that accepts a
  heartbeat **promises** not to vote for, or become, another leader until `lease = 5000 ms`
  has passed on *its* clock, and acks with the stamp.
- With one ack, the leader holds a **lease** until `s + lease − margin` on *its* clock. While
  the lease is valid, it serves reads locally, without a quorum round trip.
- A new leader needs a quorum of votes, so at least one voter made a promise to the old leader.
  A newly elected leader first re-commits the newest value of every key it learned from its
  voters, then serves reads (the counterpart of Raft's no-op entry).

The correct code measures leases and promises with the **monotonic** clock. It shortens the
leader's lease by the worst-case drift over one lease plus a guard:

```
drift_margin = 2 · drift_bound · lease = 2 · 2000 ppm · 5000 ms = 20 ms
leader_lease = lease − drift_margin − guard = 5000 − 20 − 2 = 4978 ms
```

Why the factor 2: in the worst case the leader's clock is slow by `ρ` and a follower's is fast
by `ρ`. The leader's lease then lasts `L/(1−ρ)` in true time and the follower's promise
`lease/(1+ρ)`. Safety needs `L/(1−ρ) ≤ lease/(1+ρ)`, so `L ≤ lease·(1−2ρ/(1+ρ))`. Subtracting
`2ρ·lease` gives a little more room than that.

The drift bound of ±2000 ppm is exaggerated (a quartz oscillator is within about ±100 ppm) so
that one lease is 5000 ticks instead of 50 000. Safety depends on the drift accumulated over a
lease (up to 10 ms per node here) compared with the network delay (1–4 ms). That ratio is
similar to a real cluster, where ±200 ppm over a 10 s lease is 2 ms against a datacenter round
trip of 0.1–1 ms.

Run it:

```
zig run main.zig -- run   <seed>  [--bug-no-drift-margin] [--bug-wall-clock]
zig run main.zig -- sweep <count> [--bug-no-drift-margin] [--bug-wall-clock]   # default 5000
```

### Reading the log line

```
  tick node ev role term m=<monotonic ms> r=<realtime ms> detail
  5629 2 + L   3T m=5640.258 r=5602.393 until=10638.254 clock=mono
```

- `tick` is **true time** in ms, which only the simulator knows. `m=` and `r=` are that node's
  own monotonic and realtime clocks at that tick. In this line, node 2's monotonic clock is
  11 ms ahead of true time (it drifts at +2000 ppm).
- ev: `P` partition (isolate one node), `H` heal, `S` realtime step, `?` became candidate,
  `v` granted a vote, `*` became leader, `>` leader stepped down, `c` recovery committed (may now
  serve reads), `+` lease begins, `-` lease ends, `p` promise begins, `e` promise expired,
  `W` write committed, `r` lease read (only stale ones are printed).
- `until=` is the lease or promise deadline *on that node's lease clock*.
- A candidate's retries (one every 3–15 ms, each in a new term) are hashed but not printed.

## What is simulated vs real

| Real (the code under test)                                    | Simulated                                                   |
| ------------------------------------------------------------- | ----------------------------------------------------------- |
| Promise rule: no vote, no candidacy before `promise_until`    | True time: `Simulator.tick` (1 tick = 1 ms)                 |
| Lease computation from acked stamps (`heartbeat_ack`)         | Per-node `Clock`: drift rate and a realtime offset          |
| The margin (`Node.leader_lease_us`) and clock choice (`Node.lease_clock`) | Realtime steps (NTP-style), up to `step_max_ms`     |
| Quorum writes, recovery on election, lease reads              | Network: delay 1..`delay_max`, loss, partitions isolating one node |
|                                                               | Clients: one per node; writes at the leader, reads anywhere |

The nodes never read `Simulator.tick`. Once per tick, `Node.read_clock` gives each node its own
`mono` and `real` readings and asserts that `mono` strictly increases (TigerBeetle's TimeOS
panics when the monotonic clock regresses). Each node's `Clock` has the shape of TigerBeetle's
TimeSim:

- `monotonic = tick · 1000 · (1 + drift_ppm/10⁶)` µs. This is the **linear** offset model. Here
  the drift is in the oscillator, so both readings drift together.
- `realtime = monotonic + realtime_offset_us`. The offset starts at ±50 ms and moves with every
  **step** (TimeSim's `step` model). Monotonic is never stepped.

A seed first picks the options: `drift_mode` (`uniform` in ±2000 ppm, or `extremes`, which puts
every clock at exactly ±2000 ppm to test the edge of the bound), delay, loss, step rate and size,
and partition rate and length. It then derives sub-seeds for the fault PRNG, the network PRNG,
the client PRNG, and one PRNG per node for timeout jitter. Partitions isolate the current leader
3 times out of 4, because that is when a lease handover happens while the old leader is still
alive and nobody can tell it to stop. Messages are delivered in send order from a list. Every
event, delivered message, election retry, and lease read is folded into a Wyhash trace.

## Invariants

`Simulator.check_leases` runs on **every tick**. It checks in true time, as only the simulator
can:

1. **Lease exclusivity**: at most one node believes it holds a valid lease
   (`role == .leader and lease_clock() < lease_until`). Two at once is `LEASE OVERLAP`.
2. **Linearizable lease reads**: every read served under a lease returns the value of the
   latest committed write to that key (`Simulator.lease_read`). The check is per key: the
   checker records the true-time history of commits (value, committing node, tick) and keeps the
   newest. A lease read is local and happens at one instant, so it must return exactly that
   value. Otherwise the run fails with `STALE READ`.
3. (assert) Monotonic clocks never regress. One leader per term.

After the first violation the simulator keeps running, for at most 2000 ticks, while two leases
still overlap or the node that served a stale read still believes in its lease. The trace then
shows the whole overlap window and every stale read inside it. Sweep and run use the same code,
so the trace hash is the same either way.

The checker also records every **handover** (a lease starting on a different node from the
previous one) and its **gap**: the true time from the end of the old lease to the start of the new
one. The gap is negative when the leases overlap. Over 5000 seeds the correct code makes 7526
handovers. The tightest is 4 ticks. The summary line reports the tightest gap twice. `min_gap`
covers every handover. `expiry_gap` covers only handovers where the old lease ran out, as
opposed to its holder stepping down when it saw a higher term. Only the second kind depends on
drift and the margin.

To check that the margin is needed, and not just a decoration, I temporarily built two scratch
copies in /tmp (since deleted):

- With `drift_margin = 1 · drift_bound · lease` (half the margin) and no guard, the sweep fails
  with `lease_overlap` at seed 240, a seed in `extremes` mode.
- With the full `2·ρ·lease` margin and no guard, all 5000 seeds pass (tightest gap 4 ticks).

The factor of 2 is therefore necessary, and the 2 ms guard is slack on top of it.

## The planted bugs and why normal tests miss them

### `--bug-no-drift-margin`: the lease is not shortened

`Node.leader_lease_us` returns the full `lease`. This is correct when all clocks tick at the same
rate, and that is the situation in every test that runs on one machine with one clock. To fail,
a seed needs three things together: (1) the leader is isolated for longer than a lease, (2) its
clock is slower than **both** followers' clocks (the candidate and its voter must both have
expired promises), and (3) the drift difference times the lease exceeds the time it takes to elect
a new leader and give it a lease (about 4 message delays). The sweep first finds this at seed 43
(overlap of 3 ticks). Over 600 seeds, 21 fail, and 8 of those also serve stale reads. Seed 112
is the first of them.

Seed 112 (`extremes`: nodes 0 and 2 at +2000 ppm, leader node 1 at −2000 ppm):

```
   629 1 * L   1T m=627.742 r=643.301 votes=011         node 1 leads term 1
   631 1 + L   1T m=629.738 r=645.297 until=5627.742    lease: full 5000 ms on node 1's slow clock
   829 - P - ---- isolate=1 ticks=7156                  node 1 is cut off; it still believes in its lease
  5621 0 e C   2T m=5632.242 r=5530.418 promise_expired the fast followers' promises run out first
  5627 2 * L   3T m=5638.254 r=5600.389 votes=101       node 2 elected with node 0's vote
  5629 2 + L   3T m=5640.258 r=5602.393 until=10638.254 second lease: LEASE OVERLAP
  5632 2 W L   3T m=5643.264 r=5605.399 key=1 val=952   node 2 commits a new value of key 1
  5632 1 r L   1T m=5620.736 r=5636.295 key=1 val=30 ver=1.32 STALE   node 1 still serves the old one
  5640 1 - L   1T m=5628.720 r=5644.279 expired         11 ticks of overlap, 4 stale reads
```

With the correct code the same seed runs identically up to the handover. There, node 1's lease
ends at tick 5617 (`until=5605.742`, 22 ms earlier on its clock), and node 2's begins at 5629.
Ticks 5617–5628 have no lease holder, where the bug has an overlap of 11 ticks.

### `--bug-wall-clock`: leases measured with realtime

`Node.lease_clock` returns `real` instead of `mono`, for both the leader's lease and the
followers' promises. The margin is still there. Realtime is "the time" and it usually advances
like monotonic, so this passes every test that does not step the clock. A **backwards** step on
an isolated leader stretches its lease by the size of the step. A forwards step on a follower
shortens its promise (here that matters only if it lets both followers' promises run out early, because both the candidate and its voter must be free). The sweep
first fails at seed 37. Over 600 seeds, 30 fail, and 29 of those serve stale reads. Seed 96 has a single step, -99.167 ms on the
isolated leader node 0 at tick 4700:

```
   758 0 + L   1T m=758.838 r=728.110 until=5704.108 clock=real
  2340 - P - ---- isolate=0 ticks=7323
  4700 0 S L   1T m=4705.198 r=4575.303 step=-99.167ms
  7166 1 + L   2T m=7158.919 r=7175.986 until=12151.988 clock=real
LEASE OVERLAP: node 0 and node 1 both hold a lease at tick 7166 (true time)
STALE READ: node 0 read key 1 = 307 at tick 7190, but the latest committed write is 1270 (committed by node 1 at tick 7190)
  7228 0 - L   1T m=7235.994 r=7106.099 expired
summary: handovers=1 min_gap=-62 pair=0->1 expiry_gap=-62 expiry_pair=0->1 overlap_ticks=62 stale_reads=23 ...
```

With the correct code, node 0's lease ends at tick 7129. With the bug it ends at 7228, 99 ticks
later, almost exactly the 99.167 ms step.

## How TigerBeetle does this

- **Two clocks, one interface**: `src/stdx/time.zig` defines `Time` with `monotonic()` ("Always
  use a monotonic timestamp if the goal is to measure elapsed time. This clock is not affected
  by discontinuous jumps in the system time") and `realtime()` ("This clock is affected by
  discontinuous jumps in the system time"). `--bug-wall-clock` is the mistake those comments
  warn about.
- **TimeOS**: `TimeOS.monotonic` uses `CLOCK_BOOTTIME` on Linux, which keeps counting while the
  machine is suspended, unlike `CLOCK_MONOTONIC`. It also keeps a `monotonic_guard` and panics
  with "a hardware/kernel bug regressed the monotonic clock". `Node.read_clock` asserts the same.
- **TimeSim**: the simulated clock has `offset_type` = `linear` (`A·x + B`: drift per tick and an
  initial offset), `periodic` (`A·sin(x·π/B)`), `step` ("a discontinuous jump in the wall-clock
  time"), and `non_ideal` (periodic with a random phase plus random noise up to
  `offset_coefficient_C`). `TimeSim.tick` advances `monotonic` ideally and applies the offset
  only to `realtime`. This example uses the linear model in the oscillator (so monotonic drifts
  too, which leases must survive) and the step model on realtime.
- **Bounding clock error across the cluster**: `src/vsr/clock.zig` starts with "we don't use
  time to drive consensus, we use consensus to drive time". Replicas exchange ping/pong
  (`Clock.learn(replica, m0, t1, m2)`). The round trip is measured with `monotonic`, the remote
  clock is read with `realtime`, and the result is a clock offset with an error interval.
  `Clock.synchronize` runs Marzullo's algorithm (`src/vsr/marzullo.zig`) to find the smallest
  interval that a quorum of clocks agree on, starting from `clock_offset_tolerance_max` (10 s in
  `src/config.zig`) and halving it. `realtime_synchronized()` clamps the local realtime into that
  interval. The `Epoch` notes that it captures realtime "before we take any samples, to guard
  against any jumps in the system's realtime clock", and measures elapsed time with
  `epoch.until(clock)`, which uses monotonic. An epoch expires after `clock_epoch_max` (60 s),
  because "Gradual clock drift prevents us from using an epoch for more than a few seconds".
- **Distrusting the clock when it matters**: in `Replica.on_request` (`src/vsr/replica.zig`),
  the primary timestamps a batch with `self.clock.realtime_synchronized() orelse { ...
  primary_abdicate_timeout.start(); ... "dropping (clock not synchronized)" }`. If a primary
  cannot agree with a quorum on the time, it stops timestamping and eventually abdicates.
- **No leases**: TigerBeetle does not serve reads from a lease. Its timeouts
  (`vsr.Timeout`, `src/vsr.zig`) count local ticks, and correctness never depends on two
  replicas' clocks agreeing. This example shows what a design that does depend on that has to
  get right.

## Verified run

Built with Zig 0.17.0: `zig build-exe -OReleaseSafe main.zig -femit-bin=/tmp/dst-bin/13`. The
output below is from `site/tools/capture.sh 13`, in `site/data/13/`.

Sweep without a bug (5000 seeds, 13.4–13.7 s in two captures):

```
$ /tmp/dst-bin/13 sweep
PASS: 5000 seeds
coverage: handovers=7526 tightest_handover_gap=4 ticks lease_reads=60672550 commits=17434116 realtime_steps=17742
exit=0
```

(These numbers are from 5000 seeds. The 600-seed capture used for the site's chart has 359 seeds
with an expiry handover, and the tightest of those gaps is 9 ticks.)

Sweep with each bug:

```
$ /tmp/dst-bin/13 sweep 5000 --bug-no-drift-margin
FAIL at seed=43 (lease_overlap) after 44 seeds. Replay with:
  zig run main.zig -- run 43 --bug-no-drift-margin
exit=1

$ /tmp/dst-bin/13 sweep 5000 --bug-wall-clock
FAIL at seed=37 (stale_read) after 38 seeds. Replay with:
  zig run main.zig -- run 37 --bug-wall-clock
exit=1
```

The last lines of those two replays:

```
seed=43 ticks=12244 trace=8c045de5bbdbd080 FAIL
seed=37 ticks=17148 trace=9559a5f9ce773e31 FAIL
```

Replay of seed 112 with `--bug-no-drift-margin`, run twice. Both runs exit 1, and the outputs are
byte-identical: `cmp` reports no difference, and both have sha256
`107e7ff1835b6b322064042d8146de2270ff67c770cb412428051a8b424848a8`. Run 1, in full:

```
$ /tmp/dst-bin/13 run 112 --bug-no-drift-margin
seed=112 drift_mode=extremes drift_ppm=2000,-2000,2000 realtime_offset_ms=-41.711,+15.559,-37.865
  delay=1..1 loss=40/1000 steps=9/100000 per node per tick, up to 100ms
  partitions=44/100000 per tick, 1000..10736 ticks, healthy>=1573 ticks
  lease=5000ms drift_bound=2000ppm drift_margin=20.000ms guard=2.000ms leader_lease=5000.000ms clock=monotonic
  tick node ev role term m=<monotonic ms> r=<realtime ms> detail
   627 1 ? C   1T m=625.746 r=641.305 term=1
   628 0 v F   1T m=629.256 r=587.545 for=1
   628 2 v F   1T m=629.256 r=591.391 for=1
   629 1 * L   1T m=627.742 r=643.301 votes=011
   630 0 p F   1T m=631.260 r=589.549 leader=1 until=5631.260
   630 2 p F   1T m=631.260 r=593.395 leader=1 until=5631.260
   631 1 W L   1T m=629.738 r=645.297 key=0 val=0 ver=1.1 recovery
   631 1 W L   1T m=629.738 r=645.297 key=1 val=0 ver=1.2 recovery
   631 1 c L   1T m=629.738 r=645.297 recovered
   631 1 + L   1T m=629.738 r=645.297 until=5627.742 clock=mono
   636 1 W L   1T m=634.728 r=650.287 key=1 val=1 ver=1.3
   640 1 W L   1T m=638.720 r=654.279 key=1 val=2 ver=1.4
   642 1 W L   1T m=640.716 r=656.275 key=1 val=3 ver=1.5
   644 1 W L   1T m=642.712 r=658.271 key=1 val=4 ver=1.6
   649 1 W L   1T m=647.702 r=663.261 key=0 val=5 ver=1.7
   652 1 W L   1T m=650.696 r=666.255 key=0 val=6 ver=1.8
   666 1 W L   1T m=664.668 r=680.227 key=0 val=7 ver=1.9
   677 1 W L   1T m=675.646 r=691.205 key=1 val=8 ver=1.10
   681 1 W L   1T m=679.638 r=695.197 key=0 val=9 ver=1.11
   692 1 W L   1T m=690.616 r=706.175 key=0 val=10 ver=1.12
   696 1 W L   1T m=694.608 r=710.167 key=1 val=11 ver=1.13
   700 1 W L   1T m=698.600 r=714.159 key=0 val=12 ver=1.14
   705 1 W L   1T m=703.590 r=719.149 key=1 val=13 ver=1.15
   710 1 W L   1T m=708.580 r=724.139 key=0 val=14 ver=1.16
   725 1 W L   1T m=723.550 r=739.109 key=0 val=15 ver=1.17
   726 1 W L   1T m=724.548 r=740.107 key=1 val=16 ver=1.18
   739 1 W L   1T m=737.522 r=753.081 key=1 val=17 ver=1.19
   741 1 W L   1T m=739.518 r=755.077 key=1 val=18 ver=1.20
   748 1 W L   1T m=746.504 r=762.063 key=0 val=19 ver=1.21
   758 1 W L   1T m=756.484 r=772.043 key=1 val=20 ver=1.22
   760 1 W L   1T m=758.480 r=774.039 key=1 val=21 ver=1.23
   766 1 W L   1T m=764.468 r=780.027 key=1 val=22 ver=1.24
   768 1 W L   1T m=766.464 r=782.023 key=0 val=23 ver=1.25
   776 1 W L   1T m=774.448 r=790.007 key=0 val=24 ver=1.26
   791 1 W L   1T m=789.418 r=804.977 key=0 val=25 ver=1.27
   792 1 W L   1T m=790.416 r=805.975 key=1 val=26 ver=1.28
   809 1 W L   1T m=807.382 r=822.941 key=1 val=27 ver=1.29
   826 1 W L   1T m=824.348 r=839.907 key=1 val=28 ver=1.30
   827 1 W L   1T m=825.346 r=840.905 key=0 val=29 ver=1.31
   829 - P - ---- isolate=1 ticks=7156
   829 1 W L   1T m=827.342 r=842.901 key=1 val=30 ver=1.32
  1633 0 S F   1T m=1636.266 r=1534.442 step=-60.113ms
  5621 0 ? C   2T m=5632.242 r=5530.418 term=2
  5621 2 ? C   2T m=5632.242 r=5594.377 term=2
  5621 0 e C   2T m=5632.242 r=5530.418 promise_expired
  5621 2 e C   2T m=5632.242 r=5594.377 promise_expired
  5626 0 v F   3T m=5637.252 r=5535.428 for=2
  5627 2 * L   3T m=5638.254 r=5600.389 votes=101
  5628 0 p F   3T m=5639.256 r=5537.432 leader=2 until=10639.256
  5629 2 W L   3T m=5640.258 r=5602.393 key=0 val=29 ver=3.1 recovery
  5629 2 W L   3T m=5640.258 r=5602.393 key=1 val=30 ver=3.2 recovery
  5629 2 c L   3T m=5640.258 r=5602.393 recovered
  5629 2 + L   3T m=5640.258 r=5602.393 until=10638.254 clock=mono
LEASE OVERLAP: node 1 and node 2 both hold a lease at tick 5629 (true time)
  5632 2 W L   3T m=5643.264 r=5605.399 key=1 val=952 ver=3.3
  5632 1 r L   1T m=5620.736 r=5636.295 key=1 val=30 ver=1.32 STALE
STALE READ: node 1 read key 1 = 30 at tick 5632, but the latest committed write is 952 (committed by node 2 at tick 5632)
  5633 1 r L   1T m=5621.734 r=5637.293 key=1 val=30 ver=1.32 STALE
  5635 1 r L   1T m=5623.730 r=5639.289 key=1 val=30 ver=1.32 STALE
  5636 1 r L   1T m=5624.728 r=5640.287 key=1 val=30 ver=1.32 STALE
  5640 1 - L   1T m=5628.720 r=5644.279 expired
summary: handovers=1 min_gap=-11 pair=1->2 expiry_gap=-11 expiry_pair=1->2 overlap_ticks=11 stale_reads=4 lease_reads=2540 commits=35 elections=4 steps=1
seed=112 ticks=5640 trace=48931e3b549bf699 FAIL
```

Last line of run 2:

```
seed=112 ticks=5640 trace=48931e3b549bf699 FAIL
```

The `--bug-wall-clock` replay of seed 96 is also byte-identical on two runs (sha256
`b3054d44d897eae073c58157cbea44c3936bd2af1d7d9c5df2b20b0df5712259`) and ends with
`seed=96 ticks=7228 trace=2d3ce8d2f23ec0e8 FAIL`. A Debug build (`zig build-exe main.zig`,
the mode `zig run` uses) prints the same trace hashes for both replays, so the trace does not
depend on the optimization mode.

## Exercises

1. **Measure the margin you actually need.** Make the margin a command-line value and sweep it
   in steps of 1 ms, with `drift_mode` forced to `extremes`. Find the smallest margin that passes
   5000 seeds and compare it with `2ρ·lease/(1+ρ)`. Then remove the `extremes` mode and repeat:
   how many seeds does uniform drift alone need before it finds the same boundary?
2. **Synchronize, then distrust.** Add a periodic offset to realtime (TimeSim's `periodic`
   model) and have each node estimate the other nodes' offsets with ping/pong, as `Clock.learn`
   does. Use the estimate to refuse leases when a quorum of clocks disagree by more than the drift
   budget. Which of the two bugs does this catch, and which can it never catch?
