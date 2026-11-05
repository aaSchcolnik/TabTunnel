import AppKit
import SwiftUI
import TabTunnelModel

enum PopoverFocus: Hashable { case search, list }

/// One line of the tab list. Only groups, devices and tabs can be selected.
enum Row: Identifiable, Equatable {
    case section(id: String, title: String, count: Int)
    case group(TabGroup, expanded: Bool)
    case device(Device, expanded: Bool)
    case tab(id: String, tab: Tab, context: String?, indented: Bool)
    case note(id: String, text: String)

    var id: String {
        switch self {
        case .section(let id, _, _), .note(let id, _): return id
        case .group(let g, _): return "g:" + g.id
        case .device(let d, _): return "d:" + d.name
        case .tab(let id, _, _, _): return id
        }
    }

    var selectable: Bool {
        switch self {
        case .section, .note: return false
        default: return true
        }
    }
}

/// Opens a synced URL in the default browser. Only http(s) ever opens (never file:, javascript: and the like).
@MainActor
enum Opener {
    static func webURL(_ s: String) -> URL? {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return u
    }

    static func open(_ s: String, background: Bool) {
        guard let url = webURL(s) else { return }
        if background, let browser = NSWorkspace.shared.urlForApplication(toOpen: url) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

struct TabsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var favicons: FaviconStore
    @Binding var query: String
    var focus: FocusState<PopoverFocus?>.Binding
    var close: () -> Void
    /// Bumped each time the popover opens: a selection from an earlier opening is forgotten.
    var openCount: Int = 0

    @Environment(\.theme) private var theme
    @AppStorage("tabFilter") private var filter = "all"
    @State private var expandedGroups: Set<String> = []
    @State private var collapsedDevices: Set<String> = []
    @State private var selection: String?
    @State private var hovered: String?
    @AccessibilityFocusState private var axRow: String?
    /// The selection was moved with the keyboard. Only then does the selected row get the focus ring;
    /// a mouse click selects without one, as in other Mac lists.
    @State private var keyboardNav = false
    /// Gallery only: start with these groups open, this row selected or hovered.
    var initial: (expanded: Set<String>, selection: String?, hovered: String?)?

    private var snapshot: Snapshot? { model.snapshot }

    private var searchPlaceholder: String {
        let f = effectiveFilter
        if f == "groups" { return "Search Tab Groups" }
        if f.hasPrefix("device:") { return "Search \(f.dropFirst("device:".count))" }
        return "Search all tabs"
    }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if let snap = snapshot, !snap.devices.isEmpty || !snap.tabGroups.isEmpty {
                searchField
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                FilterChips(snapshot: snap, filter: effectiveFilterBinding, searching: searching)
                    .padding(.bottom, 8)
                Divider()
            }
            content
        }
        .onAppear {
            if let initial {
                expandedGroups = initial.expanded
                selection = initial.selection
                keyboardNav = initial.selection != nil
                hovered = initial.hovered
            }
        }
        .onChange(of: query) { _, _ in if focus.wrappedValue != .list { selection = nil } }
        .onChange(of: openCount) { _, _ in
            selection = nil
            keyboardNav = false
        }
        .onChange(of: filter) { _, _ in selection = nil }
    }

    // MARK: search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondaryText)
                .accessibilityHidden(true)
            TextField("", text: $query)
                .textFieldStyle(.plain)
                // Drawn by hand: macOS ignores the color of a plain field's prompt, which is too faint (about 2:1).
                .overlay(alignment: .leading) {
                    if query.isEmpty {
                        Text(searchPlaceholder)
                            .font(.system(size: theme.title))
                            .foregroundStyle(.secondaryText)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .font(.system(size: theme.title))
                .focused(focus, equals: .search)
                .accessibilityLabel(searchPlaceholder)
                .onSubmit { openFirstMatch() }
                .onKeyPress(.downArrow) {
                    keyboardNav = true
                    // Continue from a row the user clicked; otherwise start at the top.
                    moveSelection(0, fromTop: selection == nil)
                    focus.wrappedValue = .list
                    return .handled
                }
                .onKeyPress(.escape) {
                    if query.isEmpty { return .ignored }
                    query = ""
                    return .handled
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    focus.wrappedValue = .search
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondaryText).padding(2)
                }
                .buttonStyle(QuietButtonStyle(shape: AnyShape(Circle())))
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: theme.large ? 34 : 30)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Color.primary.opacity(theme.fill)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(theme.boundary, lineWidth: 1))
        // Focus ring outside the border, like every other control, so it never reads as a thicker border.
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius + 3)
                .stroke(Color.focusRing, lineWidth: theme.focusRing)
                .padding(-2.5)
                .opacity(focus.wrappedValue == .search ? 1 : 0)
        )
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        if let snap = snapshot {
            let rows = buildRows(snap)
            if rows.isEmpty {
                EmptyState(symbol: searching ? "magnifyingglass" : "rectangle.stack",
                           title: searching ? "No tabs match “\(query)”" : "No tabs to show",
                           detail: searching ? (effectiveFilter == "all"
                                                ? "Search looks at the titles and addresses of every tab, in every group and device."
                                                : "Search looks only at what’s selected below the search field. Choose All to search every tab.")
                               : "Open tabs in Safari on your iPhone, iPad or Mac, or add them to a Tab Group, and they’ll show up here.",
                           action: searching ? ("Clear Search", { query = ""; focus.wrappedValue = .search }) : nil)
            } else {
                list(rows)
            }
        } else if let issue = model.issues.first(where: { $0.severity == .problem }) {
            ScrollView {
                // The only thing on screen: Return runs its fix.
                IssueCard(issue: issue, model: model, isDefault: true)
                    .padding(Theme.gutter)
            }
        } else {
            EmptyState(symbol: nil, title: "Getting your tabs…",
                       detail: "Usually a few seconds. Tabs from your other devices arrive while Safari is open on this Mac.",
                       action: nil)
        }
    }

    private func list(_ rows: [Row]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                            .id(row.id)
                            .accessibilityFocused($axRow, equals: row.id)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
            .focusable()
            .focused(focus, equals: .list)
            .focusEffectDisabled()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(searching ? "Search results" : "Tabs")
            .onKeyPress(keys: [.upArrow, .downArrow, .return, .leftArrow, .rightArrow, .space, .escape, .home, .end]) { press in
                handleKey(press, rows: rows, proxy: proxy)
            }
            .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters), phases: .down) { press in
                guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
                // Typing in the list goes to the search field, with the caret after what was typed
                // (focusing a field selects its text, which the next key would replace).
                query += press.characters
                focusSearchAtEnd()
                return .handled
            }
            .onChange(of: focus.wrappedValue) { _, f in
                // Keyboard focus in the list always shows on a row.
                // Only a key (Tab, ↓) shows the focus ring. Focus can also land on the list without one (a click, the
                // window picking its first key view, a page switch); then nothing is highlighted.
                guard f == .list, NSApp.currentEvent?.type == .keyDown else { return }
                keyboardNav = true
                if selection == nil || !rows.contains(where: { $0.id == selection }) {
                    selection = rows.first(where: \.selectable)?.id
                } else if let id = selection {
                    // Kept selection (a row clicked earlier in this opening): bring it into view and move VoiceOver
                    // there, since `selection` didn't change and its onChange won't run.
                    proxy.scrollTo(id)
                    axRow = id
                }
            }
            .onChange(of: selection) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
                // VoiceOver follows the keyboard selection.
                if focus.wrappedValue == .list { axRow = id }
            }
        }
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        let selected = selection == row.id && focus.wrappedValue == .list && keyboardNav
        switch row {
        case .section(_, let title, let count):
            SectionHeader(title: title, count: count)
        case .note(_, let text):
            Text(text)
                .font(.system(size: theme.secondary))
                .foregroundStyle(.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        case .group(let g, let expanded):
            DisclosureRow(symbol: GroupIcon.symbol(for: g.title), title: g.title, subtitle: nil, count: g.tabs.count,
                          expanded: expanded, kind: "Tab group", selected: selected, hovered: hovered == row.id)
                .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
                .onTapGesture { keyboardNav = false; selection = row.id; toggle(row) }
                .accessibilityAction { toggle(row) }
                .contextMenu {
                    Button(expanded ? "Collapse" : "Expand") { toggle(row) }
                    Button("Open All \(g.tabs.count) Tabs") { openAll(g.tabs) }
                }
        case .device(let d, let expanded):
            DisclosureRow(symbol: d.kind.symbol, title: d.name,
                          subtitle: d.lastModified.map { "active " + RelativeTime.string(ISO.date($0)) },
                          count: d.tabs.count, expanded: expanded, kind: "Device", selected: selected, hovered: hovered == row.id)
                .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
                .onTapGesture { keyboardNav = false; selection = row.id; toggle(row) }
                .accessibilityAction { toggle(row) }
                .contextMenu {
                    Button(expanded ? "Collapse" : "Expand") { toggle(row) }
                    Button("Open All \(d.tabs.count) Tabs") { openAll(d.tabs) }
                }
        case .tab(_, let tab, let context, let indented):
            TabRow(tab: tab, context: context, indented: indented, selected: selected, hovered: hovered == row.id,
                   image: favicons.image(for: tab.url), highlight: searching ? query : "")
                .onAppear { favicons.request(tab.url) }
                .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
                .onTapGesture {
                    keyboardNav = false
                    selection = row.id
                    open(tab, background: NSEvent.modifierFlags.contains(.command))
                }
                .accessibilityAction { open(tab, background: false) }
                .accessibilityAction(named: "Open in Background") { open(tab, background: true) }
                .accessibilityAction(named: "Copy Link") { copy(tab.url) }
                .contextMenu {
                    Button("Open") { open(tab, background: false) }
                    Button("Open in Background") { open(tab, background: true) }
                    Divider()
                    Button("Copy Link") { copy(tab.url) }
                }
        }
    }

    // MARK: rows

    /// "all", "groups" or "device:<name>"; falls back to "all" when that device is gone.
    private var effectiveFilter: String {
        guard let snap = snapshot else { return "all" }
        if filter == "groups", !snap.tabGroups.isEmpty { return filter }
        if filter.hasPrefix("device:"), snap.devices.contains(where: { "device:" + $0.name == filter }) { return filter }
        return "all"
    }

    private var effectiveFilterBinding: Binding<String> {
        Binding(get: { effectiveFilter }, set: { filter = $0 })
    }

    func buildRows(_ snap: Snapshot) -> [Row] {
        var rows: [Row] = []
        let f = effectiveFilter
        if searching {
            // Search looks within what the chips show: everything, the Tab Groups, or one device.
            let terms = query.lowercased().split(separator: " ").map(String.init)
            func hit(_ t: Tab) -> Bool {
                let hay = (t.title + " " + t.url).lowercased()
                return terms.allSatisfy { hay.contains($0) }
            }
            var results: [Row] = []
            if f == "all" || f == "groups" {
                for g in snap.tabGroups {
                    for (i, t) in g.tabs.enumerated() where hit(t) {
                        results.append(.tab(id: "s:g:\(g.id):\(i)", tab: t, context: "In \(g.title)", indented: false))
                    }
                }
            }
            for d in snap.devices where f == "all" || f == "device:" + d.name {
                for (i, t) in d.tabs.enumerated() where hit(t) {
                    results.append(.tab(id: "s:d:\(d.name):\(i)", tab: t, context: "On \(d.name)", indented: false))
                }
            }
            guard !results.isEmpty else { return [] }
            let scope = f == "all" ? "" : f == "groups" ? " in Tab Groups" : " on \(f.dropFirst("device:".count))"
            rows.append(.section(id: "sec:results", title: (results.count == 1 ? "1 match" : "\(results.count) matches") + scope,
                                 count: -1))
            rows += results.prefix(300)
            return rows
        }
        if (f == "all" || f == "groups"), !snap.tabGroups.isEmpty {
            rows.append(.section(id: "sec:groups", title: "Tab Groups", count: snap.tabGroups.count))
            for g in snap.tabGroups {
                let open = expandedGroups.contains(g.id)
                rows.append(.group(g, expanded: open))
                if open {
                    for (i, t) in g.tabs.enumerated() {
                        rows.append(.tab(id: "t:g:\(g.id):\(i)", tab: t, context: nil, indented: true))
                    }
                }
            }
        }
        let devices = snap.devices.filter { f == "all" || f == "device:" + $0.name }
        if f != "groups", !devices.isEmpty {
            // With one device chosen in the filter, its count would only repeat the chip.
            rows.append(.section(id: "sec:devices", title: "Open on Your Devices", count: f == "all" ? devices.count : -1))
            for d in devices {
                let open = !collapsedDevices.contains(d.name)
                rows.append(.device(d, expanded: open))
                if open {
                    for (i, t) in d.tabs.enumerated() {
                        rows.append(.tab(id: "t:d:\(d.name):\(i)", tab: t, context: nil, indented: true))
                    }
                }
            }
        }
        if f == "groups", snap.tabGroups.isEmpty { return [] }
        return rows
    }

    // MARK: actions

    private func toggle(_ row: Row) {
        switch row {
        case .group(let g, let expanded):
            if expanded { expandedGroups.remove(g.id) } else { expandedGroups.insert(g.id) }
        case .device(let d, let expanded):
            if expanded { collapsedDevices.insert(d.name) } else { collapsedDevices.remove(d.name) }
        default: break
        }
    }

    private func open(_ tab: Tab, background: Bool) {
        Opener.open(tab.url, background: background)
        if !background { close() }
    }

    private func openAll(_ tabs: [Tab]) {
        for t in tabs.prefix(100) { Opener.open(t.url, background: true) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func openFirstMatch() {
        guard let snap = snapshot else { return }
        let rows = buildRows(snap)
        if let id = selection, case .tab(_, let t, _, _)? = rows.first(where: { $0.id == id }) { return open(t, background: false) }
        if case .tab(_, let t, _, _)? = rows.first(where: { if case .tab = $0 { return true } else { return false } }) {
            open(t, background: false)
        }
    }

    /// Focuses the search field with the caret after the text. (Focusing a field selects all of it, so the next
    /// key would replace the query.)
    private func focusSearchAtEnd() {
        focus.wrappedValue = .search
        DispatchQueue.main.async {
            (NSApp.keyWindow?.firstResponder as? NSTextView)?
                .setSelectedRange(NSRange(location: (query as NSString).length, length: 0))
        }
    }

    private func moveSelection(_ delta: Int, fromTop: Bool = false) {
        guard let snap = snapshot else { return }
        let ids = buildRows(snap).filter(\.selectable).map(\.id)
        guard !ids.isEmpty else { return }
        if fromTop || selection == nil || !ids.contains(selection!) {
            selection = delta >= 0 ? ids.first : ids.last
            return
        }
        let i = ids.firstIndex(of: selection!)!
        selection = ids[max(0, min(ids.count - 1, i + delta))]
    }

    private func handleKey(_ press: KeyPress, rows: [Row], proxy: ScrollViewProxy) -> KeyPress.Result {
        keyboardNav = true
        let current = rows.first { $0.id == selection }
        switch press.key {
        case .downArrow:
            moveSelection(1)
        case .upArrow:
            let ids = rows.filter(\.selectable).map(\.id)
            if selection == ids.first || selection == nil {
                focusSearchAtEnd() // up from the first row goes back to search, keeping the query intact
                return .handled
            }
            moveSelection(-1)
        case .home:
            selection = rows.first(where: \.selectable)?.id
        case .end:
            selection = rows.last(where: \.selectable)?.id
        case .return:
            guard let current else { return .ignored }
            if case .tab(_, let t, _, _) = current {
                open(t, background: press.modifiers.contains(.command))
            } else {
                toggle(current)
            }
        case .space:
            guard let current else { return .ignored }
            if case .tab(_, let t, _, _) = current { open(t, background: true) } else { toggle(current) }
        case .rightArrow:
            switch current {
            case .group(_, false)?, .device(_, false)?: toggle(current!)
            default: return .ignored
            }
        case .leftArrow:
            switch current {
            case .group(_, true)?, .device(_, true)?: toggle(current!)
            case .tab(let id, _, _, true)?:
                // Move to the tab’s group or device.
                if let idx = rows.firstIndex(where: { $0.id == id }),
                   let parent = rows[..<idx].last(where: { if case .group = $0 { return true }; if case .device = $0 { return true }; return false }) {
                    selection = parent.id
                }
            default: return .ignored
            }
        case .escape:
            if !query.isEmpty {
                query = ""
                focusSearchAtEnd()
            } else {
                close()
            }
        default:
            return .ignored
        }
        return .handled
    }
}

// MARK: - pieces

struct SectionHeader: View {
    var title: String
    var count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: theme.section, weight: .semibold))
                .foregroundStyle(.secondaryText)
            if count >= 0 {
                Text("\(count)")
                    .font(.system(size: theme.section, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Row background: hover is a faint wash; keyboard focus adds the accent ring so it’s never confused with hover.
struct RowBackground: View {
    var selected: Bool
    var hovered: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.radius)
            .fill(selected ? Color.accentColor.opacity(0.16) : hovered ? Color.primary.opacity(theme.wash) : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(Color.focusRing, lineWidth: selected ? theme.focusRing : 0)
            )
    }
}

struct DisclosureRow: View {
    var symbol: String
    var title: String
    var subtitle: String?
    var count: Int
    var expanded: Bool
    var kind: String
    var selected: Bool
    var hovered: Bool
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondaryText)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: expanded)
                .frame(width: 12)
            Image(systemName: symbol)
                .font(.system(size: theme.icon - 2))
                .foregroundStyle(Color.accentColor)
                .frame(width: theme.icon + 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: theme.title, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: theme.secondary))
                        .foregroundStyle(.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.system(size: theme.secondary, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(theme.fill + 0.02)))
        }
        .padding(.horizontal, 8)
        .frame(minHeight: subtitle == nil ? theme.headerRowHeight : theme.rowHeight)
        .background(RowBackground(selected: selected, hovered: hovered))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(kind.lowercased())\(subtitle.map { ", " + $0 } ?? ""), \(count) \(count == 1 ? "tab" : "tabs")")
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(expanded ? "Collapses the list" : "Shows its tabs")
    }
}

