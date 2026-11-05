import Foundation

/// A parsed HTTP request: GET only, small, no body. Anything else is rejected before routing.
public struct HTTPRequest: Sendable {
    public var method: String
    /// Raw target, e.g. "/favicon?url=https%3A%2F%2F..."
    public var target: String
    public var headers: [String: String] // lowercased names; repeated headers keep the first value

    public init(method: String, target: String, headers: [String: String]) {
        self.method = method
        self.target = target
        self.headers = headers
    }

    public static let maxHeaderBytes = 16 * 1024

    public enum ParseResult: Equatable {
        case needMore
        case done(consumed: Int)
        case bad
    }

    /// Parses the head of a request from `buffer`. Strict: CRLF line endings, at most 64 headers,
    /// no obsolete line folding, no request body (Content-Length > 0 or Transfer-Encoding are refused).
    public static func parse(_ buffer: Data) -> (ParseResult, HTTPRequest?) {
        let end = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: end) else {
            return (buffer.count > maxHeaderBytes ? .bad : .needMore, nil)
        }
        guard range.upperBound <= maxHeaderBytes,
              let head = String(data: buffer[buffer.startIndex..<range.lowerBound], encoding: .utf8) else { return (.bad, nil) }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, start[2] == "HTTP/1.1" || start[2] == "HTTP/1.0",
              !start[0].isEmpty, start[0].allSatisfy({ $0.isUppercase }),
              start[1].hasPrefix("/"), start[1].count <= 8192,
              !start[1].contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 0x21 || $0 == 0x7f } ?? false })
        else { return (.bad, nil) }
        var headers: [String: String] = [:]
        guard lines.count <= 65 else { return (.bad, nil) }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line.hasPrefix(" "), !line.hasPrefix("\t") else { return (.bad, nil) }
            let name = line[..<colon].lowercased()
            guard name.allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) }) else { return (.bad, nil) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] == nil { headers[name] = value }
        }
        if headers["transfer-encoding"] != nil { return (.bad, nil) }
        if let cl = headers["content-length"], cl != "0" { return (.bad, nil) }
        return (.done(consumed: range.upperBound - buffer.startIndex),
                HTTPRequest(method: String(start[0]), target: String(start[1]), headers: headers))
    }

    public var path: String {
        let p = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        var trimmed = p
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? "/" : trimmed
    }

    public func query(_ name: String) -> String? {
        guard let q = target.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            if key == name {
                let v = kv.count > 1 ? String(kv[1]) : ""
                return v.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
        }
        return nil
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, contentType: String? = nil, body: Data = Data(), headers: [(String, String)] = [],
                cache: String = "no-store") {
        self.status = status
        self.body = body
        var h = headers
        if let contentType { h.insert(("Content-Type", contentType), at: 0) }
        h.append(("Cache-Control", cache))
        h.append(("X-Content-Type-Options", "nosniff"))
        h.append(("Referrer-Policy", "no-referrer"))
        if contentType?.hasPrefix("image/svg") == true { // never let a site's SVG run script on the relay origin
            h.append(("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; sandbox"))
        }
        self.headers = h
    }

    public static func json(_ status: Int, _ obj: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    static let reasons: [Int: String] = [
        200: "OK", 304: "Not Modified", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
        405: "Method Not Allowed", 408: "Request Timeout", 421: "Misdirected Request", 431: "Request Header Fields Too Large",
        503: "Service Unavailable",
    ]

    /// HTTP/1.0 with Connection: close: one request per connection, no keep-alive state to get wrong.
    public func serialized() -> Data {
        var head = "HTTP/1.0 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
