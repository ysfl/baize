# 高级配置与运维

[返回 README](../README.md)

以下内容面向需要精细控制部署的管理员。

## 配置安全

生产 `.env` 应由安装脚本生成,或由你自行填写强随机值。以下配置不能为空,也不能使用固定默认值:

`POSTGRES_PASSWORD`、`DB_PASSWORD`、`REDIS_PASSWORD`、`JWT_SECRET`、`ADMIN_PASSWORD`、`CREDENTIAL_MASTER_KEY`、`BAIZE_HOST_PROFILE_SECURITY_CODE` 或 `BAIZE_HOST_PROFILE_SECURITY_CODE_HASH`、`AGENT_PUBLIC_SERVER_URL`。

`BAIZE_HOST_PROFILE_SECURITY_CODE` 是主机画像刷新和命令历史明文查看的二次校验码,不复用登录密码。生产环境可以改用 `BAIZE_HOST_PROFILE_SECURITY_CODE_HASH` 保存哈希值,并清空明文安全码。

使用 Docker 托管的 PostgreSQL 时,`DB_PASSWORD` 必须等于 `POSTGRES_PASSWORD`;使用外部数据库时,需同步修改 `DB_HOST`、`DB_PORT`、`DB_USER`、`DB_PASSWORD`、`DB_NAME`、`DB_SSLMODE`。

脚本提示默认使用中文。需要英文提示时,可以在 `.env` 设置:

```env
BAIZE_LANG=en
```

## 域名访问策略

生产环境建议为控制台配置域名访问策略,减少 IP 直连、未知 Host 或误解析域名进入 Web 控制台:

```env
BAIZE_WEB_DOMAIN=<你的控制台域名>
BAIZE_WEB_ALLOWED_HOSTS=<你的控制台域名>,<你的备用域名>
```

`BAIZE_WEB_DOMAIN` 适合只有一个控制台域名的部署;`BAIZE_WEB_ALLOWED_HOSTS` 可配置多个允许访问的域名,使用英文逗号分隔。配置后,Web 入口会拒绝不在列表内的 Host。未配置时保持兼容模式,适合首次安装或只在内网临时访问的环境。

## 服务器地区识别

服务器列表、概览和档案页会根据公网 IP 展示地区信息。默认部署使用离线 GeoIP 数据库,这样中心服务不需要在页面访问时请求外部查询服务。安装器首次部署会自动尝试准备数据库;网络受限时仍会继续安装核心服务,地区字段在数据库补齐前保持为空。需要手动补齐或迁移部署目录时,在安装目录执行:

```bash
bash scripts/install-geoip-databases.sh
bash scripts/check-install.sh --offline
docker compose restart server
```

脚本会把 DB-IP Lite City 和 ASN 数据库放到 `runtime/geoip/`,并生成容器已配置好的稳定文件名:

```text
runtime/geoip/dbip-city-lite.mmdb
runtime/geoip/dbip-asn-lite.mmdb
```

如果 `GEOIP_OFFLINE_ONLY=true` 但这两个文件不存在,中心服务仍会正常返回服务器列表,只是地区字段不会显示。`bash scripts/check-install.sh --offline` 默认给出警告但继续其它检查;需要把 GeoIP 当成硬性要求时追加 `--require-geoip`。旧版本的 `--allow-missing-geoip` 仍可使用:

```bash
bash scripts/check-install.sh --offline --allow-missing-geoip
```

### 存量目录回填

如果你是从较早部署目录升级,服务器地区一直显示“待定”,按下面顺序回填:

1. 在当前安装目录确认 `docker-compose.yml` 中 `server` 服务已挂载 `./runtime:/app/runtime:ro`。没有该挂载时,先更新部署目录到最新公开版本,再保留原 `.env` 执行升级。
2. 执行 `bash scripts/install-geoip-databases.sh`。如果目录中已经有对应月份的 `.mmdb` 或 `.mmdb.gz`,脚本会直接复用本地文件并重建稳定文件名。
3. 执行 `bash scripts/check-install.sh --offline`,确认离线 GeoIP 数据已就绪。
4. 执行 `docker compose restart server`,让中心服务重新读取数据库。

无法联网的环境可以先把同月份的 DB-IP Lite City / ASN 压缩包放入 `runtime/geoip/`,再执行:

```bash
GEOIP_OFFLINE_BACKFILL_ONLY=true bash scripts/install-geoip-databases.sh
bash scripts/check-install.sh --offline
docker compose restart server
```

## 控制台单组件更新

镜像部署在使用 systemd 的 Linux 上安装 Server 本机执行器时,会同时安装固定更新组件。后续版本清单提供可信镜像摘要后,管理员可在“系统版本”页分别更新 Server 或 Web,无需向 Server 容器挂载 Docker Socket,也无需配置自定义宿主机命令。

更新链路只接受控制台选择的组件名。目标版本、镜像地址和 SHA-256 摘要由 Server 从可信发布清单读取,再交给唯一在线的本机执行器。宿主机固定 systemd 服务完成摘要锁定、单容器重建、健康检查和失败回滚;任务状态、日志尾部和结果保存在远程执行记录中。

可调整单次更新最长等待时间:

```env
BAIZE_IMAGE_UPGRADE_TIMEOUT_SEC=900
```

允许范围为 `60` 到 `3600` 秒。常规部署保留默认值即可。按钮不可用时,先按页面原因检查部署模式、本机执行器是否在线、是否只有一个 `server_host`、目标组件是否已经部署,以及最新清单是否包含镜像摘要。旧部署目录需要先使用完整升级流程更新公开脚本与 Compose 配置,再运行 `bash scripts/deploy-server.sh` 刷新本机执行器和固定更新组件。

控制台单组件更新不会更新部署目录、Compose 文件或 Agent。需要更新这些内容时使用 `bash scripts/upgrade.sh`;两种方式的边界和数据回退说明见[升级](upgrade.md)。

## 重新初始化(破坏性)

升级流程默认拒绝 `--force-config`,因为它会覆盖 `.env` 并重新生成全部密钥,可能导致旧数据库、登录令牌、Agent 通信和加密凭据全部失效。确实需要重新初始化时,使用专门入口:

```bash
# 只重新生成 .env,不启动或重置容器
bash scripts/reinit-config.sh --config-only --i-understand-reinit

# 备份后删除当前数据库 / Redis volume,并部署全新栈
bash scripts/reinit-config.sh --reset-stack \
  --i-understand-reinit \
  --i-understand-data-loss
```

`--reset-stack` 会清空数据。只有明确接受数据丢失风险时,才允许追加 `--skip-backup --yes --i-understand-no-backup`。

## 相关文档

- [部署模式与访问地址](deployment.md)
- [升级](upgrade.md)
- [备份与恢复](backup-and-restore.md)
- [管理员密码与安全码重置](credential-reset.md)
- [AI 远程任务使用指南](ai-remote-tasks.md)
- [故障排查](troubleshooting.md)
