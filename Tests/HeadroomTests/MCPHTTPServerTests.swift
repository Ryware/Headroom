import XCTest
@testable import Headroom

final class MCPHTTPServerTests: XCTestCase {
    func testOnlyLoopbackHostsAndOriginsAreAllowed() {
        XCTAssertTrue(MCPHTTPServer.isAllowed(host: "127.0.0.1:47120", origin: nil))
        XCTAssertTrue(MCPHTTPServer.isAllowed(host: "localhost:47120", origin: nil))
        XCTAssertTrue(MCPHTTPServer.isAllowed(host: "[::1]:47120", origin: nil))
        XCTAssertTrue(MCPHTTPServer.isAllowed(host: nil, origin: nil))
        XCTAssertTrue(MCPHTTPServer.isAllowed(host: "127.0.0.1:47120", origin: "http://localhost:3000"))
        // DNS rebinding: a page on evil.com resolving to 127.0.0.1 still sends its own Host and Origin.
        XCTAssertFalse(MCPHTTPServer.isAllowed(host: "evil.com:47120", origin: nil))
        XCTAssertFalse(MCPHTTPServer.isAllowed(host: "127.0.0.1:47120", origin: "https://evil.com"))
        XCTAssertFalse(MCPHTTPServer.isAllowed(host: "127.0.0.1:47120", origin: "null"))
    }

    func testParsesRequestOnceComplete() throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47120\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let data = Data(raw.utf8)
        XCTAssertNil(HTTPRequest.parse(data.prefix(data.count - 5)), "body not complete yet")
        let request = try XCTUnwrap(HTTPRequest.parse(data))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.headers["host"], "127.0.0.1:47120")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
    }

    func testImpossibleContentLengthsAreBadRequestsNotCrashes() {
        for length in ["-1", "99999999999999999999", "abc", "\(HTTPRequest.maxBody + 1)"] {
            let raw = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47120\r\nContent-Length: \(length)\r\n\r\n".utf8)
            guard case .invalid = HTTPRequest.read(raw) else { return XCTFail("Content-Length \(length) must be refused") }
            XCTAssertNil(HTTPRequest.parse(raw))
        }
        guard case .incomplete = HTTPRequest.read(Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\n\r\n{}".utf8)) else {
            return XCTFail("a short body is still being received")
        }
        guard case .invalid = HTTPRequest.read(Data("garbage\r\n\r\n".utf8)) else { return XCTFail("no method and path") }
    }

    func testRequestsNeedTheSessionToken() {
        XCTAssertTrue(MCPHTTPServer.authorized(header: "Bearer abc123", token: "abc123"))
        XCTAssertTrue(MCPHTTPServer.authorized(header: "bearer abc123", token: "abc123"))
        XCTAssertFalse(MCPHTTPServer.authorized(header: nil, token: "abc123"))
        XCTAssertFalse(MCPHTTPServer.authorized(header: "Bearer abc124", token: "abc123"))
        XCTAssertFalse(MCPHTTPServer.authorized(header: "Bearer abc1234", token: "abc123"))
        XCTAssertFalse(MCPHTTPServer.authorized(header: "Bearer abc12", token: "abc123"))
        XCTAssertFalse(MCPHTTPServer.authorized(header: "Basic abc123", token: "abc123"))
        XCTAssertFalse(MCPHTTPServer.authorized(header: "Bearer abc123", token: nil), "not serving: nothing is valid")
        XCTAssertFalse(MCPHTTPServer.authorized(header: "Bearer", token: "abc123"))
    }

    /// The real listener, end to end: token, Host check, parser and the CLI's forwarding.
    func testListenerEnforcesTokenHostAndParser() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let port = Int.random(in: 49_152...60_000)
        MCPHTTPServer.tokenDirectory = dir
        UserDefaults.standard.set(port, forKey: "mcpPort")
        let server = MCPHTTPServer.shared
        defer {
            server.stop()
            UserDefaults.standard.removeObject(forKey: "mcpPort")
            MCPHTTPServer.tokenDirectory = nil
            try? FileManager.default.removeItem(at: dir)
        }
        server.start()

        var token: String?
        for _ in 0..<200 where token == nil {
            token = MCPHTTPServer.readToken()
            if token == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        let t = try XCTUnwrap(token, "the server writes its token before it serves")
        XCTAssertEqual(t.count, 64)
        let tokenURL = try XCTUnwrap(MCPHTTPServer.tokenURL)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: tokenURL.path)[.posixPermissions] as? Int, 0o600)

        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        func post(_ headers: [String: String]) async throws -> (status: Int, body: String) {
            var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp")))
            request.httpMethod = "POST"
            request.httpBody = Data(ping.utf8)
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (try XCTUnwrap(response as? HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
        }
        var ready = false
        for _ in 0..<200 where !ready {
            ready = (try? await post([:])) != nil
            if !ready { try await Task.sleep(for: .milliseconds(25)) }
        }
        XCTAssertTrue(ready, "listener did not come up on port \(port)")

        let noToken = try await post([:])
        XCTAssertEqual(noToken.status, 401)
        let wrongToken = try await post(["Authorization": "Bearer nope"])
        XCTAssertEqual(wrongToken.status, 401)
        let ok = try await post(["Authorization": "Bearer \(t)"])
        XCTAssertEqual(ok.status, 200)
        XCTAssertTrue(ok.body.contains(#""id":1"#), ok.body)

        // `Headroom --mcp` and the CLI read the token themselves.
        if case .handled(let data?) = await MCPHTTPServer.forward(Data(ping.utf8)) {
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("result"))
        } else {
            XCTFail("forward should reach the listener with the token")
        }

        // Raw requests URLSession would not send: a foreign Host, and Content-Lengths that used to crash.
        XCTAssertTrue(raw("POST /mcp HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Bearer \(t)\r\nContent-Length: 0\r\n\r\n", port: port).hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(raw("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(t)\r\nContent-Length: -1\r\n\r\n", port: port).hasPrefix("HTTP/1.1 400"))
        XCTAssertTrue(raw("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: abc\r\n\r\n", port: port).hasPrefix("HTTP/1.1 400"))
        let stillUp = try await post(["Authorization": "Bearer \(t)"])
        XCTAssertEqual(stillUp.status, 200, "still serving after the bad requests")

        server.stop()
        for _ in 0..<200 where MCPHTTPServer.readToken() != nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNil(MCPHTTPServer.readToken(), "stop removes the token file")
        if case .unavailable = await MCPHTTPServer.forward(Data(ping.utf8)) {} else { XCTFail("no token: handle in-process") }
    }

    /// One HTTP exchange over a plain socket; returns the response head.
    private func raw(_ request: String, port: Int) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "socket failed" }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { return "connect failed" }
        var bytes = Array(request.utf8)
        guard write(fd, &bytes, bytes.count) == bytes.count else { return "write failed" }
        var out = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &out, out.count)
        return n > 0 ? String(decoding: out[0..<n], as: UTF8.self) : "no response"
    }

    func testRawMessagesRoundTrip() async throws {
        let response = await MCPServer.handle(Data(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(response)) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 7)
        let notification = await MCPServer.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertNil(notification)
        let garbage = await MCPServer.handle(Data("nope".utf8))
        let error = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(garbage)) as? [String: Any])
        XCTAssertEqual((error["error"] as? [String: Any])?["code"] as? Int, -32700)
    }
}

