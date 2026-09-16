# Productivity Indicator

A small, always-on-top Windows widget that estimates a productivity score from 0 to 100 every minute. It stays in the bottom-right corner above the taskbar and shows:

- 😄 **75-100** - highest productivity
- 🙂 **50-74** - positive productivity
- 😟 **25-49** - low productivity
- 😢 **0-24** - very low productivity
- A motivational message selected in 10-point score bands
- A configurable break reminder, set to 40 minutes by default
- Active browser-site classification for Chrome, Edge, Firefox, Brave, Opera, and Vivaldi

## Run

Double-click `Start-ProductivityIndicator.cmd`.

The app requires Windows PowerShell 5.1 or PowerShell 7 on Windows. It does not require a .NET SDK or an installer.

Use the gear button to configure the score interval, break interval, break reminders, and productive/distracting browser domains. Settings are saved to:

```text
%LOCALAPPDATA%\ProductivityIndicator\settings.json
```

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

Activity is calculated locally. The app samples the foreground process name, foreground window title, active browser address for immediate domain classification, mouse clicks, cursor travel distance, and Windows' last-input timestamp. URLs are not stored in history or sent anywhere. It does not record keystrokes, click coordinates, document contents, activity history, or screenshots.
