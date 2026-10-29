# Example 05 — A simulated network

## Concept introduced

A **packet simulator** stands in for the network. Each path (source → target) holds a priority
queue of in-flight messages, keyed by the tick at which each one becomes deliverable. Ties are
broken by a send sequence number, so the order is total and deterministic. Every network fault
is a decision drawn from the seeded PRNG:

| Fault | Mechanism |
|---|---|
| delay / reordering | `ready_at = now + max(delay_min, Exponential(delay_mean))`. Two packets sent in order can arrive in either order. |
| loss | a packet popped from the queue is dropped with probability `packet_loss` |
| replay (duplication) | a delivered packet is pushed back in with probability `packet_replay` and a fresh delay, so it arrives again later |
| capacity drop | a path holds at most `path_maximum_capacity` packets. When one more arrives, a random in-flight packet is dropped. |
| clogging | each tick, each path may clog for `Exponential(clog_mean)` ticks, and nothing is delivered on it during that time |

The fault parameters themselves are drawn from the seed and printed first, the way the VOPR
does. One seed gets a calm LAN and the next gets a network that loses 30% and duplicates 50% of
packets.

The run has two phases. In the **safety phase**, all faults are on and the invariants are
checked after every delivery. Then a **heal** (`transition_to_liveness_mode`) turns off loss and
replay and drops the delay to 1 tick. After the heal, every request must finish within a tick
budget.

## What is simulated vs real

- **Simulated:** the network (all five fault types above), time (a tick counter), the clients'
  think time and amounts, and the retry timers (exponential backoff with jitter).
- **Real:** the server's session and dedup logic (`Server.on_request`) and the client's
  request/retry/reply-matching logic (`Client.tick`, `Client.on_reply`). This is the code under
  test.
- **Determinism:** one master PRNG per seed derives the network seed and one seed per client.
  There are no threads, IO, or clock. Paths are visited in a fixed order, and the heap order is
  total `(ready_at, sequence)`. Every send, loss, replay, capacity drop, clog, delivery, apply,
  duplicate, retry and reply is folded into a Wyhash trace.

## Invariants

1. **Exactly-once balance (safety, after every delivery to the server):** `server.balance ==` the
   sum of the amounts of the *distinct* `(client, request)` pairs the server has received. The
   checker computes this with no access to server internals. A client sends `r+1` only after it
   has the reply to `r`, so a delivered request is either new (`== max_seen + 1`) or a repeat
   (`<= max_seen`).
2. **Replies are the original replies (safety, after every delivery to a client):** a reply for
   `(c, r)` must carry exactly the balance that `r` produced when it was applied. The checker
   looks at *every* reply on the wire, including late duplicates that the client will discard.
3. **Liveness (after the heal):** every client gets all of its replies within
   `ticks_max_convergence` = 3000 ticks. A network that drops 100% of packets would pass every
   safety check. Only this check notices that nothing is getting done. I confirmed the check is
   not vacuous: in a throwaway copy, I made the server drop duplicates instead of resending the
   cached reply. It failed at seed 0 with `LIVENESS VIOLATED: client 0 has 9/24 replies`.

## The planted bug(s) and why normal tests miss them

- **`--bug-no-dedup`:** the server applies every request it receives and ignores the session. A
  happy-path test sends one request, gets one reply, and passes. The double apply needs either
  (a) a request that arrives, gets applied, and then has its *reply* lost, so the client times out
  and resends, or (b) a network-level duplicate. Localhost TCP produces neither. In seed 0, the
  replay of `c0 r2` arrives one tick after the original and the balance jumps by 455 a second
  time.
