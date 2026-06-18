# Update Arbiter Tray - non-elevated notification-area agent
# Polls Get-ArbiterStatus every 5 minutes, paints a shield icon green when
# protected, red when policies/task missing. Right-click menu opens the
# admin dashboard (UAC prompts there, not here).

#Requires -Version 5.1

# --- Single instance guard ---
# Session-scoped (Local\), not machine-wide (Global\). One tray per logon
# session is correct; it also avoids the SeCreateGlobalPrivilege requirement
# and the cross-session DACL clash that made the Global\ object throw
# UnauthorizedAccessException ("Access to the path ... is denied") on boot.
# Guard fails open: if the mutex can't be created/acquired for any reason,
# launch anyway rather than crashing with an error box.
$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\UpdateArbiterTray.SingleInstance')
    if (-not $mutex.WaitOne(0, $false)) { return }  # another instance already owns it
} catch [System.Threading.AbandonedMutexException] {
    # Previous owner died without releasing; we now own it. Continue.
} catch {
    $mutex = $null  # guard unavailable; proceed without single-instance protection
}

# --- Constants ---

$ProductName    = 'Update Arbiter'
$ProductVersion = '2.0.2'
$ProductBrand   = 'Arcus Foundry'
$InstallDir     = 'C:\ProgramData\ArcusFoundry'
$MainExe        = Join-Path $InstallDir 'UpdateArbiter.exe'
$LogPath        = Join-Path $InstallDir 'update-arbiter.log'
$TaskName       = 'Arcus Foundry Update Arbiter'
$ProductPage    = 'https://arcusfoundry.com/labs/update-arbiter'

# Version manifest the tray polls hourly to tell existing users a newer Update
# Arbiter (with better reboot-circumvention) is out. Expected JSON shape:
#   { "version": "2.0.2", "url": "https://.../UpdateArbiter.exe", "notes": "..." }
# A missing/unreachable endpoint is a silent no-op (the check never blocks).
$VersionUrl     = 'https://arcusfoundry.com/labs/update-arbiter/version.json'

# Auto-update reboot-required flag. The tray cannot delete it (non-elevated), so
# when it sees the flag it triggers the SYSTEM self-heal task, which clears it.
$RebootRequiredKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'

$AuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$WuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$UxPath = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'

$ExpectedPolicies = @(
    @{ Path = $AuPath; Name = 'NoAutoRebootWithLoggedOnUsers';   Value = 1   }
    @{ Path = $WuPath; Name = 'SetActiveHours';                  Value = 1   }
    @{ Path = $WuPath; Name = 'ActiveHoursStart';                Value = 0   }
    @{ Path = $WuPath; Name = 'ActiveHoursEnd';                  Value = 18  }
    @{ Path = $WuPath; Name = 'ActiveHoursMaxRange';             Value = 18  }
    @{ Path = $UxPath; Name = 'ActiveHoursStart';                Value = 0   }
    @{ Path = $UxPath; Name = 'ActiveHoursEnd';                  Value = 18  }
    @{ Path = $UxPath; Name = 'IsActiveHoursEnabled';            Value = 1   }
    @{ Path = $WuPath; Name = 'DeferFeatureUpdates';             Value = 1   }
    @{ Path = $WuPath; Name = 'DeferFeatureUpdatesPeriodInDays'; Value = 365 }
    @{ Path = $WuPath; Name = 'DeferQualityUpdates';             Value = 0   }
    @{ Path = $WuPath; Name = 'DeferQualityUpdatesPeriodInDays'; Value = 0   }
    @{ Path = $AuPath; Name = 'AlwaysAutoRebootAtScheduledTime'; Value = 0   }
)

$PollIntervalMs = 5 * 60 * 1000  # 5 minutes

# --- Read-only status check (works without admin) ---

function Get-ArbiterStatus {
    $allOk = $true
    $missing = @()

    foreach ($p in $ExpectedPolicies) {
        $ok = $false
        try {
            $v = Get-ItemProperty -Path $p.Path -Name $p.Name -ErrorAction Stop
            $ok = ($v.($p.Name) -eq $p.Value)
        } catch { $ok = $false }
        if (-not $ok) { $allOk = $false; $missing += $p.Name }
    }

    $taskState = 'NotRegistered'
    $taskHealthy = $false
    $taskLastRun = $null
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $taskState = "$($task.State)"
        $taskHealthy = ($task.State -ne 'Disabled')
        try {
            $lr = ($task | Get-ScheduledTaskInfo).LastRunTime
            # Task Scheduler reports 1899-12-30 when a task has never run.
            if ($lr -and $lr.Year -gt 1900) { $taskLastRun = $lr }
        } catch { }
    }

    $installedVersion = $null
    $installedAt = $null
    $stateFile = Join-Path $InstallDir 'state.json'
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json
            $installedVersion = $state.Version
            if ($state.InstalledAt) { $installedAt = [DateTime]$state.InstalledAt }
            # Prefer the rearm stamp written by every successful self-heal; the
            # scheduler's LastRunTime is unreliable for SYSTEM tasks. Falls back to
            # the task LastRunTime captured above when the stamp isn't present yet.
            if ($state.LastRearmAt) { $taskLastRun = [DateTime]$state.LastRearmAt }
        } catch { }
    }

    $rebootFlag = Test-Path $RebootRequiredKey

    [PSCustomObject]@{
        Protected         = ($allOk -and $taskHealthy)
        AllPoliciesOk     = $allOk
        TaskState         = $taskState
        TaskHealthy       = $taskHealthy
        TaskLastRun       = $taskLastRun
        InstalledVersion  = $installedVersion
        InstalledAt       = $installedAt
        MissingPolicies   = $missing
        RebootFlagPresent = $rebootFlag
    }
}

