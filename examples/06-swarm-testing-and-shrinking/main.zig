//! Example 06 — Swarm testing and shrinking.
//!
//! Two ideas that make a random simulator dramatically better at finding bugs, and at
//! explaining them once found:
//!
//! 1. SWARM TESTING. A naive random test picks every operation from one fixed mix (say 20%
//!    push, 20% pop, 20% peek, 20% clear, 20% resize). Every seed then explores the same
//!    "average" region of the state space. Swarm testing instead lets EACH SEED pick its own
//!    configuration: a random subset of operation kinds is enabled, each with a random weight.
//!    Some seeds never pop. Some seeds never clear. Those lopsided seeds reach states (a queue
//!    that is completely full) that the uniform mix essentially never reaches.
//!    TigerBeetle: `fuzz.random_enum_weights` / `stdx.PRNG.enum_weights` and `options_swarm`
//!    in src/vopr.zig.
//!
//! 2. SHRINKING. The failing seed produces 1000 operations; only a few dozen matter. Because
//!    the simulation is deterministic, we can replay any edited operation list and ask "does
//!    it still fail the same way?". Greedily deleting chunks and simplifying arguments while
//!    the answer stays "yes" leaves a minimal reproduction a human can read.
//!
//! System under test: a bounded ring-buffer queue (fixed capacity, can be resized at runtime),
//! checked against an obviously-correct model (a plain array that shifts on pop).
//!
//! Usage:
//!   zig run main.zig -- run    <seed>  [--bug] [--no-swarm]  # one seed, verbose
//!   zig run main.zig -- sweep  <count> [--bug] [--no-swarm]  # seeds 0..count-1
//!   zig run main.zig -- shrink <seed>  [--bug] [--no-swarm]  # minimize a failing seed
const std = @import("std");
const assert = std.debug.assert;

var bug_enabled = false;
var swarm_enabled = true;

const cap_min = 32;
const cap_max = 64;
const ops_per_seed = 1000;

// ---------------------------------------------------------------------------------------------
// System under test.
// ---------------------------------------------------------------------------------------------

/// A bounded FIFO queue stored in a ring buffer. `head` is the oldest element, `tail` is where
/// the next push goes. Storage is a fixed array so the simulation needs no allocator; `cap` is
/// the logical capacity, changed by `resize`.
const RingQueue = struct {
    buf: [cap_max]u32 = undefined,
    cap: u32,
    head: u32 = 0,
    tail: u32 = 0,
    count: u32 = 0,

    fn init(cap: u32) RingQueue {
        assert(cap >= cap_min and cap <= cap_max);
        return .{ .cap = cap };
    }

    /// Returns false (and changes nothing) when the queue is full: it is bounded.
    fn push(q: *RingQueue, value: u32) bool {
        if (q.count == q.cap) return false;
        q.buf[q.tail] = value;
        q.tail = (q.tail + 1) % q.cap;
        q.count += 1;
        return true;
    }

    fn pop(q: *RingQueue) ?u32 {
        if (q.count == 0) return null;
        const value = q.buf[q.head];
        q.head = (q.head + 1) % q.cap;
        q.count -= 1;
        return value;
    }

    fn peek(q: *const RingQueue) ?u32 {
        if (q.count == 0) return null;
        return q.buf[q.head];
    }

    fn clear(q: *RingQueue) void {
        q.head = 0;
        q.tail = 0;
        q.count = 0;
    }

    /// The i-th element from the front (0 = oldest).
    fn get(q: *const RingQueue, i: u32) u32 {
        assert(i < q.count);
        return q.buf[(q.head + i) % q.cap];
    }

    /// Change capacity, keeping all elements in order. Fails if they would not fit.
    fn resize(q: *RingQueue, new_cap: u32) bool {
        assert(new_cap >= cap_min and new_cap <= cap_max);
        if (new_cap < q.count) return false;

        // THE PLANTED BUG: recompute the element count from the indices, the way many ring
        // buffers without a `count` field do. `(tail - head) mod cap` is right for every
        // state EXCEPT a completely full queue, where tail == head and the formula says 0:
        // "full" and "empty" look identical. Resize then silently drops every element.
        // To hit it you need >= 32 pushes in a row (net of pops), no clear, then a resize.
        const n = if (bug_enabled) (q.tail + q.cap - q.head) % q.cap else q.count;

        // Linearize into scratch (handles wrap-around), then copy back starting at 0.
        var scratch: [cap_max]u32 = undefined;
        for (0..n) |i| scratch[i] = q.get(@intCast(i));
        @memcpy(q.buf[0..n], scratch[0..n]);
        q.cap = new_cap;
        q.head = 0;
        q.count = n;
        q.tail = n % new_cap;
        return true;
    }
};

