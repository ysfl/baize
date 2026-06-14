# Baize

[中文](README.md) | English

Baize is a self-hosted server management platform. Run Baize on one server, install a lightweight Agent on each server you want to manage, and operate everything from a single console: asset onboarding, real-time monitoring, security protection, remote operations, and audit trails.

- **Asset onboarding**: see the status, configuration, and load of every server in one place.
- **Real-time monitoring**: live metrics and alerts for CPU, memory, disk, network, processes, and services.
- **Security protection**: login risk control, WAF coordination, and unified visibility into certificates and firewalls.
- **Remote operations**: remote commands, file distribution, scheduled tasks, service management, and a web terminal.
- **Audit trails**: key actions are recorded and can be traced afterwards.

Your data stays on your own servers. Baize does not depend on any external hosting.

This repository is the **public deployment entry** for Baize. It provides Docker Compose files, install and upgrade scripts, backup and restore tools, and version manifests. The Baize control service, node Agent, and console are distributed as container images and public release packages through the image registry and GitHub Releases.

## Quick Start

Prepare a Linux server (2 vCPU / 4 GB RAM / 20 GB disk to start) with Docker installed, then:

```bash
git clone https://github.com/ysfl/baize.git
cd baize
bash scripts/install.sh
```

The installer guides you through configuration, generates strong random values for the database password, Redis password, JWT secret, initial admin password, credential master key, and high-risk action security code, and starts all containers.

Default endpoints after installation:

```text
Console:     http://<server-ip>:8088
Service URL: http://<server-ip>:22501/api/v1
```

The initial admin username is `admin`; its password is stored as `ADMIN_PASSWORD` in the generated `.env`. High-risk actions such as refreshing host profiles and revealing command history use a separate security code, stored as `BAIZE_HOST_PROFILE_SECURITY_CODE` in `.env`. **Change the admin password right after the first login**, and keep `.env` safe — do not commit it to Git.

### Onboard a server

Create a registration token in the console, then run on the target server:

```bash
bash scripts/install-agent.sh \
  --server https://baize.example.com \
  --token <registration-token>
```

Install the Agent directly on the managed host so it can read host-level process, disk, Docker, and firewall state. Running the Agent inside a container in production is not recommended.

## Deployment Modes

Three modes, selected with `--deploy-mode`:

- `image` (recommended for production): pull and run the control service and console images directly.
- `build`: download public release packages from Releases into the matching `dist` directories, then build images locally.
- `auto` (default): use `build` when complete local artifacts exist, otherwise `image`.

Non-interactive install:

```bash
bash scripts/install.sh --yes \
  --public-url https://baize.example.com \
  --web-api-base-url /api/v1 \
  --deploy-mode image \
  --server-image ghcr.io/ysfl/baize-server:0.1.31 \
  --web-image ghcr.io/ysfl/baize-web:0.1.31 \
  --server-public-port 22501 \
  --web-public-port 8088
```

## URL Configuration

`.env` has two kinds of addresses for two kinds of clients:

- `AGENT_PUBLIC_SERVER_URL`: the address managed servers use to reach Baize; must start with `http://` or `https://`.
- `WEB_API_BASE_URL`: the Baize service URL the browser uses after loading the console.

Recommended same-origin reverse proxy (no CORS issues):

```env
WEB_API_BASE_URL=/api/v1
```

The console container then proxies `/api/`, `/ws`, `/install.sh`, `/install.ps1`, and `/download/` to the control service.

Split console/service deployment:

```env
WEB_API_BASE_URL=https://api.example.com/api/v1
CORS_ALLOW_ORIGINS=https://console.example.com
```

Restart after editing `.env`:

```bash
bash scripts/deploy-server.sh --skip-build
```

## Upgrade

The Baize console shows a version prompt in the top-right corner. From the command line:

```bash
bash scripts/version.sh                 # show current version
bash scripts/version.sh --check-remote  # compare with the latest remote version
bash scripts/version.sh --verbose       # show local source and build details for troubleshooting
bash scripts/upgrade.sh                 # run the upgrade
```

`scripts/version.sh` shows the installed version, Release tag, images, deploy mode, and container status by default. Add `--verbose` only when you need local Git and build details for troubleshooting.

The upgrade script backs up `.env`, version files, Compose config, and the database, then fetches the target version and completes deployment and checks. On failure it attempts to roll back to the previous version.

