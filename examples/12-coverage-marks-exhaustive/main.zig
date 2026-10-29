//! Example 12 — Coverage marks and exhaustive generation of small inputs.
//!
//! A sweep that passes proves nothing about code it never reached. This example adds two tools
//! TigerBeetle uses to close that gap:
//!
//!   * coverage marks (src/testing/marks.zig): production code says "this branch happened" by
//!     name; a test or a sweep asserts that a SPECIFIC branch was reached;
//!   * exhaustive generation (src/testing/exhaustigen.zig, matklad's "Generate All the Things"):
//!     instead of sampling random operation sequences, enumerate EVERY sequence up to a small
//!     length over a small domain. Off-by-ones live at boundaries, and a small domain is all
//!     boundaries.
//!
//! System under test: an extent set — the free-space map of a block allocator. It stores
//! disjoint, non-touching, sorted half-open ranges [lo, hi) of block numbers in a fixed-capacity
//! array (like a B-tree node), so insert/remove must open slots, close slots, and coalesce
//! neighbours in place. Each interesting branch carries a named mark.
//!
//! The simulator drives it with a seeded generator (or with the exhaustive Gen) and checks,
//! after EVERY operation, the set's shape (sorted, non-empty, non-touching, within capacity)
//! and its contents against an independent model (a bitset over the block domain).
//!
//! Planted bug:
//!   --bug-fill-gap   the fast path for "this range exactly plugs the hole between two
//!                    neighbours" fuses them and then deletes the left slot with a swap-remove.
//!                    That is only correct when the right neighbour is the last interval. The
//!                    uniform random generator reaches this path ~never (it needs two exact
//!                    equalities on a 2^20-block domain), so the random sweep PASSES with the
//!                    bug. The coverage report shows the mark at 0 hits; `exhaust 4` finds it.
//!   --gen-boundaries a better generator: endpoints sometimes copy existing boundaries, so
//!                    "touching" happens. With it the random sweep reaches the mark and finds
//!                    the bug too.
//!
//! Usage:
//!   zig run main.zig -- run      <seed>     [--bug-fill-gap] [--gen-boundaries]
//!   zig run main.zig -- sweep    <count>    [--bug-fill-gap] [--gen-boundaries]
//!   zig run main.zig -- coverage <count>    [--require-all] [--bug-fill-gap] [--gen-boundaries]
//!   zig run main.zig -- exhaust  <max_len>  [--bug-fill-gap]
//!   zig test main.zig                       (hand-written tests that each assert one mark)
const std = @import("std");
const assert = std.debug.assert;

var bug_fill_gap = false;
var gen_boundaries = false;

// ---------------------------------------------------------------------------------------------
// Coverage marks. In TigerBeetle, `marks.wrap_log` turns `log.mark.info("...")` into "record a
// hit if a test is currently checking this mark", and compiles to a plain log line outside
// tests. Here a mark is an enum value and the hit counters are always on, because the
// simulator itself reads them to print the coverage table.
// ---------------------------------------------------------------------------------------------

const marks = struct {
    const Mark = enum(u8) {
        insert_disjoint, // new range touches nothing: open a slot
        insert_full, // ...but every slot is used: error.NoSpace
        insert_extend, // touches or overlaps exactly one range: grow it
        insert_coalesce, // touches or overlaps several: merge them, compact the array
        insert_fill_gap, // fast path: exactly plugs the hole between two neighbours
        remove_miss, // overlaps nothing
        remove_trim, // cuts the end(s) off one or two ranges
        remove_delete, // deletes whole ranges, compact the array
        remove_split, // punches a hole in one range: one slot becomes two
        remove_split_full, // ...but every slot is used: error.NoSpace
    };
    const count = std.enums.values(Mark).len;

    var hits: [count]u64 = @splat(0);

    /// Production code calls this at each interesting branch.
    fn hit(mark: Mark) void {
        hits[@backingInt(mark)] += 1;
    }

    /// Test side, same shape as TigerBeetle's `marks.check(name)` ... `mark.expect_hit()`:
    /// a test names the branch it exists for, and fails if it did not get there.
    const Check = struct {
        mark: Mark,
        before: u64,

        fn expect_hit(c: Check) !void {
            if (hits[@backingInt(c.mark)] == c.before) {
                std.debug.print("mark '{s}' not hit\n", .{@tagName(c.mark)});
                return error.MarkNotHit;
            }
        }
    };

    fn check(mark: Mark) Check {
        return .{ .mark = mark, .before = hits[@backingInt(mark)] };
    }
};