/// Oracle: the dumbest possible bounded queue. Pop shifts the whole array; no indices to get
/// wrong. Same API, so every operation can be applied to both and compared.
const Model = struct {
    items: [cap_max]u32 = undefined,
    len: u32 = 0,
    cap: u32,

    fn push(m: *Model, value: u32) bool {
        if (m.len == m.cap) return false;
        m.items[m.len] = value;
        m.len += 1;
        return true;
    }

    fn pop(m: *Model) ?u32 {
        if (m.len == 0) return null;
        const value = m.items[0];
        std.mem.copyForwards(u32, m.items[0 .. m.len - 1], m.items[1..m.len]);
        m.len -= 1;
        return value;
    }

    fn resize(m: *Model, new_cap: u32) bool {
        if (new_cap < m.len) return false;
        m.cap = new_cap;
        return true;
    }
};

// ---------------------------------------------------------------------------------------------
// Test case: an explicit, editable list of operations. Generation and execution are separate
// so the shrinker can replay edited lists. The ops do NOT depend on the queue state (resize
// may ask for a capacity that is too small; both SUT and model then reject it), so any
// subsequence of a valid case is still a valid case.
// ---------------------------------------------------------------------------------------------

const Kind = enum(u8) { push, pop, peek, clear, resize };
const kind_count: u32 = std.enums.values(Kind).len;

const Op = struct { kind: Kind, arg: u32 = 0 };

const Case = struct {
    initial_cap: u32,
    len: u32,
    ops: [ops_per_seed]Op,
};

const Weights = [kind_count]u32;

/// Swarm: choose how many kinds to enable (1..5), choose WHICH kinds as a uniformly random
/// combination, give each enabled kind a weight in 1..100. A direct port of TigerBeetle's
/// `random_enum_weights` (src/testing/fuzz.zig) and `PRNG.Combination` (src/stdx/prng.zig).
/// With --no-swarm, every kind gets the same weight: the classic "uniform mix".
fn gen_weights(random: std.Random) Weights {
    var weights: Weights = @splat(1);
    if (!swarm_enabled) return weights;
    const sample = random.intRangeAtMost(u32, 1, kind_count);
    var taken: u32 = 0;
    for (&weights, 0..) |*w, seen| {
        // Take this kind with probability (still needed) / (still available).
        const take = random.uintLessThan(u32, kind_count - @as(u32, @intCast(seen))) < sample - taken;
        if (take) taken += 1;
        w.* = if (take) random.intRangeAtMost(u32, 1, 100) else 0;
    }
    assert(taken == sample);
    return weights;
}

fn pick_kind(random: std.Random, weights: Weights) Kind {
    var total: u32 = 0;
    for (weights) |w| total += w;
    assert(total > 0);
    var pick = random.uintLessThan(u32, total);
    for (weights, 0..) |w, i| {
        if (pick < w) return @enumFromInt(i);
        pick -= w;
    }
    unreachable;
}

fn generate(seed: u64, case: *Case) Weights {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const weights = gen_weights(random);
    case.initial_cap = random.intRangeAtMost(u32, cap_min, cap_max);
    case.len = ops_per_seed;
    for (&case.ops) |*op| {
        const kind = pick_kind(random, weights);
        op.* = switch (kind) {
            .push => .{ .kind = kind, .arg = random.int(u32) },
            .resize => .{ .kind = kind, .arg = random.intRangeAtMost(u32, cap_min, cap_max) },
            else => .{ .kind = kind },
        };
    }
    return weights;
}

// ---------------------------------------------------------------------------------------------
// Execution with invariant checks after EVERY operation (not just at the end).
// ---------------------------------------------------------------------------------------------

const FailureKind = enum { result_mismatch, count_mismatch, index_corrupt, content_mismatch };

const Failure = struct { kind: FailureKind, op_index: u32, got: u64, want: u64 };

const Result = struct { failure: ?Failure, trace_hash: u64, max_count: u32 };

/// Compare SUT and model after an op. These are the invariants:
///  - structural: count <= cap, head < cap, tail == (head + count) % cap
///  - refinement: same count and same elements in the same order as the model
fn check(q: *const RingQueue, m: *const Model, op_index: u32) ?Failure {
    if (q.count != m.len) return .{ .kind = .count_mismatch, .op_index = op_index, .got = q.count, .want = m.len };
    if (q.count > q.cap or q.head >= q.cap or q.tail != (q.head + q.count) % q.cap)
        return .{ .kind = .index_corrupt, .op_index = op_index, .got = q.tail, .want = (q.head + q.count) % q.cap };
    for (0..q.count) |i| {
        const got = q.get(@intCast(i));
        if (got != m.items[i]) return .{ .kind = .content_mismatch, .op_index = op_index, .got = got, .want = m.items[i] };
    }
    return null;
}

