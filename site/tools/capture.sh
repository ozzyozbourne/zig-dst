#!/usr/bin/env bash
# Re-runs every example (and TigerBeetle's VOPR) and stores the raw output under site/data/,
# then re-embeds that output into the HTML pages. Usage: site/tools/capture.sh [NN ...]
#   ZIG       Zig 0.17 compiler        (default: zig on PATH)
#   TB_DIR    TigerBeetle checkout     (default: ../tigerbeetle next to dst-guide; only for "tb")
set -euo pipefail
SITE=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$SITE/.." && pwd)
ZIG=${ZIG:-zig}
BIN_DIR=${BIN_DIR:-/tmp/dst-bin}
export ZIG BIN_DIR ROOT
export TB_DIR=${TB_DIR:-$(cd "$ROOT/.." && pwd)/tigerbeetle}
mkdir -p "$BIN_DIR"
want=("$@"); [ ${#want[@]} -eq 0 ] && want=($(ls "$SITE/tools/captures" | sed 's/\.sh$//'))
for id in "${want[@]}"; do
  export OUT="$SITE/data/$id"; rm -rf "$OUT"; mkdir -p "$OUT"
  dir=$(ls -d "$ROOT"/examples/"$id"-*/ 2>/dev/null || true)
  if [ -n "$dir" ]; then
    "$ZIG" build-exe -OReleaseSafe "$dir/main.zig" -femit-bin="$BIN_DIR/$id" --cache-dir "$BIN_DIR/cache" >/dev/null
    export BIN="$BIN_DIR/$id"
  fi
  echo "capturing $id"
  (cd "$OUT" && bash -eu "$SITE/tools/captures/$id.sh")
done
python3 "$SITE/tools/embed.py"
