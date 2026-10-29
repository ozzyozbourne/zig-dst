//! Example 10 — Mini-VOPR: the capstone.
//!
//! Everything from the earlier examples, wired together the way TigerBeetle's VOPR
//! (src/vopr.zig) does it:
//!
//!   * a seeded PRNG that chooses a *swarm* of fault probabilities (printed as a SEED= block),
//!   * a simulated clock (a tick counter; timeouts are counted in ticks),
//!   * a packet simulator (loss, duplication, random delay => reordering, partitions),
//!   * simulated storage with a WAL whose writes complete asynchronously; a crash loses every
//!     write that has not completed yet ("unsynced writes lost"),
//!   * replicas that crash and restart from what is durable,
//!   * clients that retry with request numbers,
//!   * checkers that run on every commit and every reply, DURING the simulation,
//!   * a safety phase (all faults on) followed by a liveness phase (heal a random core quorum,
//!     then demand convergence within a bounded number of ticks).
//!
//! System under test: a miniature Viewstamped Replication (VSR) cluster of 3 or 5 replicas that
//! replicates a log of money transfers between 4 accounts.
//!
//!   normal:      client -request-> primary -prepare-> backups -prepare_ok-> primary
//!                primary commits op N after a replication quorum has the prepare DURABLE,
//!                replies to the client, and tells backups via `commit` heartbeats.
//!   view change: a backup that hears nothing from the primary for a while starts view v+1
//!                (start_view_change). With a quorum of SVCs, each replica persists the new view
//!                and sends do_view_change (its log) to the new primary, which picks the log with
//!                the highest (log_view, op), installs it, and broadcasts start_view.
//!   repair:      a backup that notices a gap asks the primary with get_view; it gets start_view.
//!
//! Usage:
//!   zig run main.zig -- run   <seed>  [--bug-commit-early] [--bug-view-change-log] [--events]
//!   zig run main.zig -- sweep <count> [--bug-commit-early] [--bug-view-change-log]
const std = @import("std");

const replicas_max = 5;
const clients_max = 4;
const nodes_max = replicas_max + clients_max;
const accounts = 4;
const balance_initial = 100;
const money_total: u64 = accounts * balance_initial;
const pipeline_max = 4; // Uncommitted prepares a primary may have in flight.
const heartbeat_ticks = 8; // Primary -> backups `commit` interval.
const client_timeout_ticks = 40;
const ticks_max_requests = 3_000; // Safety phase: give up after this many ticks without a reply.
const ticks_max_convergence = 5_000; // Liveness phase: the core must converge within this bound.

var bug_commit_early = false;
var bug_view_change_log = false;
/// `run <seed> --events`: also print one `@` line per packet send/drop/delivery, WAL write, and
/// commit (with checksums). Print-only: it consumes no randomness and is not hashed into the trace.
var trace_events = false;

// ------------------------------------------------------------------------------------------------
// Swarm options: the seed first picks HOW hostile this run is, then runs it. One seed may be a
// calm 3-replica cluster, the next a 5-replica cluster with 15% loss and frequent crashes.
// Different bugs need different weather; swarm testing covers more of it than one fixed setting.

const Ratio = struct {
    num: u32,
    den: u32,
    pub fn format(r: Ratio, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}/{d}", .{ r.num, r.den });
    }
};
fn chance(random: std.Random, r: Ratio) bool {
    return random.uintLessThan(u32, r.den) < r.num;
}

const PartitionMode = enum { isolate_single, uniform_split };

const Options = struct {
    replica_count: u8,
    client_count: u8,
    requests_per_client: u32,
    request_idle_max: u32,
    one_way_delay_min: u32,
    one_way_delay_max: u32,
    packet_loss: Ratio,
    packet_duplicate: Ratio,
    partition_mode: PartitionMode,
    partition_symmetric: bool,
    partition: Ratio,
    unpartition: Ratio,
    partition_stability: u32,
    unpartition_stability: u32,
    write_latency_min: u32,
    write_latency_max: u32,
    crash: Ratio,
    crash_stability: u32,
    restart: Ratio,
    restart_stability: u32,
};

fn options_swarm(random: std.Random) Options {
    var o: Options = undefined;
    o.replica_count = if (random.boolean()) 3 else 5;
    o.client_count = random.intRangeAtMost(u8, 1, clients_max);
    o.requests_per_client = random.intRangeAtMost(u32, 4, 15);
    o.request_idle_max = random.uintAtMost(u32, 30);
    o.one_way_delay_min = random.intRangeAtMost(u32, 1, 3);
    o.one_way_delay_max = o.one_way_delay_min + random.uintAtMost(u32, 15);
    o.packet_loss = .{ .num = random.uintAtMost(u32, 15), .den = 100 };
    o.packet_duplicate = .{ .num = random.uintAtMost(u32, 10), .den = 100 };
    o.partition_mode = random.enumValueWithIndex(PartitionMode, u8);
    o.partition_symmetric = random.boolean();
    o.partition = .{ .num = random.uintAtMost(u32, 30), .den = 10_000 };
    o.unpartition = .{ .num = random.intRangeAtMost(u32, 1, 20), .den = 1_000 };
    o.partition_stability = random.intRangeAtMost(u32, 50, 250);
    o.unpartition_stability = random.uintAtMost(u32, 50);
    o.write_latency_min = random.intRangeAtMost(u32, 1, 3);
    o.write_latency_max = o.write_latency_min + random.uintAtMost(u32, 10);
    o.crash = .{ .num = random.uintAtMost(u32, 20), .den = 100_000 };
    o.crash_stability = random.uintAtMost(u32, 300);
    o.restart = .{ .num = random.intRangeAtMost(u32, 5, 50), .den = 1_000 };
    o.restart_stability = random.uintAtMost(u32, 200);
    return o;
}

