import AppKit
import TabTunnelModel
import TabTunnelNet

/// SF Symbols for Safari Tab Groups, picked from the group's name (English and Spanish keywords).
/// Same rules, in the same order, as the extension's webext/src/lib/icons.ts. First match wins.
enum GroupIcon {
    private static let rules: [(NSRegularExpression, String)] = [
        (#"sneaker|\bshoes?\b|zapat|\btenis\b|footwear|\bjordans?\b|\bnike\b"#, "shoeprints.fill"),
        (#"cloth|\bropa\b|fashion|\bmoda\b|\bsuits?\b|\btrajes?\b|outfit|shirt|camisa|\bwear\b|streetwear"#, "tshirt"),
        (#"\bcss\b|\bstyles?\b|\bestilos?\b|tailwind|stylesheet"#, "paintbrush"),
        (#"design|diseñ|\bui\b|\bux\b|figma|\bcolou?rs?\b|palette|\bbrand|\blogos?\b|\bart\b|\barte\b"#, "paintpalette"),
        (#"\binks?\b|\btintas?\b|\bplumas?\b|\bpens?\b|fountain|caligraf|calligra|\bwrit|\bescrit"#, "pencil.tip"),
        (#"\blearn|aprend|\bcourses?\b|\bcursos?\b|\bstudy|\bestudi|tutorial|\bclass(es)?\b|\bclases?\b|school|escuela"#, "graduationcap"),
        (#"esp32|esp8266|arduino|electr|\bcpu\b|\bchips?\b|hardware|\bpcb\b|\biot\b|\bsensors?\b"#, "cpu"),
        (#"raspberry|self.?host|\bservers?\b|servidor|homelab|docker|\bnas\b|\binfra"#, "server.rack"),
        (#"terminal|\bcli\b|\bshell\b|\bt3\b"#, "apple.terminal"),
        (#"program|\bcode\b|código|codigo|\bdev\b|develop|angular|\breact\b|\bvue\b|svelte|\bswift\b|python|\brust\b|\bjs\b|typescript"#,
         "chevron.left.forwardslash.chevron.right"),
        (#"\btask|\btareas?\b|\btodos?\b|to-do|pendiente"#, "checklist"),
        (#"download|descarga"#, "arrow.down.circle"),
        (#"\bapps?\b|aplicaci|software|\btools\b|herramient"#, "macwindow"),
        (#"\bshop|\bcompras?\b|\bbuy\b|tienda|\bstores?\b|wishlist|\bdeseos?\b"#, "bag"),
        (#"music|música|musica|\bsongs?\b|spotify|playlist"#, "music.note"),
        (#"\bvideos?\b|youtube|\bmovies?\b|película|pelicula|\bfilms?\b|watch ?later"#, "play.rectangle"),
        (#"travel|\bviajes?\b|\btrips?\b|vacation|vacacion|\bflights?\b|\bvuelos?\b|\bhotels?\b"#, "airplane"),
        (#"recipe|receta|\bfood\b|comida|\bcook|cocina"#, "fork.knife"),
        (#"\bwork\b|trabajo|\bjobs?\b|empleo|\boffice\b|oficina"#, "briefcase"),
        (#"\bfinan|\bmoney\b|dinero|\bbank|\bbanco|\binvest|budget|presupuesto"#, "wallet.bifold"),
        (#"\bgames?\b|\bjuegos?\b|gaming"#, "gamecontroller"),
        (#"\bnews\b|noticia|\barticles?\b|artículo|\bblogs?\b"#, "newspaper"),
        (#"\bbooks?\b|\blibros?\b|\bread(ing)?\b|\blectura|\bleer\b"#, "book"),
        (#"\bphoto|\bfoto|\bcameras?\b|cámara|camara"#, "camera"),
        (#"\bgym\b|fitness|workout|ejercicio"#, "dumbbell"),
        (#"health|\bsalud\b|\bmedic|\bdoctor"#, "waveform.path.ecg"),
        (#"\bhome\b|\bcasa\b|\bhogar\b|\bhouse\b|furniture|\bmuebles?\b"#, "house"),
        (#"\bcars?\b|\bautos?\b|\bcoches?\b|\bcarros?\b|vehic"#, "car"),
        (#"\bai\b|\bia\b|gpt|claude|llm|machine learning"#, "sparkles"),
    ].compactMap { pattern, symbol in (try? NSRegularExpression(pattern: pattern)).map { ($0, symbol) } }

    static func symbol(for title: String) -> String {
        let t = title.lowercased()
        let range = NSRange(t.startIndex..., in: t)
        for (re, symbol) in rules where re.firstMatch(in: t, range: range) != nil { return symbol }
        return "folder"
    }
}

extension DeviceKind {
    var symbol: String {
        switch self {
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .laptop: return "laptopcomputer"
        case .desktop: return "desktopcomputer"
        case .unknown: return "display"
        }
    }

    var spokenName: String {
        switch self {
        case .phone: return "iPhone"
        case .tablet: return "iPad"
        case .laptop, .desktop: return "Mac"
        case .unknown: return "device"
        }
    }
}

/// Favicons for the tab list: Safari's own cache (through the reader) first, then, if the user allowed it,
/// fetched from the web. Kept in memory only; looked up only for rows that are on screen.
@MainActor
final class FaviconStore: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    private var misses: [String: Date] = [:]
    private var pending: Set<String> = []
    weak var model: AppModel?

    static func key(_ url: String) -> String { FaviconFetcher.host(of: url) }

    func image(for url: String) -> NSImage? { images[Self.key(url)] }

    func request(_ url: String) {
        let key = Self.key(url)
        guard !key.isEmpty, images[key] == nil, !pending.contains(key) else { return }
        if let missed = misses[key], Date().timeIntervalSince(missed) < 600 { return }
        pending.insert(key)
        let fetch = model?.settings.fetchFavicons ?? false
        let reader = model?.readerClient
        let fetcher = model?.relayService.box.fetcher
        Task {
            var image: NSImage?
            if let d = await reader?.favicon(url), let (png, _) = ImageKind.forBrowsers(d) { image = NSImage(data: png) }
            if image == nil, fetch, let fetcher, let d = await fetcher.icon(forPage: url), let (png, _) = ImageKind.forBrowsers(d) {
                image = NSImage(data: png)
            }
            pending.remove(key)
            if let image, image.isValid {
                images[key] = image
            } else {
                misses[key] = Date()
            }
        }
    }

    /// Forget misses (after the tab list changed or fetching was turned on), so icons are looked up again.
    func retryMisses() { misses.removeAll() }

    #if DEBUG
    func debugSet(_ url: String, _ image: NSImage) { images[Self.key(url)] = image }
    #endif

    func clear() {
        images.removeAll()
        misses.removeAll()
    }
}

/// SwiftUI also has a `Tab`; in this app, `Tab` is always a Safari tab.
typealias Tab = TabTunnelModel.Tab
