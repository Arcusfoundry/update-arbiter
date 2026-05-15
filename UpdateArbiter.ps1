# Update Arbiter - Dashboard and installer (Arcus Foundry)
# Combines reboot/uptime visibility with the lockdown installer in one GUI.
# When launched normally: shows dashboard with Install / Uninstall controls.
# When launched with -SelfHeal: silently re-applies the lockdown (used by the scheduled task).

#Requires -Version 5.1

param(
    [switch]$SelfHeal
)

# ---------- Constants ----------

$ProductName    = 'Update Arbiter'
$ProductVersion = '2.0.0'
$ProductBrand   = 'Arcus Foundry'
$InstallDir     = 'C:\ProgramData\ArcusFoundry'
$LogPath        = Join-Path $InstallDir 'update-arbiter.log'
$TaskName       = 'Arcus Foundry Update Arbiter'
$StateFile      = Join-Path $InstallDir 'state.json'
$TrayExeName    = 'UpdateArbiterTray.exe'
$RunKeyPath     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunKeyName     = 'UpdateArbiterTray'

$AuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$WuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$UxPath = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'

$RebootTasks = @(
    @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Reboot' }
    @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Reboot_AC' }
    @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Reboot_Battery' }
)

$ExpectedPolicies = @(
    @{ Path = $AuPath; Name = 'NoAutoRebootWithLoggedOnUsers'; Value = 1  }
    @{ Path = $WuPath; Name = 'SetActiveHours';                Value = 1  }
    @{ Path = $WuPath; Name = 'ActiveHoursStart';              Value = 0  }
    @{ Path = $WuPath; Name = 'ActiveHoursEnd';                Value = 18 }
    @{ Path = $WuPath; Name = 'ActiveHoursMaxRange';           Value = 18 }
    @{ Path = $UxPath; Name = 'ActiveHoursStart';              Value = 0  }
    @{ Path = $UxPath; Name = 'ActiveHoursEnd';                Value = 18 }
    @{ Path = $UxPath; Name = 'IsActiveHoursEnabled';          Value = 1  }
)

# ---------- Helpers ----------

function Get-SelfExecutablePath {
    try {
        $procPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $leaf = Split-Path -Leaf $procPath
        if ($leaf -and $leaf -notmatch '^(powershell|pwsh)') { return $procPath }
    } catch { }
    return $PSCommandPath
}

function Test-IsCompiledExe {
    $p = Get-SelfExecutablePath
    return ($p -and ($p -like '*.exe'))
}

function Write-FileLog {
    param([string]$Level, [string]$Message)
    if (-not (Test-Path $InstallDir)) { return }
    $line = '[{0}] {1,-4} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
}

# ---------- Uptime sessions (carried from dashboard work) ----------

function Get-UptimeSessions {
    param([int]$DaysBack = 30)

    $startTime = (Get-Date).AddDays(-$DaysBack)

    $events = Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        ID        = 6005, 6006, 6008
        StartTime = $startTime
    } -ErrorAction Stop | Sort-Object TimeCreated

    $reasonEvents = @(Get-WinEvent -FilterHashtable @{
        LogName      = 'System'; ProviderName = 'USER32'; ID = 1074; StartTime = $startTime
    } -ErrorAction SilentlyContinue)

    $kernelPower = @(Get-WinEvent -FilterHashtable @{
        LogName      = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; ID = 41; StartTime = $startTime
    } -ErrorAction SilentlyContinue)

    $bugChecks = @(Get-WinEvent -FilterHashtable @{
        LogName = 'System'; ID = 1001; StartTime = $startTime
    } -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -match 'BugCheck|WER-SystemErrorReporting' })

    function Find-Nearest {
        param($Collection, [DateTime]$Time, [TimeSpan]$MaxDelta)
        $best = $null; $bestDelta = $MaxDelta
        foreach ($item in $Collection) {
            $delta = [TimeSpan]::FromTicks([math]::Abs(($item.TimeCreated - $Time).Ticks))
            if ($delta -le $bestDelta) { $bestDelta = $delta; $best = $item }
        }
        return $best
    }

    function Format-Reason1074 {
        param($Event)
        if (-not $Event) { return $null }
        $msg = $Event.Message; if (-not $msg) { return $null }
        $reason   = if ($msg -match 'for the following reason:\s*(.+?)(\r|\n|$)') { $matches[1].Trim() } else { $null }
        $sType    = if ($msg -match 'Shutdown Type:\s*(.+?)(\r|\n|$)')           { $matches[1].Trim() } else { $null }
        $comment  = if ($msg -match 'Comment:\s*(.+?)(\r|\n|$)')                 { $matches[1].Trim() } else { $null }
        $process  = if ($msg -match 'The process\s+(\S+)')                       { Split-Path -Leaf $matches[1] } else { $null }
        $user     = if ($msg -match 'on behalf of user\s+(.+?)\s+for the')       { $matches[1].Trim() } else { $null }
        $parts = @()
        if ($sType)   { $parts += "[$sType]" }
        if ($reason)  { $parts += $reason }
        if ($process) { $parts += "by $process" }
        if ($user)    { $parts += "($user)" }
        if ($comment) { $parts += "- $comment" }
        if ($parts.Count -eq 0) { return $null }
        return ($parts -join ' ')
    }

    function Format-BugCheck {
        param($Event)
        if (-not $Event) { return $null }
        if ($Event.Message -match '(0x[0-9A-Fa-f]{8,16}(?:\s*\([^)]*\))?)') { return "BSOD bugcheck $($matches[1])" }
        return 'BSOD bugcheck (see event 1001)'
    }

    $sessions = New-Object System.Collections.Generic.List[object]
    $currentBoot = $null
    $window = [TimeSpan]::FromMinutes(10)
    $hourWindow = [TimeSpan]::FromHours(1)

    foreach ($e in $events) {
        if ($e.Id -eq 6005) {
            if ($currentBoot) {
                $sessions.Add([PSCustomObject]@{
                    BootTime=$currentBoot.TimeCreated; ShutdownTime=$null; Duration=$null
                    ShutdownType='Unknown (no shutdown event)'
                    Reason='(no shutdown record - possible hard reset)'
                })
            }
            $currentBoot = $e
        }
        elseif ($e.Id -in 6006, 6008) {
            if ($currentBoot) {
                $type = if ($e.Id -eq 6006) { 'Clean' } else { 'Unexpected' }
                $reasonStr = Format-Reason1074 (Find-Nearest $reasonEvents $e.TimeCreated $window)
                if ($type -eq 'Unexpected') {
                    $bug = Format-BugCheck (Find-Nearest $bugChecks $e.TimeCreated $hourWindow)
                    $kp  = Find-Nearest $kernelPower $e.TimeCreated $hourWindow
                    $extra = @()
                    if ($bug) { $extra += $bug }
                    if ($kp -and -not $bug) { $extra += 'Kernel-Power 41 (system not cleanly shut down)' }
                    if ($extra.Count -gt 0) {
                        $reasonStr = if ($reasonStr) { "$reasonStr | " + ($extra -join ' | ') } else { $extra -join ' | ' }
                    }
                }
                if (-not $reasonStr) { $reasonStr = '(no reason logged)' }
                $sessions.Add([PSCustomObject]@{
                    BootTime=$currentBoot.TimeCreated; ShutdownTime=$e.TimeCreated
                    Duration=$e.TimeCreated - $currentBoot.TimeCreated
                    ShutdownType=$type; Reason=$reasonStr
                })
                $currentBoot = $null
            }
        }
    }

    if ($currentBoot) {
        $sessions.Add([PSCustomObject]@{
            BootTime=$currentBoot.TimeCreated; ShutdownTime=Get-Date
            Duration=(Get-Date) - $currentBoot.TimeCreated
            ShutdownType='Current session (ongoing)'; Reason='(session in progress)'
        })
    }

    return ,@($sessions | Sort-Object BootTime -Descending)
}

