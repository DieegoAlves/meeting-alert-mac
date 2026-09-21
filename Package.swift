// swift-tools-version:5.9
import PackageDescription

// Meeting Alert — native macOS menu-bar app (AppKit + SwiftUI-in-NSHostingController).
// macOS 14+, ZERO external dependencies. See ARCHITECTURE.md (the binding contract).
//
// Module map = one SPM target per folder under Sources/. `Core` is the frozen contract
// every module imports; each other module is owned by exactly one builder (hard ownership).
// `swift build` compiles the whole graph green; `MeetingAlert` is the executable product
// (binary name used by `footprint -p MeetingAlert`).
//
// Bundling into a real .app: SPM cannot emit a full .app bundle by itself. After
// `swift build`, wrap the produced binary with the repo-root Info.plist (LSUIElement=true,
// so no Dock icon) and MeetingAlert.entitlements — see README-scaffold.md.

let package = Package(
    name: "MeetingAlert",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MeetingAlert", targets: ["MeetingAlert"])
    ],
    targets: [
        // Frozen shared contract — owned by nobody after scaffold.
        .target(name: "Core", path: "Sources/Core"),

        // One module per builder — each depends only on Core (Scheduler also on Prefs).
        .target(name: "Auth",      dependencies: ["Core"],          path: "Sources/Auth"),
        .target(name: "Sync",      dependencies: ["Core"],          path: "Sources/Sync"),
        .target(name: "AlertUI",   dependencies: ["Core"],          path: "Sources/AlertUI"),
        .target(name: "MenuBar",   dependencies: ["Core"],          path: "Sources/MenuBar"),
        .target(name: "Prefs",     dependencies: ["Core"],          path: "Sources/Prefs"),
        .target(name: "Scheduler", dependencies: ["Core", "Prefs"], path: "Sources/Scheduler"),

        // Composition root: wires the concrete impls together. Owns no domain logic.
        .executableTarget(
            name: "MeetingAlert",
            dependencies: ["Core", "Auth", "Sync", "AlertUI", "MenuBar", "Scheduler", "Prefs"],
            path: "Sources/App"
        )
    ]
)
