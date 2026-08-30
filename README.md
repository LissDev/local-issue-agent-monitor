# local-issue-agent-monitor

`v1` is a local PowerShell monitor for GitHub Issues.  It can start one
isolated, headless Codex CLI process when a ready Issue is explicitly marked
`agent:run`.  The monitor creates no commits, pushes, pull requests, merges, or
worktree deletions.

## Safety envelope

A launch is permitted only when all of these are true:

- `launch.enabled` is `true` in the local (ignored) configuration;
- the Issue has exactly one `type:*` label, plus `status:ready` and `agent:run`;
- the configured local repository is clean and on a branch;
- the calculated branch does not already exist; and
- the calculated worktree path does not exist or belong to Git already.

The first branch is `<type>/issue-<number>/<short-name>`. Each launch gets a
new worktree below `launch.worktreeDirectory`; an existing branch or worktree is
never reused, overwritten, or removed. A deliberate re-addition of `agent:run`
after `agent:done` or `agent:needs-human` creates a numbered new attempt with a
distinct branch and worktree. Issue title, body, and labels are passed directly
to the agent as untrusted task data. The prompt says that repository rules and
watcher constraints take priority, and the agent does not need to open GitHub in
a browser to read the Issue.

## Installation and configuration

Windows PowerShell 5.1 or PowerShell 7+, Git, Codex CLI, and GitHub access are
required.  No external PowerShell modules or OpenAI API key are used.

Copy the example and replace every example path with an absolute local path:

```powershell
Copy-Item .\config.example.json .\config.json
```

Keep `launch.enabled` as `false` until the plan and paths have been reviewed.
For each monitored repository, add a matching entry in
`launch.repositoryPaths`; the worktree and state paths must be outside that
repository.  The example is deliberately non-runnable until these paths are
changed.

The example configuration deliberately contains no token or credential value.
The monitor always reads one fixed Generic Credential from Windows Credential
Manager: `local-issue-agent-monitor/github-issues`. It does not read
`GITHUB_ISSUES_TOKEN`, so a new PowerShell window needs no environment setup.

Create the credential for the current Windows user before the first poll:

1. Open **Credential Manager** → **Windows Credentials** → **Add a generic credential**.
2. Enter `local-issue-agent-monitor/github-issues` as the Internet or network address.
3. Put a fine-grained GitHub token in **Password**. The user-name field is not used by the monitor.

Limit the token to the monitored repositories and grant **Issues: Read and
write**. Read access lists Issues; write access changes only the monitor's
`agent:*` labels after an actual process start or terminal result. The Generic
Credential belongs to the current Windows user; another Windows user must
create their own credential.

The Codex CLI must already be signed in with the user's ChatGPT subscription.
This monitor does not use an OpenAI API key, API billing, or a copied desktop
session.

## Monitor modes

One poll is the default:

```powershell
.\Invoke-IssueMonitor.ps1 -Once
```

Watch continuously:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-IssueMonitor.ps1 -Watch
```

Review a no-change plan before enabling or starting anything:

```powershell
.\Invoke-IssueMonitor.ps1 -ConfigPath C:\secure\issue-monitor.json -WhatIf
```

`-WhatIf` may read the configured GitHub Issues and local Git state to calculate
the branch and worktree plan, but it never changes GitHub, creates a worktree,
writes launch metadata, or starts/stops a process.  Its output includes the
computed branch, worktree path, and `codex exec --json` command shape.

To stop one concrete tracked launch without deleting anything:

```powershell
.\Invoke-IssueMonitor.ps1 -StopIssue example-org/example-repo#42
```

This stops only the stored PID and records `interrupted`; it preserves the
branch, worktree, logs, and agent result for human recovery.  Add `-WhatIf` to
print the target without stopping it.

## Statuses and recovery

The console shows normal Issue rows plus launch statuses: `queued`, `preflight`,
`running`, `needs-human`, `done`, `failed`, and `interrupted`.  JSONL emitted by
Codex is written to the external state directory and summarized without printing
credentials.  A process that has disappeared becomes `interrupted`; it is never
restarted automatically.  Inspect the preserved worktree and log, then decide
whether to continue manually or create a new Issue/launch request.

On a successful actual start the monitor changes `agent:run` to `agent:running`.
The agent must finish its response with exactly one marker:
`WATCHER_OUTCOME: done`, `WATCHER_OUTCOME: needs-human`, or
`WATCHER_OUTCOME: failed`. `agent:done` requires both the `done` marker and a
new commit relative to the branch baseline. A clarification request or a normal
exit without a valid marker becomes `agent:needs-human`; an explicit `failed`
marker, nonzero Codex exit, or launch error becomes `agent:failed`. A GitHub
label failure is reported but does not stop or delete the local process.

See [security and recovery guidance](docs/SECURITY_AND_RECOVERY.md) for token,
log, and first-run details.

## First actual launch

Do this only with a disposable, ready test Issue and a clean local repository:

1. Copy `config.example.json`, set absolute paths, and leave `launch.enabled`
   false.
2. Create the scoped read/write GitHub Generic Credential described above and
   confirm `codex` is signed in with the intended ChatGPT subscription.
3. Run `-WhatIf` and verify the displayed branch and new worktree path.
4. Change only `launch.enabled` to `true`; put exactly `type:feat`,
   `status:ready`, and `agent:run` on the test Issue.
5. Run `-Once`, observe `queued`, `preflight`, and `running`, and check that the
   Issue label became `agent:running`.
6. Keep the monitor running to observe its terminal status, or use `-StopIssue`
   for a deliberate safe interruption.

## Self-check

The tests use no network, no Pester, no real Git, and no real Codex process; a
fake runner emits JSONL through the Core seam. Credential Manager and GitHub
requests are also replaced by offline test seams.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```
