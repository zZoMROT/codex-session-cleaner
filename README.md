# Codex Session Cleaner

Deletes a Codex session from local Codex storage.

Codex can archive sessions, but may not expose a direct delete action. This
script removes a session from local files and SQLite databases under:

```bash
${CODEX_HOME:-$HOME/.codex}
```

## Setup

```bash
chmod +x codex-delete-session.sh
chmod +x codex-list-sessions.sh
```

## Recommended Flow

```bash
./codex-list-sessions.sh --filter "/path/or/text"
./codex-delete-session.sh SESSION_ID
./codex-delete-session.sh SESSION_ID --apply --force-no-vacuum
```

If the final audit looks correct and nothing important remains:

```bash
./codex-delete-session.sh --delete-backups
./codex-delete-session.sh --delete-backups --apply
```

Later, after closing Codex, compact SQLite databases:

```bash
./codex-delete-session.sh --vacuum-only
```

## Usage

- List sessions:

  ```bash
  ./codex-list-sessions.sh
  ```

- List sessions containing text in any output field:

  ```bash
  ./codex-list-sessions.sh --filter "React"
  ./codex-list-sessions.sh --filter "/path/to/project"
  ./codex-list-sessions.sh --filter "2026-02-12"
  ```

- Dry-run mode is the default. It prints what would be deleted and changes
  nothing:

  ```bash
  ./codex-delete-session.sh SESSION_ID
  ```

- Delete with confirmations:

  ```bash
  ./codex-delete-session.sh SESSION_ID --apply
  ```

- Delete without confirmations while Codex may still be running:

  ```bash
  ./codex-delete-session.sh SESSION_ID --apply --force-no-vacuum
  ```

  This deletes rows from SQLite, but skips SQLite `VACUUM`. Skipping `VACUUM`
  does not undo row deletion. It only leaves physical database compaction for
  later. You can run that compaction later at any time, as long as Codex is
  closed:

  ```bash
  ./codex-delete-session.sh --vacuum-only
  ```

- Delete without confirmations and run SQLite `VACUUM`:

  ```bash
  ./codex-delete-session.sh SESSION_ID --apply --force
  ```

  Only use this when Codex is closed. `VACUUM` physically compacts SQLite
  database files and truncates WAL files after deletion.

- Run only SQLite `VACUUM` later, after closing Codex:

  ```bash
  ./codex-delete-session.sh --vacuum-only
  ```

- Use a custom Codex directory:

  ```bash
  ./codex-delete-session.sh SESSION_ID --codex-dir /path/to/.codex
  ```

- List backup files created by this script:

  ```bash
  ./codex-delete-session.sh --delete-backups
  ```

- Delete backup files with confirmation:

  ```bash
  ./codex-delete-session.sh --delete-backups --apply
  ```

- Delete backup files without confirmation:

  ```bash
  ./codex-delete-session.sh --delete-backups --apply --force
  ```

## What It Removes

- session `.jsonl` files from `sessions` and `archived_sessions`
- shell snapshots from `shell_snapshots`
- matching record from `session_index.jsonl`
- matching records from `history.jsonl`
- matching rows from `state_5.sqlite`, `logs_2.sqlite`, and `goals_1.sqlite`

For `history.jsonl`, only records whose JSON field `session_id` equals
`SESSION_ID` are removed. Plain text mentions of the ID are ignored.

## Backups

Backups are created before rewriting JSONL files and SQLite databases. They are
created next to the original files and are not deleted automatically.

The backup suffix is a timestamp in `YYYYMMDDHHMMSS` format.

Examples:

```text
session_index.jsonl.bak.20260614203000
history.jsonl.bak.20260614203000
state_5.sqlite.bak.20260614203000
logs_2.sqlite.bak.20260614203000
goals_1.sqlite.bak.20260614203000
```

If something went wrong, close Codex and restore the needed file:

```bash
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
cp "$CODEX_DIR/session_index.jsonl.bak.TIMESTAMP" "$CODEX_DIR/session_index.jsonl"
cp "$CODEX_DIR/history.jsonl.bak.TIMESTAMP" "$CODEX_DIR/history.jsonl"
cp "$CODEX_DIR/state_5.sqlite.bak.TIMESTAMP" "$CODEX_DIR/state_5.sqlite"
```

Replace `TIMESTAMP` with the actual backup suffix printed by the script. Delete
backup files only after you verify the cleanup result.

To delete backups created by this script:

```bash
./codex-delete-session.sh --delete-backups --apply
```

This deletes only these known backup patterns:

```text
session_index.jsonl.bak.*
history.jsonl.bak.*
state_5.sqlite.bak.*
logs_2.sqlite.bak.*
goals_1.sqlite.bak.*
```

## Notes

- `SESSION_ID` must be UUID-like, for example:
  `019c51a6-bdaf-7c53-9007-f9d6fa30cf4a`
- Use `--force-no-vacuum` if you are deleting while Codex may still be running.
