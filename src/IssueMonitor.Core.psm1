Set-StrictMode -Version Latest

$script:IssueMonitorStateVersion = 1
$script:GitHubApiVersion = '2022-11-28'
$script:GitHubUserAgent = 'local-issue-agent-monitor-v0'

function Get-IssueMonitorConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file was not found: '$Path'. Copy config.example.json to a local config file and edit it."
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Configuration file '$Path' is not valid JSON. JSON does not support comments or trailing commas."
    }

    $repositories = @()
    if ($null -ne $config.PSObject.Properties['repositories']) {
        $repositories = @($config.repositories)
    }
    elseif ($null -ne $config.PSObject.Properties['repository']) {
        $repositories = @($config.repository)
    }

    $repositories = @($repositories | ForEach-Object { if ($null -ne $_) { ([string]$_).Trim() } } | Where-Object { $_ })
    if ($repositories.Count -eq 0) {
        throw "Configuration file '$Path' must contain a non-empty 'repositories' array (for example, ['owner/repository'])."
    }

    foreach ($repository in $repositories) {
        if ($repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            throw "Invalid repository '$repository'. Use the form 'owner/repository'."
        }
    }

    $configuredLabels = if ($null -ne $config.PSObject.Properties['watchedLabels']) { @($config.watchedLabels) } else { @() }
    $watchedLabels = @($configuredLabels | ForEach-Object { if ($null -ne $_) { ([string]$_).Trim() } } | Where-Object { $_ })
    if ($watchedLabels.Count -eq 0) {
        throw "Configuration file '$Path' must contain at least one 'watchedLabels' value, such as 'status:ready'."
    }

    $interval = 60
    if ($null -ne $config.PSObject.Properties['pollIntervalSeconds']) {
        $parsedInterval = 0
        if (-not [int]::TryParse([string]$config.pollIntervalSeconds, [ref]$parsedInterval) -or $parsedInterval -lt 5) {
            throw "Configuration value 'pollIntervalSeconds' must be an integer of at least 5."
        }
        $interval = $parsedInterval
    }

    $validatedConfig = [pscustomobject]@{
        Repositories        = @($repositories | Select-Object -Unique)
        PollIntervalSeconds = $interval
        WatchedLabels       = @($watchedLabels | Select-Object -Unique)
    }
    Test-IssueMonitorConfiguration -Config $validatedConfig | Out-Null
    return $validatedConfig
}

function Test-IssueMonitorConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Config)

    if ($null -eq $Config.PSObject.Properties['Repositories'] -or @($Config.Repositories).Count -eq 0) {
        throw 'Monitor configuration must provide at least one repository.'
    }
    foreach ($repository in @($Config.Repositories)) {
        if ([string]::IsNullOrWhiteSpace([string]$repository) -or [string]$repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            throw "Invalid repository '$repository'. Use the form 'owner/repository'."
        }
    }
    if ($null -eq $Config.PSObject.Properties['WatchedLabels'] -or @($Config.WatchedLabels).Count -eq 0) {
        throw 'Monitor configuration must provide at least one watched label.'
    }
    if ($null -eq $Config.PSObject.Properties['PollIntervalSeconds'] -or [int]$Config.PollIntervalSeconds -lt 5) {
        throw 'Monitor configuration pollIntervalSeconds must be at least 5.'
    }
    return $true
}

function Get-IssueMonitorStatePath {
    [CmdletBinding()]
    param()

    $basePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($basePath)) {
        throw 'Could not determine the current user LocalAppData folder for monitor state.'
    }
    Join-Path -Path $basePath -ChildPath 'local-issue-agent-monitor\state.json'
}

function Read-IssueMonitorState {
    [CmdletBinding()]
    param(
        [string]$Path = (Get-IssueMonitorStatePath)
    )

    $empty = [pscustomobject]@{ version = $script:IssueMonitorStateVersion; issues = @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $empty
    }

    try {
        $state = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $state -or $null -eq $state.issues) {
            throw 'missing issues collection'
        }
        return [pscustomobject]@{
            version = $script:IssueMonitorStateVersion
            issues = @($state.issues)
        }
    }
    catch {
        throw "Local monitor state '$Path' cannot be read. Move or remove that file to start with a clean local state."
    }
}

function Get-IssueMonitorState {
    [CmdletBinding()]
    param([string]$Path = (Get-IssueMonitorStatePath))
    Read-IssueMonitorState -Path $Path
}

