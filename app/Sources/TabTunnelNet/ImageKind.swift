import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageKind {
    /// The content type of image bytes browsers can show, judged from the bytes themselves.
    public static func sniff(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(16))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if b.starts(with: Array("GIF".utf8)) { return "image/gif" }
        if b.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if b.count >= 12, b.starts(with: Array("RIFF".utf8)), Array(b[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        if b.starts(with: [0, 0, 1, 0]) { return "image/x-icon" }
        let head = String(decoding: d.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if head.hasPrefix("<svg") || (head.hasPrefix("<?xml") && head.contains("<svg")) { return "image/svg+xml" }
        return nil
    }

    /// Safari stores some icons as TIFF or HEIF, which browsers can't show: convert those to a 64 px PNG.
    /// Everything browsers can show passes through. Returns nil for anything that isn't an image.
    public static func forBrowsers(_ d: Data) -> (Data, String)? {
        guard !d.isEmpty, d.count <= 4 * 1024 * 1024 else { return nil }
        if let t = sniff(d), d.count <= 1024 * 1024 { return (d, t) }
        guard let png = toPNG(d, maxPixels: 64) else { return nil }
        return (png, "image/png")
    }

    public static func toPNG(_ d: Data, maxPixels: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, nil)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }
}
