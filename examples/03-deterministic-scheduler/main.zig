//! Example 03 — A deterministic scheduler: concurrency bugs you can replay.
//!
//! Concurrency bugs are the classic "can't reproduce" bugs: they depend on the order in which
//! the OS happens to run threads, and that order changes on every run. DST removes the OS from
//! the picture. Instead of threads we write each concurrent activity as an explicit STATE
//! MACHINE: a `Task` struct holding a program counter (`pc`) and the "local variables" that must
//! survive across a yield. `step()` runs exactly one atomic slice of the task and advances `pc`.
//! A single-threaded scheduler, driven by the seeded PRNG, picks which runnable task steps next.
//! The interleaving is now just another random input: the seed reproduces it exactly.
//!
//! This is the TigerBeetle shape: one thread, an event loop, and code that is written as
//! callbacks / explicit stages instead of blocking calls (see NOTES.md).
//!
//! System under test: N transfer tasks over a few shared bank accounts. Each transfer is
//!     lock → lock → read from → read to → write from → write to → unlock
//! with a yield (a scheduling point) between every step.
//!
//! Invariants, checked after EVERY step (not just at the end):
//!   * no balance is negative;
//!   * whenever no transfer is mid-flight (debited `from` but not yet credited `to`), the total
//!     money equals the initial total;
//!   * (locking modes) a task touching an account holds that account's lock.
//! Liveness: if no task is runnable but some are unfinished, that is a deadlock.
//!
//! Correct version: per-account locks, acquired in a FIXED global order (lowest index first).
//! Planted bugs:
//!   --bug           no locking at all            → lost update, money is created/destroyed.
//!   --bug-deadlock  locks taken in argument order → A→B and B→A deadlock.
//!
//! Usage:
//!   zig run main.zig -- run   <seed>  [--bug] [--bug-deadlock]   # one seed, prints schedule
//!   zig run main.zig -- sweep <count> [--bug] [--bug-deadlock]   # seeds 0..count-1
const std = @import("std");
const assert = std.debug.assert;

const accounts_max = 4;
const tasks_max = 5;
const transfers_per_task_max = 3;
const initial_balance: i64 = 100;
/// Each transfer is at most 7 steps, so a run is at most 5 * 3 * 7 = 105 ticks. If we ever get
/// near this bound something is spinning; treat it as a liveness failure.
const ticks_max = 1024;

var bug_no_lock = false;
var bug_deadlock = false;

/// The program counter. Every arrow between these states is a yield point: the scheduler may
/// run any other task there. In a real threaded program the "yield points" are everywhere (any
/// instruction); here we make them explicit, which is both honest about where interleaving
/// matters and what makes exhaustive exploration of schedules possible.
const Pc = enum(u8) {
    lock_first,
    lock_second,
    read_from,
    read_to,
    write_from,
    write_to,
    unlock,
    done,
};

const Transfer = struct { from: u8, to: u8, amount: i64 };

const Task = struct {
    id: u8,
    transfers: [transfers_per_task_max]Transfer,
    transfer_count: u8,
    transfer_index: u8 = 0,
    pc: Pc,
    // "Locals" that must survive a yield live in the struct, not on a stack. This is exactly
    // what a callback-style program does with its context struct.
    seen_from: i64 = 0,
    seen_to: i64 = 0,

    /// Debited `from` but not yet credited `to`: money is legitimately "in the air".
    fn in_flight(task: *const Task) bool {
        return task.pc == .write_to;
    }

    fn current(task: *const Task) Transfer {
        assert(task.transfer_index < task.transfer_count);
        return task.transfers[task.transfer_index];
    }

    /// The order in which this task takes its two locks.
    fn lock_order(task: *const Task) [2]u8 {
        const t = task.current();
        // BUG (--bug-deadlock): lock in argument order. Task X (0→1) takes 0 then 1, task Y
        // (1→0) takes 1 then 0. If both take their first lock, each waits on the other forever.
        if (bug_deadlock) return .{ t.from, t.to };
        // Correct: a global order (lowest account first) makes a wait-for cycle impossible.
        return .{ @min(t.from, t.to), @max(t.from, t.to) };
    }

    fn first_pc() Pc {
        // BUG (--bug): skip locking entirely.
        return if (bug_no_lock) .read_from else .lock_first;
    }

    /// The account this task wants to lock next, if it is about to acquire a lock.
    fn wants_lock(task: *const Task) ?u8 {
        return switch (task.pc) {
            .lock_first => task.lock_order()[0],
            .lock_second => task.lock_order()[1],
            else => null,
        };
    }
};

