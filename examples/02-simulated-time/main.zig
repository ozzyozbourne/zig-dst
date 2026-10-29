//! Example 02 — Never read the real clock.
//!
//! Code that reads the OS clock cannot be tested deterministically, and testing a 6-hour TTL
//! takes 6 hours. As in TigerBeetle, the code under test only asks a `Time` *interface* what
//! time it is. In production that is backed by the OS (TigerBeetle's `TimeOS`); here it is a
//! tick counter (`TimeSim`) that moves only when the simulator says so. +6 hours is one add.
//!
//! System under test: a TTL cache. `put(key, value, ttl)` stores an entry that expires at
//! `now + ttl`; `get(key)` returns the value only while `now < deadline`; `evict_expired()`
//! removes dead entries. The buggy version (--bug) treats an entry as still alive at the exact
//! tick `now == deadline` (`>` instead of `>=`). That is wrong for exactly one millisecond per
//! entry, which is why ordinary tests with sleep() basically never notice.
//!
//! Usage:
//!   zig run main.zig -- run   <seed>  [--bug]   # one seed, verbose
//!   zig run main.zig -- sweep <count> [--bug]   # seeds 0..count-1, stop at first failure
const std = @import("std");
const assert = std.debug.assert;

var bug_enabled = false;

const ms_per_s: u64 = 1000;
const ms_per_hour: u64 = 3600 * ms_per_s;

/// The only way the system under test may learn the time. Same shape as TigerBeetle's
/// `stdx.Time`: a type-erased context plus a vtable, so production and simulation share code.
const Time = struct {
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct { monotonic_ms: *const fn (*anyopaque) u64 };

    fn monotonic_ms(self: Time) u64 {
        return self.vtable.monotonic_ms(self.context);
    }
};

/// Simulated time: a counter. 1 tick = 1 simulated millisecond. Nothing here touches the OS,
/// so time is frozen between simulator steps and identical on every replay of a seed.
const TimeSim = struct {
    ticks: u64 = 0,

    const tick_ms: u64 = 1;

    fn interface(self: *TimeSim) Time {
        return .{ .context = self, .vtable = &.{ .monotonic_ms = vtable_monotonic_ms } };
    }

    fn vtable_monotonic_ms(context: *anyopaque) u64 {
        const self: *TimeSim = @ptrCast(@alignCast(context));
        return self.ticks * tick_ms;
    }

    /// Jumping forward N ticks costs the same whether N is 1 or 12 hours of milliseconds.
    fn advance(self: *TimeSim, ticks: u64) void {
        assert(ticks > 0); // Invariant: time only moves forward (and `+=` is overflow-checked).
        self.ticks += ticks;
    }
};

// ---------------------------------------------------------------- System under test.

const key_count = 16;
const capacity = key_count; // One slot per possible key, so put() can never run out of room.

const Entry = struct { key: u8, value: u32, deadline_ms: u64 };

const TtlCache = struct {
    time: Time,
    entries: [capacity]Entry = undefined,
    len: usize = 0,

    /// The boundary rule: an entry with deadline D is dead at every instant t >= D.
    fn expired(entry: Entry, now_ms: u64) bool {
        if (bug_enabled) return now_ms > entry.deadline_ms; // BUG: alive one tick too long.
        return now_ms >= entry.deadline_ms;
    }

    fn find(self: *const TtlCache, key: u8) ?usize {
        for (self.entries[0..self.len], 0..) |entry, i| {
            if (entry.key == key) return i;
        }
        return null;
    }

    fn put(self: *TtlCache, key: u8, value: u32, ttl_ms: u64) void {
        assert(ttl_ms > 0);
        const i = self.find(key) orelse blk: {
            assert(self.len < capacity);
            self.len += 1;
            break :blk self.len - 1;
        };
        self.entries[i] = .{ .key = key, .value = value, .deadline_ms = self.time.monotonic_ms() + ttl_ms };
    }

    fn get(self: *TtlCache, key: u8) ?u32 {
        const i = self.find(key) orelse return null;
        if (expired(self.entries[i], self.time.monotonic_ms())) {
            self.remove(i); // Lazy expiry.
            return null;
        }
        return self.entries[i].value;
    }

    fn evict_expired(self: *TtlCache) u32 {
        const now_ms = self.time.monotonic_ms();
        var evicted: u32 = 0;
        var i: usize = 0;
        while (i < self.len) {
            if (expired(self.entries[i], now_ms)) {
                self.remove(i); // Swap-remove: do not advance i, a new entry moved into slot i.
                evicted += 1;
            } else i += 1;
        }
        return evicted;
    }

    fn remove(self: *TtlCache, i: usize) void {
        assert(i < self.len);
        self.len -= 1;
        self.entries[i] = self.entries[self.len];
    }
};

