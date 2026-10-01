# Agent 参数与排障

[返回 README](../README.md)

白泽 Agent 是装在每台被纳管服务器上的轻量程序，负责采集主机状态、执行远程任务和边缘防护。本文说明 Agent 的安装参数、配置方式，以及节点连不上、频繁离线、任务异常时怎样判断和处理。

## 安装与卸载

在控制台创建注册令牌后，在目标服务器的宿主机上执行（需要 root 或 sudo）：

```bash
bash scripts/install-agent.sh \
  --server http://<你的服务器IP或域名>:22501 \
  --token <注册令牌>
```

| 参数 | 说明 |
| --- | --- |
| `--server <URL>` | 被纳管服务器**能访问到**的白泽地址，支持 `http(s)://` 或 `ws(s)://`。安装器不内置任何默认控制端 |
| `--token <TOKEN>` | 注册令牌，在控制台创建；令牌有使用次数和有效期 |
| `--system-role <ROLE>` | 节点身份，普通服务器无需填写；仅白泽所在宿主机的本机执行器使用专用令牌和对应身份 |
| `--force` | 覆盖已安装的 Agent |
| `--dry-run` | 只做检查并打印即将执行的安装步骤，不改动系统 |
| `--uninstall` | 卸载 Agent |

建议把 Agent 直接装在宿主机上，不要放进容器，否则读不到进程、磁盘、Docker、防火墙等宿主机状态。

## 配置文件

安装后配置写在 `/opt/baize-agent/config.toml`（macOS 为 `/usr/local/baize-agent/config.toml`，下文路径同理替换）：

```toml
server_url = "wss://baize.example.com/ws"
token = "<注册令牌>"
data_dir = "/opt/baize-agent/data"
system_role = "normal"
# ca_cert = "/etc/ssl/certs/internal-ca.pem"   # 白泽使用自签名或企业内部证书时填写
```

| 配置项 | 命令行参数 | 环境变量 | 说明 |
| --- | --- | --- | --- |
| `server_url` | `--server-url` | `BAIZE_SERVER_URL` | 连接地址。白泽走 HTTPS 时必须是 `wss://`，走 HTTP 时是 `ws://`，结尾为 `/ws` |
| `token` | `--token` | `BAIZE_TOKEN` | 注册令牌，只在首次注册时使用 |
| `data_dir` | `--data-dir` | `BAIZE_DATA_DIR` | 数据目录，默认 `/opt/baize-agent/data`，保存节点身份与白泽服务端身份 |
| `system_role` | `--system-role` | `BAIZE_AGENT_SYSTEM_ROLE` | 节点身份 |
| `ca_cert` | `--ca-cert` | `BAIZE_CA_CERT` | 自定义 CA 证书路径（PEM） |
| — | `--config` | `BAIZE_CONFIG` | 配置文件路径，默认 `/opt/baize-agent/config.toml` |

优先级：命令行参数与环境变量高于配置文件。修改配置后执行 `systemctl restart baize-agent` 生效。

## 先看哪里

节点有问题时，先在目标服务器上执行这几条只读命令，大多数问题能直接看出方向：

```bash
systemctl status baize-agent --no-pager
journalctl -u baize-agent -n 100 --no-pager
cat /opt/baize-agent/config.toml
```

macOS 上查看日志：`sudo tail -n 100 /usr/local/baize-agent/data/launchd.stderr.log`。

服务停止且状态里出现 `status=78`，表示**注册被白泽拒绝**，Agent 不会自动重启，需要按日志提示修正后手动启动。出现 `status=79` 表示该节点已在控制台被移除，属于预期停止。

## 节点一直连不上

按下表对照日志中的现象：

