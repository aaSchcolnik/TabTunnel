import SwiftUI
import TabTunnelModel

/// The Setup Guide: each step checks itself live, so the user sees it turn green as they go. Only the first
/// unfinished step is "current" (filled badge, prominent button); later ones are "to do" (outlined badge, plain
/// buttons), so there's one obvious next thing.
struct SetupView: View {
    @ObservedObject var model: AppModel
    var done: () -> Void
    @State private var addressCopied = false
    @State private var tokenCopied = false
    @State private var diagnosticsCopied = false

    private var theme: Theme { Theme(large: model.settings.textSize == .large) }

    enum StepState { case done, current, todo, waiting, optional }
    enum StepID: CaseIterable { case access, sync, share, login }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up TabTunnel")
                    .font(.system(size: 22, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("TabTunnel shows the Safari tabs from your iPhone, iPad and Mac in the menu bar, and shares them with "
                     + "the TabTunnel extension in your other browsers.")
                    .font(.system(size: theme.title))
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleSteps.enumerated()), id: \.element) { i, id in
                        stepView(id, number: i + 1)
                    }
                }
                .padding(.vertical, 8)
            }
            .contentMargins(.bottom, 8, for: .scrollContent) // the last step clears the footer bar
            Divider()
            HStack(spacing: 12) {
                Text(footerText)
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.system(size: theme.secondary))
                    .foregroundStyle(.secondaryText)
                Spacer()
                if allDone {
                    Button("Done") { done() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Close") { done() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(16)
            .background(.bar) // reads as a bar the steps scroll under
        }
        .frame(width: 560, height: 640)
        .theme(large: model.settings.textSize == .large)
    }

    // MARK: steps

    private var visibleSteps: [StepID] {
        StepID.allCases
    }

    /// Each step's own state, before choosing the one current step.
    private func rawState(_ id: StepID) -> StepState {
        switch id {
        case .access:
            guard model.readerLink == .connected, let st = model.reader?.status else { return .todo }
            return st.problem == .noAccess ? .todo : .done
        case .sync:
            // Not gated on access: turning on iCloud and opening Safari don't depend on it.
            // Done only when Safari is read correctly right now (cached tabs after a Safari update don't count).
            guard model.reader?.status.problem == nil, let snap = model.snapshot,
                  !snap.devices.isEmpty || !snap.tabGroups.isEmpty else { return .todo }
            return .done
        case .share:
            guard model.settings.sharing else { return .optional }
            // Done only once a browser has actually fetched tabs recently, not merely when the server is up.
            if case .ready = model.relay, !model.activeClients.isEmpty { return .done }
            return .todo
        case .login:
            return model.loginItem == .enabled ? .done : .optional
        }
    }

    private func state(_ id: StepID) -> StepState {
        let raw = rawState(id)
        guard raw == .todo else { return raw }
        let first = visibleSteps.first { rawState($0) == .todo }
        return first == id ? .current : .todo
    }

    private var outstanding: [String] {
        var out: [String] = []
        for id in visibleSteps where [.todo, .waiting].contains(rawState(id)) {
            switch id {
            case .access: out.append("allow access to Safari’s tabs")
            case .sync:
                if model.reader?.status.problem == .unsupportedSchema {
                    out.append("update TabTunnel for this version of Safari")
                } else {
                    out.append("sync tabs with iCloud")
                }
            case .share: out.append("connect a browser")
            case .login: break
            }
        }
        return out
    }

    private var allDone: Bool { outstanding.isEmpty }

    private var footerText: String {
        if allDone { return "You’re all set." }
        // The steps above already say what's left; the footer just counts, so it stays one line.
        let required = visibleSteps.filter { ![.optional].contains(rawState($0)) && $0 != .login }
        let total = required.count
        let done = max(0, total - outstanding.count)
        return "\(done) of \(total) \(total == 1 ? "step" : "steps") done. "
            + "Reopen this guide from Settings › Troubleshooting."
    }

    @ViewBuilder private func stepView(_ id: StepID, number n: Int) -> some View {
        let st = state(id)
        switch id {
        case .access:
            step(n, "Allow access to Safari’s tabs", state: st) {
                Caption("macOS protects Safari’s data, so TabTunnel Reader needs Full Disk Access. "
                        + "It reads only Safari’s tab and icon databases and can’t use the network.")
                if st != .done {
                    Caption("Click Open Full Disk Access, then drag “TabTunnel Reader” from the Finder window into the list "
                            + "(or click + and choose it), and turn it on. This step updates by itself.")
                    HStack {
                        primary("Open Full Disk Access", st) { model.perform(.openFullDiskAccess) }
                        Button("Check Again") { model.perform(.checkAgain) }
                    }
                }
            }
        case .sync:
            step(n, "Sync tabs with iCloud", state: st) {
                if let snap = model.snapshot, st == .done {
                    Caption("Found \(snap.deviceTabCount) open tabs on \(snap.devices.count) "
                            + "\(snap.devices.count == 1 ? "device" : "devices"), and \(snap.groupTabCount) tabs in "
                            + "\(snap.tabGroups.count) Tab \(snap.tabGroups.count == 1 ? "Group" : "Groups").")
                } else if model.reader?.status.problem == .unsupportedSchema {
                    Caption("A Safari update changed how it stores tabs, so this version of TabTunnel can’t read them. "
                            + "Update TabTunnel.")
                    primary(diagnosticsCopied ? "Copied" : "Copy Diagnostics", st, reserve: "Copy Diagnostics") {
                        model.perform(.copyDiagnostics) // also announces it
                        diagnosticsCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { diagnosticsCopied = false }
                    }
                    Caption("The report is for the developer: " + AppModel.diagnosticsPrivacy)
                } else {
                    Caption("On each iPhone, iPad and Mac, turn on Safari in Settings › your name › iCloud. "
                            + "Safari needs to be open on this Mac for tabs to arrive.")
                    HStack {
                        primary("Open iCloud Settings", st) { model.perform(.openICloudSettings) }
                        Button("Open Safari") { model.perform(.openSafari) }
                    }
                }
            }
        case .share:
            step(n, "Share with your other browsers", state: st) { sharingStep(st) }
        case .login:
            step(n, "Open at login", state: st) {
                Toggle("Open TabTunnel when you log in", isOn: Binding(get: { model.loginItem == .enabled },
                                                                     set: { model.setLaunchAtLogin($0) }))
            }
        }
    }

    /// The step's main button: prominent only on the current step.
    @ViewBuilder private func primary(_ title: String, _ st: StepState, reserve: String? = nil,
                                      action: @escaping () -> Void) -> some View {
        if st == .current {
            Button(stable: title, reserve: reserve ?? title, action: action).buttonStyle(.borderedProminent)
        } else {
            Button(stable: title, reserve: reserve ?? title, action: action).buttonStyle(.bordered)
        }
    }

    @ViewBuilder private func sharingStep(_ st: StepState) -> some View {
        Toggle("Share tabs over Tailscale", isOn: $model.settings.sharing)
        if model.settings.sharing {
            switch model.relay {
            case .ready(let url):
                Caption("In the TabTunnel extension’s settings, enter this address and the token.")
                Text(url).font(.system(size: theme.title).monospaced()).textSelection(.enabled)
                HStack {
                    Button(stable: addressCopied ? "Copied" : "Copy Address", reserve: "Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                        addressCopied = true
                        announce("Address copied")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { addressCopied = false }
                    }
                    Button(stable: tokenCopied ? "Copied" : "Copy Token", reserve: "Copy Token") {
                        model.copyToken()
                        tokenCopied = true
                        announce("Token copied")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { tokenCopied = false }
                    }
                }
                if let c = model.activeClients.first {
                    Label("\(c.kind)\(c.name.map { " on \($0)" } ?? "") connected \(RelativeTime.string(c.lastSeen))",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.statusGreen)
                        .font(.system(size: theme.secondary))
                }
            case .unreachable:
                Caption(AppModel.firewallHelp(port: model.settings.port))
                primary("Check Again", st) { model.perform(.checkAgain) }
            case .noTailscale:
                Caption("Open Tailscale and sign in on this Mac and on the computer with your browser.")
                primary("Open Tailscale", st) { model.perform(.openTailscale) }
            case .portInUse(let p):
                Caption("Port \(p) is in use. Choose another port in Settings › Sharing.")
            case .starting:
                Caption("Starting…")
            case .failed(let m):
                Caption("Sharing couldn’t start (\(m)).")
            case .off:
                EmptyView()
            }
        } else {
            Caption("Optional. Without sharing, your tabs still show in the menu bar.")
        }
    }

    /// A step that depends on TabTunnel reading Safari first says so (no step uses this state at the moment).
    private var waitingNote: String { "Available once TabTunnel can read Safari’s tabs" }

    private func step<Content: View>(_ n: Int, _ title: String, state: StepState, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                switch state {
                case .done:
                    Circle().fill(Color.statusGreen)
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                case .current:
                    // 14 pt bold counts as large text: white on the accent passes 3:1.
                    Circle().fill(Color.accentColor)
                    Text("\(n)").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                case .todo:
                    Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                    Text("\(n)").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.accentColor)
                case .waiting, .optional:
                    Circle().strokeBorder(Color.boundary, lineWidth: 1)
                    Text("\(n)").font(.system(size: 14, weight: .bold)).foregroundStyle(.primary)
                }
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: theme.headline, weight: .semibold))
                    if state == .optional {
                        Text("Optional").font(.system(size: theme.secondary)).foregroundStyle(.secondaryText)
                    }
                }
                if state == .waiting { Caption(waitingNote) } // its own line, so it never squeezes the title
                content().disabled(state == .waiting)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(n), \(title), " + {
            switch state {
            case .done: return "done"
            case .current: return "next"
            case .todo: return "to do"
            case .waiting: return "waiting"
            case .optional: return "optional"
            }
        }())
    }
}
