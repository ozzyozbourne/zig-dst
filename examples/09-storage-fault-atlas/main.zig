//! Example 09 — Storage faults, the fault atlas, and the storage checker.
//!
//! Real disks lie. They flip bits when writing, flip bits when reading, rot while idle, and
//! (rarely, but it happens) write a perfectly good block to the WRONG place: a "misdirected
//! write". A replicated system survives this by keeping a checksum with every block, verifying
//! every read, and repairing a bad block from a peer that still has a good copy.
//!
//! System under test: a 3-replica, append-only replicated block log.
//!   - Every block on disk is `[checksum: u64][payload: 56 bytes]`. Its address is NOT stored in
//!     the block: it is implied by the block's position on disk.
//!   - Client reads go to one replica. That replica reads its local disk, verifies the checksum,
//!     and on a mismatch fetches a copy from a peer, verifies it, and writes it back (repair).
//!   - A background scrubber re-reads one block on one replica every few ticks and repairs it.
//!   - At every checkpoint (and once more at the end) each replica scrubs its whole log.
//!
//! The simulator injects faults, but only where a FAULT ATLAS allows them. The atlas is drawn
//! once per seed: for every block it marks at most `replica_count - 1` replicas as "faulty" for
//! that block. So at least one replica always keeps a good copy. Without this guarantee the
//! simulator could corrupt all three copies of a block. That would be data loss caused by the
//! test itself, not by a bug, and the test would report false alarms forever.
//!
//! Invariants, checked while the simulation runs:
//!   1. Safety: a client read never returns data that differs from what was appended (oracle).
//!   2. Storage checker: at every checkpoint, after the repair sweep, the replicas' logs are
//!      byte-identical (like TigerBeetle's testing/cluster/storage_checker.zig).
//!   3. Liveness: every repair finds a good copy on some peer, and after the final repair phase
//!      (faults off, like TigerBeetle's `transition_to_liveness_mode`) every block reads back.
//!   4. Harness self-check: every tick, each written block has at least one exact good copy.
//!      If this fails, the fault injector broke the atlas. That is a bug in the TEST, not in the
//!      system, so it panics instead of reporting FAIL.
//!
//! Planted bugs:
//!   --bug-trust-read  the local read path skips checksum verification ("the disk said OK").
//!   --bug-misdirect   the checksum covers only the payload, not the block address. A block
//!                     misdirected into another block's slot then still verifies.
//!
//! Usage:
//!   zig run main.zig -- run   <seed>  [--bug-trust-read] [--bug-misdirect]
//!   zig run main.zig -- sweep <count> [--bug-trust-read] [--bug-misdirect]
//!   Add --all-events to `run` to also print every append and client read (output only; the
//!   trace hash and the result are unchanged).
const std = @import("std");
const assert = std.debug.assert;

const replica_count = 3;
const block_count = 32;
const block_size = 64;
const checksum_size = 8;
const payload_size = block_size - checksum_size;

/// How many replicas the atlas may mark faulty for a single block. `replica_count - 1` is the
/// most we can allow while still keeping one good copy. TigerBeetle uses a stricter bound
/// (quorum_replication - 1) because its protocol needs more than "one good copy somewhere".
const faults_max = replica_count - 1;

const ticks_max = 600;
const scrub_interval = 3; // The scrubber checks one (replica, block) every 3 ticks.
const checkpoint_interval = 100;

var bug_trust_read = false;
var bug_misdirect = false;
/// Print-only: with `run`, also show `append` and `client_read` events (used by the site replay).
var all_events = false;

const Block = [block_size]u8;
const Payload = [payload_size]u8;

/// The checksum must bind the payload to its ADDRESS. If it covers only the payload, a block
/// written to the wrong address is still a valid block and nothing on disk shows the mistake.
/// TigerBeetle's block header stores `address` and its header checksum covers it. Readers also
/// check the checksum against the one the parent block recorded (vsr/grid.zig read_block_validate).
fn checksum(address: u64, payload: *const Payload) u64 {
    var h = std.hash.Wyhash.init(0);
    if (!bug_misdirect) h.update(std.mem.asBytes(&address));
    h.update(payload);
    return h.final();
}

