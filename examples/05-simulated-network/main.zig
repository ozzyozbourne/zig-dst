//! Example 05 — A simulated network.
//!
//! Real networks lose, duplicate, delay and reorder packets, and they do it rarely enough that
//! ordinary tests on localhost almost never see it. A deterministic simulation replaces the
//! network with a *packet simulator*: for every path (source -> target) a priority queue of
//! in-flight messages keyed by the tick at which they become deliverable. Faults are just
//! decisions drawn from the seeded PRNG:
//!
//!   * delay:     ready_at = now + max(delay_min, Exponential(delay_mean)). Two packets sent in
//!                order can come out in the opposite order: random delay IS reordering.
//!   * loss:      when a packet is popped, drop it with probability `packet_loss`.
//!   * replay:    when a packet is delivered, with probability `packet_replay` push a copy back
//!                into the queue with a fresh delay: the receiver will see it again later.
//!   * capacity:  a path holds at most `path_maximum_capacity` packets; one more and a random
//!                in-flight packet is dropped (a full router buffer).
//!   * clogging:  each tick a path may become clogged for Exponential(clog_mean) ticks; nothing
//!                is delivered on it until the clog clears.
//!
//! The fault parameters themselves are drawn from the seed and printed first, the way the VOPR
//! prints `SEED=… packet_loss_probability=…`: one seed explores a calm network, the next a
//! terrible one.
//!
//! System under test: clients send `transfer(amount)` requests to one server, one request in
//! flight per client, resending on timeout. Retries plus network replay mean the server WILL see
//! the same request several times, so it keeps a per-client session (last request number +
//! cached reply) to give exactly-once semantics, like TigerBeetle's client_sessions.
//!
//! Invariants (checked continuously, after every delivered packet):
//!   * safety:   server balance == sum of the amounts of the DISTINCT requests it has received.
//!   * safety:   every reply that reaches a client for request r carries exactly the result
//!               (balance-after) that r produced when it was applied.
//!   * liveness: after a "heal" (faults switched off, as VOPR's transition_to_liveness_mode),
//!               every request gets its reply within a tick budget.
//!
//! Usage:
//!   zig run main.zig -- run   <seed>  [--bug-no-dedup] [--bug-reply-stale] [--packets]
//!   zig run main.zig -- sweep <count> [--bug-no-dedup] [--bug-reply-stale]
const std = @import("std");
const assert = std.debug.assert;

/// Planted bug 1: the server applies every request it receives, ignoring the session.
var bug_no_dedup = false;
/// Planted bug 2: the server answers a retry of an already-applied request with the newest
/// state (the current balance) instead of the reply it cached when the request was applied.
var bug_reply_stale = false;
var verbose = false;
/// `run <seed> --packets`: also log every packet-level event (send, loss, replay, delivery).
/// Logging only: the trace hash and all results are unchanged.
var verbose_packets = false;

/// Every observable event is folded into this hash. Reset at the start of each seed.
var trace: std.hash.Wyhash = undefined;

fn trace_event(tag: u64, a: u64, b: u64, c: u64) void {
    trace.update(std.mem.asBytes(&[4]u64{ tag, a, b, c }));
}

fn log(tick: u64, comptime fmt: []const u8, args: anytype) void {
    if (verbose) std.debug.print("  [{d:>5}] " ++ fmt ++ "\n", .{tick} ++ args);
}

const clients_max = 4;
const process_count_max = clients_max + 1;
const requests_per_client_max = 30;
const ticks_max_convergence = 3_000;
/// Process 0 is the server; client i is process i + 1.
const server_process: u8 = 0;

// ---------------------------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------------------------

const Message = struct {
    command: enum(u8) { request, reply },
    client: u8, // client index
    request: u32, // request number, starting at 1, one per client
    amount: u64 = 0, // request: the transfer amount (a retry carries the same amount)
    balance: u64 = 0, // reply: server balance right after this request was applied

    fn fold(m: Message, tag: u64) void {
        trace_event(tag, @as(u64, @backingInt(m.command)) << 8 | m.client, m.request, m.amount ^ m.balance);
    }
};

// ---------------------------------------------------------------------------------------------
// Packet simulator (mirrors tigerbeetle/src/testing/packet_simulator.zig)
// ---------------------------------------------------------------------------------------------

const Path = struct { source: u8, target: u8 };

