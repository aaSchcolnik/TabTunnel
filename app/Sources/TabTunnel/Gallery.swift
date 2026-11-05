#if DEBUG
import AppKit
import ServiceManagement
import SwiftUI
import TabTunnelModel
import TabTunnelNet

/// Debug builds only: `TabTunnel --gallery <fixture.json> <out dir>` renders every UI state to PNG (2x) for
/// design review, from fixture data, without touching the reader, the network server or any settings.
@MainActor
enum Gallery {
    final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    static func run(fixture: String, out: String) {
        guard let data = FileManager.default.contents(atPath: fixture),
              var snap = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            print("can't read fixture \(fixture)")
            exit(1)
        }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        // Recent times so relative labels look like a normal day.
        snap.updatedAt = ISO.string(Date().addingTimeInterval(-180))
        snap.sourceModifiedAt = ISO.string(Date().addingTimeInterval(-180))
        for i in snap.devices.indices {
            snap.devices[i].lastModified = ISO.string(Date().addingTimeInterval(i == 0 ? -240 : -2 * 86400))
        }

        let model = AppModel(live: false)
        WindowRouter.shared.model = model
        let favicons = FaviconStore()
        favicons.model = model
        loadIcons(snap, into: favicons)

        let ok = ReaderState(status: ReaderStatus(lastRead: ISO.now(), lastChange: snap.updatedAt,
                                                  sourceModifiedAt: snap.sourceModifiedAt), snapshot: snap)
        let url = "http://studio-mac.tail1234.ts.net:8787"
        let clients = [
            RelayClient(id: "a", ip: "100.101.1.2", kind: "Chromium extension", name: "linux-box",
                        lastSeen: Date().addingTimeInterval(-70), requests: 42, bytes: 210_000, lastStatus: 304),
            RelayClient(id: "b", ip: "100.101.1.2", kind: "Zen Live Folder", name: "linux-box",
                        lastSeen: Date().addingTimeInterval(-1300), requests: 6, bytes: 18_000, lastStatus: 200),
        ]
        let firstGroup = snap.tabGroups.first?.id ?? ""
        let secondGroup = snap.tabGroups.dropFirst().first?.id ?? ""

        func healthy() {
            model.debugSet(reader: ok, link: .connected, relay: .ready(url: url), clients: clients, bytes: 228_000, notModified: 37)
            model.settings = Settings()
        }

        var shots: [(String, NSAppearance.Name, () -> Void, PopoverPage, String, (Set<String>, String?, String?)?, PopoverFocus?)] = []
        func add(_ name: String, _ appearance: NSAppearance.Name = .darkAqua, page: PopoverPage = .tabs, query: String = "",
                 tabs: (Set<String>, String?, String?)? = nil, focus: PopoverFocus? = nil, _ setup: @escaping () -> Void) {
            shots.append((name, appearance, setup, page, query, tabs, focus))
        }

