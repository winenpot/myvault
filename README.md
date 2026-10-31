# myvault

Self-hosted KeePassXC password vault.

- KeePassXC 2.8.0 built from source (upstream INSTALL.md, tag `latest`), packaged as a
  .deb, installed identically on the laptop and on atpg.
- atpg holds the canonical `passwords.kdbx` in an SFTP-only chroot (user `vault`).
- Laptop syncs with `scripts/vault-sync.sh` (download -> keepassxc-cli merge -> safe upload).
- Android: Keepass2Android opens the file over SFTP.

Plan and progress: `.hermes/plans/2026-10-31_063000-keepassxc-vault.md`

Never committed: *.kdbx, key files, .env, upstream/ source, dist/ packages.
