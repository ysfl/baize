# 故障排查

[返回 README](../README.md)

遇到问题时,先跑一次安装检查,它会给出大多数问题的方向:

```bash
bash scripts/check-install.sh             # 运行中检查
bash scripts/check-install.sh --offline   # 未启动时的静态检查
bash scripts/version.sh --verbose         # 查看版本、镜像、部署模式与容器状态
```

## 装完后控制台打不开

- 确认控制台容器已启动:`bash scripts/check-install.sh`。
- 确认访问的是控制台端口(默认 `8088`),而不是服务端口(默认 `22501`)。
- 若用 `server-only` 模式安装,**不会启动控制台容器**,这是预期行为。需要控制台请改回 `full`,见[部署模式](deployment.md)。
- 配置了域名访问策略(`BAIZE_WEB_DOMAIN` / `BAIZE_WEB_ALLOWED_HOSTS`)时,用 IP 直连或未列入的域名会被拒绝。临时排查可清空这两项,见[高级配置](advanced.md#域名访问策略)。

## Agent 连不上中心服务

- 确认 `install-agent.sh` 的 `--server` 填的是被纳管服务器**能访问到**的白泽地址,且以 `http://` / `https://` 开头。安装器不会内置任何默认控制端。
- 确认注册令牌未过期,必要时在控制台重新生成。
- 确认 `.env` 中 `AGENT_PUBLIC_SERVER_URL` 与实际对外地址一致。
- Agent 建议直接装在被纳管服务器的宿主机上(不要放进容器),否则读不到进程、磁盘、Docker、防火墙等宿主机状态。

## 升级失败怎么回滚

升级脚本失败时会进入处理向导,可直接在向导中恢复升级前的数据库与配置、切回升级前版本,或恢复后重试。详见[升级](upgrade.md)。

手动回滚数据库:

```bash
bash scripts/restore-backup.sh --latest --yes --require-db
```

## 数据库数据卷损坏,服务起不来

从最近一次备份重建数据卷(会删除当前 PostgreSQL / Redis 数据卷):

```bash
bash scripts/restore-backup.sh --latest --yes --require-db \
  --reset-volumes --i-understand-data-loss
```

`--reset-volumes` 具有破坏性,只应在确认需要用备份重建时使用。完整流程见[备份与恢复](backup-and-restore.md)。

## 忘记管理员密码 / 安全码

- 管理员初始密码写在 `.env` 的 `ADMIN_PASSWORD`,高敏操作安全码写在 `BAIZE_HOST_PROFILE_SECURITY_CODE`。
- 如果已经修改且忘记当前值,在安装目录执行重置脚本。管理员密码、高敏操作安全码和账号锁定处理见[管理员密码与安全码重置](credential-reset.md)。

## 端口冲突 / 旧目录占用数据库

- 只在当前正在使用的安装目录中执行升级或部署,**避免旧目录和当前服务同时占用数据库端口**。
- 默认端口:控制台 `8088`、服务 `22501`、PostgreSQL `15432`、Redis `16379`。冲突时在 `.env` 调整对应 `*_PUBLIC_PORT`。

## 服务器地区一直显示“待定”

地区信息依赖安装目录下的离线 GeoIP 数据库。若服务器列表、概览或档案页能正常打开,但国家、城市或坐标一直为空,先在安装目录执行:

```bash
bash scripts/install-geoip-databases.sh
bash scripts/check-install.sh --offline
docker compose restart server
```

如果 `check-install.sh --offline` 仍提示缺少 GeoIP 数据,继续检查:

- `docker-compose.yml` 的 `server` 服务是否挂载了 `./runtime:/app/runtime:ro`。
- `.env` 中 `GEOIP_CITY_MMDB_PATH` 和 `GEOIP_ASN_MMDB_PATH` 是否仍指向 `/app/runtime/geoip/dbip-city-lite.mmdb` 与 `/app/runtime/geoip/dbip-asn-lite.mmdb`。
- `runtime/geoip/` 下是否存在 `dbip-city-lite.mmdb` 和 `dbip-asn-lite.mmdb`。

无法联网时,把同月份的 DB-IP Lite City / ASN 压缩包放入 `runtime/geoip/`,再执行:

```bash
GEOIP_OFFLINE_BACKFILL_ONLY=true bash scripts/install-geoip-databases.sh
bash scripts/check-install.sh --offline
docker compose restart server
```

完整说明见[高级配置](advanced.md#服务器地区识别)。

## 仍未解决

- 提交 Issue:<https://github.com/ysfl/baize/issues>
- 加入社区:<https://discord.gg/UMR7mnZFqh>
- 需要部署协助或商业支持,见 README 的「社区与支持」。

## 相关文档

- [升级](upgrade.md)
- [备份与恢复](backup-and-restore.md)
- [部署模式与访问地址](deployment.md)
- [高级配置与运维](advanced.md)
- [管理员密码与安全码重置](credential-reset.md)