        add("01-tabs-dark", focus: .search) { healthy() }
        add("02-tabs-light", .aqua, focus: .search) { healthy() }
        add("03-groups-expanded", tabs: ([firstGroup, secondGroup], nil, nil)) { healthy() }
        add("04-search", query: "github", focus: .search) { healthy() }
        add("05-keyboard-focus", tabs: ([firstGroup], "t:g:\(firstGroup):1", nil), focus: .list) { healthy() }
        add("06-row-hover", tabs: ([firstGroup], nil, "t:g:\(firstGroup):2"), focus: .search) { healthy() }
        add("07-no-match", query: "zzzz nothing") { healthy() }
        add("08-filter-device") {
            healthy()
            UserDefaults.standard.set("device:" + (snap.devices.first?.name ?? ""), forKey: "tabFilter")
        }
        add("09-status-ok", page: .status) {
            healthy()
            UserDefaults.standard.set("all", forKey: "tabFilter")
        }
        add("10-status-ok-light", .aqua, page: .status) { healthy() }
        add("11-attention-tailscale-safari", page: .status) {
            model.debugSet(reader: ok, link: .connected, relay: .noTailscale, safariRunning: false)
            model.settings.keepSafariOpen = false
        }
        add("12-attention-header-on-tabs") {
            model.debugSet(reader: ok, link: .connected, relay: .noTailscale, safariRunning: true)
            model.settings = Settings()
        }
        add("13-no-access-tabs") {
            model.debugSet(reader: ReaderState(status: ReaderStatus(problem: .noAccess), snapshot: nil), link: .connected, relay: .ready(url: url))
        }
        add("14-no-access-status", page: .status) {
            model.debugSet(reader: ReaderState(status: ReaderStatus(problem: .noAccess), snapshot: nil), link: .connected, relay: .ready(url: url))
        }
        add("15-schema-changed", page: .status) {
            var st = ReaderStatus(problem: .unsupportedSchema, detail: "tables: cloud_tabs_v2")
            st.sourceModifiedAt = snap.sourceModifiedAt
            model.debugSet(reader: ReaderState(status: st, snapshot: snap), link: .connected, relay: .ready(url: url), clients: clients)
        }
        add("16-port-in-use", page: .status) {
            model.debugSet(reader: ok, link: .connected, relay: .portInUse(8787))
        }
        add("17-reader-down", page: .status) {
            model.debugSet(reader: nil, link: .unavailable("TabTunnel Reader isn't running."), relay: .ready(url: url))
        }
        add("18-starting") {
            model.debugSet(reader: nil, link: .connecting, relay: .starting)
        }
        add("19-status-only-mode", page: .status) {
            healthy()
            model.settings.showTabs = false
        }
        add("20-large-text", tabs: ([firstGroup], nil, nil)) {
            healthy()
            model.settings.textSize = .large
        }
        add("22-attention-light", .aqua, page: .status) {
            model.debugSet(reader: ok, link: .connected, relay: .noTailscale, safariRunning: false)
            model.settings.keepSafariOpen = false
        }
        add("23-no-access-light", .aqua) {
            model.debugSet(reader: ReaderState(status: ReaderStatus(problem: .noAccess), snapshot: nil), link: .connected, relay: .ready(url: url))
        }
        add("24-search-in-filter", query: "s", focus: .search) {
            healthy()
            UserDefaults.standard.set("groups", forKey: "tabFilter")
        }
        add("25-firewall-blocked", page: .status) {
            model.debugSet(reader: ok, link: .connected, relay: .unreachable(url: url))
            UserDefaults.standard.set("all", forKey: "tabFilter")
        }
        var longSnap = snap
        if !longSnap.devices.isEmpty {
            longSnap.devices[0].name = "Alex’s iPhone 17 Pro Max with an unusually long name that keeps going (work)"
        }
        let longState = ReaderState(status: ok.status, snapshot: longSnap)
        add("26-long-device-name") {
            model.debugSet(reader: longState, link: .connected, relay: .ready(url: url), clients: clients)
        }
        add("27-long-device-name-large") {
            model.debugSet(reader: longState, link: .connected, relay: .ready(url: url), clients: clients)
            model.settings.textSize = .large
        }
        add("21-sharing-off", page: .status) {
            model.debugSet(reader: ok, link: .connected, relay: .off)
            model.settings.sharing = false
        }

