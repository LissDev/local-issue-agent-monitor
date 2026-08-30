[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
Import-Module (Join-Path $projectRoot 'src\IssueMonitor.Core.psm1') -Force

$script:assertions = 0
function Assert-Equal {
    param($Actual, $Expected, [string]$Because)
    $script:assertions++
    if ($Actual -ne $Expected) {
        throw "Assertion failed: $Because. Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Because)
    $script:assertions++
    if (-not $Condition) { throw "Assertion failed: $Because." }
}

function New-RawIssue {
    param(
        [int]$Number = 42,
        [string]$Title = 'Prepare monitor',
        [string[]]$Labels = @('status:ready'),
        [string]$UpdatedAt = '2026-08-30T09:00:00Z'
    )
    [pscustomobject]@{
        number = $Number; title = $Title; updated_at = $UpdatedAt; state = 'open'
        html_url = "https://github.com/example-org/example-repo/issues/$Number"
        labels = @($Labels | ForEach-Object { [pscustomobject]@{ name = $_ } })
    }
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('issue-monitor-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
$savedToken = $env:GITHUB_ISSUES_TOKEN

try {
    # Normalization and GitHub list behavior: pull requests in /issues responses are excluded.
    $env:GITHUB_ISSUES_TOKEN = 'test-token-not-printed'
    $rawIssue = New-RawIssue
    $rawPullRequest = New-RawIssue -Number 43 -Title 'A pull request'
    $rawPullRequest | Add-Member -NotePropertyName pull_request -NotePropertyValue ([pscustomobject]@{})
    $mockRequest = {
        param($Uri, $Headers, $Repository)
        [pscustomobject]@{ Items = @($rawIssue, $rawPullRequest); Headers = @{} }
    }
    $issues = @(Get-GitHubIssues -Repository 'example-org/example-repo' -InvokeRestMethodScript $mockRequest)
    Assert-Equal $issues.Count 1 'Pull requests must not be reported as Issues'
    Assert-Equal $issues[0].Number 42 'Issue number is normalized'
    Assert-Equal $issues[0].Repository 'example-org/example-repo' 'Repository is attached to normalized Issue'
    Assert-Equal ($issues[0].Labels -join ',') 'status:ready' 'Labels are normalized'

    # GitHub REST pagination follows a rel="next" URL without accessing the network.
    $script:pageRequests = 0
    $pagedRequest = {
        param($Uri, $Headers, $Repository)
        $script:pageRequests++
        if ($script:pageRequests -eq 1) {
            [pscustomobject]@{
                Items = @(New-RawIssue -Number 50)
                Headers = @{ Link = '<https://api.github.com/repos/example-org/example-repo/issues?page=2>; rel="next"' }
            }
        }
        else {
            [pscustomobject]@{ Items = @(New-RawIssue -Number 51); Headers = @{} }
        }
    }
    $pagedIssues = @(Get-GitHubIssues -Repository 'example-org/example-repo' -InvokeRestMethodScript $pagedRequest)
    Assert-Equal $script:pageRequests 2 'The next page is requested exactly once'
    Assert-Equal $pagedIssues.Count 2 'Issues from every requested page are returned'

    $emptyPollConfig = [pscustomobject]@{
        Repositories = @('example-org/example-repo'); WatchedLabels = @('status:ready'); PollIntervalSeconds = 60
    }
    $emptyPoll = Invoke-IssueMonitorPoll -Config $emptyPollConfig -StatePath (Join-Path $temporaryRoot 'empty-state.json') -InvokeRestMethodScript {
        param($Uri, $Headers, $Repository) [pscustomobject]@{ Items = @(); Headers = @{} }
    }
    Assert-Equal $emptyPoll.SuccessfulRepositoryCount 1 'An empty Issues response is a successful poll'

    # State transition: a ready Issue is announced once, then seen, then updated.
    $initialState = [pscustomobject]@{ version = 1; issues = @() }
    $first = Get-IssueMonitorEvents -Issues $issues -WatchedLabels @('status:ready') -State $initialState
    Assert-Equal $first.Events[0].Status 'ready' 'First ready Issue is announced as ready'
    $statePath = Join-Path $temporaryRoot 'state.json'
    Save-IssueMonitorState -State $first.State -Path $statePath
    $persistedState = Read-IssueMonitorState -Path $statePath
    Assert-Equal $persistedState.issues.Count 1 'State is persisted outside the repository path supplied by the caller'
    $second = Get-IssueMonitorEvents -Issues $issues -WatchedLabels @('status:ready') -State $persistedState
    Assert-Equal $second.Events[0].Status 'already-seen' 'Unchanged Issue is not announced again'
    $changedIssue = ConvertTo-MonitoredIssue -Repository 'example-org/example-repo' -Issue (New-RawIssue -UpdatedAt '2026-08-30T10:00:00Z')
    $third = Get-IssueMonitorEvents -Issues @($changedIssue) -WatchedLabels @('status:ready') -State $second.State
    Assert-Equal $third.Events[0].Status 'updated' 'Changed Issue creates an updated event'

    # Adding a watched label creates a ready event even when updated_at did not change.
    $unreadyIssue = ConvertTo-MonitoredIssue -Repository 'example-org/example-repo' -Issue (New-RawIssue -Number 44 -Labels @('triage'))
    $unreadyFirst = Get-IssueMonitorEvents -Issues @($unreadyIssue) -WatchedLabels @('status:ready') -State $initialState
    Assert-Equal $unreadyFirst.Events[0].Status 'new' 'Unwatched Issue is recorded as new'
    $nowReadyIssue = ConvertTo-MonitoredIssue -Repository 'example-org/example-repo' -Issue (New-RawIssue -Number 44 -Labels @('triage', 'status:ready'))
    $nowReady = Get-IssueMonitorEvents -Issues @($nowReadyIssue) -WatchedLabels @('status:ready') -State $unreadyFirst.State
    Assert-Equal $nowReady.Events[0].Status 'ready' 'Adding a watched label creates a ready event'

    # Invalid config fails before any network request could occur.
    $invalidConfigPath = Join-Path $temporaryRoot 'invalid.json'
    [System.IO.File]::WriteAllText($invalidConfigPath, '{"repositories":[],"watchedLabels":[]}')
    $invalidConfigFailed = $false
    try { Get-IssueMonitorConfig -Path $invalidConfigPath | Out-Null } catch { $invalidConfigFailed = $true }
    Assert-True $invalidConfigFailed 'Invalid configuration is rejected locally'

    # A missing token rejects a request before the injected HTTP seam is called.
    $env:GITHUB_ISSUES_TOKEN = ''
    $script:requestCalled = $false
    $shouldNotRun = { param($Uri, $Headers, $Repository) $script:requestCalled = $true; @() }
    $missingTokenFailed = $false
    try { Get-GitHubIssues -Repository 'example-org/example-repo' -InvokeRestMethodScript $shouldNotRun | Out-Null } catch { $missingTokenFailed = $true }
    Assert-True $missingTokenFailed 'Missing token is rejected'
    Assert-True (-not $script:requestCalled) 'Missing token does not make an HTTP request'

    # A failed repository becomes an error event, while the remaining repositories are still polled.
    $env:GITHUB_ISSUES_TOKEN = 'test-token-not-printed'
    $twoRepositoryConfig = [pscustomobject]@{
        Repositories = @('example-org/failing-repo', 'example-org/example-repo')
        WatchedLabels = @('status:ready')
        PollIntervalSeconds = 60
    }
    $mixedRequest = {
        param($Uri, $Headers, $Repository)
        if ($Repository -eq 'example-org/failing-repo') { throw 'GitHub API rate limit exceeded' }
        [pscustomobject]@{ Items = @(New-RawIssue -Number 60); Headers = @{} }
    }
    $mixedPoll = Invoke-IssueMonitorPoll -Config $twoRepositoryConfig -StatePath (Join-Path $temporaryRoot 'mixed-state.json') -InvokeRestMethodScript $mixedRequest
    Assert-Equal $mixedPoll.SuccessfulRepositoryCount 1 'Polling continues after one repository fails'
    Assert-Equal $mixedPoll.Events[0].Status 'error' 'A failed repository is reported as an error event'
    Assert-True ($mixedPoll.Events[0].Message -match 'rate limit') 'Rate-limit errors are understandable'

    # v1 launch eligibility is opt-in and requires the exact label envelope.
    $repositoryPath = Join-Path $temporaryRoot 'source-repository'
    $worktreeRoot = Join-Path $temporaryRoot 'worktrees'
    $launchStatePath = Join-Path $temporaryRoot 'external-state\launches.json'
    $enabledLaunch = [pscustomobject]@{
        Enabled = $true; WorktreeDirectory = $worktreeRoot; StatePath = $launchStatePath
        RepositoryPaths = @{ 'example-org/example-repo' = $repositoryPath }; CodexCommand = 'fake-codex'
    }
    $disabledLaunch = [pscustomobject]@{
        Enabled = $false; WorktreeDirectory = $null; StatePath = $launchStatePath
        RepositoryPaths = @{}; CodexCommand = 'fake-codex'
    }
    $launchIssue = ConvertTo-MonitoredIssue -Repository 'example-org/example-repo' -Issue (New-RawIssue -Number 77 -Title 'Safe isolated launch' -Labels @('type:feat', 'status:ready', 'agent:run'))
    Assert-Equal (Get-IssueLaunchEligibility -Issue $launchIssue -Launch $disabledLaunch).Reason 'launch-disabled' 'Disabled launch never becomes eligible'
    Assert-True (Get-IssueLaunchEligibility -Issue $launchIssue -Launch $enabledLaunch).Eligible 'The full launch label envelope is eligible'
    $missingType = ConvertTo-MonitoredIssue -Repository 'example-org/example-repo' -Issue (New-RawIssue -Number 78 -Labels @('status:ready', 'agent:run'))
    Assert-Equal (Get-IssueLaunchEligibility -Issue $missingType -Launch $enabledLaunch).Reason 'requires-exactly-one-type-label' 'A type label is mandatory'
    $twoTypes = ConvertTo-MonitoredIssue -Repository 'example-org/example-repo' -Issue (New-RawIssue -Number 79 -Labels @('type:feat', 'type:fix', 'status:ready', 'agent:run'))
    Assert-Equal (Get-IssueLaunchEligibility -Issue $twoTypes -Launch $enabledLaunch).Reason 'requires-exactly-one-type-label' 'Two type labels are rejected'
    Assert-Equal (New-IssueLaunchBranch -Type 'feat' -IssueNumber 77 -ShortName 'Safe isolated launch!') 'feat/issue-77/safe-isolated-launch' 'The branch name follows the required v1 format'

    # Every Git and filesystem operation below is an injected fake.  No real
    # repository, worktree, command, network request, or Codex process is used.
    $script:fakeGitCalls = @()
    $fakeGit = {
        param($RepositoryPath, $Arguments)
        $script:fakeGitCalls += ($Arguments -join ' ')
        if ($Arguments[0] -eq 'branch' -and $Arguments -contains '--show-current') { return @('main') }
        return @()
    }
    $fakePath = {
        param($Path, $PathType)
        if ($PathType -eq 'Any') { return $false }
        return $true
    }
    $plan = New-IssueLaunchPlan -Issue $launchIssue -Launch $enabledLaunch -TestPathScript $fakePath -GitScript $fakeGit
    Assert-True $plan.Eligible 'Preflight produces a plan without mutation'
    Assert-Equal $plan.Branch 'feat/issue-77/safe-isolated-launch' 'Preflight uses the computed branch'
    Assert-True ($plan.WorktreePath -match 'example-org-example-repo.*issue-77') 'Preflight uses a repository-scoped worktree path'
    Assert-True ($plan.Prompt -notmatch [regex]::Escape($launchIssue.Title)) 'Untrusted Issue title is excluded from the Codex prompt'
    Assert-True ($plan.Prompt -match 'Issue URL: https://github.com/example-org/example-repo/issues/77') 'Prompt contains only the canonical Issue reference'
    Assert-True ($plan.Prompt -match 'read AGENTS\.md') 'Prompt requires the agent to read repository rules before edits'
    $worktree = New-IssueLaunchWorktree -Plan $plan -Launch $enabledLaunch -TestPathScript $fakePath -GitScript $fakeGit
    Assert-True $worktree.Created 'Fake Git receives a worktree creation request only after preflight'
    Assert-True (@($script:fakeGitCalls | Where-Object { $_ -match '^worktree add -b ' }).Count -eq 1) 'Exactly one fake worktree add is issued'

    # The fake process seam stands in for codex exec --json.  It writes a JSONL
    # fixture but never starts a real child process or external executable.
    New-Item -ItemType Directory -Path $plan.WorktreePath -Force | Out-Null
    $stateDirectory = Split-Path -Path $launchStatePath -Parent
    $logPath = Join-Path $stateDirectory 'issue-77-fake.jsonl'
    $script:fakeRunnerCalls = 0
    $fakeRunner = {
        param($Prompt, $LogPath, $StateDirectory, $WorkingDirectory, $CodexCommand)
        $script:fakeRunnerCalls++
        $script:fakeRunnerWorkingDirectory = $WorkingDirectory
        if (-not (Test-Path -LiteralPath $StateDirectory)) { New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null }
        [IO.File]::WriteAllText($LogPath, '{"type":"completed","message":"token=[redacted]"}')
        [pscustomobject]@{ Id = 867; RunnerPath = 'fake-runner.ps1'; LogPath = $LogPath; StartedAt = [DateTimeOffset]::Parse('2026-08-30T12:00:00Z') }
    }
    $fakeProcess = Start-IssueLaunchProcess -Prompt $plan.Prompt -LogPath $logPath -StateDirectory $stateDirectory -WorkingDirectory $plan.WorktreePath -CodexCommand 'fake-codex' -StartProcessScript $fakeRunner
    Assert-Equal $script:fakeRunnerCalls 1 'The injected fake runner is used exactly once'
    Assert-Equal $fakeProcess.Id 867 'Fake runner supplies the tracked PID'
    Assert-Equal $script:fakeRunnerWorkingDirectory $plan.WorktreePath 'The fake runner is confined to the newly created worktree'
    $coreSource = Get-Content -LiteralPath (Join-Path $projectRoot 'src\IssueMonitor.Core.psm1') -Raw
    Assert-True ($coreSource -match 'function Protect-LaunchLogLine') 'The generated runner redacts credential-shaped JSONL values before writing its external log'
    $metadata = New-IssueLaunchMetadata -Plan $plan -ProcessId $fakeProcess.Id -LogPath $fakeProcess.LogPath -ProcessStartedAt $fakeProcess.StartedAt
    Assert-Equal $metadata.status 'running' 'New process metadata starts as running'
    Assert-Equal $metadata.pid 867 'New process metadata stores the concrete PID'
    $launchState = [pscustomobject]@{ version = 1; launches = @($metadata) }
    Save-IssueLaunchState -State $launchState -Path $launchStatePath
    $loadedLaunchState = Read-IssueLaunchState -Path $launchStatePath
    Assert-Equal @(Find-IssueLaunchMetadata -State $loadedLaunchState -Repository 'example-org/example-repo' -IssueNumber 77).Count 1 'A tracked Issue is deduplicated by repository and number'
    $reconciledAlive = Reconcile-IssueLaunchState -State $loadedLaunchState -ProcessIsAliveScript { param($ProcessId, $ProcessStartedAt) $ProcessId -eq 867 -and $ProcessStartedAt -eq '2026-08-30T12:00:00.0000000+00:00' }
    Assert-True (-not $reconciledAlive.Changed) 'A live fake PID remains running'
    $reconciledMissing = Reconcile-IssueLaunchState -State $loadedLaunchState -ProcessIsAliveScript { param($ProcessId, $ProcessStartedAt) $false }
    Assert-True $reconciledMissing.Changed 'A missing PID is recorded as interrupted and never restarted'
    Assert-Equal $reconciledMissing.State.launches[0].status 'interrupted' 'Missing PID transition is interrupted'

    # Agent label writes are isolated behind a seam and are skipped for disabled
    # launch and plan-only mode.
    $script:labelCalls = 0
    $fakeLabel = { param($Repository, $IssueNumber, $RemoveLabel, $AddLabel) $script:labelCalls++; $script:lastRemovedLabel = $RemoveLabel; $script:lastAddedLabel = $AddLabel }
    $whatIfLabel = Request-IssueLaunchAgentLabel -Issue $launchIssue -Launch $enabledLaunch -Status 'running' -WhatIf -LabelRequestScript $fakeLabel
    Assert-Equal $whatIfLabel.Reason 'what-if' 'WhatIf does not call the GitHub label seam'
    Assert-Equal $script:labelCalls 0 'No label write occurs in WhatIf'
    $disabledLabel = Request-IssueLaunchAgentLabel -Issue $launchIssue -Launch $disabledLaunch -Status 'running' -LabelRequestScript $fakeLabel
    Assert-Equal $disabledLabel.Reason 'launch-disabled' 'Disabled launch does not call the GitHub label seam'
    $actualLabel = Request-IssueLaunchAgentLabel -Issue $launchIssue -Launch $enabledLaunch -Status 'running' -LabelRequestScript $fakeLabel
    Assert-True $actualLabel.Requested 'Enabled launch invokes only the injected label seam'
    Assert-Equal $script:labelCalls 1 'The fake label seam is called once after the fake start'
    Assert-Equal $script:lastRemovedLabel 'agent:run' 'The initial transition removes only agent:run'
    Assert-Equal $script:lastAddedLabel 'agent:running' 'The initial transition adds agent:running'
    Request-IssueLaunchAgentLabel -Issue $launchIssue -Launch $enabledLaunch -Status 'done' -LabelRequestScript $fakeLabel | Out-Null
    Assert-Equal $script:lastRemovedLabel 'agent:running' 'A terminal transition replaces agent:running'
    Assert-Equal $script:lastAddedLabel 'agent:done' 'A terminal transition adds only agent:done'

    # The real Git fixture is entirely under the temporary test directory.  It
    # verifies that a clean local repository receives a genuinely isolated
    # worktree while the runner remains fake.
    $gitFixturePath = Join-Path $temporaryRoot 'git-fixture'
    $gitFixtureWorktrees = Join-Path $temporaryRoot 'git-fixture-worktrees'
    $gitFixtureState = Join-Path $temporaryRoot 'git-fixture-state\launches.json'
    New-Item -ItemType Directory -Path $gitFixturePath -Force | Out-Null
    & git init --quiet $gitFixturePath
    & git -C $gitFixturePath config user.email 'fixture@example.invalid'
    & git -C $gitFixturePath config user.name 'Issue Monitor Fixture'
    [IO.File]::WriteAllText((Join-Path $gitFixturePath 'README.md'), 'fixture')
    & git -C $gitFixturePath add README.md
    & git -C $gitFixturePath commit --quiet -m 'fixture'
    New-Item -ItemType Directory -Path $gitFixtureWorktrees -Force | Out-Null
    $fixtureLaunch = [pscustomobject]@{ Enabled = $true; WorktreeDirectory = $gitFixtureWorktrees; StatePath = $gitFixtureState; RepositoryPaths = @{ 'example-org/example-repo' = $gitFixturePath }; CodexCommand = 'fake-codex' }
    $fixturePlan = New-IssueLaunchPlan -Issue $launchIssue -Launch $fixtureLaunch
    $fixtureWorktree = New-IssueLaunchWorktree -Plan $fixturePlan -Launch $fixtureLaunch
    Assert-True $fixtureWorktree.Created 'A disposable local Git repository gets an isolated worktree'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixtureWorktree.Path '.git')) 'The disposable worktree is a Git checkout'
    Assert-Equal (& git -C $fixtureWorktree.Path branch --show-current) $fixturePlan.Branch 'The disposable worktree uses the exact computed branch'

    $readOnlyStatePath = Join-Path $temporaryRoot 'read-only-poll.json'
    Invoke-IssueMonitorPoll -Config $emptyPollConfig -StatePath $readOnlyStatePath -DoNotSaveState -InvokeRestMethodScript {
        param($Uri, $Headers, $Repository) [pscustomobject]@{ Items = @(New-RawIssue -Number 80); Headers = @{} }
    } | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $readOnlyStatePath)) 'A successful read-only poll writes no normal monitor state'

    # Source the CLI against a disabled test configuration.  The invocation has
    # no token, performs no network call, and proves its WhatIf path does not
    # create a worktree, launch state, or child process.  Its JSONL renderer is
    # then checked for terminal states and secret redaction.
    $cliConfigPath = Join-Path $temporaryRoot 'cli-disabled.json'
    $cliStatePath = Join-Path $temporaryRoot 'cli-no-write\launches.json'
    $cliConfig = [pscustomobject]@{
        repositories = @('example-org/example-repo'); pollIntervalSeconds = 60; watchedLabels = @('status:ready')
        launch = [pscustomobject]@{ enabled = $false; worktreeDirectory = (Join-Path $temporaryRoot 'cli-no-write\worktrees'); statePath = $cliStatePath; codexCommand = 'fake-codex'; repositoryPaths = @{} }
    }
    [IO.File]::WriteAllText($cliConfigPath, ($cliConfig | ConvertTo-Json -Depth 5))
    $env:GITHUB_ISSUES_TOKEN = ''
    . (Join-Path $projectRoot 'Invoke-IssueMonitor.ps1') -ConfigPath $cliConfigPath -WhatIf
    Assert-True (-not (Test-Path -LiteralPath (Split-Path -Path $cliStatePath -Parent))) 'CLI WhatIf with disabled launch creates no launch-state directory'
    $jsonlFixture = Join-Path $temporaryRoot 'render.jsonl'
    [IO.File]::WriteAllText($jsonlFixture, "{`"type`":`"needs-human`",`"message`":`"Authorization: Bearer github_pat_secret_value`"}")
    $rendered = Get-LaunchJsonlStatus -Launch ([pscustomobject]@{ status = 'running'; logPath = $jsonlFixture })
    Assert-Equal $rendered.Status 'needs-human' 'JSONL maps a human intervention event to needs-human'
    Assert-True ($rendered.Detail -notmatch 'github_pat_secret_value') 'JSONL credentials are redacted before display'
    [IO.File]::WriteAllText($jsonlFixture, '{"type":"completed"}')
    Assert-Equal (Get-LaunchJsonlStatus -Launch ([pscustomobject]@{ status = 'running'; logPath = $jsonlFixture })).Status 'done' 'JSONL completion maps to done'
    [IO.File]::WriteAllText($jsonlFixture, '{"error":"failed"}')
    Assert-Equal (Get-LaunchJsonlStatus -Launch ([pscustomobject]@{ status = 'running'; logPath = $jsonlFixture })).Status 'failed' 'JSONL errors map to failed'

    Write-Host "PASS: $script:assertions assertions succeeded (no network requests)."
}
finally {
    $env:GITHUB_ISSUES_TOKEN = $savedToken
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
