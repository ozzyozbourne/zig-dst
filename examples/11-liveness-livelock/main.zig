//! Example 11 — Liveness: the bug that never does anything wrong.
//!
//! Every other example plants a SAFETY bug: something bad happens (two leaders, lost money, a
//! rewritten log) and an assertion catches it at the tick it happens. This one plants LIVENESS
//! bugs: nothing bad ever happens, but nothing good ever happens either. No assertion can fire,
//! because every individual state is legal. You need a different checker ("within N ticks of
//! healing, progress must happen") and a different way of running the simulation (faults first,
//! then heal and demand progress), exactly like TigerBeetle's VOPR (src/vopr.zig).
//!
//! System under test: Raft-style leader election + log replication of a replicated COUNTER
//! among 3–5 nodes (count from the seed). Clients submit "increment" requests (c<client>#<n>);
//! the leader appends them to its log, replicates with AppendEntries, commits on a majority, and
//! replies with the counter value. A per-client session table makes retries exactly-once.
//!
//! Two phases, as in examples 08 and 10 and in vopr.zig:
//!   1. SAFETY phase (fault_ticks): partitions, crashes/restarts, packet loss, delay jitter.
//!      Safety invariants are checked on every tick and every commit.
//!   2. LIVENESS phase: like Simulator.transition_to_liveness_mode, pick a random CORE of at
//!      least a quorum of nodes, restart the core nodes that are down, heal every link inside the
//!      core, cut the other nodes off for good, turn off loss. The network stays jittery (TB's
//!      liveness network keeps an exponential delay). Then demand, within convergence_ticks:
//!      a stable leader agreed by the whole core, and the commit of every client request.
//!      Before reporting a liveness failure, cluster_recoverable() checks that the core really
//!      could make progress (cf. vopr.zig cluster_recoverable / core_missing_quorum).
//!
//! Safety invariants (checked during BOTH phases, and reported even when liveness fails):
//!   - Election Safety: at most one leader per term, over the whole history.
//!   - Committed prefix never rewritten: the first commit of index i (by any node) defines it;
//!     every later commit of i must match, and no node ever truncates its log below its commit.
//!   - Exactly-once: the counter after index i equals the number of distinct requests in 1..i.
//!
//! Planted bugs — both are PURE liveness bugs: the safety checkers above stay green.
//!   --bug-fixed-timeout              every node uses the same election timeout (30 ticks)
//!                                    instead of a random one in [20, 40]. Timers are re-armed
//!                                    by SHARED events: every follower that receives a
//!                                    candidate's higher-term RequestVote re-arms in the same
//!                                    delivery window. With equal timeouts the same order then
//!                                    repeats every round: either several nodes fire within one
//!                                    message delay (split vote), or a candidate with a stale log
//!                                    always fires first and re-arms the only electable node
//!                                    before it can stand (refused). Terms climb, nobody wins.
//!   --bug-no-retry-on-leader-change  once a leader has ACCEPTED a client's request (appended it),
//!                                    the client stops its retry timer and waits for the reply.
//!                                    If that leader is deposed before the entry commits, the new
//!                                    leader discards the entry and the client waits forever.
//!
//! Usage:
//!   zig run main.zig -- run   <seed>  [--bug-fixed-timeout] [--bug-no-retry-on-leader-change]
//!   zig run main.zig -- sweep <count> [--bug-fixed-timeout] [--bug-no-retry-on-leader-change]
//!   zig run main.zig -- stats <count> [--spread=K] [--bug-...]   one TSV line per seed (site)
const std = @import("std");
const assert = std.debug.assert;

var bug_fixed_timeout = false;
var bug_no_retry = false;
/// Width of the election-timeout window: timeouts are uniform in
/// [mean - spread/2, mean + spread/2]. --bug-fixed-timeout is spread = 0. `--spread=K` is an
/// exploration knob for the split-vote chart; the default reproduces the documented runs.
var timeout_spread: u64 = 20;
/// `stats` mode prints one TSV line per seed and nothing else.
var stats_mode = false;

fn say(comptime fmt: []const u8, args: anytype) void {
    if (!stats_mode) std.debug.print(fmt, args);
}

const nodes_max = 5;
const clients_max = 3;
const addresses_max = nodes_max + clients_max; // clients are network addresses n..n+c-1
const none: u8 = 0xff;
/// A set of replicas, bit k = node k.
const NodeSet = std.bit_set.Integer(nodes_max);

// Protocol timing, in ticks.
const election_timeout_mean = 30;
const heartbeat_interval = 5;
const request_vote_retry = 6;
const client_timeout = 60;
const entries_max = 4; // entries per AppendEntries message

// Simulation phases.
const fault_ticks = 2000;
/// Liveness window: ~100 election timeouts. "Eventually" is not testable; "within N" is.
const convergence_ticks = 3000;

// ---------------------------------------------------------------------------------------------
// Swarm options: the seed decides how hostile the safety phase is.
// ---------------------------------------------------------------------------------------------

const PartitionMode = enum { isolate_single, uniform_size };

const Options = struct {
    node_count: u8,
    client_count: u8,
    requests_per_client: u32,
    request_idle_max: u32,
    partition_mode: PartitionMode,
    partition_probability: u32, // per 10_000 ticks
    unpartition_probability: u32, // per 10_000 ticks
    partition_stability: u32,
    crash_probability: u32, // per node, per 100_000 ticks
    restart_probability: u32, // per down node, per 1_000 ticks
    loss_probability: u32, // per 1_000 messages
    delay_min: u8,
    delay_max: u8,

    fn generate(random: std.Random) Options {
        const delay_min = 1 + random.uintAtMost(u8, 1);
        return .{
            .node_count = 3 + random.uintAtMost(u8, 2),
            .client_count = 1 + random.uintAtMost(u8, clients_max - 1),
            .requests_per_client = 3 + random.uintAtMost(u32, 7),
            .request_idle_max = random.uintAtMost(u32, 150),
            .partition_mode = random.enumValueWithIndex(PartitionMode, u32),
            .partition_probability = 20 + random.uintAtMost(u32, 100),
            .unpartition_probability = 100 + random.uintAtMost(u32, 300),
            .partition_stability = 50 + random.uintAtMost(u32, 150),
            .crash_probability = 20 + random.uintAtMost(u32, 200),
            .restart_probability = 20 + random.uintAtMost(u32, 100),
            .loss_probability = random.uintAtMost(u32, 60),
            .delay_min = delay_min,
            .delay_max = delay_min + random.uintAtMost(u8, 4),
        };
    }
};

// ---------------------------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------------------------

/// client == none marks the no-op a new leader appends so that older entries can commit.
const Entry = struct { term: u64, client: u8, request: u32 };

