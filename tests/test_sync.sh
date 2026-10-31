#!/usr/bin/env bash
# Functional tests for scripts/vault-sync.sh using a "local" fake-remote backend
# (VAULT_REMOTE_HOST=local) so nothing touches the network or the real vault.
#
# Run: tests/test_sync.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC="$REPO_ROOT/scripts/vault-sync.sh"
TEST_PASS="vault-sync-test-pass"

PASS=0
FAIL=0

say() { echo "  $*"; }
ok()  { PASS=$((PASS+1)); echo "ok   - $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $*"; }

# db_create <path>
db_create() {
  printf '%s\n%s\n' "$TEST_PASS" "$TEST_PASS" \
    | keepassxc-cli db-create -p -q -t 100 "$1" >/dev/null
}

# db_add <path> <entry-name>
db_add() {
  printf '%s\n%s\n%s\n' "$TEST_PASS" "entrypw" "entrypw" \
    | keepassxc-cli add -q "$1" "$2" -u someuser -p >/dev/null
}

# db_entries <path> -> prints sorted entry list
db_entries() {
  printf '%s\n' "$TEST_PASS" | keepassxc-cli ls -q -R -f "$1" 2>/dev/null | sort
}

new_workdir() {
  mktemp -d "${TMPDIR:-/tmp}/vault-sync-test.XXXXXX"
}

run_sync() {
  # usage: run_sync <local> <remote> [extra args...]
  # Feeds the test master password on stdin for keepassxc-cli merge prompts
  # (only used when both sides exist and a merge actually happens).
  local local_db="$1" remote_db="$2"; shift 2
  printf '%s\n' "$TEST_PASS" | \
    VAULT_LOCAL="$local_db" VAULT_REMOTE_HOST="local" VAULT_REMOTE_PATH="$remote_db" \
    bash "$SYNC" "$@"
}

# --- Case 1: neither side exists -> error, nothing created -----------------
test_neither_exists() {
  local d; d="$(new_workdir)"
  if run_sync "$d/local.kdbx" "$d/remote.kdbx" >/tmp/out.$$ 2>&1; then
    bad "neither-exists: expected non-zero exit"
  else
    if [[ ! -e "$d/local.kdbx" && ! -e "$d/remote.kdbx" ]]; then
      ok "neither-exists: errors out, creates nothing"
    else
      bad "neither-exists: should not have created any file"
    fi
  fi
  rm -rf "$d" /tmp/out.$$
}

# --- Case 2: local exists, remote doesn't -> first push ---------------------
test_first_push() {
  local d; d="$(new_workdir)"
  db_create "$d/local.kdbx"
  if run_sync "$d/local.kdbx" "$d/remote.kdbx" >/tmp/out.$$ 2>&1; then
    if [[ -f "$d/remote.kdbx" ]] && cmp -s "$d/local.kdbx" "$d/remote.kdbx"; then
      ok "first-push: remote created, matches local"
    else
      bad "first-push: remote missing or differs"; cat /tmp/out.$$
    fi
  else
    bad "first-push: sync should have succeeded"; cat /tmp/out.$$
  fi
  rm -rf "$d" /tmp/out.$$
}

# --- Case 3: remote exists, local doesn't -> first pull ---------------------
test_first_pull() {
  local d; d="$(new_workdir)"
  db_create "$d/remote.kdbx"
  if run_sync "$d/local.kdbx" "$d/remote.kdbx" >/tmp/out.$$ 2>&1; then
    if [[ -f "$d/local.kdbx" ]] && cmp -s "$d/local.kdbx" "$d/remote.kdbx"; then
      ok "first-pull: local created, matches remote"
    else
      bad "first-pull: local missing or differs"; cat /tmp/out.$$
    fi
  else
    bad "first-pull: sync should have succeeded"; cat /tmp/out.$$
  fi
  rm -rf "$d" /tmp/out.$$
}

# --- Case 4: remote has an entry local doesn't -> merge pulls it in ---------
test_remote_only_edit_pulled() {
  local d; d="$(new_workdir)"
  db_create "$d/local.kdbx"
  cp "$d/local.kdbx" "$d/remote.kdbx"
  db_add "$d/remote.kdbx" "remoteEntry"

  run_sync "$d/local.kdbx" "$d/remote.kdbx" >/tmp/out.$$ 2>&1
  local rc=$?
  local entries; entries="$(db_entries "$d/local.kdbx")"
  if [[ $rc -eq 0 ]] && echo "$entries" | grep -q "remoteEntry"; then
    ok "remote-only-edit: local picked up remote's new entry"
  else
    bad "remote-only-edit: local did not get remote's entry (rc=$rc)"; cat /tmp/out.$$
  fi
  rm -rf "$d" /tmp/out.$$
}

# --- Case 5: both sides add a different entry -> merge keeps both ----------
test_both_sides_merged() {
  local d; d="$(new_workdir)"
  db_create "$d/local.kdbx"
  cp "$d/local.kdbx" "$d/remote.kdbx"
  db_add "$d/local.kdbx" "localEntry"
  db_add "$d/remote.kdbx" "remoteEntry"

  run_sync "$d/local.kdbx" "$d/remote.kdbx" >/tmp/out.$$ 2>&1
  local rc=$?
  local local_entries remote_entries
  local_entries="$(db_entries "$d/local.kdbx")"
  remote_entries="$(db_entries "$d/remote.kdbx")"

  if [[ $rc -eq 0 ]] \
    && echo "$local_entries" | grep -q "localEntry" \
    && echo "$local_entries" | grep -q "remoteEntry" \
    && echo "$remote_entries" | grep -q "localEntry" \
    && echo "$remote_entries" | grep -q "remoteEntry"; then
    ok "both-sides-merged: both entries present on local AND remote after sync"
  else
    bad "both-sides-merged: entries missing somewhere (rc=$rc)"
    say "local: $local_entries"; say "remote: $remote_entries"; cat /tmp/out.$$
  fi
  rm -rf "$d" /tmp/out.$$
}