# --- Update check: is a newer Update Arbiter published? ---
# Existing users have no way to know a new version (with better circumvention)
# shipped. Polled hourly. Returns the manifest object if a strictly newer version
# is available, else $null. Any failure (no endpoint, offline, bad JSON) is a
# silent no-op - this must never interrupt the tray.
function Get-AvailableUpdate {
    try {
        $m = Invoke-RestMethod -Uri $VersionUrl -TimeoutSec 5 -ErrorAction Stop
        if (-not $m.version) { return $null }
        if ([version]$m.version -gt [version]$ProductVersion) { return $m }
    } catch { }
    return $null
}

# --- Rearm: trigger the SYSTEM self-heal task to re-apply the lockdown ---
# The tray runs non-elevated and cannot write HKLM policies or touch protected
# Update Orchestrator tasks directly. The SYSTEM self-heal task can. The default
# task security descriptor grants Authenticated Users execute rights, so starting
# it from a medium-integrity process needs no UAC prompt.
function Invoke-Rearm {
    try {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# --- WinForms / shield icons ---

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function New-ShieldIcon {
    param(
        [System.Drawing.Color]$FillColor,
        [System.Drawing.Color]$BorderColor
    )
    $size = 32
    $bmp = [System.Drawing.Bitmap]::new($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $pts = @(
        [System.Drawing.Point]::new(16, 2)
        [System.Drawing.Point]::new(28, 6)
        [System.Drawing.Point]::new(28, 16)
        [System.Drawing.Point]::new(16, 30)
        [System.Drawing.Point]::new(4, 16)
        [System.Drawing.Point]::new(4, 6)
    )
    $path.AddPolygon($pts)

    $brush = [System.Drawing.SolidBrush]::new($FillColor)
    $g.FillPath($brush, $path)
    $pen = [System.Drawing.Pen]::new($BorderColor, 2)
    $g.DrawPath($pen, $path)

    $brush.Dispose(); $pen.Dispose(); $path.Dispose(); $g.Dispose()

    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    return $icon
}

$iconProtected = New-ShieldIcon `
    -FillColor   ([System.Drawing.Color]::FromArgb(120, 200, 120)) `
    -BorderColor ([System.Drawing.Color]::FromArgb(40, 90, 40))

$iconUnprotected = New-ShieldIcon `
    -FillColor   ([System.Drawing.Color]::FromArgb(230, 100, 100)) `
    -BorderColor ([System.Drawing.Color]::FromArgb(120, 30, 30))

$iconUnknown = New-ShieldIcon `
    -FillColor   ([System.Drawing.Color]::FromArgb(220, 180, 80)) `
    -BorderColor ([System.Drawing.Color]::FromArgb(120, 90, 20))

# --- NotifyIcon + menu ---

$notify = [System.Windows.Forms.NotifyIcon]::new()
$notify.Icon = $iconUnknown
$notify.Text = "$ProductName - checking..."
$notify.Visible = $true

$menu = [System.Windows.Forms.ContextMenuStrip]::new()

$miHeader = [System.Windows.Forms.ToolStripMenuItem]::new("$ProductName v$ProductVersion")
$miHeader.Enabled = $false
$miHeader.Font = [System.Drawing.Font]::new($menu.Font, [System.Drawing.FontStyle]::Bold)
[void]$menu.Items.Add($miHeader)

$miStatus = [System.Windows.Forms.ToolStripMenuItem]::new('Status: checking...')
$miStatus.Enabled = $false
[void]$menu.Items.Add($miStatus)

$miLastRun = [System.Windows.Forms.ToolStripMenuItem]::new('Last rearm: unknown')
$miLastRun.Enabled = $false
[void]$menu.Items.Add($miLastRun)

# Hidden until a newer version is published. Click opens the download page.
$miUpdate = [System.Windows.Forms.ToolStripMenuItem]::new('Update available')
$miUpdate.Visible = $false
$miUpdate.ForeColor = [System.Drawing.Color]::FromArgb(40, 110, 40)
$miUpdate.Font = [System.Drawing.Font]::new($menu.Font, [System.Drawing.FontStyle]::Bold)
$miUpdate.Add_Click({
    $target = if ($script:UpdateUrl) { $script:UpdateUrl } else { $ProductPage }
    try { Start-Process $target -ErrorAction Stop }
    catch { [System.Windows.Forms.MessageBox]::Show("Could not open $target", $ProductName) | Out-Null }
})
[void]$menu.Items.Add($miUpdate)

[void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

$miOpen = [System.Windows.Forms.ToolStripMenuItem]::new('Open Dashboard...')
$miOpen.Add_Click({
    if (Test-Path $MainExe) {
        try { Start-Process -FilePath $MainExe -ErrorAction Stop }
        catch { [System.Windows.Forms.MessageBox]::Show("Could not launch dashboard: $($_.Exception.Message)", $ProductName) | Out-Null }
    } else {
        [System.Windows.Forms.MessageBox]::Show("Main installer not found at:`n$MainExe", $ProductName,
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
})
[void]$menu.Items.Add($miOpen)

$miVerify = [System.Windows.Forms.ToolStripMenuItem]::new('Verify Now')
[void]$menu.Items.Add($miVerify)

$miRearm = [System.Windows.Forms.ToolStripMenuItem]::new('Rearm Now')
$miRearm.Add_Click({
    if (Invoke-Rearm) {
        $script:LastRearmAttempt = Get-Date
        $notify.ShowBalloonTip(2500, $ProductName, 'Rearm triggered. Re-applying lockdown...',
            [System.Windows.Forms.ToolTipIcon]::Info)
        $recheckTimer.Start()
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not trigger rearm.`n`nThe self-heal task '$TaskName' may not be registered. Open the dashboard and run Install / Repair.",
            $ProductName, [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
})
[void]$menu.Items.Add($miRearm)

$miLog = [System.Windows.Forms.ToolStripMenuItem]::new('View Log')
$miLog.Add_Click({
    if (Test-Path $LogPath) {
        try { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$LogPath`"" -ErrorAction Stop }
        catch { [System.Windows.Forms.MessageBox]::Show("Could not open log: $($_.Exception.Message)", $ProductName) | Out-Null }
    } else {
        [System.Windows.Forms.MessageBox]::Show("Log file not found at:`n$LogPath", $ProductName,
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
})
[void]$menu.Items.Add($miLog)

[void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

$miAbout = [System.Windows.Forms.ToolStripMenuItem]::new('About')
$miAbout.Add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        "$ProductName v$ProductVersion`n$ProductBrand`n`nStops Windows from rebooting without your consent.`nhttps://arcusfoundry.com/labs/update-arbiter",
        $ProductName,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
})
[void]$menu.Items.Add($miAbout)

$miExit = [System.Windows.Forms.ToolStripMenuItem]::new('Exit')
[void]$menu.Items.Add($miExit)

$notify.ContextMenuStrip = $menu

# --- State update ---

$script:LastCheck = $null
$script:LastRearmAttempt = $null
$script:LastVersionCheck = $null
$script:UpdateUrl = $null

function Set-Tooltip {
    param([string]$Text)
    # NotifyIcon.Text WinForms cap is 63 chars (legacy Shell_NotifyIcon NOTIFYICONDATA size)
    if ($Text.Length -gt 63) { $Text = $Text.Substring(0, 60) + '...' }
    $notify.Text = $Text
}

function Update-State {
    try {
        $s = Get-ArbiterStatus
    } catch {
        $notify.Icon = $iconUnknown
        Set-Tooltip "${ProductName}: status check failed"
        $miStatus.Text = 'Status: check failed'
        return
    }
    $script:LastCheck = Get-Date
    $hhmm = $script:LastCheck.ToString('HH:mm')

    if ($s.TaskLastRun) { $miLastRun.Text = "Last rearm: $($s.TaskLastRun.ToString('yyyy-MM-dd HH:mm'))" }
    else { $miLastRun.Text = 'Last rearm: never recorded' }

    if ($s.Protected) {
        $notify.Icon = $iconProtected
        # Tooltip: short signal only (63-char cap). Detail goes in the menu.
        Set-Tooltip "$ProductName v$ProductVersion - PROTECTED ($hhmm)"
        $sinceStr = if ($s.InstalledAt) { " since $($s.InstalledAt.ToString('yyyy-MM-dd'))" } else { '' }
        $miStatus.Text = "Status: PROTECTED$sinceStr  (checked $($script:LastCheck.ToString('HH:mm:ss')))"
        $miStatus.ForeColor = [System.Drawing.Color]::FromArgb(20, 110, 20)
    } else {
        $notify.Icon = $iconUnprotected
        Set-Tooltip "$ProductName - NOT PROTECTED ($hhmm)"
        $reasons = @()
        if (-not $s.AllPoliciesOk) { $reasons += "$($s.MissingPolicies.Count) policy issue(s)" }
        if (-not $s.TaskHealthy)   { $reasons += "task: $($s.TaskState)" }
        $reasonStr = $reasons -join '; '
        $miStatus.Text = "Status: NOT PROTECTED ($reasonStr)"
        $miStatus.ForeColor = [System.Drawing.Color]::FromArgb(170, 30, 30)

        # Auto-rearm on drift: trigger the SYSTEM self-heal task to re-apply the
        # lockdown before a reboot can fire. Cooldown stops the tray hammering the
        # task every poll when the drift is something a rearm can't fix (e.g. a
        # policy write genuinely failing), while still re-trying periodically.
        $cooldownOk = (-not $script:LastRearmAttempt) -or `
                      (($script:LastCheck - $script:LastRearmAttempt).TotalMinutes -ge 30)
        if ($cooldownOk) {
            $script:LastRearmAttempt = $script:LastCheck
            if (Invoke-Rearm) {
                $notify.ShowBalloonTip(3000, $ProductName,
                    'Protection drifted - rearm triggered to block reboots.',
                    [System.Windows.Forms.ToolTipIcon]::Warning)
                $recheckTimer.Start()
            }
        }
    }

    # Reboot flag is the most urgent signal: an update is staged and Windows wants
    # to restart. The tray can't delete the HKLM key, so trigger the SYSTEM
    # self-heal (which clears it). Shares the rearm cooldown so we don't stack
    # triggers when drift already kicked one off this cycle.
    if ($s.RebootFlagPresent) {
        $notify.Icon = $iconUnknown
        Set-Tooltip "$ProductName - REBOOT PENDING, clearing ($hhmm)"
        $cooldownOk = (-not $script:LastRearmAttempt) -or `
                      (($script:LastCheck - $script:LastRearmAttempt).TotalMinutes -ge 30)
        if ($cooldownOk) {
            $script:LastRearmAttempt = $script:LastCheck
            if (Invoke-Rearm) {
                $notify.ShowBalloonTip(4000, $ProductName,
                    'Windows set a reboot flag. Rearm triggered to clear it and block the restart.',
                    [System.Windows.Forms.ToolTipIcon]::Warning)
                $recheckTimer.Start()
            }
        }
    }

    # Hourly check for a newer Update Arbiter (better circumvention). Silent if the
    # endpoint is absent/unreachable. Notifies once when an update first appears.
    if ((-not $script:LastVersionCheck) -or (($script:LastCheck - $script:LastVersionCheck).TotalMinutes -ge 60)) {
        $script:LastVersionCheck = $script:LastCheck
        $upd = Get-AvailableUpdate
        if ($upd) {
            $script:UpdateUrl = if ($upd.url) { $upd.url } else { $ProductPage }
            $miUpdate.Text = "Update available: v$($upd.version) - click to get it"
            if (-not $miUpdate.Visible) {
                $miUpdate.Visible = $true
                $note = if ($upd.notes) { "`n$($upd.notes)" } else { '' }
                $notify.ShowBalloonTip(6000, "$ProductName update available",
                    "Version $($upd.version) is out (you have $ProductVersion).$note",
                    [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
    }
}

$miVerify.Add_Click({
    Update-State
    $notify.ShowBalloonTip(2500, $ProductName, "Verified: $($miStatus.Text -replace '^Status:\s*','')",
        [System.Windows.Forms.ToolTipIcon]::Info)
})

# --- Timer ---

$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = $PollIntervalMs
$timer.Add_Tick({ Update-State })
$timer.Start()

# One-shot timer to re-check status a few seconds after a rearm is triggered,
# giving the SYSTEM self-heal task time to re-apply the lockdown before we repaint.
$recheckTimer = [System.Windows.Forms.Timer]::new()
$recheckTimer.Interval = 15000
$recheckTimer.Add_Tick({ $recheckTimer.Stop(); Update-State })

# --- Click to open dashboard ---

$notify.Add_DoubleClick({ $miOpen.PerformClick() })

# --- Exit ---

$exiting = $false
$doExit = {
    if ($script:exiting) { return }
    $script:exiting = $true
    $timer.Stop(); $timer.Dispose()
    $recheckTimer.Stop(); $recheckTimer.Dispose()
    $notify.Visible = $false
    $notify.Dispose()
    try { $mutex.ReleaseMutex() } catch { }
    [System.Windows.Forms.Application]::Exit()
}
$miExit.Add_Click($doExit)
$notify.Add_Disposed({ })

# --- Initial check + run ---

Update-State

[System.Windows.Forms.Application]::Run()
