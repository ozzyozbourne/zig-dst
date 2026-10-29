//! Example 14 — Rare bugs and BUGGIFY: making rare paths common.
//!
//! System under test: a client-side *batching writer*. An application appends numbered records;
//! the writer buffers them and flushes batches over a (simulated) network connection to a
//! server, which stores each record at its position in a (simulated) file with a positional
//! write: record `seq` belongs at offset `seq`. Retrying a positional write is idempotent, so
//! the writer can retry freely, as long as it sends the right records to the right offset.
//!
//! The error-handling paths that rarely run in production (and in a plain random simulation):
//!   1. short write + retry: the disk persists only the first k records of a batch; the server
//!      acks `written = k`, the writer drops those k records and retries the rest;
//!   2. timeout while a flush is in progress: no ack within `timeout_ticks`, so the writer
//!      resends the batch it is flushing;
//!   3. buffer full while a reconnect is pending: the connection was reset, the writer waits for
//!      its reconnect backoff, the app keeps appending, the buffer fills, and the app must block
//!      (backpressure) instead of dropping or overwriting records.
//!
//! Planted bug (--bug-stale-offset): after a short write the writer shrinks `flush.count` but
//! forgets to advance `flush.offset`. The retry itself is correct (it sends from `base`), so a
//! short write alone is harmless. Only the TIMEOUT path reads `flush.offset`. If the retry after a
//! short write then times out (rare path 1 followed by rare path 2), the writer resends the
//! remaining records to the old offset and overwrites earlier records in the file.
//!
//! With realistic fault rates that combination is very rare: the sweep needs tens to hundreds of
//! thousands of seeds to find it. With --buggify, FoundationDB-style BUGGIFY points in the
//! production code (server write path, writer timeout, connection handling, buffer knobs) are
//! enabled per seed: each point is ACTIVE for a seed with probability 1/4, and each time an
//! active point is reached it FIRES with probability 1/4. The same bug then falls within ~100 seeds.
//!
//! Second lesson, seed stability: --extra-draw adds one PRNG draw at startup (as if Options got a
//! new field). Every sub-seed shifts, so the old failing seed now runs a different scenario. A
//! failing seed is not a regression test; `scenario` mode is: it replays a fixed, hand-written
//! event list without any PRNG, like TigerBeetle's src/vsr/replica_test.zig.
//!
//! Checked DURING the simulation:
//!   - every disk write: the record stored at offset p has seq p (no misplaced or lost records);
//!   - every ack: the writer never considers a record durable that is not in the file's
//!     contiguous written prefix;
//! and at the end (liveness): every appended record is durable within `ticks_max` ticks.
//!
//! Usage:
//!   zig run main.zig -- run      <seed>  [--bug-stale-offset] [--buggify] [--extra-draw]
//!   zig run main.zig -- sweep    <count> [--bug-stale-offset] [--buggify] [--extra-draw] [--start <seed>]
//!   zig run main.zig -- scenario         [--bug-stale-offset]
const std = @import("std");
const assert = std.debug.assert;

var bug_stale_offset = false;
var buggify_enabled = false;
var extra_draw = false;

const records_max = 32;
const batch_max_limit = 8;
const buffer_max = 16;
const msgs_max = 32;
/// The writer resends a flush that has not been acked after this many ticks.
const timeout_ticks = 12;
/// BUGGIFY(tiny_timeout): like FoundationDB's knob buggification
/// (`if (randomize && BUGGIFY) DD_SHARD_METRICS_TIMEOUT = 0.1;`), a timeout shorter than a
/// round trip makes "timeout while a flush is in progress" an everyday event.
const timeout_ticks_buggified = 2;
/// Liveness bound: all records must be durable by then.
const ticks_max = 4000;
const empty: u32 = std.math.maxInt(u32);

const Ratio = struct { num: u32, den: u32 };

fn chance(prng: *std.Random.DefaultPrng, r: Ratio) bool {
    return prng.random().uintLessThan(u32, r.den) < r.num;
}

// Realistic fault rates of the simulated environment (the same in every seed). These are the
// rates you might measure in production: each error path runs in a few seeds per thousand (or
// fewer), and the bug's COMBINATION of two paths in roughly one seed per hundred thousand.
const short_write_rate: Ratio = .{ .num = 1, .den = 3000 }; // per disk write with >1 record
const loss_rate: Ratio = .{ .num = 1, .den = 1500 }; // per message
const spike_rate: Ratio = .{ .num = 1, .den = 1500 }; // per message: delay 15..40 ticks
const reset_rate: Ratio = .{ .num = 1, .den = 2000 }; // per request sent: connection reset

