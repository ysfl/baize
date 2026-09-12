# Remote File Transfer

[Back to README](../README.md)

This guide covers pushing small-to-medium files from your workstation to managed nodes when **FTP/SSH are not available** and the only reachable channel is the Baize controlled remote-task channel. It also explains when to prefer FTP or an artifact registry instead.

## Choosing a channel

| Channel | Requirement | Practical size | Notes |
| --- | --- | --- | --- |
| **FTP / artifact registry (Harbor, OSS)** | Node exposes FTP, or can pull from a registry | No hard limit | Traditional, high throughput, best for large artifacts and frequent releases |
| **Baize chunked task channel** | Only the Baize Agent is reachable | ≤ 20 MB recommended | No extra ports or stored credentials; every chunk is an audited remote task |

Decision order: use an artifact registry when available; use FTP when the node exposes it; otherwise use the Baize chunked channel.

## Baize chunked task channel

### How it works and its constraints

```
local file ──gzip(optional)──▶ base64 text ──split ~96KB──▶ chunks written by serial remote tasks
                                                                        │
target file ◀──sha256 compared both ends◀── remote assemble + decode ──┘
```

- **Chunk size is limited by Linux `MAX_ARG_STRLEN` (128KB)**: each chunk is one command argument; default 96KB, do not exceed 120KB.
- **Serial execution is mandatory**: wait for each chunk task to reach `completed` before sending the next. Burst-dispatching chunks in parallel may be dropped by the Agent task queue (verified in practice).
- **Avoid cross-batch name clashes**: staging directories are named per run; re-upload failed batches into a new directory instead of reusing old chunk names.
- **The sha256 comparison is mandatory**: only use the remote file after its checksum matches the local original; keep the staging area for inspection otherwise.
- **Practical ceiling ~20MB**: a 4MB file needs about 60 chunks and a few minutes. Larger packages should go through FTP or a registry.
- On sandboxed nodes where the target directory is not directly writable, pass a wrapper command (e.g. `nsenter -t 1 -m sh -c` to enter the host namespace) via `--wrap`.

### Reference script

[`scripts/baize-file-push.sh`](../../scripts/baize-file-push.sh) wraps the whole flow: login, chunking, serial confirmation, remote assembly, sha256 verification, and cleanup.

Credentials are provided via environment variables (`BAIZE_TOKEN`, or `BAIZE_BASE_URL` + `BAIZE_USERNAME` + `BAIZE_PASSWORD`) and never appear in command arguments or remote files:

```bash
export BAIZE_BASE_URL="https://your-baize-center.example.com/api/v1"
export BAIZE_USERNAME="admin"
export BAIZE_PASSWORD="..."          # or export BAIZE_TOKEN

# Push a release artifact (zip is already compressed; no --gzip needed)
bash scripts/baize-file-push.sh \
  --agent 0123abcd-... \
  --file ./web-dist.zip \
  --remote /opt/app/releases/web-dist-1.2.3.zip

# Push a text config (gzip improves transfer)
bash scripts/baize-file-push.sh \
  --agent 0123abcd-... \
  --file ./app.env \
  --remote /opt/app/current/.env \
  --gzip
```

For sandboxed nodes:

```bash
bash scripts/baize-file-push.sh \
  --agent 0123abcd-... \
  --file ./app.env \
  --remote /opt/app/current/.env \
  --wrap 'nsenter -t 1 -m sh -c'
```

On success the script prints a checksum match; on failure it keeps the remote staging directory (path in the output) so you can inspect chunk tasks in the Baize console.

### Fit assessment

| File type | Suitable? |
| --- | --- |
| Config files (env, yaml, KB-scale) | ✅ Best fit, single chunk, instant |
| Source deltas (git bundle, ~100KB) | ✅ Good, keeps version traceability |
| Frontend bundles / hot-update packages (1–10MB) | ✅ Fine, minutes |
| Full APKs, database dumps, image tars (tens of MB+) | ❌ Use FTP or a registry instead |

### Safety rules

1. Credentials enter the script only via environment variables — never in arguments, task titles, or remote files.
2. Transferring secret-bearing config files leaves audited task records on the Baize server; prefer manual maintenance for highly sensitive files.
3. Always complete the sha256 comparison before using the pushed file; never overwrite or switch production files on a failed comparison.
4. Double-check target paths; rollback of misdirected writes is the operator's responsibility.

## FTP channel reference

When the node exposes FTP, plain `curl` is enough:

```bash
# Passive-mode upload
curl --ftp-pasv -T ./web-dist.zip \
  --user "ftpuser:password" \
  "ftp://ftp.example.com/releases/web-dist.zip"

# Verify integrity after upload
LOCAL_SHA=$(sha256sum ./web-dist.zip | awk '{print $1}')
curl --ftp-pasv -s "ftp://ftp.example.com/releases/web-dist.zip" --user "ftpuser:password" \
  | sha256sum | awk '{print $1}'   # must equal LOCAL_SHA
```

Apply the same "verify first, switch later" discipline: compare hashes before running any remote extraction or symlink switch.

## Relation to remote tasks

Every step (chunk write, assembly, verification, cleanup) is an ordinary Baize remote command task and follows the confirmation and risk boundaries in the [AI access & remote tasks guide](ai-remote-tasks.md). All steps leave task and audit records; whether approval is required is decided by server-side policy. The script only orchestrates these fixed steps and introduces no new permissions or bypasses.
