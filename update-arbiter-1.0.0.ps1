<#
.SYNOPSIS
    Update Arbiter v1.0.0 - Stops Windows 11 from rebooting without your consent.

.DESCRIPTION
    Your PC already has an update arbiter. It works for Microsoft, not for you.
    This one works for you.

    Update Arbiter applies a tight set of reboot-blocking policies and disables
    only the scheduled tasks that actually trigger reboots. Update scanning,
    downloading, installing, and notifications all keep working normally.
    Security patches still flow. The machine just never restarts without you
    saying so.

    Installs itself as a scheduled task that re-runs at boot, at logon, and
    when Windows Update servicing events fire, so feature updates cannot
    silently undo the lockdown.

    Free tool from Arcus Foundry. Use at your own risk.
    https://arcusfoundry.com/labs/update-arbiter

.PARAMETER Install
    Installs this script to C:\ProgramData\ArcusFoundry\ and registers the
    scheduled task that re-runs it on boot, logon, and servicing events.

.PARAMETER Uninstall
    Removes the scheduled task and the installed script copy. Note: registry
    policies and disabled reboot tasks remain in place until reverted manually.

.EXAMPLE
    .\update-arbiter-1.0.0.ps1
    Applies the lockdown once.

.EXAMPLE
    .\update-arbiter-1.0.0.ps1 -Install
    Applies the lockdown AND installs the self-heal scheduled task.

.EXAMPLE
    .\update-arbiter-1.0.0.ps1 -Uninstall
    Removes the self-heal scheduled task and the installed script copy.

.NOTES
    Product : Update Arbiter
    Version : 1.0.0
    Brand   : Arcus Foundry (https://arcusfoundry.com)
    License : Free. No warranty. Use at your own risk.

    Must be run from an elevated PowerShell session. If you downloaded this
    from a browser, Windows may flag it as blocked. Unblock it first:
        Unblock-File .\update-arbiter-1.0.0.ps1
    And if your execution policy is restrictive:
        powershell.exe -ExecutionPolicy Bypass -File .\update-arbiter-1.0.0.ps1
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Continue'
$productName           = 'Update Arbiter'
$productVersion        = '1.0.0'
$productBrand          = 'Arcus Foundry'
$scriptName            = 'update-arbiter-1.0.0.ps1'
$installDir            = 'C:\ProgramData\ArcusFoundry'
$installedScriptPath   = Join-Path $installDir $scriptName
$taskName              = 'Arcus Foundry Update Arbiter'
$logPath               = Join-Path $installDir 'update-arbiter.log'

function Write-Log {
    param([string]$Message, [string]$Color = 'White')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "[$stamp] $Message"
    Write-Host $line -ForegroundColor $Color
    if (Test-Path $installDir) {
        Add-Content -Path $logPath -Value $line -ErrorAction SilentlyContinue
    }
}

function Write-Banner {
    $banner = @(
        '',
        '  +--------------------------------------------------------+',
        '  |                                                        |',
        '  |             U P D A T E   A R B I T E R                |',
        '  |                                                        |',
        "  |          by $productBrand          v$productVersion           |",
        '  |                                                        |',
        '  +--------------------------------------------------------+',
        '  |  Free tool. No warranty. Use at your own risk.         |',
        '  |  https://arcusfoundry.com/labs/update-arbiter               |',
        '  +--------------------------------------------------------+',
        ''
    )
    foreach ($line in $banner) {
        Write-Host $line -ForegroundColor Green
    }
}

Write-Banner

# ---------------------------------------------------------------------------
# Uninstall path
# ---------------------------------------------------------------------------
if ($Uninstall) {
    Write-Log "Uninstalling $productName..." 'Yellow'
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $installedScriptPath) { Remove-Item $installedScriptPath -Force }
    Write-Log "Uninstall complete. Registry policies and disabled reboot tasks remain in place." 'Green'
    Write-Log "To fully revert, see https://arcusfoundry.com/labs/update-arbiter#uninstall" 'DarkGray'
    return
}

# ---------------------------------------------------------------------------
# Apply the lockdown (tight scope)
# ---------------------------------------------------------------------------
Write-Log "=== $productName v$productVersion - applying lockdown ===" 'Cyan'

# --- Registry policies ---
Write-Log "Applying reboot-blocking registry policies..." 'Yellow'

$auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$wuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$uxPath = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'

foreach ($path in @($wuPath, $auPath, $uxPath)) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
}

