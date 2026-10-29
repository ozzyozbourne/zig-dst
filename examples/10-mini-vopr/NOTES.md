# Example 10 — Mini-VOPR (capstone)

## Concept introduced

Everything at once, organized the way TigerBeetle's VOPR organizes it. The seed first chooses a
**swarm** of fault settings (cluster size, loss, duplication, delay, partition mode, write
latency, crash and restart rates) and prints them as a `SEED=` block. Then the run has two phases:

1. **Safety phase.** Every fault is on: replicas crash and restart, partitions come and go,
   packets are lost, duplicated, and reordered. Checkers run on every commit and every reply. The
   phase ends when every client request has been answered, or when no reply has arrived for 3,000
   ticks.
2. **Liveness phase.** A random **core** is chosen: a quorum or more of replicas, or all of them if
   the safety phase stalled. Down core replicas are restarted, the network between core replicas is
   healed, non-core replicas are cut off permanently, and crashes stop. The core must then converge
   within 5,000 ticks: same view, a primary inside the core, commit and log head equal to the
   canonical head, and the same state-machine hash. "Eventually" cannot be tested; "within N ticks"
   can.

The system under test is a small Viewstamped Replication cluster of 3 or 5 replicas. Its replicated
log holds transfers between 4 accounts. The protocol has prepare, prepare_ok, and commit; view
changes using start_view_change, do_view_change, and start_view; get_view to repair gaps; and a
client session table for retried requests.

## What is simulated vs real

| Simulated | Real |
|---|---|
| Time: a `u64` tick. Heartbeats, view-change timeouts, and client retries count ticks. | The VSR protocol logic and the state machine, which is what is being tested |
| Network: per-packet loss, duplication, and a random delay (which reorders packets); symmetric or asymmetric partitions | Hash-chained log entries (`parent` → `checksum`), as in TigerBeetle headers |
| Storage: a durable WAL plus a FIFO queue of unsynced writes with random latency. A crash drops the queue. | The checkers |
| Crash and restart: memory is wiped and the replica rebuilds from the durable WAL, view, and log_view, then re-executes committed ops | |
| Clients: retry the same request number on the next replica after a timeout | |

All randomness comes from one `DefaultPrng(seed)`. The simulator gets a sub-PRNG derived from it.
Every delivered packet, commit, crash, restart, view change, and partition is folded into a Wyhash
trace.

## Invariants

These run during the simulation, not at the end:

1. **State checker (no divergence).** The first time any replica commits op N, that op's checksum,
   result, and post-state hash become the canonical op N. Every later commit of op N must match
   exactly, whatever the replica and whenever it happens, including re-execution after a restart.
   This mirrors `StateChecker.check_state`.
2. **Client replies match the canonical log.** Every reply a client receives, including stale
   duplicates, must name an op that is already committed. That op must hold the same client,
   request number, and result.
3. **Money is conserved.** After every apply on every replica, the sum of balances is 400.
4. **Liveness.** After healing, the core converges within a fixed bound. To check that this
   detector works, I removed one repair line (the `get_view` request in `on_commit`) in a temporary
   copy. The sweep then failed at seed 8 with `no liveness: core=11111 did not converge in 5000
   ticks: pending replica convergence`. The copy was deleted afterward.

The protocol rules that keep correct code safe under these faults:

- A backup sends `prepare_ok` only after its write is durable.
- A replica sends `do_view_change` only after the new view is durable.
- A restarted primary never resumes as primary.
- A new primary picks the log with the highest `(log_view, op)` among a quorum of do_view_change
  messages.

## The planted bugs and why normal tests miss them

- `--bug-commit-early`: the primary commits once **one** durable copy exists (its own) instead of a
  replication quorum. In a healthy cluster the backups ack a few ticks later anyway, so every
  client still gets correct answers and no unit or integration test notices. The bug only matters
  if the primary is cut off right after committing. In the seed-3 trace, the primary keeps serving
  the client while partitioned away from both backups. It commits ops 2–5 alone, the other two run
  a view change, and the new primary assigns op 2 to a different request. The state checker flags
  it:

  ```
       7    partition side=00001 symmetric
      83  0   / .vv    0V   4/__4C   0LV   4Wo  0W!
     116  0 ! # #vv    0V   5/__6C   0LV   5Wo  1W!
     155  2 / / #v.    2V   0/__1C   2LV   1Wo  1W!
     195 FAIL: divergence: replica 2 committed op=2 checksum=9e0d1a458b510814 (client=0 request=6 view=2) but canonical op=2 is checksum=c37d68ac42d31d31 (client=0 request=2)
  ```

- `--bug-view-change-log`: the new primary keeps **its own** log instead of the best one in the
  quorum. While the new primary is up to date, this behaves exactly like the correct rule. It goes
  wrong only when the replica that rotates into primary is the one that lagged: it was crashed, or
  partitioned, while others committed. In the seed-3 trace, replica 2 crashed at tick 8 with an
  empty WAL. Later it becomes primary of view 5 and installs its empty log, and backup 1 shows
  `4/__0C` (commit 4, log head 0). Four committed ops have been truncated:

  ```
     456  2 ^ \ .v.    0V   0/__0C   0LV   0Wo  0W!
     490  2 / / .v.    5V   0/__0C   5LV   0Wo  1W!
     492  1 > \ ...    5V   4/__0C   5LV   4Wo  1W!
     560 FAIL: divergence: replica 2 committed op=1 checksum=265ebc233f913bab (client=0 request=5 view=5) but canonical op=1 is checksum=135a3546a0191492 (client=0 request=1)
  ```

