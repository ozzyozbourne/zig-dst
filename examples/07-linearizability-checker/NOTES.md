# 07 — The oracle problem: a linearizability checker

## Concept introduced

With one client, the oracle is easy: apply the same operation to a simple model and compare the
answers. With concurrent clients there is no single "expected answer". Overlapping operations may
take effect in either order, so the expected answer is a **set of legal orderings**.

The oracle changes shape:

1. During the simulation, record a **history**. For every operation, record its invoke tick and
   its complete tick (simulated time, as seen by the client), its argument and its result.
2. Ask whether **some** total order of those operations both respects real time (if A completed
   before B was invoked, A comes first) and is a legal sequential execution of a register. If such
   an order exists, the history is linearizable. If none exists, the system has a bug, even when
   every single answer looks plausible.

The checker in `main.zig` works like Wing & Gong / Knossos:

- It does a backtracking search over "which op takes effect next". An op may go next only if no
  op still unplaced completed before it was invoked.
- It memoizes failed `(set of placed ops, register state)` pairs (Lowe's optimization), stored in
  a 4096×13-bit `StaticBitSet`.
- It checks each key on its own. Linearizability is *local* (Herlihy & Wing), so a history is
  linearizable exactly when each key's sub-history is. This keeps each search at 12 ops or fewer.
- In-flight writes are optional: they may or may not have taken effect. In-flight reads are dropped.
- The search runs **on every completion**, so a violation is reported at the tick it first becomes
  visible.
- When the check fails, a greedy delta-debugging pass (`minimize`) removes ops until every
  remaining op is needed. A read may never lose the write whose value it returned, so the result
  stays meaningful. The result is printed as a timeline.

Histories are kept small on purpose: 3 clients and 6–12 ops per seed. Each search is exponential
in the worst case, so DST runs many short seeds rather than one long history.

## What is simulated vs real

- **Simulated:**
  - Time: a tick counter.
  - The network: a list of in-flight messages, each with a random delivery tick. Replication
    takes 1–30 ticks and other hops take 1–6 ticks, so replication messages are often delivered
    out of order.
  - The two replicas, primary and async backup.
  - Three clients, each with one operation outstanding and a random think time.
- **Real:** the replica logic, which is the system under test:
  - The primary assigns versions, applies writes, and replicates.
  - The backup buffers out-of-order entries and applies them in version order.
  - The backup's read path serves reads.
  - The client's session token.
  - The checker and the minimizer.
- All randomness comes from one `DefaultPrng(seed)`. Every send, delivery, invoke, completion,
  and backup apply is folded into a Wyhash trace.

## Invariants

These are checked during the simulation:

| Where | Invariant | Holds with `--bug`? |
|---|---|---|
| `check_replicas` (each backup apply) | backup log is a prefix of the primary log; `backup_applied <= primary_version` | yes |
| `complete` (each reply) | session guarantees: reply version ≥ the client's last-seen version (read-your-writes, monotonic reads) | yes |
| `complete` (each read) | the value read equals the committed value of that key at the version that served it (no garbage, no lost writes) | yes |
| `check_key` (each completion) | the history so far for that key is **linearizable** | **no** |
| `run_seed` | liveness: everything finishes within 10 000 ticks | yes |

Every per-operation check still passes under `--bug`. Only the history-level check catches it.

## The planted bug and why normal tests miss it

Correct backup read path ("read index", as in Raft's ReadIndex): the backup asks the primary for
its **current** commit version. It waits until it has applied at least that version, then serves
the read. That version was current at some moment during the read, so the value returned is the
primary's state at some moment between invoke and complete. That moment is a valid linearization
point.

`--bug`: the backup only waits for the requesting client's **own** session token (the highest
version this client has seen). Each client then sees its own writes, and its reads never go
backwards, so a test with one client, or one that checks each client's results separately, cannot
fail. The failure needs two clients and a real-time relation between them: client A's write is
acknowledged, *then* client B reads from a backup that is still behind. (Note: the brief described
"wait for the client's last-seen version" as the correct mode. That rule gives session consistency,
not linearizability, so here it is the bug.)

Seed 1 gives the textbook minimal counterexample (output below). A more interesting case is seed 3,
`run 3 --bug`. This is real output; the minimizer drops one of the 5 ops on key `x`:

```
  who  op         [invoke, complete] timeline (t=0..17, 1 tick/col)
  c0   W(x:=1)    [   0,    7]       |------|  primary v1
  c2   W(x:=3)    [   0,    6]       |-----|  primary v3
  c1   R(x)=3     [   9,   13]                |---|  primary v3
  c0   R(x)=1     [  10,   17]                 |------|  backup v1
```

The two writes overlap, so either order is fine, and so are the two reads. But `R=3` needs
`W1 < W3 < R3`, and `R=1` then needs a `W1` placed after `W3`. Because `W1` finished before either
read began, no order works. You have to try the orderings to see this, which is the job of the
backtracking search. c0's read of its own write `1` satisfies read-your-writes, which is why the
per-client checks stay quiet.

## How TigerBeetle does this

- TigerBeetle avoids the search because VSR **exposes the linearization**: every reply carries
  its op number.
- `src/testing/reply_sequence.zig`:
  - `ReplySequence` reassembles replies, which can arrive out of order, by ascending op.
  - It holds them in a priority queue (`insert`, `peek(op)`, `next`).
  - `src/vopr.zig` `on_cluster_reply` uses it to feed `workload.on_reply` strictly in commit
    order.
  - The backup's `backup_buffer` in this example does the same reassembly for replication
    messages.
- `src/state_machine/auditor.zig` ("The Auditor expects replies in ascending commit order")
  replays those replies against a model and validates each result. Once the order is known, the
  oracle is a sequential model again.
- `src/testing/cluster/state_checker.zig`:
  - `check_state(replica_index)` runs on every tick for each replica, from
    `src/testing/cluster.zig` near the "state checker error" call. It asserts that each replica's
    new commit either matches the canonical `commits` history or extends it by exactly the
    in-flight request of the originating client.
  - `on_message` tracks the latest `reply` per client.
  - `assert_cluster_convergence` checks the commit chain's parent checksums.
  - `check_replicas` here is the tiny version: the backup's log must always be a prefix of the
    primary's.
- The lesson: if the system can tell the tester its claimed order (op numbers, versions), check
  that order directly, as TigerBeetle does. It is linear time and needs no search. Use a
  Knossos-style search when the order is hidden, for example when reads are served off a replica
  and never get an op number, as in this example.

## Verified run

Build: `/home/user/tools/zig-0.17.0/zig build-exe -OReleaseSafe main.zig -femit-bin=/tmp/dst07`
(the commands below run `/tmp/dst07`, which is the same as `zig run main.zig -- ...`).

Sweep without bug (default 100 000 seeds, about 1.7 s):

```
$ /tmp/dst07 sweep
PASS: 100000 seeds
exit=0
```

Sweep with bug:

```
$ /tmp/dst07 sweep --bug
FAIL at seed=1 after 2 seeds. Replay with:
  zig run main.zig -- run 1 --bug
exit=1
```

Replay, first time:

```
$ /tmp/dst07 run 1 --bug
  t=  0 c0 invoke W(y:=1) -> primary
  t=  0 c1 invoke W(y:=2) -> primary
  t=  0 c2 invoke R(x) -> backup (session token v0)
  t=  6 c0 ok     W(y:=1) at v1
  t=  7 c1 ok     W(y:=2) at v2
  t=  7 c2 ok     R(x)=0 from backup at v0
  t=  9 c0 invoke W(x:=3) -> primary
  t=  9 c1 invoke R(y) -> backup (session token v2)
  t= 11 c2 invoke R(y) -> backup (session token v0)
  t= 16    backup applies v1 (y:=1)
  t= 18    backup applies v2 (y:=2)
  t= 18 c0 ok     W(x:=3) at v3
  t= 19 c2 ok     R(y)=0 from backup at v0

NON-LINEARIZABLE history on key 'y'. Minimal sub-history (2 of 3 ops on this key):

  who  op         [invoke, complete] timeline (t=0..19, 1 tick/col)
  c1   W(y:=2)    [   0,    7]       |------|  primary v2
  c2   R(y)=0     [  11,   19]                  |-------|  backup v0

  Real-time order forced by the history:
    c1 W(y:=2) completed at t=7 before c2 R(y)=0 was invoked at t=11
  No order of these ops that respects real time is a legal register execution,
  and removing any one op makes the history linearizable again.

seed=1 ops=6 trace=3e1850e49d1b089a FAIL
exit=1
```

Replay, second time (identical trace):

```
$ /tmp/dst07 run 1 --bug
...
seed=1 ops=6 trace=3e1850e49d1b089a FAIL
```

The full output of `run 3 --bug` was also byte-identical across two runs (`cmp`). The same seed
without the bug passes: `run 1` → `seed=1 ops=10 trace=958243d897550eef PASS`. Across seeds
0–1999 with `--bug`, 298 seeds fail. Their minimal sub-histories have 2 ops (221 seeds), 3 ops
(55), or 4 ops (22), and none hit an assertion.

## Exercises

1. Under `--bug`, have all three clients share one session token, as if they gossip out of band.
   Does the sweep pass? Explain why that hides the bug instead of fixing it: real clients have no
   such channel.
2. Make a client "crash" with some probability after sending a write, so it never receives the
   `write_ok` and the write stays pending. Check that correct mode still passes, because a read
   may observe a pending write. Then delete the "pending writes are optional" rule from `search`
   and watch false alarms appear.
