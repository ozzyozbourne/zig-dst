# 01 — The seed is everything

## Concept introduced
A randomized test whose **only** source of randomness is a PRNG seeded from a number
that gets printed. That number is then a complete bug report: replay the seed and you get
the same inputs, the same failure, and the same trace hash.

Everything else in this guide builds on this rule. Time, threads, disks and networks are
all just more things that must be driven from the seed.

## What is simulated vs real
- Real: the function under test, `average(a, b)`.
- Simulated: the inputs. A *biased* generator draws mostly small values (98%), sometimes
  any u32 (1%), and sometimes values near `maxInt(u32)` (1%).

## Invariants
- Oracle: `average(a, b) == (u64(a) + u64(b)) / 2`. The oracle computes the answer in a
  wider type, so it can't overflow.

## The planted bug and why normal tests miss it
`--bug` computes `(a + b) / 2`, which overflows when `a + b > 2^32 - 1`. Hand-written tests
use values like `average(2, 4)`, and those pass. A uniform random generator would hit the
bug about half the time, which hides the real lesson: **you have to generate the inputs that
matter**. Under the biased generator, 84 of the first 1000 seeds fail.

## How TigerBeetle does this
- `src/vopr.zig` `main`: `seed = parse_seed(arg) orelse crypto_random_int(...)`, then
  `var prng = stdx.PRNG.from_seed(seed)`. Every option and every sub-seed is derived from
  that one PRNG (`options_swarm`), and the seed is printed first (`SEED=…`).
- When a run fails, it logs `you can reproduce this failure with seed={}`.
- `src/testing/fuzz.zig` has helpers for biased distributions (`random_int_exponential`,
  `range_inclusive_ms`).

## Verified run (Zig 0.17.0, ReleaseSafe)
```
$ dst01 sweep 10000
PASS: 10000 seeds
$ dst01 sweep 10000 --bug
FAIL at seed=0 after 1 seeds. Replay with:
  zig run main.zig -- run 0 --bug
$ dst01 run 0 --bug
  step 1: average(274594, 4294967283) = 137290, want 2147620938
seed=0 steps=2 trace=5e8db608ab3a4b37 FAIL
$ dst01 run 0 --bug
  step 1: average(274594, 4294967283) = 137290, want 2147620938
seed=0 steps=2 trace=5e8db608ab3a4b37 FAIL
$ dst01 run 0
seed=0 steps=3 trace=842142446d687ff3 PASS
```
Note that `run 0` without `--bug` takes a different number of steps. The buggy run stops
at the first failure, but both runs see the same inputs up to that point.

## Exercises
1. Replace `gen_value` with a uniform `random.int(u32)`. How often do seeds fail now?
   Then make the edge bucket 0.01%. How large a sweep do you need to find the bug?
2. Add a second source of randomness: read the clock with `std.time` and mix it into the
   seed. Run `run 0 --bug` twice and watch the replay guarantee disappear.
