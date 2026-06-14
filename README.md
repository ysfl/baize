# 白泽 Baize

中文 | [English](README.en.md)

白泽（Baize）是一款自部署的服务器管控平台。在一台服务器上启动白泽，再为每台需要纳管的服务器装上轻量 Agent，你就能在一个控制台里完成资产纳管、实时监控、安全防护、远程运维和操作审计。

- **资产纳管**：集中查看所有服务器的在线状态、配置与负载。
- **实时监控**：CPU、内存、磁盘、网络、进程、服务的实时指标与告警。
- **安全防护**：登录风控、WAF 联防、证书与防火墙状态统一观测。
- **远程运维**：远程命令、文件分发、定时任务、服务管理与网页终端。
- **操作审计**：关键操作留痕，事后可追溯。

数据全程留在你自己的服务器上，白泽不依赖外部托管。

本仓库是白泽的**公开部署入口**，提供 Docker Compose 编排、安装与升级脚本、备份恢复工具和版本清单。白泽中心服务、节点 Agent 与控制台以容器镜像和公开发布包形式分发，请从镜像仓库或 GitHub Releases 获取。

## 快速开始

准备一台 Linux 服务器（2 vCPU / 4 GB 内存 / 20 GB 磁盘起步），安装好 Docker，然后：

```bash
git clone https://github.com/ysfl/baize.git
cd baize
bash scripts/install.sh
```

安装脚本会引导你完成配置，自动生成强随机的数据库密码、Redis 密码、JWT 密钥、管理员初始密码、凭据主密钥和高敏操作安全码，并拉起全部容器。

安装完成后的默认访问地址：

```text
控制台:   http://<服务器IP>:8088
服务地址: http://<服务器IP>:22501/api/v1
```

管理员初始账号为 `admin`，初始密码写在自动生成的 `.env` 文件的 `ADMIN_PASSWORD` 中。主机画像刷新、命令历史明文查看等高敏操作使用独立安全码，初始值写在 `.env` 的 `BAIZE_HOST_PROFILE_SECURITY_CODE` 中。**首次登录后请立即修改密码**，并妥善保管 `.env`，不要提交到 Git。

### 纳管一台服务器

在控制台创建注册令牌后，到目标服务器上执行：

```bash
bash scripts/install-agent.sh \
  --server https://baize.example.com \
  --token <注册令牌>
```

Agent 建议直接安装在被纳管服务器的宿主机上，以便读取进程、磁盘、Docker、防火墙等宿主机状态；不建议在生产环境放进容器。

## 部署模式

支持三种模式，安装时通过 `--deploy-mode` 选择：

- `image`（生产推荐）：从镜像仓库拉取中心服务与控制台镜像直接运行。
- `build`：把 Release 中下载的公开发布包放入对应 `dist` 目录后在本地构建镜像。
- `auto`（默认）：检测到完整本地产物就用 `build`，否则用 `image`。

无人值守安装示例：

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

## 访问地址配置

`.env` 中有两类地址，分别服务于不同的访问者：

- `AGENT_PUBLIC_SERVER_URL`：被纳管服务器访问白泽的地址，必须以 `http://` 或 `https://` 开头。
- `WEB_API_BASE_URL`：浏览器打开控制台后访问白泽服务的地址。

推荐同域反向代理，浏览器不会遇到跨域问题：

```env
WEB_API_BASE_URL=/api/v1
```

此时控制台容器会把 `/api/`、`/ws`、`/install.sh`、`/install.ps1`、`/download/` 反代到中心服务。

控制台与服务地址分离部署时：

```env
WEB_API_BASE_URL=https://api.example.com/api/v1
CORS_ALLOW_ORIGINS=https://console.example.com
```

修改 `.env` 后重启：

```bash
bash scripts/deploy-server.sh --skip-build
```

## 升级

白泽控制台右上角会提示新版本。命令行升级：

```bash
bash scripts/version.sh                 # 查看当前版本
bash scripts/version.sh --check-remote  # 对比远端最新版本
bash scripts/version.sh --verbose       # 排查时查看本地来源与构建详情
bash scripts/upgrade.sh                 # 执行升级
```

`scripts/version.sh` 默认显示当前安装版本、Release tag、镜像、部署模式和容器状态。需要排查发布来源时，再追加 `--verbose` 查看本地 Git 与构建详情。

升级脚本会自动备份 `.env`、版本文件、Compose 配置和数据库，再拉取目标版本并完成部署与检查；失败时尝试回滚到升级前版本。

所需数据结构更新会在中心服务首次启动和升级时自动完成。**升级前务必备份数据库**——数据结构不会自动回退，需要时通过备份显式恢复：

