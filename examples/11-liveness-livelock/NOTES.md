# 11 — Liveness: livelock and the request nobody retries

## Concept introduced

**Liveness bugs.** Every other example in this guide plants a *safety* bug, where something bad
happens: two leaders, lost money, a rewritten log. An assertion catches that at the tick it
happens. A liveness bug never does anything wrong, but it never makes progress either. Every
state the system passes through is legal, so no per-tick assertion can fire. Catching it needs
two different things:

1. **A different way of running the simulation.** Faults run first (the *safety phase*). Then the
   simulator stops injecting faults, heals a core quorum, and gives the system a fair chance
   (the *liveness phase*). During the safety phase, "no progress" is often correct behaviour:
   with a minority partitioned off and the rest crashed, nothing *should* commit.
2. **A different checker.** "Eventually a leader is elected" cannot be tested. "Within
   `convergence_ticks = 3000` ticks of the heal, the core has a stable leader and every client
   request is committed" can. When the bound expires, the checker must say *why* there was no
   progress, not just that there was none.

The system is a Raft-style cluster of 3–5 nodes (count from the seed): leader election
(RequestVote, term, votedFor, randomized election timeouts, the up-to-date-log vote rule) plus
log replication (AppendEntries, a no-op per new leader, majority commit) of a replicated
**counter**. One to three clients submit increments `c<client>#<n>`. A session table per client
makes retries exactly-once.

```
zig run main.zig -- run   <seed>  [--bug-fixed-timeout] [--bug-no-retry-on-leader-change]
zig run main.zig -- sweep <count> [--bug-...]                  # default count 20000
zig run main.zig -- stats <count> [--spread=K] [--bug-...]     # one TSV line per seed (for the site)
```

`--spread=K` sets the width of the election-timeout window, `[30 - K/2, 30 - K/2 + K]`.
The default is 20, which gives `[20, 40]`, and `--bug-fixed-timeout` is `--spread=0`. It exists
only to measure the split-vote rate as a function of randomization. It does not change any
documented run.

### Phases

| Phase | Ticks | What the simulator does |
| --- | --- | --- |
| Safety | 0..2000 | Partitions (`isolate_single` / `uniform_size`), crash/restart, packet loss, delay `delay_min..delay_max` |
| Heal | 2000 | `transition_to_liveness_mode`: choose a random core of ≥ quorum nodes, restart the down ones, heal every link inside the core, cut the others off for good, stop crashes and loss |
| Liveness | 2000..5000 | The network stays jittery (1 tick plus a geometric tail, up to 6), like TigerBeetle's liveness network, which keeps an exponential delay. Demand a stable leader and the commit of every request |

### Reading the log

```
  tick node event role [cluster] term votedFor leader commit/log
  2003 0 ?     ?    [????]      63T  v0       L-     c3/3
  2058 c0 R #2 node=2           client 0 re-sends request #2 to node 2
```