final class HeadroomCLITests: XCTestCase {
    private func args(_ command: String, _ argv: [String]) throws -> [String: Any] {
        try HeadroomCLI.arguments(for: XCTUnwrap(HeadroomCLI.tool(named: command)), argv)
    }

    func testEveryCommandMapsToATool() {
        for (command, tool) in HeadroomCLI.commands {
            XCTAssertEqual(HeadroomCLI.tool(named: command)?["name"] as? String, tool)
            XCTAssertTrue(HeadroomCLI.usage.contains("  \(command) "), command)
        }
        XCTAssertEqual(HeadroomCLI.commands.count, MCPServer.tools.count)
    }

    func testOptionsAreTypedFromTheSchema() throws {
        let a = try args("duplicates", ["~/Downloads", "--limit", "5", "--min-size-mb=2.5", "--refresh"])
        XCTAssertEqual(a["path"] as? String, "~/Downloads")
        XCTAssertEqual(a["limit"] as? Int, 5)
        XCTAssertEqual(a["min_size_mb"] as? Double, 2.5)
        XCTAssertEqual(a["refresh"] as? Bool, true)
        XCTAssertEqual(try args("largest_files", ["/", "--category", "video"])["category"] as? String, "video")
    }

    func testTrashTakesSeveralPaths() throws {
        XCTAssertEqual(try args("trash", ["/a", "/b", "--yes"])["paths"] as? [String], ["/a", "/b"])
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try args("scan", ["/a", "/b"]))
        XCTAssertThrowsError(try args("scan", ["/a", "--nope"]))
        XCTAssertThrowsError(try args("scan", ["/a", "--limit", "many"]))
        XCTAssertThrowsError(try args("largest", ["/a", "--category", "nope"]))
        XCTAssertThrowsError(try args("state", ["/a"]))
    }

    func testOnlyCommandsLeaveTheAppMode() {
        XCTAssertTrue(HeadroomCLI.handles(["status"]))
        XCTAssertTrue(HeadroomCLI.handles(["--help"]))
        XCTAssertTrue(HeadroomCLI.handles(["scna"]), "a typo must not open the window")
        XCTAssertFalse(HeadroomCLI.handles([]))
        XCTAssertFalse(HeadroomCLI.handles(["-NSDocumentRevisionsDebugMode", "YES"]))
    }
}
