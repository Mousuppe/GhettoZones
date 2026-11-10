# GhettoZones shareable `.pkg` installer

## Goal

Friends/coworkers can double-click a `.pkg` to install `GhettoZones.app` into `/Applications` without building from source. No Apple Developer ID / notarization for now.

## Approach

Option A: unsigned `pkgbuild` component package.

## Behavior

1. Build Release `GhettoZones.app` (or reuse a provided `.app`).
2. Stage under a payload root as `Applications/GhettoZones.app`.
3. `pkgbuild` → `dist/GhettoZones-<version>.pkg` with identifier `com.mousuppe.GhettoZones.pkg`.
4. Postinstall opens `/Applications/GhettoZones.app` (errors ignored).
5. Reinstall replaces the existing app.

## Out of scope

- Developer ID signing / notarization
- Welcome/Conclusion installer UI
- Auto-granting Accessibility (impossible without special entitlements)

## Recipient notes

- First open may require right-click → Open (Gatekeeper / ad-hoc signature).
- Accessibility must still be enabled in System Settings.
