#!/usr/bin/env bash
# Install the rustperf skill into every local agent harness.
#
#   bash scripts/install-skill.sh            # copy (safe default)
#   bash scripts/install-skill.sh --link     # symlink to this checkout
#   bash scripts/install-skill.sh --uninstall
#
# Copy mode is the default because a half-updated checkout must not silently
# change what an unattended agent does. Re-run after `git pull`.

set -euo pipefail

SKILL_NAME="rustperf"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/${SKILL_NAME}"

if [[ ! -f "${SRC}/SKILL.md" ]]; then
  echo "error: ${SRC}/SKILL.md not found" >&2
  exit 1
fi

# Harness skill roots. Only existing parents are installed into, unless
# --all is given, so a missing harness is not silently created.
TARGETS=(
  "${HOME}/.config/opencode/skills"
  "${HOME}/.codex/skills"
  "${HOME}/.claude/skills"
  "${HOME}/.agents/skills"
)

MODE="copy"
ACTION="install"
for arg in "$@"; do
  case "${arg}" in
    --link) MODE="link" ;;
    --copy) MODE="copy" ;;
    --uninstall) ACTION="uninstall" ;;
    -h|--help)
      sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown argument ${arg}" >&2
      exit 2
      ;;
  esac
done

installed=0
for root in "${TARGETS[@]}"; do
  [[ -d "${root}" ]] || continue
  dest="${root}/${SKILL_NAME}"

  if [[ "${ACTION}" == "uninstall" ]]; then
    if [[ -L "${dest}" || -d "${dest}" ]]; then
      rm -rf -- "${dest}"
      echo "removed  ${dest}"
      installed=$((installed + 1))
    fi
    continue
  fi

  rm -rf -- "${dest}"
  mkdir -p -- "${root}"
  if [[ "${MODE}" == "link" ]]; then
    ln -s "${SRC}" "${dest}"
    echo "linked   ${dest} -> ${SRC}"
  else
    cp -a -- "${SRC}" "${dest}"
    echo "copied   ${dest}"
  fi
  installed=$((installed + 1))
done

if [[ "${installed}" -eq 0 ]]; then
  echo "error: no harness skill directory found" >&2
  exit 1
fi

echo
echo "${ACTION} complete (${MODE}); ${installed} harness(es) updated."
if [[ "${ACTION}" == "install" ]]; then
  echo "Restart the agent session, or start a new one, for the skill to be listed."
fi