| 日志现象 | 原因 | 处理 |
| --- | --- | --- |
| 反复出现 `Reconnecting in` | 网络不通：目标服务器访问不到白泽地址 | 在目标服务器执行 `curl -sv https://<白泽域名>/ws`，检查防火墙、安全组和反向代理是否放行 WebSocket |
| 没有重连日志，进程看起来卡住 | 连接地址协议写错，最常见是白泽走 HTTPS 却写成 `ws://` | 把 `server_url` 改为 `wss://…/ws`，重启 Agent |
| `registration token is invalid, expired, revoked, or paused` | 令牌无效、过期、被吊销或暂停 | 在控制台重新创建令牌，更新 `token` 后重启 |
| `token or node quota is exhausted` | 令牌次数或节点数额度用完 | 请管理员扩充额度或签发新令牌 |
| `server records a different public key for this machine` | 这台机器曾经接入过其他白泽，或本机身份被重新生成 | 见下方「换了白泽服务器后重新接入」 |
| `system role does not match the registration token` | 节点身份与令牌类型不匹配 | 修正 `system_role` 或换用对应令牌 |
| 证书校验失败 | 白泽使用自签名或企业内部证书 | 配置 `ca_cert` 指向签发该证书的 CA |

journal 里看不到注册相关日志时，可以前台运行一次查看完整输出：

```bash
systemctl stop baize-agent
RUST_LOG=info /opt/baize-agent/baize-agent --config /opt/baize-agent/config.toml
# 看清原因后 Ctrl-C，再 systemctl start baize-agent
```

## 换了白泽服务器后重新接入

Agent 首次注册时会记住白泽服务端的身份，防止被冒充的服务端接管。因此一台机器从旧白泽迁到新白泽时，只改地址不够：

1. 在新白泽控制台创建注册令牌；若新白泽里已有这台机器的旧记录，先在服务器列表中移除（移除的记录可在「服务器回收站」中查看与恢复）。
2. 在目标服务器上停止 Agent，备份并清空数据目录：

   ```bash
   systemctl stop baize-agent
   mv /opt/baize-agent/data /var/tmp/baize-agent-data.bak.$(date +%Y%m%d%H%M%S)
   ```

3. 更新 `config.toml` 的 `server_url` 与 `token`，执行 `systemctl start baize-agent`。

## 节点在线但频繁离线

- 查看日志里断线前后的报错，常见是出口网络抖动、反向代理空闲超时过短。反向代理需要对 `/ws` 放开长连接，读超时建议不低于 120 秒。
- 服务器负载很高时，Agent 会主动降低自身采集频率以保护业务，指标可能短时稀疏，属于预期行为。
- 机器时间偏差过大会导致签名校验失败，确认 NTP 同步正常。

## 远程任务看起来异常

| 现象 | 判断与处理 |
| --- | --- |
| 任务看到的系统目录是只读的 | Agent 默认运行在系统加固环境里，任务看到的只读视图**不代表磁盘故障**。不要在任务里尝试重新挂载分区；需要写业务目录时，在控制台为该服务器授权部署可写目录 |
| 新任务马上失败且没有输出 | 通常是并发额度被未结束的任务占满。先在任务列表取消卡住的任务，再重试一次 |
| 任务长时间运行不结束、也没有输出 | 先取消任务；仍不恢复时在目标服务器重启 Agent：`systemctl restart baize-agent` |
| 重启 Agent 本身卡住 | 执行 `systemctl kill -s SIGKILL baize-agent` 后再 `systemctl start baize-agent` |
| 长时间运行的维护脚本被中途终止 | 远程任务适合短时命令。耗时较长的操作，在 systemd 主机上可用 `systemd-run --unit=<名称> --collect /bin/sh <脚本>` 交给系统在后台执行，脚本和日志放在宿主机可见目录（如 `/opt/<你的目录>`），再用只读任务查看日志 |
| `journalctl --since "16:45"` 查不到日志 | 绝对时间按目标服务器本地时区解析，跨时区排查改用 `--since "30 minutes ago"` |

更多远程任务的用法与风险边界见 [AI 接入与远程任务指南](ai-remote-tasks.md)。

## 升级与卸载

- 升级 Agent 优先使用控制台服务器详情页的升级功能，不要手写自升级脚本。
- 卸载：`bash scripts/install-agent.sh --uninstall`。卸载后在控制台移除该服务器记录。

## 相关文档

- [错误提示与处理](errors.md)
- [故障排查](troubleshooting.md)
- [AI 接入与远程任务指南](ai-remote-tasks.md)
- [远程文件传输](remote-file-transfer.md)
