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

# Watch mode collects the normal lifecycle messages during a poll, then renders
# them as part of one refreshed snapshot.  One-off and Stop modes keep their
# existing line-oriented output.
$script:IsActivityMonitor = [bool]$Watch
$script:ActivityMonitorNotices = [System.Collections.Generic.List[string]]::new()

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
function Add-ActivityMonitorNotice {
    param([Parameter(Mandatory)][string]$Message)
    if ($script:IsActivityMonitor) { [void]$script:ActivityMonitorNotices.Add((Protect-MonitorText $Message)) }
}
function Write-MonitorMessage {
    param([Parameter(Mandatory)][string]$Message, [string]$Status = 'error')
    $line = '{0:u} | {1,-12} | {2}' -f [DateTimeOffset]::UtcNow, $Status, (Protect-MonitorText $Message)
    if ($script:IsActivityMonitor) { Add-ActivityMonitorNotice $line; return }
    Write-Host $line
}
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
        $line = '{0} | {1,-12} | {2,-35} | {3}' -f $time, 'error', $repository, (Protect-MonitorText $Event.Message)
        if ($script:IsActivityMonitor) { Add-ActivityMonitorNotice $line } else { Write-Host $line }; return
    }
    $issue = $Event.Issue; $labels = @($issue.Labels) -join ', '
    if ([string]::IsNullOrWhiteSpace($labels)) { $labels = '-' }
    $ready = if ($Event.IsWatched) { ' READY' } else { '' }
    $format = '{0} | {1,-12} | {2,-35} | #{3,-6} | {4,-14} | {5,-28} | {6,-20} | {7}{8}'
    $line = $format -f $time, $Event.Status, $issue.Repository, $issue.Number, $issue.Type, (Get-DisplayText $labels 28), $issue.UpdatedAt, (Get-DisplayText $issue.Title), $ready
    if ($script:IsActivityMonitor) { Add-ActivityMonitorNotice $line } else { Write-Host $line }
}
function Write-LaunchEvent {
    param([Parameter(Mandatory)][string]$Status, [Parameter(Mandatory)]$Issue, [string]$Message = '')
    $suffix = if ([string]::IsNullOrWhiteSpace($Message)) { '' } else { ' | ' + (Protect-MonitorText $Message) }
    $line = '{0:u} | {1,-12} | {2,-35} | #{3,-6}{4}' -f [DateTimeOffset]::UtcNow, $Status, $Issue.Repository, $Issue.Number, $suffix
    if ($script:IsActivityMonitor) { Add-ActivityMonitorNotice $line } else { Write-Host $line }
}

