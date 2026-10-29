//! Example 04 — A simulated disk that loses and tears writes when the machine crashes.
//!
//! The disk is a byte array in memory, split into sectors. A write does NOT go straight to that
//! array: it sits in a volatile write cache (the OS page cache plus the drive's own cache) until
//! fsync. Between write and fsync the disk may quietly write cached sectors back on its own, in
//! any order. When the machine crashes (power loss, kernel panic, VM killed), each sector still
//! in the cache is either applied or dropped. Dropping all of a record's sectors loses the record.
//! Applying only some of them leaves a TORN record: for example, a fresh header followed by
//! stale payload bytes.
//!
//! System under test: a tiny key-value store with a write-ahead log (WAL). A put:
//!   1. appends a record [checksum | parent | seq | key | len | value] padded to whole sectors,
//!   2. calls fsync (which takes simulated time and can be interrupted by a crash),
//!   3. acks the client only after fsync completes.
//! On restart, recovery replays the log from offset 0 and stops at the first invalid record.
//! (Puts are batched: several records may be appended before one fsync acks them all.)
//!
//! Each seed crashes and restarts the store many times. After every restart the recovered log
//! is checked against an oracle (the list of puts the client saw acked):
//!   (1) durability:  every acked put is recovered, unchanged and in order.
//!   (2) no garbage:  every recovered record is one that the client actually wrote.
//!   (3) exact state: recovered log == acked prefix ++ (some prefix of the in-flight unacked
//!       puts), and the key-value table matches what replaying that log gives.
//!
//! Planted bugs:
//!   --bug-ack-before-fsync  ack as soon as the record is in the cache (violates (1)).
//!   --bug-no-checksum       recovery trusts the header's seq/len fields and skips the checksum,
//!                           so a torn record is replayed with stale bytes (violates (2)).
//!
//! Usage:
//!   zig run main.zig -- run   <seed>  [--bug-ack-before-fsync] [--bug-no-checksum]
//!   zig run main.zig -- sweep <count> [--bug-ack-before-fsync] [--bug-no-checksum]
//!   (add --sectors to `run` for a sector-level dump after each crash; output only)
const std = @import("std");
const assert = std.debug.assert;

var bug_ack_before_fsync = false;
var bug_no_checksum = false;
/// `--sectors` (run mode only): after each crash, also print the sector-level detail (unsynced
/// records, per-sector crash outcome, the tail of the recovery scan, the record it stopped at).
/// Output only: it draws nothing from the PRNG and adds nothing to the trace.
var verbose_sectors = false;

// Small sectors so that records span 1..3 sectors and tearing is common. Real disks use
// 512 B or 4 KiB; TigerBeetle uses constants.sector_size = 4096.
const sector_size = 64;
const sector_count = 4096; // 256 KiB disk
const header_size = 32;
const record_size_max = 3 * sector_size;
const value_max = record_size_max - header_size; // largest value that fits in 3 sectors
const key_count = 8;
const batch_max = 4; // most puts the store will group under one fsync

const ticks_per_seed = 3000;
const crash_one_in = 80; // per-tick crash chance
const writeback_percent = 15; // per-tick chance the disk writes back one cached sector on its own
const fsync_latency_max = 6; // ticks

// ---------------------------------------------------------------------------------------------
// Trace: every observable event is folded in, so equal seeds print equal trace hashes.

var trace: std.hash.Wyhash = undefined;

fn event(tag: u8, a: u64, b: u64) void {
    trace.update(&[_]u8{tag});
    trace.update(std.mem.asBytes(&[2]u64{ a, b }));
}

// ---------------------------------------------------------------------------------------------
// Simulated disk.

const CachedSector = struct { sector: u32, data: [sector_size]u8 };

