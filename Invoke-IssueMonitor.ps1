[CmdletBinding(DefaultParameterSetName = 'Once')]
param(
    [string]$ConfigPath,

    [Parameter(ParameterSetName = 'Once')]
    [switch]$Once,

    [Parameter(Mandatory, ParameterSetName = 'Watch')]
    [switch]$Watch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath 'config.json'
}

$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'src\IssueMonitor.Core.psm1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw "The core module was not found at '$modulePath'. Restore the project files before running the monitor."
}
Import-Module -Name $modulePath -Force

function Write-MonitorMessage {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ('{0:u} | error | {1}' -f [DateTimeOffset]::UtcNow, $Message)
}

function Get-DisplayText {
    param([AllowNull()][string]$Text, [int]$MaximumLength = 60)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '-' }
    if ($Text.Length -le $MaximumLength) { return $Text }
    return $Text.Substring(0, $MaximumLength - 1) + '…'
}

function Write-IssueMonitorEvent {
    param([Parameter(Mandatory)]$Event)

    $time = [DateTimeOffset]::UtcNow.ToString('u')
    if ($Event.Status -eq 'error') {
        $repository = if ($Event.Repository) { $Event.Repository } else { '-' }
        Write-Host ('{0} | {1,-12} | {2,-35} | {3}' -f $time, 'error', $repository, $Event.Message)
        return
    }

    $issue = $Event.Issue
    $labels = @($issue.Labels) -join ', '
    if ([string]::IsNullOrWhiteSpace($labels)) { $labels = '-' }
    $ready = if ($Event.IsWatched) { ' READY' } else { '' }
    $format = '{0} | {1,-12} | {2,-35} | #{3,-6} | {4,-14} | {5,-28} | {6,-20} | {7}{8}'
    $line = $format -f $time, $Event.Status, $issue.Repository, $issue.Number,
        $issue.Type, (Get-DisplayText -Text $labels -MaximumLength 28),
        $issue.UpdatedAt, (Get-DisplayText -Text $issue.Title), $ready
    Write-Host $line
}

function Invoke-MonitorIteration {
    try {
        $config = Get-IssueMonitorConfig -Path $ConfigPath
    }
    catch {
        Write-MonitorMessage -Message $_.Exception.Message
        return [pscustomobject]@{ PollIntervalSeconds = 60; Succeeded = $false }
    }

    if ([string]::IsNullOrWhiteSpace($env:GITHUB_ISSUES_TOKEN)) {
        Write-MonitorMessage -Message "GITHUB_ISSUES_TOKEN is not set. In this PowerShell window, set it with: `$env:GITHUB_ISSUES_TOKEN = 'github_pat_...'"
        return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $false }
    }

    try {
        $result = Invoke-IssueMonitorPoll -Config $config
        foreach ($event in @($result.Events)) { Write-IssueMonitorEvent -Event $event }
        if ($result.SuccessfulRepositoryCount -eq 0) {
            Write-MonitorMessage -Message 'No repository could be checked. Review the error rows above; local state was not changed.'
            return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $false }
        }
        return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $true }
    }
    catch {
        Write-MonitorMessage -Message $_.Exception.Message
        return [pscustomobject]@{ PollIntervalSeconds = $config.PollIntervalSeconds; Succeeded = $false }
    }
}

if (-not $Watch) {
    [void](Invoke-MonitorIteration)
    return
}

Write-Host 'local-issue-agent-monitor v0 is watching. Press Ctrl+C to stop.'
while ($true) {
    $iteration = Invoke-MonitorIteration
    $nextAttempt = [DateTimeOffset]::UtcNow.AddSeconds($iteration.PollIntervalSeconds)
    Write-Host ('Next attempt UTC: {0:u}' -f $nextAttempt)
    Start-Sleep -Seconds $iteration.PollIntervalSeconds
}
