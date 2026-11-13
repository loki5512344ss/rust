#!/usr/bin/env bash
# layout-check.sh — does a measured A-vs-B difference survive a layout change?
#
# The size of the environment shifts the initial stack, so the same binary
# gets different stack alignment and cache/page placement for every pad size.
# That alone can swing a benchmark by several percent and has produced "wrong
# data without doing anything obviously wrong" (Mytkowicz, Diwan, Hauswirth,
# Sweeney, ASPLOS 2009). A win that flips sign or shrinks a lot when only the
# environment grows is layout luck, not a property of the patch.
#
# What this does NOT cover: link order and function/loop alignment. Those are
# fixed inside each binary, so no environment padding can move them. Test them
# by hand and re-run this script on each variant:
#   link order:  RUSTFLAGS='-C link-arg=-Wl,--sort-section=name' vs without,
#                or shuffle the order of object files / codegen units with
#                -C codegen-units=N for a few N;
#   alignment:   RUSTFLAGS='-C llvm-args=-align-all-functions=5' (32 B) vs
#                '=6' (64 B); -align-all-nofallthru-blocks does the same for
#                branch targets. Build A and B once per setting.
# Passing this check is necessary, not sufficient.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  layout-check.sh [options] -- <cmdA> <cmdB>

For each pad size, exports LAYOUT_PAD=<that many bytes of 'x'> and runs
hyperfine (interleaved ABBA blocks) on the two commands. Pad 0
leaves LAYOUT_PAD unset. Prints one row per pad and a verdict:
  stable            the sign of the delta is the same for every pad and the
                    smallest |delta| is at least half the largest
  layout-sensitive  anything else; do not report it as a speedup

Options:
  --runs N       runs per command per pad (default: 25, at least 10)
  --pads "LIST"  space separated pad sizes in bytes (default: "0 64 1024 4000")
  -h, --help     show this help

Commands are run by hyperfine through the shell and inherit LAYOUT_PAD.
Each pad is measured in 5 interleaved blocks (AB, BA, AB, ...) like bench-ab.sh.
Needs hyperfine and python3. Does not check machine load: run it on a quiet one.
Exit: 0 ok (either verdict), 1 measurement failed or refused, 2 usage/tool.
EOF
}

die() { printf 'layout-check.sh: %s\n' "$*" >&2; exit 2; }
fail() { printf 'layout-check.sh: %s\n' "$*" >&2; exit 1; }

RUNS=25 PADS="0 64 1024 4000"
while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    --runs|--pads)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      case "$1" in --runs) RUNS=$2 ;; --pads) PADS=$2 ;; esac
      shift 2 ;;
    *) die "unknown option '$1' (commands go after --)" ;;
  esac
done

