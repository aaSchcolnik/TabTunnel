import SwiftUI

enum PopoverPage: String { case tabs, status }

/// Shared between the popover and the status item, so opening the popover can pick the right page and focus.
@MainActor
final class PopoverState: ObservableObject {
    @Published var page: PopoverPage = .tabs
    @Published var query = ""
    /// Bumped each time the popover opens, so the view can move focus to the search field.
    @Published var openCount = 0
}

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var favicons: FaviconStore
    @ObservedObject var state: PopoverState
    var close: () -> Void
    var initialTabs: (expanded: Set<String>, selection: String?, hovered: String?)? = nil
    var initialFocus: PopoverFocus? = .search
    @FocusState private var focus: PopoverFocus?

    private var theme: Theme { Theme(large: model.settings.textSize == .large) }
    private var showTabs: Bool { model.settings.showTabs }

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model, page: $state.page, showTabs: showTabs)
            Divider()
            Group {
                if showTabs && state.page == .tabs {
                    TabsView(model: model, favicons: favicons, query: $state.query, focus: $focus, close: close,
                             openCount: state.openCount, initial: initialTabs)
                } else {
                    StatusView(model: model)
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            Footer(model: model, close: close)
        }
        .frame(width: Theme.popoverWidth, height: Theme.popoverHeight)
        .theme(large: model.settings.textSize == .large)
        .onChange(of: state.openCount) { _, _ in
            if showTabs && state.page == .tabs { focus = .search }
        }
        .onAppear { if showTabs && state.page == .tabs { focus = initialFocus } }
        // Back on Tabs, focus goes to search (never silently to the list).
        .onChange(of: state.page) { _, page in if page == .tabs { focus = .search } }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .background {
            // ⌘F focuses search, ⌘1 / ⌘2 switch pages, ⌘, opens Settings.
            Group {
                Button("") { state.page = .tabs; focus = .search }.keyboardShortcut("f")
                Button("") { state.page = .tabs }.keyboardShortcut("1")
                Button("") { state.page = .status }.keyboardShortcut("2")
                Button("") { WindowRouter.shared.showSettings(tab: .general) }.keyboardShortcut(",")
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}

private struct Header: View {
    @ObservedObject var model: AppModel
    @Binding var page: PopoverPage
    var showTabs: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let health = model.health
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: health.level.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(health.level.tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(health.level.tint.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(health.headline)
                        .font(.system(size: theme.headline, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !health.detail.isEmpty {
                        Text(health.detail)
                            .font(.system(size: theme.secondary))
                            .foregroundStyle(.secondaryText)
                            .lineLimit(2)
                    }
                }
                .frame(minHeight: 36, alignment: .leading)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(health.level.spoken). \(health.headline). \(health.detail)")

            if showTabs {
                Picker("Page", selection: $page) {
                    Text("Tabs").tag(PopoverPage.tabs)
                    Text(issueCount > 0 ? "Status (\(issueCount))" : "Status")
                        .accessibilityLabel(issueCount > 0 ? "Status, \(issueCount) \(issueCount == 1 ? "issue" : "issues")" : "Status")
                        .tag(PopoverPage.status)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Page")
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var issueCount: Int { model.issues.count }
}

private struct Footer: View {
    @ObservedObject var model: AppModel
    var close: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Button {
                close()
                WindowRouter.shared.showSettings(tab: .general)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
            Button {
                model.perform(.checkAgain)
            } label: {
                Label("Check Again", systemImage: "arrow.clockwise")
            }
            .help("Re-read Safari’s tabs and re-check sharing")
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .help("Quit TabTunnel. Browsers keep their last copy of your tabs.")
        }
        .buttonStyle(FooterButtonStyle())
        .font(.system(size: theme.secondary))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// Borderless footer buttons that still show hover, press and keyboard focus.
struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FooterButton(configuration: configuration)
    }

    private struct FooterButton: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isFocused) private var focused
        @Environment(\.theme) private var theme

        var body: some View {
            configuration.label
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(configuration.isPressed ? theme.wash * 2 : hovering ? theme.wash : 0))
                )
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.focusRing, lineWidth: theme.focusRing).padding(-3).opacity(focused ? 1 : 0))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
