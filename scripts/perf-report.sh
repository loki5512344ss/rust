#!/usr/bin/env bash
# perf-report.sh — one command, one directory of CPU evidence.
#
# perf stat answers "how much" (cycles, IPC, misses), perf report answers
# "where", and perf annotate answers "which instruction". All three must come
# from the same run and the same binary, or they describe different programs.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  perf-report.sh [--out DIR] -- <command...>

Runs the command under:
  perf stat -r 7 -e cycles,instructions,branches,branch-misses,cache-references,cache-misses
  perf record -F 999 -g  ->  perf report --stdio --sort=dso,sym
                          ->  perf annotate --stdio
and writes every output into DIR (default: <repo>/target/perf/<UTC stamp>).

Options:
  --out DIR   output directory
  -h, --help  show this help

Never uses sudo. If perf is missing or perf_event_paranoid forbids events,
the exact reason is printed and `samply record` is suggested instead.
Exit: 0 ok, 1 run failed, 2 usage/missing tool, 3 perf not permitted.
EOF
}

die() { printf 'perf-report.sh: %s\n' "$*" >&2; exit 2; }

OUT=""
while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out)
      [[ $# -ge 2 ]] || die "--out needs a directory"
      OUT=$2; shift 2 ;;
    --) shift; break ;;
    *) die "unknown option '$1' (the command goes after --)" ;;
  esac
done
(( $# )) || die "missing command after --"
CMD=("$@")

command -v perf >/dev/null 2>&1 \
  || die "perf not found: pacman -S perf / apt install linux-perf (or use: samply record -- ${CMD[*]})"

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=$PWD
if [[ -z "$OUT" ]]; then
  OUT="$ROOT/target/perf/$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p -- "$OUT"

# paranoid >= 3 disables all unprivileged events; 2 hides kernel symbols but
# still samples our own process, which is enough for user-space Rust.
PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null) || PARANOID=unknown
[[ "$PARANOID" =~ ^-?[0-9]+$ ]] || PARANOID=unknown
if [[ "$PARANOID" != unknown ]] && (( PARANOID >= 3 )); then
  printf 'perf blocked: /proc/sys/kernel/perf_event_paranoid=%s (>=3 disables all unprivileged events).\n' \
    "$PARANOID" >&2
  printf 'A one-time root action (sysctl kernel.perf_event_paranoid=1) is needed, or use:\n' >&2
  printf '  samply record -- ' >&2
  printf '%q ' "${CMD[@]}" >&2
  printf '\n' >&2
  exit 3
fi
if [[ "$PARANOID" == 2 ]]; then
  printf 'note: perf_event_paranoid=2 — user-space samples only; kernel symbols will be unresolved.\n'
fi

# perf stat prints its counters to stderr, where the workload's stderr also
# lands. One combined file is the honest record; stdout is kept separately.
denied() {
  grep -qiE 'permission|not permitted|paranoid|performance monitoring' "$1"
}

STATUS=0
perf stat -r 7 \
  -e cycles,instructions,branches,branch-misses,cache-references,cache-misses \
  -- "${CMD[@]}" >"$OUT/stdout.txt" 2>"$OUT/perf-stat.txt" || STATUS=$?

if (( STATUS != 0 )); then
  if denied "$OUT/perf-stat.txt"; then
    printf 'perf stat was not permitted. perf said:\n' >&2
    { grep -iE 'permission|not permitted|paranoid|monitoring' "$OUT/perf-stat.txt" || true; } >&2
    printf 'Use instead: samply record -- ' >&2
    printf '%q ' "${CMD[@]}" >&2
    printf '\n' >&2
    exit 3
  elif grep -qiE 'not supported|invalid event|No such file' "$OUT/perf-stat.txt"; then
    # Some VMs/containers expose no PMU counters; record/report may still work.
    printf 'warning: perf stat counters are unavailable here (see %s); continuing with record/report.\n' \
      "$OUT/perf-stat.txt" >&2
  else
    printf 'warning: command exited %d under perf stat (see %s)\n' \
      "$STATUS" "$OUT/perf-stat.txt" >&2
  fi
fi

if ! perf record -F 999 -g -o "$OUT/perf.data" -- "${CMD[@]}" \
     >"$OUT/record-stdout.txt" 2>"$OUT/perf-record.txt"; then
  if denied "$OUT/perf-record.txt"; then
    printf 'perf record was not permitted. perf said:\n' >&2
    { grep -iE 'permission|not permitted|paranoid|monitoring' "$OUT/perf-record.txt" || true; } >&2
    printf 'Use instead: samply record -- ' >&2
    printf '%q ' "${CMD[@]}" >&2
    printf '\n' >&2
    exit 3
  fi
  printf 'perf record failed (see %s)\n' "$OUT/perf-record.txt" >&2
  exit 1
fi

perf report --stdio --sort=dso,sym -i "$OUT/perf.data" \
  >"$OUT/perf-report.txt" 2>"$OUT/perf-report.err" \
  || printf 'warning: perf report failed (see %s/perf-report.err)\n' "$OUT" >&2
perf annotate --stdio -i "$OUT/perf.data" \
  >"$OUT/perf-annotate.txt" 2>"$OUT/perf-annotate.err" \
  || printf 'warning: perf annotate failed (see %s/perf-annotate.err)\n' "$OUT" >&2

printf 'evidence in %s:\n' "$OUT"
printf '  perf-stat.txt      counters (7 repeats)\n'
printf '  perf-report.txt    symbols by sample share\n'
printf '  perf-annotate.txt  per-instruction samples for the hottest symbol\n'
printf '  perf.data          raw profile (perf report -i perf.data)\n'
printf '\nif symbols are unresolved or stacks are shallow, rebuild with:\n'
printf "  RUSTFLAGS='-C debuginfo=1 -C force-frame-pointers=yes' cargo build --release\n"
printf '\nstat summary:\n'
{ grep -E 'cycles|instructions|branches|cache-(references|misses)' "$OUT/perf-stat.txt" || true; } \
  | head -n 24

# A failing workload is still evidence of where it failed, but it is not a
# successful measurement; propagate its status.
exit "$STATUS"
