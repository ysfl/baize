# 备份与恢复

[返回 README](../README.md)

## 备份

```bash
bash scripts/backup.sh --yes                          # 立即备份
bash scripts/install-backup-cron.sh --yes             # 安装每日 03:00 定时备份,默认保留 14 天
bash scripts/cleanup-backups.sh --dry-run --keep-days 30   # 预览清理
```

备份默认存放在仓库外部的 `~/.baize/backups/baize-<实例哈希>`。

## 干净目录恢复

当现有安装目录已经混乱,或需要在干净目录中重装时,建议使用「先备份、再恢复」的方式,不要直接删除当前数据卷:

```bash
# 1. 在当前可用安装目录中创建备份
bash scripts/backup.sh --yes

# 2. 准备新的安装目录
git clone https://github.com/ysfl/baize.git baize-new
cd baize-new

# 3. 从备份恢复 .env 和数据库,并按备份中的部署形态启动服务
bash scripts/restore-backup.sh \
  --backup-dir ~/.baize/backups/baize-<实例>/<备份> \
  --yes --require-db --reset-volumes --i-understand-data-loss
```

恢复脚本会使用备份里的 `.env`,保留数据库密码、JWT 密钥、凭据主密钥和高敏操作安全码。**不要用新生成的 `.env` 直接导入旧数据库**,否则可能导致登录令牌、Agent 通信或加密凭据不可用。确认新目录可正常登录、Agent 可连接、备份可追溯后,再归档旧目录。

## 安装检查

```bash
bash scripts/check-install.sh --offline   # 静态检查
bash scripts/check-install.sh             # 运行中检查
```

## 相关文档

- [升级](upgrade.md)
- [部署模式与访问地址](deployment.md)
- [故障排查](troubleshooting.md)
