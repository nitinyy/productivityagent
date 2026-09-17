param(
    [switch]$StartMinimized,
    [switch]$SelfTest
)

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    if ($StartMinimized) { $arguments += '-StartMinimized' }
    if ($SelfTest) { $arguments += '-SelfTest' }
    Start-Process powershell.exe -ArgumentList $arguments
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, UIAutomationClient, UIAutomationTypes

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ActivityNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int key);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr window, StringBuilder text, int count);

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

    public static double GetIdleSeconds()
    {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(info);
        if (!GetLastInputInfo(ref info)) return 0;
        uint elapsed = unchecked((uint)Environment.TickCount - info.dwTime);
        return elapsed / 1000.0;
    }
}
"@

$script:AppName = 'Productivity Indicator'
$script:SettingsDirectory = Join-Path $env:LOCALAPPDATA 'ProductivityIndicator'
$script:SettingsPath = Join-Path $script:SettingsDirectory 'settings.json'

$script:DefaultSettings = [ordered]@{
    ScoreIntervalMinutes = 1
    BreakIntervalMinutes = 40
    BreakReminderEnabled = $true
    DistractionAlertSeconds = 20
    ReportPeriodMinutes = 1440
    ProductiveApps = @(
        'devenv', 'code', 'rider64', 'idea64', 'pycharm64', 'webstorm64',
        'wt', 'windowsterminal', 'powershell', 'pwsh', 'cmd',
        'outlook', 'olk', 'ms-teams', 'teams', 'winword', 'excel',
        'powerpnt', 'onenote', 'visio', 'msaccess', 'mspub'
    )
    FocusApps = @('acrord32', 'sumatrapdf', 'calibre', 'kindle')
    DistractionApps = @(
        'vlc', 'wmplayer', 'moviesandtv', 'spotify', 'netflix',
        'primevideo', 'disneyplus'
    )
    BrowserApps = @('chrome', 'msedge', 'firefox', 'brave', 'opera', 'vivaldi')
    ProductiveDomains = @(
        'office.com', 'office365.com', 'microsoft365.com', 'microsoft.com',
        'sharepoint.com', 'teams.microsoft.com', 'outlook.office.com',
        'dev.azure.com', 'github.com', 'learn.microsoft.com',
        'docs.microsoft.com', 'portal.azure.com', 'powerbi.com',
        'powerapps.com', 'dynamics.com'
    )
    ProductiveDomainKeywords = @('microsoft')
    DistractionDomains = @(
        'youtube.com', 'reddit.com', 'instagram.com', 'facebook.com',
        'tiktok.com', 'twitter.com', 'x.com', 'twitch.tv',
        'netflix.com', 'primevideo.com', 'disneyplus.com'
    )
    FocusTitleKeywords = @(
        'documentation', 'docs', 'learn.microsoft', 'github', 'stackoverflow',
        'wiki', 'pdf', 'readme', 'confluence', 'sharepoint'
    )
    DistractionTitleKeywords = @(
        'youtube', 'netflix', 'prime video', 'disney+', 'facebook',
        'instagram', 'tiktok', 'reddit', 'x.com', 'twitter', 'twitch'
    )
}

<#
.SYNOPSIS
Creates an independent copy of the default settings.

.DESCRIPTION
Copies array values as new arrays so runtime changes do not modify the shared
default-settings object.
#>
function Copy-Settings {
    $copy = [ordered]@{}
    foreach ($entry in $script:DefaultSettings.GetEnumerator()) {
        if ($entry.Value -is [System.Array]) {
            $copy[$entry.Key] = @($entry.Value)
        } else {
            $copy[$entry.Key] = $entry.Value
        }
    }
    return $copy
}

<#
.SYNOPSIS
Loads, merges, and validates the application's saved settings.

.DESCRIPTION
Starts with defaults, overlays recognized values from settings.json, and
clamps numeric options to their supported ranges.
#>
function Get-Settings {
    $settings = Copy-Settings
    if (Test-Path $script:SettingsPath) {
        try {
            $saved = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
            foreach ($property in $saved.PSObject.Properties) {
                if ($settings.Contains($property.Name)) {
                    $settings[$property.Name] = $property.Value
                }
            }
        } catch {
            [System.Windows.MessageBox]::Show(
                "Settings could not be read. Defaults will be used.`n`n$($_.Exception.Message)",
                $script:AppName,
                'OK',
                'Warning'
            ) | Out-Null
        }
    }
    $settings.ScoreIntervalMinutes = [Math]::Max(1, [Math]::Min(60, [int]$settings.ScoreIntervalMinutes))
    $settings.BreakIntervalMinutes = [Math]::Max(5, [Math]::Min(240, [int]$settings.BreakIntervalMinutes))
    $settings.DistractionAlertSeconds = [Math]::Max(1, [Math]::Min(3600, [int]$settings.DistractionAlertSeconds))
    $settings.ReportPeriodMinutes = [Math]::Max(5, [Math]::Min(1440, [int]$settings.ReportPeriodMinutes))
    $settings.BreakReminderEnabled = [bool]$settings.BreakReminderEnabled
    return $settings
}

<#
.SYNOPSIS
Persists the current application settings as JSON.
#>
function Save-Settings {
    param([System.Collections.IDictionary]$Settings)

    New-Item -ItemType Directory -Path $script:SettingsDirectory -Force | Out-Null
    $Settings | ConvertTo-Json -Depth 4 | Set-Content -Path $script:SettingsPath -Encoding UTF8
}

<#
.SYNOPSIS
Creates an empty daily activity record for the specified date.
#>
function New-DailyStats {
    param([datetime]$Date = (Get-Date))

    return [ordered]@{
        Date = $Date.ToString('yyyy-MM-dd')
        AppSeconds = @{}
        CategorySeconds = [ordered]@{
            productive = 0
            focus = 0
            neutral = 0
            distraction = 0
            idle = 0
        }
        Buckets = [System.Collections.ArrayList]::new()
        LastUpdated = $Date.ToString('o')
    }
}

<#
.SYNOPSIS
Returns the storage path for a date-specific daily activity file.
#>
function Get-DailyStatsPath {
    param([datetime]$Date = (Get-Date))

    return Join-Path $script:SettingsDirectory "daily-activity-$($Date.ToString('yyyy-MM-dd')).json"
}

<#
.SYNOPSIS
Loads today's persisted activity totals or creates a new daily record.
#>
function Get-DailyStats {
    param([datetime]$Date = (Get-Date))

    $stats = New-DailyStats $Date
    $path = Get-DailyStatsPath $Date
    if (-not (Test-Path $path)) {
        return $stats
    }

    try {
        $saved = Get-Content $path -Raw | ConvertFrom-Json
        if ($saved.Date -ne $stats.Date) {
            return $stats
        }
        foreach ($property in $saved.AppSeconds.PSObject.Properties) {
            $stats.AppSeconds[$property.Name] = [int]$property.Value
        }
        foreach ($category in $stats.CategorySeconds.Keys) {
            if ($null -ne $saved.CategorySeconds.$category) {
                $stats.CategorySeconds[$category] = [int]$saved.CategorySeconds.$category
            }
        }
        foreach ($savedBucket in @($saved.Buckets)) {
            if ($null -eq $savedBucket -or -not $savedBucket.Minute) {
                continue
            }
            $bucket = [ordered]@{
                Minute = [string]$savedBucket.Minute
                AppSeconds = @{}
                CategorySeconds = [ordered]@{
                    productive = 0
                    focus = 0
                    neutral = 0
                    distraction = 0
                    idle = 0
                }
            }
            foreach ($property in $savedBucket.AppSeconds.PSObject.Properties) {
                $bucket.AppSeconds[$property.Name] = [int]$property.Value
            }
            foreach ($category in $bucket.CategorySeconds.Keys) {
                if ($null -ne $savedBucket.CategorySeconds.$category) {
                    $bucket.CategorySeconds[$category] = [int]$savedBucket.CategorySeconds.$category
                }
            }
            $stats.Buckets.Add($bucket) | Out-Null
        }
        if ($stats.Buckets.Count -eq 0 -and $stats.AppSeconds.Count -gt 0) {
            $legacyBucket = [ordered]@{
                Minute = "$($stats.Date)T00:00:00"
                AppSeconds = @{}
                CategorySeconds = [ordered]@{
                    productive = 0
                    focus = 0
                    neutral = 0
                    distraction = 0
                    idle = 0
                }
            }
            foreach ($entry in $stats.AppSeconds.GetEnumerator()) {
                $legacyBucket.AppSeconds[$entry.Key] = [int]$entry.Value
            }
            foreach ($category in @($stats.CategorySeconds.Keys)) {
                $legacyBucket.CategorySeconds[$category] = [int]$stats.CategorySeconds[$category]
            }
            $stats.Buckets.Add($legacyBucket) | Out-Null
        }
        $stats.LastUpdated = [string]$saved.LastUpdated
    } catch {
        [System.Windows.MessageBox]::Show(
            "Today's activity report could not be read. A new report will be started.`n`n$($_.Exception.Message)",
            $script:AppName,
            'OK',
            'Warning'
        ) | Out-Null
    }
    return $stats
}