fn print_options(seed: u64, o: Options) void {
    std.debug.print(
        \\
        \\          SEED={d}
        \\
        \\          replicas={d}
        \\          clients={d}
        \\          requests_per_client={d}
        \\          request_idle_max={d} ticks
        \\          one_way_delay_min={d} ticks
        \\          one_way_delay_max={d} ticks
        \\          packet_loss_probability={f}
        \\          packet_duplicate_probability={f}
        \\          partition_mode={s}
        \\          partition_symmetry={s}
        \\          partition_probability={f}
        \\          unpartition_probability={f}
        \\          partition_stability={d} ticks
        \\          unpartition_stability={d} ticks
        \\          write_latency_min={d} ticks
        \\          write_latency_max={d} ticks
        \\          crash_probability={f} (x10 while writes are pending)
        \\          crash_stability={d} ticks
        \\          restart_probability={f}
        \\          restart_stability={d} ticks
        \\
        \\
    , .{
        seed,                       o.replica_count,                                          o.client_count,
        o.requests_per_client,      o.request_idle_max,                                       o.one_way_delay_min,
        o.one_way_delay_max,        o.packet_loss,                                            o.packet_duplicate,
        @tagName(o.partition_mode), if (o.partition_symmetric) "symmetric" else "asymmetric", o.partition,
        o.unpartition,              o.partition_stability,                                    o.unpartition_stability,
        o.write_latency_min,        o.write_latency_max,                                      o.crash,
        o.crash_stability,          o.restart,                                                o.restart_stability,
    });
}

// ------------------------------------------------------------------------------------------------
// The replicated state machine: 4 accounts, transfers, and a client session table for dedup.

const Transfer = struct { from: u8, to: u8, amount: u32 };
const Result = enum(u8) { ok, insufficient_funds, duplicate };

/// One log entry. `checksum` hash-chains over `parent`, so two logs that agree on the checksum
/// at op N agree on every op <= N (like TigerBeetle's header.parent chain).
const Entry = struct {
    op: u32,
    view: u32, // The view in which the entry was first prepared. Never rewritten.
    client: u8,
    request: u32,
    transfer: Transfer,
    parent: u64,
    checksum: u64,

    fn compute_checksum(e: Entry) u64 {
        var h = std.hash.Wyhash.init(0xC0FFEE);
        hash_ints(&h, .{ e.parent, e.op, e.view, e.client, e.request });
        hash_ints(&h, .{ e.transfer.from, e.transfer.to, e.transfer.amount });
        return h.final();
    }
};

/// Hash integers one by one (never `asBytes` a struct: padding bytes are undefined and would
/// make the trace hash nondeterministic).
fn hash_ints(h: *std.hash.Wyhash, values: anytype) void {
    inline for (values) |v| {
        const x: u64 = v;
        h.update(std.mem.asBytes(&x));
    }
}

const Session = struct { request: u32 = 0, op: u32 = 0, result: Result = .ok };

const StateMachine = struct {
    balances: [accounts]u64 = @splat(balance_initial),
    sessions: [clients_max]Session = @splat(.{}),

    fn apply(sm: *StateMachine, e: Entry) Result {
        const session = &sm.sessions[e.client];
        // A retried request that made it into the log twice is a no-op the second time.
        if (e.request <= session.request) return .duplicate;
        var result: Result = .ok;
        if (sm.balances[e.transfer.from] >= e.transfer.amount) {
            sm.balances[e.transfer.from] -= e.transfer.amount;
            sm.balances[e.transfer.to] += e.transfer.amount;
        } else result = .insufficient_funds;
        session.* = .{ .request = e.request, .op = e.op, .result = result };
        return result;
    }

    fn hash(sm: *const StateMachine) u64 {
        var h = std.hash.Wyhash.init(0);
        for (sm.balances) |b| hash_ints(&h, .{b});
        for (sm.sessions) |s| hash_ints(&h, .{ s.request, s.op, @backingInt(s.result) });
        return h.final();
    }

    fn money(sm: *const StateMachine) u64 {
        var sum: u64 = 0;
        for (sm.balances) |b| sum += b;
        return sum;
    }
};

// ------------------------------------------------------------------------------------------------
// Messages and the packet simulator.

const Command = enum(u8) {
    request,
    prepare,
    prepare_ok,
    commit, // normal protocol
    start_view_change,
    do_view_change,
    start_view,
    get_view, // view change and repair
    reply,
};

const Message = struct {
    command: Command,
    from: u8, // Node index: replicas are 0..replica_count, clients follow.
    view: u32 = 0,
    op: u32 = 0,
    commit: u32 = 0,
    log_view: u32 = 0,
    log: u32 = 0, // Index into Simulator.snapshots (do_view_change, start_view).
    entry: Entry = std.mem.zeroes(Entry), // prepare
    client: u8 = 0,
    request: u32 = 0,
    result: Result = .ok, // request, reply
    transfer: Transfer = .{ .from = 0, .to = 0, .amount = 0 },
};

const Packet = struct { deliver_at: u64, to: u8, message: Message };

// ------------------------------------------------------------------------------------------------
// Simulated storage. `log`/`view`/`log_view` are what survives a crash. `pending` holds writes the
// replica issued but the "disk" has not completed; they complete in FIFO order after a random
// latency. A crash throws `pending` away. The protocol rule this tests: never promise anything
// (prepare_ok, do_view_change) about state that is not yet durable.

const WriteKind = enum { append, install, view };
const Write = struct {
    done_at: u64 = 0,
    kind: WriteKind,
    view: u32,
    op: u32 = 0, // append: entry op; install: new log length.
    entry: Entry = std.mem.zeroes(Entry), // append
    log: u32 = 0, // install: snapshot index
};

const Storage = struct {
    view: u32 = 0,
    log_view: u32 = 0,
    log: std.ArrayList(Entry) = .empty, // durable WAL
    pending: std.ArrayList(Write) = .empty, // unsynced writes
};

// ------------------------------------------------------------------------------------------------
// Replicas and clients.

const Status = enum { normal, view_change };
const DoViewChange = struct { log_view: u32, op: u32, commit: u32, log: u32 };

const Replica = struct {
    up: bool = true,
    status: Status = .normal,
    view: u32 = 0,
    log_view: u32 = 0, // The latest view in which this log was installed as "normal".
    log: std.ArrayList(Entry) = .empty, // log.items[i].op == i + 1
    commit: u32 = 0,
    sm: StateMachine = .{},
    durable_op: u32 = 0, // Highest op known durable in the current view.
    acked: [replicas_max]u32 = @splat(0), // Primary: cumulative prepare_ok per replica.
    svc_votes: u8 = 0, // Bitset of start_view_change votes for `view`.
    dvc_persisting: bool = false,
    dvcs: [replicas_max]?DoViewChange = @splat(null),
    timeout: u32 = 50, // Primary: heartbeat countdown. Others: view-change countdown.
    get_view_after: u64 = 0, // Rate limit for repair requests.
    stability: u32 = 0, // Fault injector: ticks before the next crash/restart may happen.
};