[[ "$RUNS" =~ ^[0-9]+$ ]] || die "--runs must be a positive integer"
(( RUNS >= 10 )) || die "--runs must be >= 10 (5 blocks of >= 2 runs)"
read -r -a PAD_LIST <<<"$PADS"
(( ${#PAD_LIST[@]} >= 2 )) || die "--pads needs at least two sizes to compare layouts"
for p in "${PAD_LIST[@]}"; do
  [[ "$p" =~ ^[0-9]+$ ]] || die "pad '$p' is not a non-negative integer"
  # Linux caps one environment string at 128 KiB; stay well below it.
  (( p <= 100000 )) || die "pad '$p' is too large (max 100000)"
done
(( $# == 2 )) || die "need exactly two commands after -- (got $#)"
CMD_A=$1
CMD_B=$2

command -v hyperfine >/dev/null 2>&1 \
  || die "hyperfine not found: cargo install hyperfine (or pacman -S hyperfine)"
command -v python3 >/dev/null 2>&1 \
  || die "python3 not found: install python3 (needed to aggregate the results)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/layout-check.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

# hyperfine is called directly instead of through bench-ab.sh: hyperfine 2.x
# renamed the JSON fields bench-ab.sh reads ("times" became "measurements"),
# and this script must work with both schemas (see verdict.py).
BLOCKS=5
BASE=$((RUNS / BLOCKS))
REM=$((RUNS % BLOCKS))
FILES=()
for p in "${PAD_LIST[@]}"; do
  # The padded variable lives in a subshell so it cannot leak into the next
  # pad or into this script's own later steps.
  for ((b = 0; b < BLOCKS; b++)); do
    N=$((BASE + (b < REM ? 1 : 0)))
    W=0
    if (( b == 0 )); then W=3; fi
    ORDER=AB
    if (( b % 2 == 1 )); then ORDER=BA; fi
    FILE=$(printf '%s/pad-%s-block-%02d-%s.json' "$TMP" "$p" "$((b + 1))" "$ORDER")
    CMDS=("$CMD_A" "$CMD_B")
    if [[ "$ORDER" == BA ]]; then CMDS=("$CMD_B" "$CMD_A"); fi
    (
      if (( p > 0 )); then
        LAYOUT_PAD=$(head -c "$p" /dev/zero | tr '\0' x)
        export LAYOUT_PAD
      else
        unset LAYOUT_PAD
      fi
      # --shell=default: hyperfine 2.0's --shell=none default word-splits the
      # command instead of running it through sh, so shell syntax silently
      # measures the wrong thing. LAYOUT_PAD is inherited either way (checked:
      # printenv sees it inside a measured run).
      exec hyperfine --shell=default --warmup "$W" --runs "$N" --export-json "$FILE" -- "${CMDS[@]}"
    ) >"$TMP/hyperfine.log" 2>&1 \
      || { cat "$TMP/hyperfine.log" >&2; fail "hyperfine failed for pad $p, block $((b + 1)) (command itself exited nonzero?)"; }
    FILES+=("$p=$FILE")
  done
  printf 'pad %s bytes: measured\n' "$p"
done

cat >"$TMP/verdict.py" <<'PY'
import json, sys
cmd_a, cmd_b, runs, *items = sys.argv[1:]
def times(res):
    # hyperfine 1.x: "times" in seconds. hyperfine 2.x: "measurements" with
    # time_wall_clock.value in seconds.
    if "times" in res:
        return res["times"]
    return [m["time_wall_clock"]["value"] for m in res["measurements"]]
def median(xs):
    s = sorted(xs); n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2
raw = {}
for item in items:
    spec, path = item.split("=", 1)
    order = "AB" if path.endswith("-AB.json") else "BA"
    with open(path, encoding="utf-8") as fh:
        res = json.load(fh)["results"]
    ta, tb = (times(res[0]), times(res[1])) if order == "AB" else (times(res[1]), times(res[0]))
    side = raw.setdefault(int(spec), {"A": [], "B": []})
    side["A"] += ta; side["B"] += tb
rows = []
for pad, side in raw.items():
    a, b = median(side["A"]) * 1e3, median(side["B"]) * 1e3
    rows.append((pad, a, b, (b - a) / a * 100 if a else 0.0))
print("A: %s\nB: %s\nruns/command per pad=%s\n" % (cmd_a, cmd_b, runs))
print("%9s %12s %12s %9s" % ("pad bytes", "A med ms", "B med ms", "delta %"))
for pad, a, b, d in rows:
    print("%9d %12.3f %12.3f %+9.2f" % (pad, a, b, d))
deltas = [d for _, _, _, d in rows]
signs = {(d > 0) - (d < 0) for d in deltas}
lo, hi = min(abs(d) for d in deltas), max(abs(d) for d in deltas)
same_sign = len(signs) == 1 and 0 not in signs
stable = same_sign and lo >= hi / 2
print()
if stable:
    print("verdict: stable (same sign for every pad; smallest |delta| %.2f%% >= half of largest %.2f%%)" % (lo, hi))
    print("note: this only rules out environment/stack layout; link order and function alignment are not covered.")
else:
    why = "sign changes or is zero across pads" if not same_sign else \
          "smallest |delta| %.2f%% < half of largest %.2f%%" % (lo, hi)
    print("verdict: layout-sensitive (%s)" % why)
    print("A layout-sensitive result must not be reported as a speedup: the difference is explained by memory/code")
    print("placement, not by the change. Re-measure with instr-count.sh or fix the layout before drawing a conclusion.")
PY

python3 "$TMP/verdict.py" "$CMD_A" "$CMD_B" "$RUNS" "${FILES[@]}"