struct TabRow: View {
    /// `text` with every occurrence of each search term in bold, so it's clear why a result matched.
    static func bolded(_ text: String, _ query: String) -> AttributedString {
        var out = AttributedString(text)
        // One-letter terms would bold half the text; only terms of two or more letters are highlighted.
        let terms = query.lowercased().split(separator: " ").map(String.init).filter { $0.count >= 2 }
        guard !terms.isEmpty else { return out }
        let lower = text.lowercased()
        guard lower.count == text.count else { return out } // case mapping changed length: skip highlighting
        for term in terms {
            var start = lower.startIndex
            while let r = lower.range(of: term, range: start..<lower.endIndex) {
                let a = lower.distance(from: lower.startIndex, to: r.lowerBound)
                let lo = out.index(out.startIndex, offsetByCharacters: a)
                let hi = out.index(lo, offsetByCharacters: term.count)
                out[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
                start = r.upperBound
            }
        }
        return out
    }

    var tab: Tab
    var context: String?
    var indented: Bool
    var selected: Bool
    var hovered: Bool
    var image: NSImage?
    /// Search terms to show in bold in the title and address.
    var highlight: String = ""
    @Environment(\.theme) private var theme

    var host: String {
        guard let h = URL(string: tab.url)?.host else { return tab.url }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    var body: some View {
        HStack(spacing: 9) {
            Favicon(image: image, host: host, size: theme.icon)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if tab.pinned == true {
                        Image(systemName: "pin.fill")
                            .font(.system(size: theme.secondary - 2))
                            .foregroundStyle(.secondaryText)
                            .accessibilityHidden(true)
                    }
                    Text(Self.bolded(tab.title, highlight))
                        .font(.system(size: theme.title))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(Self.bolded(context.map { "\(host) · \($0)" } ?? host, highlight))
                    .font(.system(size: theme.secondary))
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if hovered || selected {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: theme.secondary, weight: .semibold))
                    .foregroundStyle(.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, indented ? 30 : 8)
        .padding(.trailing, 8)
        .frame(minHeight: theme.rowHeight)
        .background(RowBackground(selected: selected, hovered: hovered))
        .contentShape(Rectangle())
        .help(tab.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityValue([host, context, tab.pinned == true ? "pinned" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isLink)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Opens in your default browser")
    }
}

/// A site’s icon, or its first letter on a tinted tile. Icons sit on a faint tile so dark icons stay visible
/// in Dark Mode.
struct Favicon: View {
    var image: NSImage?
    var host: String
    var size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.9)))
            } else {
                Text(String(host.first ?? "•").uppercased())
                    .font(.system(size: max(12, size * 0.66), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: max(size + 4, 20), height: max(size + 4, 20))
                    .background(RoundedRectangle(cornerRadius: 4).fill(Self.color(for: host)))
            }
        }
        .accessibilityHidden(true)
    }

    /// A stable, mid-dark color per site, dark enough for white text (contrast >= 4.5:1).
    static func color(for host: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.16, green: 0.38, blue: 0.75), Color(red: 0.55, green: 0.24, blue: 0.66),
            Color(red: 0.70, green: 0.20, blue: 0.30), Color(red: 0.10, green: 0.45, blue: 0.40),
            Color(red: 0.62, green: 0.32, blue: 0.08), Color(red: 0.30, green: 0.34, blue: 0.40),
        ]
        var h: UInt32 = 0
        for u in host.unicodeScalars { h = h &* 31 &+ u.value }
        return palette[Int(h % UInt32(palette.count))]
    }
}