Required data-structure updates run automatically when the control service starts or upgrades. **Always back up the database before upgrading** — data-structure changes do not roll back automatically; restore explicitly from a backup when needed:

```bash
bash scripts/restore-backup.sh --backup-dir ~/.baize/backups/baize-<instance>/<backup> --yes
```

## Backup

```bash
bash scripts/backup.sh --yes                              # back up now
bash scripts/install-backup-cron.sh --yes                 # daily 03:00 backup, keeps 14 days by default
bash scripts/cleanup-backups.sh --dry-run --keep-days 30  # preview cleanup
```

Backups default to `~/.baize/backups/baize-<instance-hash>`, outside the Git checkout.

## Checks

```bash
bash scripts/check-install.sh --offline   # static check
bash scripts/check-install.sh             # runtime check
```

## Advanced Configuration

The following is for administrators who need fine-grained control over the deployment.

### Configuration Security

Production `.env` should be generated by the install script or filled with your own strong random values. These must not be empty and must not use fixed defaults:

`POSTGRES_PASSWORD`, `DB_PASSWORD`, `REDIS_PASSWORD`, `JWT_SECRET`, `ADMIN_PASSWORD`, `CREDENTIAL_MASTER_KEY`, `BAIZE_HOST_PROFILE_SECURITY_CODE` or `BAIZE_HOST_PROFILE_SECURITY_CODE_HASH`, `AGENT_PUBLIC_SERVER_URL`.

`BAIZE_HOST_PROFILE_SECURITY_CODE` protects host profile refreshes and command history reveal actions as a second check; it is not the login password. In production you can replace it with `BAIZE_HOST_PROFILE_SECURITY_CODE_HASH` and clear the plaintext code.

When PostgreSQL is hosted by Docker, `DB_PASSWORD` must equal `POSTGRES_PASSWORD`. When using an external database, also update `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_SSLMODE`.

For production, configure a domain access policy for the console to reduce direct IP access, unknown Host values, or misdirected domains reaching the Web console:

```env
BAIZE_WEB_DOMAIN=console.example.com
BAIZE_WEB_ALLOWED_HOSTS=console.example.com,www.example.com
```

Use `BAIZE_WEB_DOMAIN` when the console has one domain. Use `BAIZE_WEB_ALLOWED_HOSTS` for multiple allowed domains, separated by commas. When configured, the Web entry rejects Host values outside the list. Leaving both empty keeps compatibility mode for first-time setup or temporary private-network access.

### Console-triggered Upgrade (disabled by default)

By default the deployment only shows upgrade hints in the console and never lets a container run host commands. To allow console-triggered upgrades, enable it explicitly:

```env
BAIZE_UPGRADE_RUNNER_ENABLED=true
BAIZE_UPGRADE_MODE=docker-updater
BAIZE_DOCKER_UPGRADE_COMMAND=cd /path/to/baize && BAIZE_DEPLOY_MODE=image bash scripts/upgrade.sh --mode docker-updater --yes
```

Do not mount the Docker Socket into a normal container just to gain host control. Prefer a controlled operations host or a host-mode control service.

### Reinitialization (destructive)

The upgrade flow refuses `--force-config` because it overwrites `.env` and regenerates all secrets, which can invalidate the existing database, login tokens, Agent communication, and encrypted credentials. Use the dedicated entry only when intentional:

```bash
# regenerate .env only, without starting or resetting containers
bash scripts/reinit-config.sh --config-only --i-understand-reinit

# back up, then drop the current database / Redis volumes and deploy a fresh stack
bash scripts/reinit-config.sh --reset-stack \
  --i-understand-reinit \
  --i-understand-data-loss
```

`--reset-stack` wipes data. Only append `--skip-backup --yes --i-understand-no-backup` when you explicitly accept data loss.

## Repository Layout

```text
docker-compose.yml          image-based deployment
docker-compose.build.yml    local artifact build override
scripts/                    install, check, backup, upgrade, restore scripts
releases/latest.json        latest version manifest used by the console
releases/changelog.json     changelog displayed by the console
server/ agent/ web/ dist/   optional local release package directories, .gitkeep only by default
```

## Support

For trials, deployment help, or commercial support, scan to get in touch:

<img src="assets/contact-qr.png" alt="Baize contact QR" width="240">
