import XCTest
@testable import Headroom

final class MCPServerTests: XCTestCase {
    private func request(_ method: String, id: Int = 1, params: [String: Any] = [:]) async -> [String: Any]? {
        await MCPServer.handle(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    /// Calls a tool and decodes the JSON text it returns.
    private func call(_ name: String, _ args: [String: Any]) async throws -> (isError: Bool, body: Any?) {
        let response = await request("tools/call", params: ["name": name, "arguments": args])
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    func testInitializeAdvertisesTools() async throws {
        let response = await request("initialize")
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, MCPServer.protocolVersion)
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "headroom")
    }

    func testNotificationsGetNoResponse() async {
        let response = await MCPServer.handle(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(response)
    }

    func testToolsListHasSchemas() async throws {
        let response = await request("tools/list")
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String },
                       ["disk_status", "headroom_state", "scan_folder", "list_folder", "largest_files", "find_cleanup",
                        "explain_path", "find_duplicates", "open_in_headroom", "move_to_trash"])
        for tool in tools {
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
        }
        let trash = try XCTUnwrap(tools.first { $0["name"] as? String == "move_to_trash" })
        XCTAssertEqual((trash["annotations"] as? [String: Any])?["destructiveHint"] as? Bool, true)
    }

    func testUnknownMethodAndToolAreErrors() async throws {
        let methodResponse = await request("nope")
        let method = try XCTUnwrap(methodResponse?["error"] as? [String: Any])
        XCTAssertEqual(method["code"] as? Int, -32601)
        let toolResponse = await request("tools/call", params: ["name": "nope"])
        let tool = try XCTUnwrap(toolResponse?["error"] as? [String: Any])
        XCTAssertEqual(tool["code"] as? Int, -32602)
    }

    func testDiskStatus() async throws {
        let (isError, body) = try await call("disk_status", [:])
        XCTAssertFalse(isError)
        let total = try XCTUnwrap((body as? [String: Any])?["total"] as? [String: Any])
        XCTAssertGreaterThan(total["bytes"] as? Int64 ?? 0, 0)
    }