- **`--bug-reply-stale`:** when a retry of an already-applied request arrives, the server builds
  the reply from the *current* state instead of returning the reply it cached. This is
  "obviously fine" in a single-client test, because nothing else moved the balance, so the
  recomputed reply equals the cached one. It takes a second client's transfer landing between the
  apply and the retry to make the numbers differ. In seed 0, `c3 r6` is applied between `c0 r2`'s
  apply and `c0 r2`'s duplicate. The client accepted the correct first reply (`balance=8019`), and
  the duplicate that followed said `8222`. If the first reply had been lost, the client would have
  accepted the wrong number. Across seeds 0..299, 60 of the 81 one-client seeds pass even with
  this bug on. The 21 that fail were caught only because the checker inspects replies to *older*
  replayed requests, which the client itself discards.

Neither bug ever shows up with a perfect network, which is why the fault parameters are part of
the seed. Over seeds 0..499, `--bug-no-dedup` failed 494 times and `--bug-reply-stale` 406 times.
The correct code failed 0 times. In 288 of those 500 seeds, clients were still sending or
receiving after the heal, so the liveness phase does real work.

## How TigerBeetle does this

- `src/testing/packet_simulator.zig`:
  - `PacketSimulatorOptions` holds `one_way_delay_mean`/`_min`, `packet_loss_probability`,
    `packet_replay_probability`, `path_maximum_capacity`, `path_clog_duration_mean` and
    `path_clog_probability`.
  - Each `Link` has a priority `queue` keyed by `ready_at`, plus `clogged_till`.
  - `submit_packet()`: when the queue would exceed `path_maximum_capacity`, it drops a random
    packet (`queue.popIndex(self.prng.index(queue.items))`), then pushes with
    `ready_at = now + packet_delay()`.
  - `packet_delay_default()` is `max(min, fuzz.random_int_exponential(mean))`.
  - `submit_packet_finish()` decides loss (`should_drop`) and replay (`should_replay` →
    `submit_packet(packet_clone(...))`) at delivery time, as this example does.
  - `tick()` clogs paths with `should_clog` / `clog_for` and an exponential duration.
  - `step()` skips clogged paths.
- `src/testing/fuzz.zig` `random_int_exponential()`: `floatExp(f64) * avg`. This example's
  `Network.exponential` is the same.
- `src/vopr.zig`:
  - The network options are drawn from the seed (`one_way_delay_min = range_inclusive_ms(prng,
    0, 30)`, `packet_loss_probability = ratio(prng.int_inclusive(u8, 30), 100)`, and so on) and
    printed in the `SEED=…` block before the run.
  - `Simulator.transition_to_liveness_mode()` is called once the requests are done or the
    safety-phase ticks run out. After it, the loop requires `simulator.pending() == null` within
    `ticks_max_convergence`.
- `src/testing/cluster/network.zig` `transition_to_liveness_mode()`: sets delay to 1 ms, zeroes
  loss, replay and partition probabilities, and unfilters the core's links. It does *not* zero
  clogging: a clog always ends, so it can slow progress but cannot stop it. This example copies
  that choice.
- `src/vsr/client.zig`:
  - The client has a single `request_inflight`.
  - `on_request_timeout()` calls `request_timeout.backoff(&self.prng)` and resends the *same*
    message.
  - `on_reply()` ignores replies with `reply.header.request < inflight.message.header.request`
    and asserts that a matching reply has the inflight's number.
- `src/vsr/client_sessions.zig`:
  - `ClientSessions.Entry` is `{ session, header: vsr.Header.Reply }`, the header of the reply to
    the latest committed request.
  - The doc comment describes two bugs in the original VRR paper's client table: wrong replies
    from colliding request numbers, and lockout when request numbers get reordered.
- `src/vsr/replica.zig` `ignore_request_message_duplicate()`: this is the decision table that
  `Server.on_request` copies.
  - `entry.header.request > message.header.request` → "ignoring older request".
  - `==` (with a matching checksum) → `on_request_repeat_reply()`, which resends the *stored*
    reply.
  - `entry.header.request + 1 == message.header.request` → new request.

## Verified run