// ---------------------------------------------------------------------------------------------
// System under test: the extent set (~150 lines).
// ---------------------------------------------------------------------------------------------

const Interval = struct {
    lo: u32,
    hi: u32, // exclusive

    pub fn format(iv: Interval, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (iv.lo == 0 and iv.hi == 0) return w.writeAll("·"); // never-written slot
        try w.print("[{d},{d})", .{ iv.lo, iv.hi });
    }
};

const IntervalSet = struct {
    const capacity_max = 32;

    /// slots[0..len] are live. Slots past `len` keep stale bytes, like a real node.
    slots: [capacity_max]Interval = @splat(.{ .lo = 0, .hi = 0 }),
    len: u32 = 0,
    capacity: u32,

    fn items(set: *const IntervalSet) []const Interval {
        return set.slots[0..set.len];
    }

    /// Index of the first interval with hi >= x. Binary search: correct only if sorted.
    fn search(set: *const IntervalSet, x: u32) u32 {
        var lo: u32 = 0;
        var hi: u32 = set.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (set.slots[mid].hi < x) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn contains(set: *const IntervalSet, x: u32) bool {
        const i = set.search(x + 1); // first interval with hi > x
        return i < set.len and set.slots[i].lo <= x;
    }

    /// Open `count` slots at `at`, shifting the tail right.
    fn open_slots(set: *IntervalSet, at: u32, count: u32) void {
        assert(set.len + count <= set.capacity);
        std.mem.copyBackwards(Interval, set.slots[at + count .. set.len + count], set.slots[at..set.len]);
        set.len += count;
    }

    /// Close `count` slots at `at`, shifting the tail left (in-place compaction).
    fn close_slots(set: *IntervalSet, at: u32, count: u32) void {
        std.mem.copyForwards(Interval, set.slots[at .. set.len - count], set.slots[at + count .. set.len]);
        set.len -= count;
    }

    /// Add blocks [lo, hi). Ranges that touch are fused, so the set stays canonical.
    fn insert(set: *IntervalSet, lo: u32, hi: u32) error{NoSpace}!void {
        assert(lo < hi);
        // slots[i..j] are exactly the ranges that overlap OR touch [lo, hi).
        const i = set.search(lo);
        var j = i;
        while (j < set.len and set.slots[j].lo <= hi) j += 1;
        const touching = j - i;

        if (touching == 0) {
            if (set.len == set.capacity) {
                marks.hit(.insert_full);
                return error.NoSpace;
            }
            marks.hit(.insert_disjoint);
            set.open_slots(i, 1);
            set.slots[i] = .{ .lo = lo, .hi = hi };
            return;
        }

        if (touching == 2 and set.slots[i].hi == lo and set.slots[i + 1].lo == hi) {
            // Fast path: [lo, hi) is exactly the hole between two neighbours. This is what an
            // allocator sees when an extent it handed out from the middle of a free run is
            // released. Fuse the neighbours into the right slot and delete the left slot.
            marks.hit(.insert_fill_gap);
            set.slots[i + 1].lo = set.slots[i].lo;
            if (bug_fill_gap) {
                // BUG: swap-remove is O(1) and looks harmless, but it moves the LAST interval
                // into slot i. That is right only when slot i+1 was the last one (then the last
                // one IS the fused range). With anything after it, the array is now unsorted.
                set.slots[i] = set.slots[set.len - 1];
                set.len -= 1;
            } else {
                set.close_slots(i, 1);
            }
            return;
        }

        // General path: one range covering the new one and everything it touches.
        const merged: Interval = .{
            .lo = @min(lo, set.slots[i].lo),
            .hi = @max(hi, set.slots[j - 1].hi),
        };
        marks.hit(if (touching == 1) .insert_extend else .insert_coalesce);
        set.slots[i] = merged;
        set.close_slots(i + 1, touching - 1);
    }

    /// Remove blocks [lo, hi). Removing from the middle of a range needs one more slot.
    fn remove(set: *IntervalSet, lo: u32, hi: u32) error{NoSpace}!void {
        assert(lo < hi);
        // slots[i..j] are exactly the ranges that OVERLAP [lo, hi) (touching does not count).
        const i = set.search(lo + 1);
        var j = i;
        while (j < set.len and set.slots[j].lo < hi) j += 1;
        if (i == j) {
            marks.hit(.remove_miss);
            return;
        }
        const first = set.slots[i];
        const last = set.slots[j - 1];

        if (j - i == 1 and first.lo < lo and hi < first.hi) {
            if (set.len == set.capacity) {
                marks.hit(.remove_split_full);
                return error.NoSpace;
            }
            marks.hit(.remove_split);
            set.open_slots(i + 1, 1);
            set.slots[i] = .{ .lo = first.lo, .hi = lo };
            set.slots[i + 1] = .{ .lo = hi, .hi = first.hi };
            return;
        }

        // Keep whatever sticks out on the left and on the right; delete the rest.
        var keep = i;
        if (first.lo < lo) {
            set.slots[keep] = .{ .lo = first.lo, .hi = lo };
            keep += 1;
        }
        if (hi < last.hi) {
            set.slots[keep] = .{ .lo = hi, .hi = last.hi };
            keep += 1;
        }
        const deleted = j - keep;
        marks.hit(if (deleted == 0) .remove_trim else .remove_delete);
        set.close_slots(keep, deleted);
    }
};

// ---------------------------------------------------------------------------------------------
// The model: an independent bitset over the whole block domain. It knows nothing about slots.
// ---------------------------------------------------------------------------------------------

const domain_max = 1 << 20;

const Model = struct {
    words: [domain_max / 64]u64 = @splat(0),
    count: u64 = 0,

    fn get(m: *const Model, x: u32) bool {
        return (m.words[x / 64] >> @intCast(x % 64)) & 1 == 1;
    }

    /// Bits of the word holding x, from x up to hi (at most to the end of that word).
    fn mask(x: u32, hi: u32) u64 {
        const bit: u6 = @intCast(x % 64);
        const n = @min(hi - x, 64 - @as(u32, bit));
        return (if (n == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1) << bit;
    }

    /// Set or clear [lo, hi) word by word; keeps `count` exact.
    fn set_range(m: *Model, lo: u32, hi: u32, value: bool) void {
        var x = lo;
        while (x < hi) : (x = (x / 64 + 1) * 64) {
            const w = &m.words[x / 64];
            const before = @popCount(w.*);
            if (value) w.* |= mask(x, hi) else w.* &= ~mask(x, hi);
            m.count = m.count + @popCount(w.*) - before;
        }
    }

    /// How many blocks of [lo, hi) are set.
    fn count_range(m: *const Model, lo: u32, hi: u32) u64 {
        var total: u64 = 0;
        var x = lo;
        while (x < hi) : (x = (x / 64 + 1) * 64) total += @popCount(m.words[x / 64] & mask(x, hi));
        return total;
    }
};

var model: Model = .{};

// ---------------------------------------------------------------------------------------------
// Harness: applies one operation to both the set and the model, then checks everything.
// ---------------------------------------------------------------------------------------------

const Kind = enum(u8) { insert, remove };
const Op = struct {
    kind: Kind,
    lo: u32,
    hi: u32,

    pub fn format(op: Op, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} [{d},{d})", .{ @tagName(op.kind), op.lo, op.hi });
    }
};

const Harness = struct {
    domain: u32,
    set: IntervalSet,
    trace: *std.hash.Wyhash,
    failure_buf: [160]u8 = undefined,
    failure: ?[]const u8 = null,

    fn init(domain: u32, capacity: u32, trace: *std.hash.Wyhash) Harness {
        assert(capacity <= IntervalSet.capacity_max and domain <= domain_max);
        assert(model.count == 0); // the previous run cleaned up after itself
        return .{ .domain = domain, .set = .{ .capacity = capacity }, .trace = trace };
    }

    /// Clear the model cheaply: it equals the set (checked), so clear the set's ranges.
    fn deinit(h: *Harness) void {
        if (h.failure != null) {
            model = .{};
            return;
        }
        for (h.set.items()) |iv| model.set_range(iv.lo, iv.hi, false);
        assert(model.count == 0);
    }

    fn fail(h: *Harness, comptime fmt: []const u8, args: anytype) bool {
        h.failure = std.fmt.bufPrint(&h.failure_buf, fmt, args) catch "failure (message too long)";
        return false;
    }

    /// Returns false on the first violated invariant (message in `h.failure`).
    fn apply(h: *Harness, op: Op) bool {
        const result = switch (op.kind) {
            .insert => h.set.insert(op.lo, op.hi),
            .remove => h.set.remove(op.lo, op.hi),
        };
        const no_space = if (result) |_| false else |_| true;
        if (no_space) {
            // Rejected ops must leave the set unchanged, and only happen when it is full.
            if (h.set.len != h.set.capacity) return h.fail("NoSpace with {d}/{d} slots used", .{ h.set.len, h.set.capacity });
        } else {
            model.set_range(op.lo, op.hi, op.kind == .insert);
        }
        h.trace.update(std.mem.asBytes(&[_]u32{ @backingInt(op.kind), op.lo, op.hi, @intFromBool(no_space), h.set.len }));
        return h.check(op);
    }

    fn check(h: *Harness, op: Op) bool {
        // 1. Shape: every range non-empty and in the domain; sorted with a gap between
        //    neighbours (touching ranges must have been fused); within capacity.
        if (h.set.len > h.set.capacity) return h.fail("len {d} > capacity {d}", .{ h.set.len, h.set.capacity });
        var total: u64 = 0;
        for (h.set.items(), 0..) |iv, k| {
            if (iv.lo >= iv.hi or iv.hi > h.domain) return h.fail("slot {d} holds a bad range {f}", .{ k, iv });
            if (k > 0 and h.set.slots[k - 1].hi >= iv.lo) {
                return h.fail("slots {d},{d} out of order or touching: {f} then {f}", .{ k - 1, k, h.set.slots[k - 1], iv });
            }
            total += iv.hi - iv.lo;
        }
        // 2. Contents: same number of blocks as the model, and agreement at the op's edges,
        //    where off-by-ones live. Tiny domains compare every block (only affordable there).
        if (total != model.count) return h.fail("set holds {d} blocks, model holds {d}", .{ total, model.count });
        const edges = [_]u32{ op.lo -% 1, op.lo, op.hi -% 1, op.hi };
        for (edges) |x| if (x < h.domain and h.set.contains(x) != model.get(x)) {
            return h.fail("block {d}: set says {}, model says {}", .{ x, h.set.contains(x), model.get(x) });
        };
        if (h.domain <= 64) for (0..h.domain) |x| if (h.set.contains(@intCast(x)) != model.get(@intCast(x))) {
            return h.fail("block {d}: set says {}, model says {}", .{ x, h.set.contains(@intCast(x)), model.get(@intCast(x)) });
        };
        return true;
    }

    /// End-of-run check: every block of every range is in the model; with equal counts this
    /// means set == model exactly.
    fn check_final(h: *Harness) bool {
        for (h.set.items()) |iv| if (model.count_range(iv.lo, iv.hi) != iv.hi - iv.lo) {
            return h.fail("final: range {f} is in the set but not fully in the model", .{iv});
        };
        return true;
    }
};

fn print_slots(set: *const IntervalSet) void {
    for (set.slots[0..set.capacity], 0..) |iv, k| {
        if (k == set.len) std.debug.print(" |", .{});
        std.debug.print(" {f}", .{iv});
    }
    if (set.len == set.capacity) std.debug.print(" |", .{});
}

fn mark_hit_by(before: *const [marks.count]u64) []const u8 {
    for (marks.hits, before, std.enums.values(marks.Mark)) |now, then, mark| if (now != then) return @tagName(mark);
    return "-";
}

/// " name=delta" for every mark since `start`.
fn print_mark_deltas(start: *const [marks.count]u64) void {
    for (marks.hits, start, std.enums.values(marks.Mark)) |now, then, mark| {
        std.debug.print(" {s}={d}", .{ @tagName(mark), now - then });
    }
    std.debug.print("\n", .{});
}

// ---------------------------------------------------------------------------------------------
// Random generator ("realistic weights"): a 4 GiB file of 4 KiB blocks (2^20 blocks), extents
// of 1..256 blocks (up to 1 MiB), 65% inserts. This is the generator most of us would write.
// ---------------------------------------------------------------------------------------------

const random_domain = domain_max;
const random_capacity = 32;
const ops_per_seed = 100;
const len_max = 256;
const insert_percent = 65;

fn random_op(random: std.Random, set: *const IntervalSet) Op {
    const kind: Kind = if (random.uintLessThan(u32, 100) < insert_percent) .insert else .remove;
    const len = random.intRangeAtMost(u32, 1, len_max);
    var lo = random.uintAtMost(u32, random_domain - len);
    var hi = lo + len;
    if (gen_boundaries and set.len > 0) {
        // Boundary-biased endpoints: a quarter of the time `lo` copies an existing endpoint,
        // and a quarter of the time `hi` snaps to the next endpoint above `lo`. Equalities
        // between ranges (touching, exact fits) stop being measure-zero events.
        if (random.uintLessThan(u32, 4) == 0) {
            const iv = set.items()[random.uintLessThan(u32, set.len)];
            lo = @min(if (random.boolean()) iv.lo else iv.hi, random_domain - 1);
            hi = @min(lo + len, random_domain);
        }
        if (random.uintLessThan(u32, 4) == 0) {
            var next: u32 = std.math.maxInt(u32);
            for (set.items()) |iv| {
                if (iv.lo > lo) next = @min(next, iv.lo);
                if (iv.hi > lo) next = @min(next, iv.hi);
            }
            if (next != std.math.maxInt(u32)) hi = next;
        }
    }
    return .{ .kind = kind, .lo = lo, .hi = hi };
}

const SeedResult = struct { ok: bool, trace: u64, ops: u32 };

fn run_seed(seed: u64, verbose: bool) SeedResult {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var trace = std.hash.Wyhash.init(seed);
    var h = Harness.init(random_domain, random_capacity, &trace);
    defer h.deinit();
    const marks_start = marks.hits;
    if (verbose) std.debug.print(
        "seed={d} generator={s} domain={d} capacity={d} ops={d}\n  step op                        mark                len\n",
        .{ seed, if (gen_boundaries) "boundaries" else "uniform", random_domain, random_capacity, ops_per_seed },
    );
    var step: u32 = 0;
    var ok = true;
    while (step < ops_per_seed) : (step += 1) {
        const op = random_op(random, &h.set);
        const before = marks.hits;
        ok = h.apply(op);
        if (verbose) {
            var buf: [40]u8 = undefined;
            const op_text = std.fmt.bufPrint(&buf, "{f}", .{op}) catch unreachable;
            std.debug.print("  {d:>4} {s:<26} {s:<19} {d:>2}\n", .{ step, op_text, mark_hit_by(&before), h.set.len });
        }
        if (!ok) break;
    }
    if (ok) ok = h.check_final();
    if (!ok) {
        std.debug.print("INVARIANT VIOLATED: {s}\n", .{h.failure.?});
        if (verbose) {
            std.debug.print("  slots:", .{});
            print_slots(&h.set);
            std.debug.print("\n", .{});
        }
    }
    if (verbose) {
        std.debug.print("marks:", .{});
        print_mark_deltas(&marks_start);
    }
    return .{ .ok = ok, .trace = trace.final(), .ops = @min(step + 1, ops_per_seed) };
}

// ---------------------------------------------------------------------------------------------
// Exhaustive generation: a port of TigerBeetle's src/testing/exhaustigen.zig (std only).
//
// Each pass of `while (!g.done())` asks for a sequence of choices, each with a bound. Gen records
// (value, bound) pairs; `done()` advances to the next sequence like an odometer: bump the
// rightmost value still below its bound, drop everything after it. The code that consumes the
// choices can depend on earlier choices (here: hi depends on lo), and Gen still visits every
// combination exactly once.
// ---------------------------------------------------------------------------------------------

const Gen = struct {
    started: bool = false,
    v: [32]struct { value: u32, bound: u32 } = undefined,
    p: usize = 0,
    p_max: usize = 0,

    fn done(g: *Gen) bool {
        if (!g.started) {
            g.started = true;
            return false;
        }
        var i = g.p_max;
        while (i > 0) {
            i -= 1;
            if (g.v[i].value < g.v[i].bound) {
                g.v[i].value += 1;
                g.p_max = i + 1;
                g.p = 0;
                return false;
            }
        }
        return true;
    }

    /// A value in [0, bound].
    fn int_inclusive(g: *Gen, bound: u32) u32 {
        assert(g.p < g.v.len);
        if (g.p == g.p_max) {
            g.v[g.p] = .{ .value = 0, .bound = 0 };
            g.p_max += 1;
        }
        g.p += 1;
        g.v[g.p - 1].bound = bound;
        return g.v[g.p - 1].value;
    }

    fn range_inclusive(g: *Gen, min: u32, max: u32) u32 {
        assert(min <= max);
        return min + g.int_inclusive(max - min);
    }
};

/// Small scope: 7 blocks, 3 slots, ranges of 1..3 blocks. 2 x 18 = 36 possible ops per step.
const exhaust_domain = 7;
const exhaust_capacity = 3;
const exhaust_len_max = 3;

fn gen_op(g: *Gen) Op {
    const kind: Kind = if (g.int_inclusive(1) == 0) .insert else .remove;
    const lo = g.int_inclusive(exhaust_domain - 1);
    const hi = g.range_inclusive(lo + 1, @min(lo + exhaust_len_max, exhaust_domain));
    return .{ .kind = kind, .lo = lo, .hi = hi };
}

fn exhaust(max_len: u32) bool {
    var trace = std.hash.Wyhash.init(0);
    var failing: [32]Op = undefined;
    var sequences_total: u64 = 0;
    var ops_total: u64 = 0;
    std.debug.print("exhaust: domain=0..{d} capacity={d} ranges of 1..{d} blocks, max_len={d}\n", .{
        exhaust_domain, exhaust_capacity, exhaust_len_max, max_len,
    });
    var length: u32 = 1;
    while (length <= max_len) : (length += 1) {
        const marks_start = marks.hits;
        var sequences: u64 = 0;
        var ops: u64 = 0;
        var failed_len: u32 = 0;
        var g: Gen = .{};
        while (!g.done()) {
            sequences += 1;
            var h = Harness.init(exhaust_domain, exhaust_capacity, &trace);
            defer h.deinit();
            for (0..length) |k| {
                failing[k] = gen_op(&g);
                ops += 1;
                if (!h.apply(failing[k])) {
                    failed_len = @intCast(k + 1);
                    break;
                }
            }
            if (failed_len != 0) break;
        }
        sequences_total += sequences;
        ops_total += ops;
        std.debug.print("len={d} sequences={d} ops={d} hits:", .{ length, sequences, ops });
        print_mark_deltas(&marks_start);
        if (failed_len != 0) {
            std.debug.print("FAIL at len={d}: sequence {d} of this length, {d} sequences and {d} ops in total\n", .{
                length, sequences, sequences_total, ops_total,
            });
            std.debug.print("minimal failing sequence (every shorter sequence passed), replayed:\n", .{});
            replay(failing[0..failed_len]);
            std.debug.print("exhaust trace={x:0>16} FAIL\n", .{trace.final()});
            return false;
        }
    }
    std.debug.print("PASS: every sequence up to len={d}: {d} sequences, {d} ops\n", .{ max_len, sequences_total, ops_total });
    std.debug.print("exhaust trace={x:0>16} PASS\n", .{trace.final()});
    return true;
}

/// Verbose replay of one op sequence on the small-scope configuration, showing every slot.
fn replay(ops: []const Op) void {
    var trace = std.hash.Wyhash.init(0);
    var h = Harness.init(exhaust_domain, exhaust_capacity, &trace);
    defer h.deinit();
    std.debug.print("  step op              mark                slots (live | stale)\n     - start                               ", .{});
    print_slots(&h.set);
    std.debug.print("\n", .{});
    for (ops, 0..) |op, k| {
        const before = marks.hits;
        const ok = h.apply(op);
        var buf: [40]u8 = undefined;
        const op_text = std.fmt.bufPrint(&buf, "{f}", .{op}) catch unreachable;
        std.debug.print("  {d:>4} {s:<15} {s:<19}", .{ k + 1, op_text, mark_hit_by(&before) });
        print_slots(&h.set);
        std.debug.print("\n", .{});
        if (!ok) {
            std.debug.print("INVARIANT VIOLATED: {s}\n", .{h.failure.?});
            break;
        }
    }
    std.debug.print("replay trace={x:0>16}\n", .{trace.final()});
}

// ---------------------------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse "sweep";
    const count = try std.fmt.parseInt(u64, args.next() orelse "100000", 10);
    var require_all = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bug-fill-gap")) {
            bug_fill_gap = true;
        } else if (std.mem.eql(u8, arg, "--gen-boundaries")) {
            gen_boundaries = true;
        } else if (std.mem.eql(u8, arg, "--require-all")) {
            require_all = true;
        } else {
            std.debug.print("unknown flag: {s}\n", .{arg});
            std.process.exit(2);
        }
    }
    if (std.mem.eql(u8, mode, "run")) {
        const r = run_seed(count, true);
        std.debug.print("seed={d} ops={d} trace={x:0>16} {s}\n", .{ count, r.ops, r.trace, if (r.ok) "PASS" else "FAIL" });
        if (!r.ok) std.process.exit(1);
        return;
    }
    if (std.mem.eql(u8, mode, "exhaust")) {
        if (count == 0 or count > 8) {
            std.debug.print("exhaust: max_len must be 1..8\n", .{});
            std.process.exit(2);
        }
        if (!exhaust(@intCast(count))) std.process.exit(1);
        return;
    }
    const coverage = std.mem.eql(u8, mode, "coverage");
    if (!coverage and !std.mem.eql(u8, mode, "sweep")) {
        std.debug.print("unknown mode: {s}\n", .{mode});
        std.process.exit(2);
    }

    // sweep / coverage: seeds 0..count-1, stop at the first failure.
    var seeds_hit: [marks.count]u64 = @splat(0);
    var ops_total: u64 = 0;
    var seed: u64 = 0;
    var failed = false;
    while (seed < count) : (seed += 1) {
        const before = marks.hits;
        const r = run_seed(seed, false);
        ops_total += r.ops;
        for (marks.hits, before, 0..) |now, then, k| seeds_hit[k] += @intFromBool(now != then);
        if (!r.ok) {
            std.debug.print("FAIL at seed={d} after {d} seeds ({d} ops). Replay with:\n", .{ seed, seed + 1, ops_total });
            std.debug.print("  zig run main.zig -- run {d}{s}{s}\n", .{
                seed, if (gen_boundaries) " --gen-boundaries" else "", if (bug_fill_gap) " --bug-fill-gap" else "",
            });
            failed = true;
            seed += 1;
            break;
        }
    }
    if (!failed) std.debug.print("PASS: {d} seeds ({d} ops)\n", .{ count, ops_total });
    if (coverage) {
        std.debug.print("coverage: {d} seeds, generator={s}\n  mark                 seeds_hit        hits\n", .{
            seed, if (gen_boundaries) "boundaries" else "uniform",
        });
        var never: u32 = 0;
        for (seeds_hit, marks.hits, std.enums.values(marks.Mark)) |s, total, mark| {
            std.debug.print("  {s:<19} {d:>10} {d:>11}{s}\n", .{
                @tagName(mark), s, total, if (total == 0) "   <-- NEVER HIT" else "",
            });
            never += @intFromBool(total == 0);
        }
        if (require_all and never > 0) {
            std.debug.print("--require-all: FAIL, {d} mark(s) never hit\n", .{never});
            std.process.exit(1);
        }
        if (require_all) std.debug.print("--require-all: every mark hit\n", .{});
    }
    if (failed) std.process.exit(1);
}

// ---------------------------------------------------------------------------------------------
// Traceability: each test names the branch it exists for. `exhaust 4 --bug-fill-gap` printed the
// minimal sequence below; it became the test for the fill-gap fast path.
// ---------------------------------------------------------------------------------------------

test "insert: a range that exactly plugs a hole fuses its neighbours" {
    const mark = marks.check(.insert_fill_gap);
    var set: IntervalSet = .{ .capacity = 3 };
    try set.insert(0, 1);
    try set.insert(2, 3);
    try set.insert(4, 5);
    try set.insert(1, 2);
    try mark.expect_hit();
    try std.testing.expectEqualSlices(Interval, &.{ .{ .lo = 0, .hi = 3 }, .{ .lo = 4, .hi = 5 } }, set.items());
}

test "remove: punching a hole in a full set is refused" {
    const mark = marks.check(.remove_split_full);
    var set: IntervalSet = .{ .capacity = 2 };
    try set.insert(0, 1);
    try set.insert(2, 5);
    try std.testing.expectError(error.NoSpace, set.remove(3, 4));
    try mark.expect_hit();
    try std.testing.expectEqualSlices(Interval, &.{ .{ .lo = 0, .hi = 1 }, .{ .lo = 2, .hi = 5 } }, set.items());
}
