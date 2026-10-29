# 04 — Simulated disk crashes: lost and torn writes

## Concept introduced

**The disk is part of the simulation.** You cannot crash a real disk in the middle of a write
whenever you like, but you can replace it with a byte array whose behavior you control:

- writes are whole **sectors** (64 B here, to keep records at 1–3 sectors; real disks use 512 B or 4 KiB);
- a write lands in a **volatile write cache** and becomes durable only on `fsync`, or earlier if
  the disk decides to write that sector back on its own (any sector, any order);
- a **crash** can land on any tick. Each cached sector is then applied or dropped on its own, so
  a multi-sector record can be fully lost, fully kept, or **torn** (e.g. new header, stale payload).

Each seed crashes and restarts the store 21–52 times (seeds 0–199; 35 for seed 0), and the full
invariant check runs after every restart.

## What is simulated vs real

| Real | Simulated |
|---|---|
| The WAL encoding, checksum, hash chain, and recovery loop (`Store.recover`) | The disk (`Disk`): durable bytes plus a volatile per-sector cache |
| The key-value table rebuilt from the log | Time (a tick counter), fsync latency (1–6 ticks), background writeback (15 %/tick) |
| | Power loss (`Disk.crash`): each cached sector is kept with a per-crash probability of 0–100 % |
| | Never-written sectors: filled with PRNG noise, so stale bytes are not conveniently zero |
| | The client and the oracle (`acked`, `in_flight`) |

All randomness comes from one `DefaultPrng(seed)`. The disk gets its own sub-seed, drawn from
that PRNG. Every put, fsync, ack, writeback, crash, and recovery is folded into a Wyhash trace.

## Invariants

Checked after **every** restart (`check_recovery`). The cheaper checks run on every ack and fsync:
an acked value is readable right away, and after fsync the cache is empty. The disk also asserts
that no two in-flight writes overlap.

1. **Durability.** Every acked put comes back unchanged and in order.
2. **No garbage.** Every recovered record is byte-for-byte a put the client actually issued.
3. **Exact state.** The recovered log equals the acked prefix followed by some prefix of the
   in-flight (unacked) puts. The key-value table equals a replay of that log. In-flight puts that
   survive become part of the oracle's history: "maybe committed" is a legal outcome for a put
   that was never acked.

## The planted bugs and why normal tests miss them

- `--bug-ack-before-fsync`: the store acks as soon as `write` returns. It still fsyncs a few
  ticks later, so the data *usually* becomes durable. It fails only when a crash lands between
  the ack and the fsync and drops that sector. Found at seed 0, crash #3: acked seq=17 lost.
- `--bug-no-checksum`: recovery checks only `seq`, `key` and `len`, then trusts the header.
  If the header sector of an in-flight record reached the disk but its payload sector did not,
  the stale payload bytes are replayed as the value. Found at seed 0, crash #4. In the correct
  run of the same seed, recovery stops at crash #4 with `checksum mismatch (TORN record)`. In the
  buggy run it replays seq=46 (garbage) and stops one record later.

Each seed has many crashes, so both bugs fail on every one of the first 200 seeds. That rate
comes from the simulated disk. Ordinary crash tests almost never hit either bug:

**Why `kill -9` tests rarely produce torn (or lost) writes.** `kill -9` kills the *process*, not
the *machine*. Bytes that `write()` has accepted already sit in the kernel page cache, and the
kernel flushes them later whether or not the process is still alive. After the restart, reads
are served from that same page cache. So:

- an ack-before-fsync store passes every kill -9 test, because the "volatile" data was never
  lost. Only power loss, a kernel panic, or a hypervisor kill throws away the page cache and the
  drive's cache;
- a `write()` system call copies its buffer into the page cache as one step from the reader's
  point of view, and the signal is delivered only when the syscall returns. A killed process
  leaves either a whole record or no record, never "header yes, payload no". Torn sectors need the
  *device* to lose power partway through writing back several sectors, in whatever order its
  firmware chose;
- even when a team does pull the power, it can do that a handful of times a day, at times it does
  not choose. The simulator does it 21–52 times per seed and thousands of times per second,
  at every possible point (mid-batch, mid-fsync, right after an ack), and every failure can be
  replayed from its seed.

## How TigerBeetle does this

- `src/testing/storage.zig` is the in-memory `Storage` used by the VOPR. `write_sectors()` (line
  ~576) queues a `Write` with `ready_at = now + write_latency()` and asserts that no two
  concurrent writes overlap. `step()` (~361) completes writes once their latency has passed;
  `write_sectors_finish()` (~609) copies the buffer into `memory` and may inject a
  `write_fault_probability` sector fault. **`reset()` (~274) is the crash:** it pops every
  pending write. If `crash_fault_probability` hits, it calls `fault_sector()` on a random sector
  in that write's range. Pending writes are thrown away (never applied), so a crash leaves the
  target either untouched or corrupted, the way a torn write would. `read_sectors_finish()`
  (~464) fills never-written sectors with PRNG bytes, the same idea as this example's noisy disk.
- `flush_sectors()` (~685) in the test storage only resets an `unflushed` counter. TigerBeetle's
  model is "a write is durable once its completion callback runs", and real durability comes from
  `O_DIRECT` (`src/io/linux.zig`, ~1496) plus explicit `fsync`. This example models the volatile
  cache explicitly instead, because that is where the ack-before-fsync bug lives.
- `src/testing/cluster.zig`, `replica_crash()` (~665): "Reset the storage before the replica so
  that pending writes can (partially) finish", then the replica is torn down. `replica_restart()`
  (~639) runs recovery from the same `Storage`.
- `src/vopr.zig`: `crash_fault_probability = ratio(range_inclusive(80, 100), 100)` (~473).
  `tick_crash_up()` (~1520) multiplies the crash probability by 10 while the replica has writes in
  flight, which aims crashes at the moments that matter.