# --- Case 6: running sync twice in a row is a safe no-op --------------------
test_idempotent_rerun() {
  local d; d="$(new_workdir)"
  db_create "$d/local.kdbx"
  cp "$d/local.kdbx" "$d/remote.kdbx"
  db_add "$d/local.kdbx" "onlyEntry"

  run_sync "$d/local.kdbx" "$d/remote.kdbx" >/tmp/out.$$ 2>&1
  local rc1=$?
  run_sync "$d/local.kdbx" "$d/remote.kdbx" >/tmp/out2.$$ 2>&1
  local rc2=$?

  if [[ $rc1 -eq 0 && $rc2 -eq 0 ]] \
    && [[ "$(db_entries "$d/local.kdbx")" == "$(db_entries "$d/remote.kdbx")" ]]; then
    ok "idempotent-rerun: two syncs in a row both succeed, stay in sync"
  else
    bad "idempotent-rerun: rc1=$rc1 rc2=$rc2"; cat /tmp/out.$$; cat /tmp/out2.$$
  fi
  rm -rf "$d" /tmp/out.$$ /tmp/out2.$$
}

# --- Case 7: remote changes while we're mid-merge -> retry picks it up -----
test_concurrent_remote_change_retried() {
  local d; d="$(new_workdir)"
  db_create "$d/local.kdbx"
  cp "$d/local.kdbx" "$d/remote.kdbx"
  db_add "$d/local.kdbx" "localEntry"
  db_add "$d/remote.kdbx" "remoteEntryBefore"

  # Trickle-feed the password via a FIFO: keepassxc-cli does a buffered stdin
  # read, so a fully pre-written pipe (e.g. `yes`) lets attempt 1's process
  # over-consume bytes meant for attempt 2's prompt. Spacing writes out avoids
  # that -- a real interactive user wouldn't pre-type passwords either, so
  # this is purely a quirk of non-interactive test automation. A FIFO (rather
  # than piping straight into the backgrounded command) also keeps $! pointed
  # unambiguously at the sync process, not the feeder.
  local pwfifo="$d/pwfifo"
  mkfifo "$pwfifo"
  ( printf '%s\n' "$TEST_PASS"; sleep 3; printf '%s\n' "$TEST_PASS"; sleep 3; printf '%s\n' "$TEST_PASS" ) \
    > "$pwfifo" 2>/dev/null &
  local feeder_pid=$!

  VAULT_LOCAL="$d/local.kdbx" VAULT_REMOTE_HOST="local" VAULT_REMOTE_PATH="$d/remote.kdbx" \
    VAULT_SYNC_TEST_DELAY_MERGE=2 bash "$SYNC" < "$pwfifo" >/tmp/out.$$ 2>&1 &
  local syncer_pid=$!

  sleep 0.5
  db_add "$d/remote.kdbx" "remoteEntryDuringSync"

  wait "$syncer_pid"
  local rc=$?
  wait "$feeder_pid" 2>/dev/null || true
  local local_entries; local_entries="$(db_entries "$d/local.kdbx")"
  local remote_entries; remote_entries="$(db_entries "$d/remote.kdbx")"

  if [[ $rc -eq 0 ]] \
    && echo "$local_entries" | grep -q "remoteEntryDuringSync" \
    && echo "$remote_entries" | grep -q "localEntry"; then
    ok "concurrent-change-retried: late remote edit not lost, local edit reached remote"
  else
    bad "concurrent-change-retried: rc=$rc"
    say "local: $local_entries"; say "remote: $remote_entries"; cat /tmp/out.$$
  fi
  rm -rf "$d" /tmp/out.$$
}

# --- Case 8: --check reports differences without changing anything ---------
test_check_mode() {
  local d; d="$(new_workdir)"
  db_create "$d/local.kdbx"
  cp "$d/local.kdbx" "$d/remote.kdbx"

  if run_sync "$d/local.kdbx" "$d/remote.kdbx" --check >/tmp/out.$$ 2>&1; then
    ok "check-mode: reports identical as OK (exit 0)"
  else
    bad "check-mode: expected exit 0 for identical files"; cat /tmp/out.$$
  fi

  db_add "$d/remote.kdbx" "newRemoteEntry"
  if run_sync "$d/local.kdbx" "$d/remote.kdbx" --check >/tmp/out2.$$ 2>&1; then
    bad "check-mode: expected non-zero exit after remote diverged"
  else
    ok "check-mode: reports divergence (exit non-zero)"
  fi
  # --check must never touch local/remote (no merge/upload)
  if ! grep -q "newRemoteEntry" <(db_entries "$d/local.kdbx"); then
    ok "check-mode: did not mutate local"
  else
    bad "check-mode: local was mutated despite --check"
  fi
  rm -rf "$d" /tmp/out.$$ /tmp/out2.$$
}

main() {
  test_neither_exists
  test_first_push
  test_first_pull
  test_remote_only_edit_pulled
  test_both_sides_merged
  test_idempotent_rerun
  test_concurrent_remote_change_retried
  test_check_mode

  echo
  echo "passed: $PASS   failed: $FAIL"
  [[ $FAIL -eq 0 ]]
}

main