function Format-Duration {
    param($Duration)
    if (-not $Duration) { return 'unknown' }
    '{0}d {1:00}h {2:00}m' -f $Duration.Days, $Duration.Hours, $Duration.Minutes
}

# ---------- Arbiter status ----------

function Get-ArbiterStatus {
    $status = [ordered]@{
        Installed          = $false
        InstalledVersion   = $null
        InstalledAt        = $null
        InstallDirPresent  = (Test-Path $InstallDir)
        ScheduledTask      = $null
        PolicyResults      = @()
        DisabledTaskResults= @()
        AllPoliciesPresent = $false
        TaskHealthy        = $false
        TrayAutostartSet   = $false
        TrayRunning        = $false
    }

    # Scheduled task
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = $task | Get-ScheduledTaskInfo
        $status.ScheduledTask = [PSCustomObject]@{
            State      = $task.State
            LastRun    = $info.LastRunTime
            LastResult = '0x{0:X}' -f $info.LastTaskResult
            NextRun    = $info.NextRunTime
        }
        $status.TaskHealthy = ($task.State -ne 'Disabled')
    }

    # Policy presence
    $allOk = $true
    foreach ($p in $ExpectedPolicies) {
        $present = $false; $actual = $null
        if (Test-Path $p.Path) {
            try {
                $v = Get-ItemProperty -Path $p.Path -Name $p.Name -ErrorAction Stop
                $actual = $v.($p.Name)
                $present = ($actual -eq $p.Value)
            } catch { $present = $false }
        }
        if (-not $present) { $allOk = $false }
        $status.PolicyResults += [PSCustomObject]@{
            Path = $p.Path; Name = $p.Name; Expected = $p.Value; Actual = $actual; Ok = $present
        }
    }
    $status.AllPoliciesPresent = $allOk

    # Disabled task state
    foreach ($t in $RebootTasks) {
        $st = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
        $status.DisabledTaskResults += [PSCustomObject]@{
            Name = $t.Name; Present = [bool]$st; State = $(if ($st) { $st.State } else { 'NotPresent' })
        }
    }

    # State file
    if (Test-Path $StateFile) {
        try {
            $state = Get-Content $StateFile -Raw | ConvertFrom-Json
            $status.InstalledVersion = $state.Version
            $status.InstalledAt = [DateTime]$state.InstalledAt
        } catch { }
    }

    # Tray autostart + running state
    try {
        $rk = Get-ItemProperty -Path $RunKeyPath -Name $RunKeyName -ErrorAction Stop
        if ($rk.$RunKeyName) { $status.TrayAutostartSet = $true }
    } catch { $status.TrayAutostartSet = $false }

    $status.TrayRunning = [bool](Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($TrayExeName)) -ErrorAction SilentlyContinue)

    $status.Installed = ($status.AllPoliciesPresent -and $status.TaskHealthy)
    return [PSCustomObject]$status
}

