# Console Guide

[Back to README](../../README.en.md)

The Baize console brings servers, sites, security, automation, and platform settings together in one place. This page walks through the left-hand menu, explaining what each feature does and when to use it, so you can find the right entry point quickly.

After signing in, the home page is the **Operations Overview**: it summarizes online servers, pending reminders, site access quality, and protection hits, and lets you jump straight to the page for any anomaly.

## Servers

| Menu | What it does | When to use it |
| --- | --- | --- |
| Server Management | Lists all connected servers with online status and load; the detail view shows metrics, processes, disks, containers, files, and the Agent version | Routine checks, investigating a specific machine |
| Asset Inventory | Records ownership, expiry dates, and notes for each server | Renewals and handovers |
| Disk Risks | Summarizes disk usage and growth across servers | Spot disks that are about to fill up |
| Server Groups | Groups servers by business, region, or provider | Viewing and dispatching tasks in bulk |
| Runtime Diagnosis | Runs a read-only diagnosis on a single server, such as who owns a port, process, or service | Answering "who is using this port" or "why is this service missing" |
| Service Management | Start, stop, restart, or reload systemd, Nginx, and Docker services | Controlled service restarts instead of hand-written commands |
| Resource Trends | Compares CPU, memory, disk, and network trends across servers | Telling a single-host problem from a fleet-wide one |

The server detail page also provides:

- **Process Risks**: view high-resource and suspicious processes, and end a process when needed.
- **Server Files**: browse, preview, edit, and upload files; writes and deletes require the matching permission and are audited.
- **Container Service**: view container status and resources, and follow container logs live.
- **Agent upgrade**: upgrade the node component in one click.

Removed servers go to the **Server recycle bin**, where you can restore or permanently delete them. For Agent install options and troubleshooting, see [Agent Options and Troubleshooting](agent.md).

## Sites

| Menu | What it does | When to use it |
| --- | --- | --- |
| Site Center | Discovers Nginx sites on each server and summarizes request volume, error rate, and collection status | Seeing which sites exist and which one has issues |
| Access Analysis | Shows traffic, status codes, slow requests, and sources per site | Analyzing traffic changes and finding slow requests |
| Config Release | Edit Nginx configuration online: generate a draft, compare changes, back up automatically and run `nginx -t` before publishing, and roll back on failure | Changing site configuration with a change history |

The top of the Site Center shows the health of the access data pipeline. When there is no data, check here first: "no data" does not always mean no traffic; collection may have stopped.

## Security

| Menu | What it does | When to use it |
| --- | --- | --- |
| Reminder Center | View alerts in one place, acknowledge or resolve them, and configure notification channels, contact groups, silences, and escalation rules | On-call alert handling |
| Request Risk | Identifies abnormal access patterns along request chains | Spotting scans, credential stuffing, and other suspicious requests |
| Exposed Entry Points | Finds high-risk ports and services open to the internet | Reducing unnecessary public exposure |
| Network Exposure | Maps servers' external entry points and traffic paths | Understanding who can reach your services |
| Certificates | Monitors SSL certificate expiry | Avoiding outages caused by expired certificates |
| Site Security | Site protection overview, rules, block records, protection update records, and the security dashboard | Checking whether you are under attack and whether it was blocked, and adjusting the protection mode |

Site Security supports **observe** and **block** modes. Run in observe mode for a while first, then switch to block once you have confirmed there are no false positives.

## Automation

| Menu | What it does | When to use it |
| --- | --- | --- |
| Execution Tasks | Send commands to one or more servers, with batches, staged rollout, failure retry, and saved output | One-off operations and bulk checks |
| Remote Sessions | A terminal in the browser | Ad-hoc troubleshooting; for routine changes prefer Execution Tasks, which are easier to audit and review |
| Response Playbooks | Turn common response steps into reusable playbooks | Standardizing incident response |
| Execution Plans | Create, approve, and run plans based on command templates | Changes that need approval or carry high risk |
| Scheduled Tasks | Run commands on selected servers on a schedule, one-off or recurring | Periodic checks and scheduled collection |
| Execution Records | Audit trail of all remote operations: who, when, which machine, what was run | Post-incident review |
| Run Records | Baize's own runtime logs | Troubleshooting the platform itself |

Automatic scheduling for response playbooks is off by default (`RUNBOOK_SCHEDULER_ENABLED=false` in `.env`), so playbooks are run manually. For risk confirmation and approval rules of remote tasks, see the [AI Access and Remote Tasks Guide](ai-remote-tasks.md).

## Platform

| Menu | What it does |
| --- | --- |
| System Settings | Platform-wide switches, such as the direct custom command policy and the remote plan approval switch |
| System Info | Central service status and dependent components |
| Version & Subscription | Current version, checking for and applying updates, subscription entitlements and activation |
| Access Credentials | Create and manage Agent registration tokens |
| Identity & Access | Manage accounts, roles, and resource scopes |
| AI Services | Connect AI model services for assistance such as configuration suggestions and terminal command explanations |

## When something fails

When an operation fails, the message explains the cause and the suggested next step. For what each message means and how to handle it, see [Error Messages and What to Do](errors.md).

## Related docs

- [Error Messages and What to Do](errors.md)
- [Agent Options and Troubleshooting](agent.md)
- [AI Access and Remote Tasks Guide](ai-remote-tasks.md)
- [Advanced Configuration and Operations](advanced.md)
