<#
.SYNOPSIS
    Manages Sideloadly daemon lifecycle and app-expiry alerts.

.PARAMETER AlertOnly
    Only check expiry and notify. Never touch daemon or helpers.

.PARAMETER DebugMode
    Print all log lines to the console in colour (log file is always written).

.PARAMETER TestToast
    Fire a test notification and exit - confirms toasts work.

.PARAMETER TestPhone
    Pretend an iPhone is connected for this run.

.PARAMETER TestNoPhone
    Pretend no phone is connected, even if one is plugged in.

.PARAMETER TestExpireDays
    Override DaysLeft for every app to this number (test alert thresholds).
    Example: -TestExpireDays 2  fires the "expiring soon" toast.
#>
param(
    [switch]$AlertOnly,
    [switch]$DebugMode,
    [switch]$TestToast,
    [switch]$TestPhone,
    [switch]$TestNoPhone,
    [int]$TestExpireDays = -1
)

# ── Paths ──────────────────────────────────────────────────────────────────────
$DaemonPath   = "$env:LOCALAPPDATA\Sideloadly\sideloadlydaemon.exe"
$DbPath       = "$env:LOCALAPPDATA\Sideloadly\installations.db"
$DbCopy       = "$env:TEMP\sideloadly_check.db"
$FlagFile     = "$env:LOCALAPPDATA\Sideloadly\.auto-managed"
$LogFile      = "$PSScriptRoot\SideloadlyManager.log"
$LogMaxBytes    = 500KB
$AlertCooldown  = 6   # hours between repeat expiry alerts (prevents spam from 5-min polling)
$AlertFlagFile  = "$env:LOCALAPPDATA\Sideloadly\.last-expiry-alert"

$AppleHelpers = [ordered]@{
    iCloudServices = "C:\Program Files (x86)\Common Files\Apple\Internet Services\iCloudServices.exe"
    iCloudDrive    = "C:\Program Files (x86)\Common Files\Apple\Internet Services\iCloudDrive.exe"
}

# ── Logging ────────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Msg"

    # Rotate log if over size limit
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt $LogMaxBytes) {
        Move-Item $LogFile "$LogFile.old" -Force -ErrorAction SilentlyContinue
    }
    Add-Content $LogFile $line -ErrorAction SilentlyContinue

    if ($DebugMode) {
        $fg = switch ($Level) {
            "OK"    { "Green"  }
            "WARN"  { "Yellow" }
            "ERROR" { "Red"    }
            "TEST"  { "Magenta"}
            default { "Cyan"   }
        }
        Write-Host $line -ForegroundColor $fg
    }
}

# ── Find sqlite3 ───────────────────────────────────────────────────────────────
function Get-Sqlite3 {
    # 1. Already on PATH (after shell restart)
    $cmd = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # 2. WinGet installs sqlite3 here but doesn't refresh PATH in running processes
    $wingetBase = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    $found = Get-ChildItem $wingetBase -Recurse -Filter "sqlite3.exe" -ErrorAction SilentlyContinue |
             Where-Object { $_.DirectoryName -notmatch 'analyzer|rsync' } |
             Select-Object -First 1
    if ($found) { return $found.FullName }

    return $null
}

