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

服务器列表、概览和档案页会根据公网 IP 展示地区信息。默认部署使用离线 GeoIP 数据库,这样中心服务不需要在页面访问时请求外部查询服务。首次安装或迁移部署目录后,在安装目录执行:

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

如果 `GEOIP_OFFLINE_ONLY=true` 但这两个文件不存在,中心服务仍会正常返回服务器列表,只是地区字段不会显示。`bash scripts/check-install.sh --offline` 会检查这两个文件是否已经就绪。

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

## 控制台触发升级(默认关闭)

默认部署只在控制台提示升级,不会让容器执行宿主机命令。需要在控制台点击触发升级时,才显式开启:

```env
BAIZE_UPGRADE_RUNNER_ENABLED=true
BAIZE_UPGRADE_MODE=docker-updater
BAIZE_DOCKER_UPGRADE_COMMAND=cd /path/to/baize && BAIZE_DEPLOY_MODE=image bash scripts/upgrade.sh --mode docker-updater --yes
```

不要仅为获得宿主机控制权而在普通容器里挂载 Docker Socket。生产环境更推荐在受控运维主机或宿主机直跑中心服务的模式中启用升级执行器。

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
- [故障排查](troubleshooting.md)