// ---------------------------------------------------------------- Oracle.

/// Obviously-correct model, deliberately written differently from the cache: it remembers when
/// each key was put and for how long, and asks "has less than ttl elapsed?".
const Model = struct {
    slots: [key_count]?Slot = @splat(null),

    const Slot = struct { value: u32, put_at_ms: u64, ttl_ms: u64 };

    fn live(slot: Slot, now_ms: u64) bool {
        return now_ms - slot.put_at_ms < slot.ttl_ms;
    }

    fn get(self: *const Model, key: u8, now_ms: u64) ?u32 {
        const slot = self.slots[key] orelse return null;
        return if (live(slot, now_ms)) slot.value else null;
    }

    fn live_count(self: *const Model, now_ms: u64) usize {
        var count: usize = 0;
        for (self.slots) |maybe| {
            if (maybe) |slot| count += @intFromBool(live(slot, now_ms));
        }
        return count;
    }
};

// ---------------------------------------------------------------- Simulator.

/// TTLs are biased toward edges: the minimum (1 ms), typical short values, and very long ones
/// that a wall-clock test could never wait out.
fn gen_ttl_ms(random: std.Random) u64 {
    return switch (random.uintLessThan(u8, 100)) {
        0...9 => 1,
        10...79 => random.intRangeAtMost(u64, 1, 2 * ms_per_s),
        80...94 => random.intRangeAtMost(u64, 1, ms_per_hour),
        else => random.intRangeAtMost(u64, ms_per_hour, 24 * ms_per_hour),
    };
}

const Advance = enum { small, medium, jump, on_deadline, before_deadline };

/// Picks how far to move the clock. The `on_deadline` case is the important one: the simulator
/// looks at the model, picks a live entry, and lands time EXACTLY on its deadline. Random time
/// almost never does that on its own; a simulator that knows where the edges are does it often.
fn gen_advance(random: std.Random, model: *const Model, now_ms: u64) struct { Advance, u64 } {
    const roll = random.uintLessThan(u8, 100);
    if (roll < 30) if (model.slots[random.uintLessThan(u8, key_count)]) |slot| {
        const deadline = slot.put_at_ms + slot.ttl_ms;
        if (deadline > now_ms + 1) {
            if (roll < 20) return .{ .on_deadline, deadline - now_ms };
            return .{ .before_deadline, deadline - 1 - now_ms };
        }
    };
    return switch (roll % 10) {
        0...4 => .{ .small, random.intRangeAtMost(u64, 1, 10) },
        5...8 => .{ .medium, random.intRangeAtMost(u64, 1, 5 * ms_per_s) },
        else => .{ .jump, random.intRangeAtMost(u64, ms_per_hour, 12 * ms_per_hour) },
    };
}

const Result = struct { ok: bool, trace_hash: u64, steps: u32, sim_ms: u64 };

