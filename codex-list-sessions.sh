#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  codex-list-sessions.sh [--filter TEXT] [--codex-dir DIR]

Lists local Codex sessions from CODEX_DIR/sessions.

Options:
  --filter TEXT    Show only rows containing TEXT in any output field.
  --codex-dir DIR  Override CODEX_HOME / ~/.codex.
  -h, --help       Show this help.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
FILTER=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --filter)
      [ "$#" -ge 2 ] || die "--filter requires a value"
      FILTER="$2"
      shift 2
      ;;
    --codex-dir)
      [ "$#" -ge 2 ] || die "--codex-dir requires a value"
      CODEX_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

require_cmd find
require_cmd jq
require_cmd sort
require_cmd column

[ -d "$CODEX_DIR/sessions" ] || die "sessions directory not found: $CODEX_DIR/sessions"

printf 'Scanning %s/sessions ...\n' "$CODEX_DIR" >&2

{
  printf 'started_at\tid\tcwd\tprompt\n'
  find "$CODEX_DIR/sessions" -name '*.jsonl' -print0 |
    {
      count=0
      while IFS= read -r -d '' file; do
        count=$((count + 1))
        if [ $((count % 100)) -eq 0 ]; then
          printf 'Scanned %s session files ...\n' "$count" >&2
        fi

        jq -sr --arg file "$file" '
          (map(select(.type == "session_meta"))[0] // {}) as $meta
          | (map(
              select(.type == "response_item" and .payload.role == "user")
              | .payload.content[]?
              | select(.type == "input_text")
              | .text
              | select(startswith("<environment_context>") | not)
            )[0] // "") as $prompt
          | [
              ($meta.payload.started_at // $meta.timestamp // ""),
              ($meta.payload.id // ""),
              ($meta.payload.cwd // ""),
              ($prompt | gsub("\n"; " ") | .[0:120])
            ]
          | @tsv
        ' "$file" || printf 'WARN: could not parse %s\n' "$file" >&2
      done
      printf 'Scanned %s session files.\n' "$count" >&2
    } |
    sort -r
} |
  if [ -n "$FILTER" ]; then
    grep -F -- "$FILTER" || true
  else
    cat
  fi |
  column -t -s $'\t'
