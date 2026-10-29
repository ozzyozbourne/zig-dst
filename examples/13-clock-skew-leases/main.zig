//! Example 13 — Clock skew and leader leases.
//!
//! Example 02 had ONE clock, owned by the simulator. Real clusters have one clock per machine and
//! they disagree: every oscillator runs a little fast or slow (drift, in parts per million), and
//! the wall clock can additionally JUMP when NTP or an operator steps it. Protocols that turn
//! "time passed on my clock" into "time passed for everyone" are where those disagreements bite.
//!
//! System under test: 3 nodes with LEADER LEASES for fast local reads.
//!   - Writes go through the leader to a quorum (leader + 1 follower) before they are committed.
//!   - The leader sends heartbeats stamped with its own clock reading `s`. A follower that
//!     accepts one PROMISES not to vote for (or become) another leader until `lease` has passed on
//!     ITS clock, and acks with the stamp. With an ack, the leader holds a lease until
//!     `s + lease - margin` on ITS clock and serves reads locally, without a quorum round trip.
//!   - A new leader must collect a quorum of votes, so at least one voter promised the old
//!     leader. If promises and leases are measured correctly, the old lease is over in TRUE time
//!     before any new leader exists.
//!
//! What the simulator controls (all from one seed):
//!   - true time: `Simulator.tick`, 1 tick = 1 ms. Only the simulator and the checker read it;
//!     nodes only see their own clocks.
//!   - clocks: each node has a `Clock` like TigerBeetle's TimeSim (src/stdx/time.zig) with a
//!     monotonic and a realtime reading. The oscillator drifts at a seeded rate within
//!     ±drift_bound_ppm (both readings drift together, the linear offset model), and the
//!     realtime reading can also STEP forwards or backwards (the step model). Monotonic never
//!     steps, and `Node.read_clock` asserts that, like TimeOS.monotonic_guard does.
//!   - the network: delay 1..delay_max ticks, loss, and partitions that isolate one node,
//!     usually the current leader (that is when the lease handover window matters).
//!
//! Checked on EVERY tick, in true time, by `Checker`:
//!   - Lease exclusivity: at most one node believes it holds a valid lease.
//!   - Linearizable lease reads: every read served under a lease returns the value of the latest
//!     committed write to that key (a simple per-key check against the true-time history of
//!     commits; reads are local and instantaneous, so this is exact).
//!
//! Correct code measures leases and promises with the MONOTONIC clock and shortens the leader's
//! lease by the worst-case drift over one lease (2 · drift_bound · lease, see `drift_margin_us`)
//! plus a guard.
//!
//! Planted bugs:
//!   --bug-no-drift-margin  the leader's lease is not shortened. A slow leader clock and fast
//!                          follower clocks make the old lease outlive the promises: two leases
//!                          overlap in true time, and the old leader serves stale reads.
//!   --bug-wall-clock       leases and promises are measured with the REALTIME clock. A step
//!                          backwards on the leader stretches its lease by the step size.
//!
//! Usage:
//!   zig run main.zig -- run   <seed>  [--bug-no-drift-margin] [--bug-wall-clock]
//!   zig run main.zig -- sweep <count> [--bug-no-drift-margin] [--bug-wall-clock]
const std = @import("std");
const assert = std.debug.assert;

var bug_no_drift_margin = false;
var bug_wall_clock = false;

const node_count = 3;
const quorum = 2;
const key_count = 2;
const none: u8 = 0xff;

// ---------------------------------------------------------------------------------------------
// Time. True time is in ticks (1 tick = 1 ms). Local clocks count microseconds.
// ---------------------------------------------------------------------------------------------

const us_per_ms = 1000;

/// The drift bound the protocol is designed for. A real quartz oscillator is within ~±100 ppm;
/// this is exaggerated 10-20x so a lease spans 5000 ticks instead of 50_000. What decides safety
/// is the product drift x lease (here up to 10 ms per node per lease) compared with the network
/// delay (1-4 ms), and that ratio is in the same range as a real cluster: ±200 ppm x 10 s = 2 ms
/// vs a 0.1-1 ms datacenter round trip.
const drift_bound_ppm: i64 = 2000;
/// How long a follower's promise lasts, on the follower's clock.
const lease_us: i64 = 5000 * us_per_ms;
/// Worst case: the leader's clock is slow by drift_bound and a follower's is fast by
/// drift_bound. Over one lease they then disagree by 2 · drift_bound · lease. (Exactly, the
/// leader's lease L must satisfy L / (1 - ρ) <= lease / (1 + ρ), i.e. L <= lease · (1 - 2ρ/(1+ρ));
/// subtracting 2ρ · lease is slightly more than needed.)
const drift_margin_us: i64 = 2 * drift_bound_ppm * lease_us / 1_000_000;
/// Plus a guard for clock-read granularity (clocks are read once per tick).
const margin_guard_us: i64 = 2 * us_per_ms;

