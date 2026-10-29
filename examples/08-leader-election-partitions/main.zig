//! Example 08 — Leader election under partitions and crashes.
//!
//! System under test: a Raft-style leader election (RequestVote with term + votedFor,
//! heartbeats, randomized election timeouts) among 3–5 nodes. The node count comes from the seed.
//!
//! What the simulator controls (all from one seed):
//!   - the network: per-message delay, packet loss, and *partitions* modeled on TigerBeetle's
//!     PacketSimulator (src/testing/packet_simulator.zig): a PartitionMode (isolate_single,
//!     uniform_size, uniform_partition), a PartitionSymmetry (symmetric/asymmetric), and
//!     partition_stability / unpartition_stability (minimum ticks a partition / a healthy network
//!     lasts before it may change again);
//!   - the nodes: crash at any tick, restart later. A crash wipes every volatile field; only
//!     what the node wrote to its (simulated) disk survives, like Cluster.replica_crash in
//!     src/testing/cluster.zig, which leaves storage untouched and resets the replica;
//!   - time: a tick counter. Each node draws its election timeouts from its own seeded PRNG.
//!
//! Checked on EVERY tick (not only at the end):
//!   - Election Safety: at most one leader per term, ever. The checker remembers who led each
//!     term, so two leaders of the same term are caught even if they never overlap in time.
//!   - currentTerm never decreases for any node, including across crash/restart.
//! Checked after the faults heal (the VOPR's "liveness mode"):
//!   - Liveness: within a bounded number of ticks, all nodes agree on one leader in one term.
//!
//! Planted bugs:
//!   --bug-volatile-vote  votedFor is kept only in memory. A node votes for A in term t, crashes,
//!                        restarts with votedFor=null and votes for B in the same term t.
//!   --bug-no-quorum      a candidate wins with a majority of the nodes it has *heard from
//!                        recently* instead of a majority of ALL nodes. Under a partition (or
//!                        after a crash) both sides can elect a leader: split brain.
//!
//! Usage:
//!   zig run main.zig -- run   <seed>  [--bug-volatile-vote] [--bug-no-quorum]
//!   zig run main.zig -- sweep <count> [--bug-volatile-vote] [--bug-no-quorum]
const std = @import("std");
const assert = std.debug.assert;

var bug_volatile_vote = false;
var bug_no_quorum = false;

const nodes_max = 5;
const none: u8 = 0xff;

// Protocol timing (ticks). Election timeouts are drawn per node from [min, max].
const election_timeout_min = 20;
const election_timeout_max = 40;
const heartbeat_interval = 5;
const request_vote_retry = 6;
/// --bug-no-quorum only: a peer counts as "reachable" if we heard from it this recently
/// (a typical failure detector). At boot every peer is assumed reachable.
const reachable_window = 100;

// Simulation phases.
const fault_ticks = 3000;
/// After healing, a stable leader must appear within this many ticks (~15 election timeouts).
const liveness_bound = 600;

// ---------------------------------------------------------------------------------------------
// Messages and network
// ---------------------------------------------------------------------------------------------

const Kind = enum(u8) { request_vote, request_vote_reply, heartbeat, heartbeat_reply };

const Message = struct {
    deliver_at: u64,
    from: u8,
    to: u8,
    kind: Kind,
    term: u64,
    granted: bool,
};

/// Same three modes as TigerBeetle's PartitionMode (minus `.none`, which we model as "no
/// partition probability"). There are always exactly two sides.
const PartitionMode = enum { isolate_single, uniform_size, uniform_partition };
/// Asymmetric: one side can still SEND to the other but cannot receive from it. This is the
/// nasty case: a node that can talk but cannot listen keeps starting elections.
const PartitionSymmetry = enum { symmetric, asymmetric };

const Options = struct {
    node_count: u8,
    partition_mode: PartitionMode,
    partition_symmetry: PartitionSymmetry,
    partition_probability: u32, // per 10_000 ticks
    unpartition_probability: u32, // per 10_000 ticks
    partition_stability: u32,
    unpartition_stability: u32,
    crash_probability: u32, // per node, per 100_000 ticks
    restart_probability: u32, // per down node, per 1_000 ticks
    loss_probability: u32, // per 1_000 messages
    delay_max: u8, // delay is uniform in [1, delay_max]

    fn generate(random: std.Random) Options {
        return .{
            .node_count = 3 + random.uintAtMost(u8, 2),
            .partition_mode = random.enumValueWithIndex(PartitionMode, u32),
            .partition_symmetry = random.enumValueWithIndex(PartitionSymmetry, u32),
            .partition_probability = 50 + random.uintAtMost(u32, 150),
            .unpartition_probability = 100 + random.uintAtMost(u32, 400),
            .partition_stability = 50 + random.uintAtMost(u32, 150),
            .unpartition_stability = random.uintAtMost(u32, 50),
            .crash_probability = 50 + random.uintAtMost(u32, 400),
            .restart_probability = 20 + random.uintAtMost(u32, 200),
            .loss_probability = random.uintAtMost(u32, 100),
            .delay_max = 1 + random.uintAtMost(u8, 4),
        };
    }
};