fn block_make(address: u64, payload: *const Payload) Block {
    var block: Block = undefined;
    std.mem.writeInt(u64, block[0..checksum_size], checksum(address, payload), .little);
    block[checksum_size..].* = payload.*;
    return block;
}

fn block_valid(address: u64, block: *const Block) bool {
    const stored = std.mem.readInt(u64, block[0..checksum_size], .little);
    return stored == checksum(address, block[checksum_size..]);
}

/// The fault atlas, modeled on ClusterFaultAtlas in tigerbeetle/src/testing/storage.zig.
/// `faulty[r][a]` means: replica r's storage may corrupt or misdirect block a. Outside the
/// atlas, storage is perfect. Since no block is faulty on every replica, every block is always
/// repairable. Any failure the test reports is a real bug, not bad luck.
const FaultAtlas = struct {
    faulty: [replica_count][block_count]bool,

    fn init(random: std.Random) FaultAtlas {
        var atlas: FaultAtlas = .{
            .faulty = @splat(@splat(false)),
        };
        var faulty_count: [replica_count]u32 = @splat(0);
        for (0..block_count) |address| {
            var chosen: u32 = 0;
            while (chosen < faults_max) {
                const r = random.uintLessThan(u8, replica_count);
                if (atlas.faulty[r][address]) continue;
                // Like TigerBeetle: never make every block of one replica faulty.
                if (faulty_count[r] + 1 >= block_count) continue;
                atlas.faulty[r][address] = true;
                faulty_count[r] += 1;
                chosen += 1;
            }
            // The guarantee that the whole test depends on:
            var good: u32 = 0;
            for (0..replica_count) |r| good += @intFromBool(!atlas.faulty[r][address]);
            assert(good >= 1);
        }
        return atlas;
    }
};

const Event = enum(u8) {
    append,
    client_read,
    fault_write_flip,
    fault_misdirect,
    fault_read_flip,
    fault_rot,
    repair,
    scrub_repair,
    checkpoint,

    fn interesting(e: Event) bool {
        return switch (e) {
            .append, .client_read => false,
            else => true,
        };
    }
};

const Failure = error{ CorruptDataReturned, Unrepairable, StorageMismatch };