const heartbeat_us: u64 = 200 * us_per_ms;
const election_timeout_min_us: u64 = 600 * us_per_ms;
const election_timeout_max_us: u64 = 900 * us_per_ms;
/// A candidate retries (with a new term) this often. Short, so that a new leader appears as
/// soon as the promises allow it: this is what makes any overlap visible.
const election_retry_min_us: u64 = 3 * us_per_ms;
const election_retry_max_us: u64 = 15 * us_per_ms;

const ticks_max = 25_000;
/// After the first violation, keep simulating until the overlap closes (at most this long), so
/// the trace shows what the overlap cost: the stale reads inside it.
const ticks_after_failure_max = 2000;
const pending_max = 64;

/// A node's local hardware clock, in the shape of TigerBeetle's TimeSim: `monotonic` for
/// measuring durations, `realtime` for "what time is it". Both are driven by the same drifting
/// oscillator; `realtime` additionally carries an offset that NTP-style steps move.
const Clock = struct {
    drift_ppm: i64,
    realtime_offset_us: i64,

    fn monotonic(clock: *const Clock, tick: u64) u64 {
        const t: i64 = @intCast(tick);
        return @intCast(@divFloor(t * (1_000_000 + clock.drift_ppm), 1000));
    }

    fn realtime(clock: *const Clock, tick: u64) i64 {
        return @as(i64, @intCast(clock.monotonic(tick))) + clock.realtime_offset_us;
    }
};

/// A handover gap in ticks and the handover it belongs to, printed as `G <name>=a->b` or
/// `- <name>=-`.
const Gap = struct {
    ticks: i64,
    pair: [2]u8,
    name: []const u8,
    pub fn format(g: Gap, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (g.ticks == std.math.maxInt(i64)) return w.print("- {s}=-", .{g.name});
        try w.print("{d} {s}={d}->{d}", .{ g.ticks, g.name, g.pair[0], g.pair[1] });
    }
};

/// Prints microseconds as milliseconds with 3 decimals.
const Ms = struct {
    us: i64,
    signed: bool = false,
    pub fn format(v: Ms, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const a = @abs(v.us);
        const sign: []const u8 = if (v.us < 0) "-" else if (v.signed) "+" else "";
        try w.print("{s}{d}.{d:0>3}", .{ sign, a / 1000, a % 1000 });
    }
};

// ---------------------------------------------------------------------------------------------
// Options: the seed first picks the weather.
// ---------------------------------------------------------------------------------------------

/// `extremes` puts every clock at ±drift_bound: swarm testing for the edge of the bound, where
/// an off-by-a-factor-of-two margin would show up.
const DriftMode = enum { uniform, extremes };

const Options = struct {
    drift_mode: DriftMode,
    drift_ppm: [node_count]i64,
    realtime_offset_us: [node_count]i64,
    delay_max: u8, // one-way delay uniform in [1, delay_max] ticks
    loss: u32, // per 1000 messages
    step_probability: u32, // per node, per 100_000 ticks
    step_max_ms: u32,
    partition_probability: u32, // per 100_000 ticks, when healthy
    partition_ticks_min: u32,
    partition_ticks_max: u32,
    healthy_ticks_min: u32, // the network stays healthy at least this long after a heal

    fn generate(random: std.Random) Options {
        var o: Options = .{
            .drift_mode = random.enumValueWithIndex(DriftMode, u32),
            .drift_ppm = undefined,
            .realtime_offset_us = undefined,
            .delay_max = 1 + random.uintAtMost(u8, 3),
            .loss = random.uintAtMost(u32, 40),
            .step_probability = if (random.uintLessThan(u8, 3) == 0) 0 else 2 + random.uintAtMost(u32, 10),
            .step_max_ms = 5 + random.uintAtMost(u32, 245),
            .partition_probability = 10 + random.uintAtMost(u32, 40),
            .partition_ticks_min = 1000,
            .partition_ticks_max = 4000 + random.uintAtMost(u32, 10_000),
            .healthy_ticks_min = 500 + random.uintAtMost(u32, 2500),
        };
        for (0..node_count) |i| {
            o.drift_ppm[i] = switch (o.drift_mode) {
                .uniform => random.intRangeAtMost(i64, -drift_bound_ppm, drift_bound_ppm),
                .extremes => if (random.boolean()) drift_bound_ppm else -drift_bound_ppm,
            };
            o.realtime_offset_us[i] = random.intRangeAtMost(i64, -50 * us_per_ms, 50 * us_per_ms);
        }
        return o;
    }
};

// ---------------------------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------------------------

const Version = struct {
    term: u64 = 0,
    seq: u64 = 0,
    fn newer(a: Version, b: Version) bool {
        return a.term > b.term or (a.term == b.term and a.seq > b.seq);
    }
};

/// A register value. Values are unique per client write (0 = initial), so the checker can
/// compare reads by value.
const Entry = struct { value: u64 = 0, version: Version = .{} };

const Kind = enum(u8) { request_vote, vote, heartbeat, heartbeat_ack, accept, accept_ok };

