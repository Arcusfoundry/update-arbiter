# Testing + Operationalization Plan — update-arbiter

Planning artifact for the testing matrix (#6) and ops documentation (#8) epics.
Epics created 2026-06-05.

## Testing epic — #6

| Issue | Layer | Description |
|---|---|---|
| #3 | Pester unit | Unit tests for policy logic and state management (mocked registry) |
| #4 | CI wiring | Wire Pester tests into check.yml (windows-latest) |
| #5 | Deferred | Full install/uninstall smoke in sandboxed Windows environment |

Implementation order: #3 → #4 → #5

## Ops epic — #8

| Issue | Area | Description |
|---|---|---|
| #7 | All ops | Architecture + install runbook + policy reference + troubleshooting + onboarding |

Both epics can be worked in parallel.