const Kind = enum(u8) {
    request_vote, // index/log_term = candidate's last log index/term
    vote, // granted
    append, // index/log_term = prev index/term, entries, commit
    append_reply, // granted = success; index = match index (success) or retry hint (failure)
    request, // client -> replica: client, request
    redirect, // replica -> client: leader hint (none if unknown)
    accepted, // leader -> client: appended at `index` in `term`
    reply, // leader -> client: committed at `index`, counter = value
};

const Message = struct {
    deliver_at: u64 = 0, // set by send()
    from: u8,
    to: u8,
    kind: Kind,
    term: u64 = 0,
    granted: bool = false,
    index: u64 = 0,
    log_term: u64 = 0,
    commit: u64 = 0,
    entries: [entries_max]Entry = undefined,
    entry_count: u8 = 0,
    client: u8 = none,
    request: u32 = 0,
    leader_hint: u8 = none,
    value: u64 = 0,
};

// ---------------------------------------------------------------------------------------------
// Node: the system under test
// ---------------------------------------------------------------------------------------------

const Role = enum(u8) { follower, candidate, leader };

const Node = struct {
    id: u8,
    up: bool = true,
    /// The node's own clock jitter: election timeouts come from here.
    prng: std.Random.DefaultPrng,

    // Persistent (written synchronously before any message that depends on them leaves the
    // node; a crash keeps them). Example 08 shows what happens when this rule is broken.
    current_term: u64 = 0,
    voted_for: u8 = none,
    log: std.ArrayList(Entry) = .empty,

    // Volatile: reset by a crash. The state machine is rebuilt by re-applying committed entries.
    role: Role = .follower,
    leader: u8 = none,
    votes: NodeSet = .empty, // nodes that granted us a vote in current_term
    election_deadline: u64 = 0,
    next_heartbeat: u64 = 0,
    next_vote_retry: u64 = 0,
    commit: u64 = 0,
    applied: u64 = 0,
    counter: u64 = 0,
    sessions: [clients_max]u32 = @splat(0), // last request applied per client
    next_index: [nodes_max]u64 = @splat(1),
    match_index: [nodes_max]u64 = @splat(0),

    /// Every place that (re)starts the election timer goes through here: starting an election,
    /// granting a vote, hearing the current leader, and stepping down to a higher term.
    fn arm_election_timer(node: *Node, now: u64) void {
        const lo = election_timeout_mean - timeout_spread / 2;
        // THE BUG (--bug-fixed-timeout sets spread = 0): every node draws the same number, so
        // timers re-armed by the same event fire in the same order, at the same offsets, forever.
        node.election_deadline = now + node.prng.random().intRangeAtMost(u64, lo, lo + timeout_spread);
    }

    fn last_index(node: *const Node) u64 {
        return node.log.items.len;
    }

    fn term_at(node: *const Node, index: u64) u64 {
        return if (index == 0) 0 else node.log.items[index - 1].term;
    }
};

const Client = struct {
    next_request: u32 = 1,
    inflight: bool = false,
    request: u32 = 0,
    leader_guess: u8 = 0,
    deadline: u64 = 0,
    idle_until: u64 = 0,
    submitted_at: u64 = 0,
    last_sent_at: u64 = 0,
    // Set by an `accepted` message; this is what the buggy client trusts too much.
    accepted: ?struct { by: u8, term: u64, index: u64, at: u64 } = null,
};

// ---------------------------------------------------------------------------------------------
// Simulator
// ---------------------------------------------------------------------------------------------

const Failure = enum { none, election_safety, prefix_rewritten, no_stable_leader, request_stuck, not_caught_up };

/// One record per term in which somebody stood for election (the election "rounds").
const Round = struct {
    term: u64,
    candidates: NodeSet = .empty,
    votes: [nodes_max]NodeSet = @splat(.empty), // per candidate: its voters (itself included)
    log_refused: NodeSet = .empty, // voters that refused because the candidate's log was behind theirs
    leader: u8 = none,
    first_tick: u64,
    last_tick: u64,
};
/// Two candidates whose timers fire closer together than one message delivery cannot hear each
/// other's RequestVote first: they WILL split the vote. (Liveness-phase delay is 1..6 ticks.)
const simultaneous_window = 6;

const Commit = struct { term: u64, client: u8, request: u32, counter: u64 };

const Stats = struct {
    ticks_to_leader: ?u64 = null, // first tick after heal with a stable leader
    term_at_heal: u64 = 0,
    term_end: u64 = 0,
    rounds: u64 = 0, // terms with a candidate, started during the liveness window
    splits: u64 = 0, // ...of those: no leader and >= 2 candidates
    simultaneous: u64 = 0, // ...of the splits: all candidates timed out within simultaneous_window
    refused: u64 = 0, // ...no leader and a single candidate (refused by a voter whose log was ahead)
    max_pending: u64 = 0, // longest a request has waited (ticks), at the end
};

const Result = struct { failure: Failure, trace_hash: u64, ticks: u64, stats: Stats, nodes: u8, core: usize };