/// The workload and timing of one seed (drawn from the root PRNG).
const Options = struct {
    records: u32, // records the app appends
    append_gap_max: u32, // ticks between appends: uniform 1..max
    batch_max: u8, // records per flush
    capacity: u8, // buffer capacity (records not yet durable)
    linger: u32, // ticks a non-full batch waits before flushing
    delay_max: u32, // one-way network delay: uniform 1..max

    fn generate(random: std.Random) Options {
        return .{
            .records = random.intRangeAtMost(u32, 16, records_max),
            .append_gap_max = random.intRangeAtMost(u32, 1, 6),
            .batch_max = random.intRangeAtMost(u8, 2, batch_max_limit),
            .capacity = random.intRangeAtMost(u8, batch_max_limit, buffer_max),
            .linger = random.intRangeAtMost(u32, 0, 4),
            .delay_max = random.intRangeAtMost(u32, 1, 4),
        };
    }
};

// ---------------------------------------------------------------------------------------------
// BUGGIFY
// ---------------------------------------------------------------------------------------------

/// The fault points compiled into the production code below. In FoundationDB each point is a
/// `BUGGIFY` macro keyed by __FILE__/__LINE__; here each point is an enum value.
const Point = enum(u8) {
    short_write, // server write path: persist only a prefix of the batch
    tiny_timeout, // writer: arm a 2-tick flush timeout instead of 12
    delay_ack, // server reply path: send the ack 10..20 ticks late
    drop_connection, // writer send path: the connection resets
    small_buffer, // writer knob: buffer capacity = one batch
    slow_reconnect, // writer: reconnect backoff x5
};
const point_count = std.enums.values(Point).len;

/// The rare paths whose frequency we measure.
const Path = enum(u8) {
    short_write_retry,
    timeout_in_flush,
    full_while_reconnect,
    short_retry_then_timeout, // path 1 followed by path 2 on the same flush: the bug's trigger
};
const path_count = std.enums.values(Path).len;

const Stats = struct {
    hits: [path_count]u64 = @splat(0),
    seeds: [path_count]u64 = @splat(0),
    fired: [point_count]u64 = @splat(0),
    active: [point_count]u64 = @splat(0),
};

// ---------------------------------------------------------------------------------------------
// Simulator state
// ---------------------------------------------------------------------------------------------

/// The flush the writer is waiting on. `offset` is the file offset `records` go to.
const Flush = struct { id: u32, offset: u32, count: u8, deadline: u64, after_short: bool };

const MsgKind = enum(u8) { request, ack };
const Msg = struct {
    deliver_at: u64 = 0, // set by `net_send`
    epoch: u32, // connection incarnation; a reset kills all messages of the old one
    kind: MsgKind,
    id: u32,
    offset: u32,
    count: u8,
    written: u8,
    records: [batch_max_limit]u32,
};

const SendKind = enum(u8) { first, retry, resend };

const Ev = enum(u8) {
    append,
    full,
    send,
    lost,
    reset,
    reconnect,
    write,
    ack,
    short_ack,
    stale_ack,
    timeout,
    buggify,
    corrupt,
    done,
};

const Failure = enum { none, corruption, durability, liveness, expectation };

const Result = struct { failure: Failure, trace: u64, ticks: u64 };

