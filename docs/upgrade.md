# 升级

[返回 README](../README.md)

## 要不要升级?

白泽控制台右上角会在有新版本时提示。升级前先想清楚三件事:

1. **先备份。** 升级会自动备份,但数据结构变更**不会自动回退**,出问题只能从备份显式恢复。详见[备份与恢复](backup-and-restore.md)。
2. **版本是否在用。** 只在当前正在使用的安装目录中执行升级,避免旧目录和当前服务同时占用数据库端口。
3. **保留部署配置。** 升级会保留 `.env` 中的部署形态(如 `BAIZE_STACK_MODE`),不会重置你的安装目录。

## 查看版本

```bash
bash scripts/version.sh                 # 查看当前版本
bash scripts/version.sh --check-remote  # 对比远端最新版本
bash scripts/version.sh --verbose       # 排查时查看本地来源与构建详情
```

`scripts/version.sh` 默认显示当前安装版本、Release tag、镜像、部署模式和容器状态。需要排查发布来源时,再追加 `--verbose` 查看本地 Git 与构建详情。

## 执行升级

```bash
bash scripts/upgrade.sh
```

升级脚本会自动备份 `.env`、版本文件、Compose 配置和数据库,再拉取目标版本并完成部署与检查;失败时会进入处理向导。你可以在向导中:

- 查看最近日志
- 恢复升级前数据库和配置
- 恢复后重新执行本次升级
- 仅切回升级前版本
- 在数据库已经损坏时删除数据卷后从备份重建

## 升级会保留什么

升级会保留 `.env` 中的 `BAIZE_STACK_MODE`:

- 当前是 `server-only` 时,升级后仍然只启动中心服务。
- 当前是 `full` 时,升级后继续启动控制台。

## 数据结构与回退

所需数据结构更新会在中心服务首次启动和升级时自动完成。**升级前务必备份数据库**——数据结构不会自动回退,需要时通过备份显式恢复:

```bash
bash scripts/restore-backup.sh --backup-dir ~/.baize/backups/baize-<实例>/<备份> --yes
bash scripts/restore-backup.sh --latest --yes --require-db
```

如果当前数据库数据卷已经无法正常启动,可以选择从备份重建数据卷:

```bash
bash scripts/restore-backup.sh --latest --yes --require-db \
  --reset-volumes --i-understand-data-loss
```

`--reset-volumes` 会删除当前 PostgreSQL / Redis 数据卷,只应在你确认需要用备份重建时使用。

## 相关文档

- [备份与恢复](backup-and-restore.md)
- [部署模式与访问地址](deployment.md)
- [故障排查](troubleshooting.md)