// ---------------------------------------------------------------------------------------------
// Node: the system under test
// ---------------------------------------------------------------------------------------------

const Role = enum(u8) { follower, candidate, leader };

/// The only thing that survives a crash. Writes are synchronous and atomic in this simulation
/// (a later example can make them torn/lost, like TigerBeetle's simulated Storage).
const Disk = struct { current_term: u64 = 0, voted_for: u8 = none };

const Node = struct {
    id: u8,
    up: bool = true,
    disk: Disk = .{},
    /// The node's own clock jitter: election timeouts come from here.
    prng: std.Random.DefaultPrng,

    // Volatile state: reset by a crash, reloaded (term/vote) from `disk` on restart.
    current_term: u64 = 0,
    voted_for: u8 = none,
    role: Role = .follower,
    leader: u8 = none,
    votes: u8 = 0, // bitset of nodes that granted us a vote in current_term
    election_deadline: u64 = 0,
    next_heartbeat: u64 = 0,
    next_vote_retry: u64 = 0,
    last_heard: [nodes_max]u64 = @splat(0), // tick we last received anything from each peer

    fn reset_election_timer(node: *Node, now: u64) void {
        node.election_deadline = now +
            node.prng.random().intRangeAtMost(u64, election_timeout_min, election_timeout_max);
    }

    /// Persist before acting on (or advertising) any change to term/vote. TigerBeetle's
    /// equivalent rule: a replica must not advertise a view higher than its durable view
    /// (Replica.view_durable / view_durable_update in src/vsr/replica.zig).
    fn persist(node: *Node) void {
        node.disk.current_term = node.current_term;
        // THE BUG: votedFor never reaches the disk, so a restart forgets who we voted for.
        node.disk.voted_for = if (bug_volatile_vote) none else node.voted_for;
    }
};

// ---------------------------------------------------------------------------------------------
// Simulator
// ---------------------------------------------------------------------------------------------

const Failure = enum { none, election_safety, term_regressed, liveness };

const Result = struct { failure: Failure, trace_hash: u64, ticks: u64 };