/// One observable event, for the verbose trace and the trace hash.
const Event = struct { task: u8, pc: Pc, account: u8, value: i64 };

const World = struct {
    account_count: u8,
    balances: [accounts_max]i64 = @splat(initial_balance),
    /// Index of the task holding each account's lock. Acquiring a lock is a single step, which
    /// is atomic because only one task steps at a time — no real mutex needed.
    lock_owner: [accounts_max]?u8 = @splat(null),
    task_count: u8,
    tasks: [tasks_max]Task = undefined,

    fn runnable(world: *const World, task: *const Task) bool {
        if (task.pc == .done) return false;
        // A task blocked on a held lock is simply not runnable: no spinning, no busy-waiting.
        if (task.wants_lock()) |account| return world.lock_owner[account] == null;
        return true;
    }

    fn finish_transfer(task: *Task) void {
        task.transfer_index += 1;
        task.pc = if (task.transfer_index == task.transfer_count) .done else Task.first_pc();
    }

    /// Leave the critical section: release the locks, or (no locks) go straight to the next transfer.
    fn end_critical_section(task: *Task) void {
        if (bug_no_lock) finish_transfer(task) else task.pc = .unlock;
    }

    /// Run ONE atomic slice of `task`, then yield back to the scheduler.
    fn step(world: *World, task: *Task) Event {
        assert(world.runnable(task));
        const t = task.current();
        const pc = task.pc;
        switch (pc) {
            .lock_first, .lock_second => {
                const account = task.wants_lock().?;
                assert(world.lock_owner[account] == null);
                world.lock_owner[account] = task.id;
                task.pc = if (pc == .lock_first) .lock_second else .read_from;
                return .{ .task = task.id, .pc = pc, .account = account, .value = 0 };
            },
            .read_from => {
                task.seen_from = world.balances[t.from];
                task.pc = .read_to;
                return .{ .task = task.id, .pc = pc, .account = t.from, .value = task.seen_from };
            },
            .read_to => {
                task.seen_to = world.balances[t.to];
                if (task.seen_from < t.amount) {
                    // Insufficient funds: abort this transfer (still releasing the locks).
                    end_critical_section(task);
                    return .{ .task = task.id, .pc = pc, .account = t.to, .value = -1 };
                }
                task.pc = .write_from;
                return .{ .task = task.id, .pc = pc, .account = t.to, .value = task.seen_to };
            },
            .write_from => {
                // Writes a value computed from a read made one or more yields ago. Without a
                // lock, another task may have written in between: that is the lost update.
                world.balances[t.from] = task.seen_from - t.amount;
                task.pc = .write_to;
                return .{ .task = task.id, .pc = pc, .account = t.from, .value = world.balances[t.from] };
            },
            .write_to => {
                world.balances[t.to] = task.seen_to + t.amount;
                end_critical_section(task);
                return .{ .task = task.id, .pc = pc, .account = t.to, .value = world.balances[t.to] };
            },
            .unlock => {
                for (task.lock_order()) |account| {
                    assert(world.lock_owner[account] == task.id);
                    world.lock_owner[account] = null;
                }
                finish_transfer(task);
                return .{ .task = task.id, .pc = pc, .account = 0, .value = 0 };
            },
            .done => unreachable,
        }
    }

    /// The invariant checker. Runs after every single step, so a violation is reported at the
    /// exact tick it happens rather than as a confusing wrong total at the end.
    fn check(world: *const World) ?Failure {
        for (world.balances[0..world.account_count]) |b| {
            if (b < 0) return .negative_balance;
        }
        var in_flight = false;
        for (world.tasks[0..world.task_count]) |*task| {
            in_flight = in_flight or task.in_flight();
            // Lock discipline: in the locking designs, touching an account requires its lock.
            // (The --bug design has no locks, so it has no such assertion either — that is
            // precisely how the bug got written.)
            if (!bug_no_lock) switch (task.pc) {
                .read_from, .read_to, .write_from, .write_to => {
                    const t = task.current();
                    if (world.lock_owner[t.from] != task.id) return .lock_not_held;
                    if (world.lock_owner[t.to] != task.id) return .lock_not_held;
                },
                else => {},
            };
        }
        if (!in_flight and world.total() != world.expected_total()) return .money_not_conserved;
        return null;
    }

    fn total(world: *const World) i64 {
        var sum: i64 = 0;
        for (world.balances[0..world.account_count]) |b| sum += b;
        return sum;
    }

    fn expected_total(world: *const World) i64 {
        return initial_balance * @as(i64, world.account_count);
    }
};

