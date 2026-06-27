<div align="center">

# 白泽 Baize

**自部署的服务器管控平台 —— 一个控制台，掌控所有服务器**

中文 | [English](README.en.md) · [官网](https://baize.run/) · [文档](#文档)

发布与镜像：[Release](https://github.com/ysfl/baize/releases) · [中心服务镜像](https://github.com/users/ysfl/packages/container/package/baize-server) · [控制台镜像](https://github.com/users/ysfl/packages/container/package/baize-web) · [Discord](https://discord.gg/UMR7mnZFqh)

</div>

白泽（Baize）是一款自部署的服务器管控平台。在一台服务器上启动白泽，再为每台需要纳管的服务器装上轻量 Agent，你就能在一个控制台里完成**资产纳管、实时监控、安全防护、远程运维和操作审计**。

数据全程留在你自己的服务器上，白泽不依赖外部托管。

> 本仓库是白泽的**公开部署入口**，提供 Docker Compose 编排、安装与升级脚本、备份恢复工具和版本清单。白泽中心服务、节点 Agent 与控制台以容器镜像和公开发布包形式分发，请从镜像仓库或 [GitHub Releases](https://github.com/ysfl/baize/releases) 获取。

在线预览与功能演示：[https://baize.run/](https://baize.run/)

![白泽节点汇聚拓扑](assets/baize-topology.svg)

## 核心能力

| 能力 | 说明 |
| --- | --- |
| **资产纳管** | 接入服务器后统一查看在线状态、配置与负载，按需分组管理。 |
| **全栈监控** | CPU、内存、磁盘、网络、进程、服务、Nginx、Docker、SSL 证书，多维度指标采集与可视化。 |
| **安全防护** | 边缘 WAF、SSH 暴力破解检测、攻击 IP 联防，证书与防火墙状态统一观测。 |
| **远程运维** | 网页终端、批量命令执行、文件分发、服务管理，关键操作可审计记录。 |
| **任务编排** | 分布式定时任务管理，多节点协同执行，结果统一收集。 |
| **告警审计** | 规则引擎、告警升级、静默策略与多渠道推送；关键操作留痕，事后可追溯。 |

## 适合谁用

- **自建 / 私有化团队**：希望数据不出自己服务器，又想要一套现代化管控台。
- **多服务器运维**：手里有几台到几十台机器，想统一纳管、统一监控，告别逐台 SSH。
- **需要合规留痕**：关键操作要审计、要能追溯到人。
- **想替代分散脚本**：用一个平台收编四散的监控脚本、定时任务和应急命令。

## 工作方式

白泽采用「边缘智能 · 中心调度」架构：

![白泽工作方式](assets/baize-workflow.svg)

中心服务负责汇聚与调度，每台被纳管服务器上的轻量 Agent 负责采集、执行与边缘防护。控制台、移动端和开放集成共用同一套管控入口。

## 5 分钟快速开始

准备一台 Linux 服务器（2 vCPU / 4 GB 内存 / 20 GB 磁盘起步），安装好 Docker，然后：

```bash
git clone https://github.com/ysfl/baize.git
cd baize
bash scripts/install.sh
```

安装脚本会引导你完成配置，自动生成强随机的数据库密码、Redis 密码、JWT 密钥、管理员初始密码、凭据主密钥和高敏操作安全码，并拉起默认的完整部署。

安装完成后的默认访问地址：

```text
控制台:   http://<你的服务器IP或域名>:8088
服务地址: http://<你的服务器IP或域名>:22501/api/v1
```

管理员初始账号为 `admin`，初始密码写在自动生成的 `.env` 文件的 `ADMIN_PASSWORD` 中。主机画像刷新、命令历史明文查看等高敏操作使用独立安全码，初始值写在 `.env` 的 `BAIZE_HOST_PROFILE_SECURITY_CODE` 中。

> ⚠️ **首次登录后请立即修改密码**，并妥善保管 `.env`，不要提交到 Git。

需要无人值守安装、`server-only` 模式或自定义端口/镜像？见 [部署模式与访问地址](docs/deployment.md)。只在服务器部署中心服务、本地运行控制台时，见 [本地控制台接入](docs/server-only-local-web.md)。

## 装好之后做什么

1. **登录并改密** —— 用 `admin` + `.env` 里的初始密码登录控制台，立即修改密码。
2. **接入第一台节点** —— 在控制台创建注册令牌后，到目标服务器宿主机上执行：

   ```bash
   bash scripts/install-agent.sh \
     --server http://<你的服务器IP或域名>:22501 \
     --token <注册令牌>
   ```

   `--server` 必须填写你自己的白泽访问地址，安装器不会内置任何默认控制端。Agent 建议直接装在被纳管服务器的宿主机上（不建议放进容器），以便读取进程、磁盘、Docker、防火墙等宿主机状态。
3. **逛一圈** —— 打开监控看实时指标、安全看 WAF 与登录风控、审计看操作留痕。
4. **配域名访问策略**（生产建议）—— 减少 IP 直连与未知 Host 进入控制台，见 [高级配置](docs/advanced.md#域名访问策略)。

## 版本与升级

控制台右上角会在有新版本时提示。升级前请记住：

- **先备份。** 升级会自动备份，但数据结构变更**不会自动回退**，出问题需从备份显式恢复。
- **保留部署配置。** 升级会保留 `.env` 中的部署形态（如 `BAIZE_STACK_MODE`），不会重置你的安装目录。

当前测试版发布在 GitHub Releases 的 Pre-release 列表中；版本检测以 [最新版本清单](releases/latest.json) 为准。当前镜像为 [中心服务 `ghcr.io/ysfl/baize-server:0.1.38`](https://github.com/users/ysfl/packages/container/package/baize-server) 与 [控制台 `ghcr.io/ysfl/baize-web:0.1.38`](https://github.com/users/ysfl/packages/container/package/baize-web)。

```bash
bash scripts/version.sh --check-remote   # 对比远端最新版本
bash scripts/upgrade.sh                  # 执行升级（自动备份 + 失败向导）
```

完整命令、失败回滚与数据结构说明见 [升级文档](docs/upgrade.md)。

## 文档

| 文档 | 何时看 |
| --- | --- |
| [部署模式与访问地址](docs/deployment.md) | 需要 `server-only`、无人值守安装、分离部署或自定义端口/镜像时 |
| [本地控制台接入](docs/server-only-local-web.md) | 服务器只部署中心服务，本地独立运行控制台并接入时 |
| [升级](docs/upgrade.md) | 升级前的决策、命令、失败回滚与数据结构说明 |
| [备份与恢复](docs/backup-and-restore.md) | 定时备份、干净目录恢复、安装检查 |
| [管理员密码与安全码重置](docs/credential-reset.md) | 忘记管理员密码、高敏操作安全码或账号被锁定时 |
| [高级配置与运维](docs/advanced.md) | 配置安全、域名访问策略、控制台触发升级、重新初始化 |
| [故障排查](docs/troubleshooting.md) | 控制台打不开、Agent 连不上、升级失败、数据卷损坏等 |

## 常见问题

<details>
<summary><b>装完控制台打不开？</b></summary>

先跑 `bash scripts/check-install.sh`。确认访问的是控制台端口（默认 `8088`）而非服务端口（`22501`）；`server-only` 模式不会启动控制台容器。详见 [故障排查](docs/troubleshooting.md)。
</details>

<details>
<summary><b>Agent 连不上中心服务？</b></summary>

确认 `--server` 填的是被纳管服务器能访问到的白泽地址（带 `http(s)://`）、注册令牌未过期，且 Agent 装在宿主机而非容器内。详见 [故障排查](docs/troubleshooting.md)。
</details>

<details>
<summary><b>升级失败怎么回滚？</b></summary>

升级脚本失败会进入处理向导，可直接恢复升级前的数据库与配置或切回旧版本；也可 `bash scripts/restore-backup.sh --latest --yes --require-db` 手动回滚。详见 [升级](docs/upgrade.md)。
</details>

<details>
<summary><b>数据库数据卷坏了怎么办？</b></summary>

从最近备份重建：`bash scripts/restore-backup.sh --latest --yes --require-db --reset-volumes --i-understand-data-loss`（破坏性，仅在确认需要时使用）。详见 [备份与恢复](docs/backup-and-restore.md)。
</details>

<details>
<summary><b>忘记密码 / 安全码？</b></summary>

初始管理员密码在 `.env` 的 `ADMIN_PASSWORD`、安全码在 `BAIZE_HOST_PROFILE_SECURITY_CODE`。如果已经修改且忘记了当前值，在安装目录执行重置脚本即可，见 [管理员密码与安全码重置](docs/credential-reset.md)。
</details>

## 社区与支持

- **官网**：<https://baize.run/>
- **社区（Discord）**：<https://discord.gg/UMR7mnZFqh> —— 交流部署经验、使用问题与产品建议
- **问题反馈**：[GitHub Issues](https://github.com/ysfl/baize/issues)
- **邮件支持**：<support@baize.run>
- **试用、部署协助或商业支持**：扫码联系

  <img src="assets/contact-qr.png" alt="白泽联系二维码" width="200">

## 授权与使用

白泽是闭源商业软件。本仓库仅作为公开部署入口，允许你按 [LICENSE](LICENSE) 中的版权与使用声明部署、运行和维护自己的白泽实例；中心服务、节点 Agent、控制台及其镜像 / 发布包受独立商业授权约束。
