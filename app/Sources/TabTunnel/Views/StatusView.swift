import SwiftUI
import TabTunnelModel

/// A problem with its explanation and the buttons that fix it.
struct IssueCard: View {
    var issue: Issue
    @ObservedObject var model: AppModel
    /// Only the most important card on screen gets a prominent (default-looking) button.
    var prominent = true
    /// Its first action is the window's default (Return), when the card is alone on screen.
    var isDefault = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: issue.severity.symbol)
                    .foregroundStyle(issue.severity.tint)
                    .font(.system(size: theme.title))
                    .accessibilityLabel(issue.severity.spoken)
                Text(issue.title)
                    .font(.system(size: theme.title, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(issue.detail)
                .font(.system(size: theme.secondary))
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, theme.title + 8)
            if !issue.actions.isEmpty {
                FlowButtons(actions: issue.actions, prominent: prominent, isDefault: isDefault) { model.perform($0) }
                    .padding(.leading, theme.title + 8)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(issue.severity.tint.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(issue.severity.tint.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }
}

struct FlowButtons: View {
    var actions: [Issue.Action]
    var prominent = true
    var isDefault = false
    var perform: (Issue.Action) -> Void
    @State private var copied: Issue.Action?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
            VStack(alignment: .leading, spacing: 6) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(Array(actions.enumerated()), id: \.element) { i, a in
            let title = copied == a ? "Copied" : a.label
            if i == 0 && prominent && isDefault {
                Button(stable: title, reserve: a.label) { run(a) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else if i == 0 && prominent {
                Button(stable: title, reserve: a.label) { run(a) }.buttonStyle(.borderedProminent)
            } else {
                Button(stable: title, reserve: a.label) { run(a) }.buttonStyle(.bordered)
            }
        }
    }

    private func run(_ a: Issue.Action) {
        perform(a)
        if a == .copyDiagnostics {
            copied = a
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = nil }
        }
    }
}

struct StatusView: View {
    @ObservedObject var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let notice = model.notice { NoticeCard(notice: notice, model: model) }
                let issues = model.issues
                if !issues.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(Array(issues.enumerated()), id: \.element.id) { i, issue in
                            IssueCard(issue: issue, model: model, prominent: i == 0 && model.notice == nil)
                        }
                    }
                }
                checks
                if model.settings.sharing { browsers }
                if let busy = model.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.system(size: theme.secondary))
                    }
                }
            }
            .padding(Theme.gutter)
        }
    }

    // MARK: checks

    private var checks: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "How It’s Going", count: -1).padding(.horizontal, -8)
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(checkRows.enumerated()), id: \.offset) { i, row in
                        if i > 0 { Divider().padding(.leading, 30) }
                        CheckRow(check: row)
                    }
                }
            }
        }
    }

    struct Check {
        enum State { case ok, warn, bad, off }
        var state: State
        var title: String
        var detail: String
        var copyValue: String?
        var copyLabel: String?
    }

    private var checkRows: [Check] {
        var rows: [Check] = []
        let st = model.reader?.status
        // 1. Reading Safari
        switch (model.readerLink, st?.problem) {
        case (.unavailable, _):
            rows.append(Check(state: .bad, title: "Reading Safari", detail: "TabTunnel Reader isn’t running"))
        case (.connecting, _) where model.reader == nil:
            rows.append(Check(state: .off, title: "Reading Safari", detail: "Starting…"))
        case (_, .noAccess?):
            rows.append(Check(state: .bad, title: "Reading Safari", detail: "Needs Full Disk Access"))
        case (_, .noDatabase?):
            rows.append(Check(state: .bad, title: "Reading Safari", detail: "No iCloud Tabs found on this Mac"))
        case (_, .unsupportedSchema?):
            rows.append(Check(state: .bad, title: "Reading Safari", detail: "Safari’s format changed"))
        case (_, .readFailed?):
            rows.append(Check(state: .warn, title: "Reading Safari", detail: "Last read failed; retrying"))
        default:
            let snap = model.snapshot
            let detail = snap.map { "\($0.devices.count) \($0.devices.count == 1 ? "device" : "devices"), "
                + "\($0.tabGroups.count) Tab \($0.tabGroups.count == 1 ? "Group" : "Groups")" } ?? ""
            rows.append(Check(state: st?.groupsError == nil ? .ok : .warn, title: "Reading Safari", detail: detail))
        }
        // 2. iCloud
        if let src = st?.sourceModifiedAt {
            rows.append(Check(state: .ok, title: "iCloud Tabs",
                              detail: "Safari last saved tabs \(RelativeTime.string(ISO.date(src)))"))
        }
        // 3. Safari open
        if model.safariRunning {
            rows.append(Check(state: .ok, title: "Safari", detail: model.settings.keepSafariOpen ? "Open, kept open for syncing" : "Open"))
        } else {
            rows.append(Check(state: .warn, title: "Safari",
                              detail: model.settings.keepSafariOpen && !model.safariGaveUp ? "Closed; reopening it shortly" : "Closed"))
        }
        // 4. Sharing
        switch model.relay {
        case .off:
            rows.append(Check(state: .off, title: "Sharing", detail: "Off. Tabs show only in this menu."))
        case .noTailscale:
            rows.append(Check(state: .warn, title: "Sharing", detail: "Waiting for Tailscale"))
        case .starting:
            rows.append(Check(state: .off, title: "Sharing", detail: "Starting…"))
        case .ready(let url):
            rows.append(Check(state: .ok, title: "Sharing", detail: url, copyValue: url, copyLabel: "Copy Address"))
        case .unreachable(let url):
            // Same severity as its issue card (attention): tabs still show here.
            rows.append(Check(state: .warn, title: "Sharing", detail: "\(url) isn’t answering"))
        case .portInUse(let p):
            rows.append(Check(state: .bad, title: "Sharing", detail: "Port \(p) is in use"))
        case .failed:
            rows.append(Check(state: .warn, title: "Sharing", detail: "Couldn’t start"))
        }
        return rows
    }

    // MARK: browsers

    private var browsers: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Browsers", count: -1).padding(.horizontal, -8)
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    if model.clients.isEmpty {
                        Text(browsersEmptyText)
                            .font(.system(size: theme.secondary))
                            .foregroundStyle(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 4)
                    } else {
                        ForEach(Array(model.clients.enumerated()), id: \.element.id) { i, c in
                            if i > 0 { Divider().padding(.leading, 30) }
                            ClientRow(client: c)
                        }
                    }
                    if model.relay.isReady {
                        Divider().padding(.leading, 30)
                        TokenRow(model: model)
                    }
                    if model.bytesSent > 0 {
                        Divider().padding(.leading, 30)
                        trafficRow
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Why no browser shows up yet, in the terms of the current sharing state.
    private var browsersEmptyText: String {
        switch model.relay {
        case .ready:
            return "No browser has connected since TabTunnel started. In the TabTunnel extension’s settings, enter the address above and the token."
        case .unreachable:
            return "Browsers can connect once they can reach this Mac."
        case .noTailscale:
            return "Browsers can connect once Tailscale is on."
        default:
            return "Browsers can connect once sharing is running."
        }
    }

    /// Little Snitch-style traffic: what went out, and how often a check needed no data at all.
    private var trafficRow: some View {
        let sent = ByteCountFormatter.string(fromByteCount: Int64(model.bytesSent), countStyle: .file)
        let skipped = model.notModified
        return HStack(spacing: 10) {
            Image(systemName: "arrow.up.circle")
                .foregroundStyle(.secondaryText)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sent \(sent) since TabTunnel started").font(.system(size: theme.title, weight: .medium))
                if skipped > 0 {
                    Text("\(skipped) \(skipped == 1 ? "check" : "checks") found no changes and got no data")
                        .font(.system(size: theme.secondary))
                        .foregroundStyle(.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

struct TokenRow: View {
    @ObservedObject var model: AppModel
    @Environment(\.theme) private var theme
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key")
                .foregroundStyle(.secondaryText)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Access token").font(.system(size: theme.title, weight: .medium))
                Text("Paste it into the extension’s settings")
                    .font(.system(size: theme.secondary))
                    .foregroundStyle(.secondaryText)
            }
            Spacer(minLength: 4)
            Button(stable: copied ? "Copied" : "Copy Token", reserve: "Copy Token") {
                model.copyToken()
                copied = true
                announce("Token copied")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .help("Copies the token. It stays on this Mac’s clipboard for 60 seconds.")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
    }
}

extension RelayService.Status {
    var isReady: Bool { if case .ready = self { return true } else { return false } }
}

struct CheckRow: View {
    var check: StatusView.Check
    @Environment(\.theme) private var theme
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            symbol.frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(check.title).font(.system(size: theme.title, weight: .medium))
                    Spacer(minLength: 4)
                    if let value = check.copyValue {
                        Button(stable: copied ? "Copied" : (check.copyLabel ?? "Copy"), reserve: check.copyLabel ?? "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(value, forType: .string)
                            copied = true
                            announce("Copied")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }
                    }
                }
                // Addresses get the full width so they don't break mid-name.
                Text(check.detail)
                    .font(.system(size: theme.secondary))
                    .foregroundStyle(.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        // .contain, not .combine: VoiceOver reads the row and still finds Copy Address as its own button.
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var symbol: some View {
        switch check.state {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.statusGreen).accessibilityLabel("OK")
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusOrange).accessibilityLabel("Warning")
        case .bad: Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.statusRed).accessibilityLabel("Problem")
        case .off: Image(systemName: "minus.circle").foregroundStyle(.secondaryText).accessibilityLabel("Off")
        }
    }
}

struct ClientRow: View {
    var client: RelayClient
    @Environment(\.theme) private var theme

    var body: some View {
        let recent = Date().timeIntervalSince(client.lastSeen) < 600
        HStack(spacing: 10) {
            Image(systemName: client.kind.contains("Zen") ? "folder.badge.gearshape" : "puzzlepiece.extension")
                .foregroundStyle(.secondaryText)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(client.name.map { "\(client.kind) on \($0)" } ?? client.kind)
                    .font(.system(size: theme.title, weight: .medium))
                    .lineLimit(1)
                Text("\(recent ? "Active" : "Idle") · last checked \(RelativeTime.string(client.lastSeen)) · "
                     + "\(client.requests) \(client.requests == 1 ? "check" : "checks")")
                    .font(.system(size: theme.secondary))
                    .foregroundStyle(.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A one-off message after an action, with its follow-up and a Dismiss button.
struct NoticeCard: View {
    var notice: AppModel.Notice
    @ObservedObject var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(notice.isError ? Color.statusOrange : Color.statusGreen)
                    .accessibilityLabel(notice.isError ? "Warning" : "Done")
                Text(notice.title).font(.system(size: theme.title, weight: .semibold))
            }
            Text(notice.detail)
                .font(.system(size: theme.secondary))
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, theme.title + 8)
            HStack(spacing: 8) {
                if let action = notice.action {
                    Button(action.label) { model.perform(action) }.buttonStyle(.borderedProminent)
                }
                Button("Dismiss") { model.notice = nil }
            }
            .padding(.leading, theme.title + 8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(theme.fill)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(theme.hairline * 0.6)))
        .accessibilityElement(children: .contain)
    }
}
