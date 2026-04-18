# v1.0.0 Launch Notes

**Shipped:** 2026-04-18

## What went out

- **Installer v1.0.0** — `update-arbiter-1.0.0.ps1` published as a GitHub Release asset. Permanent direct link that auto-tracks the latest release:
  - <https://github.com/Arcusfoundry/update-arbiter/releases/latest/download/update-arbiter-1.0.0.ps1>
- **Landing page** at <https://arcusfoundry.com/tools/update-arbiter> — in the Arcus Foundry visual language (olive + graph grid, Barlow Condensed, lime accents). Inline Sparkforge lead-capture form in the hero and again in the final CTA.
- **Nav entry** in the Arcus Foundry global header under **RESOURCES → Tools**, pointing at the landing page.
- **Email delivery** — Sparkforge form `Nuui5gThSgjHET8amGTU` tags each submission `update-arbiter-download`; a workflow triggered on that tag sends the GitHub installer URL with setup instructions.

## What the installer does

Blocks Windows 11 auto-reboots while keeping all other Windows Update traffic intact. See `README.md` for the full technical details.

- Applies `NoAutoRebootWithLoggedOnUsers` Group Policy.
- Widens Active Hours to the maximum 18-hour window.
- Disables the three `UpdateOrchestrator` reboot-trigger scheduled tasks.
- Installs a self-heal scheduled task that re-runs at boot, logon, and on `WindowsUpdateClient` servicing events so feature updates can't quietly revert the policy.
- Leaves update scanning, download, install, notifications, and the Medic Service intact.

## How to install

```powershell
Unblock-File .\update-arbiter-1.0.0.ps1
powershell.exe -ExecutionPolicy Bypass -File .\update-arbiter-1.0.0.ps1 -Install
```

Uninstall with `-Uninstall` (removes the scheduled task; registry keys stay in place until reverted manually — see the script for exact keys).

## License

MIT. Free community tool from [Arcus Foundry](https://arcusfoundry.com). No warranty. Use at your own risk.

## Report issues

<https://github.com/Arcusfoundry/update-arbiter/issues> — or reply to the installer email.

## What's next

- Code-signing cert for the `.ps1` (parallel workstream — not blocking v1).
- Desktop companion (days-since-reboot counter + AI-summarized pending updates with severity grade) is a v2 discussion; nothing committed yet.
- Multi-device deployment story for Sparkforge Pro customers.