fn opt(v: ?u32) u64 {
    return v orelse std.math.maxInt(u64);
}

fn execute(case: *const Case, verbose: bool) Result {
    var q = RingQueue.init(case.initial_cap);
    var m: Model = .{ .cap = case.initial_cap };
    var trace = std.hash.Wyhash.init(0);
    var max_count: u32 = 0;

    for (case.ops[0..case.len], 0..) |op, i_usize| {
        const i: u32 = @intCast(i_usize);
        const was_full = q.count == q.cap;
        // Apply to both; compare the return values.
        const got: u64, const want: u64 = switch (op.kind) {
            .push => .{ @intFromBool(q.push(op.arg)), @intFromBool(m.push(op.arg)) },
            .pop => .{ opt(q.pop()), opt(m.pop()) },
            .peek => .{ opt(q.peek()), opt(if (m.len == 0) null else m.items[0]) },
            .clear => blk: {
                q.clear();
                m.len = 0;
                break :blk .{ 0, 0 };
            },
            .resize => blk: {
                const cap_before = q.cap;
                const r = .{ @intFromBool(q.resize(op.arg)), @intFromBool(m.resize(op.arg)) };
                if (verbose and was_full) std.debug.print(
                    "  op {d}: resize {d} -> {d} while FULL (count={d})\n",
                    .{ i, cap_before, op.arg, m.len },
                );
                break :blk r;
            },
        };
        // A [3]u64 array, not a tuple: tuples of mixed widths have padding bytes with
        // undefined contents, which would make the trace hash nondeterministic.
        trace.update(std.mem.asBytes(&[3]u64{ @intFromEnum(op.kind), op.arg, got }));

        const failure: ?Failure = if (got != want)
            .{ .kind = .result_mismatch, .op_index = i, .got = got, .want = want }
        else
            check(&q, &m, i);
        if (failure) |f| return .{ .failure = f, .trace_hash = trace.final(), .max_count = max_count };

        max_count = @max(max_count, q.count);
        if (verbose and !was_full and q.count == q.cap and q.cap > 0)
            std.debug.print("  op {d}: queue became full (count=cap={d})\n", .{ i, q.cap });
    }
    return .{ .failure = null, .trace_hash = trace.final(), .max_count = max_count };
}

fn print_failure(f: Failure) void {
    std.debug.print("  op {d}: {s}: got={d} want={d}\n", .{ f.op_index, @tagName(f.kind), f.got, f.want });
}

// ---------------------------------------------------------------------------------------------
// Shrinking. Purely deterministic: no PRNG, just replays. "Still fails" means fails with the
// SAME failure kind, so the shrinker cannot wander off to a different (shallower) bug.
// ---------------------------------------------------------------------------------------------

var shrink_replays: u32 = 0;

fn still_fails(case: *const Case, kind: FailureKind) bool {
    shrink_replays += 1;
    const r = execute(case, false);
    return if (r.failure) |f| f.kind == kind else false;
}

/// Delta-debugging style: try deleting chunks of size len/2, len/4, ..., 1.
fn shrink_delete(case: *Case, kind: FailureKind) void {
    var chunk: u32 = @max(1, case.len / 2);
    while (true) {
        var progress = false;
        var start: u32 = 0;
        while (start < case.len) {
            const end = @min(start + chunk, case.len);
            var candidate = case.*;
            const tail = case.ops[end..case.len];
            @memcpy(candidate.ops[start..][0..tail.len], tail);
            candidate.len = case.len - (end - start);
            if (still_fails(&candidate, kind)) {
                case.* = candidate; // keep `start`: the next chunk slid into this position
                progress = true;
            } else start += chunk;
        }
        if (!progress) {
            if (chunk == 1) return;
            chunk /= 2;
        }
    }
}

/// Move each argument toward its simplest value: first try the minimum, then halfway.
/// Returns how many arguments changed.
fn shrink_args(case: *Case, kind: FailureKind) u32 {
    var changed: u32 = 0;
    // The initial capacity is part of the input too.
    for ([_]u32{ cap_min, cap_min + (case.initial_cap - cap_min) / 2 }) |c| {
        if (c >= case.initial_cap) continue;
        var candidate = case.*;
        candidate.initial_cap = c;
        if (still_fails(&candidate, kind)) {
            case.* = candidate;
            changed += 1;
            break;
        }
    }
    for (0..case.len) |i| {
        const op = case.ops[i];
        const min: u32 = switch (op.kind) {
            .push => 0,
            .resize => cap_min,
            else => continue, // no argument
        };
        for ([_]u32{ min, min + (op.arg - min) / 2 }) |a| {
            if (a >= op.arg) continue;
            var candidate = case.*;
            candidate.ops[i].arg = a;
            if (still_fails(&candidate, kind)) {
                case.* = candidate;
                changed += 1;
                break;
            }
        }
    }
    return changed;
}