const Sim = struct {
    random: std.Random,
    trace: std.hash.Wyhash,
    verbose: bool,
    atlas: FaultAtlas,

    /// Each replica's disk: real bytes, so corruption is real corruption.
    disks: [replica_count][block_count]Block,
    /// Test oracle (not visible to the system under test): what each address must contain.
    expected: [block_count]Payload,
    /// The same oracle as whole blocks (`block_make` of `expected`), cached for check_atlas.
    expected_block: [block_count]Block,
    log_len: u32 = 0,
    tick: u64 = 0,
    /// false during checkpoint sweeps and in the final liveness phase.
    faults_enabled: bool = true,

    // Swarm-style fault rates (percent), drawn per seed so some seeds are calm and some are harsh.
    read_fault_pct: u8,
    write_fault_pct: u8,
    misdirect_pct: u8,
    rot_pct: u8,

    scrub_replica: u8 = 0,
    scrub_address: u32 = 0,

    fn event(sim: *Sim, e: Event, replica: u8, address: u64, extra: u64) void {
        sim.trace.update(std.mem.asBytes(&[_]u64{ @backingInt(e), sim.tick, replica, address, extra }));
        if (sim.verbose and (all_events or e.interesting())) {
            std.debug.print("  t={d:>3} {s:<16} replica={d} block={d:>2} {x}\n", .{
                sim.tick, @tagName(e), replica, address, extra,
            });
        }
    }

    fn fail(sim: *Sim, err: Failure, replica: u8, address: u64) Failure {
        if (sim.verbose) std.debug.print("  t={d:>3} FAIL {s}: replica={d} block={d}\n", .{
            sim.tick, @errorName(err), replica, address,
        });
        return err;
    }

    fn eligible(sim: *const Sim, replica: u8, address: u32) bool {
        return sim.faults_enabled and sim.atlas.faulty[replica][address];
    }

    fn chance(sim: *Sim, pct: u8) bool {
        return sim.random.uintLessThan(u8, 100) < pct;
    }

    /// Flip one random bit of `block` and record the fault event `e`, with the bit index as extra.
    fn inject_flip(sim: *Sim, e: Event, replica: u8, address: u32, block: *Block) void {
        const byte = sim.random.uintLessThan(u32, block_size);
        const bit = sim.random.int(u3);
        block[byte] ^= @as(u8, 1) << bit;
        sim.event(e, replica, address, byte * 8 + bit);
    }

    // ---- Simulated disk ------------------------------------------------------------------

    /// Write `block` to `address` on `replica`. Inside the atlas, the write may be corrupted
    /// or misdirected. A misdirected write leaves the intended slot unchanged (stale or never
    /// written) and overwrites a different, already-written slot. As in TigerBeetle, the wrong
    /// target is always another faulty block of this replica, so the atlas guarantee holds.
    fn disk_write(sim: *Sim, replica: u8, address: u32, block: *const Block) void {
        if (sim.eligible(replica, address) and sim.chance(sim.misdirect_pct)) {
            if (sim.misdirect_target(replica, address)) |target| {
                sim.disks[replica][target] = block.*;
                sim.event(.fault_misdirect, replica, address, target);
                return;
            }
        }
        sim.disks[replica][address] = block.*;
        if (sim.eligible(replica, address) and sim.chance(sim.write_fault_pct)) {
            sim.inject_flip(.fault_write_flip, replica, address, &sim.disks[replica][address]);
        }
    }

    fn misdirect_target(sim: *Sim, replica: u8, address: u32) ?u32 {
        var candidates: u32 = 0;
        for (0..sim.log_len) |a| {
            if (a != address and sim.atlas.faulty[replica][a]) candidates += 1;
        }
        if (candidates == 0) return null;
        var pick = sim.random.uintLessThan(u32, candidates);
        for (0..sim.log_len) |a| {
            if (a != address and sim.atlas.faulty[replica][a]) {
                if (pick == 0) return @intCast(a);
                pick -= 1;
            }
        }
        unreachable;
    }

    /// Read returns a COPY. A read fault corrupts the copy only (transient), not the disk.
    fn disk_read(sim: *Sim, replica: u8, address: u32) Block {
        var block = sim.disks[replica][address];
        if (sim.eligible(replica, address) and sim.chance(sim.read_fault_pct)) {
            sim.inject_flip(.fault_read_flip, replica, address, &block);
        }
        return block;
    }

    // ---- System under test ---------------------------------------------------------------

    fn append(sim: *Sim) void {
        const address = sim.log_len;
        sim.random.bytes(&sim.expected[address]);
        const block = &sim.expected_block[address];
        block.* = block_make(address, &sim.expected[address]);
        sim.log_len += 1;
        for (0..replica_count) |r| sim.disk_write(@intCast(r), address, block);
        sim.event(.append, 0, address, std.hash.Wyhash.hash(0, block));
    }

    /// Ask the peers for a verified copy. The repairing replica always verifies what it gets
    /// over the network, even with --bug-trust-read, because that bug is only on the local path.
    fn repair(sim: *Sim, replica: u8, address: u32) Failure!Block {
        for (1..replica_count) |i| {
            const peer: u8 = @intCast((replica + i) % replica_count);
            const block = sim.disk_read(peer, address);
            if (block_valid(address, &block)) {
                sim.disk_write(replica, address, &block);
                sim.event(.repair, replica, address, peer);
                return block;
            }
        }
        // Liveness: the atlas promises a good copy exists, so failing to find one is a bug.
        return sim.fail(error.Unrepairable, replica, address);
    }

    fn client_read(sim: *Sim, replica: u8, address: u32) Failure!void {
        var block = sim.disk_read(replica, address);
        // THE LOCAL READ PATH. With --bug-trust-read, whatever the disk returned goes to the client.
        if (!bug_trust_read and !block_valid(address, &block)) {
            block = try sim.repair(replica, address);
        }
        const payload = block[checksum_size..];
        sim.event(.client_read, replica, address, std.hash.Wyhash.hash(0, payload));
        // Invariant 1 (safety), checked on every single read, not at the end.
        if (!std.mem.eql(u8, payload, &sim.expected[address])) {
            return sim.fail(error.CorruptDataReturned, replica, address);
        }
    }

    fn scrub(sim: *Sim, replica: u8, address: u32) Failure!void {
        const block = sim.disk_read(replica, address);
        if (!block_valid(address, &block)) {
            sim.event(.scrub_repair, replica, address, 0);
            _ = try sim.repair(replica, address);
        }
    }

    fn scrub_step(sim: *Sim) Failure!void {
        if (sim.log_len == 0) return;
        if (sim.scrub_address >= sim.log_len) sim.scrub_address = 0;
        try sim.scrub(sim.scrub_replica, sim.scrub_address);
        sim.scrub_replica = (sim.scrub_replica + 1) % replica_count;
        if (sim.scrub_replica == 0) sim.scrub_address += 1;
    }

    /// Checkpoint barrier: with faults paused, every replica scrubs its whole log, then the
    /// storage checker requires the logs to be byte-identical across replicas (invariant 2).
    fn checkpoint(sim: *Sim) Failure!void {
        const faults_were_enabled = sim.faults_enabled;
        sim.faults_enabled = false;
        defer sim.faults_enabled = faults_were_enabled;

        for (0..replica_count) |r| {
            for (0..sim.log_len) |a| try sim.scrub(@intCast(r), @intCast(a));
        }

        var hashes: [replica_count]u64 = undefined;
        for (0..replica_count) |r| {
            var h = std.hash.Wyhash.init(0);
            for (0..sim.log_len) |a| {
                h.update(&sim.disks[r][a]);
                h.update(std.mem.asBytes(&@as(u64, a))); // Like TigerBeetle: guard identical blocks.
            }
            hashes[r] = h.final();
        }
        sim.event(.checkpoint, 0, sim.log_len, hashes[0]);
        for (1..replica_count) |r| {
            if (hashes[r] != hashes[0]) {
                if (sim.verbose) std.debug.print(
                    "  storage checker: replica 0 hash={x:0>16} replica {d} hash={x:0>16}\n",
                    .{ hashes[0], r, hashes[r] },
                );
                // Report the first block that differs.
                for (0..sim.log_len) |a| {
                    if (!std.mem.eql(u8, &sim.disks[r][a], &sim.disks[0][a])) {
                        return sim.fail(error.StorageMismatch, @intCast(r), a);
                    }
                }
                unreachable;
            }
        }
    }

    /// Invariant 4 (harness self-check): the fault injector must respect the atlas. If no
    /// replica holds the exact block, the scenario is unrecoverable by construction. That would
    /// be a test bug, so it panics instead of reporting a FAIL against the system.
    fn check_atlas(sim: *const Sim) void {
        for (0..sim.log_len) |a| {
            for (0..replica_count) |r| {
                if (std.mem.eql(u8, &sim.disks[r][a], &sim.expected_block[a])) break;
            } else std.debug.panic("harness bug: block {d} has no good copy anywhere", .{a});
        }
    }
};

