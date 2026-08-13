<div align="center">

# 白泽 Baize

**自部署的服务器管控平台 —— 一个控制台，掌控所有服务器**

中文 | [English](README.en.md) · [官网](https://baize.run/) · [文档](#文档)

发布与镜像：[Release](https://github.com/ysfl/baize/releases) · [中心服务镜像](https://github.com/users/ysfl/packages/container/package/baize-server) · [控制台镜像](https://github.com/users/ysfl/packages/container/package/baize-web) · [Discord](https://discord.gg/UMR7mnZFqh) · [Telegram](https://t.me/+y3n_66PfRSw0ZDRl)

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

## AI 客户端接入

如果希望直接用自然语言查询你自己的白泽节点，推荐先安装白泽 AI 接入组件。它会安装开源的 [Baize MCP](https://github.com/ysfl/baize-mcp) 和 [Baize AI Skill](skills/baize-ai/SKILL.md)，并可为 Codex 或 Claude Code 注册 MCP：

```bash
git clone https://github.com/ysfl/baize.git
cd baize
bash scripts/install-ai-access.sh --lang zh
```

> `scripts/install-ai-access.sh` **只安装本机 AI 接入组件，不安装白泽中心服务、控制台或 Agent**。安装白泽产品仍使用下方的 `scripts/install.sh`，两者用途不同。

安装后，在本机交互式终端运行安装器提示的 `baize-mcp login` 命令，再重新打开 AI 客户端。地址和登录会话保存在当前系统用户的本地配置与凭据存储中，不写入 AI 客户端的 MCP 配置。当前正式版只提供连接检查、节点列表和单节点基础状态查询，不执行远程操作。

Windows 使用 `scripts/install-ai-access.ps1`。其它 AI 客户端可通过 `--skill-dir` 指定 Skill 目录，并按安装器输出添加标准 MCP 配置。完整步骤、使用示例和各层分工见 [AI 接入与远程任务指南](docs/ai-remote-tasks.md)。

### 更新 AI 接入组件

已有 MCP 或 Skill 时，不需要重新登录，也不要使用白泽产品的 `scripts/upgrade.sh`。在之前克隆的 `baize` 目录中运行：

```bash
bash scripts/upgrade-ai-access.sh --lang zh
```

升级器会先以快进方式更新公开接入入口，再下载当前正式 MCP、校验发布包和运行文件，最后同步 Skill。它不会覆盖存在本地修改的目录。升级前请退出正在使用 Baize MCP 的 AI 客户端；Windows 运行中的 MCP 进程可能锁定文件。升级完成后请重新打开客户端，让新的工具定义生效。Windows 使用 `scripts/upgrade-ai-access.ps1`。

## 5 分钟快速开始

准备一台 Linux 服务器（2 vCPU / 4 GB 内存 / 20 GB 磁盘起步），安装好 Docker，然后：

```bash
git clone https://github.com/ysfl/baize.git
cd baize
bash scripts/install.sh
```

安装脚本会引导你完成配置。中文安装可选择 GitHub 或 ACR 下载来源，中国大陆推荐 ACR；TimescaleDB 和 Redis 会使用国内镜像加速地址，无需额外登录。脚本会先确认端口，再根据端口提示访问地址；地址格式有误时可以直接重新输入。随后脚本会自动生成强随机的数据库密码、Redis 密码、JWT 密钥、管理员初始密码、凭据主密钥和高敏操作安全码，并拉起默认的完整部署。首次运行会尝试准备离线 GeoIP 数据库；网络受限时会提示原因并继续启动核心服务。安装中断或失败后可直接重跑，脚本会保留现场并输出检查命令。

如需手动配置，基础模板见 `.env.example`，英文基础模板见 `.env.en.example`。性能、队列、调度器、外部日志和 AI 模型等低频调优项见 `.env.advanced.example` / `.env.advanced.en.example`，按需复制到 `.env`。生产环境仍建议优先使用安装脚本生成 `.env`，避免复用示例密钥。

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

当前正式版本发布在 GitHub Releases；版本检测以 [最新版本清单](releases/latest.json) 为准。安装时选择 GitHub 会使用 GHCR 和 Docker Hub，选择 ACR 会使用阿里云镜像、国内镜像加速地址和 Gitee 版本清单。

支持单组件更新的镜像版本发布后，可在“系统版本”页分别更新 Server 或 Web。该操作由宿主机上的本机执行器完成，只替换所选组件并校验镜像摘要和健康状态；Server 容器不会获得 Docker Socket。需要更新部署目录、Compose 配置、Agent 或整套发布组合时，仍使用完整升级脚本。当前正式 `0.2.1` 清单尚未提供可信镜像摘要，因此单组件更新按钮会保持不可用，直到后续版本正式发布该能力。

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
| [升级](docs/upgrade.md) | 单组件更新与完整升级的选择、失败回滚和数据结构说明 |
| [备份与恢复](docs/backup-and-restore.md) | 定时备份、干净目录恢复、安装检查 |
| [卸载与清理](docs/uninstall.md) | 迁移、重装、不再使用时，先备份、再卸载、按需清理数据 |
| [管理员密码与安全码重置](docs/credential-reset.md) | 忘记管理员密码、高敏操作安全码或账号被锁定时 |
| [高级配置与运维](docs/advanced.md) | 配置安全、域名访问策略、控制台触发升级、重新初始化 |
| [AI 接入与远程任务指南](docs/ai-remote-tasks.md) | 安装 MCP 与 Skill、在 AI 客户端中使用白泽，以及远程任务的确认和风险边界 |
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
<summary><b>想卸载或迁移白泽，怎样避免误删数据？</b></summary>

先执行 `bash scripts/uninstall.sh --yes`。默认会先备份，再停止并移除容器，同时保留 Docker 数据卷、`.env` 和历史备份。只有确认不再需要数据后，才使用 `--purge-data` 或 `--purge-all`。详见 [卸载与清理](docs/uninstall.md)。
</details>

<details>
<summary><b>忘记密码 / 安全码？</b></summary>

初始管理员密码在 `.env` 的 `ADMIN_PASSWORD`、安全码在 `BAIZE_HOST_PROFILE_SECURITY_CODE`。如果已经修改且忘记了当前值，在安装目录执行重置脚本即可，见 [管理员密码与安全码重置](docs/credential-reset.md)。
</details>

## 社区与支持

- **官网**：<https://baize.run/>
- **社区（Discord）**：<https://discord.gg/UMR7mnZFqh> —— 交流部署经验、使用问题与产品建议
- **社区（Telegram）**：<https://t.me/+y3n_66PfRSw0ZDRl> —— 交流部署经验、使用问题与产品建议
- **问题反馈**：[GitHub Issues](https://github.com/ysfl/baize/issues)
- **邮件支持**：<support@baize.run>
- **试用、部署协助或商业支持**：扫码联系

  <img src="assets/contact-qr.png" alt="白泽联系二维码" width="200">

## 授权与使用

白泽是闭源商业软件。本仓库仅作为公开部署入口，允许你按 [LICENSE](LICENSE) 中的版权与使用声明部署、运行和维护自己的白泽实例；中心服务、节点 Agent、控制台及其镜像 / 发布包受独立商业授权约束。
