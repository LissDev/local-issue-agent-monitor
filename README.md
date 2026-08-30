# local-issue-agent-monitor

`v0` is a local PowerShell monitor for GitHub Issues in one or more
repositories. It only reads Issues through the GitHub REST API and displays
work-ready tasks. It does not start Codex, create worktrees, or run GitHub
Actions.

## Installation and configuration

Windows PowerShell 5.1 or PowerShell 7+ and access to the GitHub API are
required. No external modules are needed.

Copy the example to a local configuration file. The local file is intentionally
ignored by Git:

```powershell
Copy-Item .\config.example.json .\config.json
```

In `config.json`, list the repository or repositories to monitor in the
`repositories` array. The example already includes the `status:ready` label.
You can later add, for example, `agent:run` to `watchedLabels`.

In the same PowerShell window, set a GitHub token that can read Issues:

```powershell
$env:GITHUB_ISSUES_TOKEN = 'github_pat_...'
```

The token is stored only in the current process environment: never in the
configuration, local state, logs, or program output. Use a fine-grained token
restricted to the required repositories with only the **Issues: Read**
permission.

## Running the monitor

Run one check (the default mode):

```powershell
.\Invoke-IssueMonitor.ps1 -Once
```

Run continuously in a separate PowerShell window opened by the user:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-IssueMonitor.ps1 -Watch
```

To use a different configuration file, pass `-ConfigPath`:

```powershell
.\Invoke-IssueMonitor.ps1 -ConfigPath C:\secure\issue-monitor.json -Once
```

The output includes event time, status, repository, Issue number, type
(`issue`), labels, update time, and title. Issues carrying `status:ready` are
also marked as ready.

Local state is stored outside the repository at
`%LOCALAPPDATA%\local-issue-agent-monitor\state.json`. Therefore, an unchanged
Issue is reported as `already-seen` on a later poll; an Issue update or a newly
added watched label produces `updated` or `ready`.

## Errors and v0 limitations

If `GITHUB_ISSUES_TOKEN` is missing, JSON is invalid, or configuration fields
are invalid, the script prints an instruction without exposing the secret. In
`-Watch` mode, temporary network errors and GitHub API rate limits do not stop
monitoring: the reason and the next attempt time in UTC are displayed.

`v0` does not create worktrees, run Codex or Actions, create commits or push,
use webhooks, a Windows service, Task Scheduler, a web UI, a database, multiple
accounts, or models. Issue text is not sent anywhere other than the GitHub API
request and local console output.

## Self-check

The tests do not use the network and do not require Pester:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```
