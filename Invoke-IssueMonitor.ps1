[CmdletBinding(DefaultParameterSetName = 'Once')]
param(
    [string]$ConfigPath,
    [Parameter(ParameterSetName = 'Once')][switch]$Once,
    [Parameter(Mandatory, ParameterSetName = 'Watch')][switch]$Watch,
    [Parameter(Mandatory, ParameterSetName = 'Stop')][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*$')][string]$StopIssue,
    # Plan only: does not alter GitHub, Git, launch state, or child processes.
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
$modulePath = Join-Path $PSScriptRoot 'src\IssueMonitor.Core.psm1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "The core module was not found at '$modulePath'." }
Import-Module -Name $modulePath -Force

function Protect-MonitorText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $safe = $Text
    $safe = $safe -replace '(?i)bearer\s+[^\s"'']+', 'Bearer [redacted]'
    $safe = $safe -replace '(?i)(github_pat|gh[pousr])_[A-Za-z0-9_\-]+', '[redacted]'
    $safe = $safe -replace '(?i)sk-[A-Za-z0-9_\-]+', '[redacted]'
    $safe = $safe -replace '(?i)(authorization|token)\s*[:=]\s*[^\s,;"'']+', '$1=[redacted]'
    return $safe
}
function Write-MonitorMessage { param([Parameter(Mandatory)][string]$Message, [string]$Status = 'error'); Write-Host ('{0:u} | {1,-12} | {2}' -f [DateTimeOffset]::UtcNow, $Status, (Protect-MonitorText $Message)) }
function Get-DisplayText {
    param([AllowNull()][string]$Text, [int]$MaximumLength = 60)
    $safe = Protect-MonitorText $Text
    if ([string]::IsNullOrWhiteSpace($safe)) { return '-' }
    if ($safe.Length -le $MaximumLength) { return $safe }
    return $safe.Substring(0, $MaximumLength - 1) + '…'
}
function Write-IssueMonitorEvent {
    param([Parameter(Mandatory)]$Event)
    $time = [DateTimeOffset]::UtcNow.ToString('u')
    if ($Event.Status -eq 'error') {
        $repository = if ($Event.Repository) { $Event.Repository } else { '-' }
        Write-Host ('{0} | {1,-12} | {2,-35} | {3}' -f $time, 'error', $repository, (Protect-MonitorText $Event.Message)); return
    }
    $issue = $Event.Issue; $labels = @($issue.Labels) -join ', '
    if ([string]::IsNullOrWhiteSpace($labels)) { $labels = '-' }
    $ready = if ($Event.IsWatched) { ' READY' } else { '' }
    $format = '{0} | {1,-12} | {2,-35} | #{3,-6} | {4,-14} | {5,-28} | {6,-20} | {7}{8}'
    Write-Host ($format -f $time, $Event.Status, $issue.Repository, $issue.Number, $issue.Type, (Get-DisplayText $labels 28), $issue.UpdatedAt, (Get-DisplayText $issue.Title), $ready)
}
function Write-LaunchEvent {
    param([Parameter(Mandatory)][string]$Status, [Parameter(Mandatory)]$Issue, [string]$Message = '')
    $suffix = if ([string]::IsNullOrWhiteSpace($Message)) { '' } else { ' | ' + (Protect-MonitorText $Message) }
    Write-Host ('{0:u} | {1,-12} | {2,-35} | #{3,-6}{4}' -f [DateTimeOffset]::UtcNow, $Status, $Issue.Repository, $Issue.Number, $suffix)
}

function Get-LaunchJsonlStatus {
    param([Parameter(Mandatory)]$Launch)
    if ([string]::IsNullOrWhiteSpace([string]$Launch.logPath) -or -not (Test-Path -LiteralPath $Launch.logPath -PathType Leaf)) { return [pscustomobject]@{ Status = [string]$Launch.status; Detail = ''; HasOutcomeMarker = $false; ProcessExited = $false } }
    $marker = $null; $detail = ''; $requestedHuman = $false; $runnerExitCode = $null
    foreach ($line in @(Get-Content -LiteralPath $Launch.logPath -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        $text = [string]$line
        $agentText = ''
        try {
            $json = $text | ConvertFrom-Json -ErrorAction Stop; $parts = @()
            foreach ($name in @('type', 'event', 'status', 'message', 'error', 'output')) { if ($null -ne $json.PSObject.Properties[$name]) { $parts += [string]$json.$name } }
            if ($parts.Count -gt 0) { $text = $parts -join ' ' }
            $item = if ($null -ne $json.PSObject.Properties['item']) { $json.item } else { $null }
            if ($null -ne $item -and $null -ne $item.PSObject.Properties['type'] -and [string]$item.type -eq 'agent_message') {
                foreach ($name in @('text', 'message', 'output')) { if ($null -ne $item.PSObject.Properties[$name]) { $agentText += [string]$item.$name } }
            }
            elseif ($null -ne $json.PSObject.Properties['type'] -and [string]$json.type -eq 'agent_message') {
                foreach ($name in @('text', 'message', 'output')) { if ($null -ne $json.PSObject.Properties[$name]) { $agentText += [string]$json.$name } }
            }
            if ($null -ne $json.PSObject.Properties['type'] -and [string]$json.type -eq 'watcher-runner-exit' -and $null -ne $json.PSObject.Properties['exitCode']) {
                $parsedExitCode = 0
                if ([int]::TryParse([string]$json.exitCode, [ref]$parsedExitCode)) { $runnerExitCode = $parsedExitCode }
            }
        } catch { }
        $safeText = Protect-MonitorText $text
        $safeAgentText = Protect-MonitorText $agentText
        $matches = [regex]::Matches($safeAgentText, '(?i)WATCHER_OUTCOME\s*:\s*(done|needs-human|failed)\b')
        if ($matches.Count -gt 0) { $marker = $matches[$matches.Count - 1].Groups[1].Value.ToLowerInvariant(); $detail = $safeAgentText }
        if ($safeText -match '(?i)needs[-_ ]?human|human[-_ ]?input|approval required' -or $safeAgentText -match '(?i)need[s]? (?:a )?(?:clarification|decision|input)|please (?:clarify|provide)|question for') {
            $requestedHuman = $true; if ([string]::IsNullOrWhiteSpace($detail)) { $detail = if ([string]::IsNullOrWhiteSpace($safeAgentText)) { $safeText } else { $safeAgentText } }
        }
    }
    if ($null -ne $runnerExitCode -and $runnerExitCode -ne 0) { return [pscustomobject]@{ Status = 'failed'; Detail = (Get-DisplayText 'Codex runner exited with a nonzero status.' 120); HasOutcomeMarker = ($null -ne $marker); ProcessExited = $true } }
    if ($null -ne $marker) { return [pscustomobject]@{ Status = $marker; Detail = (Get-DisplayText $detail 120); HasOutcomeMarker = $true; ProcessExited = ($null -ne $runnerExitCode) } }
    if ($requestedHuman) { return [pscustomobject]@{ Status = 'needs-human'; Detail = (Get-DisplayText $detail 120); HasOutcomeMarker = $false; ProcessExited = ($null -ne $runnerExitCode) } }
    if ($null -ne $runnerExitCode) { return [pscustomobject]@{ Status = 'needs-human'; Detail = 'Codex exited without a valid WATCHER_OUTCOME marker.'; HasOutcomeMarker = $false; ProcessExited = $true } }
    return [pscustomobject]@{ Status = [string]$Launch.status; Detail = ''; HasOutcomeMarker = $false; ProcessExited = $false }
}

function Set-LaunchProperty {
    param([Parameter(Mandatory)]$Launch, [Parameter(Mandatory)][string]$Name, $Value)
    $property = $Launch.PSObject.Properties[$Name]
    if ($null -eq $property) { $Launch | Add-Member -NotePropertyName $Name -NotePropertyValue $Value } else { $property.Value = $Value }
}
function Invoke-LaunchLabelTransition {
    param([Parameter(Mandatory)]$Issue, [Parameter(Mandatory)]$Launch, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Status, [Parameter(Mandatory)][string]$GitHubToken)
    $labelStatusProperty = $Launch.PSObject.Properties['labelStatus']
    $currentLabelStatus = if ($null -eq $labelStatusProperty) { '' } else { [string]$labelStatusProperty.Value }
    if ($WhatIf -or -not [bool]$Config.Launch.Enabled -or $currentLabelStatus -eq $Status) { return $false }
    try {
        $previousAgentStatusProperty = $Launch.PSObject.Properties['previousAgentStatus']
        $previousAgentStatus = if ($null -eq $previousAgentStatusProperty) { '' } else { [string]$previousAgentStatusProperty.Value }
        $removeAgentStatus = if ($currentLabelStatus -eq 'running') { 'running' } elseif ($previousAgentStatus -in @('done', 'needs-human', 'failed')) { $previousAgentStatus } else { 'run' }
        Request-IssueLaunchAgentLabel -Issue $Issue -Launch $Config.Launch -Status $Status -CurrentAgentStatus $removeAgentStatus -GitHubToken $GitHubToken | Out-Null
        if ($Status -eq 'running' -and $previousAgentStatus -in @('done', 'needs-human', 'failed')) {
            # A conscious retry normally adds agent:run alongside the old terminal
            # label. Remove both lifecycle labels so this attempt has one status.
            Request-IssueLaunchAgentLabel -Issue $Issue -Launch $Config.Launch -Status $Status -CurrentAgentStatus 'run' -GitHubToken $GitHubToken | Out-Null
        }
        Set-LaunchProperty $Launch 'labelStatus' $Status; return $true
    } catch { Write-LaunchEvent 'failed' $Issue ('GitHub label update failed; local process was left untouched: ' + $_.Exception.Message); return $false }
}
function Get-TrackedIssueFromKey {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)]$State)
    $matches = @($State.launches | Where-Object { $null -ne $_ -and [string]$_.issue -eq $Key })
    if ($matches.Count -ne 1) { throw "Expected exactly one tracked launch for '$Key'; found $($matches.Count)." }
    return $matches[0]
}
function Invoke-StopTrackedIssue {
    param([Parameter(Mandatory)]$Config)
    $state = Read-IssueLaunchState -Path $Config.Launch.StatePath; $launch = Get-TrackedIssueFromKey $StopIssue $state
    $parts = $StopIssue -split '#', 2; $issue = [pscustomobject]@{ Repository = $parts[0]; Number = [int]$parts[1] }
    if ($WhatIf) { Write-LaunchEvent 'queued' $issue "WhatIf: would stop tracked PID $($launch.pid); no process or state was changed."; return }
    Stop-IssueLaunchProcess -LaunchMetadata $launch -Confirm:$false | Out-Null
    Set-LaunchProperty $launch 'status' 'interrupted'; Set-LaunchProperty $launch 'interruptedAt' ([DateTimeOffset]::UtcNow.ToString('o'))
    Save-IssueLaunchState -State $state -Path $Config.Launch.StatePath
    Write-LaunchEvent 'interrupted' $issue "Stopped only tracked PID $($launch.pid); branch, worktree, logs, and results were preserved."
}