- `src/vsr/journal.zig`: recovery (`recover()` ~941, `recover_headers()` ~960,
  `recover_prepares()` ~1076, `recover_slots()` ~1240) checks every header and prepare by
  checksum. `torn_prepares()` (~1359) recognizes a prepare torn by a crash and truncates it
  (`case_cut_torn`) rather than treating it as committed. The comment at ~117 explains why
  redundant headers must not all be written at once: "a crash could lead to a series of torn
  writes making the entire journal faulty."
- `src/vsr/message_header.zig`, `Prepare.parent` (~712): "A backpointer to the previous prepare
  checksum for hash chain verification." This example's `parent` field does the same job. It is
  load-bearing: with only the parent check removed (and checksums kept), the correct-mode sweep
  fails at seed 4, because a stale but intact record from an earlier life of the log was replayed
  (`garbage: recovered seq=294`).

## Verified run

Built with `/home/user/tools/zig-0.17.0/zig build-exe main.zig -O ReleaseSafe -femit-bin=/tmp/dst04`.
The same results come from `zig run -O ReleaseSafe main.zig -- …`.

Sweep, correct code (2.9 s wall time):
```
$ /tmp/dst04 sweep 2000
PASS: 2000 seeds
```

Sweep with each bug (exit code 1):
```
$ /tmp/dst04 sweep 2000 --bug-ack-before-fsync
FAIL at seed=0 after 1 seeds. Replay with:
  zig run main.zig -- run 0 --bug-ack-before-fsync

$ /tmp/dst04 sweep 2000 --bug-no-checksum
FAIL at seed=0 after 1 seeds. Replay with:
  zig run main.zig -- run 0 --bug-no-checksum
```

Replay, run twice. Identical output and trace:
```
$ /tmp/dst04 run 0 --bug-ack-before-fsync
tick   38: crash #1: cache sectors applied=10 dropped=0; recovered 15 records (acked 15, in-flight 0); stop: unexpected seq (never written, or header sector lost)
tick   39: crash #2: cache sectors applied=0 dropped=0; recovered 15 records (acked 15, in-flight 0); stop: unexpected seq (never written, or header sector lost)
tick   50: crash #3: cache sectors applied=1 dropped=3; recovered 16 records (acked 18, in-flight 0); stop: unexpected seq (never written, or header sector lost)
  INVARIANT VIOLATED: durability: acked put seq=17 key=1 was lost (18 acked, 16 recovered)
seed=0 crashes=3 acked=18 trace=05849ac5c0fa49b0 FAIL
$ /tmp/dst04 run 0 --bug-ack-before-fsync
tick   38: crash #1: cache sectors applied=10 dropped=0; recovered 15 records (acked 15, in-flight 0); stop: unexpected seq (never written, or header sector lost)
tick   39: crash #2: cache sectors applied=0 dropped=0; recovered 15 records (acked 15, in-flight 0); stop: unexpected seq (never written, or header sector lost)
tick   50: crash #3: cache sectors applied=1 dropped=3; recovered 16 records (acked 18, in-flight 0); stop: unexpected seq (never written, or header sector lost)
  INVARIANT VIOLATED: durability: acked put seq=17 key=1 was lost (18 acked, 16 recovered)
seed=0 crashes=3 acked=18 trace=05849ac5c0fa49b0 FAIL
```

```
$ /tmp/dst04 run 0 --bug-no-checksum
tick   38: crash #1: cache sectors applied=10 dropped=0; recovered 15 records (acked 11, in-flight 4); stop: unexpected seq (never written, or header sector lost)
tick   39: crash #2: cache sectors applied=0 dropped=0; recovered 15 records (acked 15, in-flight 0); stop: unexpected seq (never written, or header sector lost)
tick   50: crash #3: cache sectors applied=1 dropped=3; recovered 16 records (acked 16, in-flight 2); stop: unexpected seq (never written, or header sector lost)
tick  140: crash #4: cache sectors applied=1 dropped=4; recovered 46 records (acked 45, in-flight 2); stop: unexpected seq (never written, or header sector lost)
  INVARIANT VIOLATED: garbage: recovered seq=46 key=1 len=102 was never written by the client
seed=0 crashes=4 acked=45 trace=826972d8c8dd33cc FAIL
$ /tmp/dst04 run 0 --bug-no-checksum 2>&1 | tail -1     # second run
seed=0 crashes=4 acked=45 trace=826972d8c8dd33cc FAIL
```
(The full outputs of the two `--bug-no-checksum` runs had the same md5sum,
`d51e347a59761fcd4ce687c97a8af9a2`.)

The correct code on the same seed, for contrast (crash #4 now stops at the torn record):
```
$ /tmp/dst04 run 0 2>&1 | sed -n 4p
tick  140: crash #4: cache sectors applied=1 dropped=4; recovered 45 records (acked 45, in-flight 2); stop: checksum mismatch (TORN record)
$ /tmp/dst04 run 0 2>&1 | tail -1
seed=0 crashes=35 acked=843 trace=3985da6fcf7f0c84 PASS
```
Across seeds 0–199 of the correct code, recoveries stopped 1288 times on a checksum mismatch
(torn record), 9 times on a parent mismatch (stale record), and 6114 times on an unexpected seq.

## Exercises

1. Remove the `parent` check in `Store.recover` (keep the checksum) and sweep. Explain the
   failure at seed 4: which earlier life wrote the record that was replayed, and why its
   checksum was valid?
2. Add a **misdirected write** fault, like TigerBeetle's `write_misdirect_probability`: a cached
   sector lands on a different sector index. Which invariant catches it, and does the checksum
   alone suffice? (Hint: what if the record had also stored its own offset?)
