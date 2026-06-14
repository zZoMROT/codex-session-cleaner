#!/usr/bin/env bash
set -euo pipefail

MANIFEST_FILE_NAME="codex-delete-session.manifest.json"
DEFAULT_MAX_TESTED_CODEX_VERSION="0.0.0"
DEFAULT_REPOSITORY_MANIFEST_URL="https://raw.githubusercontent.com/zZoMROT/codex-session-cleaner/main/codex-delete-session.manifest.json"
DEFAULT_REPOSITORY_SCRIPT_URL="https://raw.githubusercontent.com/zZoMROT/codex-session-cleaner/main/codex-delete-session.sh"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_DIM=$'\033[2m'
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_DIM=""
fi

usage() {
  cat <<'USAGE'
Usage:
  codex-delete-session.sh SESSION_ID [--apply] [--force] [--force-no-vacuum] [--codex-dir DIR]
  codex-delete-session.sh --vacuum-only [--codex-dir DIR]
  codex-delete-session.sh --delete-backups [--apply] [--force] [--codex-dir DIR]

Default mode is dry-run: the script prints what it would delete, but does not
modify files or databases.

Options:
  --apply          Actually delete data after per-step confirmations.
  --force          Answer yes to confirmations. Use with --apply to delete.
  --force-no-vacuum
                   Answer yes to confirmations, but skip SQLite VACUUM.
  --vacuum-only    Only run SQLite VACUUM. Codex must be closed.
  --delete-backups
                   Delete backup files created by this script.
  --codex-dir DIR  Override CODEX_HOME / ~/.codex.
  -h, --help       Show this help.
USAGE
}

