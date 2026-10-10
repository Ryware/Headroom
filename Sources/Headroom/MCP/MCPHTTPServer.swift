import Foundation
import Network

/// Serves `MCPServer` over MCP's Streamable HTTP transport on 127.0.0.1 while the app is open,
/// so agents see the folder open in the window. Stateless JSON responses only: every POST
/// carries one JSON-RPC message and gets one JSON reply (or 202 for notifications).
///
/// Only loopback connections are accepted, and requests with a foreign Host or Origin header
/// are rejected so web pages can't reach it through the browser (DNS rebinding). Every request
/// must also carry the session token from `tokenURL`, a file only this user can read: sandboxed
/// apps and other users logged in on the Mac can reach 127.0.0.1 too, and must not be able to
/// move this user's files to the Trash.
final class MCPHTTPServer: @unchecked Sendable {
    static let shared = MCPHTTPServer()

    static let defaultPort: UInt16 = 47_120
    static var port: UInt16 {
        let p = UserDefaults.standard.integer(forKey: "mcpPort")
        return (1...65_535).contains(p) ? UInt16(p) : defaultPort
    }
    static var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    /// Where the running app leaves the session token for the CLI and `--mcp` (mode 0600).
    static var tokenURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("Headroom", isDirectory: true).appendingPathComponent("mcp-token")
    }

    private let queue = DispatchQueue(label: "dev.ryware.headroom.mcp-http")
    private var listener: NWListener?
    /// This session's secret; nil while not serving. Only touched on `queue`.
    private var token: String?

    /// Why the listener is not running, for Settings (e.g. the port is taken).
    @MainActor static var lastError: String?

    func start() {
        queue.async { [self] in
            guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
            guard let token = Self.writeToken() else {
                Task { @MainActor in Self.lastError = "Cannot write the session token to Application Support." }
                return
            }
            self.token = token
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            params.allowLocalEndpointReuse = true
            do {
                let l = try NWListener(using: params)
                l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                l.stateUpdateHandler = { state in
                    if case .failed(let error) = state {
                        Task { @MainActor in Self.lastError = "Port \(Self.port): \(error.localizedDescription)" }
                        l.cancel()
                        self.queue.async { if self.listener === l { self.listener = nil } }
                    } else if case .ready = state {
                        Task { @MainActor in Self.lastError = nil }
                    }
                }
                l.start(queue: queue)
                listener = l
            } catch {
                Task { @MainActor in Self.lastError = error.localizedDescription }
            }
        }
    }

    func stop() {
        // Removed right away, not on the queue: at quit there may be no time left for it.
        if let url = Self.tokenURL { try? FileManager.default.removeItem(at: url) }
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            token = nil
        }
    }

    // MARK: Session token

    /// Writes a fresh random token where only this user can read it and returns it.
    private static func writeToken() -> String? {
        guard let url = tokenURL else { return nil }
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
        return token
    }

    /// The token the CLI and `--mcp` present, if the app has left one.
    static func readToken() -> String? {
        guard let url = tokenURL, let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// `Authorization: Bearer <token>` against the session token, compared in constant time.
    static func authorized(header: String?, token: String?) -> Bool {
        guard let token, let header else { return false }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        let presented = Array(parts[1].trimmingCharacters(in: .whitespaces).utf8)
        let expected = Array(token.utf8)
        guard presented.count == expected.count else { return false }
        return zip(presented, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.read(buffer) {
            case .request(let request):
                let token = self.token   // read on `queue`; the Task below runs elsewhere
                Task { await self.respond(to: request, on: conn, token: token) }
            case .invalid:
                self.send(conn, status: 400, body: nil)
            case .incomplete:
                if buffer.count > HTTPRequest.maxBody {
                    self.send(conn, status: 413, body: nil)
                } else if isComplete || error != nil {
                    conn.cancel()
                } else {
                    self.receive(conn, buffer: buffer)
                }
            }
        }
    }

    private func respond(to request: HTTPRequest, on conn: NWConnection, token: String?) async {
        guard Self.isAllowed(host: request.headers["host"], origin: request.headers["origin"]) else {
            return send(conn, status: 403, body: Data(#"{"error":"Forbidden"}"#.utf8))
        }
        guard Self.authorized(header: request.headers["authorization"], token: token) else {
            return send(conn, status: 401, body: Data(#"{"error":"Unauthorized: send the token from ~/Library/Application Support/Headroom/mcp-token as a Bearer token"}"#.utf8),
                        extra: ["WWW-Authenticate": "Bearer"])
        }
        guard request.path == "/mcp" || request.path.hasPrefix("/mcp?") else {
            return send(conn, status: 404, body: nil)
        }
        // No server-initiated streams and no sessions: GET/DELETE are not supported (allowed by the spec).
        guard request.method == "POST" else {
            return send(conn, status: 405, body: nil, extra: ["Allow": "POST"])
        }
        if let response = await MCPServer.handle(request.body) {
            send(conn, status: 200, body: response)
        } else {
            send(conn, status: 202, body: nil)
        }
    }

    private func send(_ conn: NWConnection, status: Int, body: Data?, extra: [String: String] = [:]) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 413: "Payload Too Large"][status] ?? ""
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: close\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        var out = Data((head + "\r\n").utf8)
        if let body { out.append(body) }
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Accepts loopback Host headers and either no Origin (CLI clients) or a loopback one.
    static func isAllowed(host: String?, origin: String?) -> Bool {
        func isLoopback(_ hostPort: String) -> Bool {
            let host = hostPort.hasPrefix("[") ? String(hostPort.prefix { $0 != "]" }.dropFirst())
                : String(hostPort.split(separator: ":").first ?? "")
            return ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
        }
        if let host, !isLoopback(host) { return false }
        if let origin {
            guard let url = URL(string: origin), let h = url.host else { return false }
            return isLoopback(h.contains(":") ? "[\(h)]" : h)
        }
        return true
    }

    // MARK: Forwarding from `Headroom --mcp`

    enum ForwardResult {
        case handled(Data?)     // the app answered (nil for notifications)
        case unavailable        // no app listening; handle in-process
    }

    /// Sends one stdio message to the running app, if there is one.
    static func forward(_ message: Data) async -> ForwardResult {
        // No token file means no app is serving (or its server is off): handle the message here.
        guard let url = URL(string: endpoint), let token = readToken() else { return .unavailable }
        var request = URLRequest(url: url, timeoutInterval: 3600)
        request.httpMethod = "POST"
        request.httpBody = message
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await forwardSession.data(for: request),
              let http = response as? HTTPURLResponse else { return .unavailable }
        switch http.statusCode {
        case 200: return .handled(data)
        case 202: return .handled(nil)
        default: return .unavailable
        }
    }

    private static let forwardSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]   // loopback only, never through a proxy
        config.timeoutIntervalForRequest = 3600
        return URLSession(configuration: config)
    }()
}

/// Just enough HTTP/1.1 to read one request with a Content-Length body.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]   // lowercased names
    let body: Data

    /// Largest body accepted. Anything that declares more is refused before it is buffered.
    static let maxBody = 64 << 20

    enum Outcome {
        case incomplete            // keep reading
        case invalid               // can never become a request: answer 400 and close
        case request(HTTPRequest)
    }

    /// Reads one request from the bytes received so far.
    static func read(_ data: Data) -> Outcome {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
            return data.count > maxBody ? .invalid : .incomplete
        }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // A negative, non-numeric or oversized Content-Length is a bad request, never a slice.
        guard let length = Int(headers["content-length"] ?? "0"), (0...maxBody).contains(length) else { return .invalid }
        let bodyStart = headEnd.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<data.index(bodyStart, offsetBy: length)]
        return .request(HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body)))
    }

    /// The request once `data` holds all of it; nil while incomplete or invalid.
    static func parse(_ data: Data) -> HTTPRequest? {
        if case .request(let request) = read(data) { return request }
        return nil
    }
}
