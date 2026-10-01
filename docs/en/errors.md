# Error Messages and What to Do

[Back to README](../../README.en.md)

When an operation fails in the Baize console, MCP, or API, Baize tells you why it failed and what to do next. This page groups the messages you may see and explains what each one means and how to handle it.

## Three things to look at

1. **The message**: explains why it failed, for example "The target server is offline."
2. **The suggested action**: the next step shown with the message, for example "Confirm the target server is online and the required feature is enabled, then retry."
3. **The trace ID**: a unique number for every request. When the server hits an internal error, an administrator can use it to find the matching entry in the Baize logs.

API error responses carry the same stable reason code, suggested next step, and trace ID, so your scripts can decide how to handle each failure. MCP returns the reason code and the next step to the AI client as well.

## Sign-in and permissions

| Message | Meaning | Action |
| --- | --- | --- |
| Sign in before continuing / Your session has expired | The session is missing or expired | Sign in again. MCP users run `baize-mcp login` and then restart the AI client |
| Your account is not allowed to perform this operation | The account role lacks permission for this action | Ask an administrator to assign the right role under "Identity & Access" |
| The target resource is outside this account's authorized scope | Permission is sufficient, but the target server is outside the account's scope | Ask an administrator to adjust the account's resource scope, or use an account that covers the server |
| This feature is not available in the current entitlement | The current subscription does not include the feature | Check the entitlement under "Version & subscription" |
| Too many requests | A rate limit was triggered | Wait a moment and retry. Too many failed sign-ins temporarily lock the account; see [Admin Password and Security Code Reset](credential-reset.md) |

## Forms and submissions

| Message | Meaning | Action |
| --- | --- | --- |
| The request parameters are invalid | The submitted content does not meet the requirements | Check required fields and value ranges |
| The required field "name" is missing (new version) | Names the missing field | Fill it in and retry |
| "name" must not exceed N / must be one of (new version) | Names the invalid field and the rule | Correct the field as described |
| The submitted data is not in a valid format (new version) | The request could not be parsed, usually because the page is outdated | Refresh the page and retry; for API calls, check that the body is valid JSON |
| The target resource does not exist or has been deleted | The record was deleted or the ID is wrong | Refresh the list to confirm |
| The current resource state does not allow this operation | The object's state changed, for example the task has finished or the plan was already executed | Refresh to see the latest state before deciding what to do |

Messages marked "new version" are available in upcoming Baize releases. Earlier releases show these problems as "The request parameters are invalid."

## Servers and Agents

| Message | Meaning | Action |
| --- | --- | --- |
| The target server is offline | The Agent is not connected to Baize | Check the online status in the server list; for offline diagnosis see [Agent Options and Troubleshooting](agent.md#node-never-connects) |
| The server connection is temporarily unavailable | The connection to the Agent dropped briefly | Retry later; if it persists, check the server's network |
| The server component version does not support this feature | The Agent version is too old for this feature | Upgrade the Agent from the server detail page |
| The operation timed out | The Agent did not return a result in time | Check the task or operation record to see whether it already took effect before retrying |

## Remote tasks and commands

| Message | Meaning | Action |
| --- | --- | --- |
| Direct custom commands are disabled by policy | Running custom commands directly is not enabled | Use a command template or a regular remote task; to enable it, the system owner adjusts the policy under "System settings" |
| The command is not registered in the direct-execution allowlist | The policy is in allowlist mode and the command is not registered | Register the command, or use a command template or a regular remote task |
| The current resource state does not allow this operation (remote tasks) | Common when cancelling a finished task, a high-risk operation lacks risk confirmation, or the previous batch has not finished | Check the task state first; confirm the risk explicitly for high-risk operations; for batch tasks, wait for the previous batch or cancel stuck targets |
| A new task fails immediately with no output | The concurrency quota is taken by unfinished tasks | Cancel the stuck tasks and retry once |

For confirmation and risk boundaries of remote tasks, see the [AI Access and Remote Tasks Guide](ai-remote-tasks.md).

## Sites and protection

| Message | Meaning | Action |
| --- | --- | --- |
| Site protection is turned off globally | While off, you can only view, disable, or roll back | Turn on the global switch on the site protection page before changing rules |
| The previous configuration is being restored | The last rule application failed and is being rolled back automatically | Wait for the recovery task to finish and review its result |
| The target server has reached its safe pending-task limit | Too many protection tasks are queued on that server | Wait for existing tasks to finish before submitting more |
| The platform cannot confirm which Nginx config entry owns this site | The domain may map to more than one Nginx setup, so Baize keeps it read-only to avoid wrong changes | Refresh configuration discovery on the site configuration page and select again |
| The site configuration has changed. Refresh it and regenerate the draft | The configuration on the server changed after the draft was created | Refresh and regenerate the draft |
| The configuration check has not passed or has not completed | The pre-publish `nginx -t` check did not pass | Review the check result, fix it, and check again |
| The pre-publish backup is missing or failed | Publishing requires a backup that can be rolled back | Create a backup first |
| A configuration publish is already running for this site service | Another publish has not finished | Wait for it to finish |

## Subscription and activation

| Message | Meaning | Action |
| --- | --- | --- |
| The activation code is invalid / expired / revoked / already used | The activation code cannot be used | Check or regenerate the code in the official authorization center |
| The authorization center is temporarily unreachable | The server cannot reach the authorization center | Make sure the server's outbound network can reach it, then retry |
| This request failed the authorization center signature check | Usually caused by server clock drift | Sync the server time (NTP) and retry |
| The license quota for the current subscription is exhausted | Seats or nodes reached the limit | Adjust the subscription or contact the authorization center administrator |

## The service is temporarily unavailable

"The service is temporarily unavailable. Try again later." means the Baize server hit an internal error:

1. Retry once later.
2. If it still fails, search the server log by trace ID in the Baize install directory (in upcoming releases the server records the detailed cause for these errors):

   ```bash
   docker compose logs --tail=500 server | grep <trace-id>
   ```

3. If the log does not help, report the trace ID, the steps you took, and the time it happened through the channels below.

## Still stuck

- For deployment, upgrade, and console access issues, see [Troubleshooting](troubleshooting.md).
- Open an issue: <https://github.com/ysfl/baize/issues>
- Join the Discord community: <https://discord.gg/UMR7mnZFqh>
- Join the Telegram community: <https://t.me/+y3n_66PfRSw0ZDRl>

## Related docs

- [Agent Options and Troubleshooting](agent.md)
- [Console Guide](console.md)
- [AI Access and Remote Tasks Guide](ai-remote-tasks.md)
- [Troubleshooting](troubleshooting.md)