Neither bug can be reached without a combination of faults: a crash or partition, plus the right
primary rotation, plus continued client traffic. Each bug fails on roughly 1 seed in 8 (27/200 and
25/200 seeds in a spot check). No single seed is special, which is why sweeping thousands of seeds
works.

Status line legend (modelled on `Cluster.log_replica`):
`tick replica event role statuses  viewV commit/opC log_viewLV durable_opsWo pending_writesW!`.
- Events: ` ` commit, `!` crash (its `W!` is the number of unsynced writes about to be lost),
  `^` restart, `v` view change, `/` became primary, `>` installed start_view, `=` final state.
- Statuses: `.` normal, `v` view change, `#` down.

## How TigerBeetle does this

- `src/vopr.zig` `main`: parses the seed, builds options with `options_swarm`, logs the `SEED=`
  block, and runs the safety loop until `requests_replied == requests_max` (the tick counter resets
  whenever a reply arrives). It then picks `random_core` (or `full_core` if requests did not
  finish), calls `transition_to_liveness_mode`, and loops until `pending()` returns null within
  `ticks_max_convergence`. If the core did not converge, `cluster_recoverable` decides whether that
  is a real liveness bug.
- `Simulator.tick` → `cluster.tick()`, `tick_requests`, `tick_crash` (`tick_crash_up` multiplies
  the crash probability by 10 while storage writes are pending, as done here), and `tick_pause`.
- `transition_to_liveness_mode`: restarts down core replicas, heals the core network and storage,
  and sets crash and restart probabilities to zero.
- `src/testing/cluster.zig` `tick`: interleaves network and storage steps, ticks each replica, and
  calls `state_checker.check_state` for every up replica. `on_replica_event(.committed)` runs the
  checker on every commit. `log_replica` prints the status line imitated here.
- `src/testing/cluster/state_checker.zig`: the `commits` list is the canonical history. A commit
  not seen before is appended; an existing one must match (`assert(checksum_b ==
  commit.header.checksum)`). `replica_convergence` and `assert_cluster_convergence` are used by the
  liveness phase.
- `docs/internals/vsr.md`: the Normal, Start-View-Change, View-Change, and Request/View protocols;
  "Recovery" explains why VSR state is persisted rather than using the VRR recovery protocol.
  `src/vsr.zig` `quorums()` gives the replication and view-change quorums, which must intersect.
  This example uses a majority for both.

## Verified run

Built with `zig build-exe main.zig -OReleaseSafe -femit-bin=/tmp/mini-vopr` (Zig 0.17.0).

```
$ /tmp/mini-vopr sweep            # default count = 20000, 3.99 s
PASS: 20000 seeds

$ /tmp/mini-vopr sweep 20000 --bug-commit-early
FAIL at seed=3 after 4 seeds: divergence: replica 2 committed op=2 checksum=9e0d1a458b510814 (client=0 request=6 view=2) but canonical op=2 is checksum=c37d68ac42d31d31 (client=0 request=2)
Replay with:
  zig run main.zig -- run 3 --bug-commit-early

$ /tmp/mini-vopr sweep 20000 --bug-view-change-log
FAIL at seed=3 after 4 seeds: divergence: replica 2 committed op=1 checksum=265ebc233f913bab (client=0 request=5 view=5) but canonical op=1 is checksum=135a3546a0191492 (client=0 request=1)
Replay with:
  zig run main.zig -- run 3 --bug-view-change-log
```

Each replay was run twice with the full verbose log (on stderr) captured to a file:

```
$ /tmp/mini-vopr run 3 --bug-commit-early 2> a.log; /tmp/mini-vopr run 3 --bug-commit-early 2> b.log
seed=3 ticks=195 commits=5 trace=692aa09c1869a180 FAIL     (both runs, exit 1)
0412a4f6f86c344e0010512a39229e9561d32812c02649438bcaef6f95f1ca4e  a.log
0412a4f6f86c344e0010512a39229e9561d32812c02649438bcaef6f95f1ca4e  b.log

$ /tmp/mini-vopr run 3 --bug-view-change-log   (twice)
seed=3 ticks=560 commits=4 trace=33f68caccfde5918 FAIL     (both runs, exit 1)
93b9ec6d2e7298233d0bcc007c38c9b683ef9a44c055d456c839a754246e93f2  (both logs)

$ /tmp/mini-vopr run 0   (twice, correct code)
seed=0 ticks=910 commits=15 trace=459c3b0299936c2f PASS
59fc1fb3d938046982789153acc0459141d8c9b9ce646ea66811f135d4f744ef  (both logs)
```

`zig run main.zig -- run 3 --bug-commit-early` (Debug build) prints the same
`trace=692aa09c1869a180`.

Fault coverage in a spot check of seeds 0–199 (correct code): a replica crashed in 85 seeds, a
crash lost unsynced writes in 56, a partition occurred in 114, and a non-initial primary was
elected in 125.

## Exercises

1. Make a backup send `prepare_ok` as soon as it appends to its in-memory log, not when the write
   completes. Which checker fires first, and what fault sequence does the trace show?
2. Remove the restart rule "a recovered primary must start a view change". Sweep and explain the
   failing trace. Then add storage corruption (a torn final write) and see how protocol-aware
   recovery would have to change.