const Sim = struct {
    options: Options,
    verbose: bool,
    /// Scenario mode: the environment follows a hand-written script; no PRNG is used at all.
    scripted: bool,
    app_prng: std.Random.DefaultPrng,
    net_prng: std.Random.DefaultPrng,
    disk_prng: std.Random.DefaultPrng,
    /// BUGGIFY has its own stream, so turning --buggify on does not shift the other streams:
    /// `run S` and `run S --buggify` share the workload and differ only where a point fires.
    bug_prng: std.Random.DefaultPrng,
    tick: u64 = 0,
    trace: std.hash.Wyhash = std.hash.Wyhash.init(0),
    active: [point_count]bool = @splat(false),
    fired: [point_count]u32 = @splat(0),
    hits: [path_count]u32 = @splat(0),
    failure: Failure = .none,

    // Scenario knobs (scripted mode only).
    script_short_next: u8 = 0, // the next disk write persists only this many records (0 = all)
    script_drop_acks: u32 = 0, // drop this many of the next acks

    // The application.
    appended: u32 = 0,
    next_append_at: u64 = 0,
    blocked: bool = false,

    // The writer (production code). Invariant: buf[0..buf_len] holds seqs base..base+buf_len-1,
    // and every record below `base` is durable.
    buf: [buffer_max]u32 = undefined,
    buf_len: u8 = 0,
    base: u32 = 0,
    capacity: u8,
    flush: ?Flush = null,
    next_id: u32 = 1,
    conn_up: bool = true,
    epoch: u32 = 0,
    reconnect_at: u64 = 0,
    linger_until: u64 = 0,

    // The network: an ordered list of in-flight messages.
    msgs: [msgs_max]Msg = undefined,
    msgs_len: u8 = 0,

    // The server's file. disk[p] = seq stored at offset p.
    disk: [records_max]u32 = @splat(empty),
    contiguous: u32 = 0,

    fn init(seed: u64, verbose: bool) Sim {
        var root = std.Random.DefaultPrng.init(seed);
        const random = root.random();
        // --extra-draw: one more draw than before, as if someone added a field to Options. Every
        // value drawn after it, including every sub-seed, shifts.
        if (extra_draw) _ = random.int(u64);
        const options = Options.generate(random);
        var sim: Sim = .{
            .options = options,
            .verbose = verbose,
            .scripted = false,
            .capacity = options.capacity,
            .app_prng = std.Random.DefaultPrng.init(random.int(u64)),
            .net_prng = std.Random.DefaultPrng.init(random.int(u64)),
            .disk_prng = std.Random.DefaultPrng.init(random.int(u64)),
            .bug_prng = std.Random.DefaultPrng.init(random.int(u64)),
        };
        // Per-seed activation, decided once (FoundationDB decides on first evaluation of each
        // BUGGIFY line and caches it for the run; deciding up front is equivalent and simpler).
        if (buggify_enabled) for (&sim.active) |*a| {
            a.* = sim.bug_prng.random().uintLessThan(u32, 4) == 0;
        };
        sim.hash_options();
        return sim;
    }

    fn init_scripted(options: Options, verbose: bool) Sim {
        var sim: Sim = .{
            .options = options,
            .verbose = verbose,
            .scripted = true,
            .capacity = options.capacity,
            .app_prng = std.Random.DefaultPrng.init(0),
            .net_prng = std.Random.DefaultPrng.init(0),
            .disk_prng = std.Random.DefaultPrng.init(0),
            .bug_prng = std.Random.DefaultPrng.init(0),
        };
        sim.hash_options();
        return sim;
    }

    fn hash_options(sim: *Sim) void {
        const o = sim.options;
        sim.trace.update(std.mem.asBytes(&[_]u64{
            o.records, o.append_gap_max, o.batch_max, o.capacity, o.linger, o.delay_max,
        }));
        for (sim.active) |a| sim.trace.update(&.{@intFromBool(a)});
    }

    // ---- BUGGIFY ------------------------------------------------------------------------------

    /// `if (sim.buggify(.point))` is this example's BUGGIFY macro. Off unless --buggify; then
    /// true with probability 1/4 at points that are active for this seed.
    fn buggify(sim: *Sim, point: Point) bool {
        if (!buggify_enabled or !sim.active[@backingInt(point)]) return false;
        if (sim.bug_prng.random().uintLessThan(u32, 4) != 0) return false;
        sim.fired[@backingInt(point)] += 1;
        sim.event(.buggify, @backingInt(point), 0, 0);
        return true;
    }

    fn take_id(sim: *Sim) u32 {
        defer sim.next_id += 1;
        return sim.next_id;
    }

    fn hit(sim: *Sim, path: Path) void {
        sim.hits[@backingInt(path)] += 1;
    }

    // ---- The environment: simulated network and disk -----------------------------------------

    /// One-way delay of a message, or null if the network loses it.
    fn env_delay(sim: *Sim, kind: MsgKind) ?u64 {
        if (sim.scripted) {
            if (kind == .ack and sim.script_drop_acks > 0) {
                sim.script_drop_acks -= 1;
                return null;
            }
            return 1;
        }
        if (chance(&sim.net_prng, loss_rate)) return null;
        if (chance(&sim.net_prng, spike_rate)) return sim.net_prng.random().intRangeAtMost(u64, 15, 40);
        return sim.net_prng.random().intRangeAtMost(u64, 1, sim.options.delay_max);
    }

    /// How many of `count` records the disk persists. A short write is legal for write(2)/pwrite(2):
    /// the caller must retry the rest.
    fn env_write_len(sim: *Sim, count: u8) u8 {
        if (count < 2) return count;
        if (sim.scripted) {
            const n = sim.script_short_next;
            sim.script_short_next = 0;
            return if (n == 0) count else n;
        }
        if (!chance(&sim.disk_prng, short_write_rate)) return count;
        return sim.disk_prng.random().intRangeAtMost(u8, 1, count - 1);
    }

    fn env_reset(sim: *Sim) bool {
        if (sim.scripted) return false;
        return chance(&sim.net_prng, reset_rate);
    }

    fn env_backoff(sim: *Sim) u64 {
        if (sim.scripted) return 5;
        return sim.net_prng.random().intRangeAtMost(u64, 4, 20);
    }

    /// `extra` ticks are added to the network's delay.
    fn net_send(sim: *Sim, msg: Msg, extra: u64) void {
        var m = msg;
        const delay = sim.env_delay(m.kind) orelse {
            sim.event(.lost, m.id, @backingInt(m.kind), 0);
            return;
        };
        m.deliver_at = sim.tick + delay + extra;
        assert(sim.msgs_len < msgs_max);
        sim.msgs[sim.msgs_len] = m;
        sim.msgs_len += 1;
    }

    fn deliver(sim: *Sim) void {
        var i: usize = 0;
        while (i < sim.msgs_len) {
            if (sim.msgs[i].deliver_at > sim.tick) {
                i += 1;
                continue;
            }
            const m = sim.msgs[i];
            // Ordered removal: delivery order depends only on send order and delays.
            std.mem.copyForwards(Msg, sim.msgs[i .. sim.msgs_len - 1], sim.msgs[i + 1 .. sim.msgs_len]);
            sim.msgs_len -= 1;
            if (m.epoch != sim.epoch) continue; // sent on a connection that was reset since
            switch (m.kind) {
                .request => sim.server_on_request(&m),
                .ack => sim.writer_on_ack(&m),
            }
            if (sim.failure != .none) return;
        }
    }

    // ---- Production code: the server ----------------------------------------------------------

    fn server_on_request(sim: *Sim, m: *const Msg) void {
        var n = sim.env_write_len(m.count);
        // BUGGIFY in the server's write path: behave as if the OS returned a short write.
        if (n == m.count and m.count > 1 and sim.buggify(.short_write)) {
            n = sim.bug_prng.random().intRangeAtMost(u8, 1, m.count - 1);
        }
        for (0..n) |i| {
            const pos = m.offset + @as(u32, @intCast(i));
            assert(pos < records_max);
            sim.disk[pos] = m.records[i];
            // Invariant, checked on every write: offset p holds record p.
            if (m.records[i] != pos) {
                sim.event(.corrupt, pos, m.records[i], 0);
                std.debug.print("CORRUPTION: file offset {d} now holds record {d} (tick {d}, request #{d})\n", .{
                    pos, m.records[i], sim.tick, m.id,
                });
                sim.failure = .corruption;
                return;
            }
        }
        while (sim.contiguous < records_max and sim.disk[sim.contiguous] == sim.contiguous) sim.contiguous += 1;
        sim.event(.write, m.offset, n, m.count);

        // BUGGIFY in the reply path: a slow ack (GC pause, slow fsync, busy event loop).
        const extra: u64 = if (sim.buggify(.delay_ack)) sim.bug_prng.random().intRangeAtMost(u64, 10, 20) else 0;
        sim.net_send(.{
            .epoch = m.epoch,
            .kind = .ack,
            .id = m.id,
            .offset = m.offset,
            .count = m.count,
            .written = n,
            .records = undefined,
        }, extra);
    }

    // ---- Production code: the application and the batching writer -----------------------------

    fn app_tick(sim: *Sim) void {
        if (sim.scripted) return; // the script appends explicitly
        if (sim.appended == sim.options.records or sim.tick < sim.next_append_at) return;
        if (sim.app_append()) {
            sim.next_append_at = sim.tick + sim.app_prng.random().intRangeAtMost(u64, 1, sim.options.append_gap_max);
        }
    }

    /// Returns false if the buffer is full: the app blocks and tries again next tick.
    fn app_append(sim: *Sim) bool {
        assert(sim.appended == sim.base + sim.buf_len);
        if (sim.buf_len == sim.capacity) {
            // Backpressure. Rare path 3 when the connection is down: nothing can drain the
            // buffer until the reconnect backoff expires.
            if (!sim.blocked) {
                sim.blocked = true;
                if (!sim.conn_up) sim.hit(.full_while_reconnect);
                sim.event(.full, sim.capacity, @intFromBool(sim.conn_up), 0);
            }
            return false;
        }
        sim.blocked = false;
        if (sim.buf_len == 0) sim.linger_until = sim.tick + sim.options.linger;
        sim.buf[sim.buf_len] = sim.appended;
        sim.buf_len += 1;
        sim.appended += 1;
        sim.event(.append, sim.appended - 1, 0, 0);
        return true;
    }

    fn writer_tick(sim: *Sim) void {
        if (!sim.conn_up and sim.tick >= sim.reconnect_at) {
            sim.conn_up = true;
            sim.event(.reconnect, 0, 0, 0);
        }
        if (sim.flush) |*flush| {
            if (sim.tick < flush.deadline) return;
            // Rare path 2: the timeout fires while the flush is still in progress.
            sim.hit(.timeout_in_flush);
            if (flush.after_short) sim.hit(.short_retry_then_timeout);
            sim.event(.timeout, flush.id, 0, 0);
            flush.id = sim.take_id();
            // Resend the flush we are waiting on, to the offset recorded in it.
            sim.send_request(flush.offset, .resend);
            return;
        }
        if (!sim.conn_up or sim.buf_len == 0) return;
        if (sim.buf_len < sim.options.batch_max and sim.tick < sim.linger_until) return;
        sim.flush = .{
            .id = sim.take_id(),
            .offset = sim.base,
            .count = @min(sim.buf_len, sim.options.batch_max),
            .deadline = 0,
            .after_short = false,
        };
        sim.send_request(sim.base, .first);
    }

    /// Send buf[0..flush.count] to file offset `offset` and arm the flush timeout.
    fn send_request(sim: *Sim, offset: u32, kind: SendKind) void {
        const flush = &sim.flush.?;
        const timeout: u64 = if (sim.buggify(.tiny_timeout)) timeout_ticks_buggified else timeout_ticks;
        flush.deadline = sim.tick + timeout;
        sim.event(.send, flush.id, offset, @as(u64, flush.count) | @as(u64, @backingInt(kind)) << 8);
        if (sim.env_reset() or sim.buggify(.drop_connection)) {
            sim.connection_reset();
            return;
        }
        var m: Msg = .{
            .epoch = sim.epoch,
            .kind = .request,
            .id = flush.id,
            .offset = offset,
            .count = flush.count,
            .written = 0,
            .records = undefined,
        };
        @memcpy(m.records[0..flush.count], sim.buf[0..flush.count]);
        sim.net_send(m, 0);
    }

    fn connection_reset(sim: *Sim) void {
        sim.conn_up = false;
        sim.epoch += 1;
        var backoff = sim.env_backoff();
        if (sim.buggify(.slow_reconnect)) backoff *= 5;
        sim.reconnect_at = sim.tick + backoff;
        // In-flight requests and acks die with the connection. Records stay buffered and are
        // flushed again from `base` after the reconnect.
        sim.flush = null;
        sim.event(.reset, backoff, 0, 0);
    }

    fn writer_on_ack(sim: *Sim, m: *const Msg) void {
        if (sim.flush == null or m.id != sim.flush.?.id) {
            // No flush in progress, or an ack of an attempt we already gave up on (timed out).
            // Ignoring it is safe: the current attempt covers the same records.
            sim.event(.stale_ack, m.id, m.written, 0);
            return;
        }
        const flush = &sim.flush.?;
        const written = m.written;
        assert(written >= 1 and written <= flush.count);
        // Records [base, base + written) are durable: drop them and free buffer space.
        std.mem.copyForwards(u32, sim.buf[0 .. sim.buf_len - written], sim.buf[written..sim.buf_len]);
        sim.buf_len -= written;
        sim.base += written;
        // Invariant, checked on every ack: never consider durable what is not in the file.
        if (sim.base > sim.contiguous) {
            std.debug.print("DURABILITY: writer says {d} records durable, file has {d} (tick {d})\n", .{
                sim.base, sim.contiguous, sim.tick,
            });
            sim.failure = .durability;
            return;
        }
        if (written == flush.count) {
            sim.flush = null;
            sim.event(.ack, m.id, written, 0);
            return;
        }
        // Rare path 1: a short write. Retry the rest of the batch.
        sim.hit(.short_write_retry);
        sim.event(.short_ack, m.id, written, flush.count);
        flush.count -= written;
        // THE BUG: the offset is not advanced. The retry below does not notice (it sends from
        // `base`); only the timeout path in writer_tick reads flush.offset.
        if (!bug_stale_offset) flush.offset += written;
        flush.after_short = true;
        flush.id = sim.take_id();
        sim.send_request(sim.base, .retry);
    }

    fn done(sim: *const Sim) bool {
        return sim.appended == sim.options.records and sim.base == sim.options.records and sim.flush == null;
    }

    fn step(sim: *Sim) void {
        sim.app_tick();
        sim.deliver();
        if (sim.failure != .none) return;
        sim.writer_tick();
    }

    fn run(sim: *Sim) Failure {
        // BUGGIFY at a knob: a buffer only one batch large makes "buffer full" common.
        if (sim.buggify(.small_buffer)) sim.capacity = sim.options.batch_max;
        while (sim.failure == .none) : (sim.tick += 1) {
            if (sim.tick >= ticks_max) {
                std.debug.print("LIVENESS: only {d} of {d} records durable after {d} ticks\n", .{
                    sim.base, sim.options.records, ticks_max,
                });
                return .liveness;
            }
            sim.step();
            if (sim.failure == .none and sim.done()) {
                for (0..sim.options.records) |p| assert(sim.disk[p] == p);
                sim.event(.done, sim.base, 0, 0);
                return .none;
            }
        }
        return sim.failure;
    }

    // ---- Trace and event log ------------------------------------------------------------------
    //
    //   tick event      detail                       | writer and world state AFTER the event
    //   base=  records below this are durable (writer's view)
    //   buf=   seqs buffered in the writer, cap= its capacity
    //   flush= #id@offset+count dl=deadline, or "-"
    //   conn=  up, or rc@T (reconnect at tick T)
    //   net=   in-flight messages: qN = request #N, aN = ack #N
    //   disk=  one char per file offset: '.' empty, digit = seq mod 10 at the right offset

    fn event(sim: *Sim, ev: Ev, a: u64, b: u64, c: u64) void {
        sim.trace.update(std.mem.asBytes(&[_]u64{ sim.tick, @backingInt(ev), a, b, c }));
        if (sim.verbose) sim.print_event(ev, a, b, c);
    }

    fn print_event(sim: *Sim, ev: Ev, a: u64, b: u64, c: u64) void {
        var detail_buf: [64]u8 = undefined;
        const detail = switch (ev) {
            .append => std.fmt.bufPrint(&detail_buf, "seq={d}", .{a}),
            .full => std.fmt.bufPrint(&detail_buf, "buffer full ({d}): app blocks", .{a}),
            .send => std.fmt.bufPrint(&detail_buf, "#{d} off={d} n={d} {s}", .{
                a, b, c & 0xff, @tagName(@as(SendKind, @fromBackingInt(@intCast(c >> 8)))),
            }),
            .lost => std.fmt.bufPrint(&detail_buf, "{s} #{d} lost", .{
                if (b == 0) "request" else "ack", a,
            }),
            .reset => std.fmt.bufPrint(&detail_buf, "connection reset, backoff={d}", .{a}),
            .reconnect => std.fmt.bufPrint(&detail_buf, "connected", .{}),
            .write => std.fmt.bufPrint(&detail_buf, "off={d} wrote {d}/{d}{s}", .{
                a, b, c, if (b < c) " SHORT" else "",
            }),
            .ack => std.fmt.bufPrint(&detail_buf, "#{d} written={d}", .{ a, b }),
            .short_ack => std.fmt.bufPrint(&detail_buf, "#{d} written={d} of {d}", .{ a, b, c }),
            .stale_ack => std.fmt.bufPrint(&detail_buf, "#{d} written={d} ignored", .{ a, b }),
            .timeout => std.fmt.bufPrint(&detail_buf, "#{d} not acked", .{a}),
            .buggify => std.fmt.bufPrint(&detail_buf, "{s}", .{@tagName(@as(Point, @fromBackingInt(@intCast(a))))}),
            .corrupt => std.fmt.bufPrint(&detail_buf, "offset {d} <- record {d}", .{ a, b }),
            .done => std.fmt.bufPrint(&detail_buf, "{d} records durable", .{a}),
        } catch unreachable;

        var buf_text: [24]u8 = undefined;
        const buf_s = if (sim.buf_len == 0)
            "-"
        else
            std.fmt.bufPrint(&buf_text, "{d}..{d}", .{ sim.base, sim.base + sim.buf_len - 1 }) catch unreachable;

        var flush_text: [48]u8 = undefined;
        const flush_s = if (sim.flush) |f|
            std.fmt.bufPrint(&flush_text, "#{d}@{d}+{d} dl={d}", .{ f.id, f.offset, f.count, f.deadline }) catch unreachable
        else
            "-";

        var conn_text: [24]u8 = undefined;
        const conn_s = if (sim.conn_up)
            "up"
        else
            std.fmt.bufPrint(&conn_text, "rc@{d}", .{sim.reconnect_at}) catch unreachable;

        var net_text: [msgs_max * 6]u8 = undefined;
        var net_len: usize = 0;
        for (sim.msgs[0..sim.msgs_len]) |m| {
            if (m.epoch != sim.epoch) continue;
            if (net_len > 0) {
                net_text[net_len] = ',';
                net_len += 1;
            }
            const s = std.fmt.bufPrint(net_text[net_len..], "{c}{d}", .{
                @as(u8, if (m.kind == .request) 'q' else 'a'), m.id,
            }) catch unreachable;
            net_len += s.len;
        }
        const net_s = if (net_len == 0) "-" else net_text[0..net_len];

        var disk_text: [records_max]u8 = undefined;
        for (0..sim.options.records) |p| {
            const v = sim.disk[p];
            disk_text[p] = if (v == empty) '.' else if (v == p) '0' + @as(u8, @intCast(v % 10)) else 'X';
        }

        std.debug.print("{d:>5} {s:<10} {s:<30} | base={d} buf={s} cap={d} flush={s} conn={s} net={s} disk={s}\n", .{
            sim.tick,                          @tagName(ev), detail, sim.base, buf_s, sim.capacity, flush_s, conn_s, net_s,
            disk_text[0..sim.options.records],
        });
    }

    fn print_paths(sim: *const Sim) void {
        std.debug.print("paths:", .{});
        for (sim.hits, std.enums.values(Path)) |h, path| std.debug.print(" {s}={d}", .{ @tagName(path), h });
        std.debug.print("\n", .{});
        if (!buggify_enabled) return;
        std.debug.print("buggify fired:", .{});
        for (sim.fired, sim.active, std.enums.values(Point)) |f, active, point| {
            if (active) std.debug.print(" {s}={d}", .{ @tagName(point), f });
        }
        std.debug.print("\n", .{});
    }
};