/// `reason` is the failure's error name, or null if the seed passed.
const Result = struct { trace_hash: u64, reason: ?[]const u8 };

fn run_seed(seed: u64, verbose: bool) Result {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    // Separate sub-seed for the atlas, so changing workload code does not change the atlas.
    var atlas_prng = std.Random.DefaultPrng.init(random.int(u64));

    var sim: Sim = .{
        .random = random,
        .trace = std.hash.Wyhash.init(seed),
        .verbose = verbose,
        .atlas = FaultAtlas.init(atlas_prng.random()),
        .disks = std.mem.zeroes([replica_count][block_count]Block), // all-zero = never written
        .expected = undefined,
        .expected_block = undefined,
        .read_fault_pct = random.uintAtMost(u8, 20),
        .write_fault_pct = random.uintAtMost(u8, 20),
        .misdirect_pct = random.uintAtMost(u8, 15),
        .rot_pct = random.uintAtMost(u8, 10),
    };
    if (verbose) {
        std.debug.print("  faults: read={d}% write={d}% misdirect={d}% rot={d}%\n", .{
            sim.read_fault_pct, sim.write_fault_pct, sim.misdirect_pct, sim.rot_pct,
        });
        for (0..replica_count) |r| {
            std.debug.print("  atlas replica {d}: ", .{r});
            for (sim.atlas.faulty[r]) |f| std.debug.print("{s}", .{if (f) "x" else "."});
            std.debug.print("\n", .{});
        }
    }

    simulate(&sim) catch |err| {
        return .{ .trace_hash = sim.trace.final(), .reason = @errorName(err) };
    };
    return .{ .trace_hash = sim.trace.final(), .reason = null };
}

