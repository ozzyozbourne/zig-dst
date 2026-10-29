//! Example 07 — The oracle problem: checking a concurrent history for linearizability.
//!
//! In examples with one client, the oracle is easy: run the same operation against a trivially
//! correct model and compare. With concurrent clients there is no single "expected answer".
//! Two overlapping operations may take effect in either order, so the expected answer is a SET of
//! legal orderings. The oracle therefore changes shape:
//!
//!   1. While simulating, record a HISTORY: for every operation, its invoke tick, its complete tick
//!      (simulated time, as seen by the client), its argument and its result.
//!   2. Ask: is there ANY total order of these operations that (a) respects real time — if A
//!      completed before B was invoked, A comes first — and (b) is a legal sequential execution of
//!      a single register? If yes, the history is linearizable. If no, we have a bug.
//!
//! The search (Wing & Gong 1993; Lowe's memoization; Knossos/Porcupine in practice) is exponential
//! in the worst case, which is fine because DST lets us keep histories SMALL: 3 clients and at most
//! 12 operations per seed. Many short seeds beat one long history.
//!
//! System under test: a key-value register service with 2 replicas on a simulated network.
//!   - Replica 0 (primary) executes every write, assigns it a version (log index), replies, and
//!     replicates the entry ASYNCHRONOUSLY to replica 1 (backup). Replication messages may be
//!     delayed and reordered; the backup buffers them and applies them strictly in version order.
//!   - Clients write to the primary and may read from either replica. Each client remembers the
//!     highest version it has seen (a session token) and sends it with every read.
//!
//! Correct read rule at the backup ("read index", as in Raft's ReadIndex): before serving, ask the
//! primary for its CURRENT commit version and wait until the backup has applied at least that much.
//! That version is >= anything ANY client has already observed, so the read cannot go back in time.
//!
//! Bug (`--bug`): the backup only waits for the requesting client's OWN session token. That gives
//! read-your-writes and monotonic reads for every client — each client's view looks perfect — but
//! client B can still read a value older than a write that client A already saw acknowledged.
//! No single operation is wrong; only the history as a whole is impossible.
//!
//! Usage:
//!   zig run main.zig -- run   <seed>  [--bug]   # one seed, verbose
//!   zig run main.zig -- sweep <count> [--bug]   # seeds 0..count-1, stop at first failure
const std = @import("std");
const assert = std.debug.assert;

var bug_enabled = false;

const sweep_default: u64 = 100_000;

const clients_count = 3;
/// Upper bound on operations per seed. The checker's memo table is sized from this.
const ops_max = 12;
const keys_count = 2;
const key_names = [keys_count]u8{ 'x', 'y' };

// Node ids on the simulated network.
const primary: u8 = 0;
const backup: u8 = 1;
fn client_node(client: u8) u8 {
    return 2 + client;
}

// -------------------------------------------------------------------------------------------------
// History: what the clients observed. This is the ONLY input to the linearizability checker. The
// checker never looks inside the replicas: it judges the system purely by its externally visible
// behaviour, exactly like a user would.
// -------------------------------------------------------------------------------------------------

const OpKind = enum(u8) { write, read };

const Op = struct {
    client: u8,
    kind: OpKind,
    key: u8,
    /// Write: the value written (unique per seed, so a read result names exactly one write).
    /// Read: the value returned (valid once complete). 0 is the initial value of every key.
    value: u32,
    invoke: u64,
    /// null while the operation is still in flight.
    complete: ?u64 = null,
    /// Replica the request was sent to.
    target: u8,
    /// Version of the replica state that produced the reply (diagnostics only).
    version: u64 = 0,
};

// -------------------------------------------------------------------------------------------------
// Linearizability checker (Wing & Gong backtracking + memoization on (linearized set, state)).
// -------------------------------------------------------------------------------------------------

/// Linearizability is LOCAL (Herlihy & Wing): a history is linearizable iff the sub-history of each
/// object is. So we check each key separately, which keeps every search tiny.
const KeyHistory = struct {
    ops: [ops_max]Op = undefined,
    len: usize = 0,

    fn slice(h: *const KeyHistory) []const Op {
        return h.ops[0..h.len];
    }
};

const memo_size = (1 << ops_max) * (ops_max + 1);
const Memo = std.StaticBitSet(memo_size);