fn run_seed(seed: u64, verbose: bool, stats: ?*Stats) Result {
    var sim = Sim.init(seed, verbose);
    if (verbose) {
        const o = sim.options;
        std.debug.print(
            \\seed={d} records={d} append_gap=1..{d} batch_max={d} capacity={d} linger={d} delay=1..{d}
            \\  faults: short_write={d}/{d} per write, loss={d}/{d}, spike={d}/{d} (15..40 ticks), reset={d}/{d} per send, timeout={d} ticks
            \\
        , .{
            seed,          o.records,      o.append_gap_max,     o.batch_max,          o.capacity,
            o.linger,      o.delay_max,    short_write_rate.num, short_write_rate.den, loss_rate.num,
            loss_rate.den, spike_rate.num, spike_rate.den,       reset_rate.num,       reset_rate.den,
            timeout_ticks,
        });
        if (buggify_enabled) {
            std.debug.print("  buggify: active =", .{});
            var any = false;
            for (sim.active, std.enums.values(Point)) |a, point| if (a) {
                std.debug.print(" {s}", .{@tagName(point)});
                any = true;
            };
            std.debug.print("{s} (each fires with probability 1/4 when reached)\n", .{if (any) "" else " (none)"});
        } else std.debug.print("  buggify: off\n", .{});
        std.debug.print(" tick event      detail                         | state after the event\n", .{});
    }
    const failure = sim.run();
    if (verbose) sim.print_paths();
    if (stats) |st| {
        for (sim.hits, 0..) |h, i| {
            st.hits[i] += h;
            if (h > 0) st.seeds[i] += 1;
        }
        for (sim.fired, 0..) |f, i| st.fired[i] += f;
        for (sim.active, 0..) |a, i| st.active[i] += @intFromBool(a);
    }
    return .{ .failure = failure, .trace = sim.trace.final(), .ticks = sim.tick };
}