const Disk = struct {
    /// Survives a crash. Starts full of random bytes (like TigerBeetle's testing Storage, which
    /// fills never-written sectors with PRNG bytes) so that stale data looks like noise rather
    /// than conveniently-invalid zeros.
    durable: []u8,
    /// Written but not yet durable, oldest first. Lost or torn on crash.
    cache: std.ArrayList(CachedSector) = .empty,
    random: std.Random,
    /// The fields below are only printed by --sectors (they draw nothing and touch no trace).
    /// What the last crash did to each cached sector, in cache order.
    last_crash: struct {
        keep_percent: u8 = 0,
        len: usize = 0,
        sectors: [batch_max * record_size_max / sector_size]struct { sector: u32, applied: bool } = undefined,
    } = .{},
    /// Furthest byte the log has ever reached.
    high_water: u64 = 0,

    fn write(disk: *Disk, gpa: std.mem.Allocator, offset: u64, bytes: []const u8) !void {
        assert(offset % sector_size == 0);
        assert(bytes.len % sector_size == 0);
        assert(offset + bytes.len <= disk.durable.len);
        var i: usize = 0;
        while (i < bytes.len) : (i += sector_size) {
            const sector: u32 = @intCast((offset + i) / sector_size);
            // Like TigerBeetle's Storage.write_sectors(): no two in-flight writes may overlap.
            // A write-ahead log only appends, so this must hold.
            for (disk.cache.items) |c| assert(c.sector != sector);
            try disk.cache.append(gpa, .{ .sector = sector, .data = bytes[i..][0..sector_size].* });
        }
        disk.high_water = @max(disk.high_water, offset + bytes.len);
    }

    /// Reads see the cache first (read-your-writes), then durable bytes.
    fn read(disk: *const Disk, offset: u64, buffer: []u8) void {
        assert(offset + buffer.len <= disk.durable.len);
        @memcpy(buffer, disk.durable[offset..][0..buffer.len]);
        for (disk.cache.items) |c| {
            const start = @as(u64, c.sector) * sector_size;
            if (start + sector_size <= offset or start >= offset + buffer.len) continue;
            // Overlap: copy the overlapping part of the cached sector.
            const lo = @max(start, offset);
            const hi = @min(start + sector_size, offset + buffer.len);
            @memcpy(buffer[lo - offset .. hi - offset], c.data[lo - start .. hi - start]);
        }
    }

    fn apply(disk: *Disk, c: CachedSector) void {
        @memcpy(disk.durable[@as(u64, c.sector) * sector_size ..][0..sector_size], &c.data);
    }

    /// Background writeback: the disk may persist ANY cached sector at ANY time, in any order.
    /// This is why "it hasn't been fsynced" does not mean "it is not on disk".
    fn tick(disk: *Disk) void {
        if (disk.cache.items.len == 0) return;
        if (disk.random.uintLessThan(u8, 100) >= writeback_percent) return;
        const index = disk.random.uintLessThan(usize, disk.cache.items.len);
        const c = disk.cache.orderedRemove(index);
        disk.apply(c);
        event('w', c.sector, 0);
    }

    /// fsync completes: everything written so far becomes durable.
    fn fsync(disk: *Disk) void {
        for (disk.cache.items) |c| disk.apply(c);
        disk.cache.clearRetainingCapacity();
    }

    /// Power loss. Each cached sector is applied or dropped on its own, so a multi-sector record
    /// can be fully lost, fully kept, or torn. The keep rate varies per crash so that some crashes
    /// drop everything, some keep everything, and most are in between.
    fn crash(disk: *Disk) struct { applied: usize, dropped: usize } {
        const keep_percent = disk.random.uintAtMost(u8, 100);
        var applied: usize = 0;
        disk.last_crash.keep_percent = keep_percent;
        disk.last_crash.len = disk.cache.items.len;
        for (disk.cache.items, disk.last_crash.sectors[0..disk.cache.items.len]) |c, *log| {
            const keep = disk.random.uintLessThan(u8, 100) < keep_percent;
            if (keep) {
                disk.apply(c);
                applied += 1;
            }
            log.* = .{ .sector = c.sector, .applied = keep };
        }
        const dropped = disk.cache.items.len - applied;
        disk.cache.clearRetainingCapacity();
        return .{ .applied = applied, .dropped = dropped };
    }
};

// ---------------------------------------------------------------------------------------------
// System under test: WAL-backed key-value store.

const Record = struct {
    seq: u64,
    key: u8,
    len: u8,
    value: [value_max]u8,

    fn eql(a: *const Record, b: *const Record) bool {
        return a.seq == b.seq and a.key == b.key and a.len == b.len and
            std.mem.eql(u8, a.value[0..a.len], b.value[0..b.len]);
    }

    fn sectors(len: usize) usize {
        return std.math.divCeil(usize, header_size + len, sector_size) catch unreachable;
    }
};