const NetworkOptions = struct {
    one_way_delay_min: u64, // ticks
    one_way_delay_mean: u64, // ticks
    packet_loss_percent: u8,
    packet_replay_percent: u8,
    path_maximum_capacity: u8,
    path_clog_duration_mean: u64, // ticks
    path_clog_permille: u16, // per path, per tick
};

const LinkPacket = struct { ready_at: u64, sequence: u64, message: Message };

/// What happened to a packet. The value is the tag folded into the trace.
const PacketEvent = enum(u8) { send = 1, capacity_drop = 2, lost = 3, replay = 4, deliver = 5 };

/// Key = delivery tick. Ties are broken by a send sequence number so the order is a total order
/// that depends only on what happened, never on heap internals.
fn link_packet_order(_: void, a: LinkPacket, b: LinkPacket) std.math.Order {
    return switch (std.math.order(a.ready_at, b.ready_at)) {
        .eq => std.math.order(a.sequence, b.sequence),
        else => |order| order,
    };
}

const Queue = std.PriorityQueue(LinkPacket, void, link_packet_order);

const Link = struct {
    queue: Queue = .empty,
    clogged_till: u64 = 0,
};

const Network = struct {
    gpa: std.mem.Allocator,
    options: NetworkOptions,
    prng: std.Random.DefaultPrng,
    process_count: u8,
    links: [process_count_max][process_count_max]Link = @splat(@splat(.{})),
    ticks: u64 = 0,
    sequence: u64 = 0,
    stats: struct { sent: u64 = 0, lost: u64 = 0, replayed: u64 = 0, capacity_dropped: u64 = 0, clogs: u64 = 0 } = .{},

    fn init(gpa: std.mem.Allocator, options: NetworkOptions, seed: u64, process_count: u8) !Network {
        var network: Network = .{
            .gpa = gpa,
            .options = options,
            .prng = std.Random.DefaultPrng.init(seed),
            .process_count = process_count,
        };
        // Like TigerBeetle: allocate every queue up front at its maximum capacity.
        for (0..process_count) |s| for (0..process_count) |t| {
            try network.links[s][t].queue.ensureTotalCapacity(gpa, options.path_maximum_capacity);
        };
        return network;
    }

    fn deinit(network: *Network) void {
        for (0..network.process_count) |s| for (0..network.process_count) |t| {
            network.links[s][t].queue.deinit(network.gpa);
        };
    }

    fn chance_percent(network: *Network, percent: u8) bool {
        return network.prng.random().uintLessThan(u8, 100) < percent;
    }

    /// Same as fuzz.random_int_exponential: memoryless, mostly small, occasionally huge.
    fn exponential(network: *Network, mean: u64) u64 {
        if (mean == 0) return 0;
        const x = network.prng.random().floatExp(f64) * @as(f64, @floatFromInt(mean));
        return std.math.lossyCast(u64, x);
    }

    /// Only client<->server paths carry traffic, in a fixed iteration order.
    fn path_used(path: Path) bool {
        return path.source != path.target and
            (path.source == server_process or path.target == server_process);
    }

    fn tick(network: *Network) void {
        network.ticks += 1;
        for (0..network.process_count) |s| for (0..network.process_count) |t| {
            const path: Path = .{ .source = @intCast(s), .target = @intCast(t) };
            if (!path_used(path)) continue;
            if (network.prng.random().uintLessThan(u16, 1000) < network.options.path_clog_permille) {
                const duration = network.exponential(network.options.path_clog_duration_mean);
                network.links[s][t].clogged_till = network.ticks + duration;
                network.stats.clogs += 1;
                trace_event(6, s, t, duration);
                log(network.ticks, "net: path {d}->{d} clogged for {d} ticks", .{ s, t, duration });
            }
        };
    }

    fn submit(network: *Network, path: Path, message: Message) void {
        const link = &network.links[path.source][path.target];
        if (link.queue.count() + 1 > network.options.path_maximum_capacity) {
            // Full buffer: drop a random in-flight packet (not necessarily the oldest).
            const index = network.prng.random().uintLessThan(usize, link.queue.count());
            const dropped = link.queue.popIndex(index);
            network.packet_event(.capacity_drop, path, dropped, "", .{});
            log(network.ticks, "net: path {d}->{d} full, dropped {s} c{d} r{d}", .{
                path.source, path.target, @tagName(dropped.message.command), dropped.message.client, dropped.message.request,
            });
        }
        const delay = @max(network.options.one_way_delay_min, network.exponential(network.options.one_way_delay_mean));
        network.sequence += 1;
        const packet: LinkPacket = .{
            .ready_at = network.ticks + delay,
            .sequence = network.sequence,
            .message = message,
        };
        link.queue.push(network.gpa, packet) catch unreachable; // capacity was reserved in init()
        network.packet_event(.send, path, packet, " delay={d} ready_at={d} queued={d}", .{ delay, packet.ready_at, link.queue.count() });
    }

    /// Pop the next deliverable message on `path`, applying loss and replay, or null if nothing
    /// is ready (or the path is clogged).
    fn receive(network: *Network, path: Path) ?Message {
        const link = &network.links[path.source][path.target];
        while (true) {
            if (link.clogged_till > network.ticks) return null;
            const top = link.queue.peek() orelse return null;
            if (top.ready_at > network.ticks) return null;
            _ = link.queue.pop();
            if (network.chance_percent(network.options.packet_loss_percent)) {
                network.packet_event(.lost, path, top, "", .{});
                continue;
            }
            if (network.chance_percent(network.options.packet_replay_percent)) {
                network.packet_event(.replay, path, top, "", .{});
                network.submit(path, top.message); // the copy arrives again, later
            }
            network.packet_event(.deliver, path, top, "", .{});
            return top.message;
        }
    }

    /// Count the event, fold it into the trace and, with --packets, log it.
    fn packet_event(network: *Network, comptime kind: PacketEvent, path: Path, p: LinkPacket, comptime fmt: []const u8, args: anytype) void {
        switch (kind) {
            .send => network.stats.sent += 1,
            .capacity_drop => network.stats.capacity_dropped += 1,
            .lost => network.stats.lost += 1,
            .replay => network.stats.replayed += 1,
            .deliver => {},
        }
        p.message.fold(@backingInt(kind));
        if (verbose_packets) log(network.ticks, "pkt: " ++ @tagName(kind) ++ " seq={d} {d}->{d} {s} c{d} r{d}" ++ fmt, .{
            p.sequence, path.source, path.target, @tagName(p.message.command), p.message.client, p.message.request,
        } ++ args);
    }

    /// Like testing/cluster/network.zig transition_to_liveness_mode(): no more loss or replay,
    /// minimal delay. Clogging stays on, as in TigerBeetle: a clog always ends, so it may slow
    /// progress but must never prevent it.
    fn transition_to_liveness_mode(network: *Network) void {
        network.options.one_way_delay_min = 1;
        network.options.one_way_delay_mean = 1;
        network.options.packet_loss_percent = 0;
        network.options.packet_replay_percent = 0;
    }
};

