[CmdletBinding(DefaultParameterSetName = 'Follow')]
param(
    [string]$ConfigPath,
    [Parameter(ParameterSetName = 'Once')][switch]$Once,
    [Parameter(Mandatory, ParameterSetName = 'Watch')][switch]$Watch,
    [Parameter(ParameterSetName = 'Follow')][switch]$Follow,
    # Read-only view of completed and superseded launch records.
    [Parameter(Mandatory, ParameterSetName = 'History')][switch]$History,
    [Parameter(Mandatory, ParameterSetName = 'Stop')][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*$')][string]$StopIssue,
    # Plan only: does not alter GitHub, Git, launch state, or child processes.
    [Parameter(ParameterSetName = 'Once')][Parameter(ParameterSetName = 'Watch')][Parameter(ParameterSetName = 'Stop')][switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
$modulePath = Join-Path $PSScriptRoot 'src\IssueMonitor.Core.psm1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "The core module was not found at '$modulePath'." }
Import-Module -Name $modulePath -Force -DisableNameChecking

# Watch mode collects the normal lifecycle messages during a poll, then renders
# them as part of one refreshed snapshot.  One-off and Stop modes keep their
# existing line-oriented output.
$script:IsActivityMonitor = [bool]$Watch
$script:ActivityMonitorNotices = [System.Collections.Generic.List[string]]::new()
$script:ActivityMonitorCompletedIssueKeys = [System.Collections.Generic.HashSet[string]]::new()
$script:WatcherHeartbeatVersion = 1

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
function Format-MonitorLocalTime {
    param([Parameter(Mandatory)][datetimeoffset]$Timestamp)
    # Persisted timestamps stay UTC. This formatter is only for console output
    # and always includes a numeric local offset to avoid implying UTC.
    return $Timestamp.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz', [Globalization.CultureInfo]::InvariantCulture)
}
function Format-MonitorLocalTimeText {
    param([AllowNull()][string]$Timestamp)
    if ([string]::IsNullOrWhiteSpace($Timestamp)) { return '-' }
    try {
        return Format-MonitorLocalTime ([DateTimeOffset]::Parse($Timestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind))
    } catch {
        return Get-DisplayText $Timestamp 26
    }
}
function Add-ActivityMonitorCompletedIssue {
    param([Parameter(Mandatory)]$Issue)
    if ($script:IsActivityMonitor) { [void]$script:ActivityMonitorCompletedIssueKeys.Add(('{0}#{1}' -f $Issue.Repository, $Issue.Number)) }
}
function Get-ActivityMonitorCompletionSummary {
    $counts = @{}
    foreach ($key in @($script:ActivityMonitorCompletedIssueKeys)) {
        $separator = $key.LastIndexOf('#')
        if ($separator -lt 1) { continue }
        $repository = $key.Substring(0, $separator)
        if ($counts.ContainsKey($repository)) { $counts[$repository]++ } else { $counts[$repository] = 1 }
    }
    return @($counts.GetEnumerator() | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Repository = $_.Name; Count = [int]$_.Value } })
}
function Remove-ClosedIssueLaunches {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Issues)
    $closedIssues = @{}
    foreach ($issue in $Issues) {
        if ($null -ne $issue -and [string]$issue.State -eq 'closed') { $closedIssues[('{0}#{1}' -f $issue.Repository, $issue.Number)] = $issue }
    }
    if ($closedIssues.Count -eq 0) { return [pscustomobject]@{ State = $State; Changed = $false } }
    $remaining = [System.Collections.Generic.List[object]]::new(); $changed = $false
    foreach ($launch in @($State.launches)) {
        if ($null -eq $launch) { continue }
        $key = '{0}#{1}' -f $launch.repository, $launch.issueNumber
        if (-not $closedIssues.ContainsKey($key)) { [void]$remaining.Add($launch); continue }
        if ([string]$launch.status -eq 'running') {
            Add-ActivityMonitorNotice "Closed Issue $key still has an active local process and remains tracked until it exits."
            [void]$remaining.Add($launch); continue
        }
        Add-ActivityMonitorCompletedIssue $closedIssues[$key]
        Add-ActivityMonitorNotice "Closed Issue $key was removed from tracked launch state."
        $changed = $true
    }
    if ($changed) { $State.launches = @($remaining) }
    return [pscustomobject]@{ State = $State; Changed = $changed }
}
function Write-MonitorMessage {
    param([Parameter(Mandatory)][string]$Message, [string]$Status = 'error')
    $line = '{0} | {1,-12} | {2}' -f (Format-MonitorLocalTime ([DateTimeOffset]::UtcNow)), $Status, (Protect-MonitorText $Message)
    if ($script:IsActivityMonitor) { Add-ActivityMonitorNotice $line; return }
    Write-Host $line
}
function Get-DisplayText {
    param([AllowNull()][string]$Text, [int]$MaximumLength = 60)
    # Keep the truncation marker ASCII-only so Windows PowerShell 5.1 can
    # parse this BOM-less source consistently on every system code page.
    $truncationSuffix = '...'
    $safe = Protect-MonitorText $Text
    if ([string]::IsNullOrWhiteSpace($safe)) { return '-' }
    if ($safe.Length -le $MaximumLength) { return $safe }
    if ($MaximumLength -le $truncationSuffix.Length) { return $safe.Substring(0, $MaximumLength) }
    return $safe.Substring(0, $MaximumLength - $truncationSuffix.Length) + $truncationSuffix
}
function Write-IssueMonitorEvent {
    param([Parameter(Mandatory)]$Event)
    $time = Format-MonitorLocalTime ([DateTimeOffset]::UtcNow)
    # Poll failures intentionally have no Issue payload.  Keep this guard
    # defensive so an incomplete event can never turn error rendering into a
    # secondary Labels-property failure.
    if ($Event.Status -eq 'error' -or $null -eq $Event.Issue) {
        $repository = if ($Event.Repository) { $Event.Repository } else { '-' }
        $message = if ($Event.PSObject.Properties['Message']) { [string]$Event.Message } else { 'Monitor event did not include an Issue payload.' }
        $line = '{0} | {1,-12} | {2,-35} | {3}' -f $time, 'error', $repository, (Protect-MonitorText $message)
        if ($script:IsActivityMonitor) { Add-ActivityMonitorNotice $line } else { Write-Host $line }; return
    }
    $issue = $Event.Issue; $labels = @($issue.Labels) -join ', '
    if ([string]::IsNullOrWhiteSpace($labels)) { $labels = '-' }
    $ready = if ($Event.IsWatched) { ' READY' } else { '' }
    $format = '{0} | {1,-12} | {2,-35} | #{3,-6} | {4,-14} | {5,-28} | {6,-26} | {7}{8}'
    $line = $format -f $time, $Event.Status, $issue.Repository, $issue.Number, $issue.Type, (Get-DisplayText $labels 28), (Format-MonitorLocalTimeText $issue.UpdatedAt), (Get-DisplayText $issue.Title), $ready
    if ($script:IsActivityMonitor) { Add-ActivityMonitorNotice $line } else { Write-Host $line }
}
function Write-LaunchEvent {
    param([Parameter(Mandatory)][string]$Status, [Parameter(Mandatory)]$Issue, [string]$Message = '')
    $suffix = if ([string]::IsNullOrWhiteSpace($Message)) { '' } else { ' | ' + (Protect-MonitorText $Message) }
    $line = '{0} | {1,-12} | {2,-35} | #{3,-6}{4}' -f (Format-MonitorLocalTime ([DateTimeOffset]::UtcNow)), $Status, $Issue.Repository, $Issue.Number, $suffix
    if ($script:IsActivityMonitor) { Add-ActivityMonitorNotice $line } else { Write-Host $line }
}