// ---------------------------------------------------------------------------------------------
// Scenario mode: the failure pinned as a hand-written test (no PRNG)
// ---------------------------------------------------------------------------------------------

/// Like the tests in TigerBeetle's src/vsr/replica_test.zig (`t.replica(.B2).drop_all(...)`,
/// `c.request(...)`, `t.run()`, `expectEqual(...)`), a scenario names each fault explicitly.
/// It does not depend on how anything consumes randomness, so it keeps testing the same
/// interleaving after the code (or the simulator) changes.
const Step = union(enum) {
    append: u32, // the app appends this many records now
    short_write_next: u8, // the next disk write persists only this many records
    drop_acks: u32, // the next N acks are lost on the network
    run: u32, // advance N ticks
    expect_durable: u32, // the writer must report exactly this many records durable
};

/// Every delay is 1 tick, batch_max = 4, linger = 0, so the timeline is exact:
///   t0 send #1 off=0 n=4 · t1 disk writes 2/4 (short) · t2 short ack → retry #2 off=2 n=2
///   t3 disk writes 2/2, its ack is dropped · t14 timeout → resend · t15 write · t16 ack.
const scenario_name = "short-write-then-timeout";
const scenario = [_]Step{
    .{ .append = 4 },
    .{ .short_write_next = 2 },
    .{ .run = 3 },
    .{ .drop_acks = 1 },
    .{ .run = 20 },
    .{ .expect_durable = 4 },
};