# ── Toast ──────────────────────────────────────────────────────────────────────
# WinRT type syntax only works in Windows PowerShell 5.1, not PS7.
# We write a temp .ps1 file and run it with powershell.exe (5.1) to avoid
# command-line escaping issues.
#
# Root cause of invisible notifications: Windows silently drops toasts from
# unregistered App IDs. The fix (from imabdk/Toast-Notification-Script):
#   1. Register a custom AUMID under HKCU:\Software\Classes\AppUserModelId
#   2. Enable it in HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings
# This makes the notification appear as "Sideloadly Manager" in Action Center.
function Send-Toast {
    param([string]$Title, [string]$Body)
    Write-Log "TOAST  title='$Title'  body='$Body'"
    try {
        $t   = [System.Security.SecurityElement]::Escape($Title)
        $b   = [System.Security.SecurityElement]::Escape($Body)
        $tmp = [System.IO.Path]::GetTempFileName() + ".ps1"
        Set-Content -Path $tmp -Encoding UTF8 -Value @"
`$AppId   = 'SideloadlyManager.Notify'
`$AumPath = "HKCU:\Software\Classes\AppUserModelId\`$AppId"
`$NotPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\`$AppId"

if (-not (Test-Path `$AumPath)) {
    New-Item -Path `$AumPath -Force | Out-Null
    New-ItemProperty -Path `$AumPath -Name DisplayName    -Value 'Sideloadly Manager' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path `$AumPath -Name ShowInSettings -Value 1 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path `$AumPath -Name IconUri        -Value '%SystemRoot%\ImmersiveControlPanel\images\logo.png' -PropertyType ExpandString -Force | Out-Null
}
if (-not (Test-Path `$NotPath)) {
    New-Item -Path `$NotPath -Force | Out-Null
    New-ItemProperty -Path `$NotPath -Name ShowInActionCenter -Value 1 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path `$NotPath -Name Enabled            -Value 1 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path `$NotPath -Name SoundFile          -Value '' -PropertyType String -Force | Out-Null
}
if ((Get-ItemProperty `$NotPath -Name Enabled -ErrorAction SilentlyContinue).Enabled -ne 1) {
    Set-ItemProperty -Path `$NotPath -Name Enabled -Value 1 -Force
}

[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
`$xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
`$xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>$t</text><text>$b</text></binding></visual></toast>')
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(`$AppId).Show([Windows.UI.Notifications.ToastNotification]::new(`$xml))
"@
        # Use ProcessStartInfo with CreateNoWindow so no console window flashes.
        # -WindowStyle Hidden alone only hides the window after it appears;
        # CreateNoWindow=true + UseShellExecute=false never creates it at all.
        $psi                  = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName         = "powershell.exe"
        $psi.Arguments        = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tmp`""
        $psi.WindowStyle      = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow   = $true
        $psi.UseShellExecute  = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        if ($proc.ExitCode -eq 0) { Write-Log "Toast delivered" "OK" }
        else { Write-Log "Toast powershell.exe exited $($proc.ExitCode)" "WARN" }
    } catch {
        Write-Log "Toast failed: $_" "ERROR"
    }
}

