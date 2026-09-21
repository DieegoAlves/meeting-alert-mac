# Meeting Alert — Scaffold

Native macOS menu-bar app (AppKit + SwiftUI-in-`NSHostingController`), macOS 14+, **zero external dependencies**. `ARCHITECTURE.md` is the binding contract; `Sources/Core` is the frozen shared source of truth.

## Build

```sh
swift build          # debug
swift build -c release
swift run MeetingAlert   # launches; installs a placeholder ⏰ menu-bar item
```

> **Expected linker warnings under Command Line Tools (F-003, cosmetic).** When the active
> developer dir is the Command Line Tools (`xcode-select -p` → `/Library/Developer/CommandLineTools`),
> `swift build` emits ~9 `ld: warning: search path '.../CommandLineTools/Developer/...' not found`
> — one per target/product. They are **environmental and harmless**: `Build complete!`, exit 0,
> zero compiler warnings, no bytes added to the binary. That layout simply lacks the
> `Developer/Library/Frameworks` and `Developer/usr/lib` dirs the default `ld` search list expects
> (they exist only under a full `Xcode.app`). To silence them, install Xcode and
> `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. Do **not** hard-code `-L`
> paths in `Package.swift` — that's per-machine and worse than the cosmetic warning.

## Module / ownership map

Each folder under `Sources/` is one SPM target owned by exactly one builder. `Core` is frozen (owned by nobody after scaffold).

| Module    | Folder              | Owned file(s) created           | Conforms to (Core)         |
|-----------|---------------------|---------------------------------|----------------------------|
| Core      | `Sources/Core`      | *(all contract types — frozen)* | —                          |
| Auth      | `Sources/Auth`      | `GoogleAuth.swift`              | `AuthProviding`            |
| Sync      | `Sources/Sync`      | `CalendarSyncService.swift`    | *(uses `AuthProviding`+`EventStore`)* |
| AlertUI   | `Sources/AlertUI`   | `AlertPresenter.swift`         | `AlertPresenting`          |
| MenuBar   | `Sources/MenuBar`   | `MenuBarController.swift`       | *(reads `EventStore`+`AlertScheduling`)* |
| Scheduler | `Sources/Scheduler` | `AlertScheduler.swift`         | `AlertScheduling`          |
| Prefs     | `Sources/Prefs`     | `PreferencesStore.swift`       | *(owns `Preferences` I/O)* |
| App       | `Sources/App`       | `MeetingAlertApp.swift`, `AppDelegate.swift` | composition root |

Builders add the remaining files listed in each stub's header **inside their own folder** — no two modules edit the same file.

## Producing a real `.app`

SPM cannot emit a full `.app` bundle on its own. After `swift build`, wrap the produced
executable (`.build/<config>/MeetingAlert`) into a bundle using the repo-root `Info.plist`
(`LSUIElement = true` → no Dock icon) and `MeetingAlert.entitlements`:

```sh
APP="MeetingAlert.app/Contents"
mkdir -p "$APP/MacOS"
cp .build/release/MeetingAlert "$APP/MacOS/MeetingAlert"
cp Info.plist "$APP/Info.plist"
codesign --force --options runtime \
  --identifier com.disco-tec.MeetingAlert \
  --entitlements MeetingAlert.entitlements \
  --sign - MeetingAlert.app     # replace "-" with a Developer ID for distribution
```

(A later step can move this into an Xcode project or an SPM build-plugin bundler.)