// ---------------------------------------------------------------------------------------------
// System under test: server with client sessions, and retrying clients
// ---------------------------------------------------------------------------------------------

const Session = struct {
    /// Number of the latest applied request (0 = none yet).
    request: u32 = 0,
    /// The reply produced when `request` was applied, resent verbatim for duplicates.
    reply: Message = undefined,
};

const Server = struct {
    balance: u64 = 0,
    sessions: [clients_max]Session = @splat(.{}),

    fn apply(server: *Server, session: *Session, message: Message) Message {
        server.balance += message.amount;
        session.request = message.request;
        session.reply = .{ .command = .reply, .client = message.client, .request = message.request, .balance = server.balance };
        return session.reply;
    }

    /// Same decision table as vsr/replica.zig ignore_request_message_duplicate():
    ///   request == session + 1  -> new: apply, cache reply
    ///   request == session      -> duplicate: resend cached reply
    ///   request <  session      -> older request: ignore (the client has moved on)
    fn on_request(server: *Server, tick: u64, message: Message) ?Message {
        const session = &server.sessions[message.client];
        if (bug_no_dedup) {
            // BUG: "requests are idempotent enough". A retry whose first copy was applied but
            // whose reply was lost, or a network replay, is applied a second time.
            log(tick, "server: apply c{d} r{d} amount={d} (no dedup)", .{ message.client, message.request, message.amount });
            trace_event(7, message.client, message.request, message.amount);
            return server.apply(session, message);
        }
        if (message.request == session.request + 1) {
            const reply = server.apply(session, message);
            trace_event(7, message.client, message.request, server.balance);
            log(tick, "server: apply c{d} r{d} amount={d} balance={d}", .{ message.client, message.request, message.amount, server.balance });
            return reply;
        }
        // The client protocol (one request in flight) guarantees it never runs ahead.
        assert(message.request <= session.request);
        if (bug_reply_stale) {
            // BUG: rebuild the reply from the newest state instead of the cached reply. With a
            // single client, a retry of its latest request gets the right number by luck
            // (nothing else moved the balance); only a stale replay of an OLDER request, which
            // the client discards anyway, carries a wrong number. It takes another client's
            // transfer landing between apply and retry for a client to accept a wrong answer.
            trace_event(8, message.client, message.request, server.balance);
            log(tick, "server: duplicate c{d} r{d} -> reply with current balance={d}", .{ message.client, message.request, server.balance });
            return .{ .command = .reply, .client = message.client, .request = message.request, .balance = server.balance };
        }
        if (message.request == session.request) {
            trace_event(8, message.client, message.request, session.reply.balance);
            log(tick, "server: duplicate c{d} r{d} -> cached reply balance={d}", .{ message.client, message.request, session.reply.balance });
            return session.reply;
        }
        trace_event(9, message.client, message.request, session.request);
        log(tick, "server: ignore old c{d} r{d} (session at r{d})", .{ message.client, message.request, session.request });
        return null;
    }
};