/// Register state is identified by which op wrote it: 0 = initial value, i + 1 = ops[i].
fn state_value(ops: []const Op, state: usize) u32 {
    return if (state == 0) 0 else ops[state - 1].value;
}

fn linearizable(ops: []const Op) bool {
    assert(ops.len <= ops_max);
    var memo: Memo = .empty;
    return search(ops, 0, 0, &memo);
}

/// `done` = bitmask of ops already placed in the linearization; `state` = current register state.
fn search(ops: []const Op, done: u16, state: usize, memo: *Memo) bool {
    // Finished once every COMPLETED op is placed. A pending write may or may not have taken
    // effect, so it is optional: we may place it (anywhere after its invoke) or leave it out.
    var min_complete: u64 = std.math.maxInt(u64);
    var remaining = false;
    for (ops, 0..) |op, i| {
        if (done & (@as(u16, 1) << @intCast(i)) != 0) continue;
        if (op.complete) |c| {
            remaining = true;
            min_complete = @min(min_complete, c);
        }
    }
    if (!remaining) return true;

    // Two different paths that place the same SET of ops and end in the same state have the same
    // future. Remembering failed (set, state) pairs turns factorial into exponential-but-tiny.
    const memo_index = @as(usize, done) * (ops_max + 1) + state;
    if (memo.isSet(memo_index)) return false;
    memo.set(memo_index);

    for (ops, 0..) |op, i| {
        const bit = @as(u16, 1) << @intCast(i);
        if (done & bit != 0) continue;
        // Real-time constraint: op may go next only if no unplaced op completed before op was
        // invoked (such an op must come first). Equal ticks count as concurrent.
        if (op.invoke > min_complete) continue;
        switch (op.kind) {
            .write => if (search(ops, done | bit, i + 1, memo)) return true,
            .read => if (state_value(ops, state) == op.value and
                search(ops, done | bit, state, memo)) return true,
        }
    }
    return false;
}

/// The sub-history of `key`. In-flight reads are dropped: they have no result to explain, and
/// constrain nothing. In-flight writes are kept: another client may already have read them.
fn key_history(history: []const Op, key: u8) KeyHistory {
    var h: KeyHistory = .{};
    for (history) |op| {
        if (op.key != key) continue;
        if (op.kind == .read and op.complete == null) continue;
        h.ops[h.len] = op;
        h.len += 1;
    }
    return h;
}

/// Every read result must name a write that is in the history (or the initial value). Used to
/// keep minimization honest: dropping the write a read observed would make the history trivially
/// non-linearizable for an uninteresting reason ("read a value nobody wrote").
fn well_formed(ops: []const Op) bool {
    for (ops) |r| {
        if (r.kind != .read or r.value == 0) continue;
        for (ops) |w| {
            if (w.kind == .write and w.value == r.value) break;
        } else return false;
    }
    return true;
}

/// Greedy delta-debugging: drop any op whose removal keeps the history non-linearizable, until
/// no single op can be dropped. The result is 1-minimal: every remaining op is essential.
fn minimize(failing: KeyHistory) KeyHistory {
    assert(!linearizable(failing.slice()));
    var current = failing;
    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i < current.len) {
            var candidate: KeyHistory = .{};
            for (current.slice(), 0..) |op, j| {
                if (j == i) continue;
                candidate.ops[candidate.len] = op;
                candidate.len += 1;
            }
            if (well_formed(candidate.slice()) and !linearizable(candidate.slice())) {
                current = candidate;
                changed = true;
            } else {
                i += 1;
            }
        }
    }
    return current;
}

// -------------------------------------------------------------------------------------------------
// Simulated network and replicas.
// -------------------------------------------------------------------------------------------------

const Body = union(enum) {
    write: struct { op: u8, key: u8, value: u32 },
    write_ok: struct { op: u8, version: u64 },
    read: struct { op: u8, key: u8, min_version: u64 },
    read_ok: struct { op: u8, value: u32, version: u64 },
    replicate: struct { version: u64, key: u8, value: u32 },
    read_index_request: struct { op: u8 },
    read_index_reply: struct { op: u8, commit: u64 },
};

const Message = struct { deliver_at: u64, from: u8, to: u8, body: Body };

const Entry = struct { key: u8, value: u32 };

/// A read waiting at the backup until `need` versions are applied. `need == null` means the
/// read-index reply from the primary has not arrived yet.
const PendingRead = struct { op: u8, key: u8, from: u8, min_version: u64, need: ?u64 };

