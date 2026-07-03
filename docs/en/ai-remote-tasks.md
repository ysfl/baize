# AI Remote Task Usage Guide

[Back to README](../../README.en.md)

This guide is for AI assistants, automation tools, and administrators who bring AI into Baize operations. Baize remote tasks can help you run diagnostics, service actions, file distribution, and batch commands across managed servers. The AI role is to organize context, propose a plan, draft a task for confirmation, and summarize the result. It should not take over servers without human confirmation.

## Core Principles

| Principle | Requirement |
| --- | --- |
| Human confirmation first | Before creating or running a remote task, the AI must ask the operator to confirm the target servers, purpose, command, risk, and rollback path. |
| Read-only first | If read-only diagnostics are enough, do not modify the system first. Prefer status, logs, disk, port, process, and service checks. |
| Use Baize entries | Operations on managed servers should go through Baize remote tasks, command plans, service management, or file distribution so audit trails stay intact. |
| Smallest safe scope | Test on one server first, then a small batch, then expand only after results are understood. |
| Pause on risk | Restarts, deletion, permission changes, firewall changes, account changes, and batch operations require explicit human confirmation. |
| Keep results traceable | Each task should have a clear title, target, reason, expected result, execution result, and follow-up action for audit review. |

## Information To Confirm Before Starting

Before helping a user run Baize remote tasks, the AI must confirm how it will connect, who is responsible, and which targets are in scope. A remote task is not permission for the AI to invent Baize service paths, and it is not direct SSH access to managed servers. By default, use the Baize console, or a controlled integration entry explicitly provided by an administrator.

| Information | Requirement |
| --- | --- |
| Baize access URL | The user should provide the console URL, such as `https://baize.example.com`. If a controlled integration entry is used, the user must provide the exact base URL; the AI must not guess ports, paths, or service endpoints. |
| Login user | Prefer a dedicated low-privilege account for AI or automation; the account should only cover the servers and features needed for this task. |
| Password / session | Avoid pasting passwords into chat. Prefer user-completed browser login, or a controlled secret-management flow for temporary credentials. |
| Security code / secondary confirmation | Security codes, approvals, and secondary confirmations must be completed by an authorized operator. The AI should not ask users to keep security codes in the conversation and must not suggest bypassing them. |
| Target Agent | The user must confirm the Agent name, Agent ID, group, or tag. The AI must not guess the target from a hostname, IP fragment, or log text alone. |
| Operator | The responsible human must be clear. The AI is an assistant, not the final accountable operator. |
| Maintenance window | Service restarts, upgrades, batch operations, and configuration changes require an approved time window. |

If any of this information is missing, the AI should ask the user first instead of continuing toward an executable task.

## Task Metadata Requirements

Every remote task should make it clear in the audit trail who did what, when, why, and on which servers. An AI-generated task draft should include:

| Field | Requirement |
| --- | --- |
| Task title | Briefly state the scenario, target, and action, such as `Investigate Nginx port - web-01 - read-only`. Avoid titles like `test`, `temporary run`, or `fix it`. |
| Task type | State whether this is read-only diagnosis, service action, file distribution, batch command, Agent check, Agent upgrade, or another type. |
| Operator | State the requester or owner. If the AI prepares the draft, still record the real human operator. |
| Target scope | State Agent ID, Agent name, group, or tag, plus target count. Batch tasks should also state batch size. |
| Reason | State whether the task comes from an alert, user request, maintenance plan, or incident investigation. |
| Command body | Show the full command or script draft. Do not refer vaguely to "the command above". |
| Working directory | Use an explicit directory. If unknown, use a safe default or run a read-only check first. |
| Timeout | Set a timeout according to task type; do not wait forever. |
| Risk | At minimum, separate low, medium, and high. Deletion, restart, permission, firewall, and batch operations are high risk by default. |
| Rollback path | State how to stop, restore, or inspect the task after failure. If there is no rollback path, tell the user clearly. |

Recommended title format:

```text
<scenario> - <target> - <action>
```

Examples:

```text
Investigate disk usage - web-01 - read-only
Reload Nginx - web group batch 1 - confirmation required
Check Agent status - prod-db-01 - read-only
```

## Recommended Workflow

1. **Confirm connection and identity**

   Confirm the Baize access URL, login method, operator, target Agent, and maintenance window. Do not generate an executable task until the user confirms them.

