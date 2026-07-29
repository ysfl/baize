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

## Choose an upgrade path

### Update only the Server or Web image

After a version formally ships this capability, the System Version page lets you select Server or Web independently. Use it when only one image was released and the current deployment directory and Compose configuration do not need to change.

The console enables each update button only when the deployment is ready:

- The deployment uses `BAIZE_DEPLOY_MODE=image`.
- The Server host is Linux with systemd, and its local executor is online with the fixed updater installed.
- Exactly one Server-host executor is online.
- The latest manifest provides a trusted SHA-256 digest for the target image.
- Web updates require `BAIZE_STACK_MODE=full`; a `server-only` deployment can update Server only.
- No other Server or Web update task is running.

The Server creates only a structured task. The host-side local executor pulls the image, verifies its digest, recreates only the selected container, and checks its health. On failure it restores the previous `.env` and component image. Before a Server update it also stores a PostgreSQL backup under `runtime/image-upgrade/backups/<task-id>/`. If the new Server has already changed the schema, automatic rollback restores configuration and the container but does not restore the database; an administrator must explicitly restore the backup after review.

This path does not update the deployment directory, Compose files, public scripts, or Agent. The current stable `0.2.1` manifest has no image digests, so the buttons remain unavailable. This is a safety prerequisite, not a prompt to bypass verification with a manually supplied image.

### Update the complete release set

When the deployment directory, Compose configuration, Agent, upgrade scripts, or complete release set must change, run this in the active installation directory:

```bash
bash scripts/upgrade.sh
```

The full upgrade script automatically backs up `.env`, version files, the Compose config, and the database, then pulls the target version and completes deployment and checks. On failure it enters a recovery wizard where you can:

- View recent logs
- Restore the pre-upgrade database and config
- Re-run this upgrade after restoring
- Roll back only to the pre-upgrade version
- Delete the data volume and rebuild from a backup if the database is corrupted

If the host does not yet have a local executor or the fixed updater, use the full upgrade path first to refresh the deployment directory. The deployment flow then attempts to install or refresh the local executor.

## What the upgrade preserves

Both paths preserve `BAIZE_STACK_MODE` in `.env`:

- With `server-only`, the full upgrade still starts only the central server, and the console path can update Server only.
- With `full`, the full upgrade continues to start the console, and the component path can update Server or Web independently.

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
