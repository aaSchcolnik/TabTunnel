import ServiceManagement
import SwiftUI
import TabTunnelModel

enum SettingsTab: String, Hashable, CaseIterable {
    case general, sharing, troubleshooting

    var title: String {
        switch self {
        case .general: return "General"
        case .sharing: return "Sharing"
        case .troubleshooting: return "Troubleshooting"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .sharing: return "network"
        case .troubleshooting: return "stethoscope"
        }
    }

    /// The pane's content, themed. Hosted in native toolbar tabs by `WindowRouter`.
    @MainActor
    func pane(_ model: AppModel) -> AnyView {
        let large = model.settings.textSize == .large
        switch self {
        case .general: return AnyView(GeneralSettings(model: model).frame(width: 540).theme(large: large))
        case .sharing: return AnyView(SharingSettings(model: model).frame(width: 540).theme(large: large))
        case .troubleshooting: return AnyView(TroubleshootingSettings(model: model).frame(width: 540).theme(large: large))
        }
    }
}

/// Explanatory text under a setting: secondary color, 12 pt minimum, wraps.
struct Caption: View {
    var text: String
    init(_ text: String) { self.text = text }
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: theme.secondary))
            .foregroundStyle(.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.settings.showTabs) {
                    Text("Show tabs in the menu bar")
                    Caption("Turn off to see only whether TabTunnel is working. Sharing with your browsers isn’t affected.")
                }
                Picker(selection: $model.settings.textSize) {
                    ForEach(Settings.TextSize.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Text size")
                }
            }
            Section {
                Toggle(isOn: Binding(get: { model.loginItem == .enabled }, set: { model.setLaunchAtLogin($0) })) {
                    Text("Open TabTunnel at login")
                    if model.loginItem == .requiresApproval {
                        Caption("macOS needs your approval: turn TabTunnel on in System Settings › General › Login Items.")
                    } else {
                        Caption("Keeps your tabs and sharing available after you restart.")
                    }
                }
                if model.loginItem == .requiresApproval {
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Section {
                Toggle(isOn: $model.settings.keepSafariOpen) {
                    Text("Keep Safari open in the background")
                    Caption("Tabs from your iPhone and iPad only reach this Mac while Safari is open. If you quit Safari, "
                            + "TabTunnel reopens it a minute later without a window.")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SharingSettings: View {
    @ObservedObject var model: AppModel
    @State private var portText = ""
    @FocusState private var portFocused: Bool
    @Environment(\.theme) private var theme // Increase Contrast strengthens the port field like other controls
    @State private var confirmToken = false
    @State private var confirmFeeds = false
    @State private var copied = false
    @State private var tokenCopied = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.settings.sharing) {
                    Text("Share tabs with browsers on your other computers")
                    Caption("The TabTunnel extension for Chromium (Helium) and Firefox (Zen) reads your tabs over Tailscale. "
                            + "Only devices on your tailnet can connect, and only with the token.")
                }
            }
            if model.settings.sharing {
                Section("Connection") {
                    LabeledContent("Address") {
                        HStack {
                            Text(addressText)
                                .textSelection(.enabled)
                                .lineLimit(2) // a long hostname wraps once before it's shortened in the middle
                                .truncationMode(.middle)
                                .help(addressText)
                                .foregroundStyle(addressReady ? Color.primary : Color.secondaryText)
                            if model.relay == .noTailscale {
                                Button("Open Tailscale") { model.perform(.openTailscale) }
                            }
                            if case .failed = model.relay {
                                Button("Check Again") { model.perform(.checkAgain) }
                            }
                            if addressReady {
                                let url = addressText // the address shown is the address copied
                                Button(stable: copied ? "Copied" : "Copy Address", reserve: "Copy Address") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url, forType: .string)
                                    copied = true
                                    announce("Address copied")
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                                }
                            }
                        }
                    }
                    if case .unreachable = model.relay {
                        // The address is right, but the self-check got no answer: say so here too, with the fix.
                        HStack {
                            // Like the status cards: only the icon carries the color; the words stay in body colors.
                            Label {
                                Text("Not answering. A firewall may be blocking it.").foregroundStyle(Color.secondaryText)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.statusOrange)
                                    .accessibilityLabel("Warning")
                            }
                            .font(.system(size: theme.secondary))
                            Spacer()
                            Button(Issue.Action.openFirewallSettings.label) { model.perform(.openFirewallSettings) }
                        }
                    }
                    if case .failed = model.relay {
                        Caption("TabTunnel couldn’t open its address for your browsers. It retries automatically; click Check Again to retry now. If it keeps failing, try another port below.")
                    }
                    if case .portInUse = model.relay {
                        Caption("Another program is using this port. Choose another one below.")
                    }
                    LabeledContent("Port") {
                        HStack {
                            TextField("Port", text: $portText)
                                .labelsHidden()
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .focused($portFocused)
                                .padding(.horizontal, 6)
                                .frame(width: 70, height: 24)
                                // Same field look as search: a >= 3:1 border, and the focus ring outside it.
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor))) // reads as editable
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.boundary, lineWidth: 1))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.focusRing, lineWidth: theme.focusRing)
                                    .padding(-3).opacity(portFocused ? 1 : 0))
                                .onSubmit(applyPort)
                                .accessibilityLabel("Port")
                                .accessibilityValue(portText)
                                .accessibilityHint("A port from 1024 to 65535")
                            Button("Apply", action: applyPort)
                                .disabled(Int(portText) == model.settings.port || !(1024...65535).contains(Int(portText) ?? 0))
                        }
                    }
                    if !portText.isEmpty, !(1024...65535).contains(Int(portText) ?? 0) {
                        Caption("Enter a port from 1024 to 65535.") // right under the Port row
                    }
                    LabeledContent("Token") {
                        HStack {
                            Button(stable: tokenCopied ? "Copied" : "Copy Token", reserve: "Copy Token") {
                                model.copyToken()
                                tokenCopied = true
                                announce("Token copied")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { tokenCopied = false }
                            }
                            Button("New Token…") { confirmToken = true }
                        }
                    }
                    Caption("Paste the address and token into the extension’s settings. The token stays on this Mac’s clipboard for 60 seconds.")
                }
                Section("Zen Live Folders") {
                    LabeledContent("Feed links") {
                        Button("Reset Feed Links…") { confirmFeeds = true }
                    }
                    Caption("Each Tab Group has its own feed link that opens nothing else. Resetting stops every existing link; copy new ones from the extension.")
                }
                Section("Site icons") {
                    Toggle(isOn: $model.settings.fetchFavicons) {
                        Text("Look up missing icons on the web")
                        Caption("Icons come from Safari’s own cache first. When it has none, TabTunnel asks the site for its icon, "
                                + "then DuckDuckGo or Google. They learn the site’s domain, never the page.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { portText = String(model.settings.port) }
        .confirmationDialog("Make a new token?", isPresented: $confirmToken) {
            Button("Make New Token", role: .destructive) { model.rotateToken() }
        } message: {
            Text("Browsers using the current token stop working until you paste the new one into their TabTunnel settings.")
        }
        .confirmationDialog("Reset all feed links?", isPresented: $confirmFeeds) {
            Button("Reset Feed Links", role: .destructive) { model.rotateFeeds() }
        } message: {
            Text("Every Zen Live Folder made from a TabTunnel feed stops updating until you give it a new link.")
        }
    }

    /// The Address row says what's actually going on, the same way the Status page does.
    private var addressText: String {
        switch model.relay {
        case .ready(let url), .unreachable(let url): return url
        case .noTailscale: return "Waiting for Tailscale…"
        case .starting: return "Starting…"
        case .portInUse(let p): return "Port \(p) is in use"
        case .failed: return "Couldn’t start"
        case .off: return "Sharing is off"
        }
    }

    private var addressReady: Bool {
        switch model.relay {
        case .ready, .unreachable: return true
        default: return false
        }
    }

    private func applyPort() {
        guard let p = Int(portText), (1024...65535).contains(p) else {
            portText = String(model.settings.port)
            return
        }
        model.settings.port = p
    }
}

struct TroubleshootingSettings: View {
    @ObservedObject var model: AppModel
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Setup") {
                    Button("Open Setup Guide") { WindowRouter.shared.showSetup() }
                }
                LabeledContent("Safari access") {
                    HStack {
                        Button("Open Full Disk Access") { model.perform(.openFullDiskAccess) }
                        Button("Show Reader") { model.perform(.revealReader) }
                    }
                }
                Caption("Only TabTunnel Reader needs Full Disk Access. It reads Safari’s tab and icon databases and has no network access.")
            }
            Section {
                LabeledContent("Diagnostics") {
                    Button(stable: copied ? "Copied" : "Copy Diagnostics", reserve: "Copy Diagnostics") {
                        model.perform(.copyDiagnostics) // announces "Diagnostics copied"
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                }
                Caption("A short report of what’s working, for a bug report: " + AppModel.diagnosticsPrivacy)
                LabeledContent("Logs") {
                    Button("Show Logs in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/TabTunnel")])
                    }
                }
            }
            Section {
                LabeledContent("Version") { Text(TabTunnelVersion.string).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
