# Example 05 — simulated network. cwd = site/data/05, $BIN = ReleaseSafe build of main.zig.
( time "$BIN" sweep 10000 ) > sweep.txt 2>&1 || true
( time "$BIN" sweep 10000 --bug-no-dedup ) > sweep-no-dedup.txt 2>&1 || true
( time "$BIN" sweep 10000 --bug-reply-stale ) > sweep-reply-stale.txt 2>&1 || true
# The centerpiece: seed 0 with the dedup bug, with every packet-level event (--packets only adds log lines).
"$BIN" run 0 --bug-no-dedup --packets > run0-no-dedup-packets.txt 2>&1 || true
# Determinism: the same replay twice, without --packets (the documented form).
"$BIN" run 0 --bug-no-dedup > run0-no-dedup-a.txt 2>&1 || true
"$BIN" run 0 --bug-no-dedup > run0-no-dedup-b.txt 2>&1 || true
"$BIN" run 0 --bug-reply-stale > run0-reply-stale.txt 2>&1 || true
# The correct code on seed 0, all the way through the heal (safety + liveness phases).
"$BIN" run 0 --packets > run0-packets.txt 2>&1 || true
# Seed 1: clients are still busy after the heal, so the liveness phase does real work.
"$BIN" run 1 --packets > run1-packets.txt 2>&1 || true
# Per-seed stats for seeds 0..499: parameters, outcome with each bug, activity after the heal.
for s in $(seq 0 499); do
  "$BIN" run "$s" > /tmp/dst05-seed.txt 2>&1 && ok=1 || ok=0
  "$BIN" run "$s" --bug-no-dedup > /dev/null 2>&1 && nd=1 || nd=0
  "$BIN" run "$s" --bug-reply-stale > /dev/null 2>&1 && rs=1 || rs=0
  awk -v s="$s" -v ok="$ok" -v nd="$nd" -v rs="$rs" '
    /clients=/ { split($1, a, "="); c = a[2] }
    /packet_loss_probability=/ { split($1, a, "="); loss = a[2] + 0 }
    /packet_replay_probability=/ { split($1, a, "="); rep = a[2] + 0 }
    /one_way_delay_mean=/ { split($1, a, "="); dm = a[2] }
    /transition_to_liveness_mode/ { heal = 1; ht = $0; sub(/^ *\[ */, "", ht); sub(/\].*/, "", ht) }
    heal && /client [0-9]+: (send|reply|timeout)/ { after++ }
    /^seed=/ { split($2, a, "="); t = a[2] }
    END { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n", s, c, loss, rep, dm, ok, nd, rs, ht, after, t }
  ' /tmp/dst05-seed.txt
done > per-seed.tsv
rm -f /tmp/dst05-seed.txt
sed -i '1i seed\tclients\tloss_pct\treplay_pct\tdelay_mean\tpass_correct\tpass_no_dedup\tpass_reply_stale\theal_tick\tclient_events_after_heal\tticks' per-seed.tsv