const Simulator = struct {
    gpa: std.mem.Allocator,
    options: Options,
    verbose: bool,
    nodes: [nodes_max]Node,
    clients: [clients_max]Client = @splat(.{}),
    tick: u64 = 0,
    trace: std.hash.Wyhash = std.hash.Wyhash.init(0),

    fault_prng: std.Random.DefaultPrng,
    net_prng: std.Random.DefaultPrng,
    client_prng: std.Random.DefaultPrng,
    messages: std.ArrayList(Message) = .empty,
    links: [addresses_max][addresses_max]bool = @splat(@splat(true)),
    partition: [nodes_max]bool = @splat(false),
    partition_active: bool = false,
    stability: u32 = 0,

    // Liveness phase.
    core: NodeSet = .empty, // empty during the safety phase
    heal_tick: u64 = 0,
    stats: Stats = .{},

    // Checker state. Plain lists (no hash maps) so nothing depends on iteration order.
    term_leaders: std.ArrayList(struct { term: u64, node: u8 }) = .empty,
    canonical: std.ArrayList(Commit) = .empty,
    rounds: std.ArrayList(Round) = .empty,
    failure: Failure = .none,

    fn init(gpa: std.mem.Allocator, seed: u64, verbose: bool) Simulator {
        // One root PRNG; every component gets a sub-seed derived from it.
        var root = std.Random.DefaultPrng.init(seed);
        const random = root.random();
        const options = Options.generate(random);
        var sim: Simulator = .{
            .gpa = gpa,
            .options = options,
            .verbose = verbose,
            .nodes = undefined,
            .fault_prng = std.Random.DefaultPrng.init(random.int(u64)),
            .net_prng = std.Random.DefaultPrng.init(random.int(u64)),
            .client_prng = std.Random.DefaultPrng.init(random.int(u64)),
        };
        for (&sim.nodes, 0..) |*node, i| {
            node.* = .{ .id = @intCast(i), .prng = std.Random.DefaultPrng.init(random.int(u64)) };
            node.arm_election_timer(0);
        }
        for (sim.clients[0..options.client_count], 0..) |*cl, c| {
            cl.leader_guess = @intCast(c % options.node_count);
            cl.idle_until = random.uintAtMost(u64, options.request_idle_max);
        }
        sim.hash(.{
            options.node_count,              options.client_count,                options.requests_per_client,
            options.request_idle_max,        @backingInt(options.partition_mode), options.partition_probability,
            options.unpartition_probability, options.partition_stability,         options.crash_probability,
            options.restart_probability,     options.loss_probability,            options.delay_min,
            options.delay_max,
        });
        return sim;
    }

    fn deinit(sim: *Simulator) void {
        for (&sim.nodes) |*node| node.log.deinit(sim.gpa);
        sim.messages.deinit(sim.gpa);
        sim.term_leaders.deinit(sim.gpa);
        sim.canonical.deinit(sim.gpa);
        sim.rounds.deinit(sim.gpa);
    }

    /// Hash integers one by one (never `asBytes` a struct: padding bytes are undefined).
    fn hash(sim: *Simulator, values: anytype) void {
        inline for (values) |v| {
            const x: u64 = v;
            sim.trace.update(std.mem.asBytes(&x));
        }
    }

    fn n(sim: *const Simulator) u8 {
        return sim.options.node_count;
    }

    fn quorum(sim: *const Simulator) u8 {
        return sim.n() / 2 + 1;
    }

    fn in_core(sim: *const Simulator, i: usize) bool {
        return sim.core.isSet(i);
    }

    fn liveness_mode(sim: *const Simulator) bool {
        return sim.core.mask != 0;
    }

    fn chance(prng: *std.Random.DefaultPrng, numerator: u32, denominator: u32) bool {
        return prng.random().uintLessThan(u32, denominator) < numerator;
    }

    // ---- Event log -------------------------------------------------------------------------
    //
    //   tick node event role [cluster] term votedFor leader commit/log
    //
    //   event: ? became candidate (new term)  * became leader  > adopted a higher term
    //          v granted a vote  x truncated uncommitted entries  ! crash  ^ restart
    //   role:  / leader  \ follower  ? candidate  # crashed      (VOPR symbols, as in example 08)
    //   [cluster]: every node's role symbol, at its index.
    //   Phase lines: "P" partition, "H" heal, "L" liveness mode. Client lines start with "c<i>".

    fn role_char(node: *const Node) u8 {
        if (!node.up) return '#';
        return switch (node.role) {
            .leader => '/',
            .follower => '\\',
            .candidate => '?',
        };
    }

    fn event(sim: *Simulator, i: u8, ev: u8) void {
        const node = &sim.nodes[i];
        // Election rounds (diagnosis only, never hashed): '?' stands, '*' wins, 'v' votes.
        switch (ev) {
            '?' => if (!sim.liveness_mode() or sim.in_core(i)) {
                const round = sim.round_for(node.current_term);
                round.candidates.set(i);
                round.votes[i].set(i);
                round.last_tick = sim.tick;
            },
            '*' => if (sim.round_find(node.current_term)) |round| {
                round.leader = i;
            },
            'v' => if (sim.round_find(node.current_term)) |round| round.votes[node.voted_for].set(i),
            else => {},
        }
        var cluster: [nodes_max]u8 = undefined;
        var bits: u64 = 0;
        for (sim.nodes[0..sim.n()], 0..) |*x, k| {
            cluster[k] = role_char(x);
            bits = bits * 256 + cluster[k];
        }
        sim.hash(.{ sim.tick, i, ev, node.current_term, node.voted_for, node.leader, node.commit, node.log.items.len, bits });
        if (!sim.verbose) return;
        std.debug.print("{d:>6} {d} {c} {c} [{s}] {d:>3}T v{c} L{c} c{d}/{d}\n", .{
            sim.tick,                                                  i,
            ev,                                                        role_char(node),
            cluster[0..sim.n()],                                       node.current_term,
            if (node.voted_for == none) '-' else '0' + node.voted_for, if (node.leader == none) '-' else '0' + node.leader,
            node.commit,                                               node.log.items.len,
        });
    }

    fn client_event(sim: *Simulator, c: u8, ev: u8, request: u32, to: u8) void {
        sim.hash(.{ sim.tick, 0xC1, c, ev, request, to });
        if (!sim.verbose) return;
        std.debug.print("{d:>6} c{d} {c} #{d} node={c}\n", .{
            sim.tick, c, ev, request, if (to == none) '-' else '0' + to,
        });
    }

    fn phase_event(sim: *Simulator, ev: u8) void {
        sim.hash(.{ sim.tick, 0xFA, ev });
        if (!sim.verbose) return;
        var a: [2 * nodes_max]u8 = undefined;
        var b: [2 * nodes_max]u8 = undefined;
        if (ev == 'P') {
            var side: NodeSet = .empty;
            for (0..sim.n()) |k| side.setValue(k, sim.partition[k]);
            std.debug.print("{d:>6} - P partition {s}|{s}\n", .{
                sim.tick, sim.node_list(&a, side, ""), sim.node_list(&b, side.complement(), ""),
            });
        } else if (ev == 'H') {
            std.debug.print("{d:>6} - H heal\n", .{sim.tick});
        } else {
            const cut = sim.node_list(&b, sim.core.complement(), "");
            std.debug.print("{d:>6} - L liveness mode: core={s} (cut off for good: {s})\n", .{
                sim.tick, sim.node_list(&a, sim.core, ""), if (cut.len == 0) "none" else cut,
            });
        }
    }

    /// The members of `set` among this cluster's nodes, as digits joined by `sep`.
    fn node_list(sim: *const Simulator, buf: *[2 * nodes_max]u8, set: NodeSet, sep: []const u8) []const u8 {
        var len: usize = 0;
        for (0..sim.n()) |k| if (set.isSet(k)) {
            if (len > 0) {
                @memcpy(buf[len..][0..sep.len], sep);
                len += sep.len;
            }
            buf[len] = '0' + @as(u8, @intCast(k));
            len += 1;
        };
        return buf[0..len];
    }

    // ---- Network ---------------------------------------------------------------------------

    fn delay(sim: *Simulator) u64 {
        const random = sim.net_prng.random();
        if (sim.liveness_mode()) {
            // Like network.zig transition_to_liveness_mode: min = mean = 1, but the delay stays
            // exponential: max(1, Exp(mean)). Here: 1 tick plus a geometric tail (1/3 per step).
            var d: u64 = 1;
            while (d < 6 and random.uintLessThan(u32, 3) == 0) d += 1;
            return d;
        }
        return random.intRangeAtMost(u64, sim.options.delay_min, sim.options.delay_max);
    }

    fn send(sim: *Simulator, message: Message) void {
        var m = message;
        // Like PacketSimulator: link filters apply when a packet is submitted.
        if (!sim.links[m.from][m.to]) return;
        if (!sim.liveness_mode() and chance(&sim.net_prng, sim.options.loss_probability, 1000)) return;
        m.deliver_at = sim.tick + sim.delay();
        sim.messages.append(sim.gpa, m) catch @panic("OOM");
    }

    fn partition_network(sim: *Simulator) void {
        const random = sim.fault_prng.random();
        const count = sim.n();
        @memset(&sim.partition, false);
        switch (sim.options.partition_mode) {
            .isolate_single => sim.partition[random.uintLessThan(u8, count)] = true,
            .uniform_size => {
                const size = random.intRangeAtMost(u8, 1, count - 1);
                var order: [nodes_max]u8 = .{ 0, 1, 2, 3, 4 };
                random.shuffleWithIndex(u8, order[0..count], u32);
                for (order[0..size]) |node| sim.partition[node] = true;
            },
        }
        // Symmetric split between replicas. Clients can reach everyone.
        for (0..count) |a| for (0..count) |b| {
            sim.links[a][b] = sim.partition[a] == sim.partition[b];
        };
        sim.partition_active = true;
        sim.stability = sim.options.partition_stability;
        sim.phase_event('P');
    }

    fn heal_network(sim: *Simulator) void {
        sim.links = @splat(@splat(true));
        sim.partition_active = false;
        sim.stability = sim.options.partition_stability;
        sim.phase_event('H');
    }

    // ---- Crash / restart -------------------------------------------------------------------

    fn crash(sim: *Simulator, i: u8) void {
        const node = &sim.nodes[i];
        assert(node.up);
        // Wipe everything volatile; keep the persistent fields and the node's PRNG.
        node.* = .{
            .id = node.id,
            .up = false,
            .prng = node.prng,
            .current_term = node.current_term,
            .voted_for = node.voted_for,
            .log = node.log,
        };
        sim.event(i, '!');
    }

    fn restart(sim: *Simulator, i: u8) void {
        const node = &sim.nodes[i];
        assert(!node.up);
        node.up = true;
        node.arm_election_timer(sim.tick);
        sim.event(i, '^');
    }

    fn inject_faults(sim: *Simulator) void {
        if (sim.stability > 0) {
            sim.stability -= 1;
        } else if (sim.partition_active) {
            if (chance(&sim.fault_prng, sim.options.unpartition_probability, 10_000)) sim.heal_network();
        } else {
            if (chance(&sim.fault_prng, sim.options.partition_probability, 10_000)) sim.partition_network();
        }
        for (0..sim.n()) |i| {
            if (sim.nodes[i].up) {
                if (chance(&sim.fault_prng, sim.options.crash_probability, 100_000)) sim.crash(@intCast(i));
            } else {
                if (chance(&sim.fault_prng, sim.options.restart_probability, 1_000)) sim.restart(@intCast(i));
            }
        }
    }

    // ---- Election --------------------------------------------------------------------------

    fn round_find(sim: *Simulator, term: u64) ?*Round {
        var k = sim.rounds.items.len;
        while (k > 0) : (k -= 1) {
            if (sim.rounds.items[k - 1].term == term) return &sim.rounds.items[k - 1];
        }
        return null;
    }

    /// Bookkeeping for the liveness diagnosis only (never read by the protocol). In the liveness
    /// phase only core nodes are recorded: a cut-off node elects itself in its own world.
    fn round_for(sim: *Simulator, term: u64) *Round {
        if (sim.round_find(term)) |r| return r;
        sim.rounds.append(sim.gpa, .{ .term = term, .first_tick = sim.tick, .last_tick = sim.tick }) catch @panic("OOM");
        return &sim.rounds.items[sim.rounds.items.len - 1];
    }

    /// Raft's universal rule: seeing a higher term makes you a follower in that term.
    /// Like etcd's becomeFollower, stepping down also re-arms the election timer. That is a
    /// SHARED EVENT: one broadcast of a higher term re-arms many timers in the same tick.
    fn observe_term(sim: *Simulator, node: *Node, term: u64) void {
        if (term <= node.current_term) return;
        node.current_term = term;
        node.voted_for = none;
        node.role = .follower;
        node.leader = none;
        node.votes = .empty;
        node.arm_election_timer(sim.tick);
        sim.event(node.id, '>');
    }

    fn request_vote(sim: *Simulator, node: *Node, to: u8) void {
        sim.send(.{
            .from = node.id,
            .to = to,
            .kind = .request_vote,
            .term = node.current_term,
            .index = node.last_index(),
            .log_term = node.term_at(node.last_index()),
        });
    }

    fn start_election(sim: *Simulator, node: *Node) void {
        node.current_term += 1;
        node.role = .candidate;
        node.leader = none;
        node.voted_for = node.id;
        node.votes = .empty;
        node.votes.set(node.id);
        node.arm_election_timer(sim.tick);
        node.next_vote_retry = sim.tick + request_vote_retry;
        sim.event(node.id, '?');
        for (0..sim.n()) |to| if (to != node.id) sim.request_vote(node, @intCast(to));
        sim.maybe_become_leader(node);
    }

    fn maybe_become_leader(sim: *Simulator, node: *Node) void {
        if (node.role != .candidate) return;
        if (node.votes.count() < sim.quorum()) return;
        node.role = .leader;
        node.leader = node.id;
        node.next_index = @splat(node.last_index() + 1);
        node.match_index = @splat(0);
        node.match_index[node.id] = node.last_index();
        sim.event(node.id, '*');
        // The no-op: entries from older terms can only commit together with one of ours.
        sim.append_local(node, .{ .term = node.current_term, .client = none, .request = 0 });
        sim.replicate(node);
    }

    // ---- Replication -----------------------------------------------------------------------

    fn append_local(sim: *Simulator, node: *Node, entry: Entry) void {
        node.log.append(sim.gpa, entry) catch @panic("OOM");
        node.match_index[node.id] = node.last_index();
    }

    fn send_append(sim: *Simulator, node: *Node, to: u8) void {
        const next = node.next_index[to];
        assert(next >= 1 and next <= node.last_index() + 1);
        var m: Message = .{
            .from = node.id,
            .to = to,
            .kind = .append,
            .term = node.current_term,
            .index = next - 1,
            .log_term = node.term_at(next - 1),
            .commit = node.commit,
        };
        while (m.entry_count < entries_max and next + m.entry_count <= node.last_index()) {
            m.entries[m.entry_count] = node.log.items[next - 1 + m.entry_count];
            m.entry_count += 1;
        }
        sim.send(m);
    }

    fn replicate(sim: *Simulator, node: *Node) void {
        for (0..sim.n()) |to| if (to != node.id) sim.send_append(node, @intCast(to));
        node.next_heartbeat = sim.tick + heartbeat_interval;
    }

    fn advance_commit(sim: *Simulator, node: *Node) void {
        var index = node.last_index();
        while (index > node.commit) : (index -= 1) {
            // Raft: only entries of the leader's own term are committed by counting replicas.
            if (node.term_at(index) != node.current_term) break;
            var count: u8 = 0;
            for (0..sim.n()) |k| {
                if (node.match_index[k] >= index) count += 1;
            }
            if (count >= sim.quorum()) {
                node.commit = index;
                break;
            }
        }
        sim.apply(node);
    }

    fn apply(sim: *Simulator, node: *Node) void {
        while (node.applied < node.commit) {
            node.applied += 1;
            const e = node.log.items[node.applied - 1];
            if (e.client != none and e.request > node.sessions[e.client]) {
                node.sessions[e.client] = e.request;
                node.counter += 1;
            }
            sim.check_commit(node, node.applied, e);
            if (e.client != none and node.role == .leader) {
                sim.send(.{
                    .from = node.id,
                    .to = sim.n() + e.client,
                    .kind = .reply,
                    .term = node.current_term,
                    .index = node.applied,
                    .client = e.client,
                    .request = e.request,
                    .value = node.counter,
                });
            }
        }
    }

    // ---- Message handling ------------------------------------------------------------------

    fn on_message(sim: *Simulator, m: Message) void {
        sim.hash(.{ sim.tick, m.from, m.to, @backingInt(m.kind), m.term, m.index, m.request });
        if (m.to >= sim.n()) return sim.client_on_message(m.to - sim.n(), m);
        const node = &sim.nodes[m.to];
        if (!node.up) return; // a crashed node's NIC drops everything
        if (m.kind == .request) return sim.on_request(node, m);

        sim.observe_term(node, m.term);
        switch (m.kind) {
            .request_vote => {
                const last_term = node.term_at(node.last_index());
                const up_to_date = m.log_term > last_term or
                    (m.log_term == last_term and m.index >= node.last_index());
                const grant = m.term == node.current_term and up_to_date and
                    (node.voted_for == none or node.voted_for == m.from);
                if (sim.round_find(m.term)) |round| {
                    if (m.term == node.current_term and !up_to_date) round.log_refused.set(node.id);
                }
                if (grant and node.voted_for == none) {
                    node.voted_for = m.from;
                    node.arm_election_timer(sim.tick);
                    sim.event(node.id, 'v');
                }
                sim.send(.{ .from = node.id, .to = m.from, .kind = .vote, .term = node.current_term, .granted = grant });
            },
            .vote => if (node.role == .candidate and m.term == node.current_term and m.granted) {
                node.votes.set(m.from);
                sim.maybe_become_leader(node);
            },
            .append => sim.on_append(node, m),
            .append_reply => if (node.role == .leader and m.term == node.current_term) {
                if (m.granted) {
                    node.match_index[m.from] = @max(node.match_index[m.from], m.index);
                    node.next_index[m.from] = node.match_index[m.from] + 1;
                    sim.advance_commit(node);
                } else {
                    node.next_index[m.from] = @max(1, @min(node.next_index[m.from] - 1, m.index + 1));
                }
            },
            .request, .redirect, .accepted, .reply => unreachable,
        }
    }

    fn on_append(sim: *Simulator, node: *Node, m: Message) void {
        var reply: Message = .{ .from = node.id, .to = m.from, .kind = .append_reply, .term = node.current_term };
        if (m.term < node.current_term) return sim.send(reply);
        // A leader exists for our term: follow it and stay quiet.
        node.role = .follower;
        node.leader = m.from;
        node.votes = .empty;
        node.arm_election_timer(sim.tick);
        if (m.index > node.last_index() or node.term_at(m.index) != m.log_term) {
            reply.index = @min(node.last_index(), m.index -| 1); // retry hint
            return sim.send(reply);
        }
        for (m.entries[0..m.entry_count], 0..) |e, k| {
            const index = m.index + 1 + k;
            if (index <= node.last_index()) {
                if (node.term_at(index) == e.term) continue;
                // Conflict: drop our uncommitted suffix. Truncating a COMMITTED entry would
                // rewrite history; the checker treats that as a safety violation.
                if (index <= node.commit) {
                    sim.fail_prefix(node, index, "truncated a committed entry");
                    return;
                }
                node.log.shrinkRetainingCapacity(index - 1);
                sim.event(node.id, 'x');
            }
            node.log.append(sim.gpa, e) catch @panic("OOM");
        }
        const match = m.index + m.entry_count;
        node.commit = @max(node.commit, @min(m.commit, match));
        sim.apply(node);
        reply.granted = true;
        reply.index = match;
        sim.send(reply);
    }

    fn on_request(sim: *Simulator, node: *Node, m: Message) void {
        const c = m.client;
        var out: Message = .{ .from = node.id, .to = m.from, .kind = .redirect, .term = node.current_term, .client = c, .request = m.request };
        if (node.role != .leader) {
            out.leader_hint = node.leader;
            return sim.send(out);
        }
        // Exactly-once: an applied request is answered from the session table.
        if (node.sessions[c] >= m.request) {
            out.kind = .reply;
            out.index = node.applied;
            out.value = node.counter;
            return sim.send(out);
        }
        // Already in our log (a retry of an accepted request)? Do not append it twice.
        var index: u64 = 0;
        for (node.log.items, 1..) |e, k| {
            if (e.client == c and e.request == m.request) index = k;
        }
        if (index == 0) {
            sim.append_local(node, .{ .term = node.current_term, .client = c, .request = m.request });
            index = node.last_index();
            sim.replicate(node);
        }
        out.kind = .accepted;
        out.index = index;
        out.log_term = node.term_at(index);
        sim.send(out);
    }

    // ---- Clients ---------------------------------------------------------------------------

    fn client_send(sim: *Simulator, c: u8, ev: u8) void {
        const cl = &sim.clients[c];
        cl.deadline = sim.tick + client_timeout;
        cl.last_sent_at = sim.tick;
        sim.client_event(c, ev, cl.request, cl.leader_guess);
        sim.send(.{ .from = sim.n() + c, .to = cl.leader_guess, .kind = .request, .client = c, .request = cl.request });
    }

    fn tick_client(sim: *Simulator, c: u8) void {
        const cl = &sim.clients[c];
        if (cl.inflight) {
            // THE BUG (--bug-no-retry-on-leader-change): "a leader accepted it, so it will be
            // committed; just wait for the reply." True only while that leader stays leader.
            // If it is deposed first, the new leader's log wins and the entry is discarded;
            // no retry ever re-submits it. Nothing wrong is committed — nothing is committed.
            if (bug_no_retry and cl.accepted != null) return;
            if (sim.tick < cl.deadline) return;
            cl.leader_guess = (cl.leader_guess + 1) % sim.n();
            sim.client_send(c, 'R');
        } else if (cl.next_request <= sim.options.requests_per_client and sim.tick >= cl.idle_until) {
            cl.inflight = true;
            cl.request = cl.next_request;
            cl.accepted = null;
            cl.submitted_at = sim.tick;
            sim.client_send(c, 'S');
        }
    }

    fn client_on_message(sim: *Simulator, c: u8, m: Message) void {
        const cl = &sim.clients[c];
        if (!cl.inflight or m.request != cl.request) return; // stale
        switch (m.kind) {
            .redirect => if (m.leader_hint != none and m.leader_hint != cl.leader_guess) {
                cl.leader_guess = m.leader_hint;
                sim.client_send(c, 'R');
            },
            .accepted => {
                cl.accepted = .{ .by = m.from, .term = m.log_term, .index = m.index, .at = sim.tick };
                sim.client_event(c, 'A', cl.request, m.from);
            },
            .reply => {
                cl.inflight = false;
                cl.next_request += 1;
                cl.leader_guess = m.from;
                cl.idle_until = sim.tick + sim.client_prng.random().uintAtMost(u64, sim.options.request_idle_max);
                sim.client_event(c, 'D', cl.request, m.from);
                if (sim.verbose) std.debug.print("{d:>6} c{d} = counter={d} at index {d} after {d} ticks\n", .{
                    sim.tick, c, m.value, m.index, sim.tick - cl.submitted_at,
                });
            },
            else => unreachable,
        }
    }

    fn clients_done(sim: *const Simulator) bool {
        for (sim.clients[0..sim.options.client_count]) |cl| {
            if (cl.inflight or cl.next_request <= sim.options.requests_per_client) return false;
        }
        return true;
    }

    // ---- Timers ----------------------------------------------------------------------------

    fn on_tick(sim: *Simulator, node: *Node) void {
        if (!node.up) return;
        switch (node.role) {
            .leader => if (sim.tick >= node.next_heartbeat) sim.replicate(node),
            .follower, .candidate => if (sim.tick >= node.election_deadline) {
                sim.start_election(node);
            } else if (node.role == .candidate and sim.tick >= node.next_vote_retry) {
                for (0..sim.n()) |peer| {
                    if (!node.votes.isSet(peer)) sim.request_vote(node, @intCast(peer));
                }
                node.next_vote_retry = sim.tick + request_vote_retry;
            },
        }
    }

    // ---- Safety checkers (every tick / every commit, in both phases) ----------------------

    fn fail_prefix(sim: *Simulator, node: *Node, index: u64, what: []const u8) void {
        if (sim.failure != .none) return;
        say("SAFETY VIOLATED: committed prefix rewritten: node {d} {s} at index {d} (tick {d})\n", .{
            node.id, what, index, sim.tick,
        });
        sim.failure = .prefix_rewritten;
    }

    /// Runs on EVERY apply by EVERY node (including re-applies after a restart).
    fn check_commit(sim: *Simulator, node: *Node, index: u64, e: Entry) void {
        sim.hash(.{ sim.tick, node.id, index, e.term, e.client, e.request, node.counter });
        if (index == sim.canonical.items.len + 1) {
            // Exactly-once: the counter counts distinct requests. Checked when index is first
            // committed; later commits must match this record exactly.
            var expected: u64 = if (index == 1) 0 else sim.canonical.items[index - 2].counter;
            if (e.client != none) {
                var seen = false;
                for (sim.canonical.items) |x| {
                    if (x.client == e.client and x.request == e.request) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) expected += 1;
            }
            if (expected != node.counter) {
                say("SAFETY VIOLATED: counter={d} after index {d}, expected {d}\n", .{ node.counter, index, expected });
                sim.failure = .prefix_rewritten;
                return;
            }
            sim.canonical.append(sim.gpa, .{ .term = e.term, .client = e.client, .request = e.request, .counter = node.counter }) catch @panic("OOM");
            return;
        }
        assert(index <= sim.canonical.items.len);
        const canon = sim.canonical.items[index - 1];
        if (canon.term != e.term or canon.client != e.client or canon.request != e.request or canon.counter != node.counter) {
            sim.fail_prefix(node, index, "committed a different entry");
        }
    }

    fn check_election_safety(sim: *Simulator) void {
        for (sim.nodes[0..sim.n()]) |*node| {
            if (!node.up or node.role != .leader) continue;
            var known = false;
            for (sim.term_leaders.items) |entry| {
                if (entry.term != node.current_term) continue;
                known = true;
                if (entry.node != node.id) {
                    say("SAFETY VIOLATED: term {d} has two leaders: node {d} and node {d} (tick {d})\n", .{
                        node.current_term, entry.node, node.id, sim.tick,
                    });
                    sim.failure = .election_safety;
                    return;
                }
                break;
            }
            if (!known) sim.term_leaders.append(sim.gpa, .{ .term = node.current_term, .node = node.id }) catch @panic("OOM");
        }
    }

    // ---- Liveness --------------------------------------------------------------------------

    /// Like vopr.zig transition_to_liveness_mode: restart down core nodes, heal the core's
    /// links, cut non-core nodes off for good, stop crashes and loss. Safety checks continue.
    fn transition_to_liveness_mode(sim: *Simulator) void {
        var order: [nodes_max]u8 = .{ 0, 1, 2, 3, 4 };
        const random = sim.fault_prng.random();
        random.shuffleWithIndex(u8, order[0..sim.n()], u32);
        const size = random.intRangeAtMost(u8, sim.quorum(), sim.n());
        for (order[0..size]) |i| sim.core.set(i);
        sim.heal_tick = sim.tick;
        sim.partition_active = false;
        for (0..addresses_max) |a| for (0..addresses_max) |b| {
            const a_ok = a >= sim.n() or sim.in_core(a);
            const b_ok = b >= sim.n() or sim.in_core(b);
            sim.links[a][b] = a == b or (a_ok and b_ok);
        };
        sim.phase_event('L');
        for (0..sim.n()) |i| if (sim.in_core(i) and !sim.nodes[i].up) sim.restart(@intCast(i));
        sim.stats.term_at_heal = sim.max_core_term();
    }

    fn max_core_term(sim: *const Simulator) u64 {
        var term: u64 = 0;
        for (0..sim.n()) |i| if (sim.in_core(i)) {
            term = @max(term, sim.nodes[i].current_term);
        };
        return term;
    }

    /// The whole core is up, in one term, following one leader that is in the core.
    fn stable_leader(sim: *const Simulator) ?u8 {
        var leader: u8 = none;
        for (0..sim.n()) |i| if (sim.in_core(i) and sim.nodes[i].up and sim.nodes[i].role == .leader) {
            if (leader != none) return null;
            leader = @intCast(i);
        };
        if (leader == none) return null;
        const term = sim.nodes[leader].current_term;
        for (0..sim.n()) |i| if (sim.in_core(i)) {
            const node = &sim.nodes[i];
            if (!node.up or node.current_term != term or node.leader != leader) return null;
        };
        return leader;
    }

    fn converged(sim: *const Simulator) bool {
        const leader = sim.stable_leader() orelse return false;
        if (!sim.clients_done()) return false;
        const l = &sim.nodes[leader];
        if (l.commit != l.last_index()) return false;
        for (0..sim.n()) |i| if (sim.in_core(i) and sim.nodes[i].applied != l.commit) return false;
        return true;
    }

    /// cf. vopr.zig cluster_recoverable(): before blaming the code, make sure the core COULD
    /// make progress. A core that is not a quorum, or whose links are cut, is the simulator's
    /// fault, not a bug. (By construction here the answer is always yes; the check documents
    /// and asserts the precondition, the way core_missing_quorum() does.)
    fn cluster_recoverable(sim: *const Simulator) bool {
        if (sim.core.count() < sim.quorum()) return false;
        for (0..sim.n()) |a| if (sim.in_core(a)) {
            if (!sim.nodes[a].up) return false;
            for (0..sim.n()) |b| if (sim.in_core(b) and !sim.links[a][b]) return false;
        };
        return true;
    }

    fn compute_stats(sim: *Simulator) void {
        sim.stats.term_end = sim.max_core_term();
        sim.stats.rounds = 0;
        sim.stats.splits = 0;
        sim.stats.simultaneous = 0;
        sim.stats.refused = 0;
        const current = sim.stats.term_end;
        for (sim.rounds.items) |r| {
            if (r.first_tick < sim.heal_tick) continue;
            sim.stats.rounds += 1;
            if (r.leader != none or r.term == current) continue; // won, or still open
            if (r.candidates.count() >= 2) {
                sim.stats.splits += 1;
                if (r.last_tick - r.first_tick < simultaneous_window) sim.stats.simultaneous += 1;
            } else sim.stats.refused += 1;
        }
        sim.stats.max_pending = 0;
        for (sim.clients[0..sim.options.client_count]) |cl| {
            if (cl.inflight) sim.stats.max_pending = @max(sim.stats.max_pending, sim.tick - cl.submitted_at);
        }
    }

    /// Explain WHY there was no progress, not just that there was none.
    fn diagnose(sim: *Simulator) Failure {
        sim.compute_stats();
        const s = sim.stats;
        say("cluster_recoverable: {s} (core={d}/{d} nodes, quorum={d}, all up, all core links healthy)\n", .{
            if (sim.cluster_recoverable()) "yes" else "NO", sim.core.count(), sim.n(), sim.quorum(),
        });
        if (sim.stable_leader() == null) {
            say(
                "LIVENESS VIOLATED: no stable leader {d} ticks after heal: terms advanced {d}->{d} during the convergence window with no leader elected\n",
                .{ convergence_ticks, s.term_at_heal, s.term_end },
            );
            say("  {d} election rounds: {d} split votes ({d} simultaneous: all candidates timed out within {d} ticks, before any RequestVote could arrive), {d} lone candidates refused by a voter with a longer log\n", .{
                s.rounds, s.splits, s.simultaneous, simultaneous_window, s.refused,
            });
            // Show the last few rounds: who stood, and when.
            const first = sim.rounds.items.len -| 6;
            for (sim.rounds.items[first..]) |r| {
                say("  term {d}: timed out at ticks {d}..{d}, quorum {d}, votes:", .{ r.term, r.first_tick, r.last_tick, sim.quorum() });
                var buf: [2 * nodes_max]u8 = undefined;
                for (0..sim.n()) |k| if (r.candidates.isSet(k)) {
                    say(" {d}<-{{{s}}}", .{ k, sim.node_list(&buf, r.votes[k], ",") });
                };
                if (r.log_refused.mask != 0) say(" refused-for-log:{{{s}}}", .{sim.node_list(&buf, r.log_refused, ",")});
                say(" leader={s}\n", .{if (r.leader == none) "none" else "elected"});
            }
            return .no_stable_leader;
        }
        var stuck = false;
        for (sim.clients[0..sim.options.client_count], 0..) |cl, c| {
            if (!cl.inflight) continue;
            stuck = true;
            say("LIVENESS VIOLATED: request c{d}#{d} pending for {d} ticks (submitted at tick {d}, last sent at tick {d})\n", .{
                c, cl.request, sim.tick - cl.submitted_at, cl.submitted_at, cl.last_sent_at,
            });
            if (cl.accepted) |a| {
                say("  accepted by node {d} in term {d} as index {d} at tick {d}; ", .{ a.by, a.term, a.index, a.at });
                var committed_at: u64 = 0;
                for (sim.canonical.items, 1..) |x, k| {
                    if (x.client == c and x.request == cl.request) committed_at = k;
                }
                if (committed_at != 0) {
                    say("it committed as index {d}, but the reply never arrived and the client never asked again\n", .{committed_at});
                } else if (a.index <= sim.canonical.items.len) {
                    const x = sim.canonical.items[a.index - 1];
                    say("index {d} was committed with a term-{d} {s} instead: the entry was discarded by a later leader, and the client never re-sent it\n", .{
                        a.index, x.term, if (x.client == none) "no-op" else "entry",
                    });
                } else {
                    say("the entry is in no committed log (commit={d}); the client never re-sent it\n", .{sim.canonical.items.len});
                }
            }
        }
        if (stuck) return .request_stuck;
        say("LIVENESS VIOLATED: core replicas did not catch up to the leader's commit\n", .{});
        return .not_caught_up;
    }

    fn step(sim: *Simulator) void {
        if (!sim.liveness_mode()) sim.inject_faults();
        // Deliver due messages in send order (ordered removal keeps this deterministic).
        var i: usize = 0;
        while (i < sim.messages.items.len) {
            if (sim.messages.items[i].deliver_at <= sim.tick) {
                sim.on_message(sim.messages.orderedRemove(i));
                if (sim.failure != .none) return;
            } else i += 1;
        }
        for (sim.nodes[0..sim.n()]) |*node| sim.on_tick(node);
        for (0..sim.options.client_count) |c| sim.tick_client(@intCast(c));
        sim.check_election_safety();
    }

    fn run(sim: *Simulator) Failure {
        // Phase 1: safety. Everything may fail.
        while (sim.tick < fault_ticks) : (sim.tick += 1) {
            sim.step();
            if (sim.failure != .none) return sim.failure;
        }
        // Phase 2: liveness. Heal a core and demand progress within a bound.
        sim.transition_to_liveness_mode();
        while (sim.tick < fault_ticks + convergence_ticks) : (sim.tick += 1) {
            sim.step();
            if (sim.failure != .none) return sim.failure;
            if (sim.stats.ticks_to_leader == null) if (sim.stable_leader()) |leader| {
                sim.stats.ticks_to_leader = sim.tick - sim.heal_tick;
                sim.hash(.{ sim.tick, 0x5AB1E });
                if (sim.verbose) std.debug.print("{d:>6} - stable leader: node {d} in term {d}, {d} ticks after heal\n", .{
                    sim.tick, leader, sim.nodes[leader].current_term, sim.tick - sim.heal_tick,
                });
            };
            if (sim.converged()) {
                sim.compute_stats();
                if (sim.verbose) std.debug.print("{d:>6} - converged: every request committed and applied by the core, {d} ticks after heal\n", .{
                    sim.tick, sim.tick - sim.heal_tick,
                });
                return .none;
            }
        }
        assert(sim.cluster_recoverable());
        return sim.diagnose();
    }

    /// Both outcomes: even when liveness failed, report that safety held the whole time.
    fn report_safety(sim: *const Simulator) void {
        var max_term: u64 = 0;
        for (sim.term_leaders.items) |e| max_term = @max(max_term, e.term);
        std.debug.print("safety: OK: election safety held ({d} leaders, at most one per term, highest led term {d}); committed prefix of {d} entries never rewritten; counter exactly-once\n", .{
            sim.term_leaders.items.len, max_term, sim.canonical.items.len,
        });
    }
};

