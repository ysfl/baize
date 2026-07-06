# 卸载与清理

[返回 README](../README.md)

当你要迁移、重装或不再使用白泽时，建议按「先备份、再卸载、按需清理」的顺序处理。默认卸载会保留数据库卷、`.env` 和备份文件，方便误操作后恢复；只有显式使用清除参数时才会删除数据。

## 推荐流程

```bash
# 停止并移除白泽容器，卸载当前宿主机上的本机连接程序，保留数据与配置
bash scripts/uninstall.sh --yes
```

默认流程会做这些事：

| 步骤 | 默认行为 |
| --- | --- |
| 卸载前备份 | 自动执行，备份位置会在命令结束前输出 |
| 本机连接程序 | 尝试卸载当前宿主机上的连接程序与登录声明 |
| 容器 | 停止并移除白泽容器与网络 |
| 数据卷 | 保留 PostgreSQL、Redis 和服务数据卷 |
| 配置与备份 | 保留 `.env` 和历史备份 |

如果你只想先备份，不卸载：

```bash
bash scripts/backup.sh --yes
```

## 彻底清除

确认备份可用，并且确定不再需要当前实例数据后，再执行破坏性清理：

```bash
bash scripts/uninstall.sh --yes \
  --purge-data \
  --purge-config \
  --i-understand-data-loss
```

如需连同本实例备份目录一起删除，再追加：

```bash
bash scripts/uninstall.sh --yes \
  --purge-all \
  --i-understand-data-loss
```

`--purge-all` 会删除 Docker 数据卷、`.env` 和本实例备份目录。执行前请确认你已经把需要保留的备份复制到其它位置。

如果还要删除安装目录，在上面的卸载命令完成后退出当前目录，再删除仓库目录：

```bash
cd ..
rm -rf baize
```

## 只卸载本机连接程序

如果你只想移除当前宿主机上的连接程序，不停止白泽服务：

```bash
bash scripts/install-agent.sh --uninstall
```

这会停止并移除 `baize-agent` 系统服务、安装目录和登录声明。其它被纳管服务器上的连接程序需要在对应服务器上分别卸载。

## 从备份恢复

卸载后如果需要恢复，重新进入一个干净目录并使用备份恢复：

```bash
git clone https://github.com/ysfl/baize.git baize-restore
cd baize-restore

bash scripts/restore-backup.sh \
  --backup-dir ~/.baize/backups/baize-<实例>/<备份> \
  --yes --require-db --reset-volumes --i-understand-data-loss
```

恢复完成后运行：

```bash
bash scripts/check-install.sh
```

## 相关文档

- [备份与恢复](backup-and-restore.md)
- [部署模式与访问地址](deployment.md)
- [故障排查](troubleshooting.md)