<#
.SYNOPSIS
Persists the in-memory daily activity totals.
#>
function Save-DailyStats {
    if ($null -eq $script:DailyStats -or -not $script:DailyStatsDirty) {
        return
    }

    New-Item -ItemType Directory -Path $script:SettingsDirectory -Force | Out-Null
    $script:DailyStats.LastUpdated = (Get-Date).ToString('o')
    $path = Get-DailyStatsPath ([datetime]::ParseExact(
        $script:DailyStats.Date,
        'yyyy-MM-dd',
        [Globalization.CultureInfo]::InvariantCulture
    ))
    $script:DailyStats | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
    $script:DailyStatsDirty = $false
    $script:LastDailySaveAt = Get-Date
}

<#
.SYNOPSIS
Starts a new daily activity record when the calendar date changes.
#>
function Update-DailyStatsDate {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($script:DailyStats.Date -eq $today) {
        return
    }

    Save-DailyStats
    $script:DailyStats = Get-DailyStats
    $script:DailyStatsDirty = $false
    $script:LastDailySaveAt = Get-Date
}

<#
.SYNOPSIS
Adds one sampled second to today's app/site and productivity-category totals.
#>
function Add-DailyActivitySample {
    param(
        [string]$Name,
        [string]$Category
    )

    Update-DailyStatsDate
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -eq 'unknown') {
        $Name = 'unknown'
    }
    if (-not $script:DailyStats.AppSeconds.ContainsKey($Name)) {
        $script:DailyStats.AppSeconds[$Name] = 0
    }
    $script:DailyStats.AppSeconds[$Name]++

    if (-not $script:DailyStats.CategorySeconds.Contains($Category)) {
        $Category = 'neutral'
    }
    $script:DailyStats.CategorySeconds[$Category]++

    $minute = (Get-Date).ToString('yyyy-MM-ddTHH:mm:00')
    $bucket = if (
        $script:DailyStats.Buckets.Count -gt 0 -and
        $script:DailyStats.Buckets[$script:DailyStats.Buckets.Count - 1].Minute -eq $minute
    ) {
        $script:DailyStats.Buckets[$script:DailyStats.Buckets.Count - 1]
    } else {
        $newBucket = [ordered]@{
            Minute = $minute
            AppSeconds = @{}
            CategorySeconds = [ordered]@{
                productive = 0
                focus = 0
                neutral = 0
                distraction = 0
                idle = 0
            }
        }
        $script:DailyStats.Buckets.Add($newBucket) | Out-Null
        $newBucket
    }
    if (-not $bucket.AppSeconds.ContainsKey($Name)) {
        $bucket.AppSeconds[$Name] = 0
    }
    $bucket.AppSeconds[$Name]++
    $bucket.CategorySeconds[$Category]++
    $script:DailyStatsDirty = $true
}

<#
.SYNOPSIS
Builds the top-10 usage list and overall score for a configurable time period.
#>
function Get-DailyReport {
    param(
        [int]$PeriodMinutes = $script:Settings.ReportPeriodMinutes,
        [datetime]$Now = (Get-Date),
        [object[]]$StatsRecords
    )

    $baseScores = @{
        productive = 88
        focus = 80
        neutral = 50
        distraction = 15
        idle = 5
    }
    $periodMinutes = [Math]::Max(5, [Math]::Min(1440, $PeriodMinutes))
    $cutoff = $Now.AddMinutes(-$periodMinutes)
    if ($null -eq $StatsRecords) {
        $records = [System.Collections.Generic.List[object]]::new()
        $date = $cutoff.Date
        while ($date -le $Now.Date) {
            if ($date.ToString('yyyy-MM-dd') -eq $script:DailyStats.Date) {
                $records.Add($script:DailyStats)
            } else {
                $records.Add((Get-DailyStats $date))
            }
            $date = $date.AddDays(1)
        }
        $StatsRecords = $records.ToArray()
    }

    $appSeconds = @{}
    $categorySeconds = [ordered]@{
        productive = 0
        focus = 0
        neutral = 0
        distraction = 0
        idle = 0
    }
    $bucketCount = 0
    foreach ($stats in $StatsRecords) {
        foreach ($bucket in @($stats.Buckets)) {
            $bucketTime = [datetime]::ParseExact(
                [string]$bucket.Minute,
                'yyyy-MM-ddTHH:mm:ss',
                [Globalization.CultureInfo]::InvariantCulture
            )
            if ($bucketTime -lt $cutoff -or $bucketTime -gt $Now) {
                continue
            }
            $bucketCount++
            foreach ($entry in $bucket.AppSeconds.GetEnumerator()) {
                if (-not $appSeconds.ContainsKey($entry.Key)) {
                    $appSeconds[$entry.Key] = 0
                }
                $appSeconds[$entry.Key] += [int]$entry.Value
            }
            foreach ($category in $baseScores.Keys) {
                $categorySeconds[$category] += [int]$bucket.CategorySeconds[$category]
            }
        }
    }

    if ($bucketCount -eq 0 -and $periodMinutes -eq 1440) {
        foreach ($stats in $StatsRecords) {
            foreach ($entry in $stats.AppSeconds.GetEnumerator()) {
                if (-not $appSeconds.ContainsKey($entry.Key)) {
                    $appSeconds[$entry.Key] = 0
                }
                $appSeconds[$entry.Key] += [int]$entry.Value
            }
            foreach ($category in $baseScores.Keys) {
                $categorySeconds[$category] += [int]$stats.CategorySeconds[$category]
            }
        }
    }

    $totalSeconds = 0
    $weightedScore = 0.0
    foreach ($category in $baseScores.Keys) {
        $seconds = [int]$categorySeconds[$category]
        $totalSeconds += $seconds
        $weightedScore += $seconds * $baseScores[$category]
    }
    $score = if ($totalSeconds -gt 0) {
        [int][Math]::Round($weightedScore / $totalSeconds)
    } else {
        0
    }

    $topUsage = @($appSeconds.GetEnumerator() |
        Sort-Object Value -Descending |
        Select-Object -First 10 |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Key
                Seconds = [int]$_.Value
            }
        })

    return [pscustomobject]@{
        StartTime = $cutoff
        EndTime = $Now
        PeriodMinutes = $periodMinutes
        Score = $score
        TotalSeconds = $totalSeconds
        TopUsage = $topUsage
    }
}

<#
.SYNOPSIS
Creates an empty activity-metric record for one context category.
#>
function New-Metric {
    return [ordered]@{
        Seconds = 0.0
        ActiveSeconds = 0.0
        Clicks = 0
        Distance = 0.0
    }
}

<#
.SYNOPSIS
Clears the metrics used for the next productivity scoring window.

.DESCRIPTION
Initializes each context category, resets per-app totals, and records the new
window start time.
#>
function Reset-WindowMetrics {
    $script:Metrics = [ordered]@{
        productive = New-Metric
        focus = New-Metric
        neutral = New-Metric
        distraction = New-Metric
        idle = New-Metric
    }
    $script:AppSeconds = @{}
    $script:WindowStartedAt = Get-Date
}

<#
.SYNOPSIS
Adds an app or website sample to the rolling five-minute activity queue.