Node events: `?` became candidate, `*` became leader, `>` adopted a higher term, `v` granted a
vote, `x` truncated uncommitted entries, `!` crash, `^` restart. Roles use the VOPR symbols
(`/` leader, `\` follower, `#` down) and `?` for a candidate. Client events: `S` submit, `R`
re-send, `A` accepted by a leader, `D` done (reply received). Phase lines: `P` partition, `H`
heal, `L` liveness mode.

## What is simulated vs real

| Real (the code under test) | Simulated |
| --- | --- |
| Election: terms, votes, the up-to-date-log rule, timers | Time (a tick counter) |
| Replication: AppendEntries, conflict truncation, commit rule | Network: delay, loss, partitions, link filters |
| Client retry logic and the session table | Crash/restart: volatile state wiped; term, vote, and log kept |
| The election-timeout distribution (`arm_election_timer`) | Clock jitter: each node draws its timeouts from its own PRNG |

All randomness comes from one root PRNG. It generates the `Options` and then derives sub-seeds
for faults, the network, clients, and one PRNG per node. Messages are delivered in send order
from a plain list. Every event, delivery, and commit is folded into a Wyhash trace. The
liveness bookkeeping (election rounds, votes per candidate) is never read by the protocol and is
not hashed, so the diagnosis can be improved without changing any trace.

## Invariants

**Safety**, checked during *both* phases, on every tick and every commit:

1. **Election Safety**: at most one leader per term, over the whole history (as in example 08).
2. **The committed prefix is never rewritten**: the first commit of index *i* by any node defines
   *i*. Every later commit of *i*, by any node and at any time (including re-applies after a
   restart), must be the same entry with the same counter value. Truncating at or below the
   node's own commit index is also reported as a violation.
3. **Exactly-once**: the counter after index *i* equals the number of distinct client requests
   in 1..*i*. Retries must not double-count.

**Liveness**, checked once the heal has happened:

4. Within 3000 ticks of the heal, the whole core is up, in one term, and follows one leader that is
   in the core.
5. Within the same window, every client request is committed and replied to, and every core node
   has applied the leader's whole log.

Before reporting a liveness failure, `cluster_recoverable()` checks that the core *could* make
progress: it is at least a quorum, all of its nodes are up, and all of its links are healthy.
In TigerBeetle the same step (`cluster_recoverable` in `src/vopr.zig`) separates real bugs from
runs that were simply unlucky. Here the answer is always yes by construction, so the step only
documents and asserts the precondition.

On every run that ends in liveness mode, `run` prints the safety outcome next to the liveness
outcome (`safety: OK: ...`). **Both planted bugs are pure liveness bugs.** Across 2000 seeds
(`stats`), every failure under either flag, and under both together, is `no_stable_leader` or
`request_stuck`. None is `election_safety` or `prefix_rewritten`.

How tight the bound is: across 2000 seeds of the correct code, the slowest stable leader
appeared 150 ticks after the heal (mean 8.2). The 3000-tick bound is 20× that.

## The planted bugs and why normal tests miss them

### `--bug-fixed-timeout`: a livelock

Every node uses a 30-tick election timeout instead of drawing one from [20, 40]. Only one line
of `arm_election_timer` differs:

```zig
// correct: uniform in [20, 40]       buggy: spread = 0, always 30
node.election_deadline = now + node.prng.random().intRangeAtMost(u64, lo, lo + timeout_spread);
```

The cause in the simulation is the realistic one. **Timers are re-armed by shared events.**
Every follower that receives a candidate's higher-term RequestVote steps down and re-arms its
timer (like etcd's `becomeFollower`) within the same delivery window. So does every follower
that grants a vote, or hears a heartbeat. With random timeouts, the next round's order is
reshuffled. With equal timeouts it **repeats forever**, with the same offsets each time. Random
network delay does not save it: the delay decides the offsets once, and the next shared event
re-synchronizes everyone.

Seed 11 (4 nodes, quorum 3, core = {0, 2, 3}, node 1 cut off) shows both forms the livelock
takes:

```
  2000 - L liveness mode: core=023 (cut off for good: 1)
  2003 0 ? ? [????]  63T v0 L- c3/3     node 0 (log length 3) times out first
  2004 2 > \ [??\?]  63T v- L- c3/3     node 2 adopts term 63, re-arms, votes for 0
  2004 2 v \ [??\?]  63T v0 L- c3/3
  2004 3 > \ [??\\]  63T v- L- c3/4     node 3 (log length 4: the ONLY electable node) re-arms
                                        ...and refuses node 0: node 0's log is behind
  2033 0 ? ? [??\\]  64T v0 L- c3/3     30 ticks later node 0 fires again, 1 tick before node 3
  2034 3 > \ [??\\]  64T v- L- c3/4     ...and re-arms node 3 again. Same order, every round.
```

Node 3 is the only node whose log lets it win. Node 0's timer is armed when node 0 starts its
election, and node 3's is armed when node 0's RequestVote arrives, a delivery later. So node 0
fires first. Over the window, node 3's timer was reset early 67 times this way. In the other 32
rounds the delays lined up so that node 3 fired within a tick or two of the others (`2304`:
nodes 0, 2, 3 all stand within 1 tick), and the round was a classic split vote. Either way, the
next shared event re-synchronizes everyone. The checker reports:

```
LIVENESS VIOLATED: no stable leader 3000 ticks after heal: terms advanced 62->162 during the convergence window with no leader elected
  100 election rounds: 52 split votes (52 simultaneous: all candidates timed out within 6 ticks, before any RequestVote could arrive), 47 lone candidates refused by a voter with a longer log
  term 162: timed out at ticks 4973..4974, quorum 3, votes: 0<-{0} 2<-{2} 3<-{3} refused-for-log:{3} leader=none
safety: OK: election safety held (2 leaders, at most one per term, highest led term 35); committed prefix of 3 entries never rewritten; counter exactly-once
```

The same seed with the correct code converges 11 ticks after the heal. (The safety phase plays
out differently there, because the timeouts differ from tick 0.)

**Why normal tests miss it.** A 3-node unit test with a fixed timeout often *passes*: crashes,
loss, or one lucky delay break the symmetry, and a leader is elected. Under the bug, 1578 of 2000
seeds still converge. The failure needs the right log shape (the node that fires first is not
electable) or a delay pattern that keeps nodes within one message of each other. A test also has
to *wait* through a whole window before it can conclude anything, and a test that only checks
safety stays green forever. The livelock also hides in the safety phase, where elections that
fail under faults look normal.

`stats --spread=K` measures how much randomization is enough (500 seeds per K, split votes as a
share of election rounds in the liveness window, from `site/data/11/spread.tsv`): K=0: 10619/12062
rounds split, 119 of 500 seeds never elect a leader. K=1: 138/340. K=4: 48/215. K=20 (default):
11/170. K=40: 4/144. One tick of jitter is already enough to end the livelock; more jitter makes
split votes rare.

### `--bug-no-retry-on-leader-change`: the request nobody retries

When a leader appends a client's request it sends `accepted(index, term)`. The buggy client
trusts that too much:

```zig
// "a leader accepted it, so it will be committed; just wait for the reply."
if (bug_no_retry and cl.accepted) return;   // the retry timer is never checked again
```

That is only true while that leader stays leader. If it is deposed before the entry commits, the
new leader's log wins, the entry is truncated, and its index is filled with something else. No
retry ever re-submits the request. Nothing wrong is committed: nothing is committed at all.

**Why I chose this one.** It is a different *kind* of bug from the livelock. The cluster is
perfectly healthy (stable leader 22 ticks after the heal on the failing seed), and only one
client is stuck. So the checker needs the second clause (every request committed), not just "a
leader exists". The bug is also realistic. "Accepted" or "acknowledged by the leader" status codes
are common in real client libraries. Raft §8 and VSR both require clients to retry until they get
a reply, with a session table making the retry safe. TigerBeetle's client keeps
`request_timeout` running until `on_reply` and re-sends on every timeout. A stuck replica that
never catches up would have been a third kind; clause 5 of the checker would report it as
`not_caught_up`.

Seed 3 (3 nodes, two clients):

```
   456 1 * / [\/\]   6T v1 L1 c14/14     node 1 leads term 6
   572 - P partition 1|02                node 1 is isolated (it still thinks it leads)
   604 0 * / [//\]   7T v0 L0 c18/18     node 0 leads term 7 on the majority side
   622 c0 S #8 node=1                    client 0 sends #8 to its last known leader, node 1
   626 c0 A #8 node=1                    node 1 (term 6) appends it at index 19: "accepted"
   697 - H heal
   701 1 > \ [/\\]   7T v- L- c18/19     node 1 learns term 7...
   701 1 x \ [/\\]   7T v- L0 c18/18     ...and truncates index 19. Request #8 is gone.
```

The checker explains exactly why progress didn't happen:

```
LIVENESS VIOLATED: request c0#8 pending for 4378 ticks (submitted at tick 622, last sent at tick 622)
  accepted by node 1 in term 6 as index 19 at tick 626; index 19 was committed with a term-7 no-op instead: the entry was discarded by a later leader, and the client never re-sent it
safety: OK: election safety held (7 leaders, at most one per term, highest led term 14); committed prefix of 23 entries never rewritten; counter exactly-once
```

**Why normal tests miss it.** The bug needs a client to reach a leader that has *already lost*
its leadership but does not know it yet: a stale leader on the minority side of a partition.
Without partitions, an accepted entry nearly always commits. With 727 of 2000 seeds failing,
the sweep finds it at seed 3. But every one of those runs would pass a safety-only checker, and
a "did the cluster elect a leader?" liveness checker as well.

## How TigerBeetle does this

- **Safety phase, then liveness phase**: `src/vopr.zig` `main` first ticks until all requests are
  replied (or `ticks_max_requests` passes without progress). Then it picks a core:
  `random_core(...)` if the requests finished, `full_core(...)` if safety mode stalled. Then it
  calls `simulator.transition_to_liveness_mode(core)` and ticks until `simulator.pending()` is
  null, for at most `ticks_max_convergence`.
- **`Simulator.transition_to_liveness_mode`**: "Restart any core replicas that are down at the
  moment. Heal all network partitions between core replicas. Disable storage faults on the core
  replicas. For all failures involving non-core replicas, make those failures permanent." This
  example does the same (there is no storage here) in `Simulator.transition_to_liveness_mode`.
- **The liveness network stays jittery**: `Network.transition_to_liveness_mode` in
  `src/testing/cluster/network.zig` sets `one_way_delay_min = .ms(1)` and
  `one_way_delay_mean = .ms(1)`, and zeroes loss, replay, and partition probabilities. The
  delay is still `packet_delay_default`'s exponential draw (`src/testing/packet_simulator.zig`),
  so this example also keeps a small random tail.
- **`pending()` returns a reason**: `"pending request"`, `"pending replica convergence"`,
  `"pending journal"`, and so on. On failure the VOPR logs it: `fatal(.liveness, "no state
  convergence: {s}", .{reason})`. `diagnose()` here is the same idea taken further: it names the
  terms, the rounds, the votes, or the stuck request and what happened to its entry.
- **`cluster_recoverable`** calls `core_missing_primary`, `core_missing_quorum`,
  `core_missing_prepare`, `core_missing_blocks`, and `core_missing_reply`, and reports a liveness
  bug only when none of them explains the stall. This separates "the code is wrong" from "the
  simulator made recovery impossible".
- **Randomized timeouts against thundering herds**: `Timeout.reset_with_jitter` in `src/vsr.zig`
  draws `after_dynamic` "uniformly between [0.5 * timeout, 1.5 * timeout]".
  `exponential_backoff_with_jitter` is documented as "Calculates exponential backoff with jitter
  to prevent cascading failure due to thundering herds", and `Timeout.backoff` uses it.
  `--bug-fixed-timeout` removes exactly this jitter.
- **Clients retry until they get a reply**: in `src/vsr/client.zig`, `on_request_timeout` lists
  the reasons a request times out, including "there was a view change, and we are not speaking
  to the primary". It calls `request_timeout.backoff(&self.prng)` and re-sends the same request
  (`send_request_with_hedging`). The timeout stops only in `on_reply`.
  `--bug-no-retry-on-leader-change` stops it early.
- Blog post: "Simulation Testing for Liveness", linked from `docs/internals/vopr.md`.

## Verified run

Built with Zig 0.17.0: `zig build-exe -OReleaseSafe main.zig -femit-bin=/tmp/dst-bin/11`. The
outputs below come from `site/tools/capture.sh 11` (files in `site/data/11/`).

Sweep without a bug:

```
$ /tmp/dst-bin/11 sweep
PASS: 20000 seeds

real	0m6.254s
```

Sweep with each bug (the diagnosis lines are printed as well; abridged here):

```
$ /tmp/dst-bin/11 sweep 20000 --bug-fixed-timeout
cluster_recoverable: yes (core=3/4 nodes, quorum=3, all up, all core links healthy)
LIVENESS VIOLATED: no stable leader 3000 ticks after heal: terms advanced 62->162 during the convergence window with no leader elected
  100 election rounds: 52 split votes (52 simultaneous: all candidates timed out within 6 ticks, before any RequestVote could arrive), 47 lone candidates refused by a voter with a longer log
  ...
FAIL at seed=11 (no_stable_leader) after 12 seeds. Replay with:
  zig run main.zig -- run 11 --bug-fixed-timeout

$ /tmp/dst-bin/11 sweep 20000 --bug-no-retry-on-leader-change
cluster_recoverable: yes (core=2/3 nodes, quorum=2, all up, all core links healthy)
LIVENESS VIOLATED: request c0#8 pending for 4378 ticks (submitted at tick 622, last sent at tick 622)
  accepted by node 1 in term 6 as index 19 at tick 626; index 19 was committed with a term-7 no-op instead: the entry was discarded by a later leader, and the client never re-sent it
FAIL at seed=3 (request_stuck) after 4 seeds. Replay with:
  zig run main.zig -- run 3 --bug-no-retry-on-leader-change
```

Replays, each run twice. Each pair of outputs is byte-identical (`cmp` reports no difference):

```
run 11 --bug-fixed-timeout                (867 lines)  sha256 9bfcdd106aa2577007b746c9dc7fc94aff59bcf080a44b4c76abbbd548448bd7  (both runs)
run 3 --bug-no-retry-on-leader-change     (148 lines)  sha256 a2e4cecdd55a231d304c3a944cbf5798ec1549393aa7abca85841d5185966336  (both runs)
```

Last lines of both runs:

```
seed=11 ticks=5000 trace=366aa43a8fe148f1 FAIL no_stable_leader
seed=11 ticks=5000 trace=366aa43a8fe148f1 FAIL no_stable_leader

seed=3 ticks=5000 trace=88582559ded66ffd FAIL request_stuck
seed=3 ticks=5000 trace=88582559ded66ffd FAIL request_stuck
```

The same seeds with the correct code:

```
seed=11 ticks=2011 trace=9191ccd8de56db0b PASS     (stable leader 6 ticks after heal, converged after 11)
seed=3 ticks=2039 trace=69557ce2ca90774b PASS      (converged 39 ticks after heal)
```

`zig run main.zig -- run 11 --bug-fixed-timeout` in the default Debug mode prints the same
`trace=366aa43a8fe148f1`.

Over 2000 seeds (`stats 2000`): correct code 2000 pass. `--bug-fixed-timeout`: 422
`no_stable_leader`, 1578 pass. `--bug-no-retry-on-leader-change`: 727 `request_stuck`, 1273
pass. No safety failure under either flag.

## Exercises

1. **PreVote fixes a different livelock.** With the correct timeouts, add a node that can send
   but not receive (an asymmetric partition, as in example 08) to the core. It keeps raising its
   term and deposes healthy leaders. Is that a liveness failure under this checker? Add Raft's
   PreVote and compare the `rounds` column of `stats`.
2. **Exponential backoff instead of jitter.** Keep the timeout fixed, but have a candidate that
   lost a round back off with `exponential_backoff_with_jitter` (port it from `src/vsr.zig`). How
   much jitter does backoff need before `--bug-fixed-timeout` stops failing? Plot it with
   `--spread`.