const Client = struct {
    request_next: u32 = 1,
    inflight: ?Message = null,
    view_guess: u32 = 0,
    timeout: u32 = 0,
    idle: u32 = 0,
};

/// The canonical history (state checker): the first commit of op N by ANY replica defines op N.
const Commit = struct { checksum: u64, client: u8, request: u32, result: Result, state: u64 };

const Simulator = struct {
    gpa: std.mem.Allocator, // An arena, freed per seed.
    random: std.Random,
    options: Options,
    verbose: bool,
    now: u64 = 0,
    trace: std.hash.Wyhash = std.hash.Wyhash.init(0),
    replicas: [replicas_max]Replica = @splat(.{}),
    storages: [replicas_max]Storage = @splat(.{}),
    clients: [clients_max]Client = @splat(.{}),
    packets: std.ArrayList(Packet) = .empty,
    due: std.ArrayList(Packet) = .empty,
    snapshots: std.ArrayList([]const Entry) = .empty,
    partitioned: [nodes_max][nodes_max]bool = @splat(@splat(false)),
    partition_active: bool = false,
    partition_stability: u32 = 0,
    canonical: std.ArrayList(Commit) = .empty,
    requests_replied: u32 = 0,
    core: u8 = 0, // Bitset; 0 while in the safety phase.
    failure: ?[]const u8 = null,
    failure_buf: [256]u8 = undefined,

    fn n(sim: *const Simulator) u8 {
        return sim.options.replica_count;
    }
    fn quorum(sim: *const Simulator) u8 { // Majority: replication and view-change quorums.
        return sim.options.replica_count / 2 + 1;
    }
    fn primary_index(sim: *const Simulator, view: u32) u8 {
        return @intCast(view % sim.options.replica_count);
    }
    fn is_primary(sim: *const Simulator, r: u8) bool {
        const rep = &sim.replicas[r];
        return rep.status == .normal and sim.primary_index(rep.view) == r;
    }
    fn in_core(sim: *const Simulator, r: usize) bool {
        return sim.core & (@as(u8, 1) << @intCast(r)) != 0;
    }

    fn fail(sim: *Simulator, comptime fmt: []const u8, args: anytype) void {
        if (sim.failure != null) return;
        sim.failure = std.fmt.bufPrint(&sim.failure_buf, fmt, args) catch "failure (truncated)";
        if (sim.verbose) std.debug.print("{d:>6} FAIL: {s}\n", .{ sim.now, sim.failure.? });
    }

    fn snapshot(sim: *Simulator, r: u8) u32 {
        const copy = sim.gpa.dupe(Entry, sim.replicas[r].log.items) catch oom();
        sim.snapshots.append(sim.gpa, copy) catch oom();
        return @intCast(sim.snapshots.items.len - 1);
    }

    /// VOPR-style status line, one per replica event:
    ///   tick replica event role statuses  view commit/op log_view durable-WAL-ops pending-writes
    /// events: ' ' commit, '!' crash, '^' restart, 'v' view change, '/' became primary,
    ///         '>' installed start_view, '=' final state
    /// roles: '/' primary, '\' backup, '#' down.  statuses: '.' normal, 'v' view change, '#' down.
    fn log_replica(sim: *const Simulator, r: u8, event: u8) void {
        if (!sim.verbose) return;
        var statuses: [replicas_max]u8 = undefined;
        for (0..sim.n()) |i| {
            const x = &sim.replicas[i];
            statuses[i] = if (!x.up) '#' else if (x.status == .normal) '.' else 'v';
        }
        const rep = &sim.replicas[r];
        const st = &sim.storages[r];
        const role: u8 = if (!rep.up) '#' else if (sim.primary_index(rep.view) == r) '/' else '\\';
        std.debug.print("{d:>6} {d:>2} {c} {c} {s}  {d:>3}V {d:>3}/{d:_>3}C {d:>3}LV {d:>3}Wo {d:>2}W!\n", .{
            sim.now,              r,                event,                role,
            statuses[0..sim.n()], rep.view,         rep.commit,           rep.log.items.len,
            rep.log_view,         st.log.items.len, st.pending.items.len,
        });
    }

    /// `--events` only (see trace_events): prints, never hashes, never draws randomness.
    fn event_message(sim: *const Simulator, kind: []const u8, to: u8, m: Message, at: u64) void {
        if (!sim.verbose or !trace_events) return;
        const client, const request = if (m.command == .prepare) .{ m.entry.client, m.entry.request } else .{ m.client, m.request };
        std.debug.print("{d:>6} @{s} from={d} to={d} cmd={s} view={d} op={d} commit={d} client={d} request={d} at={d}\n", .{
            sim.now, kind, m.from, to, @tagName(m.command), m.view, m.op, m.commit, client, request, at,
        });
    }

    // ---- Network --------------------------------------------------------------------------

    fn send(sim: *Simulator, from: u8, to: u8, message: Message) void {
        var m = message;
        m.from = from;
        if (from == to) {
            sim.event_message("send", to, m, sim.now + 1);
            sim.packets.append(sim.gpa, .{ .deliver_at = sim.now + 1, .to = to, .message = m }) catch oom();
            return;
        }
        const o = &sim.options;
        if (sim.partitioned[from][to]) return sim.event_message("cut", to, m, sim.now);
        if (chance(sim.random, o.packet_loss)) return sim.event_message("lost", to, m, sim.now);
        const copies: u32 = if (chance(sim.random, o.packet_duplicate)) 2 else 1;
        for (0..copies) |_| {
            const delay = sim.random.intRangeAtMost(u32, o.one_way_delay_min, o.one_way_delay_max);
            sim.event_message("send", to, m, sim.now + delay);
            sim.packets.append(sim.gpa, .{ .deliver_at = sim.now + delay, .to = to, .message = m }) catch oom();
        }
    }

    fn broadcast(sim: *Simulator, from: u8, message: Message) void {
        for (0..sim.n()) |i| if (i != from) sim.send(from, @intCast(i), message);
    }

    fn tick_network(sim: *Simulator) void {
        sim.due.clearRetainingCapacity();
        var keep: usize = 0;
        for (sim.packets.items) |p| {
            if (p.deliver_at <= sim.now) {
                sim.due.append(sim.gpa, p) catch oom();
            } else {
                sim.packets.items[keep] = p;
                keep += 1;
            }
        }
        sim.packets.shrinkRetainingCapacity(keep);
        for (sim.due.items) |p| {
            if (sim.failure != null) return;
            const m = p.message;
            hash_ints(&sim.trace, .{ sim.now, p.to, m.from, @backingInt(m.command), m.view, m.op, m.commit });
            const down = p.to < sim.n() and !sim.replicas[p.to].up;
            sim.event_message(if (down) "drop" else "recv", p.to, m, sim.now);
            if (p.to < sim.n()) {
                if (sim.replicas[p.to].up) sim.on_message(p.to, m);
            } else sim.client_on_reply(p.to - sim.n(), m);
        }
    }

    // ---- Storage --------------------------------------------------------------------------

    fn write(sim: *Simulator, r: u8, w: Write) void {
        const queue = &sim.storages[r].pending;
        const last = if (queue.items.len > 0) queue.items[queue.items.len - 1].done_at else sim.now;
        var x = w;
        x.done_at = @max(last, sim.now) +
            sim.random.intRangeAtMost(u32, sim.options.write_latency_min, sim.options.write_latency_max);
        queue.append(sim.gpa, x) catch oom();
        if (sim.verbose and trace_events) std.debug.print("{d:>6} @write replica={d} kind={s} view={d} op={d} at={d}\n", .{ sim.now, r, @tagName(x.kind), x.view, x.op, x.done_at });
    }

    fn tick_storage(sim: *Simulator, r: u8) void {
        const st = &sim.storages[r];
        while (st.pending.items.len > 0 and st.pending.items[0].done_at <= sim.now) {
            const w = st.pending.orderedRemove(0);
            if (sim.verbose and trace_events) std.debug.print("{d:>6} @durable replica={d} kind={s} view={d} op={d}\n", .{ sim.now, r, @tagName(w.kind), w.view, w.op });
            switch (w.kind) {
                .append => {
                    std.debug.assert(st.log.items.len + 1 == w.entry.op); // FIFO keeps the WAL dense.
                    st.log.append(sim.gpa, w.entry) catch oom();
                },
                .install => {
                    st.log.clearRetainingCapacity();
                    st.log.appendSlice(sim.gpa, sim.snapshots.items[w.log]) catch oom();
                    st.view = w.view;
                    st.log_view = w.view;
                },
                .view => st.view = @max(st.view, w.view),
            }
            sim.on_write_done(r, w);
        }
    }

    fn on_write_done(sim: *Simulator, r: u8, w: Write) void {
        const rep = &sim.replicas[r];
        switch (w.kind) {
            .append, .install => {
                if (rep.status != .normal or rep.view != w.view or rep.log_view != w.view) return;
                rep.durable_op = @max(rep.durable_op, w.op);
                if (sim.is_primary(r)) {
                    rep.acked[r] = rep.durable_op;
                    sim.try_commit(r);
                } else {
                    // Only now, with the prepare on "disk", may the backup vouch for it.
                    sim.send(r, sim.primary_index(rep.view), .{ .command = .prepare_ok, .from = r, .view = rep.view, .op = rep.durable_op });
                }
            },
            .view => {
                // The new view is durable: after a crash we can never rejoin an older view, so it
                // is now safe to hand our log to the new primary.
                if (rep.status != .view_change or rep.view != w.view) return;
                const dvc: DoViewChange = .{ .log_view = rep.log_view, .op = @intCast(rep.log.items.len), .commit = rep.commit, .log = sim.snapshot(r) };
                const p = sim.primary_index(rep.view);
                if (p == r) {
                    sim.record_dvc(r, r, dvc);
                } else sim.send(r, p, .{
                    .command = .do_view_change,
                    .from = r,
                    .view = rep.view,
                    .log_view = dvc.log_view,
                    .op = dvc.op,
                    .commit = dvc.commit,
                    .log = dvc.log,
                });
            },
        }
    }

    // ---- Replica protocol -----------------------------------------------------------------

    fn normal_timeout(sim: *Simulator) u32 {
        return 40 + sim.random.uintLessThan(u32, 40);
    }

    fn on_message(sim: *Simulator, r: u8, m: Message) void {
        switch (m.command) {
            .request => sim.on_request(r, m),
            .prepare => sim.on_prepare(r, m),
            .prepare_ok => sim.on_prepare_ok(r, m),
            .commit => sim.on_commit(r, m),
            .start_view_change => sim.on_start_view_change(r, m),
            .do_view_change => sim.on_do_view_change(r, m),
            .start_view => sim.on_start_view(r, m),
            .get_view => sim.on_get_view(r, m),
            .reply => unreachable,
        }
    }

    fn on_request(sim: *Simulator, r: u8, m: Message) void {
        if (!sim.is_primary(r)) return; // The client will time out and try the next replica.
        const rep = &sim.replicas[r];
        const session = rep.sm.sessions[m.client];
        if (m.request <= session.request) {
            if (m.request == session.request) sim.send_reply(r, m.client);
            return;
        }
        const uncommitted = rep.log.items[@min(rep.commit, rep.log.items.len)..];
        for (uncommitted) |e| if (e.client == m.client and e.request == m.request) return;
        if (uncommitted.len >= pipeline_max) return;

        const len: u32 = @intCast(rep.log.items.len);
        var e: Entry = .{
            .op = len + 1,
            .view = rep.view,
            .client = m.client,
            .request = m.request,
            .transfer = m.transfer,
            .parent = if (len > 0) rep.log.items[len - 1].checksum else 0,
            .checksum = 0,
        };
        e.checksum = e.compute_checksum();
        rep.log.append(sim.gpa, e) catch oom();
        sim.write(r, .{ .kind = .append, .view = rep.view, .op = e.op, .entry = e });
        sim.broadcast(r, .{ .command = .prepare, .from = r, .view = rep.view, .op = e.op, .commit = rep.commit, .entry = e });
    }

    fn request_view(sim: *Simulator, r: u8, to: u8, view: u32) void {
        if (sim.now < sim.replicas[r].get_view_after) return;
        sim.replicas[r].get_view_after = sim.now + 10;
        sim.send(r, to, .{ .command = .get_view, .from = r, .view = view });
    }

    fn on_prepare(sim: *Simulator, r: u8, m: Message) void {
        const rep = &sim.replicas[r];
        if (m.view < rep.view) return;
        if (m.view > rep.view or rep.status != .normal) return sim.request_view(r, m.from, m.view);
        if (sim.primary_index(rep.view) == r) return;
        rep.timeout = sim.normal_timeout();
        const e = m.entry;
        const len: u32 = @intCast(rep.log.items.len);
        if (e.op == len + 1) {
            const parent = if (len > 0) rep.log.items[len - 1].checksum else 0;
            if (e.parent == parent and e.checksum == e.compute_checksum()) {
                rep.log.append(sim.gpa, e) catch oom();
                sim.write(r, .{ .kind = .append, .view = rep.view, .op = e.op, .entry = e });
            } else sim.request_view(r, m.from, m.view);
        } else if (e.op > len + 1) sim.request_view(r, m.from, m.view);
        sim.commit_to(r, m.commit);
    }

    fn on_prepare_ok(sim: *Simulator, r: u8, m: Message) void {
        const rep = &sim.replicas[r];
        if (m.view != rep.view or !sim.is_primary(r)) return;
        rep.acked[m.from] = @max(rep.acked[m.from], m.op);
        sim.try_commit(r);
    }

    /// Primary: commit every op that a replication quorum holds durably.
    fn try_commit(sim: *Simulator, r: u8) void {
        const rep = &sim.replicas[r];
        // BUG --bug-commit-early: one durable copy (the primary's own) is treated as enough.
        // In a calm cluster every backup acks a moment later anyway, so no test notices.
        const needed: u8 = if (bug_commit_early) 1 else sim.quorum();
        while (rep.commit < rep.log.items.len) {
            const op = rep.commit + 1;
            var count: u8 = 0;
            for (rep.acked[0..sim.n()]) |a| count += @intFromBool(a >= op);
            if (count < needed) break;
            sim.commit_one(r);
        }
    }

    fn commit_to(sim: *Simulator, r: u8, target: u32) void {
        const rep = &sim.replicas[r];
        while (rep.commit < @min(target, rep.log.items.len)) sim.commit_one(r);
    }

    fn commit_one(sim: *Simulator, r: u8) void {
        const rep = &sim.replicas[r];
        const e = rep.log.items[rep.commit];
        const result = rep.sm.apply(e);
        rep.commit += 1;
        if (sim.verbose and trace_events) std.debug.print("{d:>6} @commit replica={d} op={d} checksum={x:0>16} client={d} request={d} view={d} transfer={d}>{d}:{d} result={s}\n", .{
            sim.now, r, e.op, e.checksum, e.client, e.request, e.view, e.transfer.from, e.transfer.to, e.transfer.amount, @tagName(result),
        });
        sim.check_commit(r, e, result);
        sim.log_replica(r, ' ');
        if (sim.is_primary(r)) sim.send_reply(r, e.client);
    }

    fn send_reply(sim: *Simulator, r: u8, client: u8) void {
        const rep = &sim.replicas[r];
        const s = rep.sm.sessions[client];
        sim.send(r, sim.n() + client, .{
            .command = .reply,
            .from = r,
            .view = rep.view,
            .client = client,
            .request = s.request,
            .op = s.op,
            .result = s.result,
        });
    }

    fn on_commit(sim: *Simulator, r: u8, m: Message) void {
        const rep = &sim.replicas[r];
        if (m.view < rep.view) return;
        if (m.view > rep.view or rep.status != .normal) return sim.request_view(r, m.from, m.view);
        if (sim.primary_index(rep.view) == r) return;
        rep.timeout = sim.normal_timeout();
        if (m.op > rep.log.items.len) sim.request_view(r, m.from, m.view);
        sim.commit_to(r, m.commit);
        // Re-ack in case our earlier prepare_ok was lost.
        if (rep.durable_op > m.commit) {
            sim.send(r, m.from, .{ .command = .prepare_ok, .from = r, .view = rep.view, .op = rep.durable_op });
        }
    }

    fn start_view_change(sim: *Simulator, r: u8, view: u32) void {
        const rep = &sim.replicas[r];
        std.debug.assert(view > rep.view or rep.status == .normal);
        rep.view = view;
        rep.status = .view_change;
        rep.svc_votes = @as(u8, 1) << @intCast(r);
        rep.dvc_persisting = false;
        rep.dvcs = @splat(null);
        rep.timeout = 60 + sim.random.uintLessThan(u32, 60);
        hash_ints(&sim.trace, .{ sim.now, r, view, 0xBEEF });
        sim.log_replica(r, 'v');
        sim.broadcast(r, .{ .command = .start_view_change, .from = r, .view = view });
    }

    fn check_svc_quorum(sim: *Simulator, r: u8) void {
        const rep = &sim.replicas[r];
        if (rep.dvc_persisting or @popCount(rep.svc_votes) < sim.quorum()) return;
        rep.dvc_persisting = true;
        sim.write(r, .{ .kind = .view, .view = rep.view, .op = 0 });
    }

    fn on_start_view_change(sim: *Simulator, r: u8, m: Message) void {
        const rep = &sim.replicas[r];
        if (m.view > rep.view) sim.start_view_change(r, m.view);
        if (m.view != rep.view or rep.status != .view_change) return;
        rep.svc_votes |= @as(u8, 1) << @intCast(m.from);
        sim.check_svc_quorum(r);
    }

    fn on_do_view_change(sim: *Simulator, r: u8, m: Message) void {
        const rep = &sim.replicas[r];
        if (m.view > rep.view) sim.start_view_change(r, m.view);
        if (m.view != rep.view or rep.status != .view_change) return;
        rep.svc_votes |= @as(u8, 1) << @intCast(m.from); // A DVC implies an SVC vote.
        sim.check_svc_quorum(r);
        if (sim.primary_index(rep.view) == r) sim.record_dvc(r, m.from, .{
            .log_view = m.log_view,
            .op = m.op,
            .commit = m.commit,
            .log = m.log,
        });
    }

    fn record_dvc(sim: *Simulator, r: u8, from: u8, dvc: DoViewChange) void {
        const rep = &sim.replicas[r];
        rep.dvcs[from] = dvc;
        if (rep.dvcs[r] == null) return; // The new primary's own view must be durable too.
        var count: u8 = 0;
        for (rep.dvcs[0..sim.n()]) |d| count += @intFromBool(d != null);
        if (count >= sim.quorum()) sim.become_primary(r);
    }

    fn become_primary(sim: *Simulator, r: u8) void {
        const rep = &sim.replicas[r];
        // Choose the log with the highest (log_view, op). Any replication quorum intersects this
        // DVC quorum, so that log contains every committed op.
        var best: u8 = r;
        var commit_max: u32 = 0;
        for (rep.dvcs[0..sim.n()], 0..) |dvc, i| {
            const d = dvc orelse continue;
            commit_max = @max(commit_max, d.commit);
            const b = rep.dvcs[best].?;
            if (d.log_view > b.log_view or (d.log_view == b.log_view and d.op > b.op)) best = @intCast(i);
        }
        // BUG --bug-view-change-log: the new primary keeps its own log. When it was the one that
        // lagged (just restarted, or partitioned), committed ops beyond its head are truncated.
        // Without crashes + partitions + an unlucky primary rotation, the new primary is always
        // up to date and this is indistinguishable from the correct rule.
        if (bug_view_change_log) best = r;
        const chosen = rep.dvcs[best].?;
        rep.log.clearRetainingCapacity();
        rep.log.appendSlice(sim.gpa, sim.snapshots.items[chosen.log]) catch oom();
        rep.status = .normal;
        rep.log_view = rep.view;
        rep.durable_op = 0;
        rep.acked = @splat(0);
        rep.dvcs = @splat(null);
        rep.timeout = heartbeat_ticks;
        const op: u32 = @intCast(rep.log.items.len);
        sim.write(r, .{ .kind = .install, .view = rep.view, .op = op, .log = chosen.log });
        hash_ints(&sim.trace, .{ sim.now, r, rep.view, op, 0xF00D });
        sim.log_replica(r, '/');
        sim.broadcast(r, .{ .command = .start_view, .from = r, .view = rep.view, .op = op, .commit = commit_max, .log = chosen.log });
        sim.commit_to(r, commit_max);
    }

    fn on_start_view(sim: *Simulator, r: u8, m: Message) void {
        const rep = &sim.replicas[r];
        if (m.view < rep.view) return;
        std.debug.assert(sim.primary_index(m.view) != r);
        const log = sim.snapshots.items[m.log];
        if (m.view == rep.view and rep.status == .normal and log.len <= rep.log.items.len) {
            rep.timeout = sim.normal_timeout();
            return sim.commit_to(r, m.commit);
        }
        rep.view = m.view;
        rep.status = .normal;
        rep.log_view = m.view;
        rep.log.clearRetainingCapacity();
        rep.log.appendSlice(sim.gpa, log) catch oom();
        rep.durable_op = 0;
        rep.svc_votes = 0;
        rep.dvc_persisting = false;
        rep.dvcs = @splat(null);
        rep.timeout = sim.normal_timeout();
        sim.write(r, .{ .kind = .install, .view = m.view, .op = @intCast(log.len), .log = m.log });
        sim.log_replica(r, '>');
        sim.commit_to(r, m.commit);
    }

    fn on_get_view(sim: *Simulator, r: u8, m: Message) void {
        const rep = &sim.replicas[r];
        if (!sim.is_primary(r)) return;
        sim.send(r, m.from, .{
            .command = .start_view,
            .from = r,
            .view = rep.view,
            .op = @intCast(rep.log.items.len),
            .commit = rep.commit,
            .log = sim.snapshot(r),
        });
    }

    fn tick_replica(sim: *Simulator, r: u8) void {
        const rep = &sim.replicas[r];
        if (!rep.up) return;
        rep.timeout -|= 1;
        if (rep.timeout > 0) return;
        if (sim.is_primary(r)) {
            rep.timeout = heartbeat_ticks;
            sim.broadcast(r, .{ .command = .commit, .from = r, .view = rep.view, .commit = rep.commit, .op = @intCast(rep.log.items.len) });
        } else sim.start_view_change(r, rep.view + 1);
    }

    // ---- Faults: crash & restart -----------------------------------------------------------

    fn crash(sim: *Simulator, r: u8) void {
        const rep = &sim.replicas[r];
        rep.up = false;
        rep.stability = sim.options.crash_stability;
        hash_ints(&sim.trace, .{ sim.now, r, sim.storages[r].pending.items.len, 0xDEAD });
        sim.log_replica(r, '!'); // Its W! column = how many unsynced writes are about to be lost.
        // Unsynced writes are lost. In-memory state (log, commit, state machine) is lost too.
        sim.storages[r].pending.clearRetainingCapacity();
    }

    fn restart(sim: *Simulator, r: u8) void {
        const rep = &sim.replicas[r];
        const st = &sim.storages[r];
        var log = rep.log;
        log.clearRetainingCapacity();
        log.appendSlice(sim.gpa, st.log.items) catch oom();
        rep.* = .{ .log = log, .view = st.view, .log_view = st.log_view };
        rep.stability = sim.options.restart_stability;
        hash_ints(&sim.trace, .{ sim.now, r, 0x0B0B });
        // The state machine restarts empty (commit=0) and re-executes the log as the replica
        // learns the commit number again. The state checker sees those as repeat commits.
        rep.durable_op = @intCast(rep.log.items.len);
        rep.timeout = sim.normal_timeout();
        if (rep.log_view != rep.view) { // Crashed mid view change.
            rep.status = .view_change;
            rep.svc_votes = @as(u8, 1) << @intCast(r);
        }
        sim.log_replica(r, '^');
        // A primary may have lost uncommitted prepares in the crash: never resume as primary.
        if (sim.is_primary(r)) sim.start_view_change(r, rep.view + 1);
    }

    fn tick_faults(sim: *Simulator) void {
        if (sim.core != 0) return; // Liveness phase: faults are frozen.
        const o = &sim.options;
        for (0..sim.n()) |i| {
            const r: u8 = @intCast(i);
            const rep = &sim.replicas[r];
            rep.stability -|= 1;
            if (rep.stability > 0) continue;
            if (rep.up) {
                var p = o.crash;
                if (sim.storages[r].pending.items.len > 0) p.num *= 10; // Crash mid-write.
                if (chance(sim.random, p)) sim.crash(r);
            } else if (chance(sim.random, o.restart)) sim.restart(r);
        }
        if (sim.partition_stability > 0) {
            sim.partition_stability -= 1;
        } else if (!sim.partition_active and chance(sim.random, o.partition)) {
            sim.partition_create();
            sim.partition_stability = o.partition_stability;
        } else if (sim.partition_active and chance(sim.random, o.unpartition)) {
            sim.partitioned = @splat(@splat(false));
            sim.partition_active = false;
            sim.partition_stability = o.unpartition_stability;
            hash_ints(&sim.trace, .{ sim.now, 0x4EA1 });
            if (sim.verbose) std.debug.print("{d:>6}    partition healed\n", .{sim.now});
        }
    }

    fn partition_create(sim: *Simulator) void {
        var side: [replicas_max]bool = @splat(false);
        switch (sim.options.partition_mode) {
            .isolate_single => side[sim.random.uintLessThan(u8, sim.n())] = true,
            .uniform_split => for (side[0..sim.n()]) |*s| {
                s.* = sim.random.boolean();
            },
        }
        // Asymmetric: only traffic from the `true` side to the `false` side is cut.
        for (0..sim.n()) |a| for (0..sim.n()) |b| {
            if (side[a] == side[b]) continue;
            if (sim.options.partition_symmetric or side[a]) sim.partitioned[a][b] = true;
        };
        sim.partition_active = true;
        var bits: u8 = 0;
        for (side[0..sim.n()], 0..) |s, i| bits |= @as(u8, @intFromBool(s)) << @intCast(i);
        hash_ints(&sim.trace, .{ sim.now, bits, 0x9A97 });
        if (sim.verbose) std.debug.print("{d:>6}    partition side={b:0>5} {s}\n", .{
            sim.now, bits, if (sim.options.partition_symmetric) "symmetric" else "asymmetric",
        });
    }

    // ---- Clients ---------------------------------------------------------------------------

    fn tick_client(sim: *Simulator, c: u8) void {
        const cl = &sim.clients[c];
        if (cl.inflight) |m| {
            cl.timeout -|= 1;
            if (cl.timeout > 0) return;
            // Retry the SAME request number at the next replica: the cluster must deduplicate.
            cl.view_guess += 1;
            cl.timeout = client_timeout_ticks;
            sim.send(sim.n() + c, sim.primary_index(cl.view_guess), m);
        } else if (cl.request_next <= sim.options.requests_per_client) {
            if (cl.idle > 0) {
                cl.idle -= 1;
                return;
            }
            const from = sim.random.uintLessThan(u8, accounts);
            const to = (from + 1 + sim.random.uintLessThan(u8, accounts - 1)) % accounts;
            const m: Message = .{
                .command = .request,
                .from = sim.n() + c,
                .client = c,
                .request = cl.request_next,
                .transfer = .{ .from = from, .to = to, .amount = sim.random.intRangeAtMost(u32, 1, 80) },
            };
            cl.inflight = m;
            cl.timeout = client_timeout_ticks;
            sim.send(sim.n() + c, sim.primary_index(cl.view_guess), m);
        }
    }

    fn client_on_reply(sim: *Simulator, c: u8, m: Message) void {
        std.debug.assert(m.command == .reply and m.client == c);
        // Checker 2: every reply a client sees (even a stale duplicate) must agree with the
        // canonical committed log: same op, same request, same result.
        if (m.op == 0 or m.op > sim.canonical.items.len) {
            return sim.fail("client {d} got reply request={d} for op={d}, but only {d} ops are committed", .{ c, m.request, m.op, sim.canonical.items.len });
        }
        const canon = sim.canonical.items[m.op - 1];
        if (canon.client != c or canon.request != m.request or canon.result != m.result) {
            return sim.fail("client {d} reply request={d} op={d} result={s} disagrees with canonical op={d} (client={d} request={d} result={s})", .{ c, m.request, m.op, @tagName(m.result), m.op, canon.client, canon.request, @tagName(canon.result) });
        }
        const cl = &sim.clients[c];
        const inflight = cl.inflight orelse return;
        if (inflight.request != m.request) return;
        cl.inflight = null;
        cl.request_next += 1;
        cl.view_guess = m.view;
        cl.idle = sim.random.uintAtMost(u32, sim.options.request_idle_max);
        sim.requests_replied += 1;
    }

    fn all_replied(sim: *const Simulator) bool {
        for (sim.clients[0..sim.options.client_count]) |cl| {
            if (cl.request_next <= sim.options.requests_per_client) return false;
        }
        return true;
    }

    // ---- Checkers --------------------------------------------------------------------------

    /// Runs on EVERY commit by EVERY replica, as it happens (cf. StateChecker.check_state).
    fn check_commit(sim: *Simulator, r: u8, e: Entry, result: Result) void {
        const rep = &sim.replicas[r];
        const op = rep.commit;
        hash_ints(&sim.trace, .{ sim.now, r, op, e.checksum });
        // Checker 3: transfers move money, never create or destroy it.
        if (rep.sm.money() != money_total) {
            return sim.fail("replica {d} op={d}: money not conserved: {d} != {d}", .{ r, op, rep.sm.money(), money_total });
        }
        if (e.op != op) return sim.fail("replica {d} committed entry op={d} at position {d}", .{ r, e.op, op });
        const state = rep.sm.hash();
        // Checker 1: the first commit of op N by anyone defines op N; all later commits of op N,
        // by any replica, at any time (including replays after restart) must match it exactly.
        if (op == sim.canonical.items.len + 1) {
            sim.canonical.append(sim.gpa, .{ .checksum = e.checksum, .client = e.client, .request = e.request, .result = result, .state = state }) catch oom();
            return;
        }
        if (op > sim.canonical.items.len) return sim.fail("replica {d} committed op={d} past canonical head {d}", .{ r, op, sim.canonical.items.len });
        const canon = sim.canonical.items[op - 1];
        if (canon.checksum != e.checksum) {
            return sim.fail("divergence: replica {d} committed op={d} checksum={x:0>16} (client={d} request={d} view={d}) but canonical op={d} is checksum={x:0>16} (client={d} request={d})", .{ r, op, e.checksum, e.client, e.request, e.view, op, canon.checksum, canon.client, canon.request });
        }
        if (canon.state != state) {
            return sim.fail("divergence: replica {d} state after op={d} differs from canonical", .{ r, op });
        }
    }

    // ---- Liveness --------------------------------------------------------------------------

    /// Like vopr.zig transition_to_liveness_mode(): restart core replicas that are down, heal the
    /// network between them, cut non-core replicas off permanently, and stop injecting faults.
    fn transition_to_liveness_mode(sim: *Simulator, core: u8) void {
        sim.core = core;
        if (sim.verbose) std.debug.print("{d:>6}    liveness mode: core={b:0>5}\n", .{ sim.now, core });
        hash_ints(&sim.trace, .{ sim.now, core, 0x11FE });
        sim.partitioned = @splat(@splat(false));
        sim.partition_active = false;
        const nodes = sim.n() + sim.options.client_count;
        for (0..sim.n()) |r| {
            if (sim.in_core(r)) {
                if (!sim.replicas[r].up) sim.restart(@intCast(r));
            } else for (0..nodes) |o| {
                sim.partitioned[r][o] = o != r;
                sim.partitioned[o][r] = o != r;
            }
        }
    }

    fn random_core(sim: *Simulator) u8 {
        var order: [replicas_max]u8 = .{ 0, 1, 2, 3, 4 };
        sim.random.shuffleWithIndex(u8, order[0..sim.n()], u8);
        const size = sim.random.intRangeAtMost(u8, sim.quorum(), sim.n());
        var core: u8 = 0;
        for (order[0..size]) |r| core |= @as(u8, 1) << @intCast(r);
        return core;
    }

    /// null once the core has converged (cf. Simulator.pending() in vopr.zig).
    fn pending(sim: *const Simulator) ?[]const u8 {
        if (!sim.all_replied()) return "pending client requests";
        var view: ?u32 = null;
        const head = sim.canonical.items.len;
        for (0..sim.n()) |i| {
            if (!sim.in_core(i)) continue;
            const rep = &sim.replicas[i];
            if (!rep.up or rep.status != .normal) return "pending view change";
            if (view != null and view.? != rep.view) return "pending view agreement";
            view = rep.view;
            if (rep.commit != head or rep.log.items.len != head) return "pending replica convergence";
            if (rep.sm.hash() != sim.canonical.items[head - 1].state) return "core state differs from canonical";
        }
        if (!sim.in_core(sim.primary_index(view.?))) return "primary outside core";
        return null;
    }

    fn step(sim: *Simulator) void {
        sim.now += 1;
        sim.tick_network();
        for (0..sim.n()) |r| if (sim.replicas[r].up) sim.tick_storage(@intCast(r));
        for (0..sim.n()) |r| sim.tick_replica(@intCast(r));
        for (0..sim.options.client_count) |c| sim.tick_client(@intCast(c));
        sim.tick_faults();
    }
};

