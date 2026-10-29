# 09 — Storage faults, the fault atlas, and the storage checker

## Concept introduced

**Disk fault injection that the system can survive.** Earlier examples injected faults into the
network and into processes. This one injects them into the disk:

- **write faults**: a bit flips while the block is written;
- **read faults**: a bit flips in the buffer returned by a read, but the disk stays intact;
- **bit rot**: a bit flips in data at rest, between operations;
- **misdirected writes**: a well-formed block is written to the *wrong address*. The intended slot
  keeps its old content and some other block is overwritten.

A replicated system survives this with checksums and repair. Every block carries a checksum.
Every read verifies it, and on a mismatch the replica fetches the block from a peer.

The difficulty is that **a fault injector can easily produce faults that no system could
survive.** Flip the same block on all three replicas and the data is gone. That is not a bug.
It is a scenario outside the fault model. A simulator that does this reports a "failure" the
developers can do nothing about, and soon nobody trusts the simulator.

### The fault atlas

The fix is to decide, **before the run starts**, where each replica is allowed to fail. This
decision is the *fault atlas*:

```
atlas replica 0: xxx.xxx.xx.x...xx.xxxxxx.xxx.xxx     x = this replica's storage may corrupt
atlas replica 1: ..xx.x.xx.x.xxx..x....xxx...x.x.         or misdirect this block
atlas replica 2: xx.xx.xx.xxxxxxxxxxxxx..xxxxxx.x     . = this replica's copy is never faulted
```

For every block (column), at most `replica_count - 1` replicas are marked `x`, so **every column
has at least one `.`**. All fault injection (write flips, read flips, rot, and both ends of a
misdirect) is restricted to `x` cells. Faults can therefore be as frequent and harsh as we like,
and every block still has a good copy somewhere. So:

- every block is repairable, which we can assert as a **liveness** property;
- any failure the simulator reports is a real bug in the system, never bad luck.

The atlas is drawn from the seed, so different seeds put the "weak spots" in different places
while each run stays fully reproducible. The harness also re-checks the atlas promise every tick
(`check_atlas`: some replica holds the exact expected bytes of every written block). If that check
fails, the test harness is broken, so it panics instead of blaming the system.

## What is simulated vs real

| Simulated | Real |
|---|---|
| 3 replicas, each disk an in-memory array of 32 × 64-byte blocks | The checksum, verification, repair, and scrubber logic |
| Time (a tick counter, 600 ticks plus a final phase) | The actual corrupted bytes. Flips really change the disk array, so verification is really tested |
| Network: peer reads are direct function calls, with no loss or delay | The byte-for-byte storage comparison |
| Fault rates per seed ("swarm testing"): read 0–20%, write 0–20%, misdirect 0–15%, rot 0–10% | |
| An oracle (`expected[]`) that remembers what was appended | |

Block layout: `[checksum u64][payload 56 bytes]`. The block's address is *not* stored in it. It
is implied by the block's position on disk, which is exactly why the checksum has to cover it.
The log is append-only, so an address is written once and later writes are only repairs.

## Invariants

1. **Safety (checked on every client read):** the payload returned to a client equals what was
   appended. → `CorruptDataReturned`
2. **Storage checker (every 100 ticks and at the end):** at a checkpoint, fault injection pauses,
   every replica scrubs its whole log, and then the replicas' logs must be **byte-identical**
   (a Wyhash of all written blocks plus their addresses). → `StorageMismatch`
