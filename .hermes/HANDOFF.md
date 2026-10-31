# Session Handoff

## Current handoff — 2026-10-31, end of day-1 session

Branch: main (clean, matches origin/main exactly, nothing ahead/behind)
Repo: /home/winenpot/code/myvault, pushed to https://github.com/winenpot/myvault (public)

Active task: T9 — server-side versioned backups on atpg (not started).
See full task list and history: `.hermes/plans/2026-10-31_063000-keepassxc-vault.md`
(progress markers at the top of that file are accurate and current: T0-T8 done, T9 is next).

### Completed and verified today (T0-T8)

- KeePassXC 2.8.0 built from source on this PC (work-pc), upstream `latest` tag,
  full test suite 46/46 passed.
- Packaged as `keepassxc_2.8.0-1myvault1_amd64.deb` (sha256
  a794002ec0eaeb7281ce70af15bf872c4a708e81d9462ca278524a913a0b4ee0), installed
  identically on work-pc and on atpg (verified: same version, same hash, `dpkg -V`
  clean on both).
- Real vault created by user: `~/Vault/passwords.kdbx`, KDBX4, Argon2id 64 MiB.
- atpg: `vault` SFTP-only chroot user set up and verified (shell refused, password
  auth refused, sftp works). SSH alias `atpg-vault` in `~/.ssh/config`, dedicated
  key `~/.ssh/vault_ed25519`.
- `scripts/vault-sync.sh` + `tests/test_sync.sh` (10/10 pass, no network). Two real
  bugs found and fixed during testing (sftp command-echo false positive in
  remote_exists; `.env` clobbering caller-exported env vars) — full postmortem is
  in the plan file under T8. Verified by sha256 that no real data was lost or
  corrupted despite the bug.
- Real vault is actually already synced: `bash scripts/vault-sync.sh --check` on
  work-pc reports "byte-identical" against atpg right now (re-verified at the top
  of this session, see command output above).
- Repo pushed to GitHub as **public**: only 7 files tracked, none sensitive
  (grepped tracked content for IPs/keys/passwords — clean). `.gitignore` hardened
  (SSH keys, `*.pem`, `.env.*`, etc.) and every pattern verified with
  `git check-ignore`.

### Files belonging to the active/recent work

- `.hermes/plans/2026-10-31_063000-keepassxc-vault.md` — the authoritative task plan,
  keep following it task-by-task.
- `scripts/build-keepassxc.sh`, `scripts/vault-sync.sh`, `tests/test_sync.sh`
- `.env` (NOT committed, exists only on work-pc: VAULT_LOCAL=/home/winenpot/Vault/passwords.kdbx,
  VAULT_REMOTE_HOST=atpg-vault, VAULT_REMOTE_PATH=/data/passwords.kdbx)
- `~/Vault/passwords.kdbx` (the real vault) + `~/Vault/.bak/` (8 harmless duplicate
  backups from the T8 bug incident, auto-prunes at 20, no action needed)
- On atpg: `/srv/vault/` (chroot root), `/srv/vault/data/passwords.kdbx` (canonical
  remote copy, currently byte-identical to local), `/etc/ssh/sshd_config.d/50-vault.conf`,
  `/etc/ssh/vault_authorized_keys`

### Declined / open decisions (don't re-ask, just pick up)

- A real merge round-trip (editing the vault, then running `vault-sync.sh` and typing
  the real master password) hasn't been done by the user yet. Not blocking; the
  check-mode verification above substitutes for it for now. Worth doing once,
  whenever convenient.
- T10 (laptop/PC automation) has an open choice already flagged in the plan:
  manual `vault-sync` alias vs. a systemd timer that needs the master password
  stored in the GNOME keyring. Ask the user at T10, don't decide it here.
- atpg's global sshd config still allows `PasswordAuthentication yes` for all other
  accounts (unrelated to the vault Match block, which is key-only). Flagged as a
  separate hardening item, intentionally not touched by this project.

### Next action

Start T9: server-side versioned backups on atpg. Per the plan:
- Root systemd timer on atpg, daily, `cp -a /srv/vault/data/passwords.kdbx` to
  `/srv/vault-backups/YYYY-MM-DD.kdbx` (outside the chroot, root:root 700), keep 60
  days, verify KDBX magic bytes (`03d9a29a`) before keeping a copy.
- atpg already has passwordless sudo for this session's user, so T9 can likely be
  done end-to-end without waiting on the user (same as T6/T7 were).
- Done when: `systemctl list-timers vault-backup.timer` shows a next run, and a
  manual trigger (`systemctl start vault-backup.service` or equivalent) produces a
  dated file.

### Remaining ordered work after T9

T10 (PC sync automation, needs a user decision) -> T11 (Android / Keepass2Android,
expected to be the hardest part) -> T12 (wrap-up docs, link from Hermes-Vault).