const Message = struct {
    deliver_at: u64 = 0, // set by `send`
    from: u8,
    to: u8 = 0, // set by `broadcast` for broadcasts
    kind: Kind,
    term: u64,
    granted: bool = false,
    /// heartbeat: the leader's lease clock when it sent it; echoed back in heartbeat_ack.
    stamp: i64 = 0,
    key: u8 = 0,
    entry: Entry = .{},
    /// vote: the voter's accepted state, so the new leader can recover every committed write.
    kv: [key_count]Entry = @splat(.{}),
};

// ---------------------------------------------------------------------------------------------
// Node: the system under test. It never reads Simulator.tick, only its own clock readings.
// ---------------------------------------------------------------------------------------------

const Role = enum(u8) { follower, candidate, leader };

const Pending = struct { key: u8, entry: Entry, acks: u8, recovery: bool };

const Node = struct {
    id: u8,
    prng: std.Random.DefaultPrng, // timeout jitter
    mono: u64 = 0, // this node's monotonic clock, µs (read once per tick)
    real: i64 = 0, // this node's realtime clock, µs

    term: u64 = 0,
    voted_for: u8 = none,
    role: Role = .follower,
    leader: u8 = none,
    election_deadline: u64 = 0, // monotonic

    /// Follower side of the lease: no vote, no candidacy before this (lease clock).
    promise_until: i64 = std.math.minInt(i64),

    accepted: [key_count]Entry = @splat(.{}),

    // Candidate.
    votes: u8 = 0,
    recovered_kv: [key_count]Entry = @splat(.{}),

    // Leader.
    committed: [key_count]Entry = @splat(.{}),
    acked_stamp: [node_count]i64 = @splat(std.math.minInt(i64)),
    lease_until: i64 = std.math.minInt(i64), // lease clock
    next_heartbeat: u64 = 0,
    seq: u64 = 0,
    pending: [pending_max]Pending = undefined,
    pending_count: u8 = 0,
    recovering: u8 = 0, // recovery writes not yet committed; no reads until 0

    fn read_clock(node: *Node, clock: *const Clock, tick: u64) void {
        const mono = clock.monotonic(tick);
        // The monotonic guard (TimeOS.monotonic in src/stdx/time.zig panics if it regresses).
        assert(tick == 0 or mono > node.mono);
        node.mono = mono;
        node.real = clock.realtime(tick);
    }

    /// THE CLOCK CHOICE. Durations must be measured with the monotonic clock: realtime is for
    /// telling the time, and it jumps whenever NTP or an operator steps it.
    fn lease_clock(node: *const Node) i64 {
        if (bug_wall_clock) return node.real; // THE BUG: a step moves every lease deadline
        return @intCast(node.mono);
    }

    /// How long the leader may use a lease measured from a heartbeat it stamped.
    fn leader_lease_us() i64 {
        // THE BUG: trust that the leader's clock and the followers' clocks tick at the same rate.
        if (bug_no_drift_margin) return lease_us;
        return lease_us - drift_margin_us - margin_guard_us;
    }

    fn holds_lease(node: *const Node) bool {
        return node.role == .leader and node.lease_clock() < node.lease_until;
    }

    fn promise_expired(node: *const Node) bool {
        return node.lease_clock() >= node.promise_until;
    }

    fn reset_election_timer(node: *Node) void {
        node.election_deadline = node.mono +
            node.prng.random().intRangeAtMost(u64, election_timeout_min_us, election_timeout_max_us);
    }
};

// ---------------------------------------------------------------------------------------------
// Checker: runs every tick, in TRUE time. It is the only code that sees all nodes at once.
// ---------------------------------------------------------------------------------------------

const Failure = enum { none, lease_overlap, stale_read };

const Checker = struct {
    /// The true-time history, reduced to what a per-key linearizability check needs: the latest
    /// committed write of each key, who committed it, and when.
    latest: [key_count]struct { entry: Entry = .{}, by: u8 = none, tick: u64 = 0 } = @splat(.{}),
    held: [node_count]bool = @splat(false), // lease belief at the previous tick
    promised: [node_count]bool = @splat(false), // follower promise at the previous tick
    last_end: [node_count]u64 = @splat(0),
    last_holder: u8 = none,
    overlap_pair: [2]u8 = .{ none, none },

    // Statistics (printed in the summary; also folded into the sweep's coverage line).
    handovers: u64 = 0,
    min_gap: i64 = std.math.maxInt(i64), // ticks between one lease's end and the next's start
    min_gap_pair: [2]u8 = .{ none, none },
    /// The same, but only over handovers where the old lease ran out (rather than its holder
    /// stepping down on seeing a higher term). Only these depend on drift and the margin.
    expiry_gap: i64 = std.math.maxInt(i64),
    expiry_gap_pair: [2]u8 = .{ none, none },
    end_expired: [node_count]bool = @splat(false), // how each node's last lease ended
    overlap_ticks: u64 = 0,
    stale_reads: u64 = 0,
    lease_reads: u64 = 0,
    commits: u64 = 0,

    /// A handover gap for the summary. An overlap is the tightest possible handover: report it
    /// as a negative gap.
    fn gap(c: *const Checker, ticks: i64, pair: [2]u8, name: []const u8) Gap {
        if (c.overlap_ticks > 0) return .{ .ticks = -@as(i64, @intCast(c.overlap_ticks)), .pair = c.overlap_pair, .name = name };
        return .{ .ticks = ticks, .pair = pair, .name = name };
    }
};