fn oom() noreturn {
    @panic("out of memory");
}

const RunResult = struct {
    ok: bool,
    trace: u64,
    ticks: u64,
    commits: usize,
    reason_buf: [256]u8 = undefined,
    reason_len: usize = 0,
    fn reason(r: *const RunResult) []const u8 {
        return r.reason_buf[0..r.reason_len];
    }
};

fn run_seed(gpa: std.mem.Allocator, seed: u64, verbose: bool) RunResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const options = options_swarm(random);
    if (verbose) print_options(seed, options);

    // The simulator gets its own PRNG derived from the seed, so adding a swarm knob later does
    // not reshuffle every fault decision of every seed.
    var sim_prng = std.Random.DefaultPrng.init(random.int(u64));
    var sim: Simulator = .{ .gpa = arena.allocator(), .random = sim_prng.random(), .options = options, .verbose = verbose };

    // Safety phase: everything may fail. Stop when all requests are replied, or when no reply has
    // arrived for ticks_max_requests ticks (like vopr.zig's ticks_max_requests loop).
    var idle_ticks: u64 = 0;
    while (sim.failure == null and idle_ticks < ticks_max_requests and !sim.all_replied()) {
        const before = sim.requests_replied;
        sim.step();
        idle_ticks = if (sim.requests_replied > before) 0 else idle_ticks + 1;
    }

    // Liveness phase: heal a random core (or every replica, if the safety phase stalled) and
    // demand convergence within a bound. "Eventually" is not testable; "within N ticks" is.
    if (sim.failure == null) {
        const core = if (sim.all_replied()) sim.random_core() else (@as(u8, 1) << @intCast(sim.n())) - 1;
        sim.transition_to_liveness_mode(core);
        var t: u64 = 0;
        while (t < ticks_max_convergence and sim.failure == null) : (t += 1) {
            sim.step();
            if (sim.pending() == null) break;
        }
        if (sim.failure == null) {
            if (sim.pending()) |reason| {
                sim.fail("no liveness: core={b:0>5} did not converge in {d} ticks: {s}", .{ sim.core, ticks_max_convergence, reason });
            }
        }
    }
    if (verbose) for (0..sim.n()) |r| sim.log_replica(@intCast(r), '=');

    var result: RunResult = .{ .ok = sim.failure == null, .trace = sim.trace.final(), .ticks = sim.now, .commits = sim.canonical.items.len };
    if (sim.failure) |f| {
        @memcpy(result.reason_buf[0..f.len], f);
        result.reason_len = f.len;
    }
    return result;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse "sweep";
    const count = try std.fmt.parseInt(u64, args.next() orelse "20000", 10);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bug-commit-early")) bug_commit_early = true;
        if (std.mem.eql(u8, arg, "--bug-view-change-log")) bug_view_change_log = true;
        if (std.mem.eql(u8, arg, "--events")) trace_events = true;
    }
    const flags = if (bug_commit_early and bug_view_change_log)
        " --bug-commit-early --bug-view-change-log"
    else if (bug_commit_early) " --bug-commit-early" else if (bug_view_change_log) " --bug-view-change-log" else "";

    if (std.mem.eql(u8, mode, "run")) {
        const r = run_seed(init.gpa, count, true);
        if (!r.ok) std.debug.print("reason: {s}\n", .{r.reason()});
        std.debug.print("seed={d} ticks={d} commits={d} trace={x:0>16} {s}\n", .{
            count, r.ticks, r.commits, r.trace, if (r.ok) "PASS" else "FAIL",
        });
        if (!r.ok) std.process.exit(1);
        return;
    }

    var seed: u64 = 0;
    while (seed < count) : (seed += 1) {
        const r = run_seed(init.gpa, seed, false);
        if (!r.ok) {
            std.debug.print("FAIL at seed={d} after {d} seeds: {s}\nReplay with:\n", .{ seed, seed + 1, r.reason() });
            std.debug.print("  zig run main.zig -- run {d}{s}\n", .{ seed, flags });
            std.process.exit(1);
        }
    }
    std.debug.print("PASS: {d} seeds\n", .{count});
}