.DESCRIPTION
Ignores unknown names and removes samples older than five minutes to keep the
queue bounded to the period displayed by the widget.
#>
function Add-RollingUsageSample {
    param(
        [string]$Name,
        [datetime]$Timestamp = (Get-Date)
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -eq 'unknown') {
        return
    }

    $script:UsageSamples.Enqueue([pscustomobject]@{
        Name = $Name
        Timestamp = $Timestamp
    })

    $cutoff = $Timestamp.AddMinutes(-5)
    while (
        $script:UsageSamples.Count -gt 0 -and
        $script:UsageSamples.Peek().Timestamp -lt $cutoff
    ) {
        $script:UsageSamples.Dequeue() | Out-Null
    }
}

<#
.SYNOPSIS
Returns the three most-used apps or websites from the last five minutes.

.DESCRIPTION
Removes expired samples, groups the remaining samples by name, and sorts them
by duration and then name.
#>
function Get-RollingUsageTop {
    param([datetime]$Timestamp = (Get-Date))

    $cutoff = $Timestamp.AddMinutes(-5)
    while (
        $script:UsageSamples.Count -gt 0 -and
        $script:UsageSamples.Peek().Timestamp -lt $cutoff
    ) {
        $script:UsageSamples.Dequeue() | Out-Null
    }

    $usage = @{}
    foreach ($sample in $script:UsageSamples) {
        if (-not $usage.ContainsKey($sample.Name)) {
            $usage[$sample.Name] = 0
        }
        $usage[$sample.Name]++
    }

    return @($usage.GetEnumerator() |
        Sort-Object @{ Expression = 'Value'; Descending = $true },
            @{ Expression = 'Name'; Descending = $false } |
        Select-Object -First 3 |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Key
                Seconds = [int]$_.Value
            }
        })
}

<#
.SYNOPSIS
Formats an activity duration as seconds or minutes and seconds.
#>
function Format-UsageDuration {
    param([int]$Seconds)

    if ($Seconds -ge 60) {
        $minutes = [Math]::Floor($Seconds / 60)
        $remainingSeconds = $Seconds % 60
        if ($remainingSeconds -gt 0) {
            return "${minutes}m ${remainingSeconds}s"
        }
        return "${minutes}m"
    }
    return "${Seconds}s"
}

<#
.SYNOPSIS
Converts user-entered domain text into a normalized, unique list.
#>
function ConvertTo-DomainList {
    param([string]$Text)

    return @($Text -split '[,\r\n;]+' |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { $_ } |
        Select-Object -Unique)
}

<#
.SYNOPSIS
Extracts a lowercase hostname from a URL or hostname-like value.

.DESCRIPTION
Adds a temporary HTTPS scheme when needed so System.Uri can parse bare domain
names, and returns an empty string for invalid input.
#>
function Get-NormalizedHost {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    $candidate = $Url.Trim()
    if ($candidate -notmatch '^[a-z][a-z0-9+.-]*://') {
        $candidate = "https://$candidate"
    }

    try {
        $uri = [Uri]$candidate
        if (-not $uri.Host) { return '' }
        return $uri.Host.TrimEnd('.').ToLowerInvariant()
    } catch {
        return ''
    }
}

<#
.SYNOPSIS
Checks whether a hostname matches a configured domain or one of its subdomains.
#>
function Test-DomainMatch {
    param(
        [string]$HostName,
        [object[]]$Domains
    )

    if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
    $hostLower = $HostName.TrimEnd('.').ToLowerInvariant()
    foreach ($configuredDomain in @($Domains)) {
        $domain = ([string]$configuredDomain).Trim().TrimStart('*', '.').TrimEnd('.').ToLowerInvariant()
        if (-not $domain) { continue }
        if ($hostLower -eq $domain -or $hostLower.EndsWith(".$domain")) {
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
Reads the active browser URL from its address bar.

.DESCRIPTION
Uses Windows UI Automation to locate the address control and caches results
briefly to reduce repeated automation work.
#>
function Get-BrowserUrl {
    param(
        [IntPtr]$WindowHandle,
        [string]$WindowTitle
    )

    if ($WindowHandle -eq [IntPtr]::Zero) { return '' }
    $cacheKey = [string]$WindowHandle.ToInt64()
    $now = Get-Date
    if ($script:BrowserUrlCache.ContainsKey($cacheKey)) {
        $cached = $script:BrowserUrlCache[$cacheKey]
        if ($cached.Title -eq $WindowTitle -and ($now - $cached.CheckedAt).TotalSeconds -lt 3) {
            return $cached.Url
        }
    }

    $url = ''
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($WindowHandle)
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Edit
        )
        $editControls = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            $condition
        )

        foreach ($control in $editControls) {
            $name = ([string]$control.Current.Name).ToLowerInvariant()
            $looksLikeAddressBar = $name -match 'address|location|search.*(web|address)|enter.*address|omnibox'
            if (-not $looksLikeAddressBar) { continue }

            $pattern = $null
            if ($control.TryGetCurrentPattern(
                    [System.Windows.Automation.ValuePattern]::Pattern,
                    [ref]$pattern
                )) {
                $value = ([System.Windows.Automation.ValuePattern]$pattern).Current.Value
                if (Get-NormalizedHost $value) {
                    $url = $value
                    break
                }
            }
        }
    } catch {
        $url = ''
    }

    $script:BrowserUrlCache[$cacheKey] = [pscustomobject]@{
        Title = $WindowTitle
        Url = $url
        CheckedAt = $now
    }
    return $url
}

<#
.SYNOPSIS
Classifies the foreground context as productive, focus, neutral, or distracting.

.DESCRIPTION
Applies configured domain, process, and window-title rules. Distracting domain
rules take precedence over productive rules.
#>
function Resolve-ContextCategory {
    param(
        [string]$ProcessName,
        [string]$Title,
        [string]$Url
    )

    $titleLower = $Title.ToLowerInvariant()
    $hostName = Get-NormalizedHost $Url

    if ($hostName) {
        if (Test-DomainMatch $hostName @($script:Settings.DistractionDomains)) {
            return 'distraction'
        }
        if (Test-DomainMatch $hostName @($script:Settings.ProductiveDomains)) {
            return 'productive'
        }
        foreach ($keyword in @($script:Settings.ProductiveDomainKeywords)) {
            $normalizedKeyword = ([string]$keyword).Trim().ToLowerInvariant()
            if ($normalizedKeyword -and $hostName.Contains($normalizedKeyword)) {
                return 'productive'
            }
        }
    }

    if (@($script:Settings.DistractionApps) -contains $ProcessName) {
        return 'distraction'
    }
    if (@($script:Settings.ProductiveApps) -contains $ProcessName) {
        return 'productive'
    }
    if (@($script:Settings.FocusApps) -contains $ProcessName) {
        return 'focus'
    }

    foreach ($keyword in @($script:Settings.DistractionTitleKeywords)) {
        if ($titleLower.Contains(([string]$keyword).ToLowerInvariant())) {
            return 'distraction'
        }
    }
    foreach ($keyword in @($script:Settings.FocusTitleKeywords)) {
        if ($titleLower.Contains(([string]$keyword).ToLowerInvariant())) {
            return 'focus'
        }
    }
    return 'neutral'
}

<#
.SYNOPSIS
Collects and classifies information about the current foreground window.

.DESCRIPTION
Returns the process, title, browser URL and hostname when available, and the
resolved productivity category.
#>
function Get-ForegroundContext {
    $window = [ActivityNative]::GetForegroundWindow()
    if ($window -eq [IntPtr]::Zero) {
        return [pscustomobject]@{ Process = 'unknown'; Title = ''; Category = 'idle' }
    }

    [uint32]$processId = 0
    [ActivityNative]::GetWindowThreadProcessId($window, [ref]$processId) | Out-Null
    $builder = New-Object Text.StringBuilder 512
    [ActivityNative]::GetWindowText($window, $builder, $builder.Capacity) | Out-Null
    $title = $builder.ToString()

    try {
        $processName = (Get-Process -Id $processId -ErrorAction Stop).ProcessName.ToLowerInvariant()
    } catch {
        $processName = 'unknown'
    }

    $url = ''
    if (@($script:Settings.BrowserApps) -contains $processName) {
        $url = Get-BrowserUrl $window $title
    }
    $category = Resolve-ContextCategory $processName $title $url

    return [pscustomobject]@{
        Process = $processName
        Title = $title
        Url = $url
        HostName = Get-NormalizedHost $url
        Category = $category
    }
}