fn run_scenario() Result {
    var sim = Sim.init_scripted(.{
        .records = 4,
        .append_gap_max = 1,
        .batch_max = 4,
        .capacity = 8,
        .linger = 0,
        .delay_max = 1,
    }, true);
    std.debug.print("scenario {s}: no PRNG; every fault comes from the script\n", .{scenario_name});
    for (scenario) |s| {
        if (sim.failure != .none) break;
        switch (s) {
            .append => |n| {
                std.debug.print("  step: append {d}\n", .{n});
                for (0..n) |_| assert(sim.app_append());
            },
            .short_write_next => |n| {
                std.debug.print("  step: next disk write persists only {d} records\n", .{n});
                sim.script_short_next = n;
            },
            .drop_acks => |n| {
                std.debug.print("  step: drop the next {d} ack(s)\n", .{n});
                sim.script_drop_acks = n;
            },
            .run => |n| {
                std.debug.print("  step: run {d} ticks\n", .{n});
                for (0..n) |_| {
                    sim.step();
                    if (sim.failure != .none) break;
                    sim.tick += 1;
                }
            },
            .expect_durable => |n| {
                std.debug.print("  step: expect {d} records durable (writer base={d}, file prefix={d})\n", .{
                    n, sim.base, sim.contiguous,
                });
                if (sim.base != n or sim.contiguous != n) sim.failure = .expectation;
            },
        }
    }
    sim.print_paths();
    return .{ .failure = sim.failure, .trace = sim.trace.final(), .ticks = sim.tick };
}

