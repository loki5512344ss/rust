#!/usr/bin/env bash
# bench-ab.sh — honest A/B of two commands with hyperfine.
#
# hyperfine runs A to completion, then B, so warming or a neighbour waking
# between them becomes the measured delta. Small alternating blocks (ABBA)
# split drift across both sides; per-block medians expose what is left.

set -euo pipefail
usage() {
  cat <<'EOF'
Usage:
  bench-ab.sh [options] -- <cmdA> <cmdB> [extra hyperfine args...]

Options:
  --warmup N     warmup runs before the first block (default: 3)
  --runs N       total measured runs per command (default: 25)
  --blocks N     interleaved blocks (default: 5); runs/blocks per block
  --prepare CMD  run CMD before every measured run (hyperfine --prepare)
  --max-load F   refuse when 1-min loadavg exceeds F (default: nproc)
  --allow-busy   run anyway on a busy machine
  --json FILE    write raw per-run times and summary to FILE
  -h, --help     show this help
Extra args after the two commands go to hyperfine verbatim (--shell=none,
--export-markdown ...). Our --runs/--warmup/--export-json come last, so they
win over conflicting extras. Exit: 0 ok, 1 busy/failed run, 2 usage/tool.
EOF
}

die() { printf 'bench-ab.sh: %s\n' "$*" >&2; exit 2; }
fail() { printf 'bench-ab.sh: %s\n' "$*" >&2; exit 1; }

WARMUP=3 RUNS=25 BLOCKS=5 PREPARE="" ALLOW_BUSY=0 JSON_OUT=""
# nproc is coreutils but may be absent in stripped containers; never let the
# default value abort the script before the real tool checks produce a hint.
MAX_LOAD=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    --allow-busy) ALLOW_BUSY=1; shift ;;
    --warmup|--runs|--blocks|--prepare|--max-load|--json)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      case "$1" in
        --warmup) WARMUP=$2 ;; --runs) RUNS=$2 ;; --blocks) BLOCKS=$2 ;;
        --prepare) PREPARE=$2 ;; --max-load) MAX_LOAD=$2 ;; --json) JSON_OUT=$2 ;;
      esac
      shift 2 ;;
    *) die "unknown option '$1' (commands go after --)" ;;
  esac
done

