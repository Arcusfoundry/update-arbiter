# Update Arbiter

**Stops Windows 11 from rebooting without your consent. Security updates still flow.**

Your PC already has an update arbiter. It works for Microsoft, not for you. This one works for you.

Free tool from [Arcus Foundry](https://arcusfoundry.com/update-arbiter). No warranty. Use at your own risk.

---

## What it does

- Applies the Windows policy that says "never restart while someone is logged in" (the `NoAutoRebootWithLoggedOnUsers` Group Policy setting that Microsoft already ships).
- Disables three specific `UpdateOrchestrator` scheduled tasks that trigger reboots: `Reboot`, `Reboot_AC`, and `Reboot_Battery`.
- Sets Active Hours to their widest allowed window (18 hours).
- Installs a scheduled task that **re-applies the lockdown** at boot, at logon, and every time Windows Update signals it finished installing something, so feature updates cannot quietly revert the policy.

It leaves intact: update scanning, downloading, installing, notifications, and the Windows Update Medic Service. Security patches keep flowing. The only thing that changes is who decides when the machine actually restarts. You do.

## Install

1. Download [`update-arbiter-1.0.0.ps1`](https://github.com/Arcusfoundry/update-arbiter/releases/latest/download/update-arbiter-1.0.0.ps1) from the latest release.
2. Open PowerShell **as Administrator**.
3. Unblock the file and run the installer:

   ```powershell
   Unblock-File .\update-arbiter-1.0.0.ps1
   powershell.exe -ExecutionPolicy Bypass -File .\update-arbiter-1.0.0.ps1 -Install
   ```

That is it. The lockdown is applied and a self-heal scheduled task is registered. You do not need to run it again. Reboots now wait for you.

### Apply once without installing the self-heal

If you just want to apply the policies once and skip the scheduled task:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\update-arbiter-1.0.0.ps1
```

## Uninstall

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\update-arbiter-1.0.0.ps1 -Uninstall
```

Removes the scheduled task and the installed script copy. Registry policies and the disabled reboot tasks remain in place until you revert them manually. See the script source for the exact keys.

## What it changes on your system

The full source is right there in [`update-arbiter-1.0.0.ps1`](update-arbiter-1.0.0.ps1). Read it before you run it.

**Registry keys:**

- `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\NoAutoRebootWithLoggedOnUsers = 1`
- `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\SetActiveHours = 1`
- `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\ActiveHoursStart = 0`
- `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\ActiveHoursEnd = 18`
- `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\ActiveHoursMaxRange = 18`
- Plus matching `UX\Settings` entries for the UI.

**Scheduled tasks disabled:**

- `\Microsoft\Windows\UpdateOrchestrator\Reboot`
- `\Microsoft\Windows\UpdateOrchestrator\Reboot_AC`
- `\Microsoft\Windows\UpdateOrchestrator\Reboot_Battery`

**Scheduled task created:**

- `Arcus Foundry Update Arbiter` at `\` (runs as SYSTEM, triggered at boot, at logon, and on `WindowsUpdateClient` event IDs 19 and 43)

**Files installed:**

- `C:\ProgramData\ArcusFoundry\update-arbiter-1.0.0.ps1`
- `C:\ProgramData\ArcusFoundry\update-arbiter.log`

## FAQ

**Will I still get security updates?** Yes. Updates download and install normally. Only the automatic reboot is blocked.

**Does it work on Windows 11 Home?** Yes, both Home and Pro.

**Is this safe?** It uses Microsoft's own published Group Policy settings and disables three specific scheduled tasks in `UpdateOrchestrator`. Nothing exotic, nothing hidden. The source is readable. That said, this is a free tool with no warranty. Use at your own risk.

**What happens after a Windows feature update?** The scheduled task self-heals. It re-runs at boot, at logon, and whenever Windows Update signals it finished installing something. If anything slips through, re-running the installer fixes it.

**Windows 10?** Not supported in v1. We only test on Windows 11.

## Disclaimer

Update Arbiter is a free community tool from Arcus Foundry. It ships as-is with no warranty, express or implied. You are running it on your own machine, on your own judgment. We use it ourselves. We think it is safe. That is not the same as a guarantee. If something breaks on your machine, or a policy conflicts with something else on your network, we cannot be responsible.

## License

[MIT](LICENSE). Free to use, modify, and distribute.

## Built by

[Arcus Foundry](https://arcusfoundry.com). Included free with [Sparkforge Pro](https://arcusfoundry.com/sparkforge). Feedback welcome in the [issues](https://github.com/Arcusfoundry/update-arbiter/issues).
