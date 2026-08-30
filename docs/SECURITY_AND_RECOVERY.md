# Security, logs, and recovery

## Credentials and Codex sign-in

The monitor reads its GitHub token only from the Generic Credential named
`local-issue-agent-monitor/github-issues` in Windows Credential Manager. It
does not read `GITHUB_ISSUES_TOKEN`. Create it manually in **Credential
Manager** → **Windows Credentials** → **Add a generic credential**: use the
exact name above as the Internet or network address and put the fine-grained
GitHub token in **Password**. The user-name field is not used.

The credential is bound to the current Windows user. It is not a shared system
credential, so each Windows user who runs the monitor must create their own.
Do not put the token in `config.json`, the repository, a JSONL file, a command
line, a PowerShell environment variable, or a registry value. The token needs
access only to the monitored repositories and **Issues: Read and write**:
reading lists Issues, while writing changes only `agent:run` to an agent
lifecycle label after an actual launch or terminal result. If GitHub rejects
the token, its repository permissions, or required organization SSO, the
monitor prints a corrective message without printing the token.

The Codex CLI uses the existing local ChatGPT subscription sign-in.  Do not add
an OpenAI API key, API billing value, or a copied ChatGPT Desktop session to the
configuration, prompt, runner, or logs.

## What the monitor records

Normal poll state is stored at
`%LOCALAPPDATA%\local-issue-agent-monitor\state.json`.  Launch metadata is at
the configured `launch.statePath`; JSONL logs and temporary runner scripts are
next to that state file.  Keep that directory outside every configured target
repository and protect it with the normal permissions of the current Windows
user.

Launch metadata contains repository, Issue number, branch, worktree path, PID,
timestamps, baseline commit, attempt number, lifecycle status, and JSONL log
path. It intentionally contains no GitHub token or Codex authentication
material. The credential is kept only in
the monitor process while it makes GitHub requests; it is not passed to the
Codex child process. Console and JSONL summaries redact bearer values, GitHub
token-shaped strings, OpenAI-style keys, and common `Authorization`/`token`
assignments before displaying them. Treat raw JSONL as potentially sensitive
anyway: it is an external tool log and should not be shared without review.

The Codex child is launched with the `workspace-write` sandbox. It can change
files in its assigned worktree but does not receive Git metadata write access;
the watcher performs the local commit only after a `commit-request` passes its
validation gates.

## Failure and interruption

The monitor never removes branches, worktrees, runner files, JSONL, or agent
output.  If the stored PID is no longer alive, its status becomes
`interrupted`; the monitor will not restart it.  Review the saved worktree and
JSONL, then choose one of these human actions:

- continue the worktree manually if the partial result is useful;
- use `-StopIssue owner/repository#123` for an intentional interruption (it
  stops only that recorded PID); or
- preserve the existing artifacts and create a fresh Issue/request for a new
  isolated run.

`-WhatIf` is the recovery-safe inspection mode: it can calculate a plan but
does not write state, create a Git worktree, change GitHub labels, or start or
stop processes.

## Agent outcomes

The watcher sends the Issue title, body, and labels to Codex as untrusted task
data. The trusted prompt envelope requires repository rules to take priority
and tells Codex not to open GitHub in a browser for the task. The final agent
response must include one `WATCHER_OUTCOME` marker. A `commit-request` marker
lets the watcher, rather than the sandboxed agent, create the local commit. The
watcher verifies the exact recorded worktree and branch, confirms HEAD still
equals the stored launch baseline, requires a non-empty diff, and runs `git diff
--check` before staging and committing. A validation or commit failure records
`needs-human` and preserves the worktree for recovery. The watcher never pushes,
creates pull requests, merges, or makes another remote Git write. A normal exit
without the marker records `needs-human`.
An agent clarification is recognized only when a valid agent message includes
both `WATCHER_HUMAN_REQUEST:` and `WATCHER_OUTCOME: needs-human`. The watcher
sanitizes that single-line request and posts it once as an `[Agent status update]`
comment; the agent process never uses GitHub credentials or a GitHub client.
Incidental log text is not a clarification request. Explicit failure, a nonzero
child exit, and launch errors record `failed`.

## First actual launch checklist

Use a disposable test Issue first.  Verify the base repository is clean, all
configured paths are absolute and outside it, and the planned branch/worktree
shown by `-WhatIf` are new.  Confirm the local `codex` command is signed in to
the intended ChatGPT subscription.  Then enable `launch.enabled`, apply one
`type:*` label plus `status:ready` and `agent:run`, and run one monitor poll.
The expected observation is `queued` → `preflight` → `running`, then (after an
agent `commit-request`) `done`, with a GitHub label transition to
`agent:running` and then `agent:done`. The watcher may create one validated local
commit in the tracked Issue worktree; it never pushes, merges, or deletes.