const Client = struct {
    busy: bool = false,
    /// Session token: highest version this client has observed.
    last_seen: u64 = 0,
    next_invoke_at: u64 = 0,
};

const Failure = struct { key: u8, full_len: usize, minimal: KeyHistory };

const Sim = struct {
    gpa: std.mem.Allocator,
    random: std.Random,
    trace: std.hash.Wyhash,
    verbose: bool,
    now: u64 = 0,

    /// In-flight messages, in send order. Delivery scans in this order, so ties are deterministic.
    network: std.ArrayList(Message) = .empty,

    // Primary.
    log: [ops_max + 1]Entry = undefined, // index 1..primary_version
    primary_version: u64 = 0,
    primary_state: [keys_count]u32 = @splat(0),

    // Backup.
    backup_log: [ops_max + 1]Entry = undefined,
    backup_applied: u64 = 0,
    backup_state: [keys_count]u32 = @splat(0),
    /// Out-of-order replication messages wait here until the gap below them fills (compare
    /// TigerBeetle's ReplySequence, which reassembles out-of-order replies by op number).
    backup_buffer: [ops_max + 1]?Entry = @splat(null),
    backup_reads: std.ArrayList(PendingRead) = .empty,

    clients: [clients_count]Client = @splat(.{}),
    history: [ops_max]Op = undefined,
    history_len: u8 = 0,
    ops_budget: u8,
    next_value: u32 = 1,

    failure: ?Failure = null,

    fn deinit(sim: *Sim) void {
        sim.network.deinit(sim.gpa);
        sim.backup_reads.deinit(sim.gpa);
    }

    fn event(sim: *Sim, tag: u64, a: u64, b: u64, c: u64) void {
        sim.trace.update(std.mem.asBytes(&[5]u64{ sim.now, tag, a, b, c }));
    }

    fn send(sim: *Sim, from: u8, to: u8, body: Body) !void {
        // Replication is the slow, lagging path; request/response hops are quicker. The overlap is
        // what creates windows where the backup is behind an acknowledged write.
        const delay: u64 = switch (body) {
            .replicate => 1 + sim.random.uintLessThan(u64, 30),
            else => 1 + sim.random.uintLessThan(u64, 6),
        };
        try sim.network.append(sim.gpa, .{ .deliver_at = sim.now + delay, .from = from, .to = to, .body = body });
        sim.event(1, from, to, @backingInt(body));
    }

    fn issue(sim: *Sim, client: u8) !void {
        const op_index = sim.history_len;
        const key = sim.random.uintLessThan(u8, keys_count);
        var op: Op = .{
            .client = client,
            .kind = if (sim.random.uintLessThan(u8, 100) < 40) .write else .read,
            .key = key,
            .value = 0,
            .invoke = sim.now,
            .target = primary,
        };
        const body: Body = switch (op.kind) {
            .write => body: {
                op.value = sim.next_value;
                sim.next_value += 1;
                log(sim, "c{d} invoke W({c}:={d}) -> primary", .{ client, key_names[key], op.value });
                break :body .{ .write = .{ .op = op_index, .key = key, .value = op.value } };
            },
            .read => body: {
                op.target = if (sim.random.boolean()) primary else backup;
                const last_seen = sim.clients[client].last_seen;
                log(sim, "c{d} invoke R({c}) -> {s} (session token v{d})", .{ client, key_names[key], replica_name(op.target), last_seen });
                break :body .{ .read = .{ .op = op_index, .key = key, .min_version = last_seen } };
            },
        };
        sim.history[op_index] = op;
        sim.history_len += 1;
        sim.clients[client].busy = true;
        sim.event(2, client, @backingInt(op.kind), op.value);
        try sim.send(client_node(client), op.target, body);
    }

    fn deliver(sim: *Sim, msg: Message) !void {
        sim.event(3, msg.from, msg.to, @backingInt(msg.body));
        switch (msg.body) {
            .write => |w| {
                assert(msg.to == primary);
                sim.primary_version += 1;
                const v = sim.primary_version;
                sim.log[v] = .{ .key = w.key, .value = w.value };
                sim.primary_state[w.key] = w.value;
                try sim.send(primary, backup, .{ .replicate = .{ .version = v, .key = w.key, .value = w.value } });
                try sim.send(primary, msg.from, .{ .write_ok = .{ .op = w.op, .version = v } });
            },
            .read => |r| {
                if (msg.to == primary) {
                    try sim.send(primary, msg.from, .{ .read_ok = .{
                        .op = r.op,
                        .value = sim.primary_state[r.key],
                        .version = sim.primary_version,
                    } });
                } else {
                    assert(msg.to == backup);
                    try sim.backup_reads.append(sim.gpa, .{
                        .op = r.op,
                        .key = r.key,
                        .from = msg.from,
                        .min_version = r.min_version,
                        // BUG: the client's own token is not enough. It proves nothing about
                        // writes OTHER clients have already seen acknowledged.
                        .need = if (bug_enabled) r.min_version else null,
                    });
                    if (!bug_enabled) {
                        try sim.send(backup, primary, .{ .read_index_request = .{ .op = r.op } });
                    }
                    try sim.backup_serve_reads();
                }
            },
            .read_index_request => |q| {
                assert(msg.to == primary);
                try sim.send(primary, backup, .{ .read_index_reply = .{ .op = q.op, .commit = sim.primary_version } });
            },
            .read_index_reply => |q| {
                assert(msg.to == backup);
                for (sim.backup_reads.items) |*pending| {
                    if (pending.op == q.op) {
                        assert(pending.need == null);
                        pending.need = @max(pending.min_version, q.commit);
                        break;
                    }
                } else unreachable;
                try sim.backup_serve_reads();
            },
            .replicate => |e| {
                assert(msg.to == backup);
                assert(e.version > sim.backup_applied);
                assert(sim.backup_buffer[e.version] == null);
                sim.backup_buffer[e.version] = .{ .key = e.key, .value = e.value };
                // Apply strictly in version order; a later entry waits for the gap to fill.
                while (sim.backup_applied < ops_max) {
                    const entry = sim.backup_buffer[sim.backup_applied + 1] orelse break;
                    sim.backup_buffer[sim.backup_applied + 1] = null;
                    sim.backup_applied += 1;
                    sim.backup_log[sim.backup_applied] = entry;
                    sim.backup_state[entry.key] = entry.value;
                    sim.event(4, sim.backup_applied, entry.key, entry.value);
                    log(sim, "   backup applies v{d} ({c}:={d})", .{ sim.backup_applied, key_names[entry.key], entry.value });
                }
                sim.check_replicas();
                try sim.backup_serve_reads();
            },
            .write_ok => |r| try sim.complete(r.op, 0, r.version),
            .read_ok => |r| try sim.complete(r.op, r.value, r.version),
        }
    }

    fn backup_serve_reads(sim: *Sim) !void {
        var i: usize = 0;
        while (i < sim.backup_reads.items.len) {
            const pending = sim.backup_reads.items[i];
            if (pending.need) |need| {
                if (sim.backup_applied >= need) {
                    _ = sim.backup_reads.orderedRemove(i);
                    try sim.send(backup, pending.from, .{ .read_ok = .{
                        .op = pending.op,
                        .value = sim.backup_state[pending.key],
                        .version = sim.backup_applied,
                    } });
                    continue;
                }
            }
            i += 1;
        }
    }

    /// Replica invariant, checked every time the backup changes (cf. TigerBeetle's StateChecker,
    /// which checks every replica's commit against the canonical commit history on every tick):
    /// the backup's log is always a prefix of the primary's log.
    fn check_replicas(sim: *const Sim) void {
        assert(sim.backup_applied <= sim.primary_version);
        var v: u64 = 1;
        while (v <= sim.backup_applied) : (v += 1) {
            assert(std.meta.eql(sim.backup_log[v], sim.log[v]));
        }
    }

    /// Value of `key` in the primary's log as of `version`.
    fn value_at(sim: *const Sim, key: u8, version: u64) u32 {
        var value: u32 = 0;
        var v: u64 = 1;
        while (v <= version) : (v += 1) {
            if (sim.log[v].key == key) value = sim.log[v].value;
        }
        return value;
    }

    fn complete(sim: *Sim, op_index: u8, value: u32, version: u64) !void {
        const op = &sim.history[op_index];
        assert(op.complete == null);
        op.complete = sim.now;
        op.version = version;
        if (op.kind == .read) op.value = value;
        const client = &sim.clients[op.client];
        sim.event(5, op.client, op.value, version);

        switch (op.kind) {
            .write => log(sim, "c{d} ok     W({c}:={d}) at v{d}", .{ op.client, key_names[op.key], op.value, version }),
            .read => log(sim, "c{d} ok     R({c})={d} from {s} at v{d}", .{
                op.client, key_names[op.key], op.value, replica_name(op.target), version,
            }),
        }

        // Per-operation checks. These are what an ordinary test would assert, and they hold even
        // with --bug: every read returns a value that really was the committed state at some
        // version, and no client ever sees its own session go backwards (read-your-writes,
        // monotonic reads). Every individual answer is "fine".
        assert(version >= client.last_seen);
        if (op.kind == .read) assert(value == sim.value_at(op.key, version));
        client.last_seen = @max(client.last_seen, version);
        client.busy = false;
        client.next_invoke_at = sim.now + 1 + sim.random.uintLessThan(u64, 4);

        // The real oracle, run DURING the simulation: is the history so far linearizable? Run on
        // every completion, so the failure is reported at the first moment it becomes visible.
        sim.check_key(op.key);
    }

    fn check_key(sim: *Sim, key: u8) void {
        if (sim.failure != null) return;
        const h = key_history(sim.history[0..sim.history_len], key);
        if (!linearizable(h.slice())) {
            sim.failure = .{ .key = key, .full_len = h.len, .minimal = minimize(h) };
        }
    }

    fn done(sim: *const Sim) bool {
        if (sim.history_len < sim.ops_budget) return false;
        for (sim.clients) |c| if (c.busy) return false;
        return sim.network.items.len == 0;
    }
};

