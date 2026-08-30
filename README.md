# local-issue-agent-monitor

`v1` is a local PowerShell monitor for GitHub Issues.  It can start one
isolated, headless agent CLI process when a ready Issue is explicitly marked
`agent:run`. It creates a local commit only after an explicit validated agent
request; it never pushes, opens pull requests, merges, or deletes worktrees.

It is designed for Windows users who run subscription-backed local coding
agents with an interactive sign-in, especially when their plan does not provide
API access and the agent therefore cannot be run through GitHub Actions. The
monitor keeps that agent work on the local machine while using GitHub Issues as
the explicit task queue.

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
a browser to read the Issue. The agent is launched with Codex's
`workspace-write` sandbox, so it can edit worktree files but does not receive
Git metadata write access.

## Installation and configuration

Windows PowerShell 5.1 or PowerShell 7+, Git, GitHub access, and either Codex
CLI or a configured compatible external CLI are required. No external
PowerShell modules or OpenAI API key are used.

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
Select one credential provider in `githubCredentialProvider`; credentials are
resolved only inside the monitor process. The monitor never reads
`GITHUB_ISSUES_TOKEN`.

`system-store` is the default and preserves the existing Windows Credential
Manager flow. Create a Generic Credential for the current Windows user:

1. Open **Credential Manager** → **Windows Credentials** → **Add a generic credential**.
2. Enter `local-issue-agent-monitor/github-issues` as the Internet or network address.
3. Put a fine-grained GitHub token in **Password**. The user-name field is not used by the monitor.

The Generic Credential belongs to the current Windows user; another Windows
user must create their own credential. `windows-credential-manager` is also
accepted as an explicit alias for `system-store`.

For a portable provider, select GitHub CLI instead:

```json
"githubCredentialProvider": { "type": "github-cli" }
```

