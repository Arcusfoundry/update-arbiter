# Update Arbiter Tray - non-elevated notification-area agent
# Polls Get-ArbiterStatus every 5 minutes, paints a shield icon green when
# protected, red when policies/task missing. Right-click menu opens the
# admin dashboard (UAC prompts there, not here).

#Requires -Version 5.1

# --- Single instance guard ---

$mutex = New-Object System.Threading.Mutex($false, 'Global\UpdateArbiterTray.SingleInstance')
$gotIt = $false
try { $gotIt = $mutex.WaitOne(0, $false) } catch { $gotIt = $false }
if (-not $gotIt) { return }

# --- Constants ---

$ProductName    = 'Update Arbiter'
$ProductVersion = '2.0.1'
$ProductBrand   = 'Arcus Foundry'
$InstallDir     = 'C:\ProgramData\ArcusFoundry'
$MainExe        = Join-Path $InstallDir 'UpdateArbiter.exe'
$LogPath        = Join-Path $InstallDir 'update-arbiter.log'
$TaskName       = 'Arcus Foundry Update Arbiter'

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
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $taskState = "$($task.State)"
        $taskHealthy = ($task.State -ne 'Disabled')
    }

    $installedVersion = $null
    $installedAt = $null
    $stateFile = Join-Path $InstallDir 'state.json'
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json
            $installedVersion = $state.Version
            $installedAt = [DateTime]$state.InstalledAt
        } catch { }
    }

    [PSCustomObject]@{
        Protected        = ($allOk -and $taskHealthy)
        AllPoliciesOk    = $allOk
        TaskState        = $taskState
        TaskHealthy      = $taskHealthy
        InstalledVersion = $installedVersion
        InstalledAt      = $installedAt
        MissingPolicies  = $missing
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
        "$ProductName v$ProductVersion`n$ProductBrand`n`nStops Windows from rebooting without your consent.`nhttps://arcusfoundry.com/update-arbiter",
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

# --- Click to open dashboard ---

$notify.Add_DoubleClick({ $miOpen.PerformClick() })

# --- Exit ---

$exiting = $false
$doExit = {
    if ($script:exiting) { return }
    $script:exiting = $true
    $timer.Stop(); $timer.Dispose()
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
