# Troubleshooting

[Back to README](../README.en.md)

When something goes wrong, run an installation check first — it points to the cause of most problems:

```bash
bash scripts/check-install.sh             # runtime check
bash scripts/check-install.sh --offline   # static check when not running
bash scripts/version.sh --verbose         # show version, image, deploy mode, and container status
```

## Console won't open after install

- Confirm the console container started: `bash scripts/check-install.sh`.
- Confirm you're hitting the console port (default `8088`), not the service port (default `22501`).
- If you installed with `server-only`, the console container **is not started** — this is expected. Switch back to `full` for a console; see [Deployment](deployment.md).
- With a domain access policy configured (`BAIZE_WEB_DOMAIN` / `BAIZE_WEB_ALLOWED_HOSTS`), direct IP access or an unlisted domain is rejected. To investigate, temporarily clear both; see [Advanced Configuration](advanced.md#domain-access-policy).

## Agent can't reach the central server

- Confirm `--server` for `install-agent.sh` is a Baize URL the managed server **can actually reach**, starting with `http(s)://`. The installer ships no default control endpoint.
- Confirm the registration token hasn't expired; regenerate it in the console if needed.
- Confirm `AGENT_PUBLIC_SERVER_URL` in `.env` matches the real external URL.
- Install the Agent directly on the managed server's host (not inside a container), otherwise it can't read host state such as processes, disks, Docker, and the firewall.

## How to roll back a failed upgrade

When the upgrade script fails it enters a recovery wizard where you can restore the pre-upgrade database and config, roll back to the previous version, or retry after restoring. See [Upgrade](upgrade.md).

Manual database rollback:

```bash
bash scripts/restore-backup.sh --latest --yes --require-db
```

## Database volume corrupted, service won't start

Rebuild the volume from the most recent backup (deletes the current PostgreSQL / Redis data volumes):

```bash
bash scripts/restore-backup.sh --latest --yes --require-db \
  --reset-volumes --i-understand-data-loss
```

`--reset-volumes` is destructive and should only be used when you are sure you want to rebuild from a backup. See the full flow in [Backup & Restore](backup-and-restore.md).

## Forgot admin password / security code

- The initial admin password is in `.env` as `ADMIN_PASSWORD`, and the high-sensitivity operation security code is in `BAIZE_HOST_PROFILE_SECURITY_CODE`.
- If you changed them and forgot the current value, run the reset scripts from the installation directory. See [Admin Password & Security Code Reset](credential-reset.md) for admin password, security code, and account-lock recovery.

## Port conflict / old directory holding the database

- Only run upgrades or deployments in the installation directory you're currently using, to **avoid an old directory and the running service competing for the database port**.
- Default ports: console `8088`, service `22501`, PostgreSQL `15432`, Redis `16379`. On conflict, adjust the matching `*_PUBLIC_PORT` in `.env`.

## Server location keeps showing "pending"

Location display depends on the offline GeoIP databases in the installation directory. If the server list, overview, or profile page opens normally but country, city, or coordinates stay empty, run:

```bash
bash scripts/install-geoip-databases.sh
bash scripts/check-install.sh --offline
docker compose restart server
```

If `check-install.sh --offline` still reports missing GeoIP data, check:

- The `server` service in `docker-compose.yml` mounts `./runtime:/app/runtime:ro`.
- `GEOIP_CITY_MMDB_PATH` and `GEOIP_ASN_MMDB_PATH` in `.env` still point to `/app/runtime/geoip/dbip-city-lite.mmdb` and `/app/runtime/geoip/dbip-asn-lite.mmdb`.
- `runtime/geoip/` contains `dbip-city-lite.mmdb` and `dbip-asn-lite.mmdb`.

For an environment without internet access, place the matching DB-IP Lite City and ASN archives in `runtime/geoip/`, then run:

```bash
GEOIP_OFFLINE_BACKFILL_ONLY=true bash scripts/install-geoip-databases.sh
bash scripts/check-install.sh --offline
docker compose restart server
```

See [Advanced Configuration](advanced.md#server-location-display) for the full flow.

## Still stuck

- File an issue: <https://github.com/ysfl/baize/issues>
- Join the community: <https://discord.gg/UMR7mnZFqh>
- For deployment assistance or commercial support, see "Community & Support" in the README.

## Related docs

- [Upgrade](upgrade.md)
- [Backup & Restore](backup-and-restore.md)
- [Deployment Modes & Access URLs](deployment.md)
- [Advanced Configuration](advanced.md)
- [Admin Password & Security Code Reset](credential-reset.md)