function Save-IssueMonitorState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$State,
        [string]$Path = (Get-IssueMonitorStatePath)
    )

    $directory = Split-Path -Path $Path -Parent
    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw "State path '$Path' must include a directory."
    }

    $temporaryPath = $null
    try {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
        }
        $temporaryPath = Join-Path -Path $directory -ChildPath ('.state-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
        $payload = [pscustomobject]@{
            version = $script:IssueMonitorStateVersion
            issues = @($State.issues)
        } | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($temporaryPath, $payload, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force -ErrorAction Stop
    }
    catch {
        if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        throw "Local monitor state could not be saved to '$Path': $($_.Exception.Message)"
    }
}

function Get-GitHubRequestHeaders {
    [CmdletBinding()]
    param()

    $token = $env:GITHUB_ISSUES_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'GITHUB_ISSUES_TOKEN is not set. In this PowerShell window, set it with: $env:GITHUB_ISSUES_TOKEN = ''github_pat_...'''
    }
    @{
        Accept                 = 'application/vnd.github+json'
        Authorization           = "Bearer $token"
        'X-GitHub-Api-Version' = $script:GitHubApiVersion
        'User-Agent'           = $script:GitHubUserAgent
    }
}

function Get-HeaderValue {
    param(
        [AllowNull()]$Headers,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Headers) { return $null }
    if ($Headers -is [System.Collections.Specialized.NameValueCollection]) {
        return $Headers.Get($Name)
    }
    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) {
            if ([string]$key -ieq $Name) { return $Headers[$key] }
        }
    }
    foreach ($property in $Headers.PSObject.Properties) {
        if ($property.Name -ieq $Name) { return $property.Value }
    }
    return $null
}

function Get-GitHubRequestFailureMessage {
    param(
        [Parameter(Mandatory)]$ErrorRecord,
        [Parameter(Mandatory)][string]$Repository
    )

    $message = $ErrorRecord.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ISSUES_TOKEN)) {
        $message = $message.Replace($env:GITHUB_ISSUES_TOKEN, '[redacted]')
    }
    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    $response = if ($null -ne $responseProperty) { $responseProperty.Value } else { $null }
    $statusCode = $null
    $responseHeaders = $null
    if ($null -ne $response) {
        try { $statusCode = [int]$response.StatusCode } catch { }
        $responseHeaders = $response.Headers
    }
    $retryAfter = Get-HeaderValue -Headers $responseHeaders -Name 'Retry-After'
    $remaining = Get-HeaderValue -Headers $responseHeaders -Name 'X-RateLimit-Remaining'
    $reset = Get-HeaderValue -Headers $responseHeaders -Name 'X-RateLimit-Reset'
    $isRateLimit = $message -match '(?i)rate limit' -or $statusCode -eq 429 -or
        ($statusCode -eq 403 -and (($remaining -eq '0') -or -not [string]::IsNullOrWhiteSpace([string]$retryAfter)))
    if ($isRateLimit) {
        $retryHint = ''
        $retrySeconds = 0
        if ([int]::TryParse([string]$retryAfter, [ref]$retrySeconds) -and $retrySeconds -gt 0) {
            $retryHint = ' Retry after {0:u}.' -f [DateTimeOffset]::UtcNow.AddSeconds($retrySeconds)
        }
        else {
            $resetSeconds = [int64]0
            if ([int64]::TryParse([string]$reset, [ref]$resetSeconds) -and $resetSeconds -gt 0) {
                $retryHint = ' Limit reset at {0:u}.' -f [DateTimeOffset]::FromUnixTimeSeconds($resetSeconds)
            }
        }
        return "GitHub API rate limit was reached while reading '$Repository'.$retryHint"
    }
    return "GitHub Issues request failed for '$Repository': $message"
}

function Get-GitHubNextPageUrl {
    param([AllowNull()]$Headers)

    $linkHeader = Get-HeaderValue -Headers $Headers -Name 'Link'
    if ($null -eq $linkHeader) { return $null }
    $links = if ($linkHeader -is [System.Array]) { $linkHeader -join ',' } else { [string]$linkHeader }
    foreach ($link in ($links -split ',')) {
        if ($link -match '<(?<url>[^>]+)>\s*;\s*rel\s*=\s*"?next"?') {
            return $Matches.url
        }
    }
    return $null
}

