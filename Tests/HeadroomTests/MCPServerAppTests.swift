import XCTest
@testable import Headroom

/// The MCP tools while the Headroom window is open: they read and reuse the window's scan.
@MainActor
final class MCPServerAppTests: XCTestCase {
    private var dir: URL!
    private var app: AppState!
    private var savedRecents: [String]?

    override func setUp() async throws {
        dir = try TestSupport.makeTempDir("mcp-app")
        savedRecents = UserDefaults.standard.stringArray(forKey: "recentScans")
        try TestSupport.write(dir.appendingPathComponent("big.bin"), bytes: 2_000_000)
        try TestSupport.write(dir.appendingPathComponent("sub/big-copy.bin"), bytes: 2_000_000)
        try TestSupport.write(dir.appendingPathComponent("sub/small.txt"), bytes: 1_000)
        app = AppState()
        MCPServer.app = app
    }

    override func tearDown() async throws {
        MCPServer.app = nil
        app = nil
        try? FileManager.default.removeItem(at: dir)
        if let savedRecents { UserDefaults.standard.set(savedRecents, forKey: "recentScans") }
        else { UserDefaults.standard.removeObject(forKey: "recentScans") }
    }

    private func call(_ name: String, _ args: [String: Any] = [:]) async throws -> (isError: Bool, body: [String: Any]) {
        let response = await MCPServer.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                               "params": ["name": name, "arguments": args]])
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        let body = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? ["text": text]
        return (result["isError"] as? Bool ?? false, body)
    }

    private func scanSource(_ body: [String: Any]) -> String? {
        (body["scan"] as? [String: Any])?["source"] as? String
    }

    private func scanInWindow() async throws -> FileNode {
        app.scan(dir)
        let root = await app.waitForScan()
        return try XCTUnwrap(root)
    }

    func testStateOfAnIdleWindow() async throws {
        let (_, body) = try await call("headroom_state")
        XCTAssertEqual(body["app_running"] as? Bool, true)
        XCTAssertEqual(body["status"] as? String, "idle")
        XCTAssertNil(body["folder"])
    }

    func testStateReportsFolderSelectionAndDuplicates() async throws {
        let root = try await scanInWindow()
        let sub = try XCTUnwrap(root.children.first { $0.name == "sub" })
        app.selection = [sub.id]
        _ = await app.findDuplicatesAndWait()

        let (_, body) = try await call("headroom_state")
        XCTAssertEqual(body["status"] as? String, "done")
        XCTAssertEqual(body["folder"] as? String, dir.path)
        XCTAssertEqual(body["files"] as? Int, 3)
        XCTAssertNotNil(body["scanned_at"])
        let selection = try XCTUnwrap(body["selection"] as? [[String: Any]])
        XCTAssertEqual(selection.first?["path"] as? String, sub.path)
        XCTAssertNotNil(selection.first?["safety"])
        XCTAssertEqual(body["inspected"] as? String, sub.path)
        XCTAssertEqual((body["duplicates"] as? [String: Any])?["groups"] as? Int, 1)
        XCTAssertEqual((body["recent_folders"] as? [String])?.first, dir.path)
    }

    func testStateOfAFailedScan() async throws {
        app.phase = .failed("disk went away")
        let (_, body) = try await call("headroom_state")
        XCTAssertEqual(body["status"] as? String, "failed")
        XCTAssertEqual(body["error"] as? String, "disk went away")
    }

    func testToolsScanInTheEmptyWindowAndReuseIt() async throws {
        let (isError, body) = try await call("scan_folder", ["path": dir.path])
        XCTAssertFalse(isError)
        XCTAssertEqual(scanSource(body), "headroom_app")
        XCTAssertEqual(app.root?.path, dir.path, "an empty window shows what the agent scanned")

        let list = try await call("list_folder", ["path": dir.appendingPathComponent("sub").path])
        XCTAssertFalse(list.isError)
        XCTAssertEqual(scanSource(list.body), "headroom_app")
    }

    func testABusyWindowIsLeftAlone() async throws {
        _ = try await scanInWindow()
        let other = try TestSupport.makeTempDir("mcp-other")
        defer { try? FileManager.default.removeItem(at: other) }
        try TestSupport.write(other.appendingPathComponent("x.bin"), bytes: 10_000)

        let (_, body) = try await call("scan_folder", ["path": other.path])
        XCTAssertEqual(scanSource(body), "mcp")
        XCTAssertEqual(app.root?.path, dir.path, "the user's folder stays on screen")
    }

    func testDuplicatesComeFromTheWindow() async throws {
        _ = try await scanInWindow()
        let first = try await call("find_duplicates", ["path": dir.path])
        XCTAssertEqual(first.body["source"] as? String, "headroom_app")
        XCTAssertEqual(first.body["groups"] as? Int, 1)
        XCTAssertNotNil(app.duplicates, "the search ran in the window, so the user sees it")

        let again = try await call("find_duplicates", ["path": dir.path])
        XCTAssertEqual(again.body["source"] as? String, "headroom_app")

        let custom = try await call("find_duplicates", ["path": dir.path, "min_size_mb": 0.5])
        XCTAssertEqual(custom.body["source"] as? String, "computed")
    }

    func testExplainUsesTheWindowsTree() async throws {
        _ = try await scanInWindow()
        let (isError, body) = try await call("explain_path", ["path": dir.appendingPathComponent("big.bin").path])
        XCTAssertFalse(isError)
        XCTAssertNotNil(body["level"] as? String)
        XCTAssertEqual(body["path"] as? String, dir.appendingPathComponent("big.bin").path)
        XCTAssertNotNil(body["size"], "a node from the scanned tree carries its size")
    }

    func testOpenInHeadroomRejectsFiles() async throws {
        let file = dir.appendingPathComponent("big.bin").path
        let (isError, body) = try await call("open_in_headroom", ["path": file])
        XCTAssertTrue(isError)
        XCTAssertTrue((body["text"] as? String ?? "").contains("Not a folder"))
    }
}