Built with `/home/user/tools/zig-0.17.0/zig build-exe main.zig -O ReleaseSafe
-femit-bin=/tmp/dst05`. `zig run -O ReleaseSafe main.zig -- run 0 --bug-reply-stale` prints the
same trace hash.

Sweep without bugs (default count 10000, about 1 s):

```
$ /tmp/dst05 sweep
PASS: 10000 seeds
exit=0
```

Sweep with each bug:

```
$ /tmp/dst05 sweep 10000 --bug-no-dedup
FAIL at seed=0 after 1 seeds. Replay with:
  zig run main.zig -- run 0 --bug-no-dedup
exit=1

$ /tmp/dst05 sweep 10000 --bug-reply-stale
FAIL at seed=0 after 1 seeds. Replay with:
  zig run main.zig -- run 0 --bug-reply-stale
exit=1
```

Replaying twice. The full outputs were byte-for-byte identical (`cmp`), and both runs exited
with 1. The header and tail are shown here:

```
$ /tmp/dst05 run 0 --bug-reply-stale

          SEED=0

          clients=4
          requests_per_client=24
          request_timeout=10 ticks
          ticks_max_safety=847 ticks
          one_way_delay_mean=3 ticks
          one_way_delay_min=1 ticks
          packet_loss_probability=13%
          packet_replay_probability=17%
          path_maximum_capacity=20 messages
          path_clog_duration_mean=7 ticks
          path_clog_probability=6/1000 per tick

  [    1] client 2: send r1 transfer(219)
  ...
  [   42] server: apply c0 r2 amount=455 balance=8019
  [   42] server: apply c3 r6 amount=203 balance=8222
  [   43] server: duplicate c0 r2 -> reply with current balance=8222
  [   43] server: duplicate c3 r6 -> reply with current balance=8222
  [   44] client 1: send r4 transfer(302)
  [   45] client 0: reply r2 balance=8019
  [   45] INVARIANT VIOLATED: reply c0 r2 says balance=8222, but r2 produced balance=8019
seed=0 ticks=45 trace=967f8d2b76791c6e FAIL

$ /tmp/dst05 run 0 --bug-reply-stale      # second time
  ...
  [   45] INVARIANT VIOLATED: reply c0 r2 says balance=8222, but r2 produced balance=8019
seed=0 ticks=45 trace=967f8d2b76791c6e FAIL
```

```
$ /tmp/dst05 run 0 --bug-no-dedup         # run twice; outputs identical
  ...
  [   42] server: apply c0 r2 amount=455 (no dedup)
  [   42] server: apply c3 r6 amount=203 (no dedup)
  [   43] server: apply c0 r2 amount=455 (no dedup)
  [   43] INVARIANT VIOLATED: server balance=8677, sum of distinct requests=8222
seed=0 ticks=43 trace=d88bc34622415f6f FAIL
```

The same seed with the correct code (tail):

```
$ /tmp/dst05 run 0
  ...
  [  578] transition_to_liveness_mode: loss=0 replay=0 delay=1

  balance=50214 sent=303 lost=32 replayed=50 capacity_dropped=0 clogs=21
seed=0 ticks=578 trace=1e84e7c45a1d42c1 PASS
```

## Extra output flags
These only add output for the visual site (`site/`). They draw nothing from the PRNG and are not hashed, so
sweeps and trace hashes are the same with or without them.

- `--packets`: print every send (delay, ready_at, queue depth), loss, replay, delivery and capacity drop.

## Exercises

1. **Liveness bug.** Make the server *ignore* a duplicate of the latest request instead of
   resending the cached reply ("it's already applied, nothing to do"). Every safety invariant
   still holds. Which check fails, and why does it fire only after the heal? (Expected:
   `LIVENESS VIOLATED` at seed 0.)
2. **Pipelining.** Let a client keep 2 requests in flight. Show that a session of
   "last request number + one cached reply" is no longer enough. Find the seed where request
   `r`'s reply is lost after `r+1` was applied. Then compare with why `vsr/client.zig` allows
   only one `request_inflight`.