/// The checksum covers everything after the checksum field: parent, seq, key, len and value.
fn record_checksum(bytes_after_checksum: []const u8) u64 {
    return std.hash.Wyhash.hash(0x5eed, bytes_after_checksum);
}

/// On-disk layout (little endian):
///   [0..8)   checksum of bytes [8 .. 32+len)
///   [8..16)  parent: checksum of the previous record (hash chain; 0 for the first)
///   [16..24) seq
///   [24]     key   [25] len   [26..32) zero padding
///   [32..32+len) value, then zero padding to the sector boundary
fn encode(buffer: []u8, parent: u64, r: *const Record) u64 {
    @memset(buffer, 0);
    std.mem.writeInt(u64, buffer[8..16], parent, .little);
    std.mem.writeInt(u64, buffer[16..24], r.seq, .little);
    buffer[24] = r.key;
    buffer[25] = r.len;
    @memcpy(buffer[header_size..][0..r.len], r.value[0..r.len]);
    const checksum = record_checksum(buffer[8 .. header_size + r.len]);
    std.mem.writeInt(u64, buffer[0..8], checksum, .little);
    return checksum;
}

const Header = struct { checksum: u64, parent: u64, seq: u64, key: u8, len: u8 };

fn decode_header(bytes: *const [header_size]u8) Header {
    return .{
        .checksum = std.mem.readInt(u64, bytes[0..8], .little),
        .parent = std.mem.readInt(u64, bytes[8..16], .little),
        .seq = std.mem.readInt(u64, bytes[16..24], .little),
        .key = bytes[24],
        .len = bytes[25],
    };
}

/// `buffer` holds the whole record whose header is `header`.
fn checksum_ok(buffer: []const u8, header: Header) bool {
    return record_checksum(buffer[8 .. header_size + header.len]) == header.checksum;
}

const Store = struct {
    // Everything here is volatile: rebuilt from the disk by recover() after every crash.
    log_end: u64 = 0,
    next_seq: u64 = 1,
    last_checksum: u64 = 0,
    table: [key_count]?Record = @splat(null),
    /// Appended, waiting for fsync before they are acked.
    batch: [batch_max]Record = undefined,
    batch_len: usize = 0,
    fsync_done_at: ?u64 = null,
    /// Why the last recovery stopped replaying (for the verbose trace).
    stop: []const u8 = "",

    fn full(store: *const Store) bool {
        return store.log_end + record_size_max > sector_count * sector_size;
    }

    /// Append a record to the log. With the bug, ack right away (data only in volatile cache!).
    /// Returns true if the put was acked immediately.
    fn put(store: *Store, gpa: std.mem.Allocator, disk: *Disk, r: Record) !bool {
        assert(store.fsync_done_at == null);
        assert(store.batch_len < batch_max);
        assert(r.seq == store.next_seq);
        var buffer: [record_size_max]u8 = undefined;
        const size = Record.sectors(r.len) * sector_size;
        store.last_checksum = encode(buffer[0..size], store.last_checksum, &r);
        try disk.write(gpa, store.log_end, buffer[0..size]);
        store.log_end += size;
        store.next_seq += 1;
        store.batch[store.batch_len] = r;
        store.batch_len += 1;
        if (bug_ack_before_fsync) {
            // BUG: "write() returned, so it's on disk." It is not: it is in a cache that a power
            // failure wipes. The store still fsyncs later, so the data USUALLY becomes durable,
            // and kill -9 never wipes that cache anyway. That is why this bug ships.
            store.table[r.key] = r;
            return true;
        }
        return false;
    }

    /// fsync finished: everything in the batch is durable, so apply it and return the puts
    /// to ack now. (With the bug they were acked already, so there is nothing left to ack.)
    fn on_fsync(store: *Store) []const Record {
        assert(store.fsync_done_at != null);
        store.fsync_done_at = null;
        const batch = store.batch[0..store.batch_len];
        store.batch_len = 0;
        if (bug_ack_before_fsync) return batch[0..0];
        for (batch) |r| store.table[r.key] = r;
        return batch;
    }

    /// Rebuild the store from durable bytes. Replays records from offset 0 and stops at the first
    /// one that is not valid. Fills `out` with the replayed records, in order.
    fn recover(gpa: std.mem.Allocator, disk: *const Disk, out: *std.ArrayList(Record)) !Store {
        assert(disk.cache.items.len == 0); // a crash empties the cache
        var store: Store = .{};
        out.clearRetainingCapacity();
        // Each iteration replays one record or yields why the replay stops.
        store.stop = while (true) {
            if (store.log_end + sector_size > disk.durable.len) break "end of disk";
            var buffer: [record_size_max]u8 = undefined;
            disk.read(store.log_end, buffer[0..sector_size]);
            const h = decode_header(buffer[0..header_size]);
            // Validate what can be checked without trusting `len` too far.
            if (h.seq != store.next_seq) break "unexpected seq (never written, or header sector lost)";
            if (h.len == 0 or h.len > value_max or h.key >= key_count) break "bad len/key";
            const size = Record.sectors(h.len) * sector_size;
            if (store.log_end + size > disk.durable.len) break "record past end of disk";
            disk.read(store.log_end, buffer[0..size]);
            if (!bug_no_checksum) {
                // The checksum proves every byte of the record was written by the same append.
                // A torn record (new header, stale payload) fails here.
                if (!checksum_ok(&buffer, h)) break "checksum mismatch (TORN record)";
                // The hash chain rejects a stale but intact record left behind by an earlier
                // life of the log, whose seq happens to be the next one expected.
                if (h.parent != store.last_checksum) break "parent mismatch (stale record from an earlier life)";
            }
            // BUG (--bug-no-checksum): seq, key and len look fine, so the header is trusted and
            // whatever bytes sit in the payload sectors are replayed as the value.
            var r: Record = .{ .seq = h.seq, .key = h.key, .len = h.len, .value = undefined };
            @memcpy(r.value[0..h.len], buffer[header_size..][0..h.len]);
            try out.append(gpa, r);
            store.table[h.key] = r;
            store.last_checksum = h.checksum;
            store.next_seq += 1;
            store.log_end += size;
        };
        return store;
    }
};