/// Lays children out left to right and wraps to a new line when the next one doesn't fit. A child wider than the
/// row is offered the row's width (so its text truncates); that one size is used for rows, placement and spacing.
struct WrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for (i, size) in zip(row.items, row.sizes) {
                // Whole-point positions keep the 1 pt chip borders crisp.
                subviews[i].place(at: CGPoint(x: x.rounded(), y: (y + (row.height - size.height) / 2).rounded()),
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var sizes: [CGSize] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    /// The size a child gets: its natural size, or the row's width if it's wider (then measured at that width).
    private func size(of view: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let natural = view.sizeThatFits(.unspecified)
        guard natural.width > maxWidth else { return natural }
        return view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = size(of: subviews[i], maxWidth: width)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + s.width > width {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + s.width
            r.height = max(r.height, s.height)
            r.items.append(i)
            r.sizes.append(s)
            rows[rows.count - 1] = r
        }
        return rows
    }
}

struct FilterChips: View {
    var snapshot: Snapshot
    @Binding var filter: String
    var searching: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        // Chips wrap onto more lines instead of scrolling sideways, so none is ever cut off (Large text, many devices).
        WrapLayout(spacing: 6, lineSpacing: 6) {
            chip("All", value: "all", symbol: nil)
            if !snapshot.tabGroups.isEmpty { chip("Groups", value: "groups", symbol: "square.stack") }
            ForEach(snapshot.devices, id: \.name) { d in
                chip(d.name, value: "device:" + d.name, symbol: d.kind.symbol)
            }
        }
        .padding(.vertical, 3) // room for the focus ring outside each chip
        .padding(.horizontal, Theme.gutter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show tabs from")
    }