const Failure = enum { negative_balance, money_not_conserved, lock_not_held, deadlock, too_many_ticks };

const Result = struct {
    failure: ?Failure,
    trace_hash: u64,
    ticks: u32,
};

/// The workload: which transfers exist. Drawn from its own sub-seed, so it is independent of
/// the schedule.
fn generate_world(random: std.Random) World {
    var world: World = .{
        .account_count = 2 + random.uintLessThan(u8, accounts_max - 1), // 2..4
        .task_count = 2 + random.uintLessThan(u8, tasks_max - 1), // 2..5
    };
    for (world.tasks[0..world.task_count], 0..) |*task, i| {
        task.* = .{
            .id = @intCast(i),
            .transfers = undefined,
            .transfer_count = 1 + random.uintLessThan(u8, transfers_per_task_max),
            .pc = Task.first_pc(),
        };
        for (task.transfers[0..task.transfer_count]) |*t| {
            const from = random.uintLessThan(u8, world.account_count);
            // Pick a different account for `to`.
            const to = (from + 1 + random.uintLessThan(u8, world.account_count - 1)) %
                world.account_count;
            // Amounts up to 60 out of 100 make "insufficient funds" aborts happen too.
            t.* = .{ .from = from, .to = to, .amount = 1 + random.intRangeAtMost(i64, 0, 59) };
        }
    }
    return world;
}

fn run_seed(seed: u64, verbose: bool) Result {
    // One root PRNG; sub-seeds for the workload and for the scheduler.
    var root = std.Random.DefaultPrng.init(seed);
    var workload_prng = std.Random.DefaultPrng.init(root.random().int(u64));
    var scheduler_prng = std.Random.DefaultPrng.init(root.random().int(u64));
    const scheduler = scheduler_prng.random();

    var world = generate_world(workload_prng.random());
    var trace = std.hash.Wyhash.init(0);
    var schedule: [ticks_max]u8 = undefined;

    if (verbose) {
        std.debug.print("accounts={d} (balance {d} each) tasks={d}\n", .{
            world.account_count, initial_balance, world.task_count,
        });
        for (world.tasks[0..world.task_count]) |*task| {
            std.debug.print("  T{d}:", .{task.id});
            for (task.transfers[0..task.transfer_count]) |t| {
                std.debug.print(" [{d}->{d} ${d}]", .{ t.from, t.to, t.amount });
            }
            std.debug.print("\n", .{});
        }
    }

    var tick: u32 = 0;
    const failure: ?Failure = while (true) : (tick += 1) {
        if (world.check()) |f| break f;
        if (tick == ticks_max) break .too_many_ticks;

        // The scheduler: collect runnable tasks IN INDEX ORDER (deterministic), pick one with
        // the seeded PRNG. This single line replaces the OS thread scheduler.
        var runnable: [tasks_max]u8 = undefined;
        var runnable_count: u8 = 0;
        var unfinished: u8 = 0;
        for (world.tasks[0..world.task_count]) |*task| {
            if (task.pc != .done) unfinished += 1;
            if (world.runnable(task)) {
                runnable[runnable_count] = task.id;
                runnable_count += 1;
            }
        }
        if (runnable_count == 0) {
            if (unfinished == 0) break null; // everyone finished: PASS
            break .deadlock; // unfinished tasks, none can move: deadlock
        }
        const pick = runnable[scheduler.uintLessThan(u8, runnable_count)];
        schedule[tick] = pick;

        const event = world.step(&world.tasks[pick]);
        trace.update(std.mem.asBytes(&[_]i64{
            tick, event.task, @backingInt(event.pc), event.account, event.value,
        }));
        if (verbose) print_event(tick, event);
    };
    const failure_code: i64 = if (failure) |f| @backingInt(f) else -1;
    trace.update(std.mem.asBytes(&failure_code));

    if (verbose) {
        std.debug.print("schedule ({d} ticks, task picked per tick):", .{tick});
        for (schedule[0..tick]) |id| std.debug.print(" {d}", .{id});
        std.debug.print("\nbalances:", .{});
        for (world.balances[0..world.account_count]) |b| std.debug.print(" {d}", .{b});
        std.debug.print("  total={d} expected={d}\n", .{ world.total(), world.expected_total() });
        if (failure) |f| {
            std.debug.print("FAILURE: {s} at tick {d}\n", .{ @tagName(f), tick });
            if (f == .deadlock) print_wait_for(&world);
        }
    }
    return .{ .failure = failure, .trace_hash = trace.final(), .ticks = tick };
}