[[ "$WARMUP" =~ ^[0-9]+$ ]] || die "--warmup must be a non-negative integer"
[[ "$RUNS" =~ ^[0-9]+$ ]] || die "--runs must be a positive integer"
[[ "$BLOCKS" =~ ^[0-9]+$ ]] || die "--blocks must be a positive integer"
[[ "$MAX_LOAD" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--max-load must be a number"
(( BLOCKS >= 1 )) || die "--blocks must be >= 1"
# Below two runs per side hyperfine cannot report a spread worth reading.
(( RUNS >= 2 * BLOCKS )) || die "--runs must be >= 2 per block (need >= $((2 * BLOCKS)))"

COMMANDS=("$@")
(( ${#COMMANDS[@]} >= 2 )) || die "need two commands after --"
CMD_A=${COMMANDS[0]}
CMD_B=${COMMANDS[1]}
EXTRA=("${COMMANDS[@]:2}")

command -v hyperfine >/dev/null 2>&1 \
  || die "hyperfine not found: cargo install hyperfine (or pacman -S hyperfine)"
command -v python3 >/dev/null 2>&1 \
  || die "python3 not found: install python3 (needed to aggregate the raw JSON)"

# 1-min loadavg reacts fastest to a benchmark that started elsewhere.
load_busy() { awk -v l="$1" -v m="$MAX_LOAD" 'BEGIN { exit !(l > m) }'; }
LOAD_1=$(awk '{ print $1 }' /proc/loadavg)
if load_busy "$LOAD_1" && (( ! ALLOW_BUSY )); then
  printf 'bench-ab.sh: refusing: 1-min loadavg %s > %s; another process is measuring (use --allow-busy).\n' \
    "$LOAD_1" "$MAX_LOAD" >&2
  exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/bench-ab.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

BASE=$((RUNS / BLOCKS))
REM=$((RUNS % BLOCKS))
FILES=()
for ((b = 0; b < BLOCKS; b++)); do
  N=$((BASE + (b < REM ? 1 : 0)))
  W=0
  if (( b == 0 )); then W=$WARMUP; fi
  ORDER=AB
  if (( b % 2 == 1 )); then ORDER=BA; fi
  FILE=$(printf '%s/block-%02d-%s.json' "$TMP" "$((b + 1))" "$ORDER")
  PRE=()
  if [[ -n "$PREPARE" ]]; then PRE=(--prepare "$PREPARE"); fi
  CMDS=("$CMD_A" "$CMD_B")
  if [[ "$ORDER" == BA ]]; then CMDS=("$CMD_B" "$CMD_A"); fi
  printf 'block %d/%d: order %s, %d runs per command\n' "$((b + 1))" "$BLOCKS" "$ORDER" "$N"
  hyperfine --warmup "$W" --runs "$N" "${PRE[@]}" "${EXTRA[@]}" \
    --export-json "$FILE" -- "${CMDS[@]}" >/dev/null \
    || fail "hyperfine failed in block $((b + 1)) (command itself exited nonzero?)"
  FILES+=("$FILE")
done

cat >"$TMP/aggregate.py" <<'PY'
import json, statistics, sys
cmd_a, cmd_b, out, warmup, runs, blocks, *paths = sys.argv[1:]
raw = {"A": [], "B": []}
per = []
for path in paths:
    order = "AB" if path.endswith("-AB.json") else "BA"
    with open(path, encoding="utf-8") as fh:
        res = json.load(fh)["results"]
    ta, tb = (res[0]["times"], res[1]["times"]) if order == "AB" else (res[1]["times"], res[0]["times"])
    raw["A"] += ta; raw["B"] += tb
    per.append((len(per) + 1, order, ta, tb))
def quant(xs, p):
    s = sorted(xs); k = (len(s) - 1) * p; lo = int(k); hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)
print(f"A: {cmd_a}\nB: {cmd_b}")
print(f"warmup={warmup} runs/command={runs} blocks={blocks} (ABBA)\n")
print(f"{'block':>5} {'order':>5} {'A med ms':>11} {'B med ms':>11} {'delta %':>8}")
for i, order, ta, tb in per:
    a, b = statistics.median(ta) * 1e3, statistics.median(tb) * 1e3
    d = (b - a) / a * 100 if a else 0.0
    print(f"{i:>5} {order:>5} {a:>11.3f} {b:>11.3f} {d:>+8.2f}")
a, b = statistics.median(raw["A"]) * 1e3, statistics.median(raw["B"]) * 1e3
delta = (b - a) / a * 100 if a else 0.0
iqr = {k: [quant(raw[k], 0.25) * 1e3, quant(raw[k], 0.75) * 1e3] for k in ("A", "B")}
print(f"\nn per side: {len(raw['A'])} / {len(raw['B'])}")
print(f"A median: {a:.3f} ms  (IQR {iqr['A'][0]:.3f}..{iqr['A'][1]:.3f})")
print(f"B median: {b:.3f} ms  (IQR {iqr['B'][0]:.3f}..{iqr['B'][1]:.3f})")
print(f"median delta (B vs A): {delta:+.2f} %")
print("verdict: below the 1% floor -> noise, not a result" if abs(delta) < 1.0 else "verdict: above the 1% floor -> confirm with a fresh session before claiming a win")
if out:
    payload = {"tool": "bench-ab.sh", "command_a": cmd_a, "command_b": cmd_b,
               "warmup": int(warmup), "runs_per_command": int(runs), "blocks": int(blocks),
               "raw": raw, "per_block": [{"block": i, "order": o, "A": ta, "B": tb} for i, o, ta, tb in per],
               "summary": {"median_ms": {"A": a, "B": b}, "delta_pct": delta, "iqr_ms": iqr,
                           "n": {"A": len(raw["A"]), "B": len(raw["B"])}}}
    with open(out, "w", encoding="utf-8") as fh: json.dump(payload, fh, indent=2)
    print(f"json: {out}")
PY

python3 "$TMP/aggregate.py" "$CMD_A" "$CMD_B" "$JSON_OUT" "$WARMUP" "$RUNS" "$BLOCKS" "${FILES[@]}"

# A busy machine still yields a number; just never quote it without this.
LOAD_2=$(awk '{ print $1 }' /proc/loadavg)
if load_busy "$LOAD_2"; then
  printf 'warning: loadavg is now %s (> %s); the machine was not quiet. Re-run before trusting it.\n' \
    "$LOAD_2" "$MAX_LOAD" >&2
fi