    private func chip(_ title: String, value: String, symbol: String?) -> some View {
        let on = filter == value
        return Button {
            filter = value
        } label: {
            HStack(spacing: 4) {
                // The selected chip shows a checkmark in place of its icon (a shape cue, not only color), in a
                // fixed-width slot, so widths never change and resting chips stay centered. "All" has no icon:
                // its checkmark appears within a minimum width instead.
                if let symbol {
                    ZStack {
                        Image(systemName: symbol).font(.system(size: theme.secondary - 1)).opacity(on ? 0 : 1)
                        Image(systemName: "checkmark").font(.system(size: theme.secondary - 2, weight: .bold)).opacity(on ? 1 : 0)
                    }
                    .frame(width: theme.secondary + 4)
                    .accessibilityHidden(true)
                } else if on {
                    Image(systemName: "checkmark").font(.system(size: theme.secondary - 2, weight: .bold))
                        .accessibilityHidden(true)
                }
                // Middle truncation keeps the end of a long device name, which is often what tells two apart.
                Text(title).lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: symbol == nil ? theme.secondary * 3.6 : nil)
            // Same weight on and off, so selecting doesn’t change the chip’s width. Selection shows as the tinted
            // fill and the checkmark (the non-color cue); VoiceOver hears "selected".
            .font(.system(size: theme.secondary, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: theme.large ? 28 : 24)
            .foregroundStyle(.primary)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.28) : Color.primary.opacity(theme.fill)))
            .overlay(Capsule().strokeBorder(theme.boundary, lineWidth: 1))
        }
        .buttonStyle(QuietButtonStyle(shape: AnyShape(Capsule())))
        .help(title) // the full name, if a long one is truncated
        .id(value)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

struct EmptyState: View {
    var symbol: String?
    var title: String
    var detail: String?
    var action: (String, () -> Void)?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            VStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondaryText)
                    .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.regular)
            }
            Text(title)
                .font(.system(size: theme.title, weight: .semibold))
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: theme.secondary))
                    .foregroundStyle(.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
            .accessibilityElement(children: .combine)
            if let action {
                // Outside the combined text, so VoiceOver finds it as a button.
                Button(action.0, action: action.1).controlSize(.regular)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
