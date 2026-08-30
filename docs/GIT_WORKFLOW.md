# Git workflow

Для каждой задачи создавайте отдельный GitHub Issue, ветку и worktree.

Формат имени ветки: `<type>/issue-<number>/<short-name>` (например,
`feat/issue-42/issue-monitor`).

Коммит создаётся только когда его явно запросили. `git push` никогда не
выполняется без отдельного явного запроса.
