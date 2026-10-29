# 03 — A deterministic scheduler

## Concept introduced

Concurrency is just another random input. We replace OS threads with **tasks written as explicit
state machines**: each `Task` holds a program counter (`pc: Pc`) and the "locals" that must
survive a yield (`seen_from`, `seen_to`). `World.step(task)` runs one atomic slice and advances
`pc`, and every transition is a yield point. A single-threaded **scheduler** collects the runnable
tasks in index order and lets the seeded PRNG pick which one steps next:

```zig
const pick = runnable[scheduler.uintLessThan(u8, runnable_count)];
```

That one line takes the place of the OS thread scheduler. The interleaving now comes from the
seed, so a lost update or a deadlock becomes a number you can replay.

## What is simulated vs real

| Real | Simulated |
|---|---|
| The transfer logic (read, check funds, write) | Threads become `Task` state machines |
| The lock protocol (acquire order, release) | Mutexes become `lock_owner[account]`. Acquiring is a single step, so it is atomic. A task waiting on a lock is simply not runnable, so it never spins. |
| The invariant checks | Preemption becomes the seeded choice of the next runnable task |
| | Time becomes the tick counter (one tick per step) |

The root seed produces two sub-seeds. One generates the workload (2–4 accounts at $100 each,
2–5 tasks, each with 1–3 transfers of $1–60). The other drives the scheduler. The same workload
can therefore be explored under many schedules.

## Invariants

`World.check()` runs after every step, not just at the end:

1. **No negative balance.**
2. **Conservation.** When no task is `in_flight` (meaning it has debited `from` but not yet
   credited `to`), the sum of balances equals `100 * accounts`. Conservation is only checked when
   no transfer is mid-flight, because money is legitimately "in the air" between `write_from` and
   `write_to`.
3. **Lock discipline** (both locking designs). A task in `read_*` or `write_*` must own the locks
   on both of its accounts.

Liveness: if no task is runnable but some are unfinished, the run fails with `deadlock` and
prints the wait-for graph. A `ticks_max` bound catches spinning.

## The planted bug(s) and why normal tests miss them

- **`--bug`: no locking.** `Task.first_pc()` skips straight to `read_from`. In seed 0, T1 reads
  acct0 = 100 at t=0. T0 then debits acct0 to 59 at t=3. At t=7, T1 writes 100 − 28 = 72 over it,
  so T0's $41 debit is lost. In total, $13 is created (213 instead of 200). The checker reports
  the failure at tick 16, the first moment when no transfer is mid-flight.
- **`--bug-deadlock`: locks taken in argument order** (`lock_order()` returns `{from, to}`
  instead of `{min, max}`). In seed 1, T3 (2→1) locks acct2 and T4 (1→2) locks acct1. Each then
  waits for the other, and everyone else queues behind them. The run fails 3 ticks in.

Why real threads plus stress tests find these only now and then, and can't replay them:

- **The bad window is tiny.** On real hardware, a thread usually runs read → write in
  nanoseconds without being preempted. The lost update needs a context switch, or a racing core,
  in exactly that window, and the deadlock needs both threads to take their first lock before
  either takes its second. A stress test can pass a million times on a developer laptop and then
  fail on a loaded CI machine.
- **You can't control the schedule.** It depends on the OS scheduler, core count, cache misses,
  other processes and timer interrupts. None of these are inputs you can record, so a failing run
  can't be replayed. Adding logging or attaching a debugger changes the timing, and the bug often
  disappears (a "heisenbug").
- **A failed run tells you little.** A wrong final total or a hung process doesn't say which
  interleaving caused it. Here, the seed **is** the interleaving: the run prints the full
  `schedule`, every read and write with its value, and the tick at which the invariant broke.
  Two runs give byte-identical output (see below).
- **Our scheduler can preempt anywhere, and does so often.** Uniform choice at every yield point
  hits the bad windows far more often than real hardware does. Over the first 1000 seeds, `--bug`
  fails on 928 and `--bug-deadlock` fails on 569.

## How TigerBeetle does this

TigerBeetle doesn't need a fake thread scheduler, because the real code is already built like this
example. It is single-threaded, every blocking operation is an async submission plus a callback,
and long operations are explicit stage machines:

- `src/vsr/replica.zig`: `CommitStage` (line ~83) is a program counter for the commit pipeline
  (`idle`, `start`, `check_prepare`, `prefetch`, `stall`, `reply_setup`, `execute`, checkpoint
  stages...). `commit_dispatch()` (line ~4398) switches on `commit_stage` and advances it each
  time an IO callback resumes it. This is our `switch (task.pc)` at production scale.
- `src/testing/io.zig`: the test `IO.submit()` pushes a `Completion` onto the `completed` queue,
  and `IO.run()` pops completions and calls their callbacks. Callbacks are the yield points, and
  the queue is the run queue.
- `src/testing/storage.zig`: `Storage.step()` (line ~361) completes the next ready read or write.
  The order is decided by simulated `ready_at` times drawn from the seeded PRNG
  (`read_latency()` / `write_latency()`). This is how the simulator chooses which pending
  operation's callback runs next.
- `src/testing/cluster.zig`: `Cluster.tick()` (line ~526) loops `network.step()` and
  `storage.step()` for every replica until nothing advances. Then it ticks time.
