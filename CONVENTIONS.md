# Conventions for every example (internal brief; also useful to readers)

- Language: Zig 0.17.0, compiler at /home/user/tools/zig-0.17.0/zig. Single file `main.zig` per example, std only.
- Template / reference style: /home/user/workspace/dst-guide/examples/01-seeded-randomness/main.zig
- Verified Zig 0.17 API facts:
  - `pub fn main(init: std.process.Init) !void`; args: `var it = init.minimal.args.iterate(); _ = it.skip(); it.next()`
  - allocator: `init.gpa`. ArrayList is unmanaged: `var l: std.ArrayList(T) = .empty; try l.append(gpa, x); l.deinit(gpa);`
  - `std.Random.DefaultPrng.init(seed)`, `.random()`, `random.uintLessThan`, `uintAtMost`, `intRangeAtMost`, `boolean`, `int`
  - `std.hash.Wyhash.init(0)` / `.update(bytes)` / `.final()`, `std.hash.Crc32.hash(bytes)`
  - printing: `std.debug.print`; exit: `std.process.exit(1)`
  - If something else does not compile, read /home/user/tools/zig-0.17.0/lib/std/ to find the 0.17 API.
- CLI (identical for every example):
  - `zig run main.zig -- run <seed> [--bug...]`   one seed, verbose trace of key events, prints `seed=… trace=<hex> PASS|FAIL`
  - `zig run main.zig -- sweep <count> [--bug...]` seeds 0..count-1, stops at first failure, prints `FAIL at seed=N` and the exact replay command; otherwise `PASS: <count> seeds`
  - Exit code 1 on failure.
- Determinism rules: ALL randomness from one seeded PRNG (derive sub-seeds from it); no wall clock, no threads, no real IO/sockets/files, no iteration over unordered containers whose order could depend on addresses. Time is a simulated tick counter. Every observable event is folded into a Wyhash trace so two runs of the same seed print the same trace hash.
- Correct code must pass a sweep of the default count (choose a count that finishes in < ~20 s in ReleaseSafe). Each `--bug` flag must be found by the sweep within that count, and `run <failing seed> --bug` must reproduce the same failure and trace hash every time.
- Use assertions/invariant checkers that run DURING the simulation (not only at the end), the way TigerBeetle does.
- Comments in the code should teach: explain what is simulated, what invariant is checked, why the bug escapes ordinary tests.
- NOTES.md next to main.zig with sections: Concept introduced; What is simulated vs real; Invariants; The planted bug(s) and why normal tests miss them; How TigerBeetle does this (cite real files/functions in /home/user/workspace/tigerbeetle/src); Verified run (paste REAL output of: sweep without bug, sweep with bug, and the replay run executed twice showing identical trace); Exercises (2 short ideas).