function Save-ArbiterState {
    if (-not (Test-Path $InstallDir)) { New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null }
    @{
        Version     = $ProductVersion
        InstalledAt = (Get-Date).ToString('o')
        InstalledBy = "$env:USERDOMAIN\$env:USERNAME"
    } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

# ---------- Install / Uninstall ----------

function Invoke-Install {
    param([scriptblock]$Log)

    function L { param([string]$Level, [string]$Msg) & $Log $Level $Msg; Write-FileLog $Level $Msg }

    L 'STEP' 'Creating install directory'
    if (-not (Test-Path $InstallDir)) {
        try { New-Item -Path $InstallDir -ItemType Directory -Force -ErrorAction Stop | Out-Null; L 'OK' "Created $InstallDir" }
        catch { L 'FAIL' "Could not create install dir: $($_.Exception.Message)"; return $false }
    } else {
        L 'OK' "Already exists: $InstallDir"
    }

    L 'STEP' 'Copying executable to install directory'
    $src = Get-SelfExecutablePath
    $isExe = Test-IsCompiledExe
    $destLeaf = if ($isExe) { 'UpdateArbiter.exe' } else { 'UpdateArbiter.ps1' }
    $dest = Join-Path $InstallDir $destLeaf
    if ($src -and (Test-Path $src) -and ($src -ne $dest)) {
        try { Copy-Item -Path $src -Destination $dest -Force -ErrorAction Stop; L 'OK' "Copied to $dest" }
        catch { L 'WARN' "Could not copy self ($($_.Exception.Message)) - self-heal task may break" }
    } elseif ($src -eq $dest) {
        L 'OK' 'Already running from install dir'
    } else {
        L 'WARN' 'Could not determine self path - self-heal task may break'
    }

    L 'STEP' 'Applying registry policies (with read-back verification)'
    foreach ($path in @($WuPath, $AuPath, $UxPath)) {
        if (-not (Test-Path $path)) {
            try { New-Item -Path $path -Force -ErrorAction Stop | Out-Null; L 'OK' "Created key: $path" }
            catch { L 'FAIL' "Could not create key ${path}: $($_.Exception.Message)"; return $false }
        }
    }

    $policyFails = 0
    foreach ($p in $ExpectedPolicies) {
        try {
            Set-ItemProperty -Path $p.Path -Name $p.Name -Value $p.Value -Type DWord -ErrorAction Stop
            $read = (Get-ItemProperty -Path $p.Path -Name $p.Name -ErrorAction Stop).($p.Name)
            if ($read -eq $p.Value) {
                L 'OK' ("Set + verified {0} = {1}" -f $p.Name, $p.Value)
            } else {
                L 'FAIL' ("Set {0} = {1} but read back {2}" -f $p.Name, $p.Value, $read)
                $policyFails++
            }
        } catch {
            L 'FAIL' ("{0}: {1}" -f $p.Name, $_.Exception.Message)
            $policyFails++
        }
    }

    # Clean up legacy values
    foreach ($legacy in 'AUOptions', 'NoAutoUpdate') {
        try { Remove-ItemProperty -Path $AuPath -Name $legacy -ErrorAction SilentlyContinue } catch { }
    }

    L 'STEP' 'Disabling Update Orchestrator reboot tasks (where present)'
    foreach ($t in $RebootTasks) {
        $task = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
        if (-not $task) {
            L 'WARN' "$($t.Name): not present on this Windows build (newer Win11 has moved reboot logic to MoUsoCoreWorker)"
            continue
        }
        try {
            Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
            $after = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop
            if ($after.State -eq 'Disabled') { L 'OK' "Disabled $($t.Name) (verified)" }
            else { L 'FAIL' "Disabled $($t.Name) but state is $($after.State)" }
        } catch {
            L 'FAIL' "Could not disable $($t.Name): $($_.Exception.Message)"
        }
    }

    L 'STEP' 'Registering self-heal scheduled task'
    try {
        if ($isExe) {
            $exePath = Join-Path $InstallDir 'UpdateArbiter.exe'
            $action = New-ScheduledTaskAction -Execute $exePath -Argument '-SelfHeal'
        } else {
            $ps1Path = Join-Path $InstallDir 'UpdateArbiter.ps1'
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1Path`" -SelfHeal"
        }

        $triggers = @()
        $triggers += New-ScheduledTaskTrigger -AtStartup
        $triggers += New-ScheduledTaskTrigger -AtLogOn

        $cimTrigger = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
        $eventTrigger = New-CimInstance -CimClass $cimTrigger -ClientOnly
        $eventTrigger.Enabled = $true
        $eventTrigger.Subscription = @'
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-WindowsUpdateClient/Operational">
    <Select Path="Microsoft-Windows-WindowsUpdateClient/Operational">
      *[System[Provider[@Name='Microsoft-Windows-WindowsUpdateClient'] and (EventID=19 or EventID=43)]]
    </Select>
  </Query>
</QueryList>
'@
        $triggers += $eventTrigger

        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew

        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
            -Principal $principal -Settings $settings `
            -Description "$ProductName self-heal v$ProductVersion - re-applies lockdown at boot, logon, and WindowsUpdateClient 19/43" `
            -ErrorAction Stop | Out-Null

        $confirm = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        if ($confirm.State -ne 'Disabled') {
            L 'OK' "Registered + verified task '$TaskName' (state: $($confirm.State))"
        } else {
            L 'FAIL' "Registered but task is disabled"
        }
    } catch {
        L 'FAIL' "Scheduled task registration failed: $($_.Exception.Message)"
    }

    L 'STEP' 'Deploying tray agent'
    $sourceDir = Split-Path -Parent (Get-SelfExecutablePath)
    $traySrc = Join-Path $sourceDir $TrayExeName
    $trayDst = Join-Path $InstallDir $TrayExeName
    if (Test-Path $traySrc) {
        try {
            Copy-Item -Path $traySrc -Destination $trayDst -Force -ErrorAction Stop
            if (Test-Path $trayDst) { L 'OK' "Copied tray agent to $trayDst" }
            else { L 'FAIL' 'Tray agent copy reported success but file is not present' }
        } catch { L 'FAIL' "Could not copy tray agent: $($_.Exception.Message)" }
    } else {
        L 'WARN' "Tray agent source not found at $traySrc (skipping autostart)"
    }

    if (Test-Path $trayDst) {
        L 'STEP' 'Registering tray autostart (HKCU Run key)'
        try {
            $runValue = "`"$trayDst`""
            if (-not (Test-Path $RunKeyPath)) { New-Item -Path $RunKeyPath -Force | Out-Null }
            Set-ItemProperty -Path $RunKeyPath -Name $RunKeyName -Value $runValue -ErrorAction Stop
            $read = (Get-ItemProperty -Path $RunKeyPath -Name $RunKeyName -ErrorAction Stop).$RunKeyName
            if ($read -eq $runValue) { L 'OK' "Autostart registered + verified: $RunKeyPath\$RunKeyName" }
            else { L 'FAIL' "Set autostart but read back '$read'" }
        } catch { L 'FAIL' "Could not register tray autostart: $($_.Exception.Message)" }

        L 'STEP' 'Starting tray agent now'
        # Stop any existing tray instance first so it picks up the new EXE
        $trayProcName = [IO.Path]::GetFileNameWithoutExtension($TrayExeName)
        Get-Process -Name $trayProcName -ErrorAction SilentlyContinue | ForEach-Object {
            try { $_.Kill(); $_.WaitForExit(2000) } catch { }
        }
        try {
            # Launch as the interactive user, NOT elevated. Since this installer
            # is elevated, Start-Process inherits elevation; use the shell to
            # spawn at the caller's medium-integrity level.
            $shell = New-Object -ComObject Shell.Application
            $shell.ShellExecute($trayDst, '', $InstallDir, $null, 1)
            Start-Sleep -Milliseconds 600
            if (Get-Process -Name $trayProcName -ErrorAction SilentlyContinue) {
                L 'OK' 'Tray agent running'
            } else {
                L 'WARN' 'Tray agent did not appear after launch (will start on next logon)'
            }
        } catch { L 'WARN' "Could not auto-start tray: $($_.Exception.Message) (will start on next logon)" }
    }

    L 'STEP' 'Refreshing Group Policy'
    try { gpupdate /force | Out-Null; L 'OK' 'gpupdate /force complete' } catch { L 'WARN' "gpupdate failed: $($_.Exception.Message)" }

    L 'STEP' 'Final verification'
    $final = Get-ArbiterStatus
    if ($final.AllPoliciesPresent) { L 'OK' 'All registry policies verified present' }
    else { L 'FAIL' 'Some registry policies missing - see step output above'; $policyFails++ }
    if ($final.TaskHealthy)        { L 'OK' "Self-heal task '$TaskName' is healthy ($($final.ScheduledTask.State))" }
    else                           { L 'FAIL' 'Self-heal task missing or disabled' }

    if ($policyFails -eq 0 -and $final.TaskHealthy) {
        Save-ArbiterState
        L 'DONE' "$ProductName v$ProductVersion installed successfully."
        return $true
    } else {
        L 'DONE' "$ProductName install completed with errors. See log above."
        return $false
    }
}

function Invoke-Uninstall {
    param([scriptblock]$Log)

    function L { param([string]$Level, [string]$Msg) & $Log $Level $Msg; Write-FileLog $Level $Msg }

    L 'STEP' 'Stopping tray agent'
    $trayProcName = [IO.Path]::GetFileNameWithoutExtension($TrayExeName)
    $running = @(Get-Process -Name $trayProcName -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        foreach ($p in $running) { try { $p.Kill(); $p.WaitForExit(2000); L 'OK' "Stopped $($p.ProcessName) (pid $($p.Id))" } catch { L 'WARN' "Could not stop pid $($p.Id): $($_.Exception.Message)" } }
    } else {
        L 'OK' 'No tray agent running'
    }

    L 'STEP' 'Removing tray autostart entry'
    try {
        Remove-ItemProperty -Path $RunKeyPath -Name $RunKeyName -ErrorAction SilentlyContinue
        $check = $null
        try { $check = (Get-ItemProperty -Path $RunKeyPath -Name $RunKeyName -ErrorAction Stop).$RunKeyName } catch { $check = $null }
        if ($null -eq $check) { L 'OK' "Autostart entry removed" } else { L 'WARN' "Autostart entry still present: $check" }
    } catch { L 'WARN' "Could not remove autostart entry: $($_.Exception.Message)" }

    L 'STEP' 'Removing self-heal scheduled task'
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        L 'OK' "Removed task '$TaskName'"
    } catch {
        L 'WARN' "No task to remove (or removal failed): $($_.Exception.Message)"
    }

    L 'STEP' 'Re-enabling Update Orchestrator reboot tasks'
    foreach ($t in $RebootTasks) {
        $task = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($task -and $task.State -eq 'Disabled') {
            try { Enable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null; L 'OK' "Re-enabled $($t.Name)" }
            catch { L 'WARN' "Could not re-enable $($t.Name): $($_.Exception.Message)" }
        } else {
            L 'OK' "$($t.Name): nothing to re-enable"
        }
    }

    L 'STEP' 'Removing reboot-blocking registry policies'
    foreach ($p in $ExpectedPolicies) {
        try { Remove-ItemProperty -Path $p.Path -Name $p.Name -ErrorAction SilentlyContinue; L 'OK' "Removed $($p.Name)" }
        catch { L 'WARN' "Could not remove $($p.Name)" }
    }

    L 'STEP' 'Removing install directory'
    if (Test-Path $InstallDir) {
        try { Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction Stop; L 'OK' "Removed $InstallDir" }
        catch { L 'WARN' "Could not remove install dir: $($_.Exception.Message)" }
    }

    L 'DONE' "$ProductName uninstalled."
    return $true
}

