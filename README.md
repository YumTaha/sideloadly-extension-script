# SideloadlyManager

### What it does

`SideloadlyManager.ps1` runs on a schedule and does two things every poll:

1. **Expiry alerts** — reads Sideloadly's SQLite database, calculates how many days each sideloaded app has left, and fires a Windows toast when any app is ≤4 days from expiry. Alerts have a 6-hour cooldown so you don't get spammed every poll.

2. **Daemon lifecycle** — detects when your iPhone connects/disconnects via WPD (Windows Portable Devices). When the phone is connected **and** at least one app is ≤3 days from expiry, it starts `sideloadlydaemon.exe` (and the required iCloud helpers) so the daemon can auto-refresh the signing. When the phone disconnects, it tears everything down after a 90-second grace period.

> **Why the ≤3-day gate on startup?** Sideloadly's daemon only auto-refreshes an app when it's within `refresh_at_hours` (default 96 h = 4 days) of expiry. Starting the daemon when nothing is due for renewal would spin it up for no reason.

---

### Prerequisites

| Requirement | How to install |
|---|---|
| [Sideloadly](https://sideloadly.io) | Install normally; daemon path is auto-detected |
| `sqlite3.exe` | `winget install SQLite.SQLite` — WinGet path is probed automatically, PATH not required |
| iCloud for Windows | Required for `iCloudServices.exe` / `iCloudDrive.exe` helpers |

---

### Task Scheduler setup

The script is intended to run automatically. Create a scheduled task that fires it every 15 minutes:

**Option A — GUI settings:**

| Setting | Value |
|---|---|
| **Trigger** | On a schedule → Daily, repeat every **15 minutes** indefinitely |
| **Action** | `pwsh.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\mehdi\Scripts\SideloadlyManager.ps1"` |
| **Run as** | Your user account (must be logged in; needed for WPD detection and toasts) |
| **Run whether user is logged on or not** | ❌ Off — toasts require an interactive session |
| **Run with highest privileges** | ❌ Off — elevation breaks WPD detection and HKCU toast registration |
| **Hidden** | ✅ On |
| **Stop task if it runs longer than** | 5 minutes |

**Option B — Quick PowerShell setup:**

```powershell
$action  = New-ScheduledTaskAction -Execute 'pwsh.exe' `
             -Argument '-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\mehdi\Scripts\SideloadlyManager.ps1"'
$trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 15) -Once -At (Get-Date)
$settings = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName 'SideloadlyManager' -Action $action -Trigger $trigger -Settings $settings -RunLevel Limited
```

To run the alert-only path more frequently (e.g. every 5 min) without the daemon logic, add a second task with the `-AlertOnly` flag.

---

### Files created at runtime

| File | Purpose |
|---|---|
| `%LOCALAPPDATA%\Sideloadly\.auto-managed` | JSON flag marking that this script started the daemon (`StartedAt`, `StartedHelpers`). Deleted on teardown. |
| `%LOCALAPPDATA%\Sideloadly\.last-expiry-alert` | ISO timestamp of the last expiry toast. Enforces the 6-hour cooldown. Deleted when apps are refreshed. |
| `%TEMP%\sideloadly_check.db` | Temporary copy of `installations.db` used for querying (avoids locking the live DB). |
| `C:\Users\mehdi\Scripts\SideloadlyManager.log` | Rolling log, rotates at 500 KB → `.log.old`. |

---

### Parameters / testing

```powershell
# Confirm toasts work
.\SideloadlyManager.ps1 -TestToast -DebugMode

# Simulate phone connected
.\SideloadlyManager.ps1 -TestPhone -DebugMode

# Simulate an app expiring in 2 days (triggers the alert toast)
.\SideloadlyManager.ps1 -TestExpireDays 2 -AlertOnly -DebugMode

# Only check expiry — never touch the daemon (safe to run any time)
.\SideloadlyManager.ps1 -AlertOnly
```

---

### Notification appearance

Toasts appear under **"Sideloadly Manager"** in Windows Action Center. The AUMID (`SideloadlyManager.Notify`) is registered in `HKCU:\Software\Classes\AppUserModelId` on the first run. If toasts stop appearing, check that notifications for this app aren't disabled in **Settings → System → Notifications**.

---

### Thresholds (quick reference)

| Variable | Default | Where |
|---|---|---|
| Alert threshold (days before expiry) | 4 days | `$threshold = 4` |
| Daemon start threshold | ≤3 days | `$needsRefresh` filter in Case 1 |
| Alert cooldown | 6 hours | `$AlertCooldown = 6` |
| Daemon teardown grace period | 90 seconds | hardcoded in Case 3 |
| Log rotation size | 500 KB | `$LogMaxBytes = 500KB` |
