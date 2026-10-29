# 08 — Leader election under partitions and crashes

## Concept introduced

Network partitions and crash/restart, applied together to a consensus protocol. A Raft-style
leader election (RequestVote with `term` and `votedFor`, heartbeats, randomized election
timeouts) runs among 3–5 nodes. The node count is chosen from the seed. The simulator
partitions the network in the same ways TigerBeetle's PacketSimulator does:

- **PartitionMode**: `isolate_single` (one node alone), `uniform_size` (side size uniform in
  1..n-1), or `uniform_partition` (each node flips a coin, which tends to give halves).
- **PartitionSymmetry**: `symmetric` (no traffic crosses the split) or `asymmetric` (one side
  can still *send* to the other but cannot *receive* from it).
- **partition_stability / unpartition_stability**: the minimum number of ticks a partition,
  or a healthy network, lasts before it can change again.

Nodes also crash at random and restart later. A crash wipes all memory, and only the
simulated disk survives. After `fault_ticks = 3000` the simulator enters *liveness mode*: it
heals the network, restarts every node, turns off packet loss, and requires that one leader is
agreed by all nodes within `liveness_bound = 600` ticks.

Run it:

```
zig run main.zig -- run   <seed>  [--bug-volatile-vote] [--bug-no-quorum]
zig run main.zig -- sweep <count> [--bug-volatile-vote] [--bug-no-quorum]   # default 5000
```

### Reading the log line

Each event prints one line, modeled on the VOPR's replica line (`docs/internals/testing.md`):

```
  tick node event role [cluster] term votedFor leader net
   974 1 *     /    [//\]      19T  v1       L1     net:12|0
```

- event: `!` crash, `^` restart, `?` became candidate (new term), `*` became leader,
  `>` adopted a higher term, `v` granted a vote, `P` partition, `H` heal, `L` liveness mode.
- role and `[cluster]` use the VOPR symbols: `/` leader, `\` follower, `#` crashed. `?` means
  candidate. `[cluster]` has one character per node, at the node's index, so you can read
  down a column.
- `net:12|0` is a symmetric split. `net:1>0234` is asymmetric: node 1 can send to {0,2,3,4},
  but nothing reaches node 1.
- For a crashed node, term and votedFor are read from its disk.

## What is simulated vs real

| Real (the code under test)                          | Simulated                                             |
| --------------------------------------------------- | ----------------------------------------------------- |
| Election state machine: terms, votes, roles, timers | Time (a tick counter)                                 |
| The persist-before-reply rule (`Node.persist`)      | Network: delay 1..`delay_max`, loss, link filters     |
| The quorum rule (`votes_needed`)                    | Disk: a struct that survives `crash()`; writes are synchronous and atomic |
|                                                     | Crash/restart: volatile fields reset, disk kept       |