# ---------- Silent self-heal entry point ----------

if ($SelfHeal) {
    if (-not (Test-Path $InstallDir)) { try { New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null } catch {} }
    $silentLog = { param($lvl, $msg) Write-FileLog $lvl $msg }
    Invoke-Install -Log $silentLog | Out-Null
    return
}

# ---------- GUI ----------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$ColorBg       = [System.Drawing.Color]::FromArgb(30, 30, 30)
$ColorPanelBg  = [System.Drawing.Color]::FromArgb(20, 20, 20)
$ColorAlt      = [System.Drawing.Color]::FromArgb(36, 36, 36)
$ColorSummary  = [System.Drawing.Color]::FromArgb(40, 40, 40)
$ColorGreen    = [System.Drawing.Color]::FromArgb(120, 200, 120)
$ColorRed      = [System.Drawing.Color]::FromArgb(230, 100, 100)
$ColorYellow   = [System.Drawing.Color]::FromArgb(220, 180, 80)
$ColorBlue     = [System.Drawing.Color]::FromArgb(120, 180, 230)
$ColorLime     = [System.Drawing.Color]::FromArgb(195, 217, 94)

# --- Main form ---

$form = New-Object System.Windows.Forms.Form
$form.Text = "$ProductName v$ProductVersion - $ProductBrand"
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1100, 720)
$form.MinimumSize = New-Object System.Drawing.Size(900, 560)
$form.BackColor = $ColorBg
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# Status banner

