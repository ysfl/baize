<div align="center">

# Baize 白泽

**Self-hosted server management platform — one console, all your servers**

[中文](README.md) | English · [Website](https://baize.run/) · [Docs](#documentation)

Release & images: [Release](https://github.com/ysfl/baize/releases) · [Server image](https://github.com/users/ysfl/packages/container/package/baize-server) · [Console image](https://github.com/users/ysfl/packages/container/package/baize-web) · [Discord](https://discord.gg/UMR7mnZFqh)

</div>

Baize is a self-hosted server management platform. Start Baize on one server, install a lightweight Agent on every server you want to manage, and run **asset management, real-time monitoring, security protection, remote operations, and operation auditing** from a single console.

Your data stays entirely on your own servers — Baize relies on no external hosting.

> This repository is the **public deployment entry point** for Baize, providing Docker Compose orchestration, install and upgrade scripts, backup/restore tooling, and the version manifest. The Baize central server, node Agent, and console are distributed as container images and public release artifacts — get them from the registry or [GitHub Releases](https://github.com/ysfl/baize/releases).

Live preview and feature demo: [https://baize.run/](https://baize.run/)

![Baize node convergence topology](assets/baize-topology.en.svg)

## Core Capabilities

| Capability | What it does |
| --- | --- |
| **Asset management** | Onboard servers and view each machine's online status, config, and load in one place, with on-demand grouping. |
| **Full-stack monitoring** | CPU, memory, disk, network, processes, services, Nginx, Docker, SSL certificates — multi-dimensional metrics collected and visualized. |
| **Security protection** | Edge WAF, SSH brute-force detection, coordinated banning of attacking IPs, unified view of certificate and firewall status. |
| **Remote operations** | Web terminal, batch command execution, file distribution, service management — key operations recorded for audit. |
| **Task orchestration** | Distributed scheduled-task management, multi-node coordinated execution, unified result collection. |
| **Alerting & audit** | Rule engine, alert escalation, silencing policies, and multi-channel delivery; key operations are logged and traceable. |

## Who It's For

- **Self-hosting / private-deployment teams** who want their data to stay on their own servers but still want a modern control plane.
- **Multi-server operators** with a handful to dozens of machines who want unified management and monitoring instead of SSH-ing into each one.
- **Teams that need compliance trails** — key operations must be audited and traceable to a person.
- **Anyone replacing scattered scripts** — consolidate dispersed monitoring scripts, cron jobs, and emergency commands into one platform.

## How It Works

Baize uses an "edge intelligence · central scheduling" architecture:

![Baize workflow](assets/baize-workflow.en.svg)

The central server aggregates and schedules; a lightweight Agent on each managed server handles collection, execution, and edge defense. Console, mobile, and open integrations share the same control entry.

## Quick Start

Prepare a Linux server (2 vCPU / 4 GB RAM / 20 GB disk to start), install Docker, then:

```bash
git clone https://github.com/ysfl/baize.git
cd baize
bash scripts/install.sh
```

The install script guides you through configuration, automatically generating strong random values for the database password, Redis password, JWT secret, initial admin password, credential master key, and high-sensitivity operation security code, then brings up the default full deployment.

Default access URLs after installation:

```text
Console:  http://<your-server-ip-or-domain>:8088
Service:  http://<your-server-ip-or-domain>:22501/api/v1
```

The initial admin account is `admin`; its initial password is in `ADMIN_PASSWORD` in the generated `.env`. High-sensitivity operations such as host-profile refresh and plaintext command-history viewing use a separate security code, with its initial value in `BAIZE_HOST_PROFILE_SECURITY_CODE` in `.env`.

> ⚠️ **Change the password immediately after first login**, keep `.env` safe, and never commit it to Git.

Need unattended installs, `server-only` mode, or custom ports/images? See [Deployment Modes & Access URLs](docs/en/deployment.md). If you only deploy the central server on your Linux host and run the console locally, see [Local Console Connection](docs/en/server-only-local-web.md).

## What To Do After Install

1. **Log in and change the password** — log in with `admin` and the initial password from `.env`, then change it right away.
2. **Onboard your first node** — create a registration token in the console, then run on the target server's host:

   ```bash
   bash scripts/install-agent.sh \
     --server http://<your-server-ip-or-domain>:22501 \
     --token <registration-token>
   ```

   `--server` must be your own Baize URL; the installer ships no default control endpoint. Install the Agent directly on the managed server's host (not inside a container) so it can read host state such as processes, disks, Docker, and the firewall.
3. **Look around** — open Monitoring for live metrics, Security for WAF and login risk control, Audit for operation trails.
4. **Configure a domain access policy** (recommended for production) — reduce direct IP access and unknown Hosts reaching the console; see [Advanced Configuration](docs/en/advanced.md#domain-access-policy).

## Versions & Upgrades

The console prompts in the top-right corner when a new version is available. Before upgrading, remember:

- **Back up first.** The upgrade backs up automatically, but schema changes **do not roll back automatically** — recovery requires an explicit restore from a backup.
- **Deployment config is preserved.** The upgrade keeps your deployment shape in `.env` (such as `BAIZE_STACK_MODE`) and does not reset your installation directory.

The current beta is published as a GitHub Pre-release; update checks use the [latest manifest](releases/latest.json). Current images are [server `ghcr.io/ysfl/baize-server:0.1.38`](https://github.com/users/ysfl/packages/container/package/baize-server) and [console `ghcr.io/ysfl/baize-web:0.1.38`](https://github.com/users/ysfl/packages/container/package/baize-web).

```bash
bash scripts/version.sh --check-remote   # compare against the latest remote version
bash scripts/upgrade.sh                  # upgrade (auto-backup + failure wizard)
```

See full commands, failure rollback, and schema notes in the [upgrade docs](docs/en/upgrade.md).

## Documentation

| Doc | When to read it |
| --- | --- |
| [Deployment Modes & Access URLs](docs/en/deployment.md) | For `server-only`, unattended installs, split deployments, or custom ports/images |
| [Local Console Connection](docs/en/server-only-local-web.md) | To deploy only the central server and connect a locally running console |
| [Upgrade](docs/en/upgrade.md) | Pre-upgrade decisions, commands, failure rollback, and schema notes |
| [Backup & Restore](docs/en/backup-and-restore.md) | Scheduled backups, clean-directory restore, installation checks |
| [Admin Password & Security Code Reset](docs/en/credential-reset.md) | When you forgot the admin password or security code, or the account is locked |
| [Advanced Configuration](docs/en/advanced.md) | Config security, domain access policy, console-triggered upgrade, reinitialization |
| [Troubleshooting](docs/en/troubleshooting.md) | Console won't open, Agent can't connect, upgrade failures, volume corruption, and more |

## FAQ

<details>
<summary><b>Console won't open after install?</b></summary>

Run `bash scripts/check-install.sh` first. Confirm you're hitting the console port (default `8088`) and not the service port (`22501`); `server-only` mode does not start the console container. See [Troubleshooting](docs/en/troubleshooting.md).
</details>

<details>
<summary><b>Agent can't reach the central server?</b></summary>

Confirm `--server` is a Baize URL the managed server can reach (with `http(s)://`), the registration token hasn't expired, and the Agent is installed on the host rather than inside a container. See [Troubleshooting](docs/en/troubleshooting.md).
</details>

<details>
<summary><b>How do I roll back a failed upgrade?</b></summary>

A failed upgrade enters a recovery wizard where you can restore the pre-upgrade database and config or roll back to the previous version; or run `bash scripts/restore-backup.sh --latest --yes --require-db` manually. See [Upgrade](docs/en/upgrade.md).
</details>

<details>
<summary><b>Database volume is corrupted — now what?</b></summary>

Rebuild from the latest backup: `bash scripts/restore-backup.sh --latest --yes --require-db --reset-volumes --i-understand-data-loss` (destructive; use only when sure). See [Backup & Restore](docs/en/backup-and-restore.md).
</details>

<details>
<summary><b>Forgot the password / security code?</b></summary>

The initial admin password is in `ADMIN_PASSWORD` in `.env`, and the security code is in `BAIZE_HOST_PROFILE_SECURITY_CODE`. If you changed them and forgot the current value, reset them from the installation directory; see [Admin Password & Security Code Reset](docs/en/credential-reset.md).
</details>

## Community & Support

- **Website**: <https://baize.run/>
- **Community (Discord)**: <https://discord.gg/UMR7mnZFqh> — share deployment experience, usage questions, and product feedback
- **Issues**: [GitHub Issues](https://github.com/ysfl/baize/issues)
- **Email support**: <support@baize.run>
- **Trials, deployment assistance, or commercial support**: scan to contact

  <img src="assets/contact-qr.png" alt="Baize contact QR" width="200">

## Licensing & Use

Baize is closed-source commercial software. This repository is the public deployment entry point only: you may deploy, run, and maintain your own Baize instance under the copyright and use terms in [LICENSE](LICENSE). The central server, node Agent, console, container images, and release artifacts are governed by separate commercial authorization terms.
