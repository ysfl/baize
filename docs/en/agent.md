# Agent Options and Troubleshooting

[Back to README](../../README.en.md)

The Baize Agent is a lightweight program installed on every managed server. It collects host status, runs remote tasks, and provides edge protection. This page covers the Agent's install options and configuration, and how to diagnose a node that cannot connect, drops offline often, or behaves unexpectedly during tasks.

## Install and uninstall

Create a registration token in the console, then run the following on the target server's host (root or sudo required):

```bash
bash scripts/install-agent.sh \
  --server http://<your-server-IP-or-domain>:22501 \
  --token <registration-token>
```

| Option | Description |
| --- | --- |
| `--server <URL>` | A Baize address that the managed server **can reach**, using `http(s)://` or `ws(s)://`. The installer has no built-in default |
| `--token <TOKEN>` | Registration token created in the console; tokens have a usage limit and an expiry |
| `--system-role <ROLE>` | Node role. Leave empty for regular servers; only the host-side executor on the Baize host uses a dedicated token and role |
| `--force` | Overwrite an existing Agent installation |
| `--dry-run` | Run checks and print the install steps without changing the system |
| `--uninstall` | Uninstall the Agent |

Install the Agent directly on the host rather than inside a container; otherwise it cannot read host processes, disks, Docker, or firewall state.

## Configuration file

After installation the configuration is written to `/opt/baize-agent/config.toml` (on macOS, `/usr/local/baize-agent/config.toml`; replace paths below accordingly):

```toml
server_url = "wss://baize.example.com/ws"
token = "<registration-token>"
data_dir = "/opt/baize-agent/data"
system_role = "normal"
# ca_cert = "/etc/ssl/certs/internal-ca.pem"   # set when Baize uses a self-signed or internal certificate
```

| Key | CLI option | Environment variable | Description |
| --- | --- | --- | --- |
| `server_url` | `--server-url` | `BAIZE_SERVER_URL` | Connection address. Use `wss://` when Baize is served over HTTPS and `ws://` over HTTP, ending in `/ws` |
| `token` | `--token` | `BAIZE_TOKEN` | Registration token, used only for the first registration |
| `data_dir` | `--data-dir` | `BAIZE_DATA_DIR` | Data directory, default `/opt/baize-agent/data`; stores the node identity and the Baize server identity |
| `system_role` | `--system-role` | `BAIZE_AGENT_SYSTEM_ROLE` | Node role |
| `ca_cert` | `--ca-cert` | `BAIZE_CA_CERT` | Custom CA certificate path (PEM) |
| — | `--config` | `BAIZE_CONFIG` | Configuration file path, default `/opt/baize-agent/config.toml` |

CLI options and environment variables take precedence over the configuration file. Run `systemctl restart baize-agent` after changing the configuration.

## Where to look first

When a node has problems, run these read-only commands on the target server first; most issues point in a clear direction:

```bash
systemctl status baize-agent --no-pager
journalctl -u baize-agent -n 100 --no-pager
cat /opt/baize-agent/config.toml
```

On macOS, view logs with `sudo tail -n 100 /usr/local/baize-agent/data/launchd.stderr.log`.

If the service has stopped with `status=78`, **Baize rejected the registration**. The Agent will not restart on its own; fix the cause shown in the log and start it manually. `status=79` means the node was removed in the console, which is an expected stop.

## Node never connects

Match what you see in the log:

| Log message | Cause | Action |
| --- | --- | --- |
| Repeated `Reconnecting in` | Network: the target server cannot reach the Baize address | Run `curl -sv https://<baize-domain>/ws` on the target server; check firewalls, security groups, and whether the reverse proxy allows WebSocket |
| No reconnect messages, process seems stuck | Wrong connection scheme, most often `ws://` while Baize is served over HTTPS | Change `server_url` to `wss://…/ws` and restart the Agent |
| `registration token is invalid, expired, revoked, or paused` | Token is invalid, expired, revoked, or paused | Create a new token in the console, update `token`, and restart |
| `token or node quota is exhausted` | Token usage or node quota is used up | Ask the administrator to extend the quota or issue a new token |
| `server records a different public key for this machine` | This machine was previously connected to another Baize server, or its local identity was regenerated | See "Reconnecting after switching Baize servers" below |
| `system role does not match the registration token` | Node role does not match the token type | Fix `system_role` or use a matching token |
| Certificate verification failure | Baize uses a self-signed or internal certificate | Set `ca_cert` to the CA that issued the certificate |

If registration messages do not appear in the journal, run the Agent in the foreground once to see the full output:

```bash
systemctl stop baize-agent
RUST_LOG=info /opt/baize-agent/baize-agent --config /opt/baize-agent/config.toml
# press Ctrl-C once you see the cause, then run systemctl start baize-agent
```

## Reconnecting after switching Baize servers

On first registration the Agent remembers the Baize server's identity so that an impostor server cannot take over the node. When moving a machine from an old Baize server to a new one, changing the address alone is not enough:

1. Create a registration token on the new Baize server. If the new server already has an old record for this machine, remove it from the server list first (removed records can be viewed and restored in the "Server recycle bin").
2. On the target server, stop the Agent, then back up and clear the data directory:

   ```bash
   systemctl stop baize-agent
   mv /opt/baize-agent/data /var/tmp/baize-agent-data.bak.$(date +%Y%m%d%H%M%S)
   ```

3. Update `server_url` and `token` in `config.toml`, then run `systemctl start baize-agent`.

## Node is online but drops offline often

- Check the log around the disconnect. Common causes are unstable outbound networking and an idle timeout on the reverse proxy that is too short. The reverse proxy must keep `/ws` connections open; a read timeout of at least 120 seconds is recommended.
- Under heavy server load the Agent lowers its own collection frequency to protect your workloads, so metrics may be sparse for a while. This is expected.
- A large clock skew causes signature verification to fail; make sure NTP synchronization is working.

## Remote tasks behave unexpectedly

| Symptom | Diagnosis and action |
| --- | --- |
| System directories appear read-only inside a task | The Agent runs in a hardened system environment by default. The read-only view seen by tasks **does not indicate a disk failure**. Do not try to remount partitions from a task; to write to business directories, grant deployment-writable directories for that server in the console |
| A new task fails immediately with no output | Usually the concurrency quota is taken by unfinished tasks. Cancel the stuck tasks in the task list, then retry once |
| A task runs for a long time with no output | Cancel the task first; if that does not help, restart the Agent on the target server: `systemctl restart baize-agent` |
| Restarting the Agent itself hangs | Run `systemctl kill -s SIGKILL baize-agent`, then `systemctl start baize-agent` |
| A long-running maintenance script is terminated midway | Remote tasks are meant for short commands. For long operations on systemd hosts, hand the script to the system with `systemd-run --unit=<name> --collect /bin/sh <script>`, keep the script and its log in a host-visible directory (such as `/opt/<your-directory>`), and read the log with a read-only task |
| `journalctl --since "16:45"` returns nothing | Absolute times are parsed in the target server's local time zone. Across time zones, use `--since "30 minutes ago"` instead |

For remote task usage and risk boundaries, see the [AI Access and Remote Tasks Guide](ai-remote-tasks.md).

## Upgrade and uninstall

- Upgrade the Agent from the server detail page in the console rather than writing your own self-upgrade script.
- Uninstall: `bash scripts/install-agent.sh --uninstall`. Remove the server record in the console afterwards.

## Related docs

- [Error Messages and What to Do](errors.md)
- [Troubleshooting](troubleshooting.md)
- [AI Access and Remote Tasks Guide](ai-remote-tasks.md)
- [Remote File Transfer](remote-file-transfer.md)