$banner = New-Object System.Windows.Forms.Panel
$banner.Dock = 'Top'
$banner.Height = 76
$banner.BackColor = $ColorPanelBg
$banner.Padding = New-Object System.Windows.Forms.Padding(16, 10, 16, 10)
$form.Controls.Add($banner)

$bannerDot = New-Object System.Windows.Forms.Label
$bannerDot.Text = [char]0x25CF  # bullet
$bannerDot.Font = New-Object System.Drawing.Font('Segoe UI', 22)
$bannerDot.AutoSize = $true
$bannerDot.Location = New-Object System.Drawing.Point(16, 14)
$banner.Controls.Add($bannerDot)

$bannerTitle = New-Object System.Windows.Forms.Label
$bannerTitle.Text = "$ProductName"
$bannerTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$bannerTitle.AutoSize = $true
$bannerTitle.Location = New-Object System.Drawing.Point(50, 12)
$bannerTitle.ForeColor = $ColorLime
$banner.Controls.Add($bannerTitle)

$bannerSub = New-Object System.Windows.Forms.Label
$bannerSub.Text = ''
$bannerSub.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$bannerSub.AutoSize = $true
$bannerSub.Location = New-Object System.Drawing.Point(50, 42)
$bannerSub.ForeColor = [System.Drawing.Color]::Gainsboro
$banner.Controls.Add($bannerSub)

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = 'Install Update Arbiter'
$btnInstall.Size = New-Object System.Drawing.Size(180, 36)
$btnInstall.FlatStyle = 'Flat'
$btnInstall.BackColor = $ColorLime
$btnInstall.ForeColor = [System.Drawing.Color]::FromArgb(35, 39, 15)
$btnInstall.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$btnInstall.Anchor = 'Top, Right'
$btnInstall.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(140, 160, 60)
$banner.Controls.Add($btnInstall)

$btnUninstall = New-Object System.Windows.Forms.Button
$btnUninstall.Text = 'Uninstall'
$btnUninstall.Size = New-Object System.Drawing.Size(110, 36)
$btnUninstall.FlatStyle = 'Flat'
$btnUninstall.BackColor = [System.Drawing.Color]::FromArgb(100, 50, 50)
$btnUninstall.ForeColor = [System.Drawing.Color]::White
$btnUninstall.Anchor = 'Top, Right'
$btnUninstall.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(140, 70, 70)
$banner.Controls.Add($btnUninstall)

# Reposition install/uninstall buttons on resize
$positionBannerButtons = {
    $btnInstall.Location   = New-Object System.Drawing.Point(($banner.Width - $btnInstall.Width - 16), 20)
    $btnUninstall.Location = New-Object System.Drawing.Point(($banner.Width - $btnInstall.Width - $btnUninstall.Width - 28), 20)
}
$banner.Add_Resize($positionBannerButtons)

# Top controls strip