const Client = struct {
    index: u8,
    prng: std.Random.DefaultPrng,
    requests_total: u32,
    timeout_base: u64,
    request_number: u32 = 0, // last issued
    inflight: ?Message = null,
    deadline: u64 = 0,
    attempts: u32 = 0,

    /// Exponential backoff with jitter, like vsr.Timeout.backoff() in vsr/client.zig.
    fn timeout(client: *Client) u64 {
        const shift: u6 = @intCast(@min(client.attempts, 3));
        return (client.timeout_base << shift) + client.prng.random().uintLessThan(u64, client.timeout_base);
    }

    fn tick(client: *Client, now: u64) ?Message {
        if (client.inflight) |message| {
            if (now < client.deadline) return null;
            // on_request_timeout(): resend the SAME request (same number, same amount).
            client.attempts += 1;
            client.deadline = now + client.timeout();
            trace_event(10, client.index, message.request, client.attempts);
            log(now, "client {d}: timeout, resend r{d} (attempt {d})", .{ client.index, message.request, client.attempts });
            return message;
        }
        if (client.request_number == client.requests_total) return null;
        if (client.prng.random().uintLessThan(u8, 10) != 0) return null; // think time
        client.request_number += 1;
        const message: Message = .{
            .command = .request,
            .client = client.index,
            .request = client.request_number,
            .amount = client.prng.random().intRangeAtMost(u64, 1, 1000),
        };
        client.inflight = message;
        client.attempts = 0;
        client.deadline = now + client.timeout();
        trace_event(11, client.index, message.request, message.amount);
        log(now, "client {d}: send r{d} transfer({d})", .{ client.index, message.request, message.amount });
        return message;
    }

    /// Like vsr/client.zig on_reply(): replies to older requests (duplicates) are ignored.
    fn on_reply(client: *Client, now: u64, reply: Message) void {
        const inflight = client.inflight orelse {
            assert(reply.request <= client.request_number);
            return;
        };
        if (reply.request < inflight.request) return;
        assert(reply.request == inflight.request);
        client.inflight = null;
        trace_event(12, client.index, reply.request, reply.balance);
        log(now, "client {d}: reply r{d} balance={d}", .{ client.index, reply.request, reply.balance });
    }

    /// Replies received so far: every issued request except the one still in flight.
    fn replies(client: *const Client) u32 {
        return client.request_number - @intFromBool(client.inflight != null);
    }

    fn done(client: *const Client) bool {
        return client.replies() == client.requests_total;
    }
};

// ---------------------------------------------------------------------------------------------
// Checker: an oracle that watches the system from outside, after every delivery.
// ---------------------------------------------------------------------------------------------

