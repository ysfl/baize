# 远程文件传输

[返回 README](../README.md)

这份指南说明在目标节点**未开放 FTP/SSH**、仅能使用白泽受控远程任务通道时，如何把中小文件从本机安全推送到受管节点，并给出两种通道（FTP 与白泽分片任务）的选择依据和参考脚本。

## 两种通道怎么选

| 通道 | 适用条件 | 适用大小 | 特点 |
| --- | --- | --- | --- |
| **FTP / 对象存储拉取** | 节点已开放 FTP 服务，或可访问 Harbor/OSS 等制品仓库 | 无实际上限 | 传统方式，吞吐高，适合大文件与高频发布 |
| **白泽分片任务通道** | 节点只有白泽 Agent 可达（未开放 FTP/SSH） | 建议 ≤ 20MB | 无需开放额外端口或存放凭据；每个分片都是一条受审计的远程任务 |

判断顺序：有制品仓库用制品仓库；节点开放 FTP 用 FTP；两者都没有，用白泽分片任务通道。

## 白泽分片任务通道

### 原理与约束

```
本地文件 ──gzip(可选)──▶ base64 文本 ──按 ~96KB 切片──▶ 逐片作为远程命令任务写盘
                                                          │
目标文件 ◀──sha256 双端比对◀── 远端拼接 + 解码（+解压）◀────┘
```

- **分片大小受 Linux `MAX_ARG_STRLEN`（128KB）限制**：每片作为一个命令参数下发，默认 96KB，请勿超过 120KB。
- **必须逐片串行**：每片确认 `completed` 后再发下一片。并发批量派发可能被 Agent 任务队列丢弃（已实测）。
- **跨批次命名冲突**：分片暂存目录按运行 ID 命名，重传失败的批次使用新目录，不要复用旧分片名。
- **sha256 双端比对是必做步骤**：拼接解码完成后必须与本地原文件比对一致才可使用，不一致保留现场排查。
- **实用上限约 20MB**：4MB 约需 60 片、数分钟；更大的包请改用 FTP 或制品仓库拉取。
- 沙箱受限的节点若无法直接写目标目录，可用包装器命令（如进入宿主命名空间的 `nsenter -t 1 -m sh -c`）执行写盘，脚本已内置 `--wrap` 支持。

### 参考脚本

[`scripts/baize-file-push.sh`](../scripts/baize-file-push.sh) 封装了全流程：登录、分片、串行确认、远端组装、sha256 比对、清理现场。

凭据通过环境变量提供（`BAIZE_TOKEN`，或 `BAIZE_BASE_URL` + `BAIZE_USERNAME` + `BAIZE_PASSWORD`），不写入命令参数、不落到远端文件：

```bash
export BAIZE_BASE_URL="https://your-baize-center.example.com/api/v1"
export BAIZE_USERNAME="admin"
export BAIZE_PASSWORD="..."          # 或直接 export BAIZE_TOKEN

# 推送发布包（zip 已压缩，无需 gzip）
bash scripts/baize-file-push.sh \
  --agent 0123abcd-... \
  --file ./web-dist.zip \
  --remote /opt/app/releases/web-dist-1.2.3.zip

# 推送文本配置（gzip 提升传输效率）
bash scripts/baize-file-push.sh \
  --agent 0123abcd-... \
  --file ./app.env \
  --remote /opt/app/current/.env \
  --gzip
```

沙箱受限节点（写目标目录需要包装器时）：

```bash
bash scripts/baize-file-push.sh \
  --agent 0123abcd-... \
  --file ./app.env \
  --remote /opt/app/current/.env \
  --wrap 'nsenter -t 1 -m sh -c'
```

成功输出 `sha256 校验一致` 后文件即为完整可用；失败时远端暂存目录会保留现场（目录名见输出），可到白泽控制台按任务标题排查具体分片。

### 适用与不适用

| 文件类型 | 是否适合 |
| --- | --- |
| 配置文件（env、yaml 等，KB 级） | ✅ 最适合，单片秒级 |
| 源码增量包（git bundle 等，百 KB 级） | ✅ 适合，保留版本可追溯性 |
| 前端构建产物 / 热更新包（1–10MB） | ✅ 适合，数分钟 |
| APK 全量包、数据库转储、镜像 tar（数十 MB 以上） | ❌ 改用 FTP 或制品仓库拉取 |

### 安全纪律

1. 凭据只通过环境变量进入脚本，不出现在命令参数、任务标题或远端文件中。
2. 含敏感信息的配置文件经任务通道传输时，任务记录由白泽服务端审计留痕；能现场手工维护的敏感文件优先手工维护。
3. 每次传输必须完成 sha256 比对后才投入使用；比对不一致时不得覆盖或切换任何线上文件。
4. 写操作请确认目标路径正确；脚本按远端任务记录审计，误写路径的回滚由操作者负责。

## FTP 通道参考

节点已开放 FTP 时，直接用 `curl` 上传即可，无需额外脚本：

```bash
# 单文件上传（被动模式，适配常见防火墙）
curl --ftp-pasv -T ./web-dist.zip \
  --user "ftpuser:password" \
  "ftp://ftp.example.com/releases/web-dist.zip"

# 带完整性校验：上传后比对本地与远端 sha256
LOCAL_SHA=$(sha256sum ./web-dist.zip | awk '{print $1}')
curl --ftp-pasv -s "ftp://ftp.example.com/releases/web-dist.zip" --user "ftpuser:password" \
  | sha256sum | awk '{print $1}'   # 应与 LOCAL_SHA 一致
```

FTP 通道同样适用“先校验、后切换”的纪律：上传完成后先比对哈希，再执行远端的解压、软链切换等发布动作。

## 与远程任务的关系

分片写盘、组装校验、清理等每一步都是普通的白泽远程命令任务：遵循[AI 接入与远程任务指南](ai-remote-tasks.md)的确认与风险边界，全部留有任务与审计记录；是否需要审批由服务端策略决定。脚本只是把这些固定步骤编排起来，不引入新的权限或绕过任何风控。