fn run_seed(seed: u64, verbose: bool) Result {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var trace = std.hash.Wyhash.init(0);

    var time_sim: TimeSim = .{};
    var cache: TtlCache = .{ .time = time_sim.interface() };
    var model: Model = .{};

    const steps: u32 = 50 + random.uintLessThan(u32, 200);
    var step: u32 = 0;
    while (step < steps) : (step += 1) {
        const now_ms = time_sim.ticks * TimeSim.tick_ms;
        const key = random.uintLessThan(u8, key_count);
        var event = [4]u64{ 0, key, now_ms, 0 };
        var ok = true;
        switch (random.uintLessThan(u8, 100)) {
            0...29 => {
                const value = random.int(u32);
                const ttl_ms = gen_ttl_ms(random);
                cache.put(key, value, ttl_ms);
                model.slots[key] = .{ .value = value, .put_at_ms = now_ms, .ttl_ms = ttl_ms };
                event[0] = 1;
                event[3] = ttl_ms;
            },
            30...64 => {
                // Invariant (oracle): every single get agrees with the model, checked as we go.
                const got = cache.get(key);
                const want = model.get(key, now_ms);
                event[0] = 2;
                event[3] = got orelse std.math.maxInt(u64);
                ok = got == want;
                if (!ok and verbose) std.debug.print(
                    "  step {d} t={d}ms: get({d}) = {?d}, want {?d} (deadline {d}ms)\n",
                    .{ step, now_ms, key, got, want, model.slots[key].?.put_at_ms + model.slots[key].?.ttl_ms },
                );
            },
            65...74 => {
                event[0] = 3;
                event[3] = cache.evict_expired();
                // Invariant: after eviction the cache holds exactly the entries the model says
                // are alive: nothing it holds is dead, and the counts match.
                for (cache.entries[0..cache.len]) |entry| {
                    if (model.get(entry.key, now_ms) != null) continue;
                    ok = false;
                    if (verbose) std.debug.print(
                        "  step {d} t={d}ms: evict kept key {d}, deadline {d}ms\n",
                        .{ step, now_ms, entry.key, entry.deadline_ms },
                    );
                }
                ok = ok and cache.len == model.live_count(now_ms);
            },
            else => {
                const kind, const ticks = gen_advance(random, &model, now_ms);
                time_sim.advance(ticks);
                event[0] = 4 + @as(u64, @backingInt(kind));
                event[3] = ticks;
                if (verbose and kind != .small and kind != .medium) std.debug.print(
                    "  step {d} t={d}ms: clock +{d}ms ({s})\n",
                    .{ step, now_ms, ticks, @tagName(kind) },
                );
            },
        }
        trace.update(std.mem.asBytes(&event));
        if (!ok) return .{ .ok = false, .trace_hash = trace.final(), .steps = step + 1, .sim_ms = now_ms };
    }
    return .{ .ok = true, .trace_hash = trace.final(), .steps = steps, .sim_ms = time_sim.ticks * TimeSim.tick_ms };
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse "sweep";
    const n = try std.fmt.parseInt(u64, args.next() orelse "100000", 10);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bug")) bug_enabled = true;
    }

    if (std.mem.eql(u8, mode, "run")) {
        const r = run_seed(n, true);
        std.debug.print("seed={d} steps={d} simulated={d}ms trace={x:0>16} {s}\n", .{
            n, r.steps, r.sim_ms, r.trace_hash, if (r.ok) "PASS" else "FAIL",
        });
        if (!r.ok) std.process.exit(1);
        return;
    }

    var sim_ms_total: u64 = 0;
    var seed: u64 = 0;
    while (seed < n) : (seed += 1) {
        const r = run_seed(seed, false);
        sim_ms_total += r.sim_ms;
        if (!r.ok) {
            std.debug.print("FAIL at seed={d} after {d} seeds. Replay with:\n", .{ seed, seed + 1 });
            std.debug.print("  zig run main.zig -- run {d}{s}\n", .{ seed, if (bug_enabled) " --bug" else "" });
            std.process.exit(1);
        }
    }
    // We do not time ourselves (no wall clock!). Measure real time from outside, e.g. `time`.
    std.debug.print("PASS: {d} seeds, simulated {d} s ({d} h) of clock time\n", .{
        n, sim_ms_total / ms_per_s, sim_ms_total / ms_per_hour,
    });
}