# ── App expiry from DB ─────────────────────────────────────────────────────────
function Get-AppExpirations {
    $sq3 = Get-Sqlite3
    if (-not $sq3) {
        Write-Log "sqlite3 not found - cannot read DB" "ERROR"
        return @()
    }
    Write-Log "sqlite3: $sq3"

    if (-not (Test-Path $DbPath)) {
        Write-Log "DB not found: $DbPath" "ERROR"
        return @()
    }

    try {
        [System.IO.File]::Copy($DbPath, $DbCopy, $true)
        Write-Log "DB copied OK -> $DbCopy" "OK"
    } catch {
        Write-Log "DB copy failed: $_" "ERROR"
        return @()
    }

    $query = @"
SELECT i.name, i.final_bundle_id, i.last_updated, i.known_ttl, i.refresh_at_hours, d.name
FROM   installations i
LEFT JOIN devices d ON d.udid = i.device_udid
WHERE  (i.deleted_at IS NULL OR i.deleted_at = '' OR i.deleted_at LIKE '0001-01-%')
  AND  i.name IS NOT NULL AND i.name != ''
ORDER BY i.last_updated;
"@

    $rows = & $sq3 -separator "|" $DbCopy $query 2>&1
    Write-Log "DB query returned $(@($rows).Count) row(s)"

    $apps = @()
    foreach ($row in $rows) {
        $p = $row -split '\|'
        if ($p.Count -lt 5) { Write-Log "Skipping malformed row: '$row'" "WARN"; continue }

        try {
            $lastUpd  = [datetimeoffset]::Parse($p[2])
            $ttlDays  = [int]$p[3]
            $expiry   = $lastUpd.AddDays($ttlDays)
            $daysLeft = [math]::Floor(($expiry - [datetimeoffset]::Now).TotalDays)
            $app = [PSCustomObject]@{
                Name        = $p[0]
                BundleId    = $p[1]
                LastUpdated = $lastUpd.LocalDateTime
                ExpiresAt   = $expiry.LocalDateTime
                DaysLeft    = $daysLeft
                RefreshHrs  = [int]$p[4]
                Device      = if ($p.Count -gt 5) { $p[5] } else { "unknown" }
            }
            $apps += $app
            Write-Log ("  App: '{0}' | device: {1} | last signed: {2:MMM d HH:mm} | expires: {3:MMM d} | days left: {4}" -f `
                $app.Name, $app.Device, $app.LastUpdated, $app.ExpiresAt, $app.DaysLeft)
        } catch {
            Write-Log "Failed to parse row '$row': $_" "WARN"
        }
    }
    return $apps
}

# ── iPhone detection ───────────────────────────────────────────────────────────
function Test-AppleDeviceConnected {
    if ($TestPhone -and -not $TestNoPhone) {
        Write-Log "TEST: phone forced ON" "TEST"
        return $true
    }
    if ($TestNoPhone) {
        Write-Log "TEST: phone forced OFF" "TEST"
        return $false
    }
    $devices = Get-PnpDevice -Class 'WPD' -ErrorAction SilentlyContinue |
               Where-Object { $_.FriendlyName -match 'Apple iPhone|Apple iPad|Apple iPod' -and
                              $_.Status -eq 'OK' }
    if ($devices) {
        Write-Log "Phone detected: $(($devices | Select-Object -ExpandProperty FriendlyName) -join ', ')" "OK"
        return $true
    }
    Write-Log "No Apple WPD device found (phone not connected or not trusted)"
    return $false
}

# ── Apple helper start ─────────────────────────────────────────────────────────
function Start-AppleHelper {
    param([string]$Name, [string]$Path)
    if (Get-Process -Name $Name -ErrorAction SilentlyContinue) {
        Write-Log "$Name already running - skip"
        return $false
    }
    if (-not (Test-Path $Path)) {
        Write-Log "$Name not found at $Path" "WARN"
        return $false
    }
    Start-Process $Path -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $running = $null -ne (Get-Process -Name $Name -ErrorAction SilentlyContinue)
    Write-Log "Started $Name - confirmed running: $running" "OK"
    return $true
}

# ══════════════════════════════════════════════════════════════════════════════
Write-Log "====== RUN  AlertOnly=$AlertOnly  DebugMode=$DebugMode  TestToast=$TestToast  TestPhone=$TestPhone  TestNoPhone=$TestNoPhone  TestExpireDays=$TestExpireDays ======"

# ── TEST: toast check ─────────────────────────────────────────────────────────
if ($TestToast) {
    Send-Toast "Sideloadly - Toast Test" "Notifications working at $(Get-Date -Format 'HH:mm:ss'). If you see this, you're good."
    Write-Log "TestToast done" "TEST"
    exit 0
}

# ── Expiry check ──────────────────────────────────────────────────────────────
$apps = Get-AppExpirations

if ($TestExpireDays -ge 0) {
    Write-Log "TEST: overriding DaysLeft=$TestExpireDays for all $($apps.Count) apps" "TEST"
    $apps | ForEach-Object { $_.DaysLeft = $TestExpireDays }
}

# Alert threshold: 4 days (matches Sideloadly's default refresh_at_hours=96)
$threshold    = 4
$expiringSoon = @($apps | Where-Object { $_.DaysLeft -le $threshold -and $_.DaysLeft -ge 0 })
$alreadyDead  = @($apps | Where-Object { $_.DaysLeft -lt 0 })

if ($alreadyDead) {
    $list = ($alreadyDead | ForEach-Object { "$($_.Name) (expired)" }) -join ", "
    Write-Log "Already expired: $list" "WARN"
    Send-Toast "Sideloadly: Apps expired!" "Re-install needed: $list"
}

if ($expiringSoon) {
    # Cooldown: don't spam the same alert every 5 minutes
    $cooldownOk = $true
    if (-not $TestExpireDays -ge 0 -and (Test-Path $AlertFlagFile)) {
        $lastAlert = [datetime]::Parse((Get-Content $AlertFlagFile))
        $hoursSince = ([datetime]::Now - $lastAlert).TotalHours
        if ($hoursSince -lt $AlertCooldown) {
            Write-Log "Expiry alert suppressed - last sent $([math]::Round($hoursSince, 1))h ago (cooldown=${AlertCooldown}h)"
            $cooldownOk = $false
        }
    }
    if ($cooldownOk) {
        $soonest = $expiringSoon | Sort-Object DaysLeft | Select-Object -First 1
        $when    = switch ($soonest.DaysLeft) { 0 { "TODAY" } 1 { "tomorrow" } default { "in $($soonest.DaysLeft) days" } }
        $list    = ($expiringSoon | ForEach-Object { "$($_.Name) ($($_.DaysLeft)d)" }) -join ", "
        $devices = ($expiringSoon | Select-Object -ExpandProperty Device -Unique) -join " & "
        Send-Toast "Sideloadly: Renew $when" "Connect $devices - $list"
        [datetime]::Now.ToString('o') | Set-Content $AlertFlagFile
        Write-Log "Expiry alert sent: $list" "OK"
    }
} else {
    Write-Log "All apps OK (none expiring within $threshold days)"
    # Clean up cooldown flag if apps were refreshed (no longer expiring soon)
    if (Test-Path $AlertFlagFile) { Remove-Item $AlertFlagFile -Force; Write-Log "Alert cooldown flag cleared" }
}

if ($AlertOnly) { Write-Log "AlertOnly - exiting"; exit 0 }

# ── Daemon lifecycle ──────────────────────────────────────────────────────────
$daemonProc    = Get-Process -Name 'sideloadlydaemon' -ErrorAction SilentlyContinue
$daemonRunning = $null -ne $daemonProc
$weManagedIt   = Test-Path $FlagFile
$phoneHere     = Test-AppleDeviceConnected

Write-Log "--- STATE: daemon=$daemonRunning  ourFlag=$weManagedIt  phone=$phoneHere ---"

# ── CASE 1: phone arrived, daemon is off → start everything
if ($phoneHere -and -not $daemonRunning) {
    Write-Log "CASE 1: phone connected + daemon off → starting up" "OK"

    $started = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $AppleHelpers.GetEnumerator()) {
        if (Start-AppleHelper -Name $entry.Key -Path $entry.Value) {
            $started.Add($entry.Key)
        }
    }

    Start-Process $DaemonPath -WindowStyle Hidden
    Write-Log "Daemon process launched" "OK"

    @{ StartedAt = [datetime]::Now.ToString('o'); StartedHelpers = ($started -join ',') } |
        ConvertTo-Json | Set-Content $FlagFile
    Write-Log "Flag written: $FlagFile"

    $note = if ($started.Count) { " + $($started -join ', ')" } else { "" }
    Send-Toast "Sideloadly" "iPhone connected - daemon started$note."

# ── CASE 2: phone still here, daemon already up → nothing to do
} elseif ($phoneHere -and $daemonRunning) {
    Write-Log "CASE 2: phone connected + daemon already running - idle"

# ── CASE 3: phone gone, daemon is ours → tear down after grace period
} elseif (-not $phoneHere -and $daemonRunning -and $weManagedIt) {
    $flag      = Get-Content $FlagFile | ConvertFrom-Json
    $startedAt = [datetime]::Parse($flag.StartedAt)
    $runSecs   = [math]::Round(([datetime]::Now - $startedAt).TotalSeconds)
    Write-Log "CASE 3: phone gone, daemon ours (up ${runSecs}s) - grace=90s"

    if ($runSecs -ge 90) {
        Stop-Process -Name 'sideloadlydaemon' -Force -ErrorAction SilentlyContinue
        Write-Log "Daemon stopped" "OK"

        $weStarted = @($flag.StartedHelpers -split ',' | Where-Object { $_ })
        foreach ($name in $weStarted) {
            Stop-Process -Name $name -Force -ErrorAction SilentlyContinue
            Write-Log "Stopped helper: $name" "OK"
        }

        Remove-Item $FlagFile -Force -ErrorAction SilentlyContinue
        $note = if ($weStarted.Count) { " Closed: $($weStarted -join ', ')." } else { "" }
        Send-Toast "Sideloadly" "Done - daemon stopped.$note"
    } else {
        Write-Log "Still in grace period (${runSecs}s / 90s) - will clean up next poll"
    }

# ── CASE 4: phone gone, daemon not running → fully idle
} elseif (-not $phoneHere -and -not $daemonRunning) {
    Write-Log "CASE 4: no phone, no daemon - idle"
    # Clean up orphan flag if it somehow exists
    if ($weManagedIt) {
        Remove-Item $FlagFile -Force -ErrorAction SilentlyContinue
        Write-Log "Removed orphan flag file" "WARN"
    }

# ── CASE 5: daemon running but user started it (no flag) → hands off
} elseif (-not $phoneHere -and $daemonRunning -and -not $weManagedIt) {
    Write-Log "CASE 5: daemon running but no flag = user-started - leaving alone"
}

Write-Log "====== END ======"