- `src/vopr.zig`: `Simulator.tick()` (line ~842) calls `cluster.tick()` plus request, crash,
  upgrade and pause injection. `main()` runs `while (tick < ticks_max_...) simulator.tick()`.
  All of it derives from `stdx.PRNG.from_seed(seed)`, and a failure prints "you can reproduce this
  failure with seed=…". Liveness is checked the same way as our deadlock detector: after the
  safety phase, `transition_to_liveness_mode` heals a core of replicas, and the run must converge
  (`simulator.pending() == null`) within `ticks_max_convergence`.

## Verified run

Built with Zig 0.17.0, ReleaseSafe, with the binary in /tmp:

```
$ zig build-exe main.zig -OReleaseSafe -femit-bin=/tmp/dst03
$ time /tmp/dst03 sweep 1000000
PASS: 1000000 seeds

real	0m4.145s
```

```
$ /tmp/dst03 sweep 1000000 --bug
FAIL at seed=0 (money_not_conserved) after 1 seeds. Replay with:
  zig run main.zig -- run 0 --bug

$ /tmp/dst03 sweep 1000000 --bug-deadlock
FAIL at seed=1 (deadlock) after 2 seeds. Replay with:
  zig run main.zig -- run 1 --bug-deadlock
```

Replay of the lost update. The full output is identical on a second run, shown here by its
final line:

```
$ /tmp/dst03 run 0 --bug
accounts=2 (balance 100 each) tasks=2
  T0: [0->1 $41] [1->0 $1] [0->1 $56]
  T1: [0->1 $28] [0->1 $3]
  t=  0 T1 read    acct0 = 100
  t=  1 T0 read    acct0 = 100
  t=  2 T0 read    acct1 = 100
  t=  3 T0 write   acct0 := 59
  t=  4 T1 read    acct1 = 100
  t=  5 T0 write   acct1 := 141
  t=  6 T0 read    acct1 = 141
  t=  7 T1 write   acct0 := 72
  t=  8 T1 write   acct1 := 128
  t=  9 T1 read    acct0 = 72
  t= 10 T0 read    acct0 = 72
  t= 11 T1 read    acct1 = 128
  t= 12 T1 write   acct0 := 69
  t= 13 T1 write   acct1 := 131
  t= 14 T0 write   acct1 := 140
  t= 15 T0 write   acct0 := 73
schedule (16 ticks, task picked per tick): 1 0 0 0 1 0 0 1 1 1 0 1 1 1 0 0
balances: 73 140  total=213 expected=200
FAILURE: money_not_conserved at tick 16
seed=0 ticks=16 trace=60d07731b56382d1 FAIL
$ /tmp/dst03 run 0 --bug 2>&1 | tail -1
seed=0 ticks=16 trace=60d07731b56382d1 FAIL
$ zig run -OReleaseSafe main.zig -- run 0 --bug 2>&1 | tail -1
seed=0 ticks=16 trace=60d07731b56382d1 FAIL
```

Replay of the deadlock, run twice with identical output (the second run shown by its final line):

```
$ /tmp/dst03 run 1 --bug-deadlock
accounts=3 (balance 100 each) tasks=5
  T0: [0->2 $32] [0->2 $47] [1->0 $35]
  T1: [0->1 $33] [0->1 $14] [2->1 $30]
  T2: [0->2 $8] [1->0 $10] [2->0 $4]
  T3: [2->1 $59]
  T4: [1->2 $8]
  t=  0 T3 lock    acct2
  t=  1 T4 lock    acct1
  t=  2 T2 lock    acct0
schedule (3 ticks, task picked per tick): 3 4 2
balances: 100 100 100  total=300 expected=300
FAILURE: deadlock at tick 3
  T0 waits for acct0, held by T2
  T1 waits for acct0, held by T2
  T2 waits for acct2, held by T3
  T3 waits for acct1, held by T4
  T4 waits for acct2, held by T3
seed=1 ticks=3 trace=026ddce53296649e FAIL
$ /tmp/dst03 run 1 --bug-deadlock 2>&1 | tail -1
seed=1 ticks=3 trace=026ddce53296649e FAIL
```

For contrast, the correct design runs the same workload as seed 0 without failing (the scheduler
draws differ because locks change which tasks are runnable):

```
$ /tmp/dst03 run 0 2>&1 | tail -3
schedule (33 ticks, task picked per tick): 1 1 1 1 1 1 1 1 1 1 1 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
balances: 29 171  total=200 expected=200
seed=0 ticks=33 trace=a40e7c5a03659fe8 PASS
```

## Exercises

1. **Model real preemption.** Make the scheduler "sticky": keep running the same task with
   probability 95% and switch only otherwise. Measure how many seeds `--bug` now needs before it
   fails. This is the stress-test experience in miniature, and it is why TigerBeetle's VOPR uses
   *swarm testing* (`options_swarm` in `src/vopr.zig`) to randomize the fault and latency
   parameters per seed.
2. **Replace per-account locks with a single global lock** (one `lock_owner`, a single
   `lock_first` step). Confirm that it passes the sweep and can never deadlock. Then count the
   average number of ticks during which two or more tasks are runnable, as a crude measure of
   lost concurrency.