const Simulator = struct {
    gpa: std.mem.Allocator,
    options: Options,
    verbose: bool,
    nodes: [nodes_max]Node,
    tick: u64 = 0,
    trace: std.hash.Wyhash = std.hash.Wyhash.init(0),

    // Network state. `links[from][to]` is false while a partition filters that path.
    fault_prng: std.Random.DefaultPrng,
    net_prng: std.Random.DefaultPrng,
    messages: std.ArrayList(Message) = .empty,
    links: [nodes_max][nodes_max]bool = @splat(@splat(true)),
    partition: [nodes_max]bool = @splat(false),
    partition_active: bool = false,
    asymmetric_side: bool = false,
    stability: u32 = 0,
    faults_enabled: bool = true,

    // Checker state. A plain list (not a hash map) so nothing depends on iteration order.
    term_leaders: std.ArrayList(struct { term: u64, node: u8 }) = .empty,
    term_seen: [nodes_max]u64 = @splat(0),

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
        };
        for (&sim.nodes, 0..) |*node, i| {
            node.* = .{ .id = @intCast(i), .prng = std.Random.DefaultPrng.init(random.int(u64)) };
            node.reset_election_timer(0);
        }
        sim.trace.update(std.mem.asBytes(&options));
        return sim;
    }

    fn deinit(sim: *Simulator) void {
        sim.messages.deinit(sim.gpa);
        sim.term_leaders.deinit(sim.gpa);
    }

    fn n(sim: *const Simulator) u8 {
        return sim.options.node_count;
    }

    fn quorum(sim: *const Simulator) u8 {
        return sim.n() / 2 + 1;
    }

    fn chance(prng: *std.Random.DefaultPrng, numerator: u32, denominator: u32) bool {
        return prng.random().uintLessThan(u32, denominator) < numerator;
    }

    // ---- Event log, VOPR-style -------------------------------------------------------------
    //
    //   tick node event role [cluster] term votedFor leader net
    //
    //   event: ! crash  ^ restart  ? became candidate  * became leader  > adopted higher term
    //          v granted vote  P partition  H heal network  L liveness mode (all faults off)
    //   role:  / leader  \ follower  ? candidate  # crashed      (same symbols as the VOPR)
    //   [cluster]: every node's role symbol, at its index, so you can scan a column.
    //   net:   "ok", or the two sides, e.g. "01|234" (symmetric) or "01>234" (asymmetric: the
    //          left side can send to the right side, but not the other way round).

    fn role_char(node: *const Node) u8 {
        if (!node.up) return '#';
        return switch (node.role) {
            .leader => '/',
            .follower => '\\',
            .candidate => '?',
        };
    }

    fn event(sim: *Simulator, node_index: u8, ev: u8) void {
        var cluster: [nodes_max]u8 = undefined;
        for (sim.nodes[0..sim.n()], 0..) |*node, i| cluster[i] = role_char(node);

        var net_buf: [nodes_max + 1]u8 = undefined;
        var net_len: usize = 0;
        if (!sim.partition_active) {
            @memcpy(net_buf[0..2], "ok");
            net_len = 2;
        } else {
            // Left side: the side that can send in an asymmetric partition.
            const left = if (sim.options.partition_symmetry == .asymmetric) sim.asymmetric_side else true;
            for (0..sim.n()) |i| if (sim.partition[i] == left) {
                net_buf[net_len] = '0' + @as(u8, @intCast(i));
                net_len += 1;
            };
            net_buf[net_len] = if (sim.options.partition_symmetry == .asymmetric) '>' else '|';
            net_len += 1;
            for (0..sim.n()) |i| if (sim.partition[i] != left) {
                net_buf[net_len] = '0' + @as(u8, @intCast(i));
                net_len += 1;
            };
        }

        var term: u64 = 0;
        var voted: u8 = none;
        var leader: u8 = none;
        if (node_index != none) {
            const node = &sim.nodes[node_index];
            term = if (node.up) node.current_term else node.disk.current_term;
            voted = if (node.up) node.voted_for else node.disk.voted_for;
            leader = if (node.up) node.leader else none;
        }
        sim.trace.update(std.mem.asBytes(&[_]u64{ sim.tick, node_index, ev, term, voted, leader }));
        sim.trace.update(cluster[0..sim.n()]);
        sim.trace.update(net_buf[0..net_len]);
        if (!sim.verbose) return;

        if (node_index == none) {
            std.debug.print("{d:>6} - {c} - [{s}]  ---  --  --  net:{s}\n", .{
                sim.tick, ev, cluster[0..sim.n()], net_buf[0..net_len],
            });
        } else {
            std.debug.print("{d:>6} {d} {c} {c} [{s}] {d:>3}T v{c} L{c} net:{s}\n", .{
                sim.tick,                                node_index,                                ev,
                role_char(&sim.nodes[node_index]),       cluster[0..sim.n()],                       term,
                if (voted == none) '-' else '0' + voted, if (leader == none) '-' else '0' + leader, net_buf[0..net_len],
            });
        }
    }

    // ---- Network ---------------------------------------------------------------------------

    fn send(sim: *Simulator, from: u8, to: u8, kind: Kind, term: u64, granted: bool) void {
        // Like PacketSimulator: the link filter applies when a packet is submitted, so packets
        // already in flight when a partition starts can still arrive.
        if (!sim.links[from][to]) return;
        if (sim.faults_enabled and chance(&sim.net_prng, sim.options.loss_probability, 1000)) return;
        const delay = sim.net_prng.random().intRangeAtMost(u64, 1, sim.options.delay_max);
        sim.messages.append(sim.gpa, .{
            .deliver_at = sim.tick + delay,
            .from = from,
            .to = to,
            .kind = kind,
            .term = term,
            .granted = granted,
        }) catch @panic("OOM");
    }

    fn broadcast(sim: *Simulator, from: u8, kind: Kind, term: u64) void {
        for (0..sim.n()) |to| if (to != from) sim.send(from, @intCast(to), kind, term, false);
    }

    /// Mirrors PacketSimulator.auto_partition_network: choose two sides, then filter links.
    fn partition_network(sim: *Simulator) void {
        const random = sim.fault_prng.random();
        const count = sim.n();
        switch (sim.options.partition_mode) {
            .isolate_single => {
                @memset(&sim.partition, false);
                sim.partition[random.uintLessThan(u8, count)] = true;
            },
            .uniform_size => {
                const size = random.intRangeAtMost(u8, 1, count - 1);
                var order: [nodes_max]u8 = .{ 0, 1, 2, 3, 4 };
                random.shuffleWithIndex(u8, order[0..count], u32);
                @memset(&sim.partition, false);
                for (order[0..count], 0..) |node, i| sim.partition[node] = i < size;
            },
            .uniform_partition => {
                var all_same = true;
                for (0..count) |i| {
                    sim.partition[i] = random.boolean();
                    if (i > 0 and sim.partition[i] != sim.partition[i - 1]) all_same = false;
                }
                if (all_same) {
                    const i = random.uintLessThan(u8, count);
                    sim.partition[i] = !sim.partition[i];
                }
            },
        }
        sim.asymmetric_side = random.boolean();
        for (0..count) |from| for (0..count) |to| {
            sim.links[from][to] = sim.partition[from] == sim.partition[to] or
                (sim.options.partition_symmetry == .asymmetric and
                    sim.partition[from] == sim.asymmetric_side);
        };
        sim.partition_active = true;
        sim.stability = sim.options.partition_stability;
        sim.event(none, 'P');
    }

    fn heal_network(sim: *Simulator) void {
        sim.links = @splat(@splat(true));
        sim.partition = @splat(false);
        sim.partition_active = false;
        sim.stability = sim.options.unpartition_stability;
        sim.event(none, 'H');
    }

    // ---- Crash / restart ------------------------------------------------------------------

    fn crash(sim: *Simulator, i: u8) void {
        const node = &sim.nodes[i];
        assert(node.up);
        // Wipe everything volatile; keep the disk and the node's PRNG ("its hardware").
        node.* = .{ .id = node.id, .up = false, .disk = node.disk, .prng = node.prng };
        sim.event(i, '!');
    }

    fn restart(sim: *Simulator, i: u8) void {
        const node = &sim.nodes[i];
        assert(!node.up);
        node.up = true;
        node.current_term = node.disk.current_term;
        node.voted_for = node.disk.voted_for;
        node.role = .follower;
        node.last_heard = @splat(sim.tick); // optimistic failure detector: assume all reachable
        node.reset_election_timer(sim.tick);
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

    // ---- Protocol --------------------------------------------------------------------------

    /// Raft's universal rule: seeing a higher term makes you a follower in that term.
    fn observe_term(sim: *Simulator, node: *Node, term: u64) void {
        if (term <= node.current_term) return;
        node.current_term = term;
        node.voted_for = none;
        node.role = .follower;
        node.leader = none;
        node.votes = 0;
        node.persist();
        sim.event(node.id, '>');
    }

    fn start_election(sim: *Simulator, node: *Node) void {
        node.current_term += 1;
        node.role = .candidate;
        node.leader = none;
        node.voted_for = node.id;
        node.votes = @as(u8, 1) << @intCast(node.id);
        node.persist();
        node.reset_election_timer(sim.tick);
        node.next_vote_retry = sim.tick + request_vote_retry;
        sim.event(node.id, '?');
        sim.broadcast(node.id, .request_vote, node.current_term);
        sim.maybe_become_leader(node);
    }

    fn votes_needed(sim: *const Simulator, node: *const Node) u8 {
        if (!bug_no_quorum) return sim.quorum(); // a majority of ALL nodes, reachable or not
        // THE BUG: "a majority of the nodes I can currently reach". Under a partition each side
        // sees itself as the whole cluster, so each side can elect its own leader.
        var reachable: u8 = 1;
        for (0..sim.n()) |peer| {
            if (peer == node.id) continue;
            if (node.last_heard[peer] + reachable_window >= sim.tick) reachable += 1;
        }
        return reachable / 2 + 1;
    }

    fn maybe_become_leader(sim: *Simulator, node: *Node) void {
        if (node.role != .candidate) return;
        if (@popCount(node.votes) < sim.votes_needed(node)) return;
        node.role = .leader;
        node.leader = node.id;
        sim.event(node.id, '*');
        sim.broadcast(node.id, .heartbeat, node.current_term);
        node.next_heartbeat = sim.tick + heartbeat_interval;
    }

    fn on_message(sim: *Simulator, m: Message) void {
        const node = &sim.nodes[m.to];
        if (!node.up) return; // a crashed node's NIC drops everything
        node.last_heard[m.from] = sim.tick;
        sim.trace.update(std.mem.asBytes(&[_]u64{ sim.tick, m.from, m.to, @backingInt(m.kind), m.term }));

        sim.observe_term(node, m.term);
        switch (m.kind) {
            .request_vote => {
                const grant = m.term == node.current_term and
                    (node.voted_for == none or node.voted_for == m.from);
                if (grant and node.voted_for == none) {
                    node.voted_for = m.from;
                    node.persist(); // persist the vote BEFORE the reply leaves the node
                    node.reset_election_timer(sim.tick);
                    sim.event(node.id, 'v');
                }
                sim.send(node.id, m.from, .request_vote_reply, node.current_term, grant);
            },
            .request_vote_reply => {
                if (node.role == .candidate and m.term == node.current_term and m.granted) {
                    node.votes |= @as(u8, 1) << @intCast(m.from);
                    sim.maybe_become_leader(node);
                }
            },
            .heartbeat => {
                if (m.term == node.current_term) {
                    // A leader exists for our term. (Two leaders in one term is exactly what the
                    // checker is for; the node itself just follows the newest heartbeat.)
                    if (node.role != .leader) {
                        node.role = .follower;
                        node.leader = m.from;
                        node.votes = 0;
                    }
                    node.reset_election_timer(sim.tick);
                }
                sim.send(node.id, m.from, .heartbeat_reply, node.current_term, false);
            },
            .heartbeat_reply => {}, // its term was handled by observe_term
        }
    }

    fn on_tick(sim: *Simulator, node: *Node) void {
        if (!node.up) return;
        switch (node.role) {
            .leader => if (sim.tick >= node.next_heartbeat) {
                sim.broadcast(node.id, .heartbeat, node.current_term);
                node.next_heartbeat = sim.tick + heartbeat_interval;
            },
            .follower, .candidate => if (sim.tick >= node.election_deadline) {
                sim.start_election(node);
            } else if (node.role == .candidate and sim.tick >= node.next_vote_retry) {
                // Retry RequestVote to peers that have not granted yet (lost/partitioned/crashed).
                for (0..sim.n()) |peer| {
                    if ((node.votes >> @intCast(peer)) & 1 == 0) {
                        sim.send(node.id, @intCast(peer), .request_vote, node.current_term, false);
                    }
                }
                node.next_vote_retry = sim.tick + request_vote_retry;
            },
        }
    }

    // ---- Invariant checkers (run every tick) -----------------------------------------------

    fn check_safety(sim: *Simulator) Failure {
        for (sim.nodes[0..sim.n()], 0..) |*node, i| {
            // currentTerm never decreases, including across crashes: read the disk if down.
            const term = if (node.up) node.current_term else node.disk.current_term;
            if (term < sim.term_seen[i]) {
                std.debug.print("TERM REGRESSED: node {d} term {d} -> {d} at tick {d}\n", .{
                    i, sim.term_seen[i], term, sim.tick,
                });
                return .term_regressed;
            }
            sim.term_seen[i] = term;
            if (node.up) assert(node.disk.current_term == node.current_term); // persisted

            // Election Safety: one leader per term, over the whole history.
            if (!node.up or node.role != .leader) continue;
            var known = false;
            for (sim.term_leaders.items) |entry| {
                if (entry.term != node.current_term) continue;
                known = true;
                if (entry.node != node.id) {
                    std.debug.print(
                        "ELECTION SAFETY VIOLATED: term {d} has two leaders: node {d} and node {d} (tick {d})\n",
                        .{ node.current_term, entry.node, node.id, sim.tick },
                    );
                    return .election_safety;
                }
            }
            if (!known) sim.term_leaders.append(sim.gpa, .{
                .term = node.current_term,
                .node = node.id,
            }) catch @panic("OOM");
        }
        return .none;
    }

    /// Converged = every node is up, in the same term, and following the same leader.
    fn converged(sim: *const Simulator) bool {
        var leader: u8 = none;
        for (sim.nodes[0..sim.n()]) |*node| if (node.up and node.role == .leader) {
            if (leader != none) return false;
            leader = node.id;
        };
        if (leader == none) return false;
        const term = sim.nodes[leader].current_term;
        for (sim.nodes[0..sim.n()]) |*node| {
            if (!node.up or node.current_term != term or node.leader != leader) return false;
        }
        return true;
    }

    fn enter_liveness_mode(sim: *Simulator) void {
        // Like vopr.zig transition_to_liveness_mode: stop injecting faults, heal everything,
        // and demand progress. Safety checking continues.
        sim.faults_enabled = false;
        if (sim.partition_active) sim.heal_network();
        for (0..sim.n()) |i| if (!sim.nodes[i].up) sim.restart(@intCast(i));
        sim.event(none, 'L');
    }

    fn run(sim: *Simulator) Failure {
        while (true) : (sim.tick += 1) {
            if (sim.tick == fault_ticks) sim.enter_liveness_mode();
            if (sim.faults_enabled) sim.inject_faults();

            // Deliver due messages in send order (ordered removal keeps this deterministic).
            var i: usize = 0;
            while (i < sim.messages.items.len) {
                if (sim.messages.items[i].deliver_at <= sim.tick) {
                    sim.on_message(sim.messages.orderedRemove(i));
                } else i += 1;
            }
            for (sim.nodes[0..sim.n()]) |*node| sim.on_tick(node);

            const failure = sim.check_safety();
            if (failure != .none) return failure;

            if (!sim.faults_enabled) {
                if (sim.converged()) {
                    const leader = for (sim.nodes[0..sim.n()]) |*node| {
                        if (node.role == .leader) break node.id;
                    } else unreachable;
                    sim.trace.update(std.mem.asBytes(&sim.tick));
                    if (sim.verbose) std.debug.print(
                        "liveness: node {d} leads term {d}, agreed by all, {d} ticks after heal\n",
                        .{ leader, sim.nodes[leader].current_term, sim.tick - fault_ticks },
                    );
                    return .none;
                }
                if (sim.tick >= fault_ticks + liveness_bound) {
                    std.debug.print("LIVENESS VIOLATED: no agreed leader {d} ticks after heal\n", .{liveness_bound});
                    return .liveness;
                }
            }
        }
    }
};