<#
.SYNOPSIS
Detects the transition from an unpressed to a pressed mouse-button state.

.DESCRIPTION
Updates the supplied previous-state reference so a held button is counted only
once rather than on every sampling tick.
#>
function Test-MouseButtonPressed {
    param(
        [int]$VirtualKey,
        [ref]$PreviousState
    )

    $isDown = (([ActivityNative]::GetAsyncKeyState($VirtualKey) -band 0x8000) -ne 0)
    $pressed = $isDown -and -not $PreviousState.Value
    $PreviousState.Value = $isDown
    return $pressed
}

<#
.SYNOPSIS
Samples the current app context, idle state, pointer movement, and mouse clicks.

.DESCRIPTION
Adds one second to the appropriate scoring category, updates rolling app or
website usage, and records interaction data without storing coordinates or
input content.
#>
function Add-ActivitySample {
    $context = Get-ForegroundContext
    $category = $context.Category
    $idleSeconds = [ActivityNative]::GetIdleSeconds()

    $activityThreshold = switch ($category) {
        'focus' { 120 }
        'productive' { 45 }
        'neutral' { 25 }
        'distraction' { 15 }
        default { 10 }
    }

    if ($idleSeconds -gt 300) {
        $category = 'idle'
    }

    $script:CurrentProcess = $context.Process
    $script:CurrentCategory = $category

    $metric = $script:Metrics[$category]
    $metric.Seconds += 1
    if ($idleSeconds -le $activityThreshold) {
        $metric.ActiveSeconds += 1
    }

    $appKey = if ($context.HostName) {
        $context.HostName
    } elseif ($context.Process) {
        $context.Process
    } else {
        'unknown'
    }
    if (-not $script:AppSeconds.ContainsKey($appKey)) {
        $script:AppSeconds[$appKey] = 0
    }
    $script:AppSeconds[$appKey]++
    Add-DailyActivitySample $appKey $category
    if ($category -ne 'idle') {
        Add-RollingUsageSample $appKey
    }

    $point = New-Object ActivityNative+POINT
    if ([ActivityNative]::GetCursorPos([ref]$point)) {
        if ($null -ne $script:LastCursor) {
            $deltaX = $point.X - $script:LastCursor.X
            $deltaY = $point.Y - $script:LastCursor.Y
            $distance = [Math]::Sqrt(($deltaX * $deltaX) + ($deltaY * $deltaY))
            if ($distance -lt 3000) {
                $metric.Distance += $distance
            }
        }
        $script:LastCursor = [pscustomobject]@{ X = $point.X; Y = $point.Y }
    }

    $clicked = $false
    $clicked = (Test-MouseButtonPressed 0x01 ([ref]$script:LeftMouseDown)) -or $clicked
    $clicked = (Test-MouseButtonPressed 0x02 ([ref]$script:RightMouseDown)) -or $clicked
    $clicked = (Test-MouseButtonPressed 0x04 ([ref]$script:MiddleMouseDown)) -or $clicked
    if ($clicked) {
        $metric.Clicks++
    }
}

<#
.SYNOPSIS
Calculates the productivity score and its component scores for the current window.

.DESCRIPTION
Combines context, context-sensitive interaction, recent activity, and focus
consistency into a value from 0 to 100 and identifies the dominant app or site.
#>
function Get-ProductivityScore {
    $totalSeconds = 0.0
    foreach ($metric in $script:Metrics.Values) {
        $totalSeconds += $metric.Seconds
    }

    if ($totalSeconds -lt 1) {
        return [pscustomobject]@{
            Score = 50
            ContextScore = 50
            InteractionScore = 50
            ActivityScore = 50
            ConsistencyScore = 50
            DominantApp = 'Collecting activity'
        }
    }

    $baseScores = @{
        productive = 88
        focus = 80
        neutral = 50
        distraction = 15
        idle = 5
    }

    $weightedContext = 0.0
    $totalActiveSeconds = 0.0
    foreach ($category in $script:Metrics.Keys) {
        $metric = $script:Metrics[$category]
        $weightedContext += $metric.Seconds * $baseScores[$category]
        $totalActiveSeconds += $metric.ActiveSeconds
    }
    $contextScore = $weightedContext / $totalSeconds
    $activityScore = [Math]::Min(100, ($totalActiveSeconds / $totalSeconds) * 100)

    $interactionWeighted = 0.0
    foreach ($category in $script:Metrics.Keys) {
        $metric = $script:Metrics[$category]
        if ($metric.Seconds -le 0) { continue }

        $minuteFactor = [Math]::Max($metric.Seconds / 60.0, 0.1)
        $clicksPerMinute = $metric.Clicks / $minuteFactor
        $distancePerMinute = $metric.Distance / $minuteFactor

        $interaction = switch ($category) {
            'productive' {
                55 + (20 * [Math]::Min($clicksPerMinute / 10.0, 1)) +
                    (25 * [Math]::Min($distancePerMinute / 3500.0, 1))
            }
            'focus' {
                $clickPenalty = [Math]::Max(0, $clicksPerMinute - 6) * 2
                $movementPenalty = [Math]::Max(0, $distancePerMinute - 1800) / 120
                [Math]::Max(50, 92 - $clickPenalty - $movementPenalty)
            }
            'neutral' {
                42 + (18 * [Math]::Min($clicksPerMinute / 12.0, 1)) +
                    (15 * [Math]::Min($distancePerMinute / 4000.0, 1))
            }
            'distraction' {
                12 + (10 * [Math]::Min($clicksPerMinute / 12.0, 1)) +
                    (8 * [Math]::Min($distancePerMinute / 4000.0, 1))
            }
            default { 5 }
        }
        $interactionWeighted += $metric.Seconds * [Math]::Min(100, $interaction)
    }
    $interactionScore = $interactionWeighted / $totalSeconds

    $focusedSeconds = $script:Metrics.productive.Seconds + $script:Metrics.focus.Seconds
    $consistencyScore = [Math]::Min(100, ($focusedSeconds / $totalSeconds) * 100)

    $score = (0.55 * $contextScore) +
        (0.25 * $interactionScore) +
        (0.15 * $activityScore) +
        (0.05 * $consistencyScore)
    $score = [Math]::Max(0, [Math]::Min(100, [Math]::Round($score)))

    $dominantApp = 'No active app'
    if ($script:AppSeconds.Count -gt 0) {
        $dominantApp = ($script:AppSeconds.GetEnumerator() |
            Sort-Object Value -Descending |
            Select-Object -First 1).Key
    }

    return [pscustomobject]@{
        Score = [int]$score
        ContextScore = [int][Math]::Round($contextScore)
        InteractionScore = [int][Math]::Round($interactionScore)
        ActivityScore = [int][Math]::Round($activityScore)
        ConsistencyScore = [int][Math]::Round($consistencyScore)
        DominantApp = $dominantApp
    }
}

<#
.SYNOPSIS
Maps a productivity score to its emoji, motivational message, and accent color.
#>
function Get-ScorePresentation {
    param([int]$Score)

    $emoji = if ($Score -ge 75) {
        [char]::ConvertFromUtf32(0x1F604)
    } elseif ($Score -ge 50) {
        [char]::ConvertFromUtf32(0x1F642)
    } elseif ($Score -ge 25) {
        [char]::ConvertFromUtf32(0x1F61F)
    } else {
        [char]::ConvertFromUtf32(0x1F622)
    }

    $messages = @(
        'Start tiny: choose one useful task.',
        'Clear one distraction and reset.',
        'A focused five minutes can change momentum.',
        'Pick the next concrete action.',
        'You are building focus - keep simplifying.',
        'Good progress. Protect this rhythm.',
        'Stay with the task in front of you.',
        'Strong focus - keep the momentum steady.',
        'Excellent flow. Finish the current step.',
        'Outstanding focus - keep it sustainable.',
        'Peak productivity. Great work!'
    )
    $messageIndex = [Math]::Min(10, [Math]::Floor($Score / 10))

    $accent = if ($Score -ge 75) {
        '#22C55E'
    } elseif ($Score -ge 50) {
        '#84CC16'
    } elseif ($Score -ge 25) {
        '#F59E0B'
    } else {
        '#EF4444'
    }

    return [pscustomobject]@{
        Emoji = $emoji
        Message = $messages[$messageIndex]
        Accent = $accent
    }
}

