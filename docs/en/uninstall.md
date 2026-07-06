# Uninstall and Cleanup

[Back to README](../../README.en.md)

When you migrate, reinstall, or stop using Baize, handle it in this order: back up first, uninstall next, then clean data only if you are sure. The default uninstall keeps Docker volumes, `.env`, and backup files so you can recover from mistakes. Data is deleted only when you pass explicit purge options.

## Recommended Flow

```bash
# Stop and remove Baize containers, uninstall the local connection program, and keep data/config
bash scripts/uninstall.sh --yes --lang en
```

The default flow does this:

| Step | Default behavior |
| --- | --- |
| Backup before uninstall | Runs automatically and prints the backup path |
| Local connection program | Tries to uninstall the connection program and login notice on the current host |
| Containers | Stops and removes Baize containers and networks |
| Volumes | Keeps PostgreSQL, Redis, and service data volumes |
| Config and backups | Keeps `.env` and existing backups |

If you only want to create a backup:

```bash
bash scripts/backup.sh --yes --lang en
```

## Full Cleanup

After you confirm the backup is usable and you no longer need the current instance data, run destructive cleanup:

```bash
bash scripts/uninstall.sh --yes --lang en \
  --purge-data \
  --purge-config \
  --i-understand-data-loss
```

To also delete the backup directory for this instance:

```bash
bash scripts/uninstall.sh --yes --lang en \
  --purge-all \
  --i-understand-data-loss
```

`--purge-all` deletes Docker volumes, `.env`, and this instance's backup directory. Copy any backup you want to keep to another location before running it.

To remove the checkout directory too, leave the directory after the uninstall command finishes:

```bash
cd ..
rm -rf baize
```

## Uninstall Only the Local Connection Program

If you only want to remove the connection program on the current host and keep Baize running:

```bash
bash scripts/install-agent.sh --uninstall
```

This stops and removes the `baize-agent` system service, install directory, and login notice. Connection programs on other managed servers must be uninstalled on those servers separately.

## Restore from Backup

To restore after uninstalling, use a clean directory:

```bash
git clone https://github.com/ysfl/baize.git baize-restore
cd baize-restore

bash scripts/restore-backup.sh \
  --backup-dir ~/.baize/backups/baize-<instance>/<backup> \
  --yes --require-db --reset-volumes --i-understand-data-loss
```

After restore:

```bash
bash scripts/check-install.sh
```

## Related Docs

- [Backup and Restore](backup-and-restore.md)
- [Deployment Modes and URLs](deployment.md)
- [Troubleshooting](troubleshooting.md)
