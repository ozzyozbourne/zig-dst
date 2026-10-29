# 02 — Simulated time

## Concept introduced

**Never read the real clock.** The code under test asks a `Time` interface what time it is
(`Time.monotonic_ms()`). In production that interface would wrap the OS clock. In the
simulator it wraps `TimeSim`, which is just a tick counter (1 tick = 1 simulated ms) that moves
only when the simulator calls `advance()`. That gives you three things:

1. **Speed.** Waiting 12 hours costs one addition. No test ever sleeps.
2. **Reproducibility.** Time is part of the seed. Between two simulator steps, time stands
   still, so a replay sees exactly the same timestamps.
3. **Control.** The simulator can put time *anywhere*, including exactly on the boundaries
   where bugs live.

## What is simulated vs real

| Simulated | Real |
|---|---|
| The clock (`TimeSim.ticks`). Every TTL, deadline and "now" | The cache code (`TtlCache`), which runs unchanged |
| The order of operations and clock advances (one seeded PRNG) | The comparison logic, the swap-remove eviction loop |
| Workload: keys, values, TTLs (1 ms … 24 h) | — |

Clock advances come in five kinds (`gen_advance`): `small` (1–10 ms), `medium` (≤ 5 s),
`jump` (1–12 h), `on_deadline` (exactly onto a live entry's deadline), and `before_deadline`
(one tick before it). The last two read the model to find where the edges are.

The program never measures its own speed, because that would mean reading the wall clock. To
measure real time, run `time` on it from outside.

## Invariants

These are checked during the run, at the step where they apply, not only at the end:

- **Oracle on every `get`:** `cache.get(key)` must equal `model.get(key, now)`. The model is
  written differently on purpose. It stores `put_at` and `ttl` and asks
  `now - put_at < ttl`. The cache stores `deadline = put_at + ttl` and asks
  `now >= deadline`.
- **After every `evict_expired`:** no entry left in the cache is dead according to the model,
  and the cache's size equals the model's live count.
- **Time is monotonic:** `TimeSim.advance` asserts `ticks > 0`, and in ReleaseSafe the `+=`
  is overflow-checked.

## The planted bug and why normal tests miss it

With `--bug`, `TtlCache.expired` uses `now > deadline` instead of `now >= deadline`. An entry
stays alive for **exactly one extra clock unit**: the instant `now == deadline`. At every
other moment the cache behaves correctly.

A typical wall-clock test looks like this:

```
cache.put("k", v, ttl = 100ms); sleep(100ms); assert(cache.get("k") == null);
```

Whether that test catches the off-by-one depends on the clock's resolution, and you can't rely on it
either way. Measured on the orb (300 real runs: put with a 5 ms TTL, `time.sleep(5 ms)`, get;
data in `site/data/02/sleep-test.tsv`): with a nanosecond clock, 0 of 300 gets landed exactly on the
deadline; with the same timestamps truncated to milliseconds, 178 of 300 did. So the test either never
sees the bug or sees it about 60% of the time, at random:

- `sleep(d)` only promises to wait *at least* `d`. It overshoots by scheduler latency and timer
  slack (Linux's default timer slack alone is 50 µs; on a loaded CI box it can be milliseconds).
  Overshoot pushes `get` *past* the one-unit window.
- If the clock has nanosecond resolution (as TigerBeetle's `Instant` does), the window is
  1 ns wide and the overshoot is thousands of ns. The test cannot land on it.
- With a millisecond clock, landing on the window depends on where inside a millisecond `put`
  happened and how long the scheduler took. You get a test that fails once in a while on one
  machine and never reproduces. Usually someone "fixes" it with `sleep(ttl + 10ms)`, which
  guarantees the boundary is never tested again.
- To test a 6-hour TTL you would have to wait 6 hours, so nobody does.

The simulator does not depend on luck. It knows every deadline (from the model) and often jumps
time **exactly** onto one, then calls `get` or `evict_expired`. To measure how much this helps,
I ran a scratch experiment (in /tmp, not shipped) on seeds 0..999 with `--bug`:

| Clock-advance strategy | Seeds that hit the bug |
|---|---|
| Random advances only (`on_deadline`/`before_deadline` disabled) | 70 / 1000 (all from 1 ms TTLs and 1–10 ms steps) |
| With deadline targeting (the shipped code) | 357 / 1000 |

The random-only rate is still non-zero only because the simulator also makes 1 ms TTLs and
1 ms steps. Real time gives you neither.

## How TigerBeetle does this

- `src/stdx/time.zig`: `Time` (line ~17) is a `context` + `vtable` with `monotonic()` and
  `realtime()`. This example's `Time` has the same shape. `TimeOS` (line ~42) is the
  production implementation and reads the OS clocks. It panics if the monotonic clock goes
  backwards (`monotonic_guard`). `TimeSim` (line ~198) is the simulated one:
  `TimeSim.tick()` (line ~315) does `ticks += 1; monotonic.ns = ticks * tick_duration.ns`.
  It also models wall-clock drift through `offset()` with `OffsetType` `linear`, `periodic`,
  `step` (a discontinuous jump) and `non_ideal`.
- `src/vsr/clock.zig`: the replica `Clock` reads time only through a `Time`
  (`Clock.monotonic()`, `Clock.realtime()` at lines ~331–339). `realtime_synchronized()`
  (line ~346) clamps the local clock to a cluster-agreed interval. The header comment explains
  why raw system time cannot be trusted (it differs per replica, NTP moves it backwards, and it
  can drift while partitioned). The `ClockSimulator` at the bottom of the file tests the
  synchronization algorithm against `TimeSim` drift models.
- `src/vsr.zig` `Timeout` (line ~732): TigerBeetle protocol timeouts are counted in **ticks**,
  not nanoseconds. `fired()` is `ticks >= after_dynamic`, which is the same `>=` boundary this
  example protects. It also panics if `ticks > after`, meaning a timeout was not reset after it
  fired. That assertion exists to catch boundary mistakes.
- `src/testing/cluster.zig`: the VOPR cluster gives each replica and client its own `TimeSim`
  (`replica_times`, `client_times`, line ~259/309). `Cluster.tick()` calls `time_sim.tick()`
  before `replica.tick()` (lines ~559–581). Simulated time advances in lockstep with the
  simulation loop.
- `src/tigerbeetle/main.zig` (line ~113): production builds a `TimeOS` and passes
  `time_os.interface()` in. It is the same replica code with a different clock behind the
  interface.

## Verified run

Built with `/home/user/tools/zig-0.17.0/zig build-exe main.zig -O ReleaseSafe -femit-bin=/tmp/dst02`.

Sweep without the bug (default count 100000):

```
$ time ./dst02 sweep 100000
PASS: 100000 seeds, simulated 9498765621 s (2638546 h) of clock time

real	0m0.751s
user	0m0.749s
sys	0m0.000s
exit=0
```

**That is ≈ 1.26 × 10¹⁰ simulated seconds per real second.** 9,498,765,621 s of simulated
clock time ran in 0.751 s, which is about 400 simulated years per real second. Each seed
covers about 26 simulated hours on average. A sleep()-based test of the same coverage would
take about 300 years.

Sweep with the bug:

```
$ time ./dst02 sweep 100000 --bug
FAIL at seed=1 after 2 seeds. Replay with:
  zig run main.zig -- run 1 --bug

real	0m0.001s
user	0m0.000s
sys	0m0.000s
exit=1
```

Replay, run twice. The output and trace hash are identical:

```
$ ./dst02 run 1 --bug
  step 25 t=15612ms: clock +1638ms (on_deadline)
  step 27 t=17250ms: evict kept key 14, deadline 17250ms
seed=1 steps=28 simulated=17250ms trace=b51d0a68fc5da3f4 FAIL
exit=1
$ ./dst02 run 1 --bug
  step 25 t=15612ms: clock +1638ms (on_deadline)
  step 27 t=17250ms: evict kept key 14, deadline 17250ms
seed=1 steps=28 simulated=17250ms trace=b51d0a68fc5da3f4 FAIL
exit=1
```

The clock landed exactly on t=17250 ms, key 14's deadline. Eviction kept the entry, and the
after-eviction invariant caught it. `zig run main.zig -- run 1 --bug` (Debug build) prints
the same `trace=b51d0a68fc5da3f4`.

The same bug caught by the `get` oracle instead (seed 43). Two multi-hour jumps come first,
then a landing on the deadline:

```
$ ./dst02 run 43 --bug
  step 24 t=5665ms: clock +17971879ms (jump)
  step 26 t=17977544ms: clock +36561947ms (jump)
  step 93 t=54552913ms: clock +305ms (on_deadline)
  step 99 t=54553218ms: get(8) = 856363089, want null (deadline 54553218ms)
seed=43 steps=100 simulated=54553218ms trace=3895ccdfbbf7c6f1 FAIL
```

## Extra output flags
These only add output for the visual site (`site/`). They draw nothing from the PRNG and are not hashed, so
sweeps and trace hashes are the same with or without them.

- `--dump`: print each step's op, key, time and value, plus the cache's entries after the step.
- `--no-target`: turn off the on_deadline / before_deadline clock advances.

## Exercises

1. Add wall-clock drift. Give the cache a second reading, `realtime_ms()`, that drifts or
   steps backwards (like `TimeSim.OffsetType.step`), and plant a bug where expiry uses
   realtime instead of monotonic time. Which invariant catches it, and which advance kind
   triggers it?
2. Swap the system under test for a token-bucket rate limiter with `refill(now)`. Plant an
   off-by-one in the refill boundary, then measure how much `on_deadline` targeting improves
   the hit rate over random advances, using the same experiment as above.