3. **Liveness:** every repair finds a verified copy on some peer (→ `Unrepairable`). In the final
   phase, faults are switched off for good (TigerBeetle's "liveness mode"), everything is repaired,
   the storage checker runs, and every block is read from every replica.
4. **Harness self-check:** the atlas holds every tick (panics, because a failure here is a test bug).

## The planted bug(s) and why normal tests miss them

### `--bug-trust-read`: the local read path skips verification

The replica returns whatever its own disk gave it. The repair path and the scrubber still verify,
which makes the bug easy to miss in code review: "we do verify checksums".

Why normal tests miss it: with a disk that never lies, skipping a check that always passes
changes nothing. Unit tests of the checksum function pass, and so do integration tests on a real
SSD, which corrupts data perhaps once in many terabytes. The bug only shows up when a corrupted
block is read through the local path *before* the scrubber gets to it. In seed 0, rot flips a bit
of block 1 on replica 0 at t=16, and a client reads it there at t=27.

### `--bug-misdirect`: the checksum covers only the payload, not the address

A misdirected write puts block 2's bytes into block 1's slot. That block is internally
consistent: its checksum matches its payload. If the checksum does not cover the address, block 1
now "verifies" and the reader gets block 2's data. The scrubber also finds nothing wrong, so the
damage is permanent. Seed 1 shows the client read returning wrong data. Seed 12 shows the same
bug caught later by the storage checker instead (replica 1's block 30 differs from its peers
after the checkpoint repair sweep).

Why normal tests miss it: bit-flip testing passes, because any flipped bit breaks the checksum.
You need a fault model that produces *valid-looking data in the wrong place*. On real hardware
that is roughly an order of magnitude rarer than bit rot (see the comment in TigerBeetle's
`storage.zig`). With the fix, the checksum is `hash(address ‖ payload)`, so a block in the
wrong slot fails verification like any other corruption. Seed 1 without the bug shows
`fault_misdirect replica=2 block=2 1` at t=7 followed by `repair replica=2 block=1` at t=15.

## How TigerBeetle does this

- **`src/testing/storage.zig`**, header comment: storage "injects faults that a fully-connected
  cluster can (i.e. should be able to) recover from". For `wal_headers`/`wal_prepares` and `grid`,
  faults "are distributed between replicas according to ClusterFaultAtlas, to ensure that at least
  one replica will have a valid copy". With `replica_count=1`, WAL and grid read/write faults are
  disabled (the WAL can still be corrupted by a crash). Grid faults are disabled when
  `replica_count≤2`.
- **`ClusterFaultAtlas.init`** (same file): for every chunk (WAL header sector, client-reply slot,
  grid block) it picks `faults_max = quorums.replication - 1` replicas as faulty and "never
  corrupt[s] all chunks of a particular replica". Our `FaultAtlas.init` follows the same loop. We
  use the looser bound `replica_count - 1` because our system only needs one good copy, while
  TigerBeetle's doc comment requires validity at a majority so that VSR recovery works.
- **Misdirected writes** (`Storage.overlays` doc comment and `write_sectors_finish_overlay_misdirect`):
  the whole write is misdirected within the same zone, and `faulty_chunk_offset` chooses the wrong
  target only among the *same replica's faulty chunks*. We do the same in `misdirect_target`, which
  is what keeps misdirects inside the atlas. The comment also explains the goal: "test how
  TigerBeetle handles well-formed but incorrectly-located data".
- **Address in the checksum:** grid block headers store `address`, and the header checksum covers
  the header. `read_block_validate` in `src/vsr/grid.zig` checks `valid_checksum()`, the body
  checksum, and that the checksum equals the one the reader expected (from the parent reference),
  then asserts `header.address == expect.address`. A misdirected block therefore cannot pass.
- **Scrubber:** `src/vsr/grid_scrubber.zig` reads the grid in the background to find latent sector
  errors "proactively" before a double fault makes a block unrecoverable. Our `scrub_step` is a
  tiny version of this.
- **`src/testing/cluster/storage_checker.zig`:** at each checkpoint (`replica_checkpoint` →
  `check`), it computes checksums of the superblock checkpoint state, the client replies, and the
  acquired grid blocks. `checksum_grid` also mixes in each block address as an "extra guard
  against identical blocks", as we do. It returns `error.StorageMismatch` if another replica
  recorded a different value for the same checkpoint op.
  Difference: TigerBeetle keeps `Storage.memory` pristine and tracks faults in a side bitset and
  overlays, so the checker can compare intended bytes at any time. Our disks hold real corrupted
  bytes, so we pause faults and repair everything first.
- **`Storage.transition_to_liveness_mode`** sets all fault probabilities to zero. It is the model
  for our final phase.

## Verified run

Built with `/home/user/tools/zig-0.17.0/zig build-exe -O ReleaseSafe main.zig -femit-bin=/tmp/dst09`
and run as `/tmp/dst09 <args>`. This is the same program as `zig run main.zig -- <args>`. The
command `zig run -O ReleaseSafe main.zig -- run 0 --bug-trust-read` printed the same trace,
`ed1a70000c0e0d2e`.

Sweep without bugs (default count 10000, 9.9 s):
```
$ /tmp/dst09 sweep
PASS: 10000 seeds
```
(A sweep of 100000 seeds also passed, in 69 s.)

Sweep with `--bug-trust-read`:
```
$ /tmp/dst09 sweep 10000 --bug-trust-read
FAIL at seed=0 (CorruptDataReturned) after 1 seeds. Replay with:
  zig run main.zig -- run 0 --bug-trust-read
```

Replay, twice:
```
$ /tmp/dst09 run 0 --bug-trust-read
  faults: read=0% write=20% misdirect=1% rot=10%
  atlas replica 0: xxx.xxx.xx.x...xx.xxxxxx.xxx.xxx
  atlas replica 1: ..xx.x.xx.x.xxx..x....xxx...x.x.
  atlas replica 2: xx.xx.xx.xxxxxxxxxxxxx..xxxxxx.x
  t=  8 fault_rot        replica=2 block= 0 101
  t=  9 scrub_repair     replica=2 block= 0 0
  t=  9 repair           replica=2 block= 0 0
  t= 16 fault_rot        replica=0 block= 1 5f
  t= 27 FAIL CorruptDataReturned: replica=0 block=1
seed=0 trace=ed1a70000c0e0d2e FAIL CorruptDataReturned
$ /tmp/dst09 run 0 --bug-trust-read
  faults: read=0% write=20% misdirect=1% rot=10%
  atlas replica 0: xxx.xxx.xx.x...xx.xxxxxx.xxx.xxx
  atlas replica 1: ..xx.x.xx.x.xxx..x....xxx...x.x.
  atlas replica 2: xx.xx.xx.xxxxxxxxxxxxx..xxxxxx.x
  t=  8 fault_rot        replica=2 block= 0 101
  t=  9 scrub_repair     replica=2 block= 0 0
  t=  9 repair           replica=2 block= 0 0
  t= 16 fault_rot        replica=0 block= 1 5f
  t= 27 FAIL CorruptDataReturned: replica=0 block=1
seed=0 trace=ed1a70000c0e0d2e FAIL CorruptDataReturned
```

Sweep with `--bug-misdirect`:
```
$ /tmp/dst09 sweep 10000 --bug-misdirect
FAIL at seed=1 (CorruptDataReturned) after 2 seeds. Replay with:
  zig run main.zig -- run 1 --bug-misdirect
```

Replay, twice:
```
$ /tmp/dst09 run 1 --bug-misdirect
  faults: read=11% write=2% misdirect=13% rot=7%
  atlas replica 0: .xx..xx.xx..xxxxxx.xxxxx.xxxxx..
  atlas replica 1: x..xx.xx..xx...xxxx...x.xxxxxxxx
  atlas replica 2: xxxxxx.xxxxxxxx...xxxx.xx.....xx
  t=  5 fault_read_flip  replica=2 block= 0 8d
  t=  5 repair           replica=2 block= 0 0
  t=  7 fault_misdirect  replica=2 block= 2 1
  t= 11 fault_read_flip  replica=1 block= 0 58
  t= 11 repair           replica=1 block= 0 2
  t= 15 FAIL CorruptDataReturned: replica=2 block=1
seed=1 trace=54ce8d97a0503e62 FAIL CorruptDataReturned
$ /tmp/dst09 run 1 --bug-misdirect
  faults: read=11% write=2% misdirect=13% rot=7%
  atlas replica 0: .xx..xx.xx..xxxxxx.xxxxx.xxxxx..
  atlas replica 1: x..xx.xx..xx...xxxx...x.xxxxxxxx
  atlas replica 2: xxxxxx.xxxxxxxx...xxxx.xx.....xx
  t=  5 fault_read_flip  replica=2 block= 0 8d
  t=  5 repair           replica=2 block= 0 0
  t=  7 fault_misdirect  replica=2 block= 2 1
  t= 11 fault_read_flip  replica=1 block= 0 58
  t= 11 repair           replica=1 block= 0 2
  t= 15 FAIL CorruptDataReturned: replica=2 block=1
seed=1 trace=54ce8d97a0503e62 FAIL CorruptDataReturned
```

The same bug caught by the storage checker instead (last lines of `run 12 --bug-misdirect`):
```
  t=199 checkpoint       replica=0 block=32 e335ab49eb2baa06
  storage checker: replica 0 hash=e335ab49eb2baa06 replica 1 hash=41d67d9650c81939
  t=199 FAIL StorageMismatch: replica=1 block=30
seed=12 trace=77500907cc862d43 FAIL StorageMismatch
```

With the bug fixed, the same seed 1 detects the misdirect and repairs both ends: block 1, which
received the wrong data, and block 2, which never got its write:
```
  t=  7 fault_misdirect  replica=2 block= 2 1
  ...
  t= 15 repair           replica=2 block= 1 0
  ...
  t= 20 repair           replica=2 block= 2 0
seed=1 trace=b33ae975aeb47d6b PASS
```

## Extra output flags
These only add output for the visual site (`site/`). They draw nothing from the PRNG and are not hashed, so
sweeps and trace hashes are the same with or without them.

- `--all-events`: also print every append and client read.

## Exercises

1. **Break the atlas on purpose.** Make `Sim.eligible` ignore the atlas (`return sim.faults_enabled;`)
   and sweep without any bug flag. The code under test is correct, yet seed 0 hits the
   `check_atlas` panic ("block 25 has no good copy anywhere") and seed 1 fails with
   `Unrepairable`. These are false alarms, which is the reason the atlas exists. (Raising
   `faults_max` to `replica_count` does not work as a shortcut: `FaultAtlas.init` asserts that a
   good replica exists for every block.)
2. **Stale versions.** Make the log mutable (blocks can be rewritten). A misdirect then leaves the
   intended slot with an *old but valid* block, and `hash(address ‖ payload)` no longer catches
   it. Add what TigerBeetle uses, an expected checksum carried by the reader (the parent reference
   in `read_block_validate`), and check that the sweep still passes.