fn print_event(tick: u32, e: Event) void {
    switch (e.pc) {
        .lock_first, .lock_second => std.debug.print(
            "  t={d:>3} T{d} lock    acct{d}\n",
            .{ tick, e.task, e.account },
        ),
        .unlock => std.debug.print("  t={d:>3} T{d} unlock\n", .{ tick, e.task }),
        .read_from, .read_to => if (e.pc == .read_to and e.value < 0) std.debug.print(
            "  t={d:>3} T{d} insufficient funds, abort\n",
            .{ tick, e.task },
        ) else std.debug.print(
            "  t={d:>3} T{d} read    acct{d} = {d}\n",
            .{ tick, e.task, e.account, e.value },
        ),
        .write_from, .write_to => std.debug.print(
            "  t={d:>3} T{d} write   acct{d} := {d}\n",
            .{ tick, e.task, e.account, e.value },
        ),
        .done => unreachable,
    }
}

fn print_wait_for(world: *const World) void {
    for (world.tasks[0..world.task_count]) |*task| {
        const account = task.wants_lock() orelse continue;
        std.debug.print("  T{d} waits for acct{d}, held by T{d}\n", .{
            task.id, account, world.lock_owner[account].?,
        });
    }
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse "sweep";
    const n = try std.fmt.parseInt(u64, args.next() orelse "1000000", 10);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bug")) bug_no_lock = true;
        if (std.mem.eql(u8, arg, "--bug-deadlock")) bug_deadlock = true;
    }
    if (std.mem.eql(u8, mode, "run")) {
        const r = run_seed(n, true);
        std.debug.print("seed={d} ticks={d} trace={x:0>16} {s}\n", .{
            n, r.ticks, r.trace_hash, if (r.failure == null) "PASS" else "FAIL",
        });
        if (r.failure != null) std.process.exit(1);
        return;
    }

    var seed: u64 = 0;
    while (seed < n) : (seed += 1) {
        const r = run_seed(seed, false);
        if (r.failure) |f| {
            std.debug.print("FAIL at seed={d} ({s}) after {d} seeds. Replay with:\n", .{
                seed, @tagName(f), seed + 1,
            });
            std.debug.print("  zig run main.zig -- run {d}{s}{s}\n", .{
                seed, if (bug_no_lock) " --bug" else "", if (bug_deadlock) " --bug-deadlock" else "",
            });
            std.process.exit(1);
        }
    }
    std.debug.print("PASS: {d} seeds\n", .{n});
}