function Invoke-GitHubIssuesPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository,
        [Parameter(Mandatory)][uri]$Uri,
        [scriptblock]$InvokeRestMethodScript
    )

    $headers = Get-GitHubRequestHeaders
    try {
        if ($null -ne $InvokeRestMethodScript) {
            # Test seam: return either @{ Items = ...; Headers = ... } or a raw API item array.
            $response = & $InvokeRestMethodScript -Uri $Uri -Headers $headers -Repository $Repository
            $items = if ($null -ne $response -and $null -ne $response.PSObject.Properties['Items']) { @($response.Items) } else { @($response) }
            $responseHeaders = if ($null -ne $response -and $null -ne $response.PSObject.Properties['Headers']) { $response.Headers } else { $null }
        }
        else {
            # Invoke-WebRequest exposes response headers on Windows PowerShell 5.1 as well as PowerShell 7.
            $response = Invoke-WebRequest -Uri $Uri -Headers $headers -Method Get -UseBasicParsing -ErrorAction Stop
            $items = if ([string]::IsNullOrWhiteSpace($response.Content)) { @() } else { @($response.Content | ConvertFrom-Json -ErrorAction Stop) }
            $responseHeaders = $response.Headers
        }
    }
    catch {
        throw (Get-GitHubRequestFailureMessage -ErrorRecord $_ -Repository $Repository)
    }

    [pscustomobject]@{
        Items       = @($items)
        Headers     = $responseHeaders
        NextPageUrl = Get-GitHubNextPageUrl -Headers $responseHeaders
    }
}

function ConvertTo-MonitoredIssue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Issue,
        [Parameter(Mandatory)][string]$Repository
    )

    $number = if ($null -ne $Issue.PSObject.Properties['number']) { $Issue.number } else { $null }
    $title = if ($null -ne $Issue.PSObject.Properties['title']) { $Issue.title } else { $null }
    if ($null -eq $number -or [string]::IsNullOrWhiteSpace([string]$title)) {
        throw "GitHub returned an invalid Issue for '$Repository': number and title are required."
    }
    $rawLabels = if ($null -ne $Issue.PSObject.Properties['labels']) { @($Issue.labels) } else { @() }
    $labels = @($rawLabels | ForEach-Object {
        if ($_ -is [string]) { $_ } elseif ($null -ne $_ -and $null -ne $_.PSObject.Properties['name']) { [string]$_.name }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $updatedAt = [DateTimeOffset]::MinValue
    $rawUpdatedAt = if ($null -ne $Issue.PSObject.Properties['updated_at']) { $Issue.updated_at } else { $null }
    if (-not [DateTimeOffset]::TryParse([string]$rawUpdatedAt, [ref]$updatedAt)) {
        throw "GitHub returned an Issue with an invalid updated_at value for '$Repository' #$number."
    }
    $url = if ($null -ne $Issue.PSObject.Properties['html_url'] -and $Issue.html_url) { [string]$Issue.html_url } elseif ($null -ne $Issue.PSObject.Properties['url']) { [string]$Issue.url } else { '' }
    [pscustomobject]@{
        Number    = [int]$number
        Repository = $Repository
        Title     = [string]$title
        Type      = 'issue'
        Labels    = @($labels)
        UpdatedAt = $updatedAt.ToUniversalTime().ToString('o')
        Url       = $url
    }
}

function Get-GitHubIssues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository,
        [scriptblock]$InvokeRestMethodScript
    )

    $encodedRepository = ($Repository -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $nextUrl = "https://api.github.com/repos/$encodedRepository/issues?state=open&sort=updated&direction=desc&per_page=100"
    $result = [System.Collections.Generic.List[object]]::new()
    $pageCount = 0
    while (-not [string]::IsNullOrWhiteSpace($nextUrl)) {
        $pageCount++
        if ($pageCount -gt 1000) { throw "GitHub pagination for '$Repository' exceeded a safe limit." }
        $page = Invoke-GitHubIssuesPage -Repository $Repository -Uri $nextUrl -InvokeRestMethodScript $InvokeRestMethodScript
        foreach ($item in $page.Items) {
            if ($null -eq $item -or $null -ne $item.PSObject.Properties['pull_request']) { continue }
            [void]$result.Add((ConvertTo-MonitoredIssue -Issue $item -Repository $Repository))
        }
        $nextUrl = $page.NextPageUrl
    }
    return @($result)
}

