import Foundation
import TabTunnelModel

/// Runs launchctl (only ever with fixed arguments) and reports its exit code.
enum Launchctl {
    static var domain: String { "gui/\(getuid())" }

    @discardableResult
    static func run(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func isLoaded(_ label: String) -> Bool { run(["print", "\(domain)/\(label)"]) == 0 }

    static func bootout(_ label: String) {
        run(["bootout", "\(domain)/\(label)"])
        for _ in 0..<50 where isLoaded(label) { usleep(100_000) } // bootout returns before the job is gone
    }

    static func bootstrap(_ plist: String) -> Bool {
        for _ in 0..<5 {
            if run(["bootstrap", domain, plist]) == 0 { return true }
            usleep(500_000)
        }
        return false
    }
}

/// Installs the reader as a per-user launchd agent that launchd starts on demand when the app connects.
/// This is a classic agent plist, so macOS keeps the Full Disk Access grant on
/// TabTunnel Reader itself and never on the app, which has the network code.
enum ReaderAgent {
    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(TabTunnelIDs.readerService).plist" }
    static var readerApp: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(TabTunnelIDs.readerAppName)") }
    static var readerExecutable: URL { readerApp.appendingPathComponent("Contents/MacOS/TabTunnel Reader") }
    static var logPath: String { NSHomeDirectory() + "/Library/Logs/TabTunnel/Reader.log" }

    /// True when running from a built app bundle (not `swift run`).
    static var isBundled: Bool { FileManager.default.isExecutableFile(atPath: readerExecutable.path) }

    static func desiredPlist() -> [String: Any] {
        [
            "Label": TabTunnelIDs.readerService,
            "ProgramArguments": [readerExecutable.path],
            "MachServices": [TabTunnelIDs.readerService: true],
            "ProcessType": "Adaptive",
            "ThrottleInterval": 5,
            "StandardErrorPath": logPath,
            "StandardOutPath": logPath,
        ]
    }

    enum Result { case ok, notBundled, failed }

    /// Writes the plist (if it changed, e.g. after the app moved) and makes sure launchd has it. Blocking.
    static func ensureInstalled() -> Result {
        guard isBundled else { return .notBundled }
        try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/Library/Logs/TabTunnel",
                                                 withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let current = NSDictionary(contentsOfFile: plistPath)
        let desired = desiredPlist() as NSDictionary
        let changed = current != desired
        if changed {
            guard let data = try? PropertyListSerialization.data(fromPropertyList: desired, format: .xml, options: 0),
                  FileManager.default.createFile(atPath: plistPath + ".new", contents: data, attributes: [.posixPermissions: 0o600]),
                  rename(plistPath + ".new", plistPath) == 0 else { return .failed }
        }
        if changed || !Launchctl.isLoaded(TabTunnelIDs.readerService) {
            Launchctl.bootout(TabTunnelIDs.readerService)
            return Launchctl.bootstrap(plistPath) ? .ok : .failed
        }
        return .ok
    }

    /// Stops the reader for good (TabTunnel's "Remove helper"). Blocking.
    static func uninstall() {
        Launchctl.bootout(TabTunnelIDs.readerService)
        unlink(plistPath)
    }

    /// Restarts the reader process (launchd starts a new one on the next connection).
    static func restart() {
        Launchctl.run(["kill", "SIGTERM", "\(Launchctl.domain)/\(TabTunnelIDs.readerService)"])
    }
}