2. **Confirm the target**

   Confirm the server, group, business system, maintenance window, and impact scope. If the target is unclear, do not create a task.

3. **Collect read-only information**

   Prefer read-only status checks, log tails, process checks, port checks, and disk checks. Examples:

   ```bash
   systemctl status <service-name> --no-pager
   journalctl -u <service-name> -n 100 --no-pager
   ss -lntp
   df -h
   free -m
   ```

4. **Draft the task**

   The AI should show a task draft before execution. The draft should include:

   - Baize access URL or controlled entry
   - Operator
   - Target server or group
   - Agent ID or target filter
   - Task title
   - Operation purpose
   - Command or task type
   - Working directory
   - Timeout
   - Expected output
   - Risk notes
   - Rollback or stop method

5. **Let the operator confirm**

   Create or run the task only after the operator confirms it in the Baize console. If the console asks for secondary confirmation, a security code, or approval, the AI must not suggest bypassing it.

6. **Observe the result**

   After the task starts, watch status, output, failed targets, and timed-out targets. Do not blindly repeat a task just because one target failed; understand the cause first.

7. **Record the conclusion**

   After completion, summarize the result, failure reason, affected servers, and next action. Redact sensitive output before it enters a chat or ticket.

## Agent-Related Operations

The Baize Agent collects data and executes remote tasks. Be more careful when operating on the Agent itself, because it is also part of the task execution path.

| Scenario | Recommendation |
| --- | --- |
| Check Agent status | Start with read-only service status and recent logs. |
| Restart Agent | Do it only when clearly needed, and confirm that output may stop and the task may briefly time out. |
| Upgrade Agent | Prefer the upgrade flow provided by the Baize console. Do not handwrite self-upgrade scripts. |
| Agent offline | Do not keep dispatching remote tasks. Check network reachability, registration token, service status, and server firewall first. |
| Batch Agent operation | Verify on one server first, then use small batches with a clear stop condition. |

Common read-only checks:

```bash
systemctl status baize-agent --no-pager
journalctl -u baize-agent -n 100 --no-pager
ps -ef | grep baize-agent | grep -v grep
```

If the server does not use systemd, check the Agent process and logs according to the actual installation method instead of applying these commands to every system.

## Command Requirements

When drafting remote task commands, the AI should follow these requirements:

- Prefer commands that are safe to repeat.
- Use explicit paths and avoid relying on an unknown current directory.
- Do not put passwords, tokens, private keys, or certificate private keys in commands or parameters.
- Do not dump large logs into task output; limit by line count or time range.
- Set reasonable timeouts for long-running tasks.
- Limit concurrency for batch tasks and define a failure stop condition.
- Run read-only checks before write operations.
- Back up configuration or confirm that Baize keeps a reviewable operation record before changing it.
- Use explicit parameters for user input, paths, service names, and filenames. Do not paste unconfirmed text directly into shell.

## Shell Symbol Safety

Many remote task incidents come from shell symbol mistakes: a condition is bypassed, a command continues after failure, or a path expands wider than intended. When drafting commands, the AI should be especially careful with:

| Symbol or pattern | Risk | Requirement |
| --- | --- | --- |
| `;` | The next command runs even if the previous command failed. | Use only for independent steps; prefer `&&` when the next step depends on success. |
| `&&` | Continue only after success. | Good for "check first, then act" flows. |
| `||` | Runs fallback commands after failure and can hide high-risk actions in the fallback path. | Fallbacks must be low risk and scoped with clear grouping. |
| `|` | A pipeline can hide failures on the left side. | Do not rely only on the final command for critical tasks; split checks when needed. |
| `&` | Background execution can make the task return early while output and failures are missed. | Use only when needed, state the log path and follow-up check, and do not produce invalid combinations like `&;`. |
| `>` / `>>` | `>` overwrites files; `>>` appends. | Confirm the destination path before writing, especially for configuration or system files. |
| `2>&1` | Wrong redirection order can send output somewhere unexpected. | Write log redirection clearly, for example `command > /tmp/task.log 2>&1`. |
| `*` / `?` / `[]` | Globs may match too many files. | Avoid broad globs for delete or move operations; run `ls` or `find` read-only first. |
| `` `...` `` / `$(...)` | Runs a subcommand. | Do not put user-provided text inside command substitution. |
| Quotes | Unquoted variables can be split by spaces, globs, or semicolons. | Quote paths and variables, such as `"$target_path"`. |
| Newlines | Multiline scripts can change the scope of conditions. | Review the whole script, not just fragments. |
| `eval` | Reinterprets strings and easily causes command injection. | Do not use it in AI-generated remote tasks. |