// ---------------------------------------------------------------------------------------------
// Simulator and oracle.

const Result = struct { ok: bool, trace_hash: u64, crashes: u32, acked: usize };

fn fail(verbose: bool, comptime fmt: []const u8, args: anytype) void {
    if (verbose) std.debug.print("  INVARIANT VIOLATED: " ++ fmt ++ "\n", args);
}

/// Check the recovered log against the oracle. Runs after EVERY restart, i.e. many times per seed.
/// On success, in-flight records that made it to disk become part of the oracle's history: the
/// client never got an ack, but the put did happen ("maybe committed" is a legal outcome).
fn check_recovery(
    gpa: std.mem.Allocator,
    verbose: bool,
    acked: *std.ArrayList(Record),
    in_flight: []const Record,
    recovered: []const Record,
    store: *const Store,
) !bool {
    // (1) Durability: every acked put is there, unchanged, in order.
    for (acked.items, 0..) |*want, i| {
        if (i >= recovered.len) {
            fail(verbose, "durability: acked put seq={d} key={d} was lost ({d} acked, {d} recovered)", .{
                want.seq, want.key, acked.items.len, recovered.len,
            });
            return false;
        }
        if (!want.eql(&recovered[i])) {
            fail(verbose, "durability: acked put seq={d} came back with different contents", .{want.seq});
            return false;
        }
    }
    // (2)+(3) Anything after the acked prefix must be a prefix of the in-flight puts, byte for byte.
    const extra = recovered[acked.items.len..];
    for (extra, 0..) |*got, j| {
        if (j >= in_flight.len or !got.eql(&in_flight[j])) {
            fail(verbose, "garbage: recovered seq={d} key={d} len={d} was never written by the client", .{
                got.seq, got.key, got.len,
            });
            return false;
        }
    }
    try acked.appendSlice(gpa, extra);
    // (3) The key-value table must equal a replay of the oracle's history.
    var want_table: [key_count]?*const Record = @splat(null);
    for (acked.items) |*r| want_table[r.key] = r;
    for (0..key_count) |k| {
        const want = want_table[k];
        const got = store.table[k];
        const same = if (want == null) got == null else (got != null and want.?.eql(&got.?));
        if (!same) {
            fail(verbose, "state: key={d} differs from the oracle after recovery", .{k});
            return false;
        }
    }
    return true;
}

