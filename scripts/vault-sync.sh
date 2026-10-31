#!/usr/bin/env bash
# Sync the KeePassXC vault between this PC and the atpg SFTP vault.
#
# Flow: lock -> download remote -> merge remote into local (keepassxc-cli merge)
#       -> re-check remote hasn't changed since download -> upload (atomic rename)
#       -> keep a local timestamped backup.
#
# Config: sourced from <repo-root>/.env (see .env.example). Env vars already set
# in the calling shell take precedence (used by tests/test_sync.sh).
#
# VAULT_REMOTE_HOST=local is a special test mode: VAULT_REMOTE_PATH is treated as
# a plain local path instead of an SFTP host, so the whole flow can be exercised
# without a network or a real server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAX_RETRIES=3
BACKUP_KEEP=20

DRY_RUN=0
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help)
      echo "usage: $0 [--dry-run] [--check]"
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

# --- config ---------------------------------------------------------------
# .env provides defaults but must never clobber vars the caller already
# exported (tests/test_sync.sh relies on this to force VAULT_REMOTE_HOST=local).

_preset_local="${VAULT_LOCAL+x}"; _orig_local="${VAULT_LOCAL:-}"
_preset_host="${VAULT_REMOTE_HOST+x}"; _orig_host="${VAULT_REMOTE_HOST:-}"
_preset_path="${VAULT_REMOTE_PATH+x}"; _orig_path="${VAULT_REMOTE_PATH:-}"

if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

[[ -n "$_preset_local" ]] && VAULT_LOCAL="$_orig_local"
[[ -n "$_preset_host" ]] && VAULT_REMOTE_HOST="$_orig_host"
[[ -n "$_preset_path" ]] && VAULT_REMOTE_PATH="$_orig_path"

VAULT_LOCAL="${VAULT_LOCAL:-$HOME/Vault/passwords.kdbx}"
VAULT_REMOTE_HOST="${VAULT_REMOTE_HOST:-atpg-vault}"
VAULT_REMOTE_PATH="${VAULT_REMOTE_PATH:-/data/passwords.kdbx}"

LOCK_FILE="$VAULT_LOCAL.lock"
BACKUP_DIR="$(dirname "$VAULT_LOCAL")/.bak"

log() { echo "[vault-sync] $*" >&2; }

# --- remote I/O abstraction ------------------------------------------------
# Two backends: real SFTP, or a "local" backend (VAULT_REMOTE_HOST=local) used
# by the test suite so tests never touch the network.

is_local_backend() { [[ "$VAULT_REMOTE_HOST" == "local" ]]; }

remote_exists() {
  if is_local_backend; then
    [[ -f "$VAULT_REMOTE_PATH" ]]
  else
    # sftp echoes the batch command itself to stdout (it contains the path,
    # so it would false-positive-match a naive grep for the basename) --
    # filter those "sftp>" echo lines out before looking for a real listing.
    sftp -o BatchMode=yes -o ConnectTimeout=10 \
      -b <(printf -- '-ls -la %s\n' "$VAULT_REMOTE_PATH") "$VAULT_REMOTE_HOST" 2>/dev/null \
      | grep -v '^sftp>' | grep -q "$(basename "$VAULT_REMOTE_PATH")\$"
  fi
}

# Prints an opaque signature string for the remote file (size + mtime line).
# Used only to detect "did the remote change between download and upload".
remote_signature() {
  if is_local_backend; then
    stat -c '%s %Y' "$VAULT_REMOTE_PATH" 2>/dev/null || echo "MISSING"
  else
    sftp -o BatchMode=yes -o ConnectTimeout=10 \
      -b <(printf -- '-ls -la %s\n' "$VAULT_REMOTE_PATH") "$VAULT_REMOTE_HOST" 2>/dev/null \
      | grep -v '^sftp>' | grep "$(basename "$VAULT_REMOTE_PATH")\$" || echo "MISSING"
  fi
}

remote_download() {
  local dest="$1"
  if is_local_backend; then
    cp -p "$VAULT_REMOTE_PATH" "$dest"
  else
    sftp -o BatchMode=yes -o ConnectTimeout=10 \
      -b <(printf 'get %s %s\n' "$VAULT_REMOTE_PATH" "$dest") "$VAULT_REMOTE_HOST" >/dev/null
  fi
}