Safer directions:

```bash
# Read-only check first
test -d "/var/log/nginx" && du -sh "/var/log/nginx"

# Use && when steps depend on success
systemctl status nginx --no-pager && journalctl -u nginx -n 100 --no-pager

# Show cleanup scope before deleting anything
find "/tmp/my-app-cache" -maxdepth 1 -type f -mtime +7 -print
```

High-risk or discouraged patterns:

```bash
# reload still runs after a failed config test
nginx -t; systemctl reload nginx

# an empty or malformed variable can expand the delete scope
rm -rf $target_path/*

# reinterprets user input and can break out of the intended command
eval "$user_command"
```

If a write operation is truly needed, split read-only confirmation and the write action into two tasks: first show the impact scope, then ask the user to confirm the second task.

## High-Risk Actions

The following actions require explicit administrator confirmation. The AI should not make them the default recommendation.

| Action | Requirement |
| --- | --- |
| Restart a business service | Confirm the maintenance window, impact scope, and recovery check. |
| Delete files or clean directories | Only clean clearly scoped business cache, temporary files, or log fragments; state the path and match range. |
| Change accounts, permissions, or SSH settings | Confirm an alternate login path so you do not lock yourself out. |
| Change firewall or security policy | Confirm allow rules and rollback steps so the console or Agent connection is not cut off. |
| Batch execution | Test on one server, then a small batch, then expand. |
| Restart or upgrade Agent | Prefer built-in Baize flows and prepare for temporary connection interruption. |

The AI should not use remote tasks for:

- Formatting disks, rewriting partition tables, or wiping block devices.
- Deleting root directories, system directories, or broad unscoped directories.
- Flushing firewall rules.
- Printing or packaging passwords, tokens, private keys, or certificate private keys.
- Changing production configuration without backup and rollback notes.

## Batch Task Rules

Batch tasks can turn a small mistake into a large incident. The AI should proceed like this:

1. Validate the command on one low-risk server.
2. Run a small batch of 2 to 5 similar servers.
3. Define a stop condition, such as pausing on any failure or when the failure rate exceeds a threshold.
4. Read each batch result before continuing.
5. Do not mix different operating systems, business roles, or network zones in the same batch.

## Output And Privacy

Remote task output may include paths, usernames, process arguments, internal addresses, or business logs. When using output, the AI should:

- Quote only the relevant excerpts.
- Redact passwords, tokens, private keys, sessions, phone numbers, and email addresses.
- Avoid posting full logs into public chats, public tickets, or public repositories.
- Use Baize audit records or your own internal archive for long-term retention.

## Failure Handling

When a task fails, the AI should identify the cause before suggesting the next step.

| Status | Suggested handling |
| --- | --- |
| Waiting or running too long | Check timeout settings, whether the command expects interaction, and whether the target Agent is online. |
| Timed out | Review existing output before cancelling, extending timeout, or splitting the task. |
| Partially failed | Retry only failed targets after confirming the failure cause is consistent. |
| Output too large | Limit by line count, time range, or paged reading instead of expanding output. |
| Agent disconnected | Pause later tasks and restore the Agent connection first. |

## AI Response Template

Before recommending a remote task, the AI can use this format:

```text
Baize access URL: <console URL or controlled entry>
Login method: <user logs in / temporary low-privilege account / controlled credential>
Operator: <responsible person>
Target: <server or group>
Agent ID: <specific Agent ID, name, or filter>
Task title: <scenario - target - action>
Task type: <read-only diagnosis / service action / file distribution / batch task / Agent operation>
Purpose: <problem to solve>
Task draft: <command or console task settings>
Risk: <low / medium / high>
Expected result: <what success should look like>
Failure handling: <what to do on failure or timeout>
Need your confirmation: <target, maintenance window, permission to run>
```

Only continue to create or run the remote task after the operator confirms it.

## Related Docs

- [Advanced Configuration & Operations](advanced.md)
- [Troubleshooting](troubleshooting.md)
- [Upgrade](upgrade.md)