/// `--sectors`: sector-level view of one crash and the recovery that followed. Sector numbers are
/// 64-byte units; `seq=S@N+K` means record S occupies sectors N..N+K-1.
fn print_sectors(
    disk: *const Disk,
    before: *const Store,
    after: *const Store,
    recovered: []const Record,
) void {
    const p = std.debug.print;
    // The batch appended since the last fsync sits back to back, ending at the old log_end.
    var offset = before.log_end;
    for (before.batch[0..before.batch_len]) |*r| offset -= Record.sectors(r.len) * sector_size;
    p("  | unsynced (keep {d}%):", .{disk.last_crash.keep_percent});
    for (before.batch[0..before.batch_len]) |*r| {
        const n = Record.sectors(r.len);
        p(" seq={d}@{d}+{d}", .{ r.seq, offset / sector_size, n });
        offset += n * sector_size;
    }
    p("\n  | cache:", .{});
    for (disk.last_crash.sectors[0..disk.last_crash.len]) |c| p(" {d}={s}", .{ c.sector, if (c.applied) "kept" else "dropped" });
    // The last few replayed records, each re-checked against its checksum on disk.
    p("\n  | scan: {d} records in sectors [0,{d}); last:", .{ recovered.len, after.log_end / sector_size });
    var buffer: [record_size_max]u8 = undefined;
    offset = 0;
    for (recovered, 0..) |*r, i| {
        const size = Record.sectors(r.len) * sector_size;
        if (i + 4 >= recovered.len) {
            disk.read(offset, buffer[0..size]);
            const ok = checksum_ok(&buffer, decode_header(buffer[0..header_size]));
            p(" seq={d}@{d}+{d}:{s}", .{ r.seq, offset / sector_size, size / sector_size, if (ok) "crc_ok" else "crc_BAD" });
        }
        offset += size;
    }
    // The record the scan stopped at, field by field.
    p("\n  | stop @{d}:", .{after.log_end / sector_size});
    if (after.log_end + sector_size <= disk.durable.len) {
        disk.read(after.log_end, buffer[0..sector_size]);
        const h = decode_header(buffer[0..header_size]);
        p(" seq={d} want={d} key={d} len={d}", .{ h.seq, after.next_seq, h.key, h.len });
        const size = Record.sectors(h.len) * sector_size;
        if (h.len > 0 and h.len <= value_max and after.log_end + size <= disk.durable.len) {
            disk.read(after.log_end, buffer[0..size]);
            p(" checksum={x:0>16} computed={x:0>16} parent={x:0>16} want={x:0>16}", .{
                h.checksum, record_checksum(buffer[8 .. header_size + h.len]), h.parent, after.last_checksum,
            });
        }
        p("\n  | bytes:", .{});
        for (buffer[0..header_size]) |b| p(" {x:0>2}", .{b});
    }
    p("\n  | high water: sector {d}\n", .{disk.high_water / sector_size});
}

