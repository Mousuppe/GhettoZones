# GhettoZones

A native macOS window manager — a FancyZones-style zone snapper built with Swift and SwiftUI.

GhettoZones lets you define custom screen zones and snap windows into them using drag gestures or keyboard shortcuts. It runs as a menu bar app with no Dock icon.

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ (for building)
- Accessibility permission (required for window snapping)

## Building

### Option A: XcodeGen (recommended)

```bash
brew install xcodegen
cd GhettoZones
xcodegen generate
open GhettoZones.xcodeproj
```

Build and run with ⌘R in Xcode.

### Option B: Open existing project

If `GhettoZones.xcodeproj` is already present:

```bash
open GhettoZones.xcodeproj
```

## First launch

1. Click the grid icon in the menu bar.
2. Grant **Accessibility** access when prompted (System Settings → Privacy & Security → Accessibility).
3. Choose a layout and enable snapping.
4. Drag a window toward a zone edge — hold briefly (default 300ms) until the zone highlights, then release to snap.

## Features

- **Drag-to-snap** — global mouse monitoring with configurable activation threshold
- **Keyboard shortcuts** — ⌥+arrows, ⌥+1–9, ⌥+⇧+arrows (all remappable in Settings)
- **Custom layouts** — visual zone editor with draw, resize, rename, and delete
- **5 built-in presets** — halves, thirds, quarters, primary+sidebar, focus
- **Multi-monitor** — independent layouts per display
- **Position memory** — restores apps to their last zone on launch

## Architecture

```
Zones/
├── GhettoZonesApp.swift      # App entry point
├── AppDelegate.swift         # Menu bar, monitors, window lifecycle
├── Models/                   # Zone, ZoneLayout, AppZoneBinding
├── Managers/                 # ZoneManager, WindowMonitor, etc.
└── Views/                    # SwiftUI views
```

Data persists to `~/Library/Application Support/Zones/layouts.json`.

## Keyboard shortcuts (defaults)

| Shortcut | Action |
|----------|--------|
| ⌥ ← → ↑ ↓ | Snap to adjacent zone |
| ⌥ 1–9 | Snap to zone by index |
| ⌥ ⇧ ← → | Move window to previous/next monitor |

## License

MIT
