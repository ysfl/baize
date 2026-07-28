# 部署模式与访问地址

[返回 README](../README.md)

本文覆盖快速开始之外的部署选项:如何选择要启动的服务、镜像从哪里来、控制台与服务地址如何配置。如果你只是想先把白泽跑起来,请先看 README 的「5 分钟快速开始」。

## 两个相互独立的部署选择

白泽的部署由两个互不影响的开关决定:

- `--stack-mode` 决定**启动哪些服务**。
- `--image-source` 决定**从哪个公开地址下载**。

### `--stack-mode`(启动哪些服务)

- `full`(默认):部署 PostgreSQL、Redis、中心服务和控制台。
- `server-only`:只部署 PostgreSQL、Redis 和中心服务,不启动控制台容器。适合使用独立控制台、只需要服务接口,或控制台由其它环境提供的场景。

### `--image-source`(从哪里下载)

- `acr`(中国大陆推荐):中心服务和控制台从阿里云镜像仓库下载,TimescaleDB 和 Redis 使用国内镜像加速地址,版本信息从 Gitee 获取。
- `github`:中心服务和控制台从 GHCR 下载,TimescaleDB 和 Redis 从 Docker Hub 下载,版本信息从 GitHub 获取。

中文交互安装会提示选择并默认推荐 `acr`;无人值守安装可显式传入 `--image-source acr`。这些公开镜像都可以匿名下载,不需要配置仓库账号。

首次安装时,脚本会按宿主机架构生成配置,检查 Docker 守护进程和端口,并尝试自动准备离线 GeoIP 数据库。GeoIP 下载失败不会阻断中心服务安装,但地区字段会暂时为空;需要严格要求数据库时追加 `--require-geoip`,不需要时可追加 `--skip-geoip`。

## 无人值守安装示例

完整部署:

```bash
bash scripts/install.sh --yes \
  --image-source acr \
  --stack-mode full \
  --server-public-port 22501 \
  --web-public-port 8088 \
  --public-url http://<你的服务器IP或域名>:22501 \
  --web-api-base-url /api/v1 \
  --skip-server-host-agent
```

只部署中心服务:

```bash
bash scripts/install.sh --yes \
  --image-source acr \
  --stack-mode server-only \
  --server-public-port 22501 \
  --public-url http://<你的服务器IP或域名>:22501 \
  --skip-server-host-agent
```

`server-only` 不会占用控制台端口,也不会拉起控制台容器。之后如需改回完整部署,修改 `.env` 中的 `BAIZE_STACK_MODE=full`,确认控制台端口可用后重新执行:

```bash
bash scripts/deploy-server.sh
```

## 访问地址配置

`.env` 中有两类地址,分别服务于不同的访问者:

- `AGENT_PUBLIC_SERVER_URL`:被纳管服务器访问白泽的地址,必须以 `http://` 或 `https://` 开头。
- `WEB_API_BASE_URL`:浏览器打开控制台后访问白泽服务的地址。

### 本机执行器地址

部署脚本会在中心服务启动成功后,尝试在当前宿主机安装一个本机执行器。它用于后续承接升级、备份、迁移等需要访问宿主机的操作,不会放进 Docker 容器里运行。

本机执行器默认连接:

```env
http://127.0.0.1:${SERVER_PUBLIC_PORT}
```

这条地址只给当前宿主机使用,不受 `AGENT_PUBLIC_SERVER_URL` 影响。这样即使你先用服务器 IP 完成部署、稍后再解析域名,本机执行器也不会因为外部访问地址变化而掉线。

可选配置:

```env
BAIZE_SERVER_HOST_AGENT_ENABLED=true
BAIZE_SERVER_HOST_AGENT_INTERNAL_URL=
```

- `BAIZE_SERVER_HOST_AGENT_ENABLED=false`:跳过自动安装,适合宿主机已安装 Agent 或不希望部署脚本申请 sudo 的场景。
- `BAIZE_SERVER_HOST_AGENT_INTERNAL_URL`:仅在端口映射或本机访问方式特殊时填写;常规部署保持空值。

公开安装入口默认会尝试安装本机执行器,但只有当前用户是 root、具备免密 sudo,或明确传入 `--install-server-host-agent` 且存在可交互终端时才会执行需要主机权限的动作。没有 systemd/launchd 或权限不足时,脚本会跳过并给出手动安装提示,不会判定容器部署失败。只需要 Docker 服务时,推荐在无人值守命令中加入 `--skip-server-host-agent`。

### 中断、失败与重试

安装过程中按 `Ctrl-C` 或遇到异常时,脚本不会自动删除 `.env`、容器或数据卷,并会输出失败阶段、容器状态、最近日志和重试命令。确认 Docker 已恢复后,直接在安装目录重新执行:

```bash
bash scripts/install.sh --yes
```

如需先查看现场:

```bash
bash scripts/check-install.sh --allow-missing-geoip
docker compose ps -a
docker compose logs --tail=120 server
```

除非明确接受数据丢失,不要在排障时使用 `docker compose down --volumes`。

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
bash scripts/deploy-server.sh
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
scripts/                    安装、检查、备份、升级、恢复脚本
releases/latest.json        控制台版本检测使用的最新版本清单
releases/changelog.json     控制台版本页展示的更新日志
```

## 相关文档

- [本地控制台接入](server-only-local-web.md)
- [升级](upgrade.md)
- [备份与恢复](backup-and-restore.md)
- [卸载与清理](uninstall.md)
- [高级配置与运维](advanced.md)
- [故障排查](troubleshooting.md)
