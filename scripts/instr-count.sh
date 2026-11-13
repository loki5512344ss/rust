#!/usr/bin/env bash
# instr-count.sh — A/B of two commands by user-space hardware counters.
#
# Wall time moves with frequency scaling, neighbours and cache state;
# user-space instructions barely move between runs, so a real change in work
# shows up here even when the clock is noisy. Instructions are not time,
# though: a patch can cut instructions and still lose on stalls or IPC, so
# read cycles:u next to them and confirm with bench-ab.sh before claiming a win.
# Runs are interleaved A B B A A B B A ... so drift lands on both sides.

set -euo pipefail

# perf's CSV output is locale-dependent: under a comma-decimal locale (e.g.
# ru_RU.UTF-8) the percent-enabled field is printed as "66,67" and is itself
# split by the -x, separator, so the multiplexing check in aggregate.py would
# read a truncated number. Counter values are plain integers in every locale,
# but the parser must not depend on the caller's environment.
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage:
  instr-count.sh [options] -- <cmdA> <cmdB>

Each command is run through `sh -c` under
  perf stat -x, -e EVENTS -- sh -c "<cmd>"
in ABBA order and the per-event median, min and max of every side are printed
with the percent delta of B against A.

Options:
  --runs N       runs per command (default: 10)
  --events LIST  comma separated perf events
                 (default: instructions:u,cycles:u,branches:u,branch-misses:u)
  --json FILE    write every raw count and the summary to FILE
  -h, --help     show this help

stdout of the commands is discarded; their stderr is passed through.
Never uses sudo. If perf cannot open the events nothing is measured and the
reason is printed. Exit: 0 ok, 1 measurement failed or refused, 2 usage/tool.
EOF
}

die() { printf 'instr-count.sh: %s\n' "$*" >&2; exit 2; }
fail() { printf 'instr-count.sh: %s\n' "$*" >&2; exit 1; }

RUNS=10 EVENTS="instructions:u,cycles:u,branches:u,branch-misses:u" JSON_OUT=""
while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    --runs|--events|--json)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      case "$1" in
        --runs) RUNS=$2 ;; --events) EVENTS=$2 ;; --json) JSON_OUT=$2 ;;
      esac
      shift 2 ;;
    *) die "unknown option '$1' (commands go after --)" ;;
  esac
done