/// Verbose-only event line, prefixed with the current tick.
fn log(sim: *const Sim, comptime fmt: []const u8, args: anytype) void {
    if (sim.verbose) std.debug.print("  t={d:>3} " ++ fmt ++ "\n", .{sim.now} ++ args);
}

fn replica_name(node: u8) []const u8 {
    return if (node == primary) "primary" else "backup";
}

// -------------------------------------------------------------------------------------------------
// Reporting: print the minimal non-linearizable sub-history as a timeline.
// -------------------------------------------------------------------------------------------------

fn op_label(buf: []u8, op: Op) []const u8 {
    return switch (op.kind) {
        .write => std.fmt.bufPrint(buf, "W({c}:={d})", .{ key_names[op.key], op.value }),
        .read => std.fmt.bufPrint(buf, "R({c})={d}", .{ key_names[op.key], op.value }),
    } catch unreachable;
}

fn print_failure(f: Failure, now: u64) void {
    const ops = f.minimal.slice();
    std.debug.print(
        "\nNON-LINEARIZABLE history on key '{c}'. Minimal sub-history ({d} of {d} ops on this key):\n\n",
        .{ key_names[f.key], ops.len, f.full_len },
    );

    // Sort by invoke tick (insertion sort: stable, tiny and deterministic).
    var order: [ops_max]usize = undefined;
    for (0..ops.len) |i| order[i] = i;
    std.sort.insertion(usize, order[0..ops.len], ops, struct {
        fn invoked_before(o: []const Op, a: usize, b: usize) bool {
            return o[a].invoke < o[b].invoke;
        }
    }.invoked_before);

    var t0: u64 = std.math.maxInt(u64);
    var t1: u64 = 0;
    for (ops) |op| {
        t0 = @min(t0, op.invoke);
        t1 = @max(t1, op.complete orelse now);
    }
    const width = 48;
    const scale: u64 = (t1 - t0) / width + 1; // ticks per column

    std.debug.print("  {s:<4} {s:<10} {s:<18} timeline (t={d}..{d}, {d} tick/col)\n", .{
        "who", "op", "[invoke, complete]", t0, t1, scale,
    });
    for (order[0..ops.len]) |k| {
        const op = ops[k];
        var label_buf: [32]u8 = undefined;
        var span_buf: [32]u8 = undefined;
        const span = if (op.complete) |c|
            std.fmt.bufPrint(&span_buf, "[{d:>4}, {d:>4}]", .{ op.invoke, c }) catch unreachable
        else
            std.fmt.bufPrint(&span_buf, "[{d:>4}, pending]", .{op.invoke}) catch unreachable;

        var bar: [width + 4]u8 = @splat(' ');
        const start: usize = @intCast((op.invoke - t0) / scale);
        const end: usize = @intCast(((op.complete orelse now) - t0) / scale);
        bar[start] = '|';
        for (start + 1..end) |c| bar[c] = '-';
        bar[end] = if (op.complete == null) '>' else '|';

        std.debug.print("  c{d:<3} {s:<10} {s:<18} {s}  {s} v{d}\n", .{
            op.client, op_label(&label_buf, op), span, bar[0 .. end + 1], replica_name(op.target), op.version,
        });
    }

    std.debug.print("\n  Real-time order forced by the history:\n", .{});
    for (ops) |a| {
        const ac = a.complete orelse continue;
        for (ops) |b| {
            if (ac < b.invoke) {
                var la: [32]u8 = undefined;
                var lb: [32]u8 = undefined;
                std.debug.print("    c{d} {s} completed at t={d} before c{d} {s} was invoked at t={d}\n", .{
                    a.client, op_label(&la, a), ac, b.client, op_label(&lb, b), b.invoke,
                });
            }
        }
    }
    std.debug.print(
        "  No order of these ops that respects real time is a legal register execution,\n" ++
            "  and removing any one op makes the history linearizable again.\n\n",
        .{},
    );
}

