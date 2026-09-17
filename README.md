# Productivity Indicator

A small, always-on-top Windows widget that estimates a productivity score from 0 to 100 every minute. It stays in the bottom-right corner above the taskbar and shows:

- 😄 **75-100** - highest productivity
- 🙂 **50-74** - positive productivity
- 😟 **25-49** - low productivity
- 😢 **0-24** - very low productivity
- A motivational message selected in 10-point score bands
- A configurable break reminder, set to 40 minutes by default
- A blinking yellow border after a configurable period on a neutral or distracting website
- Active browser-site classification for Chrome, Edge, Firefox, Brave, Opera, and Vivaldi
- Three compact labels showing the most-used apps or browser sites in the last five minutes
- A configurable 5-minute to 24-hour report with the top 10 apps/sites, time spent, usage share, and an overall productivity score

## Run

Double-click `Start-ProductivityIndicator.cmd`.

The app requires Windows PowerShell 5.1 or PowerShell 7 on Windows. It does not require a .NET SDK or an installer.

Use the gear button to configure the score interval, break interval, break reminders, report period, unproductive-site alert threshold, and productive/distracting browser domains. Set the report period from 5 to 1440 minutes, then select **Generate Report** to view the top 10 apps/sites and overall score for that rolling period. The alert defaults to 20 continuous seconds on a neutral or distracting browser page, can be configured in seconds, and stops as soon as you leave it. Settings are saved to:

```text
%LOCALAPPDATA%\ProductivityIndicator\settings.json
```

Activity totals and compact per-minute report data are stored locally in date-specific `daily-activity-YYYY-MM-DD.json` files in the same directory.

## Scoring model

Each scoring window combines:

| Signal | Weight | Behavior |
|---|---:|---|
| App context | 55% | Work apps and configured corporate/Office domains receive high base scores, reading/focus apps receive positive scores, general apps are neutral, and social/video domains receive low scores. |
| Context-sensitive interaction | 25% | Work apps benefit from appropriate clicks and movement. Reading contexts reward low pointer activity instead of treating it as inactivity. |
| Recent activity | 15% | Uses Windows' last-input time without recording keys or content. Reading apps have a longer inactivity allowance. |
| Focus consistency | 5% | Rewards the share of the window spent in productive or focused contexts. |

The final value is clamped to 0-100. Browser domains are matched exactly or as subdomains, so `sharepoint.com` also matches `contoso.sharepoint.com`. Any hostname containing `microsoft` is also productive. Distracting domains take precedence. Defaults include Reddit, YouTube, Instagram, Facebook, TikTok, X/Twitter, Twitch, and streaming sites as distracting; Microsoft 365, Office, SharePoint, Teams, Outlook, Azure DevOps, GitHub, Microsoft Learn, Power BI, Power Apps, and Dynamics domains are productive.

## Privacy

Activity is calculated locally. The app samples the foreground process name, foreground window title, active browser address for immediate domain classification, mouse clicks, cursor travel distance, and Windows' last-input timestamp. Daily reports store only aggregate seconds by app name or browser hostname and productivity category in local JSON files. Full URLs are not stored or sent anywhere. The app does not record keystrokes, click coordinates, document contents, window titles, or screenshots.