fn run_seed(gpa: std.mem.Allocator, seed: u64, verbose: bool) !Result {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    // Sub-seed for the disk so that disk faults and workload are independent streams.
    var disk_prng = std.Random.DefaultPrng.init(random.int(u64));
    trace = std.hash.Wyhash.init(0);

    const durable = try gpa.alloc(u8, sector_count * sector_size);
    defer gpa.free(durable);
    random.bytes(durable); // never-written sectors hold noise
    var disk: Disk = .{ .durable = durable, .random = disk_prng.random() };
    defer disk.cache.deinit(gpa);

    // Oracle: what the client knows. `acked` = history that must survive; `in_flight` = puts
    // sent but not acked yet, which may or may not survive a crash.
    var acked: std.ArrayList(Record) = .empty;
    defer acked.deinit(gpa);
    var in_flight: std.ArrayList(Record) = .empty;
    defer in_flight.deinit(gpa);
    var recovered: std.ArrayList(Record) = .empty;
    defer recovered.deinit(gpa);

    var store: Store = .{};
    var crashes: u32 = 0;
    var tick: u64 = 0;
    var ok = true;

    while (tick < ticks_per_seed) : (tick += 1) {
        disk.tick();

        // A crash can land anywhere: between append and fsync, during fsync, right after an ack.
        if (random.uintLessThan(u32, crash_one_in) == 0) {
            crashes += 1;
            const before: ?Store = if (verbose and verbose_sectors) store else null;
            const c = disk.crash();
            event('C', c.applied, c.dropped);
            store = try Store.recover(gpa, &disk, &recovered);
            event('R', recovered.items.len, store.log_end);
            if (verbose) std.debug.print(
                "tick {d:>4}: crash #{d}: cache sectors applied={d} dropped={d}; " ++
                    "recovered {d} records (acked {d}, in-flight {d}); stop: {s}\n",
                .{
                    tick,                crashes,         c.applied,           c.dropped,
                    recovered.items.len, acked.items.len, in_flight.items.len, store.stop,
                },
            );
            if (before) |*b| print_sectors(&disk, b, &store, recovered.items);
            if (!try check_recovery(gpa, verbose, &acked, in_flight.items, recovered.items, &store)) {
                ok = false;
                break;
            }
            in_flight.clearRetainingCapacity();
            continue;
        }

        if (store.fsync_done_at) |done_at| {
            if (tick >= done_at) {
                disk.fsync();
                const now_acked = store.on_fsync();
                event('F', now_acked.len, tick);
                for (now_acked) |*r| {
                    // The client receives the ack. Oracle: this put must now survive any crash.
                    assert(in_flight.items.len > 0 and in_flight.items[0].eql(r));
                    try acked.append(gpa, in_flight.orderedRemove(0));
                    event('A', r.seq, 0);
                }
                // In-simulation check: an acked value is readable right away (the newest put
                // per key wins when one batch writes the same key twice).
                for (now_acked, 0..) |*r, i| {
                    const newest = for (now_acked[i + 1 ..]) |*later| {
                        if (later.key == r.key) break false;
                    } else true;
                    if (newest) assert(store.table[r.key].?.eql(r));
                }
                // Disk check: fsync means nothing is volatile any more.
                assert(disk.cache.items.len == 0);
            }
            continue;
        }

        const roll = random.uintLessThan(u8, 100);
        if (roll < 60 and store.batch_len < batch_max and !store.full()) {
            var r: Record = .{
                .seq = store.next_seq,
                .key = random.uintLessThan(u8, key_count),
                .len = 1 + random.uintLessThan(u8, value_max),
                .value = undefined,
            };
            random.bytes(r.value[0..r.len]);
            event('P', r.seq, r.len);
            const acked_now = try store.put(gpa, &disk, r);
            if (acked_now) {
                try acked.append(gpa, r);
                event('A', r.seq, 1);
                assert(store.table[r.key].?.eql(&r));
            } else {
                try in_flight.append(gpa, r);
            }
        } else if (store.batch_len > 0) {
            store.fsync_done_at = tick + 1 + random.uintLessThan(u64, fsync_latency_max);
            event('S', store.batch_len, store.fsync_done_at.?);
        }
    }
    event('E', acked.items.len, crashes);
    return .{ .ok = ok, .trace_hash = trace.final(), .crashes = crashes, .acked = acked.items.len };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse "sweep";
    const n = try std.fmt.parseInt(u64, args.next() orelse "2000", 10);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bug-ack-before-fsync")) {
            bug_ack_before_fsync = true;
        } else if (std.mem.eql(u8, arg, "--bug-no-checksum")) {
            bug_no_checksum = true;
        } else if (std.mem.eql(u8, arg, "--sectors")) {
            verbose_sectors = true;
        } else {
            std.debug.print("unknown flag: {s}\n", .{arg});
            std.process.exit(2);
        }
    }
    if (std.mem.eql(u8, mode, "run")) {
        const r = try run_seed(gpa, n, true);
        std.debug.print("seed={d} crashes={d} acked={d} trace={x:0>16} {s}\n", .{
            n, r.crashes, r.acked, r.trace_hash, if (r.ok) "PASS" else "FAIL",
        });
        if (!r.ok) std.process.exit(1);
        return;
    }

    var seed: u64 = 0;
    while (seed < n) : (seed += 1) {
        const r = try run_seed(gpa, seed, false);
        if (!r.ok) {
            std.debug.print("FAIL at seed={d} after {d} seeds. Replay with:\n", .{ seed, seed + 1 });
            std.debug.print("  zig run main.zig -- run {d}{s}{s}\n", .{
                seed,
                if (bug_ack_before_fsync) " --bug-ack-before-fsync" else "",
                if (bug_no_checksum) " --bug-no-checksum" else "",
            });
            std.process.exit(1);
        }
    }
    std.debug.print("PASS: {d} seeds\n", .{n});
}