# Atomic upload: write to a temp name, then rename over the real path in one step.
remote_upload() {
  local src="$1"
  if is_local_backend; then
    mkdir -p "$(dirname "$VAULT_REMOTE_PATH")"
    local tmp="${VAULT_REMOTE_PATH}.tmp.$$"
    cp -p "$src" "$tmp"
    mv -f "$tmp" "$VAULT_REMOTE_PATH"
  else
    local tmp_name
    tmp_name="$(basename "$VAULT_REMOTE_PATH").tmp.$$"
    local tmp_path="$(dirname "$VAULT_REMOTE_PATH")/$tmp_name"
    sftp -o BatchMode=yes -o ConnectTimeout=10 -b <(printf \
      'put %s %s\nrename %s %s\n' "$src" "$tmp_path" "$tmp_path" "$VAULT_REMOTE_PATH") \
      "$VAULT_REMOTE_HOST" >/dev/null
  fi
}

# --- backup -----------------------------------------------------------------

keep_backup() {
  mkdir -p "$BACKUP_DIR"
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$VAULT_LOCAL" "$BACKUP_DIR/passwords.$stamp.kdbx"
  # prune to last BACKUP_KEEP, oldest first
  ls -1t "$BACKUP_DIR"/passwords.*.kdbx 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))" | xargs -r rm -f
}

# --- main --------------------------------------------------------------------

main() {
  if [[ ! -f "$VAULT_LOCAL" ]] && ! remote_exists; then
    log "ERROR: neither local ($VAULT_LOCAL) nor remote ($VAULT_REMOTE_HOST:$VAULT_REMOTE_PATH) database exists."
    log "Create the database first (KeePassXC GUI) before syncing."
    exit 1
  fi

  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "ERROR: another vault-sync is already running (lock: $LOCK_FILE)"
    exit 1
  fi

  if [[ ! -f "$VAULT_LOCAL" ]]; then
    log "No local database yet; pulling from remote (first pull)."
    [[ $DRY_RUN -eq 1 ]] && { log "[dry-run] would download remote to $VAULT_LOCAL"; exit 0; }
    mkdir -p "$(dirname "$VAULT_LOCAL")"
    remote_download "$VAULT_LOCAL"
    log "Pulled remote database to $VAULT_LOCAL."
    exit 0
  fi

  if ! remote_exists; then
    log "No remote database yet; pushing local (first push)."
    [[ $DRY_RUN -eq 1 ]] && { log "[dry-run] would upload $VAULT_LOCAL to remote"; exit 0; }
    remote_upload "$VAULT_LOCAL"
    log "Pushed local database to remote."
    exit 0
  fi

  if [[ $CHECK_ONLY -eq 1 ]]; then
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    remote_download "$tmp"
    if cmp -s "$VAULT_LOCAL" "$tmp"; then
      log "OK: local and remote are byte-identical."
      exit 0
    else
      log "DIFFERS: local and remote are not identical (this is normal if either side has unsynced edits)."
      exit 1
    fi
  fi

  local attempt=1
  while (( attempt <= MAX_RETRIES )); do
    log "Sync attempt $attempt/$MAX_RETRIES"
    local tmp_remote sig_before sig_after
    tmp_remote="$(mktemp)"

    remote_download "$tmp_remote"
    sig_before="$(remote_signature)"

    # Test-only hook (tests/test_sync.sh): pause here so a test can mutate the
    # remote file concurrently and verify the retry logic picks it up. No-op
    # in normal use.
    if [[ -n "${VAULT_SYNC_TEST_DELAY_MERGE:-}" ]]; then
      sleep "$VAULT_SYNC_TEST_DELAY_MERGE"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
      log "[dry-run] merge preview (remote -> local), nothing will be written:"
      keepassxc-cli merge -s --dry-run "$VAULT_LOCAL" "$tmp_remote"
      rm -f "$tmp_remote"
      exit 0
    fi

    keep_backup
    keepassxc-cli merge -s "$VAULT_LOCAL" "$tmp_remote"
    rm -f "$tmp_remote"

    sig_after="$(remote_signature)"
    if [[ "$sig_before" == "$sig_after" ]]; then
      remote_upload "$VAULT_LOCAL"
      log "Synced OK (merged remote into local, uploaded merged copy)."
      exit 0
    fi

    log "Remote changed during sync (race with another writer); retrying merge."
    rm -f "$tmp_remote"
    (( attempt++ ))
  done

  log "ERROR: remote kept changing after $MAX_RETRIES attempts; aborting without uploading."
  log "Your local copy already has the latest merge. Just run vault-sync.sh again."
  exit 1
}

main "$@"