## ==================== HELPERS ====================
die() {
  printf '%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

warn() {
  printf '%sWARNING: %s%s\n' "$C_YELLOW" "$*" "$C_RESET"
}

success() {
  printf '%s%s%s\n' "$C_GREEN" "$*" "$C_RESET"
}

section() {
  printf '%s%s%s\n' "$C_BLUE" "$*" "$C_RESET"
}

kv() {
  printf '%s%s:%s %s\n' "$C_BLUE" "$1" "$C_RESET" "$2"
}

count_info() {
  printf '%s%s:%s %s\n' "$C_BLUE" "$1" "$C_RESET" "$2"
}

path_info() {
  printf '%s  %s%s\n' "$C_DIM" "$*" "$C_RESET"
}

# Ask a yes/no question. Empty input means default "no".
ask_yes() {
  local prompt="$1"
  local answer

  if [ "${FORCE:-0}" -eq 1 ]; then
    warn "FORCE: yes - $prompt"
    return 0
  fi

  printf '%s [y/N]: ' "$prompt"
  IFS= read -r answer

  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# Ask for confirmation only in --apply mode.
# In dry-run mode, only print what would be asked.
confirm_apply() {
  local prompt="$1"
  local answer

  if [ "$APPLY" -ne 1 ]; then
    printf '%sDRY RUN:%s would ask: %s\n' "$C_DIM" "$C_RESET" "$prompt"
    return 1
  fi

  ask_yes "$prompt"
}

# Stop if a required command, such as awk, is not available.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

validate_session_id() {
  local id="$1"

  [ -n "$id" ] || die "SESSION_ID is empty"

  [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
    die "SESSION_ID must be a UUID-like value, for example: 019c51a6-bdaf-7c53-9007-f9d6fa30cf4a"
}

read_manifest_string() {
  local manifest="$1"
  local key="$2"
  local default="$3"
  local value

  if [ ! -f "$manifest" ]; then
    warn "manifest not found: $manifest"
    printf '%s\n' "$default"
    return 0
  fi

  value=$(
    awk -F: '
      $0 ~ "\"" key "\"[[:space:]]*:" {
        sub(/^[^:]*:[[:space:]]*"/, "", $0)
        sub(/"[[:space:]]*,?[[:space:]]*$/, "", $0)
        print $0
        exit
      }
    ' key="$key" "$manifest"
  )

  if [ -z "$value" ]; then
    printf '%s\n' "$default"
    return 0
  fi

  printf '%s\n' "$value"
}

read_max_tested_codex_version() {
  local manifest="$1"
  local version

  version=$(read_manifest_string "$manifest" "max_tested_codex_version" "$DEFAULT_MAX_TESTED_CODEX_VERSION")

  if ! [[ "$version" =~ ^[0-9]+([.][0-9]+){1,3}$ ]]; then
    warn "manifest max_tested_codex_version has invalid format: $version"
    printf '%s\n' "$DEFAULT_MAX_TESTED_CODEX_VERSION"
    return 0
  fi

  printf '%s\n' "$version"
}

version_gt() {
  local a="$1"
  local b="$2"
  local a1=0 a2=0 a3=0 a4=0
  local b1=0 b2=0 b3=0 b4=0
  local i av bv

  IFS=. read -r a1 a2 a3 a4 <<< "$a"
  IFS=. read -r b1 b2 b3 b4 <<< "$b"

  for i in 1 2 3 4; do
    case "$i" in
      1) av=${a1:-0}; bv=${b1:-0} ;;
      2) av=${a2:-0}; bv=${b2:-0} ;;
      3) av=${a3:-0}; bv=${b3:-0} ;;
      4) av=${a4:-0}; bv=${b4:-0} ;;
    esac

    if [ "$((10#$av))" -gt "$((10#$bv))" ]; then
      return 0
    fi

    if [ "$((10#$av))" -lt "$((10#$bv))" ]; then
      return 1
    fi
  done

  return 1
}

check_repository_manifest() {
  local current_version="$1"
  local manifest="$2"
  local local_max_tested="$3"
  local manifest_url script_url remote_manifest remote_max script_path manifest_path update_command

  manifest_url=$(read_manifest_string "$manifest" "repository_manifest_url" "$DEFAULT_REPOSITORY_MANIFEST_URL")
  script_url=$(read_manifest_string "$manifest" "repository_script_url" "$DEFAULT_REPOSITORY_SCRIPT_URL")

  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not found."
    info "Install curl to let this script check for available updates automatically."
    return 0
  fi

  remote_manifest=$(curl --fail --silent --show-error --location --max-time 20 "$manifest_url" 2>/dev/null || true)
  if [ -z "$remote_manifest" ]; then
    warn "could not download remote manifest. Automatic update check was skipped."
    return 0
  fi

  remote_max=$(
    printf '%s\n' "$remote_manifest" |
      awk -F: '
        /"max_tested_codex_version"[[:space:]]*:/ {
          sub(/^[^:]*:[[:space:]]*"/, "", $0)
          sub(/"[[:space:]]*,?[[:space:]]*$/, "", $0)
          print $0
          exit
        }
      '
  )

  if ! [[ "$remote_max" =~ ^[0-9]+([.][0-9]+){1,3}$ ]]; then
    warn "repository manifest does not contain a valid max_tested_codex_version."
    return 0
  fi

  if version_gt "$current_version" "$remote_max"; then
    warn "remote script is tested up to Codex $remote_max, which is still older than current Codex $current_version."
    return 0
  fi

  section "A newer version $remote_max of this script is available."
  warn "recommended: update the script before continuing."

  if [ -n "$script_url" ]; then
    script_path="$SCRIPT_DIR/codex-delete-session.sh"
    manifest_path="$SCRIPT_DIR/$MANIFEST_FILE_NAME"
    update_command="curl -fsSL '$script_url' -o '$script_path' && curl -fsSL '$manifest_url' -o '$manifest_path' && chmod +x '$script_path'"
    kv "Update command" "$update_command"

    if ask_yes "Run update command now?"; then
      curl -fsSL "$script_url" -o "$script_path"
      curl -fsSL "$manifest_url" -o "$manifest_path"
      chmod +x "$script_path"
      success "Updated local script and manifest."
    else
      warn "skipped script update."
    fi
  else
    warn "no repository_script_url in manifest; update command cannot be generated."
  fi
}

check_codex_version() {
  local output current_version manifest max_tested

  manifest="$SCRIPT_DIR/$MANIFEST_FILE_NAME"
  max_tested=$(read_max_tested_codex_version "$manifest")

  kv "Manifest" "$manifest"
  kv "Max tested Codex version" "$max_tested"

  if ! command -v codex >/dev/null 2>&1; then
    warn "codex command not found; cannot check current Codex version"
    return 0
  fi

  output=$(codex --version 2>/dev/null || true)
  if [[ "$output" =~ ([0-9]+([.][0-9]+){1,3}) ]]; then
    current_version="${BASH_REMATCH[1]}"
  else
    current_version=""
  fi

  if [ -z "$current_version" ]; then
    warn "could not parse Codex version from: $output"
    return 0
  fi

  kv "Current Codex version" "$current_version"

  if version_gt "$current_version" "$max_tested"; then
    info ""
    warn "latest tested Codex version is $max_tested, but current Codex version is $current_version."
    warn "this script may not work as expected; continuing is risky."
    check_repository_manifest "$current_version" "$manifest" "$max_tested"

    if ! ask_yes "Continue anyway?"; then
      warn "cancelled"
      exit 0
    fi
  fi
}

## ==================== SESSION CLEANUP LOGIC ====================
find_session_files() {
  local dir
  for dir in "$CODEX_DIR/sessions" "$CODEX_DIR/archived_sessions"; do
    [ -d "$dir" ] || continue
    find "$dir" -type f -name "*$SESSION_ID*.jsonl" -print
  done
}

find_shell_snapshots() {
  local dir="$CODEX_DIR/shell_snapshots"
  [ -d "$dir" ] || return 0
  find "$dir" -type f -name "$SESSION_ID.*.sh" -print
}

delete_listed_files() {
  local label="$1"
  shift
  local file
  local count="$#"
  local deleted=0

  [ "$count" -gt 0 ] || return 0

  if ! confirm_apply "Delete $label?"; then
    warn "skipped $label"
    return 0
  fi

  for file in "$@"; do
    rm -f -- "$file"
    success "deleted: $file"
    deleted=$((deleted + 1))
  done

  success "$label deleted: $deleted"
}

backup_file() {
  local file="$1"
  local backup

  backup="$file.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$file" "$backup"
  printf '%s\n' "$backup"
}

line_count() {
  local file="$1"
  wc -l < "$file" | tr -d ' '
}

show_cleaned_file_diff() {
  local label="$1"
  local file="$2"
  local backup="$3"
  local json_field="$4"
  local unexpected_removed

  if ! ask_yes "Show diff for $label changes?"; then
    return 0
  fi

  if ! command -v diff >/dev/null 2>&1; then
    warn "diff not found; cannot show file changes."
    return 0
  fi

  diff -u "$backup" "$file" || true

  unexpected_removed=$(
    { diff -u "$backup" "$file" || true; } |
      awk -v id="$SESSION_ID" -v field="$json_field" '
        BEGIN {
          pattern = "(^|[,{])[[:space:]]*\"" field "\"[[:space:]]*:[[:space:]]*\"" id "\""
        }
        /^--- / || /^\+\+\+ / || /^@@/ { next }
        /^-/ && $0 !~ pattern { print }
      '
  )

  if [ -n "$unexpected_removed" ]; then
    warn "diff contains removed lines without JSON field $json_field=$SESSION_ID:"
    printf '%s\n' "$unexpected_removed"
  else
    success "diff check passed: all removed lines match $json_field=$SESSION_ID."
  fi
}

remove_session_lines_from_file() {
  local label="$1"
  local file="$2"
  local json_field="$3"
  CLEANED_FILE_BACKUP=""

  if [ ! -f "$file" ]; then
    warn "$label not found: $file"
    return 0
  fi

  local before matches backup tmp expected after deleted remaining
  before=$(line_count "$file")
  matches=$(awk -v id="$SESSION_ID" -v field="$json_field" '
    BEGIN { pattern = "(^|[,{])[[:space:]]*\"" field "\"[[:space:]]*:[[:space:]]*\"" id "\"" }
    $0 ~ pattern { count++ }
    END { print count + 0 }
  ' "$file")

  info ""
  section "$label: $file"
  count_info "total lines before" "$before"
  count_info "matching lines to delete" "$matches"

  if [ "$matches" = "0" ]; then
    return 0
  fi

  awk -v id="$SESSION_ID" -v field="$json_field" '
    BEGIN { pattern = "(^|[,{])[[:space:]]*\"" field "\"[[:space:]]*:[[:space:]]*\"" id "\"" }
    $0 ~ pattern { print FNR ":" $0 }
  ' "$file"

  if ! confirm_apply "Delete matching lines from $label?"; then
    warn "skipped $label"
    return 0
  fi

  backup=$(backup_file "$file")
  tmp=$(mktemp "$file.tmp.XXXXXX")
  expected=$(mktemp "$file.expected.XXXXXX")

  awk -v id="$SESSION_ID" -v field="$json_field" '
    BEGIN { pattern = "(^|[,{])[[:space:]]*\"" field "\"[[:space:]]*:[[:space:]]*\"" id "\"" }
    $0 !~ pattern
  ' "$file" > "$tmp"
  awk -v id="$SESSION_ID" -v field="$json_field" '
    BEGIN { pattern = "(^|[,{])[[:space:]]*\"" field "\"[[:space:]]*:[[:space:]]*\"" id "\"" }
    $0 !~ pattern
  ' "$backup" > "$expected"
  mv "$tmp" "$file"

  after=$(line_count "$file")
  deleted=$((before - after))
  remaining=$(awk -v id="$SESSION_ID" -v field="$json_field" '
    BEGIN { pattern = "(^|[,{])[[:space:]]*\"" field "\"[[:space:]]*:[[:space:]]*\"" id "\"" }
    $0 ~ pattern { count++ }
    END { print count + 0 }
  ' "$file")

  count_info "total lines after" "$after"
  count_info "deleted lines" "$deleted"
  count_info "remaining matches" "$remaining"
  kv "backup" "$backup"

  if [ "$deleted" -ne "$matches" ]; then
    rm -f "$expected"
    die "$label deleted count mismatch; restore with: cp \"$backup\" \"$file\""
  fi

  if [ "$remaining" -ne 0 ]; then
    rm -f "$expected"
    die "$label still contains SESSION_ID; restore with: cp \"$backup\" \"$file\""
  fi

  if ! cmp -s "$expected" "$file"; then
    rm -f "$expected"
    die "$label differs from expected filtered output; restore with: cp \"$backup\" \"$file\""
  fi

  CLEANED_FILE_BACKUP="$backup"
  rm -f "$expected"
}

clean_file_session_index() {
  remove_session_lines_from_file "session index" "$CODEX_DIR/session_index.jsonl" "id"
  if [ -n "${CLEANED_FILE_BACKUP:-}" ]; then
    show_cleaned_file_diff "session index" "$CODEX_DIR/session_index.jsonl" "$CLEANED_FILE_BACKUP" "id"
  fi
}

clean_file_history() {
  remove_session_lines_from_file "history" "$CODEX_DIR/history.jsonl" "session_id"
  if [ -n "${CLEANED_FILE_BACKUP:-}" ]; then
    show_cleaned_file_diff "history" "$CODEX_DIR/history.jsonl" "$CLEANED_FILE_BACKUP" "session_id"
  fi
}

delete_sqlite_rows() {
  local state_db="$CODEX_DIR/state_5.sqlite"
  local logs_db="$CODEX_DIR/logs_2.sqlite"
  local goals_db="$CODEX_DIR/goals_1.sqlite"
  local backup

  if ! confirm_apply "Delete matching rows from SQLite databases? Backups will be created first."; then
    warn "skipped SQLite delete"
    return 0
  fi

  for db in "$state_db" "$logs_db" "$goals_db"; do
    if [ -f "$db" ]; then
      backup=$(backup_file "$db")
      kv "backup" "$backup"
    fi
  done

  if [ -f "$state_db" ]; then
    sqlite3 -cmd ".timeout 5000" "$state_db" "
      PRAGMA foreign_keys=ON;
      DELETE FROM threads WHERE id = '$SESSION_ID';
    "
  fi

  if [ -f "$logs_db" ]; then
    sqlite3 -cmd ".timeout 5000" "$logs_db" "
      DELETE FROM logs WHERE thread_id = '$SESSION_ID';
    "
  fi

  if [ -f "$goals_db" ]; then
    sqlite3 -cmd ".timeout 5000" "$goals_db" "
      DELETE FROM thread_goals WHERE thread_id = '$SESSION_ID';
    "
  fi
}

vacuum_sqlite() {
  local state_db="$CODEX_DIR/state_5.sqlite"
  local logs_db="$CODEX_DIR/logs_2.sqlite"
  local goals_db="$CODEX_DIR/goals_1.sqlite"
  local db

  if [ "${SKIP_VACUUM:-0}" -eq 1 ]; then
    warn "skipped SQLite VACUUM (--force-no-vacuum)"
    return 0
  fi

  if ! confirm_apply "Run SQLite VACUUM now? Codex must be closed. You can skip this and run later with: ./codex-delete-session.sh --vacuum-only"; then
    warn "skipped SQLite VACUUM"
    return 0
  fi

  for db in "$state_db" "$logs_db" "$goals_db"; do
    [ -f "$db" ] || continue
    sqlite3 -cmd ".timeout 5000" "$db" "
      PRAGMA wal_checkpoint(TRUNCATE);
      VACUUM;
    "
    success "vacuumed: $db"
  done
}

list_backup_files() {
  find "$CODEX_DIR" -maxdepth 1 -type f \( \
    -name 'session_index.jsonl.bak.*' -o \
    -name 'history.jsonl.bak.*' -o \
    -name 'state_5.sqlite.bak.*' -o \
    -name 'logs_2.sqlite.bak.*' -o \
    -name 'goals_1.sqlite.bak.*' \
  \) -print
}

delete_backups() {
  local count=0
  local file
  local deleted=0

  info ""
  section "backup files found:"
  while IFS= read -r file; do
    path_info "$file"
    count=$((count + 1))
  done < <(list_backup_files)
  count_info "backup files" "$count"

  [ "$count" -gt 0 ] || return 0

  if ! confirm_apply "Delete backup files created by this script?"; then
    warn "skipped backup deletion"
    return 0
  fi

  while IFS= read -r file; do
    rm -f -- "$file"
    success "deleted: $file"
    deleted=$((deleted + 1))
  done < <(list_backup_files)

  success "backup files deleted: $deleted"
}

final_audit() {
  local count
  local session_index_matches
  local history_matches

  info ""
  section "Final audit"

  section "Files whose names contain SESSION_ID:"
  while IFS= read -r file; do
    path_info "$file"
  done < <(find "$CODEX_DIR" -name "*$SESSION_ID*" -print || true)

  info ""
  section "JSONL remaining records:"
  if [ -f "$CODEX_DIR/session_index.jsonl" ]; then
    session_index_matches=$(awk -v id="$SESSION_ID" '
      BEGIN { pattern = "(^|[,{])[[:space:]]*\"id\"[[:space:]]*:[[:space:]]*\"" id "\"" }
      $0 ~ pattern { count++ }
      END { print count + 0 }
    ' "$CODEX_DIR/session_index.jsonl")
    count_info "session index records" "$session_index_matches"
  fi
  if [ -f "$CODEX_DIR/history.jsonl" ]; then
    history_matches=$(awk -v id="$SESSION_ID" '
      BEGIN { pattern = "(^|[,{])[[:space:]]*\"session_id\"[[:space:]]*:[[:space:]]*\"" id "\"" }
      $0 ~ pattern { count++ }
      END { print count + 0 }
    ' "$CODEX_DIR/history.jsonl")
    count_info "history records" "$history_matches"
  fi

  info ""
  section "SQLite remaining counts:"
  if [ -f "$CODEX_DIR/state_5.sqlite" ]; then
    count=$(sqlite3 "$CODEX_DIR/state_5.sqlite" "select count(*) from threads where id='$SESSION_ID';" || true)
    count_info "state threads" "$count"
  fi
  if [ -f "$CODEX_DIR/logs_2.sqlite" ]; then
    count=$(sqlite3 "$CODEX_DIR/logs_2.sqlite" "select count(*) from logs where thread_id='$SESSION_ID';" || true)
    count_info "logs" "$count"
  fi
  if [ -f "$CODEX_DIR/goals_1.sqlite" ]; then
    count=$(sqlite3 "$CODEX_DIR/goals_1.sqlite" "select count(*) from thread_goals where thread_id='$SESSION_ID';" || true)
    count_info "goals" "$count"
  fi
}

## ==================== MAIN ====================
APPLY=0
FORCE=0
SKIP_VACUUM=0
VACUUM_ONLY=0
DELETE_BACKUPS_ONLY=0
SESSION_ID=""
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)
      APPLY=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --force-no-vacuum)
      FORCE=1
      SKIP_VACUUM=1
      shift
      ;;
    --vacuum-only)
      APPLY=1
      FORCE=1
      VACUUM_ONLY=1
      shift
      ;;
    --delete-backups)
      DELETE_BACKUPS_ONLY=1
      shift
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
      [ -z "$SESSION_ID" ] || die "unexpected extra argument: $1"
      SESSION_ID="$1"
      shift
      ;;
  esac
done

[ -d "$CODEX_DIR" ] || die "CODEX_DIR does not exist: $CODEX_DIR"

require_cmd awk
require_cmd cmp
require_cmd cp
require_cmd date
require_cmd find
require_cmd grep
require_cmd mktemp
require_cmd mv
require_cmd rm
require_cmd tr
require_cmd wc
require_cmd sqlite3

if [ "$VACUUM_ONLY" -eq 1 ] && [ "$SKIP_VACUUM" -eq 1 ]; then
  die "--vacuum-only cannot be combined with --force-no-vacuum"
fi

if [ "$DELETE_BACKUPS_ONLY" -eq 1 ] && [ "$VACUUM_ONLY" -eq 1 ]; then
  die "--delete-backups cannot be combined with --vacuum-only"
fi

if [ "$VACUUM_ONLY" -eq 1 ]; then
  kv "CODEX_DIR" "$CODEX_DIR"
  warn "MODE: vacuum-only"
  vacuum_sqlite
  exit 0
fi

if [ "$DELETE_BACKUPS_ONLY" -eq 1 ]; then
  kv "CODEX_DIR" "$CODEX_DIR"
  if [ "$APPLY" -eq 1 ] && [ "$FORCE" -eq 1 ]; then
    warn "MODE: delete-backups force"
  elif [ "$APPLY" -eq 1 ]; then
    warn "MODE: delete-backups apply"
  elif [ "$FORCE" -eq 1 ]; then
    success "MODE: delete-backups dry-run force"
  else
    success "MODE: delete-backups dry-run"
  fi
  delete_backups
  exit 0
fi

[ -n "$SESSION_ID" ] || {
  usage
  exit 1
}

validate_session_id "$SESSION_ID"

check_codex_version

kv "CODEX_DIR" "$CODEX_DIR"
kv "SESSION_ID" "$SESSION_ID"
if [ "$APPLY" -eq 1 ] && [ "$FORCE" -eq 1 ] && [ "$SKIP_VACUUM" -eq 1 ]; then
  warn "MODE: force no-vacuum"
elif [ "$APPLY" -eq 1 ] && [ "$FORCE" -eq 1 ]; then
  warn "MODE: force"
elif [ "$APPLY" -eq 1 ]; then
  warn "MODE: apply"
elif [ "$FORCE" -eq 1 ] && [ "$SKIP_VACUUM" -eq 1 ]; then
  success "MODE: dry-run force no-vacuum"
elif [ "$FORCE" -eq 1 ]; then
  success "MODE: dry-run force"
else
  success "MODE: dry-run"
fi

if ! confirm_apply "Continue with this Codex directory and session id?"; then
  if [ "$APPLY" -eq 1 ]; then
    warn "cancelled"
    exit 0
  fi
fi

# Get session files
session_files=()
while IFS= read -r file; do
  session_files+=("$file")
done < <(find_session_files)
info ""
section "session jsonl files found: ${#session_files[@]}"
if [ "${#session_files[@]}" -gt 0 ]; then
  for file in "${session_files[@]}"; do
    path_info "$file"
  done
fi
# Delete session files
if [ "${#session_files[@]}" -gt 0 ]; then
  delete_listed_files "session jsonl files" "${session_files[@]}"
else
  delete_listed_files "session jsonl files"
fi

# Get session snapshots
snapshots=()
while IFS= read -r file; do
  snapshots+=("$file")
done < <(find_shell_snapshots)
info ""
section "shell snapshots found: ${#snapshots[@]}"
if [ "${#snapshots[@]}" -gt 0 ]; then
  for file in "${snapshots[@]}"; do
    path_info "$file"
  done
fi
# Delete session snapshots
if [ "${#snapshots[@]}" -gt 0 ]; then
  delete_listed_files "shell snapshots" "${snapshots[@]}"
else
  delete_listed_files "shell snapshots"
fi

# Delete session from session_index.jsonl
clean_file_session_index
# Delete session from history.jsonl
clean_file_history
# Delete session from database
delete_sqlite_rows
# Clean up SQLite database files after deletion
vacuum_sqlite
# Check for leftovers
final_audit