$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = 'Top'
$topPanel.Height = 48
$topPanel.BackColor = $ColorPanelBg
$form.Controls.Add($topPanel)

$lblDays = New-Object System.Windows.Forms.Label
$lblDays.Text = 'Days back:'
$lblDays.Location = New-Object System.Drawing.Point(16, 16)
$lblDays.AutoSize = $true
$lblDays.ForeColor = [System.Drawing.Color]::Gainsboro
$topPanel.Controls.Add($lblDays)

$numDays = New-Object System.Windows.Forms.NumericUpDown
$numDays.Location = New-Object System.Drawing.Point(86, 13)
$numDays.Size = New-Object System.Drawing.Size(70, 24)
$numDays.Minimum = 1; $numDays.Maximum = 3650; $numDays.Value = 30
$numDays.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$numDays.ForeColor = [System.Drawing.Color]::White
$topPanel.Controls.Add($numDays)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh'
$btnRefresh.Location = New-Object System.Drawing.Point(169, 11); $btnRefresh.Size = New-Object System.Drawing.Size(90, 28)
$btnRefresh.FlatStyle = 'Flat'
$btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(60, 110, 60); $btnRefresh.ForeColor = [System.Drawing.Color]::White
$btnRefresh.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(40, 90, 40)
$topPanel.Controls.Add($btnRefresh)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = 'Export CSV...'
$btnExport.Location = New-Object System.Drawing.Point(269, 11); $btnExport.Size = New-Object System.Drawing.Size(110, 28)
$btnExport.FlatStyle = 'Flat'
$btnExport.BackColor = [System.Drawing.Color]::FromArgb(60, 80, 110); $btnExport.ForeColor = [System.Drawing.Color]::White
$btnExport.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(40, 60, 90)
$topPanel.Controls.Add($btnExport)

# Summary strip

$summaryPanel = New-Object System.Windows.Forms.Panel
$summaryPanel.Dock = 'Top'; $summaryPanel.Height = 72; $summaryPanel.BackColor = $ColorSummary
$summaryPanel.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)
$form.Controls.Add($summaryPanel)

function New-Stat {
    param([string]$Caption, [int]$X, [System.Drawing.Color]$ValueColor)
    $cap = New-Object System.Windows.Forms.Label
    $cap.Text = $Caption; $cap.Location = New-Object System.Drawing.Point($X, 8); $cap.AutoSize = $true
    $cap.ForeColor = [System.Drawing.Color]::Gray
    $cap.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $summaryPanel.Controls.Add($cap)
    $val = New-Object System.Windows.Forms.Label
    $val.Text = '--'; $val.Location = New-Object System.Drawing.Point($X, 26); $val.AutoSize = $true
    $val.ForeColor = $ValueColor
    $val.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $summaryPanel.Controls.Add($val)
    return $val
}

$lblSessions   = New-Stat 'SESSIONS'           16  ([System.Drawing.Color]::White)
$lblUnexpected = New-Stat 'UNEXPECTED REBOOTS' 130 ([System.Drawing.Color]::White)
$lblTotal      = New-Stat 'TOTAL UPTIME'       310 ([System.Drawing.Color]::White)
$lblAvg        = New-Stat 'AVERAGE'            460 ([System.Drawing.Color]::White)
$lblLongest    = New-Stat 'LONGEST'            600 $ColorGreen
$lblShortest   = New-Stat 'SHORTEST'           740 $ColorYellow

# Status bar

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusStrip.BackColor = $ColorPanelBg
$statusStrip.SizingGrip = $false
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = 'Ready'
$statusLabel.ForeColor = [System.Drawing.Color]::Gainsboro
[void]$statusStrip.Items.Add($statusLabel)
$form.Controls.Add($statusStrip)

# Grid

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.BackgroundColor = $ColorBg
$grid.GridColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$grid.BorderStyle = 'None'
$grid.RowHeadersVisible = $false
$grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.AllowUserToResizeRows = $false
$grid.ReadOnly = $true
$grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$grid.ColumnHeadersHeight = 32; $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
$grid.DefaultCellStyle.BackColor = $ColorBg; $grid.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(70, 90, 130)
$grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
$grid.AlternatingRowsDefaultCellStyle.BackColor = $ColorAlt
$grid.RowTemplate.Height = 26
$form.Controls.Add($grid); $grid.BringToFront()

[void]$grid.Columns.Add('BootTime',     'Boot Time')
[void]$grid.Columns.Add('ShutdownTime', 'Shutdown Time')
[void]$grid.Columns.Add('Duration',     'Uptime')
[void]$grid.Columns.Add('ShutdownType', 'Status')
[void]$grid.Columns.Add('Reason',       'Reboot Reason')
$grid.Columns['BootTime'].FillWeight     = 14
$grid.Columns['ShutdownTime'].FillWeight = 14
$grid.Columns['Duration'].FillWeight     = 10
$grid.Columns['ShutdownType'].FillWeight = 14
$grid.Columns['Reason'].FillWeight       = 48
$grid.Columns['Reason'].DefaultCellStyle.WrapMode = 'True'
$grid.AutoSizeRowsMode = 'AllCells'

$script:Sessions = @()

# --- Behavior ---

