# Port Inspector

A macOS menu bar app that shows listening ports and active network connections with full process details — the equivalent of running `lsof -nP -iTCP -iUDP` from your terminal, without leaving your desktop.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift 5](https://img.shields.io/badge/Swift-5-orange)

## Features

- **Live port list** in a click-to-open popover — no terminal required
- **Filter** between Listening, Active, and All connections
- **Per-row details**: protocol, port, state (color-coded), process name, PID, user, elapsed time, executable path
- **Auto-refresh** every 5 seconds
- Runs quietly in the menu bar with no Dock icon

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ (to build from source)

## Building

### Quick build (ad-hoc signed, runs on your Mac only)

```bash
./build.sh
```

Output: `dist/PortInspector.app` and `dist/PortInspector-1.0.dmg`

### Clean build

```bash
./build.sh --clean
```

### Distribute to other Macs

Requires an Apple Developer account with a Developer ID certificate.

```bash
# Sign only
./build.sh --identity "Developer ID Application: Your Name (TEAMID)"

# Sign + notarize (passes Gatekeeper on any Mac)
./build.sh \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --notarize \
  --profile  "notarytool-profile"
```

Set up the notarytool keychain profile once with:

```bash
xcrun notarytool store-credentials "notarytool-profile" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

### Open in Xcode

```bash
open PortInspector.xcodeproj
```

## Project layout

```
PortInspector/
├── PortInspectorApp.swift    — @main entry point, MenuBarExtra
├── PortEntry.swift           — data model: PortEntry, PortState, ScanFilter
├── PortScanner.swift         — lsof/ps scanning, @MainActor ObservableObject
├── MenuBarView.swift         — popover UI (header, filter picker, list, footer)
├── PortRowView.swift         — expandable row with inline detail drawer
├── Info.plist                — LSUIElement=YES (no Dock icon)
└── PortInspector.entitlements
ports.sh                      — original bash prototype
build.sh                      — release build + DMG packager
```

## How it works

On each refresh, the scanner runs two commands:

1. `lsof -nP -iTCP [-sTCP:LISTEN | -sTCP:ESTABLISHED | -iUDP]` — collects port entries and PIDs
2. Two `ps` calls against the collected PID list — retrieves user, elapsed time, and executable path

Results are deduplicated (same proto + port + PID), sorted by port number, and published to the SwiftUI view.

Without `sudo`, visibility matches what `lsof` shows for your current user — typically all user-owned processes plus most system services. Run the app with elevated privileges via `sudo open` if you need complete system-wide coverage.

## Notes

- App Sandbox is **disabled** — required for `lsof` subprocess access to network socket data
- Hardened Runtime is enabled for release builds; ad-hoc debug builds relax this automatically
- Minimum deployment target: macOS 13.0 (uses `MenuBarExtra` SwiftUI API)