[[ "$RUNS" =~ ^[0-9]+$ ]] || die "--runs must be a positive integer"
(( RUNS >= 1 )) || die "--runs must be a positive integer"
[[ "$EVENTS" =~ ^[A-Za-z0-9_.:/=,-]+$ ]] || die "--events must be a comma separated list of perf event names"
(( $# == 2 )) || die "need exactly two commands after -- (got $#)"
CMD_A=$1
CMD_B=$2

command -v perf >/dev/null 2>&1 \
  || die "perf not found: pacman -S perf / apt install linux-perf (or use bench-ab.sh for wall time)"
command -v python3 >/dev/null 2>&1 \
  || die "python3 not found: install python3 (needed to aggregate the counts)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/instr-count.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null) || PARANOID=unknown

refuse() {
  printf 'instr-count.sh: perf stat cannot count %s here: %s\n' "$EVENTS" "$1" >&2
  printf '  /proc/sys/kernel/perf_event_paranoid = %s\n' "$PARANOID" >&2
  printf '  paranoid >= 3 blocks every unprivileged event; <= 2 allows user-space (:u) counting.\n' >&2
  printf '  try: a one-time root action (sysctl kernel.perf_event_paranoid=1), or events that exist here\n' >&2
  printf '       (perf list), or software-only timing with bench-ab.sh. In a VM without a virtual PMU\n' >&2
  printf '       hardware events are never available. No number was measured.\n' >&2
  exit 1
}

# One run of `true` proves the events open and count before any real command
# spends time; a "<not supported>" counter must never reach the statistics.
if ! perf stat -x, -o "$TMP/probe.csv" -e "$EVENTS" -- sh -c true \
     >/dev/null 2>"$TMP/probe.err"; then
  refuse "$(head -n 3 "$TMP/probe.err" | tr '\n' ' ')"
fi
if grep -qE '<not (supported|counted)>' "$TMP/probe.csv" 2>/dev/null; then
  refuse "$(grep -E '<not (supported|counted)>' "$TMP/probe.csv" | cut -d, -f3 | tr '\n' ' ')reported <not supported>/<not counted>"
fi
grep -qE '^[0-9]+,' "$TMP/probe.csv" 2>/dev/null \
  || refuse "perf produced no counter lines"

run_one() { # side index cmd
  local file="$TMP/$1-$2.csv"
  if ! perf stat -x, -o "$file" -e "$EVENTS" -- sh -c "$3" >/dev/null; then
    fail "command $1 failed or perf aborted on run $2: $3"
  fi
}

IA=0 IB=0
for ((k = 0; k < RUNS; k++)); do
  if (( k % 2 == 0 )); then ORDER="A B"; else ORDER="B A"; fi
  for side in $ORDER; do
    if [[ "$side" == A ]]; then
      run_one A "$IA" "$CMD_A"; IA=$((IA + 1))
    else
      run_one B "$IB" "$CMD_B"; IB=$((IB + 1))
    fi
  done
done

cat >"$TMP/aggregate.py" <<'PY'
import glob, json, os, statistics, sys
cmd_a, cmd_b, out, runs, tmp = sys.argv[1:]
counts = {"A": {}, "B": {}}
pct_min = 100.0
for side in ("A", "B"):
    for path in sorted(glob.glob(os.path.join(tmp, side + "-*.csv"))):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if not line.strip() or line.startswith("#"):
                    continue
                f = line.rstrip("\n").split(",")
                # value,unit,event,run-time,percent-enabled,...
                if len(f) < 3 or not f[0].isdigit():
                    sys.exit("instr-count.sh: unparsable or uncounted line in %s: %r" % (path, line))
                counts[side].setdefault(f[2], []).append(int(f[0]))
                if len(f) > 4 and f[4].replace(".", "", 1).isdigit():
                    pct_min = min(pct_min, float(f[4]))
events = list(counts["A"])
for side in ("A", "B"):
    for ev in events:
        if len(counts[side].get(ev, [])) != int(runs):
            sys.exit("instr-count.sh: event %s has %d samples on side %s, expected %s"
                     % (ev, len(counts[side].get(ev, [])), side, runs))
print("A: %s\nB: %s" % (cmd_a, cmd_b))
print("runs/command=%s (ABBA)\n" % runs)
print("%-16s %14s %14s %9s  %-27s %-27s %s" % ("event", "A median", "B median", "delta %", "A min..max", "B min..max", "note"))
summary = {}
for ev in events:
    a, b = counts["A"][ev], counts["B"][ev]
    ma, mb = statistics.median(a), statistics.median(b)
    delta = (mb - ma) / ma * 100 if ma else float("nan")
    # Overlapping ranges mean some A runs were slower than some B runs (or
    # the reverse): the medians alone do not separate the two commands.
    note = "ranges overlap" if max(min(a), min(b)) <= min(max(a), max(b)) else ""
    print("%-16s %14.0f %14.0f %+9.2f  %-27s %-27s %s" % (
        ev, ma, mb, delta, "%d..%d" % (min(a), max(a)), "%d..%d" % (min(b), max(b)), note))
    summary[ev] = {"median": {"A": ma, "B": mb}, "delta_pct": delta,
                   "min": {"A": min(a), "B": min(b)}, "max": {"A": max(a), "B": max(b)}}
if pct_min < 100.0:
    print("\nwarning: counters were multiplexed (lowest enabled share %.1f%%); counts are scaled estimates, use fewer events." % pct_min)
if out:
    payload = {"tool": "instr-count.sh", "command_a": cmd_a, "command_b": cmd_b,
               "runs_per_command": int(runs), "raw": counts, "summary": summary}
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
    print("json: %s" % out)
PY

python3 "$TMP/aggregate.py" "$CMD_A" "$CMD_B" "$JSON_OUT" "$RUNS" "$TMP"