function Update-StatusBanner {
    $s = Get-ArbiterStatus
    if ($s.Installed) {
        $bannerDot.ForeColor = $ColorGreen
        $installedAt = if ($s.InstalledAt) { $s.InstalledAt.ToString('yyyy-MM-dd HH:mm') } else { 'unknown' }
        $trayBit = if ($s.TrayAutostartSet) {
            if ($s.TrayRunning) { 'Tray: running' } else { 'Tray: registered (not running)' }
        } else { 'Tray: not registered' }
        $bannerTitle.Text = "$ProductName - PROTECTED"
        $bannerSub.Text = "Installed v$($s.InstalledVersion) on $installedAt | Self-heal: $($s.ScheduledTask.State) | $trayBit"
        $btnInstall.Text = 'Reinstall / Repair'
        $btnUninstall.Enabled = $true
    } else {
        $bannerDot.ForeColor = $ColorRed
        $bannerTitle.Text = "$ProductName - NOT INSTALLED"
        $missing = @()
        if (-not $s.AllPoliciesPresent) { $missing += 'reboot policies' }
        if (-not $s.TaskHealthy)        { $missing += 'self-heal task' }
        $bannerSub.Text = if ($missing.Count -gt 0) { "Missing: $($missing -join ', ')" } else { 'Run installer to lock down Windows auto-reboots' }
        $btnInstall.Text = 'Install Update Arbiter'
        $btnUninstall.Enabled = ($s.InstallDirPresent -or ($s.ScheduledTask -ne $null) -or $s.PolicyResults.Where({ $_.Ok }).Count -gt 0)
    }
    & $positionBannerButtons
}