Install [GitHub CLI](https://cli.github.com/) and run `gh auth login --hostname
github.com` before the first poll. The monitor runs `gh auth token --hostname
github.com` only in its own process and keeps the returned value in memory.

Limit either provider's credential to the monitored repositories. **Issues:
Read** is the minimum permission for read-only polling. **Issues: Read and
write** is required when launch processing changes `agent:*` labels or posts an
agent status comment. If GitHub reports an authorization, repository, or SSO
failure, update that selected provider credential rather than putting a token in
the configuration.

The built-in Codex runner must already be signed in with the user's ChatGPT subscription.
This monitor does not use an OpenAI API key, API billing, or a copied desktop
session.

## Runner contract

The monitor lifecycle is CLI-neutral. It asks a runner to discover its command,
launch it in the isolated worktree, deliver the trusted prompt, and append
normalized JSONL records. `launch.runner` selects either the built-in `codex`
adapter or an `external` compatible CLI. If `launch.runner` is omitted, the
monitor preserves the original behavior: it uses `launch.codexCommand` (or
`codex`) with the built-in adapter.

An external runner starts with its current directory set to the assigned
worktree. It receives no monitor GitHub token: the wrapper explicitly removes
`GITHUB_ISSUES_TOKEN`. It is responsible for any vendor-specific sign-in and
must not depend on GitHub credentials or Git metadata supplied by the monitor.
Its command and fixed arguments are configuration values; Issue text is never
interpolated into shell syntax or an executable command line.

Use this configuration for a CLI that reads the complete UTF-8 prompt on
standard input:

```json
"runner": {
  "type": "external",
  "command": "example-agent",
  "arguments": ["run"],
  "promptTransport": "stdin"
}
```

For a CLI that expects a file, the monitor writes a distinct UTF-8 (no BOM)
prompt file in the external state directory and supplies it as a separate
argument, after the configured flag:

```json
"runner": {
  "type": "external",
  "command": "example-agent",
  "arguments": ["run"],
  "promptTransport": "file",
  "promptFileArgument": "--prompt-file"
}
```

The compatible external CLI writes ordinary activity to stdout or stderr. To
finish, it emits a standalone text line (the last valid line wins):

```text
WATCHER_OUTCOME: done
WATCHER_OUTCOME: needs-human
WATCHER_HUMAN_REQUEST: One concise, sanitized question for the Issue author.
WATCHER_OUTCOME: failed
```

`done` is normalized to the existing watcher-side `commit-request` event. The
watcher still requires process exit, the recorded worktree and branch, an
unchanged baseline commit, a non-empty diff, and `git diff --check` before it
creates the local commit and records `done`. `needs-human` may include one
single-line `WATCHER_HUMAN_REQUEST`; `failed` and a nonzero CLI exit both record
`failed`. Exit code zero without a valid terminal line records `needs-human`.

Configuration rejects an unknown runner type, an empty command, non-string
arguments, unsupported prompt transport, or a missing file flag before the
monitor calculates a launch plan, creates a worktree, or starts a process.

Each record has `version: 1`, `type: "watcher-agent-event"`, and one of these
event values: `activity` (a redacted `message`), `outcome` (a terminal
`outcome`, optional `message`, and optional `humanRequest`), or `exit` (an
`exitCode`). Launch-state processing and `-Follow` consume this normalized
shape rather than vendor event fields. The built-in Codex runner invokes
`codex exec --sandbox workspace-write --json` and sends the exact prompt over
standard input, so untrusted Issue content is never assembled into shell
syntax or a child-process command line.

## Monitor modes

Observation is the default and is read-only:

```powershell
.\Invoke-IssueMonitor.ps1
# equivalent to: .\Invoke-IssueMonitor.ps1 -Follow
```

`-Follow` requires an already active watcher for the same configuration. It
shows the watcher's PID, last heartbeat, configuration, tracked launch state,
and only JSONL events appended after Follow started. It never polls GitHub,
creates a worktree, changes launch state or Issue labels, or starts/stops a
process. If the heartbeat is absent, stale, or belongs to a different process,
Follow reports that there is nothing to observe and exits; it never starts a
watcher automatically.

All console timestamps use the local time zone of the machine running the
monitor and include a numeric offset (for example, `2026-08-30 12:00:00 +03:00`).
This includes normal poll rows, Watch and Follow snapshots, notices, and agent
activity rows. Heartbeats, launch state, JSONL records, and GitHub timestamps
remain persisted in UTC.

Continuous polling is explicit:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-IssueMonitor.ps1 -Watch
```

`-Watch` publishes an identity-verified heartbeat next to `launch.statePath`.
Only one Watch instance can own a configuration at a time; a second invocation
exits before polling and suggests `-Follow`.

Run one explicit poll only when no watcher is active:

```powershell
.\Invoke-IssueMonitor.ps1 -Once
```

When an active watcher owns the configuration, `-Once` exits without polling
or changing anything and suggests `-Follow` instead.

Review a no-change plan before enabling or starting anything:

```powershell
.\Invoke-IssueMonitor.ps1 -ConfigPath C:\secure\issue-monitor.json -Once -WhatIf
```

`-WhatIf` may read the configured GitHub Issues and local Git state to calculate
the branch and worktree plan, but it never changes GitHub, creates a worktree,
writes launch metadata, or starts/stops a process. Its output includes the
computed branch, worktree path, and configured runner command shape.

To stop one concrete tracked launch without deleting anything:

```powershell
.\Invoke-IssueMonitor.ps1 -StopIssue example-org/example-repo#42
```

This stops only the stored PID and records `interrupted`; it preserves the
branch, worktree, logs, and agent result for human recovery.  Add `-WhatIf` to
print the target without stopping it.

## Statuses and recovery

The console shows normal Issue rows plus launch statuses: `queued`, `preflight`,
`running`, `needs-human`, `done`, `failed`, and `interrupted`. Normalized JSONL
written by the runner is stored in the external state directory and summarized
without printing credentials. A process that has disappeared becomes `interrupted`; it is never
restarted automatically.  Inspect the preserved worktree and log, then decide
whether to continue manually or create a new Issue/launch request.

After a pull request has been merged and its Issue closed, the integration
coordinator should remove the now-unused local worktree and branch. Verify the
merged PR, closed Issue, exited process, and clean worktree first. This cleanup
is deliberately not performed by the agent or watcher, so a failed,
needs-human, or unmerged result remains recoverable.

On a successful actual start the monitor changes `agent:run` to `agent:running`.
The agent must finish its response with exactly one marker:
`WATCHER_OUTCOME: commit-request`, `WATCHER_OUTCOME: needs-human`, or
`WATCHER_OUTCOME: failed`. A `commit-request` tells the watcher to validate the
exact recorded worktree, expected branch, unchanged launch baseline, non-empty
diff, and `git diff --check`; only then does it stage all changes and create one
local commit. Validation or commit failure becomes `agent:needs-human` with a
recoverable diagnostic. The watcher never pushes, opens pull requests, merges,
or performs other remote Git writes. A clarification request or normal exit
without a valid marker becomes `agent:needs-human`; an explicit `failed` marker,
nonzero Codex exit, or launch error becomes `agent:failed`. A GitHub label
failure is reported but does not stop or delete the local process.

An agent that needs a decision must put one sanitized
`WATCHER_HUMAN_REQUEST: <question>` line before
`WATCHER_OUTCOME: needs-human`. The agent never receives the Issue token or
posts directly to GitHub. On that explicit outcome, the watcher adds exactly one
`[Agent status update]` Issue comment saying that the text was prepared by the
agent and published by the watcher. Incidental activity text mentioning
`needs-human` does not change the launch status or create a comment.

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

The tests use no network, no Pester, and no real Codex or vendor process; fake
runners emit JSONL through the Core seam and a disposable fake external
executable exercises both prompt transports. They create disposable local Git
fixtures to exercise watcher-side commits. Credential Manager and GitHub
requests are also replaced by offline test seams.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```