# The single most important setting: never reboot while a user is logged on
Set-ItemProperty -Path $auPath -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1 -Type DWord

# Max active hours window (18 hours is the cap Windows allows)
Set-ItemProperty -Path $wuPath -Name 'SetActiveHours'       -Value 1  -Type DWord
Set-ItemProperty -Path $wuPath -Name 'ActiveHoursStart'     -Value 0  -Type DWord
Set-ItemProperty -Path $wuPath -Name 'ActiveHoursEnd'       -Value 18 -Type DWord
Set-ItemProperty -Path $wuPath -Name 'ActiveHoursMaxRange'  -Value 18 -Type DWord
Set-ItemProperty -Path $uxPath -Name 'ActiveHoursStart'     -Value 0  -Type DWord
Set-ItemProperty -Path $uxPath -Name 'ActiveHoursEnd'       -Value 18 -Type DWord
Set-ItemProperty -Path $uxPath -Name 'IsActiveHoursEnabled' -Value 1  -Type DWord

# Clean up any previous over-aggressive values from earlier script versions
Remove-ItemProperty -Path $auPath -Name 'AUOptions'    -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $auPath -Name 'NoAutoUpdate' -ErrorAction SilentlyContinue

Write-Log "      Registry policies applied." 'Green'

# --- Disable ONLY the reboot-trigger tasks ---
Write-Log "Disabling reboot-trigger scheduled tasks..." 'Yellow'

$rebootTasks = @(
    @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Reboot' },
    @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Reboot_AC' },
    @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Reboot_Battery' }
)

foreach ($t in $rebootTasks) {
    try {
        $task = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($task) {
            Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
            Write-Log "      Disabled: $($t.Path)$($t.Name)" 'Green'
        } else {
            Write-Log "      Not found (ok): $($t.Path)$($t.Name)" 'DarkYellow'
        }
    }
    catch {
        Write-Log "      Could not disable $($t.Name). Try PsExec -i -s. ($($_.Exception.Message))" 'DarkYellow'
    }
}

# Refresh policy
gpupdate /force | Out-Null

Write-Log "Lockdown applied." 'Cyan'
Write-Log "Kept intact: update scanning, download, install, notifications, Medic Service." 'DarkGray'

# ---------------------------------------------------------------------------
# Install path: copy script and register scheduled task
# ---------------------------------------------------------------------------
if ($Install) {
    Write-Log "Installing self-heal scheduled task..." 'Yellow'

    if (-not (Test-Path $installDir)) {
        New-Item -Path $installDir -ItemType Directory -Force | Out-Null
    }

    # Copy this script to the install location
    $currentScript = $PSCommandPath
    if ($currentScript -and ($currentScript -ne $installedScriptPath)) {
        Copy-Item -Path $currentScript -Destination $installedScriptPath -Force
        Write-Log "      Copied script to $installedScriptPath" 'Green'
    }

    # Build the action: run this script silently as SYSTEM
    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installedScriptPath`""

    # Triggers: boot, logon, and servicing events
    $triggers = @()

    # At boot
    $triggers += New-ScheduledTaskTrigger -AtStartup

    # At any user logon
    $triggers += New-ScheduledTaskTrigger -AtLogOn

    # When Windows Update finishes installing something (event 19 in the
    # WindowsUpdateClient log). This is the servicing self-heal hook.
    $cimTrigger = Get-CimClass -ClassName MSFT_TaskEventTrigger `
                               -Namespace Root/Microsoft/Windows/TaskScheduler
    $eventTrigger = New-CimInstance -CimClass $cimTrigger -ClientOnly
    $eventTrigger.Enabled      = $true
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

    # Run as SYSTEM so it can touch protected tasks and registry keys
    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -MultipleInstances IgnoreNew

    # Register (overwrite if it already exists)
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask `
        -TaskName    $taskName `
        -Action      $action `
        -Trigger     $triggers `
        -Principal   $principal `
        -Settings    $settings `
        -Description "Re-applies $productName lockdown at boot, logon, and after servicing events. $productBrand v$productVersion." | Out-Null

    Write-Log "      Scheduled task registered: $taskName" 'Green'
    Write-Log "      Triggers: AtStartup, AtLogOn, WindowsUpdateClient event 19/43" 'DarkGray'
    Write-Log "      Runs as: SYSTEM (Highest)" 'DarkGray'
    Write-Log "      Log: $logPath" 'DarkGray'
}

Write-Log "Done." 'Cyan'
