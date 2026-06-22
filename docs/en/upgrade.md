# Upgrade

[Back to README](../README.en.md)

## Should you upgrade?

The Baize console shows a prompt in the top-right corner when a new version is available. Before upgrading, settle three things:

1. **Back up first.** The upgrade backs up automatically, but schema changes **do not roll back automatically** — recovery is only possible by explicitly restoring from a backup. See [Backup & Restore](backup-and-restore.md).
2. **Is this the active version?** Only upgrade in the installation directory you're currently using, to avoid an old directory and the running service competing for the database port.
3. **Deployment config is preserved.** The upgrade keeps your deployment shape in `.env` (such as `BAIZE_STACK_MODE`) and does not reset your installation directory.

## Check the version

```bash
bash scripts/version.sh                 # show current version
bash scripts/version.sh --check-remote  # compare against the latest remote version
bash scripts/version.sh --verbose       # inspect local source and build details when troubleshooting
```

`scripts/version.sh` shows the installed version, Release tag, image, deploy mode, and container status by default. Add `--verbose` to inspect local Git and build details when investigating the release source.

## Run the upgrade

```bash
bash scripts/upgrade.sh
```

The upgrade script automatically backs up `.env`, version files, the Compose config, and the database, then pulls the target version and completes deployment and checks. On failure it enters a recovery wizard where you can:

- View recent logs
- Restore the pre-upgrade database and config
- Re-run this upgrade after restoring
- Roll back only to the pre-upgrade version
- Delete the data volume and rebuild from a backup if the database is corrupted

## What the upgrade preserves

The upgrade preserves `BAIZE_STACK_MODE` in `.env`:

- If it is `server-only`, only the central server starts after the upgrade.
- If it is `full`, the console continues to start after the upgrade.

## Schema and rollback

Required schema updates run automatically when the central server first starts and during upgrades. **Always back up the database before upgrading** — the schema does not roll back automatically and must be restored explicitly when needed:

```bash
bash scripts/restore-backup.sh --backup-dir ~/.baize/backups/baize-<instance>/<backup> --yes
bash scripts/restore-backup.sh --latest --yes --require-db
```

If the current database volume can no longer start, you can rebuild it from a backup:

```bash
bash scripts/restore-backup.sh --latest --yes --require-db \
  --reset-volumes --i-understand-data-loss
```

`--reset-volumes` deletes the current PostgreSQL / Redis data volumes and should only be used when you are sure you want to rebuild from a backup.

## Related docs

- [Backup & Restore](backup-and-restore.md)
- [Deployment Modes & Access URLs](deployment.md)
- [Troubleshooting](troubleshooting.md)