const Checker = struct {
    /// Highest request number delivered to the server per client. Because a client sends r+1
    /// only after r's reply, which exists only after r was applied, every delivered request is
    /// either "new" (== max + 1) or a repeat (<= max). So "distinct requests" is just a counter.
    delivered_max: [clients_max]u32 = @splat(0),
    /// Sum of amounts of distinct requests: what the balance must be if each applies exactly once.
    expected_balance: u64 = 0,
    /// The result each request produced at its (single) application.
    applied_balance: [clients_max][requests_per_client_max + 1]u64 = @splat(@splat(0)),

    fn on_request_delivered(checker: *Checker, message: Message) void {
        const c = message.client;
        if (message.request == checker.delivered_max[c] + 1) {
            checker.delivered_max[c] = message.request;
            checker.expected_balance += message.amount;
            checker.applied_balance[c][message.request] = checker.expected_balance;
        } else {
            assert(message.request <= checker.delivered_max[c]);
        }
    }

    fn check_balance(checker: *const Checker, tick: u64, balance: u64) error{InvariantViolated}!void {
        if (balance != checker.expected_balance) {
            log(tick, "INVARIANT VIOLATED: server balance={d}, sum of distinct requests={d}", .{ balance, checker.expected_balance });
            return error.InvariantViolated;
        }
    }

    /// Checks EVERY reply that reaches a client, including late duplicates the client will
    /// discard: a wrong reply on the wire is a bug even if this particular client ignores it.
    fn on_reply_delivered(checker: *const Checker, tick: u64, reply: Message) error{InvariantViolated}!void {
        assert(reply.request <= checker.delivered_max[reply.client]);
        const want = checker.applied_balance[reply.client][reply.request];
        if (reply.balance != want) {
            log(tick, "INVARIANT VIOLATED: reply c{d} r{d} says balance={d}, but r{d} produced balance={d}", .{
                reply.client, reply.request, reply.balance, reply.request, want,
            });
            return error.InvariantViolated;
        }
    }
};

// ---------------------------------------------------------------------------------------------
// Simulator
// ---------------------------------------------------------------------------------------------

const Simulator = struct {
    network: Network,
    server: Server = .{},
    clients: [clients_max]Client = undefined,
    client_count: u8,
    checker: Checker = .{},

    fn deliver(sim: *Simulator, path: Path, message: Message) !void {
        const now = sim.network.ticks;
        if (path.target == server_process) {
            assert(message.command == .request);
            sim.checker.on_request_delivered(message);
            const reply = sim.server.on_request(now, message);
            try sim.checker.check_balance(now, sim.server.balance);
            if (reply) |r| sim.network.submit(.{ .source = server_process, .target = r.client + 1 }, r);
        } else {
            assert(message.command == .reply);
            try sim.checker.on_reply_delivered(now, message);
            sim.clients[message.client].on_reply(now, message);
        }
    }

    fn tick(sim: *Simulator) !void {
        sim.network.tick();
        const pc = sim.network.process_count;
        for (0..pc) |s| for (0..pc) |t| {
            const path: Path = .{ .source = @intCast(s), .target = @intCast(t) };
            if (!Network.path_used(path)) continue;
            while (sim.network.receive(path)) |message| try sim.deliver(path, message);
        };
        for (sim.clients[0..sim.client_count]) |*client| {
            if (client.tick(sim.network.ticks)) |request| {
                sim.network.submit(.{ .source = client.index + 1, .target = server_process }, request);
            }
        }
    }

    fn all_done(sim: *const Simulator) bool {
        for (sim.clients[0..sim.client_count]) |*client| if (!client.done()) return false;
        return true;
    }
};

const Result = struct { ok: bool, trace_hash: u64, ticks: u64 };