fn run_seed(gpa: std.mem.Allocator, seed: u64, verbose: bool) Result {
    var sim = Simulator.init(gpa, seed, verbose);
    defer sim.deinit();
    if (verbose) {
        const o = sim.options;
        std.debug.print(
            \\seed={d} nodes={d} partition_mode={s} partition_symmetry={s}
            \\  partition_probability={d}/10000 unpartition_probability={d}/10000
            \\  partition_stability={d} unpartition_stability={d} ticks
            \\  crash_probability={d}/100000 restart_probability={d}/1000 loss={d}/1000 delay=1..{d}
            \\  tick node event role [cluster] term votedFor leader net
            \\
        , .{
            seed,                           o.node_count,            @tagName(o.partition_mode),
            @tagName(o.partition_symmetry), o.partition_probability, o.unpartition_probability,
            o.partition_stability,          o.unpartition_stability, o.crash_probability,
            o.restart_probability,          o.loss_probability,      o.delay_max,
        });
    }
    const failure = sim.run();
    return .{ .failure = failure, .trace_hash = sim.trace.final(), .ticks = sim.tick };
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse "sweep";
    const count = try std.fmt.parseInt(u64, args.next() orelse "5000", 10);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bug-volatile-vote")) {
            bug_volatile_vote = true;
        } else if (std.mem.eql(u8, arg, "--bug-no-quorum")) {
            bug_no_quorum = true;
        } else {
            std.debug.print("unknown flag: {s}\n", .{arg});
            std.process.exit(2);
        }
    }
    const flags = if (bug_volatile_vote and bug_no_quorum)
        " --bug-volatile-vote --bug-no-quorum"
    else if (bug_volatile_vote) " --bug-volatile-vote" else if (bug_no_quorum) " --bug-no-quorum" else "";

    if (std.mem.eql(u8, mode, "run")) {
        const r = run_seed(init.gpa, count, true);
        std.debug.print("seed={d} ticks={d} trace={x:0>16} {s}\n", .{
            count, r.ticks, r.trace_hash, if (r.failure == .none) "PASS" else "FAIL",
        });
        if (r.failure != .none) std.process.exit(1);
        return;
    }

    var seed: u64 = 0;
    while (seed < count) : (seed += 1) {
        const r = run_seed(init.gpa, seed, false);
        if (r.failure != .none) {
            std.debug.print("FAIL at seed={d} ({s}) after {d} seeds. Replay with:\n", .{
                seed, @tagName(r.failure), seed + 1,
            });
            std.debug.print("  zig run main.zig -- run {d}{s}\n", .{ seed, flags });
            std.process.exit(1);
        }
    }
    std.debug.print("PASS: {d} seeds\n", .{count});
}
