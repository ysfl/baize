# AI Access and Remote Task Guide

[Back to README](../../README.en.md)

This guide is for AI assistants, automation tools, and administrators who bring AI into Baize operations. Start with the Baize AI access components so an AI client can read Baize information through the local Baize MCP connector. Use this guide and the public API for explanations, deployment, upgrades, recovery, and advanced integration. Existing Baize permissions and human confirmation remain responsible for remote changes.

## Recommended Access Path

1. Run [`scripts/install-ai-access.sh`](../../scripts/install-ai-access.sh), or use [`scripts/install-ai-access.ps1`](../../scripts/install-ai-access.ps1) on Windows. These scripts install only MCP and the Skill; they do not install the Baize server, console, or Agent. Use [`scripts/install.sh`](../../scripts/install.sh) to install the product itself.
2. Run the displayed `baize-mcp login` command in an interactive local terminal. The password never enters command arguments or the AI conversation.
3. Restart the AI client. The public Skill routes natural-language intents such as finding a node or checking status to Baize MCP first.
4. The AI checks `baize_connection_status`, then uses `baize_agents_list` with the available name, alias, system, region, version, architecture, status, or group filters. It calls `baize_agent_get` only after a unique match. Users do not need to remember node IDs.
5. For a remote action, first use the command-template list and preview tools to confirm the available scope, then create a command plan. Creating a plan does not dispatch it; if the plan requires approval, requesting approval, submitting a decision, and execution remain separate confirmations.

## Update MCP and the Skill

AI access components are updated separately from the Baize product. If MCP and the Skill are already installed, run this from the `baize` directory that you originally cloned with Git:

```bash
bash scripts/upgrade-ai-access.sh --lang en
```

On Windows, use `scripts/upgrade-ai-access.ps1`. The upgrader fast-forwards the public access entry, installs the current stable MCP, verifies the archive and executable, and refreshes the public Skill. It refuses to overwrite a directory with local changes and does not delete or re-request an existing local sign-in session. Close AI clients that use MCP before upgrading, then reopen them afterward so the updated tool definitions are loaded.

