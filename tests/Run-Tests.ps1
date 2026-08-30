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

    Write-Host "PASS: $script:assertions assertions succeeded (no network requests)."
}
finally {
    $env:GITHUB_ISSUES_TOKEN = $savedToken
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
