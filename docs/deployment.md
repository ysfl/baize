# 部署模式与访问地址

[返回 README](../README.md)

本文覆盖快速开始之外的部署选项:如何选择要启动的服务、镜像从哪里来、控制台与服务地址如何配置。如果你只是想先把白泽跑起来,请先看 README 的「5 分钟快速开始」。

## 两个相互独立的部署选择

白泽的部署由两个互不影响的开关决定:

- `--stack-mode` 决定**启动哪些服务**。
- `--deploy-mode` 决定**镜像从哪里来**。

### `--stack-mode`(启动哪些服务)

- `full`(默认):部署 PostgreSQL、Redis、中心服务和控制台。
- `server-only`:只部署 PostgreSQL、Redis 和中心服务,不启动控制台容器。适合使用独立控制台、只需要服务接口,或控制台由其它环境提供的场景。

### `--deploy-mode`(镜像从哪里来)

- `image`(生产推荐):从镜像仓库拉取中心服务与控制台镜像直接运行。
- `build`:把 Release 中下载的公开发布包放入对应 `dist` 目录后在本地构建镜像。
- `auto`(默认):检测到完整本地产物就用 `build`,否则用 `image`。

## 无人值守安装示例

完整部署:

```bash
bash scripts/install.sh --yes \
  --public-url http://<你的服务器IP或域名>:22501 \
  --web-api-base-url /api/v1 \
  --stack-mode full \
  --deploy-mode image \
  --server-image ghcr.io/ysfl/baize-server:0.1.39 \
  --web-image ghcr.io/ysfl/baize-web:0.1.38 \
  --server-public-port 22501 \
  --web-public-port 8088
```

只部署中心服务:

```bash
bash scripts/install.sh --yes \
  --public-url http://<你的服务器IP或域名>:22501 \
  --stack-mode server-only \
  --deploy-mode image \
  --server-image ghcr.io/ysfl/baize-server:0.1.39 \
  --server-public-port 22501
```

`server-only` 不会占用控制台端口,也不会拉起控制台容器。之后如需改回完整部署,修改 `.env` 中的 `BAIZE_STACK_MODE=full`,确认控制台端口可用后重新执行:

```bash
bash scripts/deploy-server.sh --skip-build
```

## 访问地址配置

`.env` 中有两类地址,分别服务于不同的访问者:

- `AGENT_PUBLIC_SERVER_URL`:被纳管服务器访问白泽的地址,必须以 `http://` 或 `https://` 开头。
- `WEB_API_BASE_URL`:浏览器打开控制台后访问白泽服务的地址。

### 推荐:同域反向代理

浏览器不会遇到跨域问题:

```env
WEB_API_BASE_URL=/api/v1
```

此时控制台容器会把 `/api/`、`/ws`、`/install.sh`、`/install.ps1`、`/download/` 反代到中心服务。

### 控制台与服务地址分离部署

```env
WEB_API_BASE_URL=https://<你的服务域名>/api/v1
CORS_ALLOW_ORIGINS=https://<你的控制台域名>
```

修改 `.env` 后重启:

```bash
bash scripts/deploy-server.sh --skip-build
```

`server-only` 模式下不会启动控制台容器,`WEB_API_BASE_URL` 只在你重新启用控制台容器时生效。

## 默认端口

| 服务 | 默认端口 |
| --- | --- |
| 控制台 Web | `8088` |
| 中心服务 API | `22501`(容器内 `8080`) |
| PostgreSQL | `15432` |
| Redis | `16379` |

## 仓库内容

```text
docker-compose.yml          镜像部署编排
docker-compose.build.yml    本地产物构建镜像的覆盖编排
scripts/                    安装、检查、备份、升级、恢复脚本
releases/latest.json        控制台版本检测使用的最新版本清单
releases/changelog.json     控制台版本页展示的更新日志
server/ agent/ web/ 的 dist/  可选本地发布包目录,默认仅保留 .gitkeep
```

## 相关文档

- [本地控制台接入](server-only-local-web.md)
- [升级](upgrade.md)
- [备份与恢复](backup-and-restore.md)
- [高级配置与运维](advanced.md)
- [故障排查](troubleshooting.md)
