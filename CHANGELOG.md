# Changelog

## v1.0.0 - 2026-04-17

First public release.

- Applies `NoAutoRebootWithLoggedOnUsers` Group Policy so Windows 11 never restarts while a user is logged in.
- Widens Active Hours to the maximum 18-hour window.
- Disables the three `UpdateOrchestrator` reboot-trigger scheduled tasks (`Reboot`, `Reboot_AC`, `Reboot_Battery`).
- Installs a self-heal scheduled task that re-applies the lockdown at boot, at logon, and when `WindowsUpdateClient` events 19 and 43 fire, so feature updates cannot quietly revert the policy.
- Leaves update scanning, download, installation, notifications, and the Windows Update Medic Service intact. Security patches keep flowing.
- `-Install` registers the self-heal task. `-Uninstall` removes it (registry policies remain until reverted manually).
