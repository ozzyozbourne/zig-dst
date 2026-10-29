//! Example 01 — The seed is everything.
//!
//! The smallest possible deterministic simulation: a random test whose ONLY source of
//! randomness is a PRNG seeded from a number we print. When the test fails, the seed is a
//! complete bug report: replay it and you get the exact same inputs, the exact same failure.
//!
//! System under test: `average(a, b)` for u32 timestamps (e.g. a midpoint for a binary search
//! over time). The buggy version computes `(a + b) / 2`, which overflows when a + b > 2^32 - 1.
//!
//! Usage:
//!   zig run main.zig -- run   <seed>  [--bug]   # one seed, verbose
//!   zig run main.zig -- sweep <count> [--bug]   # seeds 0..count-1, stop at first failure
const std = @import("std");

var bug_enabled = false;
/// Opt-in extras for the website (off by default; they never touch the trace hash):
/// --dump prints every step's inputs, --uniform swaps in a uniform generator (exercise 1).
var dump_enabled = false;
var uniform_enabled = false;

/// System under test.
fn average(a: u32, b: u32) u32 {
    if (bug_enabled) {
        // Wrapping add so the bug shows up as a wrong answer instead of a Zig safety panic.
        return (a +% b) / 2;
    }
    // Correct: never overflows.
    return a / 2 + b / 2 + (a & b & 1);
}

/// Biased generator. Uniform random u32s hit the bug half the time, which is unrealistic.
/// Real bugs live at edges, so most values are small and a few are "interesting" (near max).
/// This teaches the most important DST skill: generate the inputs that matter.
/// Returns the bucket roll (100 = uniform; only printed by --dump) and the value.
fn gen_value(random: std.Random) struct { u8, u32 } {
    if (uniform_enabled) return .{ 100, random.int(u32) };
    const roll = random.uintLessThan(u8, 100);
    const value = switch (roll) {
        0...97 => random.uintAtMost(u32, 1_000_000), // typical
        98 => random.int(u32), // anywhere
        else => std.math.maxInt(u32) - random.uintAtMost(u32, 16), // edge
    };
    return .{ roll, value };
}

const Result = struct { ok: bool, trace_hash: u64, steps: u32 };

fn run_seed(seed: u64, verbose: bool) Result {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    // Every observable step is folded into a hash: same seed => same hash, always.
    var trace = std.hash.Wyhash.init(0);

    const steps: u32 = 1 + random.uintLessThan(u32, 8);
    var i: u32 = 0;
    while (i < steps) : (i += 1) {
        const roll_a, const a = gen_value(random);
        const roll_b, const b = gen_value(random);
        const got = average(a, b);
        // Oracle: compute the obviously-correct answer in a wider type.
        const want: u32 = @intCast((@as(u64, a) + @as(u64, b)) / 2);
        if (dump_enabled) std.debug.print(
            "  dump seed={d} step={d} roll_a={d} a={d} roll_b={d} b={d} got={d} want={d}\n",
            .{ seed, i, roll_a, a, roll_b, b, got, want },
        );
        trace.update(std.mem.asBytes(&[3]u32{ a, b, got }));
        if (got != want) {
            if (verbose) std.debug.print(
                "  step {d}: average({d}, {d}) = {d}, want {d}\n",
                .{ i, a, b, got, want },
            );
            return .{ .ok = false, .trace_hash = trace.final(), .steps = i + 1 };
        }
    }
    return .{ .ok = true, .trace_hash = trace.final(), .steps = steps };
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse "sweep";
    const n = try std.fmt.parseInt(u64, args.next() orelse "1000", 10);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bug")) bug_enabled = true;
        if (std.mem.eql(u8, arg, "--dump")) dump_enabled = true;
        if (std.mem.eql(u8, arg, "--uniform")) uniform_enabled = true;
    }

    if (std.mem.eql(u8, mode, "run")) {
        const r = run_seed(n, true);
        std.debug.print("seed={d} steps={d} trace={x:0>16} {s}\n", .{
            n, r.steps, r.trace_hash, if (r.ok) "PASS" else "FAIL",
        });
        if (!r.ok) std.process.exit(1);
        return;
    }

    var seed: u64 = 0;
    while (seed < n) : (seed += 1) {
        const r = run_seed(seed, false);
        if (!r.ok) {
            std.debug.print("FAIL at seed={d} after {d} seeds. Replay with:\n", .{ seed, seed + 1 });
            std.debug.print("  zig run main.zig -- run {d}{s}\n", .{ seed, if (bug_enabled) " --bug" else "" });
            std.process.exit(1);
        }
    }
    std.debug.print("PASS: {d} seeds\n", .{n});
}