function Get-LaunchJsonlStatus {
    param([Parameter(Mandatory)]$Launch)
    if ([string]::IsNullOrWhiteSpace([string]$Launch.logPath) -or -not (Test-Path -LiteralPath $Launch.logPath -PathType Leaf)) { return [pscustomobject]@{ Status = [string]$Launch.status; Detail = ''; Activity = ''; LastActivityAt = ''; HasOutcomeMarker = $false; ProcessExited = $false } }
    $marker = $null; $detail = ''; $latestActivity = ''; $requestedHuman = $false; $runnerExitCode = $null
    foreach ($line in @(Get-Content -LiteralPath $Launch.logPath -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        $text = [string]$line
        $agentText = ''; $hasUsableActivity = $true
        try {
            $json = $text | ConvertFrom-Json -ErrorAction Stop; $parts = @()
            $hasUsableActivity = $false
            foreach ($name in @('type', 'event', 'status', 'message', 'error', 'output')) {
                if ($null -ne $json.PSObject.Properties[$name]) {
                    $parts += [string]$json.$name
                    if ($name -in @('message', 'error', 'output') -and -not [string]::IsNullOrWhiteSpace([string]$json.$name)) { $hasUsableActivity = $true }
                }
            }
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
        $candidateActivity = if ([string]::IsNullOrWhiteSpace($safeAgentText)) { $safeText } else { $safeAgentText }
        if (-not [string]::IsNullOrWhiteSpace($safeAgentText)) { $hasUsableActivity = $true }
        if ($hasUsableActivity -and -not [string]::IsNullOrWhiteSpace($candidateActivity)) { $latestActivity = Get-DisplayText $candidateActivity 120 }
        $matches = [regex]::Matches($safeAgentText, '(?i)WATCHER_OUTCOME\s*:\s*(done|needs-human|failed)\b')
        if ($matches.Count -gt 0) { $marker = $matches[$matches.Count - 1].Groups[1].Value.ToLowerInvariant(); $detail = $safeAgentText }
        if ($safeText -match '(?i)needs[-_ ]?human|human[-_ ]?input|approval required' -or $safeAgentText -match '(?i)need[s]? (?:a )?(?:clarification|decision|input)|please (?:clarify|provide)|question for') {
            $requestedHuman = $true; if ([string]::IsNullOrWhiteSpace($detail)) { $detail = if ([string]::IsNullOrWhiteSpace($safeAgentText)) { $safeText } else { $safeAgentText } }
        }
    }
    $lastActivityAt = (Get-Item -LiteralPath $Launch.logPath -ErrorAction SilentlyContinue).LastWriteTimeUtc.ToString('u')
    if ($null -ne $runnerExitCode -and $runnerExitCode -ne 0) { return [pscustomobject]@{ Status = 'failed'; Detail = (Get-DisplayText 'Codex runner exited with a nonzero status.' 120); Activity = $latestActivity; LastActivityAt = $lastActivityAt; HasOutcomeMarker = ($null -ne $marker); ProcessExited = $true } }
    if ($null -ne $marker) { return [pscustomobject]@{ Status = $marker; Detail = (Get-DisplayText $detail 120); Activity = $latestActivity; LastActivityAt = $lastActivityAt; HasOutcomeMarker = $true; ProcessExited = ($null -ne $runnerExitCode) } }
    if ($requestedHuman) { return [pscustomobject]@{ Status = 'needs-human'; Detail = (Get-DisplayText $detail 120); Activity = $latestActivity; LastActivityAt = $lastActivityAt; HasOutcomeMarker = $false; ProcessExited = ($null -ne $runnerExitCode) } }
    if ($null -ne $runnerExitCode) { return [pscustomobject]@{ Status = 'needs-human'; Detail = 'Codex exited without a valid WATCHER_OUTCOME marker.'; Activity = $latestActivity; LastActivityAt = $lastActivityAt; HasOutcomeMarker = $false; ProcessExited = $true } }
    return [pscustomobject]@{ Status = [string]$Launch.status; Detail = ''; Activity = $latestActivity; LastActivityAt = $lastActivityAt; HasOutcomeMarker = $false; ProcessExited = $false }
}

function Get-ActivityMonitorRows {
    param([Parameter(Mandatory)]$State)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($launch in @($State.launches)) {
        if ($null -eq $launch) { continue }
        $jsonl = Get-LaunchJsonlStatus $launch
        $activity = if (-not [string]::IsNullOrWhiteSpace([string]$jsonl.Detail)) { $jsonl.Detail } elseif (-not [string]::IsNullOrWhiteSpace([string]$jsonl.Activity)) { $jsonl.Activity } elseif ([string]$launch.status -eq 'interrupted') { 'PID is no longer identity-verified; manual recovery is required.' } else { '-' }
        [void]$rows.Add([pscustomobject]@{
            Repository = [string]$launch.repository
            Issue = [int]$launch.issueNumber
            Status = [string]$launch.status
            Pid = [string]$launch.pid
            ActivityAt = [string]$jsonl.LastActivityAt
            Activity = Get-DisplayText $activity 120
        })
    }
    return @($rows)
}

function Write-ActivityMonitorSnapshot {
    param($Config, [Parameter(Mandatory)]$Iteration)
    Clear-Host
    Write-Host 'local-issue-agent-monitor v1 | live agent activity'
    Write-Host ('Refreshed UTC: {0:u} | next poll: {1:u}' -f [DateTimeOffset]::UtcNow, [DateTimeOffset]::UtcNow.AddSeconds($Iteration.PollIntervalSeconds))
    if ($null -eq $Config) {
        Write-Host 'Configuration is unavailable; no launch state can be shown.'
    }
    else {
        $state = Read-IssueLaunchState -Path $Config.Launch.StatePath
        $rows = @(Get-ActivityMonitorRows $state)
        if (-not [bool]$Config.Launch.Enabled) { Write-Host 'New launch processing is disabled; showing preserved tracked launch state.' }
        if ($rows.Count -eq 0) { Write-Host 'No tracked agent launches.' }
        else {
            Write-Host ('{0,-35} {1,-8} {2,-14} {3,-8} {4,-20} {5}' -f 'Repository', 'Issue', 'Status', 'PID', 'Latest activity UTC', 'Activity')
            foreach ($row in $rows) {
                $activityAt = if ([string]::IsNullOrWhiteSpace($row.ActivityAt)) { '-' } else { $row.ActivityAt }
                Write-Host ('{0,-35} #{1,-7} {2,-14} {3,-8} {4,-20} {5}' -f (Get-DisplayText $row.Repository 35), $row.Issue, (Get-DisplayText $row.Status 14), $row.Pid, $activityAt, (Get-DisplayText $row.Activity 120))
            }
        }
    }
    if ($script:ActivityMonitorNotices.Count -gt 0) {
        Write-Host ''
        Write-Host 'Latest poll notices:'
        foreach ($notice in @($script:ActivityMonitorNotices | Select-Object -Last 3)) { Write-Host (Get-DisplayText $notice 180) }
    }
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
    try { $config = Get-IssueMonitorConfig -Path $ConfigPath } catch { Write-MonitorMessage $_.Exception.Message; return [pscustomobject]@{ PollIntervalSeconds = 60; Succeeded = $false; Config = $null } }
    if ($PSCmdlet.ParameterSetName -eq 'Stop') {
        try { Invoke-StopTrackedIssue $config; return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $true; Config = $config } } catch { Write-MonitorMessage $_.Exception.Message; return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $false; Config = $config } }
    }
    try {
        $gitHubToken = Get-GitHubIssuesToken -CredentialReadScript $CredentialReadScript
        $noStateWrite = [bool]$WhatIf -or -not [bool]$config.Launch.Enabled
        $result = Invoke-IssueMonitorPoll -Config $config -GitHubToken $gitHubToken -DoNotSaveState:$noStateWrite; foreach ($event in @($result.Events)) { Write-IssueMonitorEvent $event }; Invoke-LaunchMonitoring $config $result $gitHubToken
        if ($result.SuccessfulRepositoryCount -eq 0) { Write-MonitorMessage 'No repository could be checked. Review the error rows above; local state was not changed.'; return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $false; Config = $config } }
        return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $true; Config = $config }
    } catch { Write-MonitorMessage $_.Exception.Message; return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $false; Config = $config } }
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Watch) { [void](Invoke-MonitorIteration); return }
while ($true) {
    $script:ActivityMonitorNotices.Clear()
    $iteration = Invoke-MonitorIteration
    Write-ActivityMonitorSnapshot -Config $iteration.Config -Iteration $iteration
    Start-Sleep -Seconds $iteration.PollIntervalSeconds
}
