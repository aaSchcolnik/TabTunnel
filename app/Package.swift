// swift-tools-version: 6.0
// TabTunnel: a menu bar app that shows your Safari tabs (iCloud Tabs + Tab Groups) and shares them with the
// TabTunnel browser extensions over Tailscale. Build the app bundle with scripts/build.sh, not `swift build`.
import PackageDescription

let package = Package(
    name: "TabTunnel",
    platforms: [.macOS(.v14)],
    targets: [
        // Plain data types, hashing and the XPC contract. No file, database or network access.
        .target(name: "TabTunnelModel"),
        // Reads Safari's databases and favicon cache. Linked only into the reader (and dev/test tools). No network code.
        .target(name: "TabTunnelSafari", dependencies: ["TabTunnelModel"], linkerSettings: [.linkedLibrary("sqlite3")]),
        // HTTP server for the extensions, favicon fetching, Tailscale detection. Never linked into the reader.
        .target(name: "TabTunnelNet", dependencies: ["TabTunnelModel"]),
        // The menu bar app: UI + server. No Full Disk Access.
        .executableTarget(name: "TabTunnel", dependencies: ["TabTunnelModel", "TabTunnelNet"]),
        // The helper that holds Full Disk Access: reads Safari, answers the app over XPC. No network code.
        .executableTarget(name: "TabTunnelReader", dependencies: ["TabTunnelModel", "TabTunnelSafari"]),
        // Development only (never bundled): serves fixture databases on 127.0.0.1 for the e2e tests.
        .executableTarget(name: "tabtunnel-dev", dependencies: ["TabTunnelModel", "TabTunnelSafari", "TabTunnelNet"]),
        .testTarget(
            name: "TabTunnelTests",
            dependencies: ["TabTunnelModel", "TabTunnelSafari", "TabTunnelNet"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