function Get-LaunchJsonlStatus {
    param([Parameter(Mandatory)]$Launch)
    if ([string]::IsNullOrWhiteSpace([string]$Launch.logPath) -or -not (Test-Path -LiteralPath $Launch.logPath -PathType Leaf)) { return [pscustomobject]@{ Status = [string]$Launch.status; Detail = ''; Activity = ''; LastActivityAt = ''; HasOutcomeMarker = $false; ProcessExited = $false; HumanRequest = ''; DelegatesCreated = $null; DelegationRefusalReason = '' } }
    $marker = $null; $detail = ''; $latestActivity = ''; $humanRequest = ''; $runnerExitCode = $null; $delegatesCreated = $null; $delegationRefusalReason = ''
    foreach ($line in @(Get-Content -LiteralPath $Launch.logPath -Encoding utf8 -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        try {
            $json = ([string]$line | ConvertFrom-Json -ErrorAction Stop)
            if ([int]$json.version -ne 1 -or [string]$json.type -ne 'watcher-agent-event') { continue }
            $event = [string]$json.event
            if ($event -eq 'activity' -and $null -ne $json.PSObject.Properties['message']) { $latestActivity = Get-DisplayText (Protect-MonitorText ([string]$json.message)) 120 }
            if ($event -eq 'outcome' -and $null -ne $json.PSObject.Properties['outcome']) {
                $candidateOutcome = [string]$json.outcome
                if ($candidateOutcome -in @('commit-request', 'needs-human', 'failed')) {
                    $marker = $candidateOutcome; $detail = if ($null -ne $json.PSObject.Properties['message']) { Protect-MonitorText ([string]$json.message) } else { '' }
                    if ($candidateOutcome -eq 'needs-human' -and $null -ne $json.PSObject.Properties['humanRequest']) {
                        $candidateRequest = ([string]$json.humanRequest -replace '\s+', ' ') -replace '(?i)(?:[A-Z]:\\|\\\\)[^\s,;]+', '[local path redacted]'
                        $humanRequest = Get-DisplayText (Protect-MonitorText $candidateRequest) 600
                    }
                }
            }
            if ($event -eq 'delegation') {
                if ($null -ne $json.PSObject.Properties['delegatesCreated']) { $candidateCount = 0; if ([int]::TryParse([string]$json.delegatesCreated, [ref]$candidateCount) -and $candidateCount -ge 0) { $delegatesCreated = $candidateCount } }
                if ($null -ne $json.PSObject.Properties['delegationRefusalReason']) { $delegationRefusalReason = Get-DisplayText (Protect-MonitorText ([string]$json.delegationRefusalReason)) 600 }
            }
            if ($event -eq 'exit' -and $null -ne $json.PSObject.Properties['exitCode']) { $parsedExitCode = 0; if ([int]::TryParse([string]$json.exitCode, [ref]$parsedExitCode)) { $runnerExitCode = $parsedExitCode } }
        } catch {
            continue
        }
    }
    $lastActivityAt = (Get-Item -LiteralPath $Launch.logPath -ErrorAction SilentlyContinue).LastWriteTimeUtc.ToString('u')
    if ($null -ne $runnerExitCode -and $runnerExitCode -ne 0) { return [pscustomobject]@{ Status = 'failed'; Detail = (Get-DisplayText 'Agent runner exited with a nonzero status.' 120); Activity = $latestActivity; LastActivityAt = $lastActivityAt; HasOutcomeMarker = ($null -ne $marker); ProcessExited = $true; HumanRequest = ''; DelegatesCreated = $delegatesCreated; DelegationRefusalReason = $delegationRefusalReason } }
    if ($null -ne $marker) { return [pscustomobject]@{ Status = $marker; Detail = (Get-DisplayText $detail 120); Activity = $latestActivity; LastActivityAt = $lastActivityAt; HasOutcomeMarker = $true; ProcessExited = ($null -ne $runnerExitCode); HumanRequest = if ($marker -eq 'needs-human') { $humanRequest } else { '' }; DelegatesCreated = $delegatesCreated; DelegationRefusalReason = $delegationRefusalReason } }
    if ($null -ne $runnerExitCode) { return [pscustomobject]@{ Status = 'needs-human'; Detail = 'Agent runner exited without a valid terminal outcome.'; Activity = $latestActivity; LastActivityAt = $lastActivityAt; HasOutcomeMarker = $false; ProcessExited = $true; HumanRequest = ''; DelegatesCreated = $delegatesCreated; DelegationRefusalReason = $delegationRefusalReason } }
    return [pscustomobject]@{ Status = [string]$Launch.status; Detail = ''; Activity = $latestActivity; LastActivityAt = $lastActivityAt; HasOutcomeMarker = $false; ProcessExited = $false; HumanRequest = ''; DelegatesCreated = $delegatesCreated; DelegationRefusalReason = $delegationRefusalReason }
}

function Test-LaunchIsSuperseded {
    param([Parameter(Mandatory)]$Launch)
    return $null -ne $Launch.PSObject.Properties['supersededAt'] -and -not [string]::IsNullOrWhiteSpace([string]$Launch.supersededAt)
}

function Test-LaunchIsHistorical {
    param([Parameter(Mandatory)]$Launch)
    return (Test-LaunchIsSuperseded $Launch) -or [string]$Launch.status -eq 'done'
}

function Get-ActiveLaunches {
    param([Parameter(Mandatory)]$State)
    return @($State.launches | Where-Object { $null -ne $_ -and -not (Test-LaunchIsHistorical $_) })
}

function Get-HistoricalLaunches {
    param([Parameter(Mandatory)]$State)
    return @($State.launches | Where-Object { $null -ne $_ -and (Test-LaunchIsHistorical $_) })
}

function Get-ActivityMonitorRows {
    param([Parameter(Mandatory)]$State)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($launch in @(Get-ActiveLaunches $State)) {
        $jsonl = Get-LaunchJsonlStatus $launch
        $activity = if (-not [string]::IsNullOrWhiteSpace([string]$jsonl.Detail)) { $jsonl.Detail } elseif (-not [string]::IsNullOrWhiteSpace([string]$jsonl.Activity)) { $jsonl.Activity } elseif ([string]$launch.status -eq 'interrupted') { 'PID is no longer identity-verified; manual recovery is required.' } else { '-' }
        [void]$rows.Add([pscustomobject]@{
            Repository = [string]$launch.repository
            Issue = [int]$launch.issueNumber
            Status = [string]$launch.status
            Pid = [string]$launch.pid
            ActivityAt = Format-MonitorLocalTimeText ([string]$jsonl.LastActivityAt)
            Activity = Get-DisplayText $activity 120
        })
    }
    return @($rows)
}

function Get-LaunchHistoryRows {
    param([Parameter(Mandatory)]$State)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($launch in @(Get-HistoricalLaunches $State)) {
        $superseded = Test-LaunchIsSuperseded $launch
        [void]$rows.Add([pscustomobject]@{
            Repository = [string]$launch.repository
            Issue = [int]$launch.issueNumber
            Attempt = if ($null -ne $launch.PSObject.Properties['attempt']) { [string]$launch.attempt } else { '-' }
            Status = [string]$launch.status
            HistoricalState = if ($superseded) { 'superseded' } else { 'completed' }
            StartedAt = if ($null -ne $launch.PSObject.Properties['startedAt']) { Format-MonitorLocalTimeText ([string]$launch.startedAt) } else { '-' }
            SupersededAt = if ($superseded) { Format-MonitorLocalTimeText ([string]$launch.supersededAt) } else { '-' }
        })
    }
    return @($rows)
}

function Write-LaunchHistory {
    param([Parameter(Mandatory)]$Config)
    Write-Host 'local-issue-agent-monitor v1 | launch history (read-only)'
    $rows = @(Get-LaunchHistoryRows (Read-IssueLaunchState -Path $Config.Launch.StatePath))
    if ($rows.Count -eq 0) { Write-Host 'No historical agent launches.'; return }
    Write-Host ('{0,-35} {1,-8} {2,-8} {3,-14} {4,-16} {5,-26} {6}' -f 'Repository', 'Issue', 'Attempt', 'Status', 'Historical state', 'Started (local)', 'Superseded (local)')
    foreach ($row in $rows) {
        Write-Host ('{0,-35} #{1,-7} {2,-8} {3,-14} {4,-16} {5,-26} {6}' -f (Get-DisplayText $row.Repository 35), $row.Issue, $row.Attempt, (Get-DisplayText $row.Status 14), $row.HistoricalState, $row.StartedAt, $row.SupersededAt)
    }
}

function Write-ActivityMonitorSnapshot {
    param($Config, [Parameter(Mandatory)]$Iteration)
    Clear-Host
    Write-Host 'local-issue-agent-monitor v1 | live agent activity'
    Write-Host ('Refreshed (local): {0} | next poll: {1}' -f (Format-MonitorLocalTime ([DateTimeOffset]::UtcNow)), (Format-MonitorLocalTime ([DateTimeOffset]::UtcNow.AddSeconds($Iteration.PollIntervalSeconds))))
    if ($null -eq $Config) {
        Write-Host 'Configuration is unavailable; no launch state can be shown.'
    }
    else {
        $state = Read-IssueLaunchState -Path $Config.Launch.StatePath
        $rows = @(Get-ActivityMonitorRows $state)
        $completed = @(Get-ActivityMonitorCompletionSummary)
        if (-not [bool]$Config.Launch.Enabled) { Write-Host 'New launch processing is disabled; showing preserved tracked launch state.' }
        if ($completed.Count -eq 0) { Write-Host 'Completed this session: none.' }
        else {
            Write-Host 'Completed this session:'
            foreach ($entry in $completed) { Write-Host ('  {0}: {1}' -f (Get-DisplayText $entry.Repository 50), $entry.Count) }
        }
        if ($rows.Count -eq 0) { Write-Host 'No tracked agent launches.' }
        else {
            Write-Host ('{0,-35} {1,-8} {2,-14} {3,-8} {4,-26} {5}' -f 'Repository', 'Issue', 'Status', 'PID', 'Latest activity (local)', 'Activity')
            foreach ($row in $rows) {
                $activityAt = if ([string]::IsNullOrWhiteSpace($row.ActivityAt)) { '-' } else { $row.ActivityAt }
                Write-Host ('{0,-35} #{1,-7} {2,-14} {3,-8} {4,-26} {5}' -f (Get-DisplayText $row.Repository 35), $row.Issue, (Get-DisplayText $row.Status 14), $row.Pid, $activityAt, (Get-DisplayText $row.Activity 120))
            }
        }
    }
    if ($script:ActivityMonitorNotices.Count -gt 0) {
        Write-Host ''
        Write-Host 'Latest poll notices:'
        foreach ($notice in @($script:ActivityMonitorNotices | Select-Object -Last 3)) { Write-Host (Get-DisplayText $notice 180) }
    }
}

function Get-WatcherHeartbeatPath {
    param([Parameter(Mandatory)]$Config)
    return ([IO.Path]::GetFullPath([string]$Config.Launch.StatePath) + '.watcher-heartbeat.json')
}
function Get-WatcherConfigurationKey {
    param([Parameter(Mandatory)]$Config)
    $identity = [IO.Path]::GetFullPath([string]$Config.Launch.StatePath).ToLowerInvariant()
    $bytes = [Text.Encoding]::UTF8.GetBytes($identity)
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return (-join ($hash | ForEach-Object { $_.ToString('x2') }))
}
function Get-WatcherHeartbeatMaximumAgeSeconds {
    param([Parameter(Mandatory)]$Config)
    return [Math]::Max(30, ([int]$Config.PollIntervalSeconds * 2) + 15)
}
function Test-WatcherProcessIdentity {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$ProcessStartedAt,
        [scriptblock]$ProcessLookupScript
    )
    try {
        $process = if ($null -ne $ProcessLookupScript) { & $ProcessLookupScript -ProcessId $ProcessId } else { Get-Process -Id $ProcessId -ErrorAction SilentlyContinue }
        if ($null -eq $process) { return $false }
        $expected = [DateTimeOffset]::Parse($ProcessStartedAt).ToUniversalTime()
        $actual = [DateTimeOffset]$process.StartTime.ToUniversalTime()
        return [Math]::Abs(($actual - $expected).TotalSeconds) -lt 1
    } catch { return $false }
}
function Get-WatcherHeartbeatStatus {
    param(
        [Parameter(Mandatory)][string]$HeartbeatPath,
        [Parameter(Mandatory)][int]$MaximumAgeSeconds,
        [datetimeoffset]$Now = [DateTimeOffset]::UtcNow,
        [scriptblock]$ProcessLookupScript
    )
    $missing = [pscustomobject]@{ Active = $false; Reason = 'No watcher heartbeat was found.'; Heartbeat = $null; AgeSeconds = $null }
    if (-not (Test-Path -LiteralPath $HeartbeatPath -PathType Leaf)) { return $missing }
    try { $heartbeat = Get-Content -LiteralPath $HeartbeatPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { return [pscustomobject]@{ Active = $false; Reason = 'The watcher heartbeat cannot be read.'; Heartbeat = $null; AgeSeconds = $null } }
    $heartbeatProcessId = 0
    if ($null -eq $heartbeat -or -not [int]::TryParse([string]$heartbeat.pid, [ref]$heartbeatProcessId) -or $heartbeatProcessId -lt 1 -or [string]::IsNullOrWhiteSpace([string]$heartbeat.processStartedAt)) {
        return [pscustomobject]@{ Active = $false; Reason = 'The watcher heartbeat is incomplete.'; Heartbeat = $heartbeat; AgeSeconds = $null }
    }
    try { $heartbeatAt = [DateTimeOffset]::Parse([string]$heartbeat.heartbeatAt).ToUniversalTime() }
    catch { return [pscustomobject]@{ Active = $false; Reason = 'The watcher heartbeat has no valid timestamp.'; Heartbeat = $heartbeat; AgeSeconds = $null } }
    $ageSeconds = ($Now.ToUniversalTime() - $heartbeatAt).TotalSeconds
    if ($ageSeconds -lt -5 -or $ageSeconds -gt $MaximumAgeSeconds) {
        return [pscustomobject]@{ Active = $false; Reason = ('The watcher heartbeat is stale ({0:N0}s old).' -f [Math]::Max(0, $ageSeconds)); Heartbeat = $heartbeat; AgeSeconds = $ageSeconds }
    }
    if (-not (Test-WatcherProcessIdentity -ProcessId $heartbeatProcessId -ProcessStartedAt ([string]$heartbeat.processStartedAt) -ProcessLookupScript $ProcessLookupScript)) {
        return [pscustomobject]@{ Active = $false; Reason = 'The watcher PID is not alive with the recorded process identity.'; Heartbeat = $heartbeat; AgeSeconds = $ageSeconds }
    }
    return [pscustomobject]@{ Active = $true; Reason = ''; Heartbeat = $heartbeat; AgeSeconds = $ageSeconds }
}
function Write-WatcherHeartbeat {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$ConfigFilePath, [Parameter(Mandatory)][string]$InstanceId)
    $path = Get-WatcherHeartbeatPath $Config
    $directory = Split-Path -Path $path -Parent
    $process = Get-Process -Id $PID -ErrorAction Stop
    $payload = [pscustomobject]@{
        version = $script:WatcherHeartbeatVersion; pid = $PID
        processStartedAt = ([DateTimeOffset]$process.StartTime.ToUniversalTime()).ToString('o')
        heartbeatAt = [DateTimeOffset]::UtcNow.ToString('o'); instanceId = $InstanceId
        config = [pscustomobject]@{
            path = [IO.Path]::GetFullPath($ConfigFilePath); launchStatePath = [IO.Path]::GetFullPath([string]$Config.Launch.StatePath)
            repositories = @($Config.Repositories); pollIntervalSeconds = [int]$Config.PollIntervalSeconds; watchedLabels = @($Config.WatchedLabels)
        }
    }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null }
    $temporaryPath = Join-Path $directory ('.watcher-heartbeat-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporaryPath, ($payload | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $path -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
}
function Enter-WatcherInstance {
    param([Parameter(Mandatory)]$Config)
    $mutexName = 'Local\local-issue-agent-monitor-' + (Get-WatcherConfigurationKey $Config)
    $mutex = [Threading.Mutex]::new($false, $mutexName)
    $acquired = $false
    try { $acquired = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { $mutex.Dispose(); return $null }
    return $mutex
}
function Test-WatcherInstanceOwned {
    param([Parameter(Mandatory)]$Config)
    $mutex = Enter-WatcherInstance $Config
    if ($null -eq $mutex) { return $true }
    try { return $false }
    finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
function Convert-JsonlLineToFollowText {
    param([Parameter(Mandatory)][string]$Line)
    $text = $Line
    try {
        $json = $Line | ConvertFrom-Json -ErrorAction Stop
        if ([int]$json.version -ne 1 -or [string]$json.type -ne 'watcher-agent-event') { return '' }
        if ([string]$json.event -eq 'outcome') { $text = 'terminal outcome: ' + [string]$json.outcome }
        elseif ([string]$json.event -eq 'exit') { $text = 'runner exit: ' + [string]$json.exitCode }
        elseif ($null -ne $json.PSObject.Properties['message']) { $text = [string]$json.message }
        else { return '' }
    } catch { }
    return (Get-DisplayText (Protect-MonitorText $text) 180)
}
function Get-FollowLogEvents {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][hashtable]$Cursors, [switch]$Initialize)
    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($launch in @(Get-ActiveLaunches $State)) {
        if ([string]::IsNullOrWhiteSpace([string]$launch.logPath) -or -not (Test-Path -LiteralPath $launch.logPath -PathType Leaf)) { continue }
        $lines = @(Get-Content -LiteralPath $launch.logPath -Encoding utf8 -ErrorAction SilentlyContinue)
        $key = [string]$launch.logPath; $offset = if ($Cursors.ContainsKey($key)) { [int]$Cursors[$key] } else { 0 }
        if ($Initialize -and -not $Cursors.ContainsKey($key)) { $Cursors[$key] = $lines.Count; continue }
        if ($lines.Count -lt $offset) { $offset = 0 }
        for ($index = $offset; $index -lt $lines.Count; $index++) {
            if (-not [string]::IsNullOrWhiteSpace([string]$lines[$index])) {
                $eventText = Convert-JsonlLineToFollowText ([string]$lines[$index])
                if (-not [string]::IsNullOrWhiteSpace($eventText)) { [void]$events.Add([pscustomobject]@{ Repository = [string]$launch.repository; Issue = [int]$launch.issueNumber; Text = $eventText }) }
            }
        }
        $Cursors[$key] = $lines.Count
    }
    return @($events)
}
function Write-FollowSnapshot {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$HeartbeatStatus)
    $heartbeat = $HeartbeatStatus.Heartbeat
    Write-Host 'local-issue-agent-monitor v1 | follow (read-only)'
    Write-Host ('Watcher PID: {0} | Last heartbeat (local): {1} | Config: {2}' -f $heartbeat.pid, (Format-MonitorLocalTimeText $heartbeat.heartbeatAt), $heartbeat.config.launchStatePath)
    $rows = @(Get-ActiveLaunches (Read-IssueLaunchState -Path $Config.Launch.StatePath))
    if ($rows.Count -eq 0) { Write-Host 'No active agent launches.'; return }
    Write-Host ('{0,-35} {1,-8} {2,-14} {3}' -f 'Repository', 'Issue', 'Status', 'PID')
    foreach ($row in $rows) {
        Write-Host ('{0,-35} #{1,-7} {2,-14} {3}' -f (Get-DisplayText ([string]$row.repository) 35), $row.issueNumber, (Get-DisplayText ([string]$row.status) 14), $row.pid)
    }
}
function Invoke-FollowMode {
    param([Parameter(Mandatory)]$Config)
    $heartbeatPath = Get-WatcherHeartbeatPath $Config; $maximumAge = Get-WatcherHeartbeatMaximumAgeSeconds $Config
    $heartbeatStatus = Get-WatcherHeartbeatStatus -HeartbeatPath $heartbeatPath -MaximumAgeSeconds $maximumAge
    if (-not $heartbeatStatus.Active) { Write-Host ('Follow: there is no active watcher to observe. {0}' -f $heartbeatStatus.Reason); return }
    $cursors = @{}
    Write-FollowSnapshot -Config $Config -HeartbeatStatus $heartbeatStatus
    [void](Get-FollowLogEvents -State (Read-IssueLaunchState -Path $Config.Launch.StatePath) -Cursors $cursors -Initialize)
    while ($true) {
        Start-Sleep -Seconds $Config.PollIntervalSeconds
        $heartbeatStatus = Get-WatcherHeartbeatStatus -HeartbeatPath $heartbeatPath -MaximumAgeSeconds $maximumAge
        if (-not $heartbeatStatus.Active) { Write-Host ('Follow: the watcher is no longer active. {0}' -f $heartbeatStatus.Reason); return }
        Write-FollowSnapshot -Config $Config -HeartbeatStatus $heartbeatStatus
        foreach ($event in @(Get-FollowLogEvents -State (Read-IssueLaunchState -Path $Config.Launch.StatePath) -Cursors $cursors)) {
            Write-Host ('New JSONL event | {0}#{1} | {2}' -f (Get-DisplayText $event.Repository 35), $event.Issue, $event.Text)
        }
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
    $targetLabel = if ($Status -eq 'running') { 'agent:running' } else { 'agent:' + $Status }
    $agentLabels = @($Issue.Labels | Where-Object { $_ -in @('agent:run', 'agent:running', 'agent:needs-human', 'agent:failed', 'agent:done') })
    $alreadyConsistent = $agentLabels.Count -eq 1 -and $agentLabels[0] -eq $targetLabel
    if ($WhatIf -or -not [bool]$Config.Launch.Enabled -or ($currentLabelStatus -eq $Status -and $alreadyConsistent)) { return $false }
    try {
        # The Core request replaces every agent lifecycle label in one GitHub
        # operation while preserving all non-agent labels from this Issue.
        Request-IssueLaunchAgentLabel -Issue $Issue -Launch $Config.Launch -Status $Status -GitHubToken $GitHubToken | Out-Null
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

function Publish-LaunchHumanRequestComment {
    param([Parameter(Mandatory)]$Issue, [Parameter(Mandatory)]$Launch, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$GitHubToken, [scriptblock]$CommentRequestScript)
    $request = if ($null -ne $Launch.PSObject.Properties['humanRequest']) { [string]$Launch.humanRequest } else { '' }
    $alreadyPublished = $null -ne $Launch.PSObject.Properties['humanRequestCommentedAt'] -and -not [string]::IsNullOrWhiteSpace([string]$Launch.humanRequestCommentedAt)
    if ($WhatIf -or -not [bool]$Config.Launch.Enabled -or $alreadyPublished -or [string]::IsNullOrWhiteSpace($request)) { return $false }
    $comment = "[Agent status update]`n`nPrepared by the agent and published by the watcher:`n$request"
    try {
        if ($null -ne $CommentRequestScript) { & $CommentRequestScript -Repository $Issue.Repository -IssueNumber ([int]$Issue.Number) -Body $comment -GitHubToken $GitHubToken }
        else { Invoke-GitHubIssueCommentCreate -Repository $Issue.Repository -IssueNumber ([int]$Issue.Number) -Body $comment -GitHubToken $GitHubToken | Out-Null }
        Set-LaunchProperty $Launch 'humanRequestCommentedAt' ([DateTimeOffset]::UtcNow.ToString('o'))
        return $true
    }
    catch {
        Write-LaunchEvent 'needs-human' $Issue ('GitHub status comment failed; it will be retried: ' + $_.Exception.Message)
        return $false
    }
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
    foreach ($event in @($PollResult.Events | Where-Object { $_.Status -ne 'error' -and $null -ne $_.Issue })) {
        $issuesByKey[('{0}#{1}' -f $event.Issue.Repository, $event.Issue.Number)] = $event.Issue
    }
    $closedLaunches = Remove-ClosedIssueLaunches -State $state -Issues @($issuesByKey.Values)
    $state = $closedLaunches.State
    $stateChanged = $stateChanged -or [bool]$closedLaunches.Changed
    foreach ($launch in @($state.launches)) {
        $keyIssue = [pscustomobject]@{ Repository = [string]$launch.repository; Number = [int]$launch.issueNumber }
        if ([string]$launch.status -ne 'running') {
            Write-LaunchEvent ([string]$launch.status) $keyIssue 'tracked launch'
            $isSuperseded = $null -ne $launch.PSObject.Properties['supersededAt'] -and -not [string]::IsNullOrWhiteSpace([string]$launch.supersededAt)
            if ($isSuperseded) { continue }
            if ([string]$launch.status -in @('done', 'needs-human', 'failed')) {
                $currentIssue = $issuesByKey[([string]$launch.issue)]
                $isExplicitRetry = $null -ne $currentIssue -and @($currentIssue.Labels | Where-Object { $_ -eq 'agent:run' }).Count -gt 0 -and ([string]$launch.status -in @('done', 'needs-human', 'failed'))
                if ($null -ne $currentIssue -and -not $isExplicitRetry) {
                    if (Invoke-LaunchLabelTransition $currentIssue $launch $Config ([string]$launch.status) $GitHubToken) { $stateChanged = $true }
                }
                if ($null -ne $currentIssue -and [string]$launch.status -eq 'needs-human') {
                    if (Publish-LaunchHumanRequestComment $currentIssue $launch $Config $GitHubToken) { $stateChanged = $true }
                }
            }
            continue
        }
        $currentIssue = $issuesByKey[([string]$launch.issue)]
        if ($null -ne $currentIssue -and (Invoke-LaunchLabelTransition $currentIssue $launch $Config 'running' $GitHubToken)) { $stateChanged = $true }
        $jsonl = Get-LaunchJsonlStatus $launch
        if ($null -ne $jsonl.DelegatesCreated) {
            if ($null -eq $launch.PSObject.Properties['delegatesCreated'] -or [int]$launch.delegatesCreated -ne [int]$jsonl.DelegatesCreated) { Set-LaunchProperty $launch 'delegatesCreated' ([int]$jsonl.DelegatesCreated); $stateChanged = $true }
        }
        $existingDelegationRefusalReason = if ($null -ne $launch.PSObject.Properties['delegationRefusalReason']) { [string]$launch.delegationRefusalReason } else { '' }
        if (-not [string]::IsNullOrWhiteSpace([string]$jsonl.DelegationRefusalReason) -and $existingDelegationRefusalReason -ne [string]$jsonl.DelegationRefusalReason) {
            Set-LaunchProperty $launch 'delegationRefusalReason' ([string]$jsonl.DelegationRefusalReason); $stateChanged = $true
        }
        if ($jsonl.Status -ne 'running') {
            # A final response can reach JSONL shortly before its runner-exit
            # record. Never stage or commit while the agent process is still
            # active, even when it has already requested a local commit.
            if ($jsonl.Status -eq 'commit-request' -and -not $jsonl.ProcessExited) { continue }
            $terminalStatus = [string]$jsonl.Status
            $terminalDetail = [string]$jsonl.Detail
            $delegationRequested = $null -ne $launch.PSObject.Properties['delegationRequested'] -and [bool]$launch.delegationRequested
            $delegateCount = if ($null -ne $launch.PSObject.Properties['delegatesCreated']) { [int]$launch.delegatesCreated } else { 0 }
            if ($delegationRequested -and $delegateCount -lt 1) {
                $terminalStatus = 'needs-human'
                $terminalDelegationRefusalReason = if ($null -ne $launch.PSObject.Properties['delegationRefusalReason']) { [string]$launch.delegationRefusalReason } else { '' }
                $terminalDetail = if (-not [string]::IsNullOrWhiteSpace($terminalDelegationRefusalReason)) { $terminalDelegationRefusalReason } else { 'Multi-agent execution was requested, but no delegates were recorded.' }
                if ([string]::IsNullOrWhiteSpace($terminalDelegationRefusalReason)) { Set-LaunchProperty $launch 'delegationRefusalReason' $terminalDetail }
            }
            if ($terminalStatus -eq 'commit-request') {
                $commitResult = Invoke-IssueLaunchCommitRequest -LaunchMetadata $launch
                if ($commitResult.Committed) {
                    $terminalStatus = 'done'
                    $terminalDetail = 'Watcher created local commit ' + $commitResult.Commit + ' after validating the tracked launch.'
                }
                else {
                    $terminalStatus = 'needs-human'
                    $terminalDetail = $commitResult.Message
                }
            }
            Set-LaunchProperty $launch 'status' $terminalStatus; $stateChanged = $true
            if ($terminalStatus -eq 'needs-human' -and -not [string]::IsNullOrWhiteSpace([string]$jsonl.HumanRequest)) {
                Set-LaunchProperty $launch 'humanRequest' ([string]$jsonl.HumanRequest)
            }
            if ($terminalStatus -eq 'done') { Add-ActivityMonitorCompletedIssue $keyIssue }
            Write-LaunchEvent $terminalStatus $keyIssue $terminalDetail
            if ($null -ne $currentIssue -and $terminalStatus -in @('done', 'needs-human', 'failed')) { if (Invoke-LaunchLabelTransition $currentIssue $launch $Config $terminalStatus $GitHubToken) { $stateChanged = $true } }
            if ($null -ne $currentIssue -and $terminalStatus -eq 'needs-human') {
                if (Publish-LaunchHumanRequestComment $currentIssue $launch $Config $GitHubToken) { $stateChanged = $true }
            }
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
    foreach ($event in @($PollResult.Events | Where-Object { $_.Status -ne 'error' -and $null -ne $_.Issue })) {
        $issue = $event.Issue; $known = @(Find-IssueLaunchMetadata -State $state -Repository $issue.Repository -IssueNumber $issue.Number)
        if (@($known | Where-Object { [string]$_.status -eq 'running' }).Count -gt 0) { continue }
        $eligibility = Get-IssueLaunchEligibility -Issue $issue -Launch $Config.Launch
        if (-not $eligibility.Eligible) { continue }
        Write-LaunchEvent 'queued' $issue 'agent:run is eligible.'
        try {
            Write-LaunchEvent 'preflight' $issue 'Checking branch, base repository, and isolated worktree path.'
            $plan = New-IssueLaunchPlan -Issue $issue -Launch $Config.Launch -PriorLaunches $known
            $runner = New-IssueAgentRunnerFromConfiguration -Launch $Config.Launch
            if ($WhatIf) { Write-LaunchEvent 'preflight' $issue ("WhatIf plan: branch={0}; worktree={1}; command={2}" -f $plan.Branch, $plan.WorktreePath, $runner.CommandDescription); continue }
            if ($plan.DelegationRequested -and -not [bool]$runner.DelegationAvailable) {
                $reason = 'Multi-agent execution was requested, but the configured runner does not declare delegation capability.'
                $attempt = @($known).Count + 1
                $metadata = New-IssueDelegationRefusalMetadata -Issue $issue -Attempt $attempt -Reason $reason
                $state.launches = @($state.launches) + @($metadata); Save-IssueLaunchState -State $state -Path $Config.Launch.StatePath
                Write-LaunchEvent 'needs-human' $issue $reason
                [void](Invoke-LaunchLabelTransition $issue $metadata $Config 'needs-human' $GitHubToken); Save-IssueLaunchState -State $state -Path $Config.Launch.StatePath
                continue
            }
            Find-IssueAgentRunnerCommand -Runner $runner | Out-Null
            New-IssueLaunchWorktree -Plan $plan -Launch $Config.Launch | Out-Null
            $stateDirectory = Split-Path -Path $Config.Launch.StatePath -Parent; $logPath = Join-Path $stateDirectory ('issue-{0}-{1}.jsonl' -f $issue.Number, [Guid]::NewGuid().ToString('N'))
            $process = Start-IssueAgentRunner -Runner $runner -Prompt $plan.Prompt -LogPath $logPath -StateDirectory $stateDirectory -WorkingDirectory $plan.WorktreePath
            $metadata = New-IssueLaunchMetadata -Plan $plan -ProcessId $process.Id -LogPath $process.LogPath -ProcessStartedAt $process.StartedAt
            Set-LaunchProperty $metadata 'runnerPath' $process.RunnerPath; Set-LaunchProperty $metadata 'runner' $runner.Name; Set-LaunchProperty $metadata 'runnerEventVersion' $runner.EventVersion
            foreach ($priorLaunch in @($known)) {
                if ([string]$priorLaunch.status -in @('done', 'needs-human', 'failed')) {
                    Set-LaunchProperty $priorLaunch 'supersededAt' ([DateTimeOffset]::UtcNow.ToString('o'))
                }
            }
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
    param([scriptblock]$CredentialReadScript, [scriptblock]$CredentialProviderScript, [scriptblock]$InvokeRestMethodScript, [scriptblock]$MonitorMessageScript, $ResolvedConfig)
    try { $config = if ($null -ne $ResolvedConfig) { $ResolvedConfig } else { Get-IssueMonitorConfig -Path $ConfigPath } } catch { Write-MonitorMessage $_.Exception.Message; return [pscustomobject]@{ PollIntervalSeconds = 60; Succeeded = $false; Config = $null } }
    if ($PSCmdlet.ParameterSetName -eq 'Stop') {
        try { Invoke-StopTrackedIssue $config; return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $true; Config = $config } } catch { Write-MonitorMessage $_.Exception.Message; return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $false; Config = $config } }
    }
    try {
        $gitHubToken = Get-GitHubIssuesToken -CredentialProvider $config.CredentialProvider -CredentialProviderScript $CredentialProviderScript -CredentialReadScript $CredentialReadScript
        $noStateWrite = [bool]$WhatIf -or -not [bool]$config.Launch.Enabled
        $result = Invoke-IssueMonitorPoll -Config $config -GitHubToken $gitHubToken -DoNotSaveState:$noStateWrite -InvokeRestMethodScript $InvokeRestMethodScript; foreach ($event in @($result.Events)) { Write-IssueMonitorEvent $event }; Invoke-LaunchMonitoring $config $result $gitHubToken
        if ($result.SuccessfulRepositoryCount -eq 0) {
            $allErrorMessage = 'No repository could be checked. Review the error rows above; GitHub Issue and label state was not updated. Local launch JSONL may still have been reconciled.'
            if ($null -ne $MonitorMessageScript) { & $MonitorMessageScript -Message $allErrorMessage -Status 'error' } else { Write-MonitorMessage $allErrorMessage }
            return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $false; Config = $config; Message = $allErrorMessage }
        }
        return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $true; Config = $config }
    } catch { Write-MonitorMessage $_.Exception.Message; return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $false; Config = $config } }
}
function Invoke-WatchMode {
    param([Parameter(Mandatory)]$Config)
    $mutex = Enter-WatcherInstance $Config
    if ($null -eq $mutex) {
        Write-Host 'Watch: another watcher already owns this configuration. Use .\Invoke-IssueMonitor.ps1 -Follow to observe it.'
        return
    }
    try {
        $instanceId = [Guid]::NewGuid().ToString('N')
        while ($true) {
            Write-WatcherHeartbeat -Config $Config -ConfigFilePath $ConfigPath -InstanceId $instanceId
            $script:ActivityMonitorNotices.Clear()
            $iteration = Invoke-MonitorIteration -ResolvedConfig $Config
            Write-WatcherHeartbeat -Config $Config -ConfigFilePath $ConfigPath -InstanceId $instanceId
            Write-ActivityMonitorSnapshot -Config $iteration.Config -Iteration $iteration
            Start-Sleep -Seconds $iteration.PollIntervalSeconds
        }
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }
try { $resolvedConfig = Get-IssueMonitorConfig -Path $ConfigPath }
catch { Write-MonitorMessage $_.Exception.Message; return }
switch ($PSCmdlet.ParameterSetName) {
    'Follow' { Invoke-FollowMode -Config $resolvedConfig; return }
    'History' { Write-LaunchHistory -Config $resolvedConfig; return }
    'Watch' { Invoke-WatchMode -Config $resolvedConfig; return }
    'Once' {
        $heartbeatStatus = Get-WatcherHeartbeatStatus -HeartbeatPath (Get-WatcherHeartbeatPath $resolvedConfig) -MaximumAgeSeconds (Get-WatcherHeartbeatMaximumAgeSeconds $resolvedConfig)
        if ($heartbeatStatus.Active -or (Test-WatcherInstanceOwned $resolvedConfig)) {
            $owner = if ($heartbeatStatus.Active) { 'an active watcher (PID {0})' -f $heartbeatStatus.Heartbeat.pid } else { 'a watcher that is starting or has not yet published a fresh heartbeat' }
            Write-Host ('Once: {0} already owns this configuration. Use .\Invoke-IssueMonitor.ps1 -Follow instead.' -f $owner)
            return
        }
        [void](Invoke-MonitorIteration -ResolvedConfig $resolvedConfig)
        return
    }
    'Stop' { [void](Invoke-MonitorIteration -ResolvedConfig $resolvedConfig); return }
}
