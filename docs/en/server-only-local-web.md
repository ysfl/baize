# Local Console Connection

[Back to README](../../README.en.md)

Use this guide when your Linux server runs only the Baize central server, PostgreSQL, and Redis, while the console runs independently on your computer or another host and connects back to that central server.

If you only want a complete Baize deployment, start with the README "Quick Start" instead. This page is for users who already have an independently runnable console project or build artifact and want to deploy the service and console separately.

## Overview

| Location | Runs | URL |
| --- | --- | --- |
| Linux server | Central server, PostgreSQL, Redis | `http://<your-server-ip-or-domain>:22501` |
| Local computer / separate host | Console | `http://127.0.0.1:8088` or your console URL |
| Managed servers | Node Agent | Connects to `http://<your-server-ip-or-domain>:22501` |

## 1. Deploy Only the Central Server

Run on your Linux server:

```bash
git clone https://github.com/ysfl/baize.git
cd baize
bash scripts/install.sh --yes \
  --public-url http://<your-server-ip-or-domain>:22501 \
  --stack-mode server-only \
  --deploy-mode image \
  --server-public-port 22501
```

`--public-url` is the central server URL that node Agents and the standalone console must reach. Use the real reachable IP address or domain of this server.

After installation, check the configuration:

```bash
bash scripts/check-install.sh --offline
```

`server-only` mode does not start the console container and does not occupy the console port.

## 2. Choose a Local Console Connection Mode

### Recommended: Local Proxy Mode

The local console still requests `/api/v1` and `/ws`; your local development server proxies them to the remote central server. The browser sees same-origin requests, so this usually avoids extra cross-origin setup.

In the local console project's development environment config, set:

```env
VITE_GLOB_API_URL=/api/v1
VITE_DEV_PROXY_API_TARGET=http://<your-server-ip-or-domain>:22501
VITE_DEV_PROXY_WS_TARGET=ws://<your-server-ip-or-domain>:22501
```

Then start the console:

```bash
pnpm dev:baize
```

Open the local console URL, usually:

```text
http://127.0.0.1:8088
```

If your central server uses HTTPS, use the matching protocols:

```env
VITE_DEV_PROXY_API_TARGET=https://<your-domain-or-ip>:22501
VITE_DEV_PROXY_WS_TARGET=wss://<your-domain-or-ip>:22501
```

### Alternative: Browser Direct Connection

If you want the local console to call the remote central server directly, set a full service URL in the local console project:

```env
VITE_GLOB_API_URL=http://<your-server-ip-or-domain>:22501/api/v1
```

On the server-side public deployment repo, make sure `.env` allows the local console origin:

```env
CORS_ALLOW_ORIGINS=http://127.0.0.1:8088,http://localhost:8088
```

If your local console does not use port `8088`, replace the port with the actual one. After editing the server `.env`, restart the central server:

```bash
bash scripts/deploy-server.sh --skip-build
bash scripts/check-install.sh --offline
```

## 3. Onboard Node Agents

Node Agents still connect to the central server URL, not the local console URL:

```bash
bash scripts/install-agent.sh \
  --server http://<your-server-ip-or-domain>:22501 \
  --token <registration-token>
```

Do not append `/api/v1` to `--server`, and do not use a local console URL such as `http://127.0.0.1:8088`.

## 4. Production Recommendations

- Use a domain and HTTPS in production, for example `https://<your-domain-or-ip>`.
- In browser direct mode, set `CORS_ALLOW_ORIGINS` only to your real console origins. Do not use `*`.
- Allow the central server port through the server firewall. The default is `22501`.
- To switch back to full deployment later, set `BAIZE_STACK_MODE=full` in `.env`, make sure the console port is free, then run `bash scripts/deploy-server.sh --skip-build`.

## 5. Quick Troubleshooting

| Symptom | What to check |
| --- | --- |
| Local console requests fail | Make sure your computer can open `http://<your-server-ip-or-domain>:22501/install.sh`. |
| Browser direct mode reports a cross-origin error | Add the full local console origin to `CORS_ALLOW_ORIGINS` in the server `.env`, then restart the central server. |
| WebSocket or terminal connection fails | In proxy mode, make sure `VITE_DEV_PROXY_WS_TARGET` uses `ws://` or `wss://` and points to the central server root URL. |
| Agent does not come online | Make sure Agent `--server` is the central server root URL, the token is still valid, and the central server port is reachable from the managed server. |