All randomness comes from one root PRNG seeded with `seed`. It generates the `Options` and
then derives sub-seeds for the fault PRNG, the network PRNG, and one PRNG per node (that
node's election-timeout jitter). Messages sit in a list and are delivered in send order. The
checker keeps a plain list instead of a hash map, so nothing depends on iteration order.
Every event and every delivered message is folded into a Wyhash trace.

## Invariants

Checked on **every tick** in `Simulator.check_safety`:

1. **Election Safety**: at most one leader per term over the whole history. The checker
   records `(term, leader)` the first time it sees a leader. A second node leading the same
   term fails the run, even if the two leaderships never overlapped in time.
2. **Term monotonicity**: no node's `currentTerm` ever decreases. For crashed nodes the
   checker reads the term from disk, so a restart that loses the term is caught too.
3. (assert) A running node's on-disk term equals its in-memory term. Nothing is advertised
   before it is persisted.

Checked in **liveness mode**:

4. **Liveness**: within 600 ticks of healing, every node is up, in the same term, and
   following the same single leader. Across 2000 seeds of the correct code, the slowest
   convergence was 53 ticks.

To check that the liveness check can actually fail, I temporarily made the election timeout
fixed at 30 ticks with no jitter (a scratch copy in /tmp, since deleted). The sweep then
reported `LIVENESS VIOLATED` at seed 38: with identical timeouts, split votes repeat forever.

## The planted bugs and why normal tests miss them

### `--bug-volatile-vote`: votedFor is not persisted

`Node.persist` writes `current_term` but writes `none` for `voted_for`. Without crashes the
in-memory vote is still correct, so every test without crashes passes. The failure needs four
things in order: (1) a node votes in term t, (2) it crashes before the term moves on,
(3) another candidate asks for a vote in that **same** term t, and (4) that vote makes the
difference for a majority. In the sweep this first happens at seed 86 and shows up in about
2% of seeds (9/500). A hand-written test would have to create that exact interleaving on
purpose.

The trace from seed 86 (3 nodes, quorum = 2):

```
   969 1 ? ? [/?\]  19T v1 L- net:12|0    node 1 starts term 19 and votes for itself
   970 2 v \ [/?\]  19T v1 L- net:12|0    node 2 votes for node 1
   974 1 * / [//\]  19T v1 L1 net:12|0    node 1 leads term 19 (a real majority: {1,2})
  1176 1 ! # [\#\]  19T v- L- net:ok      node 1 crashes: the disk has term 19, votedFor = none
  1176 0 ? ? [?#\]  19T v0 L- net:ok      node 0 starts term 19
  1189 1 ^ \ [?\\]  19T v- L- net:ok      node 1 restarts and has forgotten its vote
  1189 1 v \ [?\\]  19T v0 L- net:ok      ...so it votes for node 0 in term 19
  1191 0 * / [/\\]  19T v0 L0 net:ok      node 0 leads term 19 with {0,1}: two leaders
```

### `--bug-no-quorum`: majority of reachable nodes instead of all nodes

`votes_needed` counts the peers heard from in the last 100 ticks and requires a majority of
*that number*. The rule looks reasonable ("ignore dead nodes") and it works whenever the
network is healthy. Under a partition, though, the minority side thinks it is the whole
cluster. The asymmetric case is the worst: a node that can send but not receive hears from
nobody, so its "quorum" is just its own vote. The sweep finds this at seed 0.

From seed 0 (5 nodes, quorum = 3, node 1 isolated asymmetrically by `1>0234`):

```
  1068 0 * / [/?\\\]   8T v0 L0 net:1>0234   node 0 leads term 8 with votes from {0,2,3,4}
  1071 1 ? ? [/?\\#]   8T v1 L- net:1>0234   node 1 has heard nothing for over 100 ticks
  1071 1 * / [//\\#]   8T v1 L1 net:1>0234   reachable = 1, so it "wins" term 8 with its own vote
```

## How TigerBeetle does this

- **Partitions**: `src/testing/packet_simulator.zig` defines `PartitionMode` (`none`,
  `uniform_size`, `uniform_partition`, `isolate_single`), `PartitionSymmetry`, and the options
  `partition_probability`, `unpartition_probability`, `partition_stability`, and
  `unpartition_stability`. `auto_partition_network` chooses the two sides and sets each link's
  filter. In asymmetric mode a link stays enabled when
  `partition[from] == asymmetric_partition_side`. `PacketSimulator.tick` counts the stability
  down and then may partition or heal. `Simulator.partition_network` / `heal_network` and
  `inject_faults` in this example follow that code closely. `src/vopr.zig` picks the mode and
  symmetry per seed with `prng.enum_uniform(...)` and uses
  `partition_stability = 100 + prng.int_inclusive(u32, 100)`.
- **Crash with persisted state**: `Cluster.replica_crash` in `src/testing/cluster.zig` resets
  the replica, leaves storage untouched, and keeps in-flight messages in the network.
  `Cluster.replica_restart` reopens the replica from that storage.
- **Never advertise what is not durable**: in `src/vsr/replica.zig`, `view_durable()` says
  "A replica must not advertise a view higher than its durable view… The advertised `view`
  must never backtrack after a crash." `log_view_durable()` walks through a log fork caused by
  a `log_view` that regressed, and `view_durable_update()` persists through
  `SuperBlock.view_change` (`src/vsr/superblock.zig`). TigerBeetle's view is the counterpart
  of Raft's term. `--bug-volatile-vote` is a smaller version of the bug those comments warn
  about.
- **Quorums over the full replica count**: `vsr.quorums(replica_count)` in `src/vsr.zig`
  asserts `quorum_view_change >= @divFloor(replica_count, 2) + 1` and
  `quorum_view_change + quorum_replication > replica_count`. These depend on the configured
  count, never on the number of reachable nodes. `--bug-no-quorum` breaks exactly this rule.
- **Asymmetric partitions and view changes**: `docs/internals/vsr.md` (Protocol:
  Start-View-Change) explains that a replica which can send but not receive can never gather
  a view-change quorum, so the cluster's view stays stable.
- **Liveness mode**: `Simulator.transition_to_liveness_mode` in `src/vopr.zig` stops faults
  on a core of replicas and requires convergence. `core_missing_primary` handles the case of a
  primary outside the core. This example's `enter_liveness_mode` is the simple version: heal
  everything and require one agreed leader within a fixed bound.
- **Log line**: `Cluster.log_replica` in `src/testing/cluster.zig` prints the
  per-replica status line described in `docs/internals/testing.md`.

## Verified run

Built with Zig 0.17.0: `zig build-exe main.zig -O ReleaseSafe -femit-bin=/tmp/dst08`.
The 5000-seed sweep of the correct code takes about 1.9 s.

Sweep without a bug:

```
$ /tmp/dst08 sweep
PASS: 5000 seeds
exit=0
```

Sweep with each bug:

```
$ /tmp/dst08 sweep 5000 --bug-volatile-vote
ELECTION SAFETY VIOLATED: term 19 has two leaders: node 1 and node 0 (tick 1191)
FAIL at seed=86 (election_safety) after 87 seeds. Replay with:
  zig run main.zig -- run 86 --bug-volatile-vote
exit=1

$ /tmp/dst08 sweep 5000 --bug-no-quorum
ELECTION SAFETY VIOLATED: term 8 has two leaders: node 0 and node 1 (tick 1071)
FAIL at seed=0 (election_safety) after 1 seeds. Replay with:
  zig run main.zig -- run 0 --bug-no-quorum
exit=1
```

Replay, run twice. Both runs exit 1, and their full outputs are byte-identical: `cmp` reports
no difference, and both have
sha256 `0dcc3c4496eacf9e7d85e7f10c34872e2129664792a52fb8963fa6e16d6adf2d`. Run 1, in full:

```
$ /tmp/dst08 run 86 --bug-volatile-vote
seed=86 nodes=3 partition_mode=uniform_partition partition_symmetry=symmetric
  partition_probability=108/10000 unpartition_probability=365/10000
  partition_stability=167 unpartition_stability=26 ticks
  crash_probability=217/100000 restart_probability=122/1000 loss=49/1000 delay=1..4
  tick node event role [cluster] term votedFor leader net
     3 - P - [\\\]  ---  --  --  net:12|0
    20 0 ? ? [?\\]   1T v0 L- net:12|0
    21 2 ? ? [?\?]   1T v2 L- net:12|0
    22 1 > \ [?\?]   1T v- L- net:12|0
    22 1 v \ [?\?]   1T v2 L- net:12|0
    26 2 * / [?\/]   1T v2 L2 net:12|0
    53 0 ? ? [?\/]   2T v0 L- net:12|0
    63 1 ! # [?#/]   1T v- L- net:12|0
    64 1 ^ \ [?\/]   1T v- L- net:12|0
    68 2 ! # [?\#]   1T v- L- net:12|0
    72 2 ^ \ [?\\]   1T v- L- net:12|0
    90 0 ? ? [?\\]   3T v0 L- net:12|0
    97 1 ? ? [??\]   2T v1 L- net:12|0
    98 2 > \ [??\]   2T v- L- net:12|0
    98 2 v \ [??\]   2T v1 L- net:12|0
   101 1 * / [?/\]   2T v1 L1 net:12|0
   117 0 ? ? [?/\]   4T v0 L- net:12|0
   156 0 ? ? [?/\]   5T v0 L- net:12|0
   178 0 ? ? [?/\]   6T v0 L- net:12|0
   179 - H - [?/\]  ---  --  --  net:ok
   185 2 > \ [?/\]   6T v- L- net:ok
   185 2 v \ [?/\]   6T v0 L- net:ok
   186 1 > \ [?\\]   6T v- L- net:ok
   186 1 v \ [?\\]   6T v0 L- net:ok
   186 0 * / [/\\]   6T v0 L0 net:ok
   376 1 ! # [/#\]   6T v- L- net:ok
   378 1 ^ \ [/\\]   6T v- L- net:ok
   434 - P - [/\\]  ---  --  --  net:2|01
   446 2 ! # [/\#]   6T v- L- net:2|01
   453 2 ^ \ [/\\]   6T v- L- net:2|01
   483 2 ? ? [/\?]   7T v2 L- net:2|01
   503 2 ? ? [/\?]   8T v2 L- net:2|01
   533 2 ? ? [/\?]   9T v2 L- net:2|01
   562 2 ? ? [/\?]  10T v2 L- net:2|01
   586 2 ? ? [/\?]  11T v2 L- net:2|01
   595 0 ! # [#\?]   6T v- L- net:2|01
   607 0 ^ \ [\\?]   6T v- L- net:2|01
   613 - H - [\\?]  ---  --  --  net:ok
   614 2 ? ? [\\?]  12T v2 L- net:ok
   617 0 > \ [\\?]  12T v- L- net:ok
   617 0 v \ [\\?]  12T v2 L- net:ok
   618 1 > \ [\\?]  12T v- L- net:ok
   618 1 v \ [\\?]  12T v2 L- net:ok
   618 2 * / [\\/]  12T v2 L2 net:ok
   689 - P - [\\/]  ---  --  --  net:12|0
   729 0 ? ? [?\/]  13T v0 L- net:12|0
   766 0 ? ? [?\/]  14T v0 L- net:12|0
   794 0 ? ? [?\/]  15T v0 L- net:12|0
   833 0 ? ? [?\/]  16T v0 L- net:12|0
   857 0 ? ? [?\/]  17T v0 L- net:12|0
   882 0 ? ? [?\/]  18T v0 L- net:12|0
   893 - H - [?\/]  ---  --  --  net:ok
   896 1 > \ [?\/]  18T v- L- net:ok
   896 1 v \ [?\/]  18T v0 L- net:ok
   896 2 > \ [?\\]  18T v- L- net:ok
   896 2 v \ [?\\]  18T v0 L- net:ok
   898 0 * / [/\\]  18T v0 L0 net:ok
   944 - P - [/\\]  ---  --  --  net:12|0
   969 1 ? ? [/?\]  19T v1 L- net:12|0
   970 2 > \ [/?\]  19T v- L- net:12|0
   970 2 v \ [/?\]  19T v1 L- net:12|0
   974 1 * / [//\]  19T v1 L1 net:12|0
  1138 0 ! # [#/\]  18T v- L- net:12|0
  1149 0 ^ \ [\/\]  18T v- L- net:12|0
  1174 - H - [\/\]  ---  --  --  net:ok
  1176 1 ! # [\#\]  19T v- L- net:ok
  1176 0 ? ? [?#\]  19T v0 L- net:ok
  1189 1 ^ \ [?\\]  19T v- L- net:ok
  1189 1 v \ [?\\]  19T v0 L- net:ok
  1191 0 * / [/\\]  19T v0 L0 net:ok
ELECTION SAFETY VIOLATED: term 19 has two leaders: node 1 and node 0 (tick 1191)
seed=86 ticks=1191 trace=3dfa85464a32b0b4 FAIL
```

Last line of run 2:

```
seed=86 ticks=1191 trace=3dfa85464a32b0b4 FAIL
```

The `--bug-no-quorum` replay also produced byte-identical output on two runs (sha256
`8fb465cf…a8e7`), ending with:

```
seed=0 ticks=1071 trace=02dcb41e2bd60ee0 FAIL
seed=0 ticks=1071 trace=02dcb41e2bd60ee0 FAIL
```

`zig run main.zig -- run 86 --bug-volatile-vote` in the default Debug mode prints the same
`trace=3dfa85464a32b0b4`, so the trace hash is the same across optimization modes.

## Exercises

1. **Torn persistence.** Make `Node.persist` write `current_term` and `voted_for` as two
   separate writes, and let a crash land between them (draw it from the fault PRNG). Which
   write order is safe? Show it by sweeping both orders.
2. **PreVote / CheckQuorum.** In asymmetric partitions, the node that can send but not
   receive keeps raising its term and disrupts a healthy leader (look for runs of `?` lines
   followed by `>` on every other node). Add Raft's PreVote and measure in the trace how
   many leader changes it removes. Compare with the Start-View-Change argument in
   `docs/internals/vsr.md`.
