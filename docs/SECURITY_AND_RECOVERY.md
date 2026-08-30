# Security, logs, and recovery

## Credentials and Codex sign-in

`GITHUB_ISSUES_TOKEN` is read only from the current PowerShell process
environment.  Do not put it in `config.json`, the repository, a JSONL file, or
a command line.  The token needs **Issues: Read and write** on only the
repositories being monitored: listing Issues needs read access, while the
monitor changes only `agent:run` to an agent lifecycle label after an actual
launch or terminal result.

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
timestamps, lifecycle status, and JSONL log path.  It intentionally contains no
GitHub token or Codex authentication material.  Console and JSONL summaries
redact bearer values, GitHub token-shaped strings, OpenAI-style keys, and common
`Authorization`/`token` assignments before displaying them.  Treat raw JSONL as
potentially sensitive anyway: it is an external tool log and should not be
shared without review.

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

## First actual launch checklist

Use a disposable test Issue first.  Verify the base repository is clean, all
configured paths are absolute and outside it, and the planned branch/worktree
shown by `-WhatIf` are new.  Confirm the local `codex` command is signed in to
the intended ChatGPT subscription.  Then enable `launch.enabled`, apply one
`type:*` label plus `status:ready` and `agent:run`, and run one monitor poll.
The expected observation is `queued` → `preflight` → `running` and a GitHub
label transition to `agent:running`.  No commit, push, merge, or deletion is
performed by the monitor.
