# Example 09 — storage faults, fault atlas, storage checker. cwd = site/data/09, $BIN = binary.
# Sweeps: correct code and each planted bug.
( time "$BIN" sweep 10000 ) > sweep.txt 2>&1 || true
"$BIN" sweep 10000 --bug-trust-read > sweep-trust-read.txt 2>&1 || true
"$BIN" sweep 10000 --bug-misdirect > sweep-misdirect.txt 2>&1 || true
# Full event replays (--all-events also prints appends and client reads; trace hash unchanged).
"$BIN" run 1 --bug-misdirect --all-events > run1-misdirect-all.txt 2>&1 || true
"$BIN" run 1 --all-events > run1-correct-all.txt 2>&1 || true
"$BIN" run 0 --bug-trust-read --all-events > run0-trust-read-all.txt 2>&1 || true
"$BIN" run 0 --all-events > run0-correct-all.txt 2>&1 || true
# Determinism: the documented replays, each run twice.
"$BIN" run 1 --bug-misdirect > run1-misdirect-a.txt 2>&1 || true
"$BIN" run 1 --bug-misdirect > run1-misdirect-b.txt 2>&1 || true
"$BIN" run 0 --bug-trust-read > run0-trust-read-a.txt 2>&1 || true
"$BIN" run 0 --bug-trust-read > run0-trust-read-b.txt 2>&1 || true
# The misdirect bug caught by the storage checker instead of a client read.
"$BIN" run 12 --bug-misdirect > run12-misdirect.txt 2>&1 || true
# Per-seed statistics: event counts per kind from the verbose `run` output, for 3 modes.
summarize='
/faults: read=/ { match($0, /read=[0-9]+/); rp=substr($0, RSTART+5, RLENGTH-5);
  match($0, /write=[0-9]+/); wp=substr($0, RSTART+6, RLENGTH-6); match($0, /misdirect=[0-9]+/); mp=substr($0, RSTART+10, RLENGTH-10);
  match($0, /rot=[0-9]+/); op=substr($0, RSTART+4, RLENGTH-4) }
/atlas replica/ { x += gsub(/x/, "x", $4) }
/ fault_read_flip / { rf++ } / fault_write_flip / { wf++ } / fault_misdirect / { md++ } / fault_rot / { ro++ }
/ repair / { rep++ } / scrub_repair / { sr++ } / checkpoint / { cp++ }
/^ +t= *[0-9]+ FAIL / { match($0, /t= *[0-9]+/); ft=substr($0, RSTART+2, RLENGTH-2); gsub(/ /, "", ft) }
/^seed=/ { split($2, tr, "="); res=$3; reason=($4 == "" ? "-" : $4) }
END { printf "%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\n", seed, mode, res, reason, (ft == "" ? "-" : ft),
  rf, wf, md, ro, rep, sr, cp, x, rp, wp, mp, op, tr[2] }'
{
  printf "seed\tmode\tresult\treason\tfail_t\tread_flip\twrite_flip\tmisdirect\trot\trepair\tscrub_repair\tcheckpoints\tatlas_x\tread_pct\twrite_pct\tmisdirect_pct\trot_pct\ttrace\n"
  for s in $(seq 0 299); do
    "$BIN" run "$s" 2>&1 | awk -v seed="$s" -v mode=correct "$summarize"
    "$BIN" run "$s" --bug-trust-read 2>&1 | awk -v seed="$s" -v mode=trust-read "$summarize"
    "$BIN" run "$s" --bug-misdirect 2>&1 | awk -v seed="$s" -v mode=misdirect "$summarize"
  done
} > per-seed.tsv