    func testScanFolderSummarizesTree() async throws {
        let root = try TestSupport.makeTempDir("mcp-scan")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(root.appendingPathComponent("big/movie.mov"), bytes: 300_000)
        try TestSupport.write(root.appendingPathComponent("small.txt"), bytes: 10)

        let (isError, body) = try await call("scan_folder", ["path": root.path, "limit": 5])
        XCTAssertFalse(isError)
        let out = try XCTUnwrap(body as? [String: Any])
        XCTAssertEqual(out["files"] as? Int, 2)
        let children = try XCTUnwrap(out["largest_children"] as? [[String: Any]])
        XCTAssertEqual(children.first?["path"] as? String, root.appendingPathComponent("big").path)
        XCTAssertEqual(children.first?["kind"] as? String, "folder")
        let items = try XCTUnwrap(out["largest_items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["path"] as? String, root.appendingPathComponent("big/movie.mov").path)
    }

    func testFindCleanupInFolder() async throws {
        let root = try TestSupport.makeTempDir("mcp-cleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(root.appendingPathComponent("proj/node_modules/pkg/index.js"), bytes: 2 << 20)

        let (_, body) = try await call("find_cleanup", ["path": root.path])
        let candidates = try XCTUnwrap((body as? [String: Any])?["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?["kind"] as? String, "dependencies")
        XCTAssertEqual((candidates.first?["safety"] as? [String: Any])?["level"] as? String, "safe")
    }

    func testExplainPathInheritsFromAncestors() async throws {
        let (_, body) = try await call("explain_path", ["path": "/System/Library"])
        XCTAssertEqual((body as? [String: Any])?["level"] as? String, "never")
        let missing = try await call("explain_path", ["path": "/definitely/not/here"])
        XCTAssertTrue(missing.isError)
    }

    func testFindDuplicates() async throws {
        let root = try TestSupport.makeTempDir("mcp-dupes")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(root.appendingPathComponent("a.bin"), bytes: 2_000_000)
        try TestSupport.write(root.appendingPathComponent("b/a-copy.bin"), bytes: 2_000_000)

        let (_, body) = try await call("find_duplicates", ["path": root.path])
        let out = try XCTUnwrap(body as? [String: Any])
        XCTAssertEqual(out["groups"] as? Int, 1)
        let group = try XCTUnwrap((out["top_groups"] as? [[String: Any]])?.first)
        XCTAssertEqual(group["copies"] as? Int, 2)
    }

    func testMoveToTrashRefusesProtectedPaths() async throws {
        let (isError, body) = try await call("move_to_trash", ["paths": ["/", "~", "/System/Library", "/definitely/not/here"]])
        XCTAssertFalse(isError)
        let out = try XCTUnwrap(body as? [String: Any])
        XCTAssertEqual((out["moved_to_trash"] as? [String])?.count, 0)
        XCTAssertEqual((out["refused"] as? [[String: Any]])?.count, 4)
    }

    func testRefusalSeesThroughCaseAndSymlinks() throws {
        let home = NSHomeDirectory()
        XCTAssertNotNil(MCPServer.refusal(for: home + "/Library"))
        // APFS ignores case by default, so this names the real folder.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: home + "/LIBRARY", isDirectory: &isDir), isDir.boolValue {
            XCTAssertNotNil(MCPServer.refusal(for: MCPServer.expand(home + "/LIBRARY")))
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let link = tmp.appendingPathComponent("lib")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: home + "/Library"))
        XCTAssertNotNil(MCPServer.refusal(for: MCPServer.expand(link.path)), "a symlink to a protected folder names that folder")
        XCTAssertNil(MCPServer.refusal(for: MCPServer.expand(tmp.path)))
        XCTAssertNil(MCPServer.refusal(for: "/definitely/not/here"))
    }

    func testMissingArgumentsAreToolErrors() async throws {
        let noPath = try await call("scan_folder", [:])
        XCTAssertTrue(noPath.isError)
        let noPaths = try await call("move_to_trash", ["paths": [String]()])
        XCTAssertTrue(noPaths.isError)
    }

    func testScansAreCachedUntilRefresh() async throws {
        let root = try TestSupport.makeTempDir("mcp-cache")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(root.appendingPathComponent("sub/a.bin"), bytes: 50_000)

        let first = try await call("scan_folder", ["path": root.path])
        let firstScan = try XCTUnwrap((first.body as? [String: Any])?["scan"] as? [String: Any])
        XCTAssertEqual(firstScan["source"] as? String, "mcp")

        // A subfolder of a cached tree is answered from the cache, even after the disk changes.
        try TestSupport.write(root.appendingPathComponent("sub/b.bin"), bytes: 50_000)
        let cached = try await call("scan_folder", ["path": root.appendingPathComponent("sub").path])
        XCTAssertEqual(((cached.body as? [String: Any])?["scan"] as? [String: Any])?["root"] as? String, root.path)
        XCTAssertEqual((cached.body as? [String: Any])?["files"] as? Int, 1)

        let fresh = try await call("scan_folder", ["path": root.appendingPathComponent("sub").path, "refresh": true])
        XCTAssertEqual((fresh.body as? [String: Any])?["files"] as? Int, 2)
    }

    func testListFolderExpandsToDepth() async throws {
        let root = try TestSupport.makeTempDir("mcp-list")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(root.appendingPathComponent("a/b/deep.bin"), bytes: 40_000)
        try TestSupport.write(root.appendingPathComponent("top.txt"), bytes: 10)

        let (_, body) = try await call("list_folder", ["path": root.path, "depth": 2, "refresh": true])
        let tree = try XCTUnwrap((body as? [String: Any])?["tree"] as? [String: Any])
        let children = try XCTUnwrap(tree["children"] as? [[String: Any]])
        XCTAssertEqual(children.first?["path"] as? String, root.appendingPathComponent("a").path)
        let grandchildren = try XCTUnwrap(children.first?["children"] as? [[String: Any]])
        XCTAssertEqual(grandchildren.first?["path"] as? String, root.appendingPathComponent("a/b").path)
        XCTAssertNil(grandchildren.first?["children"], "depth 2 stops below the grandchildren")
    }

    func testListFolderSummarizesTruncatedChildren() async throws {
        let root = try TestSupport.makeTempDir("mcp-more")
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<5 { try TestSupport.write(root.appendingPathComponent("f\(i).bin"), bytes: 10_000) }

        let (_, body) = try await call("list_folder", ["path": root.path, "limit": 2, "refresh": true])
        let tree = try XCTUnwrap((body as? [String: Any])?["tree"] as? [String: Any])
        XCTAssertEqual((tree["children"] as? [Any])?.count, 2)
        XCTAssertEqual((tree["more"] as? [String: Any])?["items"] as? Int, 3)
    }

    func testLargestFilesByCategory() async throws {
        let root = try TestSupport.makeTempDir("mcp-largest")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(root.appendingPathComponent("movie.mov"), bytes: 300_000)
        try TestSupport.write(root.appendingPathComponent("photo.jpg"), bytes: 100_000)
        try TestSupport.write(root.appendingPathComponent("node_modules/lib.js"), bytes: 200_000)

        let video = try await call("largest_files", ["path": root.path, "category": "video", "refresh": true])
        let videoItems = try XCTUnwrap((video.body as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertEqual(videoItems.map { $0["path"] as? String }, [root.appendingPathComponent("movie.mov").path])

        // Files take the category forced by their folder (node_modules → packages).
        let packages = try await call("largest_files", ["path": root.path, "category": "packages"])
        let packageItems = try XCTUnwrap((packages.body as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertEqual(packageItems.first?["path"] as? String, root.appendingPathComponent("node_modules/lib.js").path)

        let all = try await call("largest_files", ["path": root.path, "limit": 2])
        XCTAssertEqual(((all.body as? [String: Any])?["items"] as? [Any])?.count, 2)

        let bad = try await call("largest_files", ["path": root.path, "category": "nope"])
        XCTAssertTrue(bad.isError)
    }

    func testHeadroomStateWithoutApp() async throws {
        let (_, body) = try await call("headroom_state", [:])
        XCTAssertEqual((body as? [String: Any])?["app_running"] as? Bool, false)
        let open = try await call("open_in_headroom", ["path": NSTemporaryDirectory()])
        XCTAssertTrue(open.isError)
    }

    func testFindLocatesNodesByPath() {
        let root = TestSupport.tree("root", path: "/r") { r in
            [TestSupport.tree("a", path: "/r/a", parent: r) { a in [TestSupport.file("x", size: 1, parent: a)] }]
        }
        XCTAssertTrue(MCPServer.find("/r", in: root) === root)
        XCTAssertEqual(MCPServer.find("/r/a/x", in: root)?.name, "x")
        XCTAssertNil(MCPServer.find("/r/b", in: root))
        XCTAssertNil(MCPServer.find("/rr/a", in: root))
    }

    func testChainLinksParents() {
        let nodes = MCPServer.chain(to: "/usr/bin")
        XCTAssertEqual(nodes.map(\.name), ["/", "usr", "bin"])
        XCTAssertTrue(nodes.last?.parent === nodes[1])
        XCTAssertTrue(MCPServer.chain(to: "/definitely/not/here").isEmpty)
    }
}