function Invoke-LaunchMonitoring {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$PollResult, [Parameter(Mandatory)][string]$GitHubToken)
    if (-not [bool]$Config.Launch.Enabled) {
        foreach ($event in @($PollResult.Events | Where-Object { $_.Status -ne 'error' })) {
            if (@($event.Issue.Labels | Where-Object { $_ -eq 'agent:run' }).Count -gt 0) { Write-LaunchEvent 'queued' $event.Issue 'agent:run is visible, but launch.enabled is false. No local or GitHub change was made.' }
        }
        return
    }
    $state = Read-IssueLaunchState -Path $Config.Launch.StatePath; $stateChanged = $false
    $issuesByKey = @{}
    foreach ($event in @($PollResult.Events | Where-Object { $_.Status -ne 'error' })) {
        $issuesByKey[('{0}#{1}' -f $event.Issue.Repository, $event.Issue.Number)] = $event.Issue
    }
    foreach ($launch in @($state.launches)) {
        $keyIssue = [pscustomobject]@{ Repository = [string]$launch.repository; Number = [int]$launch.issueNumber }
        if ([string]$launch.status -ne 'running') {
            Write-LaunchEvent ([string]$launch.status) $keyIssue 'tracked launch'
            if ([string]$launch.status -in @('done', 'needs-human', 'failed')) {
                $labelStatusProperty = $launch.PSObject.Properties['labelStatus']
                $currentLabelStatus = if ($null -eq $labelStatusProperty) { '' } else { [string]$labelStatusProperty.Value }
                $currentIssue = $issuesByKey[([string]$launch.issue)]
                $isExplicitRetry = $null -ne $currentIssue -and @($currentIssue.Labels | Where-Object { $_ -eq 'agent:run' }).Count -gt 0 -and ([string]$launch.status -in @('done', 'needs-human'))
                if ($currentLabelStatus -ne [string]$launch.status -and -not $isExplicitRetry) {
                    if (Invoke-LaunchLabelTransition $keyIssue $launch $Config ([string]$launch.status) $GitHubToken) { $stateChanged = $true }
                }
            }
            continue
        }
        $labelStatusProperty = $launch.PSObject.Properties['labelStatus']
        $currentLabelStatus = if ($null -eq $labelStatusProperty) { '' } else { [string]$labelStatusProperty.Value }
        if ($currentLabelStatus -ne 'running') {
            if (Invoke-LaunchLabelTransition $keyIssue $launch $Config 'running' $GitHubToken) { $stateChanged = $true }
        }
        $jsonl = Get-LaunchJsonlStatus $launch
        if ($jsonl.Status -ne 'running') {
            $terminalStatus = [string]$jsonl.Status
            $terminalDetail = [string]$jsonl.Detail
            if ($terminalStatus -eq 'done') {
                $commitCheck = Test-IssueLaunchHasNewCommit -LaunchMetadata $launch
                if (-not $commitCheck.HasNewCommit) { $terminalStatus = 'needs-human'; $terminalDetail = $commitCheck.Message }
            }
            Set-LaunchProperty $launch 'status' $terminalStatus; $stateChanged = $true; Write-LaunchEvent $terminalStatus $keyIssue $terminalDetail
            if ($terminalStatus -in @('done', 'needs-human', 'failed')) { if (Invoke-LaunchLabelTransition $keyIssue $launch $Config $terminalStatus $GitHubToken) { $stateChanged = $true } }
        }
    }
    # A completed child can disappear before the next poll.  Parse its JSONL
    # first; only runs with no terminal event are eligible for interruption.
    $reconciled = Reconcile-IssueLaunchState -State $state
    $state = $reconciled.State
    $stateChanged = $stateChanged -or [bool]$reconciled.Changed
    foreach ($launch in @($state.launches | Where-Object { [string]$_.status -eq 'running' })) {
        $keyIssue = [pscustomobject]@{ Repository = [string]$launch.repository; Number = [int]$launch.issueNumber }
        Write-LaunchEvent 'running' $keyIssue ('PID ' + $launch.pid)
    }
    foreach ($launch in @($state.launches | Where-Object { [string]$_.status -eq 'interrupted' })) {
        $keyIssue = [pscustomobject]@{ Repository = [string]$launch.repository; Number = [int]$launch.issueNumber }
        Write-LaunchEvent 'interrupted' $keyIssue 'PID is no longer identity-verified. The monitor will not restart it; choose recovery manually.'
    }
    if ($stateChanged -and -not $WhatIf) { Save-IssueLaunchState -State $state -Path $Config.Launch.StatePath }
    foreach ($event in @($PollResult.Events | Where-Object { $_.Status -ne 'error' })) {
        $issue = $event.Issue; $known = @(Find-IssueLaunchMetadata -State $state -Repository $issue.Repository -IssueNumber $issue.Number)
        if (@($known | Where-Object { [string]$_.status -eq 'running' }).Count -gt 0) { continue }
        $eligibility = Get-IssueLaunchEligibility -Issue $issue -Launch $Config.Launch
        if (-not $eligibility.Eligible) { continue }
        Write-LaunchEvent 'queued' $issue 'agent:run is eligible.'
        try {
            Write-LaunchEvent 'preflight' $issue 'Checking branch, base repository, and isolated worktree path.'
            $plan = New-IssueLaunchPlan -Issue $issue -Launch $Config.Launch -PriorLaunches $known
            if ($WhatIf) { Write-LaunchEvent 'preflight' $issue ("WhatIf plan: branch={0}; worktree={1}; command={2} exec --json" -f $plan.Branch, $plan.WorktreePath, $Config.Launch.CodexCommand); continue }
            if ($null -eq (Get-Command -Name $Config.Launch.CodexCommand -ErrorAction SilentlyContinue)) { throw "Configured Codex command '$($Config.Launch.CodexCommand)' was not found. No worktree was created." }
            New-IssueLaunchWorktree -Plan $plan -Launch $Config.Launch | Out-Null
            $stateDirectory = Split-Path -Path $Config.Launch.StatePath -Parent; $logPath = Join-Path $stateDirectory ('issue-{0}-{1}.jsonl' -f $issue.Number, [Guid]::NewGuid().ToString('N'))
            $process = Start-IssueLaunchProcess -Prompt $plan.Prompt -LogPath $logPath -StateDirectory $stateDirectory -WorkingDirectory $plan.WorktreePath -CodexCommand $Config.Launch.CodexCommand
            $metadata = New-IssueLaunchMetadata -Plan $plan -ProcessId $process.Id -LogPath $process.LogPath -ProcessStartedAt $process.StartedAt; Set-LaunchProperty $metadata 'runnerPath' $process.RunnerPath
            $priorAgentStatus = @($issue.Labels | Where-Object { $_ -in @('agent:done', 'agent:needs-human', 'agent:failed') } | Select-Object -First 1)
            if ($priorAgentStatus.Count -gt 0) { Set-LaunchProperty $metadata 'previousAgentStatus' ([string]$priorAgentStatus[0]).Substring(6) }
            $state.launches = @($state.launches) + @($metadata); Save-IssueLaunchState -State $state -Path $Config.Launch.StatePath
            Write-LaunchEvent 'running' $issue ('Started tracked PID ' + $metadata.pid + '.')
            [void](Invoke-LaunchLabelTransition $issue $metadata $Config 'running' $GitHubToken); Save-IssueLaunchState -State $state -Path $Config.Launch.StatePath
        } catch {
            $launchFailure = $_.Exception.Message
            Write-LaunchEvent 'failed' $issue $launchFailure
            if (-not $WhatIf) {
                try { Request-IssueLaunchAgentLabel -Issue $issue -Launch $Config.Launch -Status 'failed' -CurrentAgentStatus 'run' -GitHubToken $GitHubToken | Out-Null }
                catch { Write-LaunchEvent 'failed' $issue ('GitHub failure label update failed: ' + $_.Exception.Message) }
            }
        }
    }
}
function Invoke-MonitorIteration {
    param([scriptblock]$CredentialReadScript)
    try { $config = Get-IssueMonitorConfig -Path $ConfigPath } catch { Write-MonitorMessage $_.Exception.Message; return [pscustomobject]@{ PollIntervalSeconds = 60; Succeeded = $false } }
    if ($PSCmdlet.ParameterSetName -eq 'Stop') {
        try { Invoke-StopTrackedIssue $config; return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $true } } catch { Write-MonitorMessage $_.Exception.Message; return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $false } }
    }
    try {
        $gitHubToken = Get-GitHubIssuesToken -CredentialReadScript $CredentialReadScript
        $noStateWrite = [bool]$WhatIf -or -not [bool]$config.Launch.Enabled
        $result = Invoke-IssueMonitorPoll -Config $config -GitHubToken $gitHubToken -DoNotSaveState:$noStateWrite; foreach ($event in @($result.Events)) { Write-IssueMonitorEvent $event }; Invoke-LaunchMonitoring $config $result $gitHubToken
        if ($result.SuccessfulRepositoryCount -eq 0) { Write-MonitorMessage 'No repository could be checked. Review the error rows above; local state was not changed.'; return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $false } }
        return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $true }
    } catch { Write-MonitorMessage $_.Exception.Message; return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $false } }
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Watch) { [void](Invoke-MonitorIteration); return }
Write-Host 'local-issue-agent-monitor v1 is watching. Press Ctrl+C to stop.'
while ($true) { $iteration = Invoke-MonitorIteration; Write-Host ('Next attempt UTC: {0:u}' -f [DateTimeOffset]::UtcNow.AddSeconds($iteration.PollIntervalSeconds)); Start-Sleep -Seconds $iteration.PollIntervalSeconds }
