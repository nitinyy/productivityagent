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
    $settings.BreakReminderEnabled = [bool]$settings.BreakReminderEnabled
    return $settings
}

function Save-Settings {
    param([System.Collections.IDictionary]$Settings)

    New-Item -ItemType Directory -Path $script:SettingsDirectory -Force | Out-Null
    $Settings | ConvertTo-Json -Depth 4 | Set-Content -Path $script:SettingsPath -Encoding UTF8
}

function New-Metric {
    return [ordered]@{
        Seconds = 0.0
        ActiveSeconds = 0.0
        Clicks = 0
        Distance = 0.0
    }
}

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

function ConvertTo-DomainList {
    param([string]$Text)

    return @($Text -split '[,\r\n;]+' |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { $_ } |
        Select-Object -Unique)
}

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

function ConvertTo-Brush {
    param([string]$Color)
    return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

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

function Show-SettingsWindow {
    $settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Productivity Indicator settings"
        Width="500" Height="505"
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

        <CheckBox x:Name="BreakEnabled" Grid.Row="3"
                  Content="Enable break reminders"
                  VerticalAlignment="Top" Margin="0,4,0,14"
                  Foreground="#F9FAFB"/>

        <StackPanel Grid.Row="4" Margin="0,0,0,14">
            <TextBlock Text="Productive browser domains" FontWeight="SemiBold"/>
            <TextBlock Text="Comma-separated corporate, Office, development, and work domains."
                       Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,5"/>
            <TextBox x:Name="ProductiveDomains" Height="58" Padding="7,5"
                     AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
        </StackPanel>

        <StackPanel Grid.Row="5" Margin="0,0,0,14">
            <TextBlock Text="Distracting browser domains" FontWeight="SemiBold"/>
            <TextBlock Text="Comma-separated social media, video, and entertainment domains."
                       Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,5"/>
            <TextBox x:Name="DistractionDomains" Height="58" Padding="7,5"
                     AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
        </StackPanel>

        <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
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
    $breakEnabled = $settingsWindow.FindName('BreakEnabled')
    $productiveDomains = $settingsWindow.FindName('ProductiveDomains')
    $distractionDomains = $settingsWindow.FindName('DistractionDomains')
    $saveButton = $settingsWindow.FindName('SaveButton')
    $cancelButton = $settingsWindow.FindName('CancelButton')

    $scoreInterval.Text = [string]$script:Settings.ScoreIntervalMinutes
    $breakInterval.Text = [string]$script:Settings.BreakIntervalMinutes
    $breakEnabled.IsChecked = [bool]$script:Settings.BreakReminderEnabled
    $productiveDomains.Text = @($script:Settings.ProductiveDomains) -join ', '
    $distractionDomains.Text = @($script:Settings.DistractionDomains) -join ', '

    $cancelButton.Add_Click({ $settingsWindow.DialogResult = $false })
    $saveButton.Add_Click({
        [int]$scoreValue = 0
        [int]$breakValue = 0
        $scoreValid = [int]::TryParse($scoreInterval.Text, [ref]$scoreValue)
        $breakValid = [int]::TryParse($breakInterval.Text, [ref]$breakValue)

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

        $script:Settings.ScoreIntervalMinutes = $scoreValue
        $script:Settings.BreakIntervalMinutes = $breakValue
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
        Width="270" Height="184"
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

            <Grid Grid.Row="2">
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
                           Margin="0,9,0,0"/>
            </Grid>
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
$settingsButton = $script:Window.FindName('SettingsButton')
$closeButton = $script:Window.FindName('CloseButton')

$script:Settings = Get-Settings
$script:LastBreakAt = Get-Date
$script:LastScore = 50
$script:LastCursor = $null
$script:LeftMouseDown = $false
$script:RightMouseDown = $false
$script:MiddleMouseDown = $false
$script:BrowserUrlCache = @{}
Reset-WindowMetrics

function Update-Display {
    param($Result)

    $presentation = Get-ScorePresentation $Result.Score
    $script:LastScore = $Result.Score
    $script:EmojiText.Text = $presentation.Emoji
    $script:ScoreText.Text = [string]$Result.Score
    $script:StatusText.Text = $presentation.Message
    $script:ScoreBar.Value = $Result.Score
    $script:ScoreBar.Foreground = ConvertTo-Brush $presentation.Accent
    $script:Card.BorderBrush = ConvertTo-Brush $presentation.Accent
    $script:Window.ToolTip = "Dominant app: $($Result.DominantApp)`nApp context: $($Result.ContextScore)`nInteraction: $($Result.InteractionScore)`nActivity: $($Result.ActivityScore)`nFocus consistency: $($Result.ConsistencyScore)"
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

$script:Window.Add_Closed({ $timer.Stop() })
$timer.Start()
$script:Window.ShowDialog() | Out-Null