If MCP was installed manually from [Baize MCP Releases](https://github.com/ysfl/baize-mcp/releases), rerun the public AI access installer or replace the executable in the same directory with the target release and keep the accompanying `baize-mcp.sha256` file. Do not delete the local configuration directory or operating-system credential store.

## Four Responsibilities

| Component | Responsibility | Not responsible for |
| --- | --- | --- |
| Public API | The stable capability and field contract for advanced integrations | Tool discovery and natural-language orchestration in an AI client |
| Baize MCP | Local, discoverable AI tools for published behavior with bounded inputs and results, including template previews, plan management, and task status | Reimplementing Baize permissions, storing secrets, or acting as a universal request proxy |
| Baize AI Skill | Deciding when to use Baize, selecting MCP tools, handling unique/multiple/zero matches, and guiding fallback | Copying the full API reference or inventing unpublished actions |
| Public documentation | Installation, upgrades, troubleshooting, recovery, and advanced usage | Asking users to paste login details into every conversation |

When MCP and the Skill are available, use MCP first. When MCP is unavailable, repair the local access setup and then read the documentation. Use the public API only when MCP does not cover a capability and the user explicitly needs the advanced integration.

## Core Principles

| Principle | Requirement |
| --- | --- |
| Human confirmation first | Before creating a plan, the AI must show the target, template, parameters, risk, expected result, and rollback path; before executing or cancelling a task, the operator must explicitly confirm. |
| Read-only first | If read-only diagnostics are enough, do not modify the system first. Prefer status, logs, disk, port, process, and service checks. |
| Use Baize entries | Operations on managed servers should go through Baize remote tasks, command plans, service management, or file distribution so audit trails stay intact. |
| Smallest safe scope | Test on one server first, then a small batch, then expand only after results are understood. |
| Pause on risk | Restarts, deletion, permission changes, firewall changes, account changes, batch operations, and approval decisions require explicit human confirmation. |
| Keep results traceable | Each task should have a clear title, target, reason, expected result, execution result, and follow-up action for audit review. |

## Information To Confirm Before Starting

The AI should first determine whether Baize MCP is already connected. When it is available, do not ask the user to repeat the Baize address, account, password, session, or node ID; query candidates through MCP first. A remote task is not permission to invent Baize service paths or use direct SSH. Return to the Baize console for operations not covered by the current MCP release.

| Information | Requirement |
| --- | --- |
| Connection status | Call `baize_connection_status` first. Continue when the saved session is valid; if it expired, ask the user to sign in again from a local terminal without requesting the address in chat. |
| Login user | MCP uses the locally signed-in Baize account and its existing permission scope. The user signs in again locally to switch accounts. |
| Password / session | Never paste the password, session, or address into chat. Sign-in runs in an interactive local terminal, and the operating-system credential store protects the session. |
| Security code / secondary confirmation | Security codes, approvals, and secondary confirmations must be completed by an authorized operator. The AI should not ask users to keep security codes in the conversation and must not suggest bypassing them. |
| Target Agent | Search by the name or business characteristics supplied by the user. Use the ID internally after one unique match, show candidates for multiple matches, and ask for more detail after no match. |
| Operator | Read-only queries do not require repeated identification. A responsible human is required before a remote change; the AI is not the accountable operator. |
| Maintenance window | Confirm a window only for restarts, upgrades, batch operations, or configuration changes. |

If the client has no MCP tools, install or repair the access setup first. Ask follow-up questions only when information required for a write operation is missing; do not turn a read-only query into a configuration interview.

## MCP Command Workflow

When the user requests a command workflow already published by Baize, the AI should follow this sequence:

1. Use `baize_command_templates_list` to find templates allowed for the signed-in account, then confirm the template name, parameter constraints, platform, and risk level.
2. Use `baize_command_template_preview` for the selected agents. Preview does not create a plan or run a command; do not request or expose secret parameter values.
3. Show the operator the target agents, template, parameters, risk, precheck result, expected result, and rollback path. Ask the user to choose when multiple agents or templates match.
4. After the user confirms creation, call `baize_command_plan_create`, then use `baize_command_plan_get` to review plan status, risk, and prechecks. Creating a plan does not dispatch a task.
5. If the plan returns `approvalRequired=true` and the current MCP exposes approval tools, explain the plan, risk, and approval reason. After the operator explicitly confirms “submit for approval”, call `baize_command_plan_approval_create`. Use `baize_command_plan_approvals_list` or `baize_command_plan_approval_get` to review the status and redacted plan snapshot.
6. Call `baize_command_plan_approval_decide` only when the operator explicitly instructs the current account to approve or reject the request. `approved=true` submits an opinion only; Baize still checks approval permission, self-approval policy, snapshot drift, and expiry. Never bypass a permission denial or state conflict. If approval tools are unavailable, complete approval in the Baize console.
7. After approval, obtain a separate explicit confirmation before calling `baize_command_plan_execute`. Baize may still require risk confirmation or a secondary security confirmation; follow the returned state.
8. Use `baize_exec_task_get` to monitor overall and per-agent progress. Before stopping a pending or running task, explain the impact and get confirmation before calling `baize_exec_task_cancel`.

MCP returns bounded plan and task status fields. It does not return command bodies, working directories, environment values, operator identity, or task output. Use the Baize console for complete audit details and output.

## Task Metadata Requirements

Every remote task should make it clear in the audit trail who did what, when, why, and on which servers. An AI-generated task draft should include:

| Field | Requirement |
| --- | --- |
| Task title | Briefly state the scenario, target, and action, such as `Investigate Nginx port - web-01 - read-only`. Avoid titles like `test`, `temporary run`, or `fix it`. |
| Task type | State whether this is read-only diagnosis, service action, file distribution, batch command, Agent check, Agent upgrade, or another type. |
| Operator | State the requester or owner. If the AI prepares the draft, still record the real human operator. |
| Target scope | State Agent ID, Agent name, or group, plus target count. Batch tasks should also state batch size. |
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

   Check the saved session through MCP. Use the current account scope for read-only queries; confirm the operator and maintenance window only before a write operation.

2. **Confirm the target**

   Search the node list by name or business characteristics. Continue after one unique match, ask the user to choose from multiple candidates, and ask for more detail after no match. Do not create a task for an unclear target.

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

   - Access method (connected MCP or Baize console)
   - Operator
   - Target server or group
   - Confirmed target name or filter
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
- Avoid posting full logs into public chats, public tickets, or external channels.
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
Access method: <connected MCP / Baize console>
Operator: <responsible person>
Target: <server or group>
Target evidence: <selected name or filter>
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
