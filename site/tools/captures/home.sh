# Overview page: one row per (example, flag) with the real sweep result.
# Columns: id, flag, result, first failing seed, trace hash of the failing replay, sweep wall ms
declare -A BUGS=(
 [01]="--bug" [02]="--bug" [03]="--bug --bug-deadlock"
 [04]="--bug-ack-before-fsync --bug-no-checksum" [05]="--bug-no-dedup --bug-reply-stale"
 [06]="--bug" [07]="--bug" [08]="--bug-volatile-vote --bug-no-quorum"
 [09]="--bug-trust-read --bug-misdirect" [10]="--bug-commit-early --bug-view-change-log"
 [11]="--bug-fixed-timeout --bug-no-retry-on-leader-change"
 [12]="--bug-fill-gap --bug-fill-gap+--gen-boundaries"
 [13]="--bug-no-drift-margin --bug-wall-clock"
 [14]="--bug-stale-offset --bug-stale-offset+--buggify")
# A "+" joins several flags into one row. Example 12's plain --bug-fill-gap row is expected to PASS:
# that example shows a random sweep missing its bug.
declare -A COUNT=([01]=10000 [02]=100000 [03]=1000000 [04]=2000 [05]=10000 [06]=20000 [07]=100000 [08]=5000 [09]=10000 [10]=20000 [11]=20000 [12]=100000 [13]=5000 [14]=2000000)
printf 'id\tflag\tcount\tresult\tseed\ttrace\tms\n' > sweeps.tsv
for id in 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do
  dir=$(ls -d "$ROOT"/examples/$id-*/); bin="$BIN_DIR/$id"
  "$ZIG" build-exe -OReleaseSafe "$dir/main.zig" -femit-bin="$bin" --cache-dir "$BIN_DIR/cache" >/dev/null
  for f in none ${BUGS[$id]}; do
    flag=$([ $f = none ] || echo $f | tr + " ")
    t0=$(date +%s%N); out=$("$bin" sweep ${COUNT[$id]} $flag 2>&1 || true); t1=$(date +%s%N)
    seed=$(echo "$out" | sed -n 's/.*FAIL at seed=\([0-9]*\).*/\1/p' | head -1)
    if [ -n "$seed" ]; then res=FAIL; tr=$("$bin" run $seed $flag 2>&1 | grep -o 'trace=[0-9a-f]*' | tail -1 | cut -d= -f2); else res=PASS; seed=-; tr=-; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' $id $f ${COUNT[$id]} $res $seed $tr $(( (t1-t0)/1000000 )) >> sweeps.tsv
  done
done
# Example 06: the swarm vs fixed-mix contrast, the one result that needs a large count.
"$BIN_DIR/06" sweep 20000 --bug --no-swarm > swarm-off.txt 2>&1 || true
"$BIN_DIR/06" sweep 20000 --bug > swarm-on.txt 2>&1 || true
# Example 02: simulated clock time covered by the default sweep (wall time measured outside).
( time "$BIN_DIR/02" sweep 100000 ) > time-compression.txt 2>&1 || true