        var index = 0
        func next() {
            guard index < shots.count else {
                renderWindows(model: model, out: out)
                return
            }
            let s = shots[index]
            index += 1
            s.2()
            let state = PopoverState()
            state.page = s.3
            state.query = s.4
            let root = PopoverView(model: model, favicons: favicons, state: state, close: {},
                                   initialTabs: s.5.map { (expanded: $0.0, selection: $0.1, hovered: $0.2) },
                                   initialFocus: s.6)
                .background(Color(nsColor: .windowBackgroundColor))
            render(AnyView(root), size: NSSize(width: Theme.popoverWidth, height: Theme.popoverHeight),
                   appearance: s.1, to: "\(out)/\(s.0).png", focusNothing: s.6 == nil) {
                model.settings = Settings()
                next()
            }
        }
        next()
    }

    private static func renderWindows(model: AppModel, out: String) {
        let url = "http://studio-mac.tail1234.ts.net:8787"
        func base(_ relay: RelayService.Status) {
            model.settings.textSize = .standard
            model.debugSet(reader: nil, link: .connected, relay: relay, login: .notRegistered)
        }
        let size = NSSize(width: 540, height: 660)
        // Each job sets up its own state just before it renders.
        let longURL = "http://alexs-very-long-studio-mac-mini-hostname.tail1234ab.ts.net:8787"
        var jobs: [(String, () -> AnyView, NSSize)] = [
            ("30-settings-general", { base(.ready(url: url)); return SettingsTab.general.pane(model) }, NSSize(width: 540, height: 400)),
            ("31-settings-sharing", { base(.ready(url: url)); return SettingsTab.sharing.pane(model) }, size),
            ("31b-settings-sharing-no-tailscale", { base(.noTailscale); return SettingsTab.sharing.pane(model) }, size),
            ("31c-settings-sharing-unreachable", { base(.unreachable(url: url)); return SettingsTab.sharing.pane(model) }, size),
            ("31d-settings-sharing-port-in-use", { base(.portInUse(8787)); return SettingsTab.sharing.pane(model) }, size),
            ("31e-settings-sharing-failed", { base(.failed("bind")); return SettingsTab.sharing.pane(model) }, size),
            ("32-settings-troubleshooting", { base(.ready(url: url)); return SettingsTab.troubleshooting.pane(model) }, NSSize(width: 540, height: 470)),
            ("33-setup-guide", { base(.ready(url: url)); return AnyView(SetupView(model: model, done: {})) }, NSSize(width: 560, height: 640)),
            ("34-menu-bar-icons", { AnyView(iconStrip) }, NSSize(width: 520, height: 120)),
        ]
        // Light appearance, Large text and a long hostname together (rendered in light, see `lightJobs`).
        jobs.insert(("31f-settings-sharing-light-large-long", {
            base(.unreachable(url: longURL))
            model.settings.textSize = .large
            return SettingsTab.sharing.pane(model)
        }, NSSize(width: 540, height: 760)), at: 6)
        jobs.insert(("31g-settings-sharing-unreachable-light", {
            base(.unreachable(url: url))
            return SettingsTab.sharing.pane(model)
        }, NSSize(width: 540, height: 700)), at: 7)
        let lightJobs: Set<String> = ["31f-settings-sharing-light-large-long", "31g-settings-sharing-unreachable-light"]
        var i = 0
        func next() {
            guard i < jobs.count else {
                print("gallery written to \(out)")
                exit(0)
            }
            let j = jobs[i]
            i += 1
            render(AnyView(j.1().background(Color(nsColor: .windowBackgroundColor))), size: j.2,
                   appearance: lightJobs.contains(j.0) ? .aqua : .darkAqua,
                   to: "\(out)/\(j.0).png", focusNothing: true, then: next)
        }
        next()
    }

    /// The menu bar icon in each state, on light and dark menu bars, at 1x menu bar size (scaled up 2x).
    private static var iconStrip: some View {
        let states: [(String, String)] = [
            ("Starting", "arrow.clockwise.icloud"), ("Working", "checkmark.icloud"), ("Sending", "icloud.and.arrow.up"),
            ("Attention", "exclamationmark.icloud"), ("Not working", "icloud.slash"),
        ]
        return VStack(spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 24) {
                    ForEach(states, id: \.0) { s in
                        VStack(spacing: 4) {
                            Image(nsImage: StatusItemController.icon(s.1, description: s.0))
                                .renderingMode(.template)
                            Text(s.0).font(.system(size: 10))
                        }
                        .foregroundStyle(dark ? Color.white : Color.black)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(dark ? Color(white: 0.12) : Color(white: 0.93))
            }
        }
    }

    private static func render(_ view: AnyView, size: NSSize, appearance: NSAppearance.Name, to path: String,
                               focusNothing: Bool = false, then: @escaping () -> Void) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let w = KeyWindow(contentRect: NSRect(x: 80, y: 80, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: appearance)
        w.contentView = host
        w.alphaValue = 0.01 // drawn, but practically invisible on screen
        w.level = .floating // another app activating mid-run can't take key status away
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { if focusNothing { w.makeFirstResponder(nil) } }
        // Capture only while the window is key and the app active: otherwise macOS draws accent-colored controls
        // (prominent buttons, switches) in their inactive gray and the screenshot misrepresents the app.
        func capture(attempt: Int) {
            guard (w.isKeyWindow && NSApp.isActive) || attempt >= 4 else {
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { capture(attempt: attempt + 1) }
                return
            }
            if !(w.isKeyWindow && NSApp.isActive) { print("warning: \((path as NSString).lastPathComponent) captured while not key") }
            host.layoutSubtreeIfNeeded()
            let bounds = host.bounds
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = bounds.size
            host.cacheDisplay(in: bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            w.orderOut(nil)
            then()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { capture(attempt: 0) }
    }

    /// Real icons for the fixture's sites, fetched once and cached in the build folder (dev only).
    private static func loadIcons(_ snap: Snapshot, into store: FaviconStore) {
        let cache = "build/gallery-icons"
        try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        let urls = (snap.devices.flatMap(\.tabs) + snap.tabGroups.flatMap(\.tabs)).map(\.url)
        let fetcher = FaviconFetcher()
        let group = DispatchGroup()
        var found: [String: Data] = [:]
        let lock = NSLock()
        for url in Set(urls.map { FaviconStore.key($0) }).sorted() {
            let file = "\(cache)/\(url).png"
            if let d = FileManager.default.contents(atPath: file) {
                found[url] = d
                continue
            }
            if FileManager.default.fileExists(atPath: file + ".miss") { continue }
            group.enter()
            Task.detached {
                let d = await fetcher.icon(forPage: "https://\(url)/")
                let png = d.flatMap { ImageKind.forBrowsers($0)?.0 }
                lock.withLock { if let png { found[url] = png } }
                if let png { try? png.write(to: URL(fileURLWithPath: file)) } else { FileManager.default.createFile(atPath: file + ".miss", contents: nil) }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 25)
        // Leave a few sites without an icon so the letter fallback is reviewed too.
        for url in urls {
            let key = FaviconStore.key(url)
            if key.contains("t3.chat") || key.contains("origami") { continue }
            if let d = lock.withLock({ found[key] }), let img = NSImage(data: d) { store.debugSet(url, img) }
        }
    }
}
#endif
