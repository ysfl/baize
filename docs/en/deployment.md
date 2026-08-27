# Deployment Modes & Access URLs

[Back to README](../README.en.md)

This page covers deployment options beyond the quick start: which services to launch, where images come from, and how to configure the console and service URLs. If you just want to get Baize running, start with the "Quick Start" section in the README.

## Two independent deployment choices

Baize deployment is controlled by two independent switches:

- `--stack-mode` decides **which services start**.
- `--image-source` decides **which public download endpoints are used**.

### `--stack-mode` (which services start)

- `full` (default): deploys PostgreSQL, Redis, the central server, and the console.
- `server-only`: deploys only PostgreSQL, Redis, and the central server, without starting the console container. Use this when you run a standalone console, only need the service API, or the console is provided by another environment.

### `--image-source` (where downloads come from)

- `github` (default): downloads the server and console from GHCR, TimescaleDB and Redis from Docker Hub, and release metadata from GitHub.
- `acr`: uses Alibaba Cloud images, mainland China image acceleration, and the Gitee release manifest.

All listed images support anonymous pulls. Use `--image-source acr` for unattended deployments in mainland China.

On first install, the script detects the host architecture, checks the Docker daemon and ports, and attempts to prepare the offline GeoIP databases. A GeoIP download failure does not block the central service; location fields stay empty until the databases are added. Add `--require-geoip` to make the database mandatory, or `--skip-geoip` to skip the attempt.

## Unattended install examples

Full deployment:

```bash
bash scripts/install.sh --yes \
  --image-source github \
  --stack-mode full \
  --server-public-port 22501 \
  --web-public-port 8088 \
  --public-url http://<your-server-ip-or-domain>:22501 \
  --web-api-base-url /api/v1 \
  --skip-server-host-agent
```

Server-only deployment:

```bash
bash scripts/install.sh --yes \
  --image-source github \
  --stack-mode server-only \
  --server-public-port 22501 \
  --public-url http://<your-server-ip-or-domain>:22501 \
  --skip-server-host-agent
```

`server-only` does not occupy the console port or start the console container. To switch back to full deployment later, set `BAIZE_STACK_MODE=full` in `.env`, make sure the console port is free, and re-run:

```bash
bash scripts/deploy-server.sh
```

## Access URL configuration

`.env` has two kinds of URLs, each serving a different audience:

- `AGENT_PUBLIC_SERVER_URL`: the URL managed servers use to reach Baize. Must start with `http://` or `https://`.
- `WEB_API_BASE_URL`: the URL the browser uses to reach the Baize service after opening the console.

### Recommended: same-origin reverse proxy

The browser won't hit any cross-origin issues:

```env
WEB_API_BASE_URL=/api/v1
```

In this mode the console container reverse-proxies `/api/`, `/ws`, `/install.sh`, `/install.ps1`, and `/download/` to the central server.

When accessing Baize through a reverse proxy, declare the trusted proxy network in `.env` so the central server can restore real client addresses, and rate limiting plus audit attribution follow the true source:

```env
SERVER_TRUSTED_PROXIES=172.18.0.0/16
```

- List the network where the reverse proxy runs (IP or CIDR, comma-separated for several).
- Since 0.2.2 no proxy is trusted by default: when unset, client addresses come from the direct connection, so reverse-proxy deployments would see every request from one source and rate limiting would misfire.
- Run `bash scripts/deploy-server.sh` after changing `.env` to apply it.

### Console and service on separate origins

```env
WEB_API_BASE_URL=https://<your-api-domain>/api/v1
CORS_ALLOW_ORIGINS=https://<your-console-domain>
```

Restart after editing `.env`:

```bash
bash scripts/deploy-server.sh
```

In `server-only` mode the console container is not started, so `WEB_API_BASE_URL` only takes effect when you re-enable the console container.

### Server-host executor

After the central server is healthy, the public installer attempts to install a local executor on the current host. It handles later operations that require host access, such as upgrades, backups, and migrations, and does not run inside a Docker container. For image deployments on Linux with systemd, it also installs the fixed updater used to update Server or Web independently from the console.

The executor connects to `http://127.0.0.1:<SERVER_PUBLIC_PORT>` by default, independently of `AGENT_PUBLIC_SERVER_URL`. Use `BAIZE_SERVER_HOST_AGENT_ENABLED=false` to skip automatic installation, or set `BAIZE_SERVER_HOST_AGENT_INTERNAL_URL` only when the host must use a different local access path.

Host-level installation runs only when the process is root, has passwordless `sudo`, or receives `--install-server-host-agent` from an interactive terminal. On systems without systemd/launchd, or without the required permission, the installer skips the optional step and prints guidance; the container deployment remains successful.

Do not pass `--skip-server-host-agent` when console component updates are required. This capability also requires the executor to run with the `server_host` role, exactly one executor with that role to be online, and the image-update capability to be advertised. The Server container does not mount the Docker socket; actual Docker operations run only in the fixed host-side systemd service. On non-Linux hosts, without systemd, outside image deployment mode, or when the local executor is skipped, the console still shows version information but explains why update buttons are unavailable.

### Interruptions, failures, and retry

`Ctrl-C` and deployment failures preserve `.env`, containers, and data volumes. The installer prints the failed stage, container status, recent logs, and a retry command. After Docker is available again, rerun from the installation directory:

```bash
bash scripts/install.sh --yes
```

To inspect the preserved state first:

```bash
bash scripts/check-install.sh --allow-missing-geoip
docker compose ps -a
docker compose logs --tail=120 server
```

Do not run `docker compose down --volumes` during troubleshooting unless you explicitly accept data loss.

## Default ports

| Service | Default port |
| --- | --- |
| Console (Web) | `8088` |
| Central server API | `22501` (`8080` inside the container) |
| PostgreSQL | `15432` |
| Redis | `16379` |

## Repository layout

```text
docker-compose.yml          image-based deployment orchestration
scripts/                    install, check, backup, upgrade, restore scripts
releases/latest.json        latest-version manifest used by console update check
releases/changelog.json     changelog shown on the console version page
```

## Related docs

- [Local Console Connection](server-only-local-web.md)
- [Upgrade](upgrade.md)
- [Backup & Restore](backup-and-restore.md)
- [Uninstall and Cleanup](uninstall.md)
- [Advanced Configuration](advanced.md)
- [Troubleshooting](troubleshooting.md)