```bash
bash scripts/restore-backup.sh --backup-dir ~/.baize/backups/baize-<实例>/<备份> --yes
```

## 备份

```bash
bash scripts/backup.sh --yes                          # 立即备份
bash scripts/install-backup-cron.sh --yes             # 安装每日 03:00 定时备份，默认保留 14 天
bash scripts/cleanup-backups.sh --dry-run --keep-days 30   # 预览清理
```

备份默认存放在仓库外部的 `~/.baize/backups/baize-<实例哈希>`。

## 安装检查

```bash
bash scripts/check-install.sh --offline   # 静态检查
bash scripts/check-install.sh             # 运行中检查
```

## 高级配置与运维

以下内容面向需要精细控制部署的管理员。

### 配置安全

生产 `.env` 应由安装脚本生成，或由你自行填写强随机值。以下配置不能为空，也不能使用固定默认值：

`POSTGRES_PASSWORD`、`DB_PASSWORD`、`REDIS_PASSWORD`、`JWT_SECRET`、`ADMIN_PASSWORD`、`CREDENTIAL_MASTER_KEY`、`BAIZE_HOST_PROFILE_SECURITY_CODE` 或 `BAIZE_HOST_PROFILE_SECURITY_CODE_HASH`、`AGENT_PUBLIC_SERVER_URL`。

`BAIZE_HOST_PROFILE_SECURITY_CODE` 是主机画像刷新和命令历史明文查看的二次校验码，不复用登录密码。生产环境可以改用 `BAIZE_HOST_PROFILE_SECURITY_CODE_HASH` 保存哈希值，并清空明文安全码。

使用 Docker 托管的 PostgreSQL 时，`DB_PASSWORD` 必须等于 `POSTGRES_PASSWORD`；使用外部数据库时，需同步修改 `DB_HOST`、`DB_PORT`、`DB_USER`、`DB_PASSWORD`、`DB_NAME`、`DB_SSLMODE`。

生产环境建议为控制台配置域名访问策略，减少 IP 直连、未知 Host 或误解析域名进入 Web 控制台：

```env
BAIZE_WEB_DOMAIN=console.example.com
BAIZE_WEB_ALLOWED_HOSTS=console.example.com,www.example.com
```

`BAIZE_WEB_DOMAIN` 适合只有一个控制台域名的部署；`BAIZE_WEB_ALLOWED_HOSTS` 可配置多个允许访问的域名，使用英文逗号分隔。配置后，Web 入口会拒绝不在列表内的 Host。未配置时保持兼容模式，适合首次安装或只在内网临时访问的环境。

### 控制台触发升级（默认关闭）

默认部署只在控制台提示升级，不会让容器执行宿主机命令。需要在控制台点击触发升级时，才显式开启：

```env
BAIZE_UPGRADE_RUNNER_ENABLED=true
BAIZE_UPGRADE_MODE=docker-updater
BAIZE_DOCKER_UPGRADE_COMMAND=cd /path/to/baize && BAIZE_DEPLOY_MODE=image bash scripts/upgrade.sh --mode docker-updater --yes
```

不要仅为获得宿主机控制权而在普通容器里挂载 Docker Socket。生产环境更推荐在受控运维主机或宿主机直跑中心服务的模式中启用升级执行器。

### 重新初始化（破坏性）

升级流程默认拒绝 `--force-config`，因为它会覆盖 `.env` 并重新生成全部密钥，可能导致旧数据库、登录令牌、Agent 通信和加密凭据全部失效。确实需要重新初始化时，使用专门入口：

```bash
# 只重新生成 .env，不启动或重置容器
bash scripts/reinit-config.sh --config-only --i-understand-reinit

# 备份后删除当前数据库 / Redis volume，并部署全新栈
bash scripts/reinit-config.sh --reset-stack \
  --i-understand-reinit \
  --i-understand-data-loss
```

`--reset-stack` 会清空数据。只有明确接受数据丢失风险时，才允许追加 `--skip-backup --yes --i-understand-no-backup`。

## 仓库内容

```text
docker-compose.yml          镜像部署编排
docker-compose.build.yml    本地产物构建镜像的覆盖编排
scripts/                    安装、检查、备份、升级、恢复脚本
releases/latest.json        控制台版本检测使用的最新版本清单
releases/changelog.json     控制台版本页展示的更新日志
server/ agent/ web/ 的 dist/  可选本地发布包目录，默认仅保留 .gitkeep
```

## 联系支持

如需试用、部署协助或商业支持，请扫码联系：

<img src="assets/contact-qr.png" alt="白泽联系二维码" width="240">