fn run_seed(gpa: std.mem.Allocator, seed: u64, verbose: bool) Result {
    var sim = Simulator.init(gpa, seed, verbose);
    defer sim.deinit();
    if (verbose) {
        const o = sim.options;
        std.debug.print(
            \\seed={d} nodes={d} clients={d} requests_per_client={d} election_timeout={d}..{d}
            \\  partition_mode={s} partition_probability={d}/10000 unpartition_probability={d}/10000 partition_stability={d}
            \\  crash_probability={d}/100000 restart_probability={d}/1000 loss={d}/1000 delay={d}..{d}
            \\  safety phase: ticks 0..{d}; liveness window: {d} ticks
            \\  tick node event role [cluster] term votedFor leader commit/log
            \\
        , .{
            seed,                       o.node_count,                               o.client_count,
            o.requests_per_client,      election_timeout_mean - timeout_spread / 2, election_timeout_mean - timeout_spread / 2 + timeout_spread,
            @tagName(o.partition_mode), o.partition_probability,                    o.unpartition_probability,
            o.partition_stability,      o.crash_probability,                        o.restart_probability,
            o.loss_probability,         o.delay_min,                                o.delay_max,
            fault_ticks,                convergence_ticks,
        });
    }
    const failure = sim.run();
    if (verbose and (failure == .none or failure == .no_stable_leader or failure == .request_stuck or failure == .not_caught_up)) {
        sim.report_safety();
    }
    return .{
        .failure = failure,
        .trace_hash = sim.trace.final(),
        .ticks = sim.tick,
        .stats = sim.stats,
        .nodes = sim.n(),
        .core = sim.core.count(),
    };
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse "sweep";
    const count = try std.fmt.parseInt(u64, args.next() orelse "20000", 10);
    var spread_set = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bug-fixed-timeout")) {
            bug_fixed_timeout = true;
        } else if (std.mem.eql(u8, arg, "--bug-no-retry-on-leader-change")) {
            bug_no_retry = true;
        } else if (std.mem.cutPrefix(u8, arg, "--spread=")) |value| {
            timeout_spread = try std.fmt.parseInt(u64, value, 10);
            if (timeout_spread > 2 * (election_timeout_mean - heartbeat_interval)) {
                std.debug.print("--spread must be at most {d}\n", .{2 * (election_timeout_mean - heartbeat_interval)});
                std.process.exit(2);
            }
            spread_set = true;
        } else {
            std.debug.print("unknown flag: {s}\n", .{arg});
            std.process.exit(2);
        }
    }
    if (bug_fixed_timeout) {
        if (spread_set) {
            std.debug.print("--bug-fixed-timeout is --spread=0; pass only one\n", .{});
            std.process.exit(2);
        }
        timeout_spread = 0;
    }
    if (std.mem.eql(u8, mode, "run")) {
        const r = run_seed(init.gpa, count, true);
        std.debug.print("seed={d} ticks={d} trace={x:0>16} {s}{s}{s}\n", .{
            count,                                      r.ticks,                             r.trace_hash,
            if (r.failure == .none) "PASS" else "FAIL", if (r.failure == .none) "" else " ", if (r.failure == .none) "" else @tagName(r.failure),
        });
        if (r.failure != .none) std.process.exit(1);
        return;
    }

    if (std.mem.eql(u8, mode, "stats")) {
        stats_mode = true;
        // One line per seed, for the site's charts. Columns:
        std.debug.print("seed\tnodes\tcore\tresult\tticks_to_leader\trounds\tsplits\tsimultaneous\trefused\tterm_at_heal\tterm_end\tmax_pending\n", .{});
        var seed: u64 = 0;
        while (seed < count) : (seed += 1) {
            const r = run_seed(init.gpa, seed, false);
            const s = r.stats;
            std.debug.print("{d}\t{d}\t{d}\t{s}\t", .{ seed, r.nodes, r.core, @tagName(r.failure) });
            if (s.ticks_to_leader) |t| std.debug.print("{d}", .{t}) else std.debug.print("-", .{});
            std.debug.print("\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
                s.rounds, s.splits, s.simultaneous, s.refused, s.term_at_heal, s.term_end, s.max_pending,
            });
        }
        return;
    }

    var seed: u64 = 0;
    while (seed < count) : (seed += 1) {
        const r = run_seed(init.gpa, seed, false);
        if (r.failure != .none) {
            std.debug.print("FAIL at seed={d} ({s}) after {d} seeds. Replay with:\n", .{
                seed, @tagName(r.failure), seed + 1,
            });
            std.debug.print("  zig run main.zig -- run {d}{s}{s}\n", .{
                seed,
                if (bug_fixed_timeout) " --bug-fixed-timeout" else "",
                if (bug_no_retry) " --bug-no-retry-on-leader-change" else "",
            });
            std.process.exit(1);
        }
    }
    std.debug.print("PASS: {d} seeds\n", .{count});
}
