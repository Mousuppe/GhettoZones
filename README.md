# GhettoZones

A native macOS window manager — a FancyZones-style zone snapper built with Swift and SwiftUI.

GhettoZones lets you define custom screen zones and snap windows into them using drag gestures or keyboard shortcuts. It runs as a menu bar app with no Dock icon.

## Getting Started

### What you need

| Requirement | Why |
|-------------|-----|
| **macOS 13 Ventura** or later | Minimum supported OS |
| **Xcode 15+** | Required to build the app from source (no pre-built release yet) |
| **Accessibility permission** | Required so GhettoZones can move and resize windows |

### 1. Get the code

```bash
git clone https://github.com/Mousuppe/GhettoZones.git
cd GhettoZones
```

### 2. Build and run

Open the project in Xcode and run it:

```bash
open GhettoZones.xcodeproj
```

Press **⌘R** to build and launch. GhettoZones appears as a **grid icon** in the menu bar — there is no Dock icon.

<details>
<summary>Alternative: build with XcodeGen</summary>

```bash
brew install xcodegen
xcodegen generate
open GhettoZones.xcodeproj
```

</details>

### 3. Grant Accessibility access

On first launch, GhettoZones asks for **Accessibility** permission. This is required for snapping to work.

1. Click **Open System Settings** in the prompt (or go to **System Settings → Privacy & Security → Accessibility**).
2. Enable the toggle for **GhettoZones**.
3. Return to the app — the menu bar icon should no longer show a warning triangle.

If snapping stays disabled, open **Settings…** from the menu bar popover and click **Grant Access**.

### 4. Pick a layout and enable snapping

1. Click the **grid icon** in the menu bar.
2. Choose a layout from the dropdown (e.g. **Halves** or **Thirds**).
3. Make sure **Snapping Enabled** is turned on.

### 5. Snap your first window

**Control + drag to snap**

1. Click and drag a window by its title bar.
2. While dragging, hold **⌃ Control** — all zones appear at low opacity on your display.
3. Drag the cursor over the zone you want (it highlights brighter).
4. Release the mouse — the window snaps to that zone.

**Keyboard shortcuts**

| Shortcut | Action |
|----------|--------|
| ⌃ ← → ↑ ↓ | Snap focused window to adjacent zone |
| ⌃ 1–9 | Snap focused window to zone by number |
| ⌃ ⇧ ← → | Move window to previous/next monitor |

Shortcuts can be remapped under **Settings… → Shortcuts**.

### 6. Customize (optional)

- **Edit Zones…** — draw, resize, rename, and delete zones on a visual canvas.
- **Settings…** — change the drag activation delay, remap shortcuts, or manage remembered app positions.

Layouts are saved to `~/Library/Application Support/Zones/layouts.json`. GhettoZones remembers which zone each app was last snapped to and restores it on relaunch.

### Troubleshooting

| Problem | Fix |
|---------|-----|
| Snapping does nothing | Check **Accessibility** is enabled for GhettoZones |
| No zone highlight while dragging | Hold **⌃ Control** while dragging; confirm **Snapping Enabled** is on |
| `xcodebuild` fails | Install full **Xcode** from the App Store (Command Line Tools alone are not enough) |
| App not in menu bar | Look for the grid icon near the clock; the app has no Dock icon by design |

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ (for building)
- Accessibility permission (required for window snapping)

## Building

See [Getting Started](#getting-started) for full setup instructions. Quick reference:

### Option A: XcodeGen

```bash
brew install xcodegen
xcodegen generate
open GhettoZones.xcodeproj
```

Build and run with ⌘R in Xcode.

### Option B: Open existing project

```bash
open GhettoZones.xcodeproj
```

## Features

- **Control + drag to snap** — hold ⌃ while dragging to preview all zones and drop into one
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
