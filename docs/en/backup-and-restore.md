# Backup & Restore

[Back to README](../README.en.md)

## Backup

```bash
bash scripts/backup.sh --yes                          # back up now
bash scripts/install-backup-cron.sh --yes             # install a daily 03:00 backup, retained 14 days by default
bash scripts/cleanup-backups.sh --dry-run --keep-days 30   # preview cleanup
```

Backups are stored outside the repository by default at `~/.baize/backups/baize-<instance-hash>`.

## Restore into a clean directory

When the existing installation directory is messy, or you need to reinstall in a clean directory, use the "back up first, then restore" approach instead of deleting the current data volumes:

```bash
# 1. Create a backup in the currently working installation directory
bash scripts/backup.sh --yes

# 2. Prepare a new installation directory
git clone https://github.com/ysfl/baize.git baize-new
cd baize-new

# 3. Restore .env and the database from the backup, starting services in the backup's deployment shape
bash scripts/restore-backup.sh \
  --backup-dir ~/.baize/backups/baize-<instance>/<backup> \
  --yes --require-db --reset-volumes --i-understand-data-loss
```

The restore script uses the `.env` from the backup, preserving the database password, JWT secret, credential master key, and the high-sensitivity operation security code. **Do not import an old database with a freshly generated `.env`**, or login tokens, Agent communication, or encrypted credentials may become unusable. Only archive the old directory after confirming the new one can log in, Agents can connect, and backups are traceable.

## Installation check

```bash
bash scripts/check-install.sh --offline   # static check
bash scripts/check-install.sh             # runtime check
```

## Related docs

- [Upgrade](upgrade.md)
- [Deployment Modes & Access URLs](deployment.md)
- [Troubleshooting](troubleshooting.md)