function Get-IssueMonitorEvents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Issues,
        [Parameter(Mandatory)][string[]]$WatchedLabels,
        [Parameter(Mandatory)][psobject]$State
    )

    $known = @{}
    foreach ($entry in @($State.issues)) {
        if ($null -ne $entry -and $entry.key) { $known[[string]$entry.key] = $entry }
    }
    $nextEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($existing in @($State.issues)) { if ($null -ne $existing) { [void]$nextEntries.Add($existing) } }
    $events = [System.Collections.Generic.List[object]]::new()

    foreach ($issue in $Issues) {
        $key = '{0}#{1}' -f $issue.Repository, $issue.Number
        $isWatched = @($issue.Labels | Where-Object { $WatchedLabels -contains $_ }).Count -gt 0
        $previous = $known[$key]
        $labelsSignature = (@($issue.Labels | Sort-Object) -join "`n")
        $changed = $null -ne $previous -and (($previous.updatedAt -ne $issue.UpdatedAt) -or ($previous.labelsSignature -ne $labelsSignature))
        $becameWatched = $null -ne $previous -and -not [bool]$previous.wasWatched -and $isWatched
        $status = if ($null -eq $previous) { if ($isWatched) { 'ready' } else { 'new' } } elseif ($becameWatched) { 'ready' } elseif ($changed) { 'updated' } else { 'already-seen' }

        [void]$events.Add([pscustomobject]@{ Status = $status; IsWatched = $isWatched; Issue = $issue })
        $newEntry = [pscustomobject]@{
            key = $key; updatedAt = $issue.UpdatedAt; labelsSignature = $labelsSignature
            wasWatched = $isWatched; lastSeenAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        if ($null -ne $previous) {
            for ($index = $nextEntries.Count - 1; $index -ge 0; $index--) {
                if ($nextEntries[$index].key -eq $key) { $nextEntries.RemoveAt($index) }
            }
        }
        [void]$nextEntries.Add($newEntry)
    }
    [pscustomobject]@{ Events = @($events); State = [pscustomobject]@{ version = $script:IssueMonitorStateVersion; issues = @($nextEntries) } }
}

function Get-IssueMonitorEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Issues,
        [Parameter(Mandatory)][psobject]$State,
        [Parameter(Mandatory)][string[]]$WatchedLabels
    )
    return @(Get-IssueMonitorEvents -Issues $Issues -State $State -WatchedLabels $WatchedLabels).Events
}

function New-IssueMonitorErrorEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Status = 'error'; IsWatched = $false; Repository = $Repository; Message = $Message; Issue = $null }
}

function Invoke-IssueMonitorPoll {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [string]$StatePath = (Get-IssueMonitorStatePath),
        [scriptblock]$InvokeRestMethodScript
    )

    $state = Read-IssueMonitorState -Path $StatePath
    $events = [System.Collections.Generic.List[object]]::new()
    $successfulRepositoryCount = 0
    foreach ($repository in $Config.Repositories) {
        try {
            $issues = @(Get-GitHubIssues -Repository $repository -InvokeRestMethodScript $InvokeRestMethodScript)
            $evaluation = Get-IssueMonitorEvents -Issues $issues -WatchedLabels $Config.WatchedLabels -State $state
            $state = $evaluation.State
            foreach ($event in $evaluation.Events) { [void]$events.Add($event) }
            $successfulRepositoryCount++
        }
        catch {
            [void]$events.Add((New-IssueMonitorErrorEvent -Repository $repository -Message $_.Exception.Message))
        }
    }
    if ($successfulRepositoryCount -gt 0) { Save-IssueMonitorState -State $state -Path $StatePath }
    [pscustomobject]@{ Events = @($events); StatePath = $StatePath; SuccessfulRepositoryCount = $successfulRepositoryCount }
}

Export-ModuleMember -Function @(
    'Get-IssueMonitorConfig', 'Test-IssueMonitorConfiguration', 'Get-IssueMonitorStatePath', 'Read-IssueMonitorState', 'Get-IssueMonitorState',
    'Save-IssueMonitorState', 'Invoke-GitHubIssuesPage', 'Get-GitHubIssues',
    'ConvertTo-MonitoredIssue', 'Get-IssueMonitorEvents', 'Get-IssueMonitorEvent',
    'New-IssueMonitorErrorEvent', 'Invoke-IssueMonitorPoll'
)