// ---------------------------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse "sweep";
    const is_scenario = std.mem.eql(u8, mode, "scenario");
    var count: u64 = 2_000_000;
    var start: u64 = 0;
    var flags_buf: [96]u8 = undefined;
    var flags_len: usize = 0;
    var first = true;
    while (args.next()) |arg| {
        defer first = false;
        if (first and !is_scenario and arg.len > 0 and std.ascii.isDigit(arg[0])) {
            count = try std.fmt.parseInt(u64, arg, 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--bug-stale-offset")) {
            bug_stale_offset = true;
        } else if (std.mem.eql(u8, arg, "--buggify")) {
            buggify_enabled = true;
        } else if (std.mem.eql(u8, arg, "--extra-draw")) {
            extra_draw = true;
        } else if (std.mem.eql(u8, arg, "--start")) {
            start = try std.fmt.parseInt(u64, args.next() orelse "0", 10);
            continue;
        } else {
            std.debug.print("unknown flag: {s}\n", .{arg});
            std.process.exit(2);
        }
        flags_buf[flags_len] = ' ';
        @memcpy(flags_buf[flags_len + 1 ..][0..arg.len], arg);
        flags_len += 1 + arg.len;
    }
    const flags = flags_buf[0..flags_len];

    if (is_scenario) {
        const r = run_scenario();
        std.debug.print("scenario={s} ticks={d} trace={x:0>16} {s}\n", .{
            scenario_name, r.ticks, r.trace, if (r.failure == .none) "PASS" else "FAIL",
        });
        if (r.failure != .none) std.process.exit(1);
        return;
    }

    if (std.mem.eql(u8, mode, "run")) {
        const r = run_seed(count, true, null);
        std.debug.print("seed={d} ticks={d} trace={x:0>16} {s}\n", .{
            count, r.ticks, r.trace, if (r.failure == .none) "PASS" else "FAIL",
        });
        if (r.failure != .none) std.process.exit(1);
        return;
    }

    var stats: Stats = .{};
    var i: u64 = 0;
    var failed: ?struct { seed: u64, failure: Failure } = null;
    while (i < count) : (i += 1) {
        const seed = start + i;
        const r = run_seed(seed, false, &stats);
        if (r.failure != .none) {
            failed = .{ .seed = seed, .failure = r.failure };
            i += 1;
            break;
        }
    }
    // Rare-path frequencies over the seeds that ran: total hits, and seeds with at least one hit.
    for (stats.hits, stats.seeds, std.enums.values(Path)) |hits, seeds, path| {
        std.debug.print("path {s} hits={d} seeds={d} of={d}\n", .{
            @tagName(path), hits, seeds, i,
        });
    }
    if (buggify_enabled) for (stats.active, stats.fired, std.enums.values(Point)) |active, fired, point| {
        std.debug.print("buggify {s} active_seeds={d} fired={d} of={d}\n", .{
            @tagName(point), active, fired, i,
        });
    };
    if (failed) |f| {
        std.debug.print("FAIL at seed={d} ({s}) after {d} seeds. Replay with:\n", .{
            f.seed, @tagName(f.failure), i,
        });
        std.debug.print("  zig run main.zig -- run {d}{s}\n", .{ f.seed, flags });
        std.process.exit(1);
    }
    std.debug.print("PASS: {d} seeds (from seed {d})\n", .{ count, start });
}
