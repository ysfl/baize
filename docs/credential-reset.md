# 管理员密码与安全码重置

[返回 README](../README.md)

当你无法登录控制台，或忘记主机画像刷新、命令历史明文查看等高敏操作安全码时，可以在白泽安装目录中直接重置。重置只处理对应凭据，不会清空业务数据，也不会重新生成数据库、Redis、JWT、Agent 通信或凭据主密钥。

> ⚠️ 不要为了找回密码或安全码执行重新初始化。重新初始化会更换多项生产密钥，可能导致旧数据、登录态、Agent 通信或加密凭据不可用。

## 开始前

1. SSH 登录运行白泽的服务器。
2. 进入白泽公开部署仓目录，也就是存在 `.env`、`docker-compose.yml` 和 `scripts/` 的目录。
3. 确认 Docker Compose 可用：

```bash
docker compose version
```

如果你不确定当前目录是否正确，先运行：

```bash
bash scripts/check-install.sh --offline
```

## 重置管理员密码

适用于忘记 `admin` 密码、账号因失败登录被锁定、或无法进入控制台自行改密的情况。

交互式执行：

```bash
bash scripts/reset-admin-password.sh --username admin
```

脚本会要求输入两次新密码。完成后，用新密码登录控制台。

无人值守执行时，可以通过环境变量传入新密码：

```bash
BAIZE_NEW_ADMIN_PASSWORD='<新管理员密码>' \
  bash scripts/reset-admin-password.sh --username admin --yes
```

说明：

- 新密码至少 8 个字符，建议使用密码管理器生成强密码。
- 脚本只重置本地管理员账号，并清除失败登录锁定状态。
- `.env` 中的 `ADMIN_PASSWORD` 是首次安装时的初始值，重置后不会同步更新，不要再把它当作当前密码来源。
- 已登录会话可能会在过期前继续有效。若这是一次安全事件，需要让所有会话立即失效，请先备份并谨慎轮换 `JWT_SECRET`，随后重建中心服务；这会让所有用户重新登录。

## 重置高敏操作安全码

适用于忘记主机画像刷新、命令历史明文查看等高敏操作安全码的情况。安全码独立于登录密码，建议单独保存在密码管理器中。

交互式执行：

```bash
bash scripts/reset-security-code.sh
```

脚本会要求输入两次新安全码。完成后会在 `.env` 中保存安全码哈希、清空明文安全码，并重建中心服务使新安全码生效。

无人值守执行时，可以通过环境变量传入新安全码：

```bash
BAIZE_NEW_SECURITY_CODE='<至少24位新安全码>' \
  bash scripts/reset-security-code.sh --yes
```

说明：

- 新安全码至少 24 个字符，建议使用随机字符串。
- 重置后 `.env` 会使用 `BAIZE_HOST_PROFILE_SECURITY_CODE_HASH` 保存哈希值，`BAIZE_HOST_PROFILE_SECURITY_CODE` 会被清空。
- 如果你只想更新 `.env`，稍后手动重建中心服务，可以追加 `--no-restart`。
- 重建中心服务期间，控制台请求会有短暂中断；PostgreSQL、Redis 和业务数据不会被清空。

## 常见问题

**可以用 `scripts/reinit-config.sh` 找回密码吗？**

不建议。重新初始化的目标是生成一套全新的部署配置，不是凭据找回工具。忘记密码或安全码时，应优先使用本页脚本。

**为什么安全码重置后 `.env` 看不到明文？**

这是预期行为。重置脚本会只保存哈希，明文只在你输入时出现一次，请把新安全码保存到自己的密码管理器。

**没有找到可重置的管理员账号怎么办？**

确认 `--username` 填写的是本地账号，默认初始账号为 `admin`。如果你修改过管理员账号名，可以先检查 `.env` 中的 `ADMIN_USERNAME`，或联系支持协助排查。

## 相关文档

- [高级配置与运维](advanced.md)
- [故障排查](troubleshooting.md)
- [备份与恢复](backup-and-restore.md)