fn run_seed(gpa: std.mem.Allocator, seed: u64, verbose_: bool) !Result {
    verbose = verbose_;
    trace = std.hash.Wyhash.init(0);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    // Everything below — including how hostile the network is — is a function of the seed.
    const client_count: u8 = random.intRangeAtMost(u8, 1, clients_max);
    const requests_per_client: u32 = random.intRangeAtMost(u32, 5, requests_per_client_max);
    const ticks_max_safety: u64 = random.intRangeAtMost(u64, 200, 2_000);
    const request_timeout: u64 = random.intRangeAtMost(u64, 10, 60);
    const options: NetworkOptions = .{
        .one_way_delay_min = random.uintAtMost(u64, 3),
        .one_way_delay_mean = random.intRangeAtMost(u64, 3, 15),
        .packet_loss_percent = random.uintAtMost(u8, 30),
        .packet_replay_percent = random.uintAtMost(u8, 50),
        .path_maximum_capacity = random.intRangeAtMost(u8, 2, 20),
        .path_clog_duration_mean = random.uintAtMost(u64, 100),
        .path_clog_permille = random.uintAtMost(u16, 10),
    };

    if (verbose) std.debug.print(
        \\
        \\          SEED={d}
        \\
        \\          clients={d}
        \\          requests_per_client={d}
        \\          request_timeout={d} ticks
        \\          ticks_max_safety={d} ticks
        \\          one_way_delay_mean={d} ticks
        \\          one_way_delay_min={d} ticks
        \\          packet_loss_probability={d}%
        \\          packet_replay_probability={d}%
        \\          path_maximum_capacity={d} messages
        \\          path_clog_duration_mean={d} ticks
        \\          path_clog_probability={d}/1000 per tick
        \\
        \\
    , .{
        seed,                          client_count,                    requests_per_client,
        request_timeout,               ticks_max_safety,                options.one_way_delay_mean,
        options.one_way_delay_min,     options.packet_loss_percent,     options.packet_replay_percent,
        options.path_maximum_capacity, options.path_clog_duration_mean, options.path_clog_permille,
    });

    var sim: Simulator = .{
        .network = try Network.init(gpa, options, random.int(u64), client_count + 1),
        .client_count = client_count,
    };
    defer sim.network.deinit();
    for (0..client_count) |i| {
        sim.clients[i] = .{
            .index = @intCast(i),
            .prng = std.Random.DefaultPrng.init(random.int(u64)),
            .requests_total = requests_per_client,
            .timeout_base = request_timeout,
        };
    }

    // Phase 1 — safety: full faults. Invariants are checked after every delivery.
    while (sim.network.ticks < ticks_max_safety and !sim.all_done()) {
        sim.tick() catch return .{ .ok = false, .trace_hash = trace.final(), .ticks = sim.network.ticks };
    }

    // Phase 2 — liveness: heal the network, then every request must complete within a budget.
    // Without this phase a network that drops 100% of packets would "pass" every safety check.
    sim.network.transition_to_liveness_mode();
    trace_event(13, sim.network.ticks, 0, 0);
    log(sim.network.ticks, "transition_to_liveness_mode: loss=0 replay=0 delay=1", .{});
    const convergence_start = sim.network.ticks;
    while (!sim.all_done()) {
        if (sim.network.ticks - convergence_start >= ticks_max_convergence) {
            for (sim.clients[0..client_count]) |*client| if (!client.done()) {
                log(sim.network.ticks, "LIVENESS VIOLATED: client {d} has {d}/{d} replies", .{ client.index, client.replies(), client.requests_total });
            };
            return .{ .ok = false, .trace_hash = trace.final(), .ticks = sim.network.ticks };
        }
        sim.tick() catch return .{ .ok = false, .trace_hash = trace.final(), .ticks = sim.network.ticks };
    }

    const stats = sim.network.stats;
    if (verbose) std.debug.print(
        "\n  balance={d} sent={d} lost={d} replayed={d} capacity_dropped={d} clogs={d}\n",
        .{ sim.server.balance, stats.sent, stats.lost, stats.replayed, stats.capacity_dropped, stats.clogs },
    );
    return .{ .ok = true, .trace_hash = trace.final(), .ticks = sim.network.ticks };
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse "sweep";
    const n = try std.fmt.parseInt(u64, args.next() orelse "10000", 10);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bug-no-dedup")) {
            bug_no_dedup = true;
        } else if (std.mem.eql(u8, arg, "--bug-reply-stale")) {
            bug_reply_stale = true;
        } else if (std.mem.eql(u8, arg, "--packets")) {
            verbose_packets = true;
        } else {
            std.debug.print("unknown flag: {s}\n", .{arg});
            std.process.exit(2);
        }
    }
    if (std.mem.eql(u8, mode, "run")) {
        const r = try run_seed(init.gpa, n, true);
        std.debug.print("seed={d} ticks={d} trace={x:0>16} {s}\n", .{
            n, r.ticks, r.trace_hash, if (r.ok) "PASS" else "FAIL",
        });
        if (!r.ok) std.process.exit(1);
        return;
    }

    var seed: u64 = 0;
    while (seed < n) : (seed += 1) {
        const r = try run_seed(init.gpa, seed, false);
        if (!r.ok) {
            std.debug.print("FAIL at seed={d} after {d} seeds. Replay with:\n", .{ seed, seed + 1 });
            std.debug.print("  zig run main.zig -- run {d}{s}{s}\n", .{
                seed,
                if (bug_no_dedup) " --bug-no-dedup" else "",
                if (bug_reply_stale) " --bug-reply-stale" else "",
            });
            std.process.exit(1);
        }
    }
    std.debug.print("PASS: {d} seeds\n", .{n});
}