fn shrink(seed: u64) void {
    var case: Case = undefined;
    _ = generate(seed, &case);
    const original = execute(&case, false);
    const f = original.failure orelse {
        std.debug.print("seed={d} passes; nothing to shrink\n", .{seed});
        return;
    };
    std.debug.print("shrink: seed={d} recorded {d} ops, initial_cap={d}\n", .{ seed, case.len, case.initial_cap });
    print_failure(f);

    // Everything after the failing op is irrelevant: cut it off for free.
    case.len = f.op_index + 1;
    std.debug.print("  truncate after failing op -> {d} ops\n", .{case.len});

    var round: u32 = 1;
    while (true) : (round += 1) {
        const len_before = case.len;
        shrink_delete(&case, f.kind);
        const changed = shrink_args(&case, f.kind);
        std.debug.print("  round {d}: delete -> {d} ops, simplified {d} args\n", .{ round, case.len, changed });
        if (case.len == len_before and changed == 0) break;
    }

    const final = execute(&case, false);
    const ff = final.failure.?;
    assert(ff.kind == f.kind);
    std.debug.print("minimal reproduction ({d} ops, {d} replays):\n", .{ case.len, shrink_replays });
    std.debug.print("  q = RingQueue.init({d})\n", .{case.initial_cap});
    // Run-length encode identical consecutive ops so 32 pushes print as one line.
    var i: u32 = 0;
    while (i < case.len) {
        var j = i + 1;
        while (j < case.len and std.meta.eql(case.ops[j], case.ops[i])) j += 1;
        const op = case.ops[i];
        switch (op.kind) {
            .push, .resize => std.debug.print("  {s}({d})", .{ @tagName(op.kind), op.arg }),
            else => std.debug.print("  {s}()", .{@tagName(op.kind)}),
        }
        if (j - i > 1) std.debug.print(" x{d}", .{j - i});
        if (j == case.len) std.debug.print("   <- {s}: got={d} want={d}", .{ @tagName(ff.kind), ff.got, ff.want });
        std.debug.print("\n", .{});
        i = j;
    }
    std.debug.print("seed={d} shrunk trace={x:0>16} FAIL\n", .{ seed, final.trace_hash });
    std.process.exit(1);
}

// ---------------------------------------------------------------------------------------------

fn run_seed(seed: u64, verbose: bool) Result {
    var case: Case = undefined;
    const weights = generate(seed, &case);
    if (verbose) {
        std.debug.print("seed={d} initial_cap={d} weights:", .{ seed, case.initial_cap });
        for (weights, 0..) |w, k| std.debug.print(" {s}={d}", .{ @tagName(@as(Kind, @enumFromInt(k))), w });
        std.debug.print("\n", .{});
    }
    const r = execute(&case, verbose);
    if (verbose) if (r.failure) |f| print_failure(f);
    return r;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse "sweep";
    const n = try std.fmt.parseInt(u64, args.next() orelse "20000", 10);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bug")) bug_enabled = true;
        if (std.mem.eql(u8, arg, "--no-swarm")) swarm_enabled = false;
    }
    const flags = if (bug_enabled and !swarm_enabled)
        " --bug --no-swarm"
    else if (bug_enabled)
        " --bug"
    else if (!swarm_enabled) " --no-swarm" else "";

    if (std.mem.eql(u8, mode, "shrink")) return shrink(n);

    if (std.mem.eql(u8, mode, "run")) {
        const r = run_seed(n, true);
        std.debug.print("seed={d} max_count={d} trace={x:0>16} {s}\n", .{
            n, r.max_count, r.trace_hash, if (r.failure == null) "PASS" else "FAIL",
        });
        if (r.failure != null) std.process.exit(1);
        return;
    }

    var seed: u64 = 0;
    // Coverage stats: how often did we reach the deep states the bug needs?
    var deep_seeds: u64 = 0;
    var deepest: u32 = 0;
    while (seed < n) : (seed += 1) {
        const r = run_seed(seed, false);
        if (r.failure != null) {
            std.debug.print("FAIL at seed={d} after {d} seeds. Replay with:\n", .{ seed, seed + 1 });
            std.debug.print("  zig run main.zig -- run {d}{s}\n", .{ seed, flags });
            std.debug.print("  zig run main.zig -- shrink {d}{s}\n", .{ seed, flags });
            std.process.exit(1);
        }
        if (r.max_count >= cap_min) deep_seeds += 1;
        deepest = @max(deepest, r.max_count);
    }
    std.debug.print("PASS: {d} seeds ({d} reached >= {d} queued items; deepest queue={d})\n", .{
        n, deep_seeds, cap_min, deepest,
    });
}
