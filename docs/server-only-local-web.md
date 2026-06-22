# 本地控制台接入

[返回 README](../README.md)

本文适用于这样的部署方式：服务器上只运行白泽中心服务、PostgreSQL 和 Redis，不启动公开仓自带的控制台容器；控制台在你的电脑或另一台机器上独立运行，再连接到这台中心服务。

如果你只是想把白泽完整跑起来，请优先使用 README 的「5 分钟快速开始」。本页适合已经获得可独立运行的控制台工程或构建产物，并希望把服务端和控制台分开部署的场景。

## 方案概览

| 位置 | 运行内容 | 访问地址 |
| --- | --- | --- |
| Linux 服务器 | 中心服务、PostgreSQL、Redis | `http://<你的服务器IP或域名>:22501` |
| 本地电脑 / 独立机器 | 控制台 | `http://127.0.0.1:8088` 或你的控制台地址 |
| 被纳管服务器 | 节点 Agent | 连接 `http://<你的服务器IP或域名>:22501` |

## 1. 在服务器只部署中心服务

在 Linux 服务器上执行：

```bash
git clone https://github.com/ysfl/baize.git
cd baize
bash scripts/install.sh --yes \
  --public-url http://<你的服务器IP或域名>:22501 \
  --stack-mode server-only \
  --deploy-mode image \
  --server-public-port 22501
```

`--public-url` 是节点 Agent 和独立控制台要访问的中心服务地址，必须使用这台服务器真实可达的 IP 或域名。

安装完成后确认：

```bash
bash scripts/check-install.sh --offline
```

`server-only` 模式不会启动控制台容器，也不会占用控制台端口。

## 2. 选择本地控制台连接方式

### 推荐：本地代理模式

本地控制台仍然请求 `/api/v1` 和 `/ws`，由本地开发服务代理到远端中心服务。这样浏览器看到的是同源请求，通常不需要额外处理跨域。

在本地控制台工程的开发环境配置中写入：

```env
VITE_GLOB_API_URL=/api/v1
VITE_DEV_PROXY_API_TARGET=http://<你的服务器IP或域名>:22501
VITE_DEV_PROXY_WS_TARGET=ws://<你的服务器IP或域名>:22501
```

然后启动控制台：

```bash
pnpm dev:baize
```

打开本地控制台地址，通常是：

```text
http://127.0.0.1:8088
```

如果你的中心服务使用 HTTPS，把代理地址改成对应协议：

```env
VITE_DEV_PROXY_API_TARGET=https://<你的域名或IP>:22501
VITE_DEV_PROXY_WS_TARGET=wss://<你的域名或IP>:22501
```

### 备选：浏览器直连中心服务

如果你希望本地控制台直接请求远端中心服务，请在本地控制台工程中写入完整服务地址：

```env
VITE_GLOB_API_URL=http://<你的服务器IP或域名>:22501/api/v1
```

同时在服务器公开仓的 `.env` 中确认允许本地控制台来源：

```env
CORS_ALLOW_ORIGINS=http://127.0.0.1:8088,http://localhost:8088
```

如果你的本地控制台不是 `8088` 端口，请把上面的端口改成实际端口。修改服务器 `.env` 后重启中心服务：

```bash
bash scripts/deploy-server.sh --skip-build
bash scripts/check-install.sh --offline
```

## 3. 接入节点 Agent

节点 Agent 仍然连接中心服务地址，不连接本地控制台地址：

```bash
bash scripts/install-agent.sh \
  --server http://<你的服务器IP或域名>:22501 \
  --token <注册令牌>
```

`--server` 不要填写 `/api/v1` 后缀，也不要填写 `http://127.0.0.1:8088` 这类本地控制台地址。

## 4. 生产建议

- 生产环境建议使用域名和 HTTPS，例如 `https://<你的域名或IP>`。
- 如果采用浏览器直连模式，`CORS_ALLOW_ORIGINS` 只填写实际控制台来源，不要使用 `*`。
- 服务器防火墙需要放行中心服务端口，默认是 `22501`。
- 如果之后要改回完整部署，把 `.env` 中的 `BAIZE_STACK_MODE` 改为 `full`，确认控制台端口可用后执行 `bash scripts/deploy-server.sh --skip-build`。

## 5. 快速排查

| 现象 | 处理 |
| --- | --- |
| 本地控制台提示请求失败 | 确认本机能访问 `http://<你的服务器IP或域名>:22501/install.sh`。 |
| 浏览器直连时报跨域错误 | 把本地控制台完整来源加入服务器 `.env` 的 `CORS_ALLOW_ORIGINS`，然后重启中心服务。 |
| WebSocket 或终端连接失败 | 代理模式下确认 `VITE_DEV_PROXY_WS_TARGET` 使用 `ws://` 或 `wss://`，并指向中心服务根地址。 |
| Agent 无法上线 | 确认 Agent 的 `--server` 是中心服务根地址，令牌未过期，服务器端口可从被纳管机器访问。 |