<#
.SYNOPSIS
Converts a color string into a WPF brush.
#>
function ConvertTo-Brush {
    param([string]$Color)
    return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

<#
.SYNOPSIS
Displays the break reminder and resets the break-reminder timer.
#>
function Show-BreakReminder {
    $script:Window.Activate() | Out-Null
    [System.Windows.MessageBox]::Show(
        $script:Window,
        "You have been working for $($script:Settings.BreakIntervalMinutes) minutes.`n`nStand up, look away from the screen, and take a short break.",
        'Time for a break',
        'OK',
        'Information'
    ) | Out-Null
    $script:LastBreakAt = Get-Date
}

<#
.SYNOPSIS
Formats a daily activity duration using hours, minutes, and seconds.
#>
function Format-DailyDuration {
    param([int]$Seconds)

    $span = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
    if ($span.TotalHours -ge 1) {
        return '{0}h {1}m' -f [Math]::Floor($span.TotalHours), $span.Minutes
    }
    if ($span.TotalMinutes -ge 1) {
        return '{0}m {1}s' -f $span.Minutes, $span.Seconds
    }
    return "$($span.Seconds)s"
}

<#
.SYNOPSIS
Displays the configured-period productivity score and top 10 apps or sites.
#>
function Show-DailyReportWindow {
    param(
        [System.Windows.Window]$Owner = $script:Window,
        [int]$PeriodMinutes = $script:Settings.ReportPeriodMinutes
    )

    try {
        Save-DailyStats
    } catch {
        [System.Windows.MessageBox]::Show(
            $Owner,
            "Today's activity report could not be saved.`n`n$($_.Exception.Message)",
            $script:AppName,
            'OK',
            'Error'
        ) | Out-Null
        return
    }

    $report = Get-DailyReport $PeriodMinutes
    $reportXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Productivity Report"
        Width="620" Height="540"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        Background="#111827"
        Foreground="#F9FAFB"
        FontFamily="Segoe UI">
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Text="Productivity Report" FontSize="24" FontWeight="SemiBold"/>
        <Grid Grid.Row="1" Margin="0,16,0,18">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
                <TextBlock x:Name="ReportDate" Foreground="#9CA3AF" FontSize="13"/>
                <TextBlock x:Name="TrackedTime" Foreground="#D1D5DB" FontSize="13" Margin="0,5,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="1" HorizontalAlignment="Right">
                <TextBlock Text="OVERALL SCORE" Foreground="#9CA3AF" FontSize="11"
                           HorizontalAlignment="Right"/>
                <TextBlock x:Name="DailyScore" FontSize="36" FontWeight="Bold"
                           Foreground="#FACC15" HorizontalAlignment="Right"/>
            </StackPanel>
        </Grid>
        <DataGrid x:Name="UsageGrid" Grid.Row="2"
                  AutoGenerateColumns="False" IsReadOnly="True"
                  CanUserAddRows="False" CanUserDeleteRows="False"
                  HeadersVisibility="Column" GridLinesVisibility="Horizontal"
                  Background="#1F2937" Foreground="#F9FAFB"
                  RowBackground="#1F2937" AlternatingRowBackground="#172033"
                  BorderBrush="#374151">
            <DataGrid.Columns>
                <DataGridTextColumn Header="#" Binding="{Binding Rank}" Width="45"/>
                <DataGridTextColumn Header="App or site" Binding="{Binding Name}" Width="*"/>
                <DataGridTextColumn Header="Time spent" Binding="{Binding Duration}" Width="140"/>
                <DataGridTextColumn Header="Share" Binding="{Binding Share}" Width="90"/>
            </DataGrid.Columns>
        </DataGrid>
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
            <Button x:Name="CloseReportButton" Content="Close" Width="90" Height="32" IsDefault="True"/>
        </StackPanel>
    </Grid>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new([xml]$reportXaml)
    $reportWindow = [Windows.Markup.XamlReader]::Load($reader)
    $reportWindow.Owner = $Owner
    $periodLabel = if ($report.PeriodMinutes -eq 1440) {
        'Last 24 hours'
    } elseif ($report.PeriodMinutes -ge 60 -and $report.PeriodMinutes % 60 -eq 0) {
        "Last $([int]($report.PeriodMinutes / 60)) hour(s)"
    } else {
        "Last $($report.PeriodMinutes) minutes"
    }
    $reportWindow.FindName('ReportDate').Text = "$periodLabel, ending $($report.EndTime.ToString('g'))"
    $reportWindow.FindName('TrackedTime').Text = "Tracked time: $(Format-DailyDuration $report.TotalSeconds)"
    $reportWindow.FindName('DailyScore').Text = if ($report.TotalSeconds -gt 0) {
        "$($report.Score)/100"
    } else {
        '--'
    }

    $rows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    for ($index = 0; $index -lt $report.TopUsage.Count; $index++) {
        $entry = $report.TopUsage[$index]
        $share = if ($report.TotalSeconds -gt 0) {
            '{0:N1}%' -f (($entry.Seconds / $report.TotalSeconds) * 100)
        } else {
            '0.0%'
        }
        $rows.Add([pscustomobject]@{
            Rank = $index + 1
            Name = $entry.Name
            Duration = Format-DailyDuration $entry.Seconds
            Share = $share
        })
    }
    $reportWindow.FindName('UsageGrid').ItemsSource = $rows
    $reportWindow.FindName('CloseReportButton').Add_Click({
        $reportWindow.DialogResult = $true
    })
    $reportWindow.ShowDialog() | Out-Null
}

<#
.SYNOPSIS
Stops the distracting-site alert and restores the normal score border.
#>
function Stop-DistractionAlert {
    $script:DistractionStartedAt = $null
    $script:DistractionAlertActive = $false
    $script:DistractionBlinkOn = $false
    if ($null -ne $script:Card) {
        $script:Card.BorderThickness = [System.Windows.Thickness]::new(1)
        $script:Card.BorderBrush = ConvertTo-Brush $script:LastAccent
    }
}

<#
.SYNOPSIS
Updates the alert state and border for the current browser context.

.DESCRIPTION
Tracks continuous time on a neutral or distracting page in a supported browser.
Once the configured threshold is reached, each sampling tick alternates the
widget border between bright and dark yellow until the user leaves the page.
#>
function Update-DistractionAlert {
    $isUnproductiveBrowser = (
        $script:CurrentCategory -in @('neutral', 'distraction') -and
        @($script:Settings.BrowserApps) -contains $script:CurrentProcess
    )

    if (-not $isUnproductiveBrowser) {
        Stop-DistractionAlert
        return
    }

    $now = Get-Date
    if ($null -eq $script:DistractionStartedAt) {
        $script:DistractionStartedAt = $now
        return
    }

    $elapsed = $now - $script:DistractionStartedAt
    if (
        -not $script:DistractionAlertActive -and
        $elapsed.TotalSeconds -ge $script:Settings.DistractionAlertSeconds
    ) {
        $script:DistractionAlertActive = $true
    }

    if ($script:DistractionAlertActive) {
        $script:DistractionBlinkOn = -not $script:DistractionBlinkOn
        if ($script:DistractionBlinkOn) {
            $script:Card.BorderThickness = [System.Windows.Thickness]::new(8)
            $script:Card.BorderBrush = ConvertTo-Brush '#FDE047'
        } else {
            $script:Card.BorderThickness = [System.Windows.Thickness]::new(3)
            $script:Card.BorderBrush = ConvertTo-Brush '#A16207'
        }
    }
}

<#
.SYNOPSIS
Opens the settings dialog and applies validated user changes.

.DESCRIPTION
Builds the WPF dialog, validates interval values, normalizes domain lists,
persists accepted settings, and resets the active scoring window.
#>
function Show-SettingsWindow {
    $settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Productivity Indicator settings"
        Width="500" Height="635"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Background="#111827"
        Foreground="#F9FAFB"
        FontFamily="Segoe UI">
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Text="Settings" FontSize="22" FontWeight="SemiBold" Margin="0,0,0,20"/>

        <Grid Grid.Row="1" Margin="0,0,0,14">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="90"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
                <TextBlock Text="Score interval (minutes)" FontWeight="SemiBold"/>
                <TextBlock Text="How often the displayed score is finalized." Foreground="#9CA3AF" FontSize="12"/>
            </StackPanel>
            <TextBox x:Name="ScoreInterval" Grid.Column="1" Height="30" Padding="7,4"/>
        </Grid>

        <Grid Grid.Row="2" Margin="0,0,0,14">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="90"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
                <TextBlock Text="Break reminder (minutes)" FontWeight="SemiBold"/>
                <TextBlock Text="Allowed range: 5 to 240 minutes." Foreground="#9CA3AF" FontSize="12"/>
            </StackPanel>
            <TextBox x:Name="BreakInterval" Grid.Column="1" Height="30" Padding="7,4"/>
        </Grid>

        <Grid Grid.Row="3" Margin="0,0,0,14">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="90"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
                <TextBlock Text="Unproductive-site alert (seconds)" FontWeight="SemiBold"/>
                <TextBlock Text="Blink the border after 1 to 3600 continuous seconds."
                           Foreground="#9CA3AF" FontSize="12"/>
            </StackPanel>
            <TextBox x:Name="DistractionAlertInterval" Grid.Column="1" Height="30" Padding="7,4"/>
        </Grid>

        <Grid Grid.Row="4" Margin="0,0,0,14">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="90"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
                <TextBlock Text="Report period (minutes)" FontWeight="SemiBold"/>
                <TextBlock Text="Allowed range: 5 minutes to 1 day (1440)."
                           Foreground="#9CA3AF" FontSize="12"/>
            </StackPanel>
            <TextBox x:Name="ReportPeriod" Grid.Column="1" Height="30" Padding="7,4"/>
        </Grid>

        <CheckBox x:Name="BreakEnabled" Grid.Row="5"
                  Content="Enable break reminders"
                  VerticalAlignment="Top" Margin="0,4,0,14"
                  Foreground="#F9FAFB"/>

        <StackPanel Grid.Row="6" Margin="0,0,0,14">
            <TextBlock Text="Productive browser domains" FontWeight="SemiBold"/>
            <TextBlock Text="Comma-separated corporate, Office, development, and work domains."
                       Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,5"/>
            <TextBox x:Name="ProductiveDomains" Height="58" Padding="7,5"
                     AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
        </StackPanel>

        <StackPanel Grid.Row="7" Margin="0,0,0,14">
            <TextBlock Text="Distracting browser domains" FontWeight="SemiBold"/>
            <TextBlock Text="Comma-separated social media, video, and entertainment domains."
                       Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,5"/>
            <TextBox x:Name="DistractionDomains" Height="58" Padding="7,5"
                     AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
        </StackPanel>

        <StackPanel Grid.Row="8" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="GenerateReportButton" Content="Generate Report"
                    Width="155" Height="32" Margin="0,0,18,0"/>
            <Button x:Name="CancelButton" Content="Cancel" Width="80" Height="32" Margin="0,0,8,0"/>
            <Button x:Name="SaveButton" Content="Save" Width="80" Height="32" IsDefault="True"/>
        </StackPanel>
    </Grid>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new([xml]$settingsXaml)
    $settingsWindow = [Windows.Markup.XamlReader]::Load($reader)
    $scoreInterval = $settingsWindow.FindName('ScoreInterval')
    $breakInterval = $settingsWindow.FindName('BreakInterval')
    $distractionAlertInterval = $settingsWindow.FindName('DistractionAlertInterval')
    $reportPeriod = $settingsWindow.FindName('ReportPeriod')
    $breakEnabled = $settingsWindow.FindName('BreakEnabled')
    $productiveDomains = $settingsWindow.FindName('ProductiveDomains')
    $distractionDomains = $settingsWindow.FindName('DistractionDomains')
    $generateReportButton = $settingsWindow.FindName('GenerateReportButton')
    $saveButton = $settingsWindow.FindName('SaveButton')
    $cancelButton = $settingsWindow.FindName('CancelButton')

    $scoreInterval.Text = [string]$script:Settings.ScoreIntervalMinutes
    $breakInterval.Text = [string]$script:Settings.BreakIntervalMinutes
    $distractionAlertInterval.Text = [string]$script:Settings.DistractionAlertSeconds
    $reportPeriod.Text = [string]$script:Settings.ReportPeriodMinutes
    $breakEnabled.IsChecked = [bool]$script:Settings.BreakReminderEnabled
    $productiveDomains.Text = @($script:Settings.ProductiveDomains) -join ', '
    $distractionDomains.Text = @($script:Settings.DistractionDomains) -join ', '

    $cancelButton.Add_Click({ $settingsWindow.DialogResult = $false })
    $generateReportButton.Add_Click({
        [int]$reportValue = 0
        if (
            -not [int]::TryParse($reportPeriod.Text, [ref]$reportValue) -or
            $reportValue -lt 5 -or
            $reportValue -gt 1440
        ) {
            [System.Windows.MessageBox]::Show(
                $settingsWindow,
                'Report period must be between 5 and 1440 minutes.',
                $script:AppName,
                'OK',
                'Warning'
            ) | Out-Null
            return
        }
        Show-DailyReportWindow $settingsWindow $reportValue
    })
    $saveButton.Add_Click({
        [int]$scoreValue = 0
        [int]$breakValue = 0
        [int]$distractionAlertValue = 0
        [int]$reportPeriodValue = 0
        $scoreValid = [int]::TryParse($scoreInterval.Text, [ref]$scoreValue)
        $breakValid = [int]::TryParse($breakInterval.Text, [ref]$breakValue)
        $distractionAlertValid = [int]::TryParse(
            $distractionAlertInterval.Text,
            [ref]$distractionAlertValue
        )
        $reportPeriodValid = [int]::TryParse($reportPeriod.Text, [ref]$reportPeriodValue)

        if (-not $scoreValid -or $scoreValue -lt 1 -or $scoreValue -gt 60) {
            [System.Windows.MessageBox]::Show(
                $settingsWindow,
                'Score interval must be between 1 and 60 minutes.',
                $script:AppName,
                'OK',
                'Warning'
            ) | Out-Null
            return
        }
        if (-not $breakValid -or $breakValue -lt 5 -or $breakValue -gt 240) {
            [System.Windows.MessageBox]::Show(
                $settingsWindow,
                'Break interval must be between 5 and 240 minutes.',
                $script:AppName,
                'OK',
                'Warning'
            ) | Out-Null
            return
        }
        if (
            -not $distractionAlertValid -or
            $distractionAlertValue -lt 1 -or
            $distractionAlertValue -gt 3600
        ) {
            [System.Windows.MessageBox]::Show(
                $settingsWindow,
                'Unproductive-site alert must be between 1 and 3600 seconds.',
                $script:AppName,
                'OK',
                'Warning'
            ) | Out-Null
            return
        }
        if (
            -not $reportPeriodValid -or
            $reportPeriodValue -lt 5 -or
            $reportPeriodValue -gt 1440
        ) {
            [System.Windows.MessageBox]::Show(
                $settingsWindow,
                'Report period must be between 5 and 1440 minutes.',
                $script:AppName,
                'OK',
                'Warning'
            ) | Out-Null
            return
        }

        $script:Settings.ScoreIntervalMinutes = $scoreValue
        $script:Settings.BreakIntervalMinutes = $breakValue
        $script:Settings.DistractionAlertSeconds = $distractionAlertValue
        $script:Settings.ReportPeriodMinutes = $reportPeriodValue
        $script:Settings.BreakReminderEnabled = [bool]$breakEnabled.IsChecked
        $script:Settings.ProductiveDomains = ConvertTo-DomainList $productiveDomains.Text
        $script:Settings.DistractionDomains = ConvertTo-DomainList $distractionDomains.Text
        try {
            Save-Settings $script:Settings
        } catch {
            [System.Windows.MessageBox]::Show(
                $settingsWindow,
                "Settings could not be saved.`n`n$($_.Exception.Message)",
                $script:AppName,
                'OK',
                'Error'
            ) | Out-Null
            return
        }

        $script:LastBreakAt = Get-Date
        Stop-DistractionAlert
        Reset-WindowMetrics
        $settingsWindow.DialogResult = $true
    })

    $settingsWindow.Owner = $script:Window
    $settingsWindow.ShowDialog() | Out-Null
}

$mainXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Productivity Indicator"
        Width="310" Height="230"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ShowInTaskbar="False"
        Topmost="True"
        ResizeMode="NoResize"
        FontFamily="Segoe UI">
    <Border x:Name="Card"
            Background="#F2111827"
            BorderBrush="#374151"
            BorderThickness="1"
            CornerRadius="18"
            Padding="14">
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="18" ShadowDepth="4" Opacity="0.35"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Grid>
                <TextBlock Text="PRODUCTIVITY"
                           Foreground="#9CA3AF"
                           FontSize="11"
                           FontWeight="SemiBold"
                           VerticalAlignment="Center"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                    <Button x:Name="SettingsButton"
                            Content="&#x2699;"
                            Width="26" Height="24"
                            Foreground="#D1D5DB"
                            Background="Transparent"
                            BorderThickness="0"
                            ToolTip="Settings"/>
                    <Button x:Name="CloseButton"
                            Content="&#x2715;"
                            Width="26" Height="24"
                            Foreground="#D1D5DB"
                            Background="Transparent"
                            BorderThickness="0"
                            ToolTip="Close"/>
                </StackPanel>
            </Grid>

            <Grid Grid.Row="1" Margin="0,4,0,4">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="92"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="EmojiText"
                           Text="&#x1F642;"
                           FontFamily="Segoe UI Emoji"
                           FontSize="60"
                           HorizontalAlignment="Center"
                           VerticalAlignment="Center"/>
                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="8,0,0,0">
                    <StackPanel Orientation="Horizontal">
                        <TextBlock x:Name="ScoreText"
                                   Text="50"
                                   Foreground="#F9FAFB"
                                   FontSize="34"
                                   FontWeight="Bold"/>
                        <TextBlock Text="/100"
                                   Foreground="#9CA3AF"
                                   FontSize="14"
                                   VerticalAlignment="Bottom"
                                   Margin="3,0,0,6"/>
                    </StackPanel>
                    <TextBlock x:Name="StatusText"
                               Text="Building your first score..."
                               Foreground="#D1D5DB"
                               FontSize="11"
                               TextWrapping="Wrap"
                               MaxWidth="125"/>
                </StackPanel>
            </Grid>

            <StackPanel Grid.Row="2" Margin="0,0,0,8">
                <ProgressBar x:Name="ScoreBar"
                             Height="5"
                             Minimum="0"
                             Maximum="100"
                             Value="50"
                             Background="#374151"
                             Foreground="#84CC16"
                             BorderThickness="0"/>
                <TextBlock x:Name="NextUpdateText"
                           Text=""
                           Foreground="#6B7280"
                           FontSize="9"
                           HorizontalAlignment="Right"
                           Margin="0,4,0,0"/>
            </StackPanel>

            <StackPanel Grid.Row="3">
                <TextBlock Text="TOP ACTIVITY - LAST 5 MIN"
                           Foreground="#6B7280"
                           FontSize="9"
                           FontWeight="SemiBold"
                           Margin="2,0,0,3"/>
                <UniformGrid Columns="3">
                    <Border Background="#1F2937" CornerRadius="7" Margin="2,0" Padding="6,5">
                        <TextBlock x:Name="UsageLabel1" Text="1  --"
                                   Foreground="#E5E7EB" FontSize="10"
                                   TextTrimming="CharacterEllipsis"/>
                    </Border>
                    <Border Background="#1F2937" CornerRadius="7" Margin="2,0" Padding="6,5">
                        <TextBlock x:Name="UsageLabel2" Text="2  --"
                                   Foreground="#E5E7EB" FontSize="10"
                                   TextTrimming="CharacterEllipsis"/>
                    </Border>
                    <Border Background="#1F2937" CornerRadius="7" Margin="2,0" Padding="6,5">
                        <TextBlock x:Name="UsageLabel3" Text="3  --"
                                   Foreground="#E5E7EB" FontSize="10"
                                   TextTrimming="CharacterEllipsis"/>
                    </Border>
                </UniformGrid>
            </StackPanel>
        </Grid>
    </Border>
</Window>
"@

$reader = [System.Xml.XmlNodeReader]::new([xml]$mainXaml)
$script:Window = [Windows.Markup.XamlReader]::Load($reader)
$script:Card = $script:Window.FindName('Card')
$script:EmojiText = $script:Window.FindName('EmojiText')
$script:ScoreText = $script:Window.FindName('ScoreText')
$script:StatusText = $script:Window.FindName('StatusText')
$script:ScoreBar = $script:Window.FindName('ScoreBar')
$script:NextUpdateText = $script:Window.FindName('NextUpdateText')
$script:UsageLabels = @(
    $script:Window.FindName('UsageLabel1'),
    $script:Window.FindName('UsageLabel2'),
    $script:Window.FindName('UsageLabel3')
)
$settingsButton = $script:Window.FindName('SettingsButton')
$closeButton = $script:Window.FindName('CloseButton')

$script:Settings = Get-Settings
$script:LastBreakAt = Get-Date
$script:LastScore = 50
$script:LastAccent = '#84CC16'
$script:LastCursor = $null
$script:LeftMouseDown = $false
$script:RightMouseDown = $false
$script:MiddleMouseDown = $false
$script:BrowserUrlCache = @{}
$script:UsageSamples = [System.Collections.Generic.Queue[object]]::new()
$script:CurrentProcess = ''
$script:CurrentCategory = 'idle'
$script:DistractionStartedAt = $null
$script:DistractionAlertActive = $false
$script:DistractionBlinkOn = $false
$script:DailyStats = Get-DailyStats
$script:DailyStatsDirty = $false
$script:LastDailySaveAt = Get-Date
Reset-WindowMetrics

<#
.SYNOPSIS
Refreshes the widget with a newly calculated productivity result.

.DESCRIPTION
Updates the score, presentation, progress bar, border color, and diagnostic
tooltip shown on the main window.
#>
function Update-Display {
    param($Result)

    $presentation = Get-ScorePresentation $Result.Score
    $script:LastScore = $Result.Score
    $script:EmojiText.Text = $presentation.Emoji
    $script:ScoreText.Text = [string]$Result.Score
    $script:StatusText.Text = $presentation.Message
    $script:ScoreBar.Value = $Result.Score
    $script:ScoreBar.Foreground = ConvertTo-Brush $presentation.Accent
    $script:LastAccent = $presentation.Accent
    if (-not $script:DistractionAlertActive) {
        $script:Card.BorderBrush = ConvertTo-Brush $presentation.Accent
    }
    $script:Window.ToolTip = "Dominant app: $($Result.DominantApp)`nApp context: $($Result.ContextScore)`nInteraction: $($Result.InteractionScore)`nActivity: $($Result.ActivityScore)`nFocus consistency: $($Result.ConsistencyScore)"
}

<#
.SYNOPSIS
Refreshes the three rolling-usage labels in the widget.
#>
function Update-UsageDisplay {
    $topUsage = @(Get-RollingUsageTop)
    for ($index = 0; $index -lt $script:UsageLabels.Count; $index++) {
        $label = $script:UsageLabels[$index]
        if ($index -lt $topUsage.Count) {
            $entry = $topUsage[$index]
            $duration = Format-UsageDuration $entry.Seconds
            $label.Text = "$($index + 1)  $($entry.Name) - $duration"
            $label.ToolTip = "$($entry.Name): $duration in the last 5 minutes"
        } else {
            $label.Text = "$($index + 1)  --"
            $label.ToolTip = 'No activity collected yet'
        }
    }
}

if ($SelfTest) {
    $script:Metrics.productive.Seconds = 60
    $script:Metrics.productive.ActiveSeconds = 60
    $script:Metrics.productive.Clicks = 8
    $script:Metrics.productive.Distance = 3000
    $script:AppSeconds.devenv = 60
    $productiveResult = Get-ProductivityScore

    Reset-WindowMetrics
    $script:Metrics.distraction.Seconds = 60
    $script:Metrics.distraction.ActiveSeconds = 60
    $script:Metrics.distraction.Clicks = 1
    $script:Metrics.distraction.Distance = 300
    $script:AppSeconds.youtube = 60
    $distractionResult = Get-ProductivityScore

    $failures = @()
    if ($productiveResult.Score -lt 75) {
        $failures += "Productive sample scored $($productiveResult.Score), expected at least 75."
    }
    if ($distractionResult.Score -ge 50) {
        $failures += "Distraction sample scored $($distractionResult.Score), expected below 50."
    }
    if ((Get-ScorePresentation 74).Emoji -eq (Get-ScorePresentation 75).Emoji) {
        $failures += 'Emoji boundary at 75 is not distinct.'
    }
    if ((Get-ScorePresentation 24).Emoji -eq (Get-ScorePresentation 25).Emoji) {
        $failures += 'Emoji boundary at 25 is not distinct.'
    }
    if ((Resolve-ContextCategory 'msedge' 'Reddit' 'https://www.reddit.com/r/programming') -ne 'distraction') {
        $failures += 'Reddit domain was not classified as distracting.'
    }
    if ((Resolve-ContextCategory 'chrome' 'Microsoft 365' 'https://contoso.sharepoint.com/sites/work') -ne 'productive') {
        $failures += 'SharePoint domain was not classified as productive.'
    }
    if ((Resolve-ContextCategory 'msedge' 'Internal portal' 'https://microsoftinternal.example.com/work') -ne 'productive') {
        $failures += 'A domain containing microsoft was not classified as productive.'
    }
    if ((Resolve-ContextCategory 'chrome' 'Video' 'https://youtube.com/watch?v=test') -ne 'distraction') {
        $failures += 'YouTube domain was not classified as distracting.'
    }
    $script:UsageSamples.Clear()
    $usageTestTime = Get-Date
    1..3 | ForEach-Object { Add-RollingUsageSample 'code' $usageTestTime }
    1..2 | ForEach-Object { Add-RollingUsageSample 'github.com' $usageTestTime }
    Add-RollingUsageSample 'outlook' $usageTestTime
    $usageTop = @(Get-RollingUsageTop $usageTestTime)
    if ($usageTop.Count -ne 3 -or $usageTop[0].Name -ne 'code' -or $usageTop[1].Name -ne 'github.com') {
        $failures += 'Rolling usage ranking did not return the expected top applications.'
    }
    $script:UsageSamples.Clear()
    Add-RollingUsageSample 'stale' $usageTestTime.AddMinutes(-6)
    Add-RollingUsageSample 'current' $usageTestTime
    $prunedUsage = @(Get-RollingUsageTop $usageTestTime)
    if ($prunedUsage.Count -ne 1 -or $prunedUsage[0].Name -ne 'current') {
        $failures += 'Rolling usage did not discard activity older than five minutes.'
    }
    $script:CurrentProcess = 'chrome'
    $script:CurrentCategory = 'distraction'
    $script:DistractionStartedAt = (Get-Date).AddSeconds(-$script:Settings.DistractionAlertSeconds)
    Update-DistractionAlert
    if (-not $script:DistractionAlertActive) {
        $failures += 'Distracting-site alert did not activate at the configured threshold.'
    }
    if ($script:Card.BorderThickness.Left -ne 8) {
        $failures += 'Distracting-site alert did not apply the bright border state.'
    }
    Update-DistractionAlert
    if ($script:Card.BorderThickness.Left -ne 3) {
        $failures += 'Distracting-site alert did not apply the alternate border state.'
    }
    $script:CurrentCategory = 'productive'
    Update-DistractionAlert
    if ($script:DistractionAlertActive -or $null -ne $script:DistractionStartedAt) {
        $failures += 'Distracting-site alert did not reset after leaving the distracting page.'
    }
    $script:CurrentProcess = 'msedge'
    $script:CurrentCategory = 'neutral'
    $script:DistractionStartedAt = (Get-Date).AddSeconds(-$script:Settings.DistractionAlertSeconds)
    Update-DistractionAlert
    if (-not $script:DistractionAlertActive) {
        $failures += 'Neutral browser pages were not treated as unproductive for the alert.'
    }
    Stop-DistractionAlert
    $dailyTestStats = New-DailyStats
    $dailyTestStats.AppSeconds.code = 80
    $dailyTestStats.AppSeconds.'youtube.com' = 20
    $dailyTestStats.CategorySeconds.productive = 80
    $dailyTestStats.CategorySeconds.distraction = 20
    $dailyTestNow = Get-Date
    $dailyTestBucket = [ordered]@{
        Minute = $dailyTestNow.ToString('yyyy-MM-ddTHH:mm:00')
        AppSeconds = @{ code = 80; 'youtube.com' = 20 }
        CategorySeconds = [ordered]@{
            productive = 80
            focus = 0
            neutral = 0
            distraction = 20
            idle = 0
        }
    }
    $dailyTestStats.Buckets.Add($dailyTestBucket) | Out-Null
    $dailyTestReport = Get-DailyReport -PeriodMinutes 60 -Now $dailyTestNow -StatsRecords @($dailyTestStats)
    if ($dailyTestReport.Score -ne 73) {
        $failures += "Daily report score was $($dailyTestReport.Score), expected 73."
    }
    if ($dailyTestReport.TopUsage.Count -ne 2 -or $dailyTestReport.TopUsage[0].Name -ne 'code') {
        $failures += 'Daily report did not rank app and site usage correctly.'
    }
    $shortReport = Get-DailyReport -PeriodMinutes 5 -Now $dailyTestNow.AddMinutes(10) -StatsRecords @($dailyTestStats)
    if ($shortReport.TotalSeconds -ne 0) {
        $failures += 'Report period did not exclude activity outside the configured window.'
    }

    if ($failures.Count -gt 0) {
        $failures | ForEach-Object { Write-Error $_ }
        exit 1
    }

    "Self-test passed. Productive=$($productiveResult.Score), Distraction=$($distractionResult.Score)"
    exit 0
}

$script:Window.Add_Loaded({
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $script:Window.Left = $workArea.Right - $script:Window.Width - 16
    $script:Window.Top = $workArea.Bottom - $script:Window.Height - 16
    if ($StartMinimized) {
        $script:Window.Opacity = 0
        $fadeTimer = [Windows.Threading.DispatcherTimer]::new()
        $fadeTimer.Interval = [TimeSpan]::FromMilliseconds(80)
        $fadeTimer.Add_Tick({
            $script:Window.Opacity = [Math]::Min(1, $script:Window.Opacity + 0.2)
            if ($script:Window.Opacity -ge 1) { $fadeTimer.Stop() }
        })
        $fadeTimer.Start()
    }
})

$script:Window.Add_MouseLeftButtonDown({
    if ($_.ButtonState -eq 'Pressed') {
        $script:Window.DragMove()
    }
})

$settingsButton.Add_Click({
    $_.Handled = $true
    Show-SettingsWindow
})

$closeButton.Add_Click({
    $_.Handled = $true
    $script:Window.Close()
})

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    Add-ActivitySample
    Update-DistractionAlert
    Update-UsageDisplay
    if (
        $script:DailyStatsDirty -and
        ((Get-Date) - $script:LastDailySaveAt).TotalSeconds -ge 60
    ) {
        try {
            Save-DailyStats
        } catch {
            $script:NextUpdateText.Text = 'daily report save failed'
        }
    }

    $elapsed = (Get-Date) - $script:WindowStartedAt
    $scoreIntervalSeconds = $script:Settings.ScoreIntervalMinutes * 60
    $remainingSeconds = [Math]::Max(0, [Math]::Ceiling($scoreIntervalSeconds - $elapsed.TotalSeconds))
    $script:NextUpdateText.Text = "updates in $remainingSeconds sec"

    if ($elapsed.TotalSeconds -ge $scoreIntervalSeconds) {
        $result = Get-ProductivityScore
        Update-Display $result
        Reset-WindowMetrics
    }

    if ($script:Settings.BreakReminderEnabled) {
        $breakElapsed = (Get-Date) - $script:LastBreakAt
        if ($breakElapsed.TotalMinutes -ge $script:Settings.BreakIntervalMinutes) {
            Show-BreakReminder
        }
    }
})

$script:Window.Add_Closed({
    $timer.Stop()
    try {
        Save-DailyStats
    } catch {
        [System.Diagnostics.Debug]::WriteLine($_.Exception.Message)
    }
})
$timer.Start()
$script:Window.ShowDialog() | Out-Null