// ---------------------------------------------------------------------------------------------
// Simulator
// ---------------------------------------------------------------------------------------------

const Simulator = struct {
    gpa: std.mem.Allocator,
    options: Options,
    verbose: bool,
    tick: u64 = 0,
    clocks: [node_count]Clock,
    nodes: [node_count]Node,
    trace: std.hash.Wyhash = std.hash.Wyhash.init(0),

    fault_prng: std.Random.DefaultPrng,
    net_prng: std.Random.DefaultPrng,
    client_prng: std.Random.DefaultPrng,
    messages: std.ArrayList(Message) = .empty,
    isolated: u8 = none,
    stability: u32 = 0,

    checker: Checker = .{},
    failure: Failure = .none,
    failure_tick: u64 = 0,
    stale_reader: u8 = none, // the node that served the first stale read
    next_value: u64 = 0,
    elections: u64 = 0,
    steps: u64 = 0,

    fn init(gpa: std.mem.Allocator, seed: u64, verbose: bool) Simulator {
        var root = std.Random.DefaultPrng.init(seed);
        const random = root.random();
        const options = Options.generate(random);
        var sim: Simulator = .{
            .gpa = gpa,
            .options = options,
            .verbose = verbose,
            .clocks = undefined,
            .nodes = undefined,
            .fault_prng = std.Random.DefaultPrng.init(random.int(u64)),
            .net_prng = std.Random.DefaultPrng.init(random.int(u64)),
            .client_prng = std.Random.DefaultPrng.init(random.int(u64)),
        };
        for (0..node_count) |i| {
            sim.clocks[i] = .{ .drift_ppm = options.drift_ppm[i], .realtime_offset_us = options.realtime_offset_us[i] };
            sim.nodes[i] = .{ .id = @intCast(i), .prng = std.Random.DefaultPrng.init(random.int(u64)) };
            sim.nodes[i].read_clock(&sim.clocks[i], 0);
            sim.nodes[i].reset_election_timer();
        }
        sim.trace.update(std.mem.asBytes(&options));
        return sim;
    }

    fn deinit(sim: *Simulator) void {
        sim.messages.deinit(sim.gpa);
    }

    fn chance(prng: *std.Random.DefaultPrng, numerator: u32, denominator: u32) bool {
        return prng.random().uintLessThan(u32, denominator) < numerator;
    }

    // ---- Event log ---------------------------------------------------------------------------
    //
    //   tick node ev role term m=<monotonic ms> r=<realtime ms> detail
    //
    //   tick is TRUE time (ms). m= and r= are that node's own clocks at that tick.
    //   ev:  P partition (isolate one node)  H heal  S realtime step
    //        ? became candidate  v granted vote  * became leader  > leader stepped down
    //        c recovery committed (may serve reads)  + lease begins  - lease ends
    //        p promise begins  e promise expired  W write committed  r lease read
    //   role: L leader, F follower, C candidate.

    fn event(sim: *Simulator, node_index: u8, ev: u8, comptime fmt: []const u8, args: anytype) void {
        var buf: [160]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
        var term: u64 = 0;
        var role: u8 = '-';
        var mono: i64 = 0;
        var real: i64 = 0;
        if (node_index != none) {
            const node = &sim.nodes[node_index];
            term = node.term;
            role = switch (node.role) {
                .leader => 'L',
                .follower => 'F',
                .candidate => 'C',
            };
            mono = @intCast(node.mono);
            real = node.real;
        }
        sim.trace.update(std.mem.asBytes(&[_]u64{ sim.tick, node_index, ev, term }));
        sim.trace.update(detail);
        if (!sim.verbose) return;
        if (node_index == none) {
            std.debug.print("{d:>6} - {c} - ---- {s}\n", .{ sim.tick, ev, detail });
        } else {
            std.debug.print("{d:>6} {d} {c} {c} {d:>3}T m={f} r={f} {s}\n", .{
                sim.tick, node_index, ev, role, term, Ms{ .us = mono }, Ms{ .us = real }, detail,
            });
        }
    }

    // ---- Network -----------------------------------------------------------------------------

    fn send(sim: *Simulator, m: Message) void {
        // Like PacketSimulator, the partition filter applies when a packet is submitted.
        if (sim.isolated == m.from or sim.isolated == m.to) return;
        if (chance(&sim.net_prng, sim.options.loss, 1000)) return;
        var msg = m;
        msg.deliver_at = sim.tick + sim.net_prng.random().intRangeAtMost(u64, 1, sim.options.delay_max);
        sim.messages.append(sim.gpa, msg) catch @panic("OOM");
    }

    fn broadcast(sim: *Simulator, m: Message) void {
        for (0..node_count) |to| if (to != m.from) {
            var msg = m;
            msg.to = @intCast(to);
            sim.send(msg);
        };
    }

    fn inject_faults(sim: *Simulator) void {
        const random = sim.fault_prng.random();
        if (sim.stability > 0) {
            sim.stability -= 1;
        } else if (sim.isolated != none) {
            sim.isolated = none;
            sim.stability = sim.options.healthy_ticks_min;
            sim.event(none, 'H', "net=ok", .{});
        } else if (chance(&sim.fault_prng, sim.options.partition_probability, 100_000)) {
            // Mostly isolate the current leader: the dangerous handover is the one where the old
            // leader is alive, still believes in its lease, and nobody can tell it otherwise.
            var leader: u8 = none;
            for (&sim.nodes) |*node| if (node.role == .leader) {
                leader = node.id;
            };
            sim.isolated = if (leader != none and random.uintLessThan(u8, 4) != 0)
                leader
            else
                random.uintLessThan(u8, node_count);
            sim.stability = random.intRangeAtMost(u32, sim.options.partition_ticks_min, sim.options.partition_ticks_max);
            sim.event(none, 'P', "isolate={d} ticks={d}", .{ sim.isolated, sim.stability });
        }
        // NTP-style steps of the REALTIME clock only. Monotonic is never stepped.
        for (0..node_count) |i| {
            if (!chance(&sim.fault_prng, sim.options.step_probability, 100_000)) continue;
            const size = random.intRangeAtMost(i64, us_per_ms, @as(i64, sim.options.step_max_ms) * us_per_ms);
            const step = if (random.boolean()) size else -size;
            sim.clocks[i].realtime_offset_us += step;
            sim.steps += 1;
            sim.nodes[i].real = sim.clocks[i].realtime(sim.tick); // this tick's reading jumps
            sim.event(@intCast(i), 'S', "step={f}ms", .{Ms{ .us = step, .signed = true }});
        }
    }

    // ---- Protocol ----------------------------------------------------------------------------

    /// Seeing a higher term: become a follower in it. The PROMISE survives: a term change does
    /// not make an earlier promise to the old leader any less binding.
    fn observe_term(sim: *Simulator, node: *Node, term: u64) void {
        if (term <= node.term) return;
        const was_leader = node.role == .leader;
        node.term = term;
        node.voted_for = none;
        node.role = .follower;
        node.leader = none;
        node.votes = 0;
        if (was_leader) {
            node.pending_count = 0;
            sim.event(node.id, '>', "stepped_down", .{});
        }
    }

    fn start_election(sim: *Simulator, node: *Node) void {
        const first = node.role == .follower;
        node.term += 1;
        node.role = .candidate;
        node.leader = none;
        node.voted_for = node.id;
        node.votes = @as(u8, 1) << @intCast(node.id);
        node.recovered_kv = node.accepted;
        node.election_deadline = node.mono +
            node.prng.random().intRangeAtMost(u64, election_retry_min_us, election_retry_max_us);
        sim.elections += 1;
        // Retries are hashed but not printed (an isolated node retries every few ms).
        if (first) sim.event(node.id, '?', "term={d}", .{node.term}) else {
            sim.trace.update(std.mem.asBytes(&[_]u64{ sim.tick, node.id, node.term }));
        }
        sim.broadcast(.{ .from = node.id, .kind = .request_vote, .term = node.term });
    }

    fn become_leader(sim: *Simulator, node: *Node) void {
        node.role = .leader;
        node.leader = node.id;
        node.acked_stamp = @splat(std.math.minInt(i64));
        node.lease_until = std.math.minInt(i64);
        node.committed = @splat(.{});
        node.pending_count = 0;
        sim.event(node.id, '*', "votes={b:0>3}", .{node.votes});
        // Recovery: re-commit the newest value of every key seen by the quorum of voters, in our
        // term, before serving any read (like Raft's no-op entry at the start of a term).
        node.recovering = key_count;
        for (0..key_count) |k| sim.propose(node, @intCast(k), node.recovered_kv[k].value, true);
        node.next_heartbeat = node.mono; // heartbeat (lease request) right now
    }

    fn propose(sim: *Simulator, node: *Node, key: u8, value: u64, recovery: bool) void {
        assert(node.role == .leader);
        if (node.pending_count == pending_max) return; // client times out and gives up
        node.seq += 1;
        const entry: Entry = .{ .value = value, .version = .{ .term = node.term, .seq = node.seq } };
        node.accepted[key] = entry;
        node.pending[node.pending_count] = .{ .key = key, .entry = entry, .acks = @as(u8, 1) << @intCast(node.id), .recovery = recovery };
        node.pending_count += 1;
        sim.broadcast(.{ .from = node.id, .kind = .accept, .term = node.term, .key = key, .entry = entry });
    }

    fn on_message(sim: *Simulator, m: Message) void {
        const node = &sim.nodes[m.to];
        sim.trace.update(std.mem.asBytes(&[_]u64{ sim.tick, m.from, m.to, @backingInt(m.kind), m.term, @bitCast(m.stamp) }));
        sim.observe_term(node, m.term);
        switch (m.kind) {
            .request_vote => {
                // The lease rule on the voter side: no vote while my promise holds on MY clock.
                const grant = m.term == node.term and node.promise_expired() and
                    (node.voted_for == none or node.voted_for == m.from);
                if (grant and node.voted_for == none) {
                    node.voted_for = m.from;
                    node.reset_election_timer();
                    sim.event(node.id, 'v', "for={d}", .{m.from});
                }
                sim.send(.{ .from = node.id, .to = m.from, .kind = .vote, .term = node.term, .granted = grant, .kv = node.accepted });
            },
            .vote => {
                if (node.role != .candidate or m.term != node.term or !m.granted) return;
                node.votes |= @as(u8, 1) << @intCast(m.from);
                for (0..key_count) |k| {
                    if (m.kv[k].version.newer(node.recovered_kv[k].version)) node.recovered_kv[k] = m.kv[k];
                }
                if (@popCount(node.votes) >= quorum) sim.become_leader(node);
            },
            .heartbeat => {
                // A stale leader gets an ungranted ack with the newer term (it steps down on it).
                const current = m.term >= node.term;
                if (current) {
                    assert(node.role != .leader); // one leader per term: votes are unique per term
                    node.role = .follower;
                    node.leader = m.from;
                    node.reset_election_timer();
                    // THE PROMISE, measured on MY clock from when I received it.
                    node.promise_until = @max(node.promise_until, node.lease_clock() + lease_us);
                }
                sim.send(.{ .from = node.id, .to = m.from, .kind = .heartbeat_ack, .term = node.term, .stamp = m.stamp, .granted = current });
            },
            .heartbeat_ack => {
                if (node.role != .leader or m.term != node.term or !m.granted) return;
                node.acked_stamp[m.from] = @max(node.acked_stamp[m.from], m.stamp);
                // Quorum = me + 1 follower, so the best follower promise bounds my lease. The
                // stamp is from BEFORE the follower promised, so the follower's promise started
                // later in true time than the stamp: the lease can only be too short, not too long.
                var best: i64 = std.math.minInt(i64);
                for (0..node_count) |f| if (f != node.id) {
                    best = @max(best, node.acked_stamp[f]);
                };
                node.lease_until = @max(node.lease_until, best + Node.leader_lease_us());
            },
            .accept => {
                const current = m.term >= node.term;
                if (current) {
                    if (node.role == .candidate) node.role = .follower;
                    if (m.entry.version.newer(node.accepted[m.key].version)) node.accepted[m.key] = m.entry;
                }
                sim.send(.{ .from = node.id, .to = m.from, .kind = .accept_ok, .term = node.term, .key = m.key, .entry = m.entry, .granted = current });
            },
            .accept_ok => {
                if (node.role != .leader or m.term != node.term or !m.granted) return;
                var i: usize = 0;
                while (i < node.pending_count) : (i += 1) {
                    const p = &node.pending[i];
                    if (p.key != m.key or !std.meta.eql(p.entry.version, m.entry.version)) continue;
                    p.acks |= @as(u8, 1) << @intCast(m.from);
                    if (@popCount(p.acks) < quorum) return;
                    sim.commit(node, p.*);
                    node.pending[i] = node.pending[node.pending_count - 1];
                    node.pending_count -= 1;
                    return;
                }
            },
        }
    }

    fn commit(sim: *Simulator, node: *Node, p: Pending) void {
        if (p.entry.version.newer(node.committed[p.key].version)) node.committed[p.key] = p.entry;
        const latest = &sim.checker.latest[p.key];
        if (p.entry.version.newer(latest.entry.version)) latest.* = .{ .entry = p.entry, .by = node.id, .tick = sim.tick };
        sim.checker.commits += 1;
        sim.event(node.id, 'W', "key={d} val={d} ver={d}.{d}{s}", .{
            p.key, p.entry.value, p.entry.version.term, p.entry.version.seq, if (p.recovery) " recovery" else "",
        });
        if (p.recovery) {
            node.recovering -= 1;
            if (node.recovering == 0) sim.event(node.id, 'c', "recovered", .{});
        }
    }

    fn on_tick(sim: *Simulator, node: *Node) void {
        if (node.role == .leader) {
            if (node.mono < node.next_heartbeat) return;
            node.next_heartbeat = node.mono + heartbeat_us;
            sim.broadcast(.{ .from = node.id, .kind = .heartbeat, .term = node.term, .stamp = node.lease_clock() });
            for (node.pending[0..node.pending_count]) |p| { // retransmit unacked writes
                sim.broadcast(.{ .from = node.id, .kind = .accept, .term = node.term, .key = p.key, .entry = p.entry });
            }
            return;
        }
        // The lease rule on the candidate side: wait for my own promise to expire too.
        if (node.mono >= node.election_deadline and node.promise_expired()) sim.start_election(node);
    }

    /// The node-local client: reads go to the local node and are served only under a lease;
    /// writes are proposed only by a recovered leader.
    fn client(sim: *Simulator, node: *Node) void {
        const random = sim.client_prng.random();
        if (random.boolean()) {
            const key = random.uintLessThan(u8, key_count);
            if (node.holds_lease() and node.recovering == 0) sim.lease_read(node, key);
        }
        if (node.role == .leader and node.recovering == 0 and random.uintLessThan(u8, 5) == 0) {
            sim.next_value += 1;
            sim.propose(node, random.uintLessThan(u8, key_count), sim.next_value, false);
        }
    }

    // ---- Invariant checkers ------------------------------------------------------------------

    /// Linearizable lease reads: the read is local and happens at one true-time instant, so it
    /// must return exactly the latest write committed before that instant.
    fn lease_read(sim: *Simulator, node: *Node, key: u8) void {
        const c = &sim.checker;
        const got = node.committed[key];
        const want = c.latest[key];
        c.lease_reads += 1;
        sim.trace.update(std.mem.asBytes(&[_]u64{ sim.tick, node.id, key, got.value }));
        if (got.value == want.entry.value) return;
        c.stale_reads += 1;
        sim.event(node.id, 'r', "key={d} val={d} ver={d}.{d} STALE", .{ key, got.value, got.version.term, got.version.seq });
        // The first stale read gets the full explanation; later ones only their `r` line.
        if (sim.verbose and c.stale_reads == 1) std.debug.print(
            "STALE READ: node {d} read key {d} = {d} at tick {d}, but the latest committed write is {d} (committed by node {d} at tick {d})\n",
            .{ node.id, key, got.value, sim.tick, want.entry.value, want.by, want.tick },
        );
        sim.fail(.stale_read);
        sim.stale_reader = node.id;
    }

    fn fail(sim: *Simulator, failure: Failure) void {
        if (sim.failure != .none) return;
        sim.failure = failure;
        sim.failure_tick = sim.tick;
    }

    /// How many nodes believe they hold a valid lease right now.
    fn holders(sim: *const Simulator) u8 {
        var count: u8 = 0;
        for (&sim.nodes) |*node| count += @intFromBool(node.holds_lease());
        return count;
    }

    /// Lease exclusivity, in true time, every tick. Also records lease intervals and handover
    /// gaps (the true time between one node's lease ending and another's beginning).
    fn check_leases(sim: *Simulator) void {
        const c = &sim.checker;
        for (&sim.nodes) |*node| {
            const now = node.holds_lease();
            const i = node.id;
            if (now and !c.held[i]) {
                const other_holding = for (0..node_count) |j| {
                    if (j != i and c.held[j]) break @as(u8, @intCast(j));
                } else none;
                if (other_holding != none) {
                    c.handovers += 1;
                    c.overlap_pair = .{ other_holding, i };
                } else if (c.last_holder != none and c.last_holder != i) {
                    c.handovers += 1;
                    const gap: i64 = @as(i64, @intCast(sim.tick)) - @as(i64, @intCast(c.last_end[c.last_holder]));
                    if (gap < c.min_gap) {
                        c.min_gap = gap;
                        c.min_gap_pair = .{ c.last_holder, i };
                    }
                    if (c.end_expired[c.last_holder] and gap < c.expiry_gap) {
                        c.expiry_gap = gap;
                        c.expiry_gap_pair = .{ c.last_holder, i };
                    }
                }
                c.last_holder = i;
                sim.event(i, '+', "until={f} clock={s}", .{ Ms{ .us = node.lease_until }, if (bug_wall_clock) "real" else "mono" });
            }
            if (!now and c.held[i]) {
                c.last_end[i] = sim.tick - 1;
                c.end_expired[i] = node.role == .leader;
                sim.event(i, '-', "{s}", .{if (node.role == .leader) "expired" else "stepped_down"});
            }
            c.held[i] = now;
            // Promise intervals are logged too, so the replay can draw them next to the leases.
            const promised = node.role != .leader and !node.promise_expired();
            if (promised and !c.promised[i]) {
                sim.event(i, 'p', "leader={d} until={f}", .{ node.leader, Ms{ .us = node.promise_until } });
            }
            if (!promised and c.promised[i]) sim.event(i, 'e', "promise_expired", .{});
            c.promised[i] = promised;
        }
        if (sim.holders() >= 2) {
            c.overlap_ticks += 1;
            if (sim.failure == .none and sim.verbose) {
                std.debug.print("LEASE OVERLAP: node {d} and node {d} both hold a lease at tick {d} (true time)\n", .{
                    c.overlap_pair[0], c.overlap_pair[1], sim.tick,
                });
            }
            sim.fail(.lease_overlap);
        }
    }

    /// After a failure, run on while the damage is still unfolding: two leases overlap, or the
    /// node that served a stale read still believes in its lease.
    fn still_failing(sim: *const Simulator) bool {
        if (sim.holders() >= 2) return true;
        return sim.stale_reader != none and sim.nodes[sim.stale_reader].holds_lease();
    }

    fn run(sim: *Simulator) void {
        while (sim.tick < ticks_max) {
            if (sim.failure != .none and
                (!sim.still_failing() or sim.tick >= sim.failure_tick + ticks_after_failure_max)) break;
            sim.tick += 1;
            for (&sim.nodes, &sim.clocks) |*node, *clock| node.read_clock(clock, sim.tick);
            sim.inject_faults();

            var i: usize = 0;
            while (i < sim.messages.items.len) {
                if (sim.messages.items[i].deliver_at <= sim.tick) {
                    sim.on_message(sim.messages.orderedRemove(i));
                } else i += 1;
            }
            for (&sim.nodes) |*node| sim.on_tick(node);
            for (&sim.nodes) |*node| sim.client(node);
            sim.check_leases();
        }
    }
};