function Update-Dashboard {
    $statusLabel.Text = 'Loading event log...'
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $grid.Rows.Clear()
    [System.Windows.Forms.Application]::DoEvents()

    try { $script:Sessions = Get-UptimeSessions -DaysBack ([int]$numDays.Value) }
    catch {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $statusLabel.Text = "Failed to read event log: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Could not read the System event log.`n`n$($_.Exception.Message)`n`nThis tool must run as Administrator.",
            $ProductName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    if (-not $script:Sessions -or $script:Sessions.Count -eq 0) {
        $statusLabel.Text = "No boot/shutdown events in the last $($numDays.Value) days."
        foreach ($l in $lblSessions, $lblUnexpected, $lblTotal, $lblAvg, $lblLongest, $lblShortest) { $l.Text = '--' }
        $lblSessions.Text = '0'; $lblUnexpected.Text = '0'
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        return
    }

    foreach ($s in $script:Sessions) {
        $bootStr = $s.BootTime.ToString('yyyy-MM-dd HH:mm')
        $shutStr = if ($s.ShutdownTime) { $s.ShutdownTime.ToString('yyyy-MM-dd HH:mm') } else { '---' }
        $durStr  = Format-Duration $s.Duration
        $idx = $grid.Rows.Add($bootStr, $shutStr, $durStr, $s.ShutdownType, $s.Reason)
        $row = $grid.Rows[$idx]
        switch ($s.ShutdownType) {
            'Clean'                     { $row.Cells['ShutdownType'].Style.ForeColor = $ColorGreen }
            'Unexpected'                {
                $row.Cells['ShutdownType'].Style.ForeColor = $ColorRed
                $row.Cells['ShutdownType'].Style.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
            }
            'Current session (ongoing)' { $row.Cells['ShutdownType'].Style.ForeColor = $ColorBlue }
            default                     { $row.Cells['ShutdownType'].Style.ForeColor = $ColorYellow }
        }
    }

    $completed = @($script:Sessions | Where-Object { $_.Duration -and $_.ShutdownType -ne 'Current session (ongoing)' })
    $lblSessions.Text = "$($script:Sessions.Count)"
    if ($completed.Count -gt 0) {
        $secs  = $completed | ForEach-Object { $_.Duration.TotalSeconds }
        $stats = $secs | Measure-Object -Sum -Average -Maximum -Minimum
        $unexpectedCount = @($completed | Where-Object { $_.ShutdownType -eq 'Unexpected' }).Count
        $lblUnexpected.Text = "$unexpectedCount"
        $lblUnexpected.ForeColor = if ($unexpectedCount -gt 0) { $ColorRed } else { $ColorGreen }
        $lblTotal.Text    = Format-Duration ([TimeSpan]::FromSeconds($stats.Sum))
        $lblAvg.Text      = Format-Duration ([TimeSpan]::FromSeconds($stats.Average))
        $lblLongest.Text  = Format-Duration ([TimeSpan]::FromSeconds($stats.Maximum))
        $lblShortest.Text = Format-Duration ([TimeSpan]::FromSeconds($stats.Minimum))
    } else {
        $lblUnexpected.Text = '0'
        foreach ($l in $lblTotal, $lblAvg, $lblLongest, $lblShortest) { $l.Text = '--' }
    }

    $statusLabel.Text = "Loaded $($script:Sessions.Count) sessions over last $($numDays.Value) days. Last refresh: $(Get-Date -Format 'HH:mm:ss')"
    $form.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Export-Sessions {
    if (-not $script:Sessions -or $script:Sessions.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Nothing to export. Refresh first.', $ProductName,
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $dialog.FileName = "uptime_sessions_$(Get-Date -Format 'yyyyMMdd').csv"
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        $script:Sessions | Select-Object BootTime, ShutdownTime,
            @{N='DurationHours'; E={ if ($_.Duration) { [math]::Round($_.Duration.TotalHours, 2) } }},
            ShutdownType, Reason |
            Export-Csv -Path $dialog.FileName -NoTypeInformation -Encoding UTF8
        $statusLabel.Text = "Exported to $($dialog.FileName)"
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Export failed: $($_.Exception.Message)", $ProductName,
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

# --- Install/Uninstall modal ---

function Show-OperationDialog {
    param(
        [string]$Title,
        [string]$IntroText,
        [scriptblock]$Operation  # called with a $Log scriptblock
    )

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.StartPosition = 'CenterParent'
    $dlg.Size = New-Object System.Drawing.Size(820, 540)
    $dlg.MinimumSize = New-Object System.Drawing.Size(640, 400)
    $dlg.BackColor = $ColorBg
    $dlg.ForeColor = [System.Drawing.Color]::White
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dlg.FormBorderStyle = 'Sizable'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = $IntroText
    $intro.Dock = 'Top'; $intro.Height = 44
    $intro.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 8)
    $intro.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $intro.ForeColor = [System.Drawing.Color]::Gainsboro
    $dlg.Controls.Add($intro)

    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'; $bottom.Height = 52
    $bottom.BackColor = $ColorPanelBg
    $dlg.Controls.Add($bottom)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Close'
    $btnClose.Size = New-Object System.Drawing.Size(100, 32)
    $btnClose.FlatStyle = 'Flat'
    $btnClose.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60); $btnClose.ForeColor = [System.Drawing.Color]::White
    $btnClose.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $btnClose.Anchor = 'Top, Right'
    $btnClose.Enabled = $false
    $bottom.Controls.Add($btnClose)
    $bottom.Add_Resize({ $btnClose.Location = New-Object System.Drawing.Point(($bottom.Width - $btnClose.Width - 16), 10) })
    $btnClose.Location = New-Object System.Drawing.Point(($bottom.Width - $btnClose.Width - 16), 10)
    $btnClose.Add_Click({ $dlg.Close() })

    $box = New-Object System.Windows.Forms.RichTextBox
    $box.Dock = 'Fill'
    $box.ReadOnly = $true
    $box.BackColor = $ColorBg
    $box.ForeColor = [System.Drawing.Color]::White
    $box.Font = New-Object System.Drawing.Font('Consolas', 9)
    $box.BorderStyle = 'None'
    $box.ScrollBars = 'Vertical'
    $box.DetectUrls = $false
    $dlg.Controls.Add($box); $box.BringToFront()

    $log = {
        param([string]$Level, [string]$Message)
        $color = switch ($Level) {
            'OK'   { $ColorGreen }
            'STEP' { $ColorLime }
            'WARN' { $ColorYellow }
            'FAIL' { $ColorRed }
            'DONE' { $ColorBlue }
            default { [System.Drawing.Color]::White }
        }
        $stamp = Get-Date -Format 'HH:mm:ss'
        $prefix = "[$stamp] "
        $tag = "{0,-5} " -f $Level
        $box.SelectionStart = $box.TextLength
        $box.SelectionColor = [System.Drawing.Color]::DimGray
        $box.AppendText($prefix)
        $box.SelectionStart = $box.TextLength
        $box.SelectionColor = $color
        $box.AppendText($tag)
        $box.SelectionStart = $box.TextLength
        $box.SelectionColor = [System.Drawing.Color]::White
        $box.AppendText("$Message`r`n")
        $box.SelectionStart = $box.TextLength
        $box.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }

    $dlg.Add_Shown({
        & $log 'STEP' "$ProductName v$ProductVersion"
        & $log 'STEP' "Running as $env:USERDOMAIN\$env:USERNAME (admin elevated)"
        try {
            & $Operation $log | Out-Null
        } catch {
            & $log 'FAIL' "Unhandled error: $($_.Exception.Message)"
        }
        $btnClose.Enabled = $true
        $btnClose.Focus() | Out-Null
    })

    [void]$dlg.ShowDialog($form)
    Update-StatusBanner
}

# --- Wire up ---

$btnRefresh.Add_Click({ Update-Dashboard })
$btnExport.Add_Click({ Export-Sessions })

$btnInstall.Add_Click({
    $isInstalled = (Get-ArbiterStatus).Installed
    $confirmText = if ($isInstalled) {
        "This will re-apply $ProductName policies and refresh the self-heal task. Continue?"
    } else {
        "This will:`n`n  - Set Windows Update reboot-blocking policies`n  - Disable Update Orchestrator reboot tasks (where present)`n  - Register a SYSTEM scheduled task that re-applies these on every boot, logon, and Windows Update servicing event`n`nContinue?"
    }
    $ans = [System.Windows.Forms.MessageBox]::Show($confirmText, "$ProductName - Install",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ans -ne [System.Windows.Forms.DialogResult]::OK) { return }
    Show-OperationDialog -Title "$ProductName - Installing" `
        -IntroText 'Applying lockdown. Each step is verified by reading the setting back after writing it.' `
        -Operation { param($Log) Invoke-Install -Log $Log }
})

$btnUninstall.Add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "This will remove the self-heal task, re-enable Update Orchestrator reboot tasks, remove reboot-blocking registry policies, and delete $InstallDir.`n`nContinue?",
        "$ProductName - Uninstall",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($ans -ne [System.Windows.Forms.DialogResult]::OK) { return }
    Show-OperationDialog -Title "$ProductName - Uninstalling" `
        -IntroText 'Reverting all changes.' `
        -Operation { param($Log) Invoke-Uninstall -Log $Log }
})

$form.Add_Shown({
    Update-StatusBanner
    Update-Dashboard
})

[System.Windows.Forms.Application]::Run($form)
