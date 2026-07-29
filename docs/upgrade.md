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

## 选择升级方式

### 只更新 Server 或 Web 镜像

支持该能力的版本正式发布后,可在控制台“系统版本”页分别选择 Server 或 Web。适合只发布了其中一个镜像、且当前部署目录和 Compose 配置不需要变化的情况。

控制台会根据现场状态决定按钮是否可用。自动更新要求:

- 当前使用 `BAIZE_DEPLOY_MODE=image` 镜像部署。
- Server 所在宿主机是使用 systemd 的 Linux,并且本机执行器在线且已安装固定更新组件。
- 现场只有一个在线的 Server 本机执行器。
- 最新版本清单包含目标镜像的可信 SHA-256 摘要。
- 更新 Web 时必须是 `BAIZE_STACK_MODE=full`;`server-only` 只能更新 Server。
- 同一时间没有其它 Server 或 Web 更新任务。

点击后,Server 只创建结构化任务,由宿主机本机执行器完成镜像拉取、摘要校验、单容器重建和健康检查。失败时会恢复升级前的 `.env` 和旧组件镜像。更新 Server 前还会在 `runtime/image-upgrade/backups/<任务ID>/` 保存 PostgreSQL 备份;如果新 Server 已经修改数据结构,自动回滚只恢复配置和容器,不会自动恢复数据库,需要管理员确认后显式恢复备份。

该入口不会更新部署目录、Compose 文件、公开脚本或 Agent。当前正式 `0.2.1` 清单没有镜像摘要,因此按钮保持不可用;这表示安全前置条件未满足,不是让用户绕过校验手工填入镜像。

### 更新完整发布组合

需要更新部署目录、Compose 配置、Agent、升级脚本或完整发布组合时,在当前安装目录执行:

```bash
bash scripts/upgrade.sh
```

完整升级脚本会自动备份 `.env`、版本文件、Compose 配置和数据库,再拉取目标版本并完成部署与检查;失败时会进入处理向导。你可以在向导中:

- 查看最近日志
- 恢复升级前数据库和配置
- 恢复后重新执行本次升级
- 仅切回升级前版本
- 在数据库已经损坏时删除数据卷后从备份重建

如果现场还没有本机执行器或固定更新组件,也应先使用完整升级脚本更新部署目录;完成后部署流程会尝试安装或刷新本机执行器。

## 升级会保留什么

两种升级方式都会保留 `.env` 中的 `BAIZE_STACK_MODE`:

- 当前是 `server-only` 时,完整升级后仍然只启动中心服务,控制台入口只能更新 Server。
- 当前是 `full` 时,完整升级后继续启动控制台,单组件入口可分别更新 Server 或 Web。

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