const Result = struct {
    failure: Failure,
    trace_hash: u64,
    ticks: u64,
    checker: Checker,
    steps: u64,
};

fn run_seed(gpa: std.mem.Allocator, seed: u64, verbose: bool) Result {
    var sim = Simulator.init(gpa, seed, verbose);
    defer sim.deinit();
    if (verbose) {
        const o = sim.options;
        std.debug.print(
            \\seed={d} drift_mode={s} drift_ppm={d},{d},{d} realtime_offset_ms={f},{f},{f}
            \\  delay=1..{d} loss={d}/1000 steps={d}/100000 per node per tick, up to {d}ms
            \\  partitions={d}/100000 per tick, {d}..{d} ticks, healthy>={d} ticks
            \\  lease={d}ms drift_bound={d}ppm drift_margin={f}ms guard={f}ms leader_lease={f}ms clock={s}
            \\  tick node ev role term m=<monotonic ms> r=<realtime ms> detail
            \\
        , .{
            seed,                                                @tagName(o.drift_mode),                              o.drift_ppm[0],
            o.drift_ppm[1],                                      o.drift_ppm[2],                                      Ms{ .us = o.realtime_offset_us[0], .signed = true },
            Ms{ .us = o.realtime_offset_us[1], .signed = true }, Ms{ .us = o.realtime_offset_us[2], .signed = true }, o.delay_max,
            o.loss,                                              o.step_probability,                                  o.step_max_ms,
            o.partition_probability,                             o.partition_ticks_min,                               o.partition_ticks_max,
            o.healthy_ticks_min,                                 @divExact(lease_us, us_per_ms),                      drift_bound_ppm,
            Ms{ .us = drift_margin_us },                         Ms{ .us = margin_guard_us },                         Ms{ .us = Node.leader_lease_us() },
            if (bug_wall_clock) "realtime" else "monotonic",
        });
    }
    sim.run();
    const c = sim.checker;
    if (verbose) {
        const gap = c.gap(c.min_gap, c.min_gap_pair, "pair");
        const expiry_gap = c.gap(c.expiry_gap, c.expiry_gap_pair, "expiry_pair");
        std.debug.print("summary: handovers={d} min_gap={f} expiry_gap={f} overlap_ticks={d} stale_reads={d} lease_reads={d} commits={d} elections={d} steps={d}\n", .{
            c.handovers, gap, expiry_gap, c.overlap_ticks, c.stale_reads, c.lease_reads, c.commits, sim.elections, sim.steps,
        });
    }
    return .{ .failure = sim.failure, .trace_hash = sim.trace.final(), .ticks = sim.tick, .checker = c, .steps = sim.steps };
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse "sweep";
    const count = try std.fmt.parseInt(u64, args.next() orelse "5000", 10);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bug-no-drift-margin")) {
            bug_no_drift_margin = true;
        } else if (std.mem.eql(u8, arg, "--bug-wall-clock")) {
            bug_wall_clock = true;
        } else {
            std.debug.print("unknown flag: {s}\n", .{arg});
            std.process.exit(2);
        }
    }
    if (std.mem.eql(u8, mode, "run")) {
        const r = run_seed(init.gpa, count, true);
        std.debug.print("seed={d} ticks={d} trace={x:0>16} {s}\n", .{
            count, r.ticks, r.trace_hash, if (r.failure == .none) "PASS" else "FAIL",
        });
        if (r.failure != .none) std.process.exit(1);
        return;
    }

    // Coverage over the whole sweep: a passing sweep only means something if the dangerous
    // situations (handovers, reads under a lease, clock steps) actually happened.
    var handovers: u64 = 0;
    var lease_reads: u64 = 0;
    var commits: u64 = 0;
    var steps: u64 = 0;
    var min_gap: i64 = std.math.maxInt(i64);
    var seed: u64 = 0;
    while (seed < count) : (seed += 1) {
        const r = run_seed(init.gpa, seed, false);
        if (r.failure != .none) {
            std.debug.print("FAIL at seed={d} ({s}) after {d} seeds. Replay with:\n", .{
                seed, @tagName(r.failure), seed + 1,
            });
            std.debug.print("  zig run main.zig -- run {d}{s}{s}\n", .{
                seed, if (bug_no_drift_margin) " --bug-no-drift-margin" else "", if (bug_wall_clock) " --bug-wall-clock" else "",
            });
            std.process.exit(1);
        }
        handovers += r.checker.handovers;
        lease_reads += r.checker.lease_reads;
        commits += r.checker.commits;
        steps += r.steps;
        min_gap = @min(min_gap, r.checker.min_gap);
    }
    std.debug.print("PASS: {d} seeds\n", .{count});
    std.debug.print("coverage: handovers={d} tightest_handover_gap={d} ticks lease_reads={d} commits={d} realtime_steps={d}\n", .{
        handovers, min_gap, lease_reads, commits, steps,
    });
}