fn simulate(sim: *Sim) Failure!void {
    const random = sim.random;
    while (sim.tick < ticks_max) : (sim.tick += 1) {
        // Workload: append until the log is full, interleaved with client reads.
        if (sim.log_len < block_count and sim.chance(15)) {
            sim.append();
        } else if (sim.log_len > 0) {
            const replica = random.uintLessThan(u8, replica_count);
            const address = random.uintLessThan(u32, sim.log_len);
            try sim.client_read(replica, address);
        }

        // Latent corruption ("bit rot") of data at rest, only inside the atlas.
        if (sim.log_len > 0 and sim.chance(sim.rot_pct)) {
            const replica = random.uintLessThan(u8, replica_count);
            const address = random.uintLessThan(u32, sim.log_len);
            if (sim.eligible(replica, address)) {
                sim.inject_flip(.fault_rot, replica, address, &sim.disks[replica][address]);
            }
        }

        if (sim.tick % scrub_interval == 0) try sim.scrub_step();
        if (sim.tick % checkpoint_interval == checkpoint_interval - 1) try sim.checkpoint();
        sim.check_atlas();
    }

    // Final repair phase = liveness mode: faults off for good, repair everything, then check.
    sim.faults_enabled = false;
    try sim.checkpoint();
    for (0..replica_count) |r| {
        for (0..sim.log_len) |a| try sim.client_read(@intCast(r), @intCast(a));
    }
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse "sweep";
    const n = try std.fmt.parseInt(u64, args.next() orelse "10000", 10);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bug-trust-read")) {
            bug_trust_read = true;
        } else if (std.mem.eql(u8, arg, "--bug-misdirect")) {
            bug_misdirect = true;
        } else if (std.mem.eql(u8, arg, "--all-events")) {
            all_events = true;
        } else {
            std.debug.print("unknown flag: {s}\n", .{arg});
            std.process.exit(2);
        }
    }
    if (std.mem.eql(u8, mode, "run")) {
        const r = run_seed(n, true);
        std.debug.print("seed={d} trace={x:0>16} {s}{s}\n", .{
            n, r.trace_hash, if (r.reason == null) "PASS" else "FAIL ", r.reason orelse "",
        });
        if (r.reason != null) std.process.exit(1);
        return;
    }

    var seed: u64 = 0;
    while (seed < n) : (seed += 1) {
        const r = run_seed(seed, false);
        if (r.reason) |reason| {
            std.debug.print("FAIL at seed={d} ({s}) after {d} seeds. Replay with:\n", .{
                seed, reason, seed + 1,
            });
            std.debug.print("  zig run main.zig -- run {d}{s}{s}\n", .{
                seed,
                if (bug_trust_read) " --bug-trust-read" else "",
                if (bug_misdirect) " --bug-misdirect" else "",
            });
            std.process.exit(1);
        }
    }
    std.debug.print("PASS: {d} seeds\n", .{n});
}
