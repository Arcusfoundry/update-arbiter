# Changelog

## v2.0.2 - 2026-06-18

Reliability and self-defense pass on the v2.0.x agent, plus a self-update signal.

- Fix tray crash on boot. The single-instance guard moved from the machine-wide `Global\` namespace to session-scoped `Local\`, ending the `Access to the path 'Global\UpdateArbiterTray.SingleInstance' is denied` exception (a `Global\` named object needs `SeCreateGlobalPrivilege` and matching DACL rights the non-elevated tray may lack). The guard now fails open and handles `AbandonedMutexException`.
- Self-heal hardening. `Invoke-Install` takes a new `-Headless` switch for the SYSTEM self-heal path, which no longer kills/relaunches the user's tray or writes the `HKCU` autostart key. SYSTEM runs in session 0, so doing either would empty the notification area until next logon.
- Fix tray-deploy ordering. The interactive installer now stops a running tray before copying its EXE, so a repair no longer fails on the file lock and relaunches a stale binary.
- Hourly rearm. The self-heal task now also fires hourly (a `TimeTrigger` with a 1-hour repetition) on top of boot, logon, and `WindowsUpdateClient` 19/43.
- Reboot-flag kill. Every self-heal deletes `...\WindowsUpdate\Auto Update\RebootRequired` when present. Component Based Servicing `RebootPending` is deliberately left untouched (clearing it mid-servicing can corrupt the component store). The tray also detects the flag each poll and triggers a SYSTEM rearm to clear it.
- Reliable "Last rearm". Sourced from a `LastRearmAt` stamp written to `state.json` on every successful self-heal, since Task Scheduler's `LastRunTime` is unreliable for SYSTEM tasks and can stay pinned at the 1899 sentinel. `InstalledAt` is preserved across rearms.
- New-version notifier. The tray polls a `version.json` manifest hourly and surfaces a download prompt when a newer Update Arbiter is published. Silent no-op when the endpoint is absent or unreachable.
- Product URLs updated to `arcusfoundry.com/labs/update-arbiter`.

## v2.0.1 - in development

Fix for the planned-upgrade reboot bypass observed on Win11 26200+. `NoAutoRebootWithLoggedOnUsers` and `SetActiveHours` cover the AU code path but not `MoUsoCoreWorker.exe` / `TrustedInstaller.exe` driving "Operating System: Service pack (Planned)" and "Operating System: Upgrade (Planned)" restarts — those use the feature-update code path and ignore the AU policy. Adds Windows Update for Business deferral policies so the feature/OS-upgrade reboots are held off; quality (security) updates still flow normally.

- Add `DeferFeatureUpdates = 1` and `DeferFeatureUpdatesPeriodInDays = 365` (max) under `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`.
- Add explicit `DeferQualityUpdates = 0` and `DeferQualityUpdatesPeriodInDays = 0` so security CUs remain on the normal cadence.
- Add `AlwaysAutoRebootAtScheduledTime = 0` under `...\WindowsUpdate\AU` as a belt-and-suspenders block against scheduled-time reboots.
- Tray's `Get-ArbiterStatus` policy list synced with the installer so the PROTECTED badge requires the new deferral policies to be present.
- Fix double-write in the self-heal log path. The `-SelfHeal` entry point passed `Write-FileLog` as the UI logger, and `Invoke-Install`'s internal `L` function then called `Write-FileLog` again, so every entry landed in `update-arbiter.log` twice. The UI logger is now a no-op in self-heal mode.
- Fix "Cannot overwrite the item ... with itself" when the installer is re-run from `C:\ProgramData\ArcusFoundry`. The tray-deploy step now compares fully-resolved source/destination paths before `Copy-Item`.

## v2.0.0 - in development

Major rework. Adds a GUI dashboard with an installer that verifies every step by reading the value back, and a non-elevated tray agent so users have an ongoing signal that protection is in place.

- New `UpdateArbiter.ps1` (admin GUI, compiled to `UpdateArbiter.exe`) replaces the v1.0.0 CLI installer.
- Status banner shows `PROTECTED` or `NOT INSTALLED` at a glance, with version, install date, scheduled-task state, and tray status.
- Built-in uptime dashboard correlates boot and shutdown events with USER32 1074 (initiated shutdowns), Microsoft-Windows-Kernel-Power 41 (dirty shutdowns), and BugCheck 1001 (BSOD codes). New `Reboot Reason` column makes it obvious *why* a reboot happened.
- Install modal streams a step-by-step log. Every registry write does `Set-ItemProperty` followed by `Get-ItemProperty` read-back, and the final verification refuses to claim success unless all policies are present and the self-heal task is healthy.
- New `UpdateArbiterTray.ps1` (no admin, compiled to `UpdateArbiterTray.exe`) — notification-area shield icon, green when protected, red when policies or task have drifted, with right-click menu (Open Dashboard, Verify Now, View Log, About, Exit).
- Tray autostarts via `HKCU` Run key, set by the installer with read-back verification. Launched at medium integrity from the elevated installer, so no UAC prompt at logon.
- Self-heal task now runs `UpdateArbiter.exe -SelfHeal` directly rather than a copied `.ps1`.
- Fix for the v1.0.0 silent-failure mode: replaced `$ErrorActionPreference = 'Continue'` with explicit `-ErrorAction Stop` plus per-step verification.
- Newer Win11 builds (26200+) have moved reboot-trigger logic out of the `UpdateOrchestrator\Reboot*` scheduled tasks. v2.0.0 treats missing tasks as expected on those builds and leans on `NoAutoRebootWithLoggedOnUsers` as the load-bearing protection.

Pending before public release: EV code-signing cert, Add/Remove Programs registration, optional WiX MSI wrapper for fleet deployment.

## v1.0.0 - 2026-04-17

First public release.

- Applies `NoAutoRebootWithLoggedOnUsers` Group Policy so Windows 11 never restarts while a user is logged in.
- Widens Active Hours to the maximum 18-hour window.
- Disables the three `UpdateOrchestrator` reboot-trigger scheduled tasks (`Reboot`, `Reboot_AC`, `Reboot_Battery`).
- Installs a self-heal scheduled task that re-applies the lockdown at boot, at logon, and when `WindowsUpdateClient` events 19 and 43 fire, so feature updates cannot quietly revert the policy.
- Leaves update scanning, download, installation, notifications, and the Windows Update Medic Service intact. Security patches keep flowing.
- `-Install` registers the self-heal task. `-Uninstall` removes it (registry policies remain until reverted manually).