// -------------------------------------------------------------------------------------------------
// Driver.
// -------------------------------------------------------------------------------------------------

const Result = struct { ok: bool, trace_hash: u64, ops: u32 };

fn run_seed(gpa: std.mem.Allocator, seed: u64, verbose: bool) !Result {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const ops_budget = 6 + random.uintAtMost(u8, ops_max - 6);
    assert(ops_budget <= ops_max);
    var sim: Sim = .{
        .gpa = gpa,
        .random = random,
        .trace = std.hash.Wyhash.init(0),
        .verbose = verbose,
        .ops_budget = ops_budget,
    };
    defer sim.deinit();

    while (!sim.done()) : (sim.now += 1) {
        // Liveness: with no message loss, every operation must finish quickly.
        assert(sim.now < 10_000);

        for (0..clients_count) |c| {
            const client: u8 = @intCast(c);
            if (sim.clients[client].busy) continue;
            if (sim.now < sim.clients[client].next_invoke_at) continue;
            if (sim.history_len == sim.ops_budget) continue;
            try sim.issue(client);
        }

        // Deliver everything due this tick, in send order. Sends have delay >= 1, so messages
        // produced during delivery always land in a later tick.
        var i: usize = 0;
        while (i < sim.network.items.len) {
            if (sim.network.items[i].deliver_at == sim.now) {
                const msg = sim.network.orderedRemove(i);
                try sim.deliver(msg);
            } else {
                assert(sim.network.items[i].deliver_at > sim.now);
                i += 1;
            }
        }
        if (sim.failure) |f| {
            if (verbose) print_failure(f, sim.now);
            return .{ .ok = false, .trace_hash = sim.trace.final(), .ops = sim.history_len };
        }
    }

    // Final check of every key over the complete history (each key was already checked at each of
    // its completions; this documents that the full history is linearizable).
    for (0..keys_count) |k| sim.check_key(@intCast(k));
    assert(sim.failure == null);
    return .{ .ok = true, .trace_hash = sim.trace.final(), .ops = sim.history_len };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse "sweep";
    var n: u64 = sweep_default;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bug")) {
            bug_enabled = true;
        } else {
            n = try std.fmt.parseInt(u64, arg, 10);
        }
    }

    if (std.mem.eql(u8, mode, "run")) {
        const r = try run_seed(gpa, n, true);
        std.debug.print("seed={d} ops={d} trace={x:0>16} {s}\n", .{
            n, r.ops, r.trace_hash, if (r.ok) "PASS" else "FAIL",
        });
        if (!r.ok) std.process.exit(1);
        return;
    }

    var seed: u64 = 0;
    while (seed < n) : (seed += 1) {
        const r = try run_seed(gpa, seed, false);
        if (!r.ok) {
            std.debug.print("FAIL at seed={d} after {d} seeds. Replay with:\n", .{ seed, seed + 1 });
            std.debug.print("  zig run main.zig -- run {d}{s}\n", .{ seed, if (bug_enabled) " --bug" else "" });
            std.process.exit(1);
        }
    }
    std.debug.print("PASS: {d} seeds\n", .{n});
}
