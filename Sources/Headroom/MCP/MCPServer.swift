import Foundation
import AppKit
import Darwin

/// Model Context Protocol server, so AI agents (Claude Code, Cursor, …) can use Headroom's
/// scanner, cleanup finder, duplicate finder and safety rules.
///
/// Two transports share this handler:
/// - while the app is open, `MCPHTTPServer` serves it on 127.0.0.1 and tools see the folder
///   open in the window (no rescan, plus the user's selection);
/// - `Headroom --mcp` speaks newline-delimited JSON-RPC on stdio. It forwards every message to
///   the running app when there is one and handles it in-process otherwise.
///
/// Everything is read-only except `move_to_trash`, which only ever uses the recoverable Trash
/// and refuses items the safety rules mark "Do not delete".
enum MCPServer {
    static let protocolVersion = "2025-06-18"

    /// The app's state when running inside Headroom.app; nil in standalone stdio mode.
    @MainActor static weak var app: AppState?

    /// Trees scanned on behalf of agents, reused across calls.
    static let store = ScanStore()

    // MARK: stdio

    /// Reads requests until stdin closes, then exits. Never returns.
    static func runStdio() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task.detached {
            do {
                for try await line in FileHandle.standardInput.bytes.lines {
                    guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
                    switch await MCPHTTPServer.forward(data) {
                    case .handled(let response?):
                        if let text = String(data: response, encoding: .utf8) { print(text) }
                    case .handled(nil):
                        break
                    case .unavailable:
                        if let response = await handle(data), let text = String(data: response, encoding: .utf8) { print(text) }
                    }
                }
            } catch {}
            exit(0)
        }
        // Keep the main queue running: moving to the Trash goes through NSWorkspace on main.
        dispatchMain()
    }

    // MARK: JSON-RPC

    /// Handles one raw JSON-RPC message. Returns nil for notifications.
    static func handle(_ data: Data) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(error(id: NSNull(), code: -32700, message: "Parse error"))
        }
        return await handle(message).map(encode)
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    /// Handles one JSON-RPC message. Returns nil for notifications.
    static func handle(_ message: [String: Any]) async -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        guard let id = message["id"] else { return nil }   // notification (e.g. notifications/initialized)
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return result(id: id, [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "headroom", "version": appVersion],
                "instructions": """
                Headroom analyzes disk usage on this Mac. Start with disk_status and headroom_state \
                (what the user has open in Headroom), then scan_folder for an overview. Drill down with \
                list_folder, largest_files and find_cleanup. Scans are cached: pass refresh=true after \
                files change. Check explain_path before suggesting deletions; move_to_trash is \
                recoverable and refuses items marked 'never'. Always confirm with the user before trashing.
                """,
            ])
        case "ping":
            return result(id: id, [:])
        case "tools/list":
            return result(id: id, ["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let payload = try await call(name, args)
                return result(id: id, [
                    "content": [["type": "text", "text": json(payload)]],
                    "isError": false,
                ])
            } catch let e as ToolError {
                if case .unknownTool = e { return error(id: id, code: -32602, message: e.description) }
                return result(id: id, ["content": [["type": "text", "text": e.description]], "isError": true])
            } catch {
                return result(id: id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: Tools

    enum ToolError: Error, CustomStringConvertible {
        case unknownTool(String)
        case invalid(String)

        var description: String {
            switch self {
            case .unknownTool(let name): return "Unknown tool: \(name)"
            case .invalid(let message): return message
            }
        }
    }

    private static let pathArg: [String: Any] = ["type": "string", "description": "Folder or file. ~ is expanded."]
    private static let refreshArg: [String: Any] = ["type": "boolean", "description": "Rescan instead of reusing the folder open in Headroom or a cached scan (default false)."]
    private static func limitArg(_ fallback: Int) -> [String: Any] {
        ["type": "integer", "description": "Maximum entries to return (default \(fallback), max 500)."]
    }

    static let tools: [[String: Any]] = [
        tool("disk_status", "Free, used and total space on the volume holding a path (the startup disk by default), plus the free-space trend Headroom records while it runs (24 hours and 7 days).",
             ["path": ["type": "string", "description": "Any path on the volume. Defaults to /."]]),
        tool("headroom_state", "What the user has open in the Headroom app: scanned folder, scan status, selected items with sizes and safety verdicts, and duplicate results if they ran the duplicate finder. Returns app_running=false when the app is closed.",
             [:]),
        tool("scan_folder", "Dashboard for a folder: total size, file and folder counts, unreadable items, space by category, largest subfolders, largest files and bundles, reclaimable cleanup total. Reuses the folder open in Headroom or a cached scan when possible.",
             ["path": pathArg, "limit": limitArg(15), "refresh": refreshArg], required: ["path"]),
        tool("list_folder", "Folder tree (the data behind Headroom's outline and treemap): children sorted by size with share of parent, file counts, modified dates and categories, expanded to the given depth.",
             ["path": pathArg,
              "depth": ["type": "integer", "description": "Levels to expand (default 1, max 4)."],
              "limit": limitArg(25), "refresh": refreshArg], required: ["path"]),
        tool("largest_files", "Largest files and bundles under a folder, optionally limited to one category (e.g. video, caches, aiModels).",
             ["path": pathArg,
              "category": ["type": "string", "enum": FileCategory.allCases.map(\.rawValue), "description": "Only items in this category."],
              "limit": limitArg(25), "refresh": refreshArg], required: ["path"]),
        tool("find_cleanup", "Find regenerable clutter (caches, node_modules, DerivedData, build output, logs, Trash) with sizes and safety advice. Without a path, checks Headroom's list of well-known cache locations in the home folder.",
             ["path": ["type": "string", "description": "Folder to search. Omit to check the well-known locations."],
              "min_size_mb": ["type": "number", "description": "Ignore candidates smaller than this (default 1)."],
              "refresh": refreshArg]),
        tool("explain_path", "Explain what a file or folder is and whether it is safe to delete, using Headroom's safety rules.",
             ["path": pathArg], required: ["path"]),
        tool("find_duplicates", "Find byte-for-byte identical files in a folder (size, then header, sampled and full SHA-256 hashes), ranked by space wasted. Runs in the Headroom window when it shows this folder (or is empty), so the user sees the results there, and reuses results already found.",
             ["path": pathArg,
              "min_size_mb": ["type": "number", "description": "Ignore files smaller than this (default 1)."],
              "limit": limitArg(20), "refresh": refreshArg], required: ["path"]),
        tool("open_in_headroom", "Open a folder in the Headroom window so the user can explore it visually (treemap, tree, categories). Requires the app to be running.",
             ["path": pathArg], required: ["path"], readOnly: false, destructive: false),
        tool("move_to_trash", "Move files or folders to the Trash (recoverable from Finder). Refuses items Headroom marks 'Do not delete' and top-level system and home folders. Always confirm with the user first.",
             ["paths": ["type": "array", "items": ["type": "string"], "description": "Absolute paths (or ~) to move to the Trash."]],
             required: ["paths"], readOnly: false, destructive: true),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any],
                             required: [String] = [], readOnly: Bool = true, destructive: Bool = false) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive, "openWorldHint": false],
        ]
    }

    static func call(_ name: String, _ args: [String: Any]) async throws -> Any {
        switch name {
        case "disk_status": return try diskStatus(args)
        case "headroom_state": return await headroomState()
        case "scan_folder": return try await scanFolder(args)
        case "list_folder": return try await listFolder(args)
        case "largest_files": return try await largestFiles(args)
        case "find_cleanup": return try await findCleanup(args)
        case "explain_path": return try await explainPath(args)
        case "find_duplicates": return try await findDuplicates(args)
        case "open_in_headroom": return try await openInHeadroom(args)
        case "move_to_trash": return try await moveToTrash(args)
        default: throw ToolError.unknownTool(name)
        }
    }

    // MARK: Tool implementations

    private static func diskStatus(_ args: [String: Any]) throws -> Any {
        let path = try optionalPath(args) ?? "/"
        guard let v = VolumeSnapshot.read(path: path) else { throw ToolError.invalid("Cannot read volume for \(path)") }
        var out: [String: Any] = [
            "volume": v.name,
            "total": sizeJSON(v.total),
            "used": sizeJSON(v.used),
            "free": sizeJSON(v.free),
            "free_percent": percent(v.freeFraction),
        ]
        // The history covers the startup disk only.
        if VolumeSnapshot.read(path: "/")?.name == v.name {
            let history = DiskMonitor.loadHistory()
            var trend: [String: Any] = ["samples": history.count]
            if let d = DiskMonitor.delta(in: history, hours: 24) { trend["change_24h"] = signedSizeJSON(d) }
            if let d = DiskMonitor.delta(in: history, hours: 24 * 7) { trend["change_7d"] = signedSizeJSON(d) }
            if let first = history.first { trend["since"] = date(first.t) }
            out["trend"] = trend
        }
        return out
    }

    private static func headroomState() async -> Any {
        await MainActor.run { () -> [String: Any] in
            guard let app else { return ["app_running": false] }
            var out: [String: Any] = ["app_running": true]
            switch app.phase {
            case .idle: out["status"] = "idle"
            case .scanning:
                out["status"] = "scanning"
                out["progress"] = ["files": app.progress.files, "bytes": app.progress.bytes, "current": app.progress.current]
            case .done: out["status"] = "done"
            case .failed(let message): out["status"] = "failed"; out["error"] = message
            }
            if let url = app.rootURL { out["folder"] = url.path }
            if let root = app.root, app.phase == .done {
                out["size"] = sizeJSON(root.allocatedSize)
                out["files"] = root.fileCount
                out["unreadable"] = app.progress.errors
                if let finished = app.progress.finished { out["scanned_at"] = date(finished) }
                let selected = app.selectedNodes.sorted { $0.allocatedSize > $1.allocatedSize }
                out["selection"] = selected.prefix(100).map { n -> [String: Any] in
                    var j = nodeJSON(n, parentSize: 0)
                    j["safety"] = safetyJSON(SafetyKB.info(for: n))
                    return j
                }
                out["selection_total"] = sizeJSON(selected.reduce(0) { $0 + $1.allocatedSize })
                if let inspected = app.selectedNode, inspected !== root { out["inspected"] = inspected.path }
                if let d = app.duplicates {
                    out["duplicates"] = ["groups": d.groups.count, "wasted": sizeJSON(d.wasted)]
                }
            }
            out["recent_folders"] = app.recentScans.map(\.path)
            return out
        }
    }

    private static func scanFolder(_ args: [String: Any]) async throws -> Any {
        let (scan, node) = try await resolve(try requiredPath(args), refresh: args["refresh"] as? Bool ?? false)
        let limit = clamp(args["limit"], default: 15)
        let categories = node.categoryTotals()
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { ["category": $0.key.rawValue, "title": $0.key.title, "size": $0.value.humanBytes, "bytes": $0.value] as [String: Any] }
        let cleanup = CleanupFinder.candidates(in: node)
        var out = scan.json
        out.merge([
            "path": node.path,
            "size": sizeJSON(node.allocatedSize),
            "files": node.fileCount,
            "folders": node.directoryCount,
            "largest_children": node.children.prefix(limit).map { nodeJSON($0, parentSize: node.allocatedSize) },
            "largest_items": node.largestItems(limit: limit).map { nodeJSON($0, parentSize: node.allocatedSize) },
            "categories": categories,
            "cleanup": ["candidates": cleanup.count, "reclaimable": sizeJSON(cleanup.reduce(0) { $0 + $1.size })],
        ]) { _, new in new }
        return out
    }

    private static func listFolder(_ args: [String: Any]) async throws -> Any {
        let (scan, node) = try await resolve(try requiredPath(args), refresh: args["refresh"] as? Bool ?? false)
        let depth = min(4, max(1, args["depth"] as? Int ?? 1))
        let limit = clamp(args["limit"], default: 25)
        func expand(_ n: FileNode, level: Int) -> [String: Any] {
            var j = nodeJSON(n, parentSize: n.parent?.allocatedSize ?? 0)
            if n.isDirectory && !n.isPackage && level < depth {
                j["children"] = n.children.prefix(limit).map { expand($0, level: level + 1) }
                if n.children.count > limit {
                    let rest = n.children.dropFirst(limit)
                    j["more"] = ["items": rest.count, "size": sizeJSON(rest.reduce(0) { $0 + $1.allocatedSize })]
                }
            }
            return j
        }
        var out = scan.json
        out["tree"] = expand(node, level: 0)
        return out
    }

    private static func largestFiles(_ args: [String: Any]) async throws -> Any {
        let (scan, node) = try await resolve(try requiredPath(args), refresh: args["refresh"] as? Bool ?? false)
        let limit = clamp(args["limit"], default: 25)
        var category: FileCategory?
        if let raw = args["category"] as? String {
            guard let c = FileCategory(rawValue: raw) else {
                throw ToolError.invalid("Unknown category '\(raw)'. Use one of: \(FileCategory.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            category = c
        }
        var items: [FileNode]
        if let category {
            items = []
            func visit(_ n: FileNode, inherited: FileCategory?) {
                let forced = n.category ?? inherited
                if n.isDirectory && !n.isPackage {
                    for c in n.children { visit(c, inherited: forced) }
                } else if (forced ?? FileCategory.forFile(named: n.name)) == category {
                    items.append(n)
                }
            }
            visit(node, inherited: inheritedCategory(of: node))
            items.sort { $0.allocatedSize > $1.allocatedSize }
            items = Array(items.prefix(limit))
        } else {
            items = node.largestItems(limit: limit)
        }
        var out = scan.json
        out["path"] = node.path
        if let category { out["category"] = category.rawValue }
        out["items"] = items.map { nodeJSON($0, parentSize: node.allocatedSize) }
        return out
    }

    private static func findCleanup(_ args: [String: Any]) async throws -> Any {
        let minimum = Int64((args["min_size_mb"] as? Double ?? 1) * 1_048_576)
        var candidates: [CleanupCandidate] = []
        var out: [String: Any] = [:]
        if let path = try optionalPath(args) {
            let (scan, node) = try await resolve(path, refresh: args["refresh"] as? Bool ?? false)
            candidates = CleanupFinder.candidates(in: node, minimumSize: max(minimum, 1))
            out = scan.json
        } else {
#if APP_STORE
            throw ToolError.invalid("The App Store build only scans folders you pass explicitly. Provide a path.")
#else
            for loc in CleanupFinder.knownLocations {
                if let (_, node) = try? await store.scan(loc.path), node.allocatedSize >= minimum {
                    candidates.append(CleanupCandidate(kind: loc.kind, node: node, contentsOnly: true))
                }
            }
            candidates.sort { $0.size > $1.size }
#endif
        }
        out["total_reclaimable"] = sizeJSON(candidates.reduce(0) { $0 + $1.size })
        out["candidates"] = candidates.map { c -> [String: Any] in
            [
                "path": c.path,
                "kind": c.kind.rawValue,
                "size": c.size.humanBytes,
                "bytes": c.size,
                "contents_only": c.contentsOnly,
                "note": c.kind.note,
                "safety": safetyJSON(SafetyKB.info(for: c.node)),
            ]
        }
        return out
    }

    private static func explainPath(_ args: [String: Any]) async throws -> Any {
        let path = try requiredPath(args)
        // Prefer a node from a scanned tree: it carries sizes and real ancestors.
        if let (_, node) = await cached(path) {
            var out = safetyJSON(SafetyKB.info(for: node))
            out.merge(nodeJSON(node, parentSize: 0)) { old, _ in old }
            return out
        }
        let nodes = chain(to: path)
        guard let node = nodes.last else { throw ToolError.invalid("No such file or folder: \(path)") }
        var out = withExtendedLifetime(nodes) { safetyJSON(SafetyKB.info(for: node)) }
        out["path"] = node.path
        out["kind"] = kind(of: node)
        return out
    }

    private static func findDuplicates(_ args: [String: Any]) async throws -> Any {
        let path = try requiredPath(args)
        let refresh = args["refresh"] as? Bool ?? false
        let limit = clamp(args["limit"], default: 20)
        let minimumMB = args["min_size_mb"] as? Double

        var result: DuplicateScanResult?
        var source = "computed"
        if !refresh && minimumMB == nil {
            result = await MainActor.run { () -> DuplicateScanResult? in
                guard let app, app.root?.path == path else { return nil }
                return app.duplicates
            }
            if result != nil { source = "headroom_app" }
        }
        if result == nil {
            let (_, node) = try await resolve(path, refresh: refresh)
            // When the window shows this folder, search there so the user sees progress and results.
            if minimumMB == nil, let window = await MainActor.run(body: { app?.root === node ? app : nil }) {
                guard let r = await window.findDuplicatesAndWait() else {
                    throw ToolError.invalid("The duplicate search was cancelled in Headroom.")
                }
                result = r
                source = "headroom_app"
            } else {
                var options = DuplicateOptions()
                if let mb = minimumMB { options.minimumSize = max(1, Int64(mb * 1_048_576)) }
                result = try await DuplicateFinder(counters: DuplicateCounters(), options: options).find(in: node)
            }
        }
        let r = result ?? DuplicateScanResult()
        return [
            "source": source,
            "files_considered": r.filesConsidered,
            "groups": r.groups.count,
            "total_wasted": sizeJSON(r.wasted),
            "top_groups": r.groups.prefix(limit).map { g -> [String: Any] in
                [
                    "size_each": g.size.humanBytes,
                    "copies": g.count,
                    "wasted": g.wasted.humanBytes,
                    "files_newest_first": g.files.map(\.path),
                ]
            },
        ]
    }

    private static func openInHeadroom(_ args: [String: Any]) async throws -> Any {
        let path = try requiredPath(args)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError.invalid("Not a folder: \(path)")
        }
        let opened = await MainActor.run { () -> Bool in
            guard let app else { return false }
            if app.root?.path != path || app.phase != .done { app.scan(URL(fileURLWithPath: path)) }
            AppWindows.showMain()
            return true
        }
        guard opened else { throw ToolError.invalid("The Headroom app is not running. Ask the user to open it.") }
        return ["opened": path]
    }

    private static func moveToTrash(_ args: [String: Any]) async throws -> Any {
        guard let raw = args["paths"] as? [String], !raw.isEmpty else { throw ToolError.invalid("'paths' must be a non-empty array of paths.") }
        var appNodes: [FileNode] = []
        var otherNodes: [FileNode] = []
        var refused: [[String: Any]] = []
        let appRoot = await MainActor.run { app?.phase == .done ? app?.root : nil }

        for p in raw.map(expand) {
            if let reason = refusal(for: p) {
                refused.append(["path": p, "reason": reason])
                continue
            }
            let hit = await cached(p)
            let chainNodes = chain(to: p)
            guard hit != nil || !chainNodes.isEmpty else {
                refused.append(["path": p, "reason": "No such file or folder"])
                continue
            }
            // Judge before measuring: scanned nodes know their real ancestors, otherwise use the path chain.
            let safety = hit.map { SafetyKB.info(for: $0.node) }
                ?? withExtendedLifetime(chainNodes) { chainNodes.last.map(SafetyKB.info(for:)) ?? .unknown }
            if safety.level == .never {
                refused.append(["path": p, "reason": "Headroom marks this 'Do not delete': \(safety.advice)"])
                continue
            }
            // A measured node, so the response reports what was freed.
            var measured = hit?.node
            if measured == nil { measured = try? await store.scan(p).node }
            guard let node = measured else {
                refused.append(["path": p, "reason": "Could not read it"])
                continue
            }
            if let appRoot, root(of: node) === appRoot { appNodes.append(node) } else { otherNodes.append(node) }
        }

        var result = DeleteResult()
        if !appNodes.isEmpty {
            // Through the app, so its tree, totals and duplicate list update in place.
            let nodes = appNodes
            let task = await MainActor.run { () -> Task<DeleteResult?, Never>? in
                guard let app else { return nil }
                return Task { await app.delete(nodes, mode: .trash, silent: true) }
            }
            if let r = await task?.value {
                merge(r, into: &result)
            } else {
                otherNodes += appNodes   // app busy deleting or gone: fall back to the engine
            }
        }
        if !otherNodes.isEmpty {
            let r = await Deleter(mode: .trash, counters: DeleteCounters()).delete(otherNodes)
            merge(r, into: &result)
            let failed = Set(r.errors.map(\.path))
            await store.forget(otherNodes.filter { !failed.contains($0.path) })
        }
        let failed = Set(result.errors.map(\.path))
        return [
            "moved_to_trash": (appNodes + otherNodes).map(\.path).filter { !failed.contains($0) },
            "freed": sizeJSON(result.freedBytes),
            "note": "Disk space is freed once the Trash is emptied.",
            "errors": result.errors.map { ["path": $0.path, "message": $0.message] },
            "refused": refused,
        ]
    }

    private static func merge(_ r: DeleteResult, into result: inout DeleteResult) {
        result.removedFiles += r.removedFiles
        result.removedDirectories += r.removedDirectories
        result.freedBytes += r.freedBytes
        result.errors += r.errors
    }

    // MARK: Trees

    /// A scanned tree and where it came from.
    struct Scan {
        let root: FileNode
        let scannedAt: Date
        let duration: TimeInterval
        let unreadable: Int
        let source: String      // "headroom_app" or "mcp"

        var json: [String: Any] {
            ["scan": ["root": root.path, "source": source, "scanned_at": MCPServer.date(scannedAt),
                      "seconds": MCPServer.decimal(duration), "unreadable": unreadable]]
        }
    }

    /// Finds `path` in the folder open in the app or in a cached scan, scanning only if needed.
    static func resolve(_ path: String, refresh: Bool) async throws -> (scan: Scan, node: FileNode) {
        if !refresh, let hit = await cached(path) { return hit }
        var st = stat()
        guard lstat(path, &st) == 0 else { throw ToolError.invalid("No such file or folder: \(path)") }
        if (st.st_mode & S_IFMT) == S_IFDIR, let shown = await scanInApp(path, refresh: refresh) { return shown }
        return try await store.scan(path)
    }

    /// Scans `path` in the Headroom window when that doesn't take over something the user is
    /// looking at: the window is empty, already scanning `path`, or showing `path` and asked to refresh.
    /// Returns nil (scan privately instead) when the window is busy with another folder.
    private static func scanInApp(_ path: String, refresh: Bool) async -> (scan: Scan, node: FileNode)? {
        let window = await MainActor.run { () -> AppState? in
            guard let app else { return nil }
            if app.isScanning { return app.rootURL?.path == path ? app : nil }
            guard app.root == nil || (refresh && app.root?.path == path) else { return nil }
            app.scan(URL(fileURLWithPath: path))
            return app
        }
        guard let window, let root = await window.waitForScan(), root.path == path else { return nil }
        return await cached(path)
    }

    /// `path` inside an already scanned tree, without scanning.
    static func cached(_ path: String) async -> (scan: Scan, node: FileNode)? {
        let appScan = await MainActor.run { () -> Scan? in
            guard let app, app.phase == .done, let root = app.root else { return nil }
            return Scan(root: root, scannedAt: app.progress.finished ?? Date(), duration: app.progress.elapsed,
                        unreadable: app.progress.errors, source: "headroom_app")
        }
        if let appScan, let node = find(path, in: appScan.root) { return (appScan, node) }
        return await store.lookup(path)
    }

    /// Walks down from `root` along the components of `path`.
    static func find(_ path: String, in root: FileNode) -> FileNode? {
        if path == root.path { return root }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var node = root
        for comp in path.dropFirst(prefix.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == comp }) else { return nil }
            node = next
        }
        return node
    }

    private static func root(of node: FileNode) -> FileNode {
        var n = node
        while let p = n.parent { n = p }
        return n
    }

    private static func inheritedCategory(of node: FileNode) -> FileCategory? {
        var p = node.parent
        while let n = p {
            if let c = n.category { return c }
            p = n.parent
        }
        return nil
    }

    /// Builds parent-linked nodes from / down to `path` without scanning, so the safety rules
    /// can inherit from known ancestors (a file deep inside ~/Library/Caches is still "safe").
    /// Returned root first; keep the array alive while using the leaf (`FileNode.parent` is weak).
    static func chain(to path: String) -> [FileNode] {
        var st = stat()
        guard lstat(path, &st) == 0 else { return [] }
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        var parent: FileNode?
        var url = URL(fileURLWithPath: "/")
        var nodes: [FileNode] = []
        for (i, comp) in components.enumerated() {
            if i > 0 { url.appendPathComponent(comp) }
            let isLast = i == components.count - 1
            let isDir = isLast ? (st.st_mode & S_IFMT) == S_IFDIR : true
            let isPackage = isDir && NSWorkspace.shared.isFilePackage(atPath: url.path)
            let node = FileNode(
                url: url, name: comp, isDirectory: isDir, isSymlink: isLast && (st.st_mode & S_IFMT) == S_IFLNK,
                isPackage: isPackage,
                allocatedSize: isLast && !isDir ? Int64(st.st_blocks) * 512 : 0,
                logicalSize: isLast && !isDir ? Int64(st.st_size) : 0,
                modified: nil, category: nil, parent: parent
            )
            nodes.append(node)
            parent = node
        }
        return nodes
    }

    // MARK: Arguments

    /// Paths that are never deleted through MCP, whatever the rules say.
    static func refusal(for path: String) -> String? {
        let home = NSHomeDirectory()
        let protected = ["/", home, "/System", "/Library", "/Applications", "/Users", "/private", "/usr", "/bin", "/sbin", "/etc", "/var", "/opt",
                         home + "/Library", home + "/Documents", home + "/Desktop", home + "/Downloads", home + "/Pictures", home + "/Movies", home + "/Music"]
        let reason = "Top-level system or home folder"
        if protected.contains(path) { return reason }
        // The same folder has many names: APFS ignores case by default (~/DOCUMENTS), and a path
        // can go through a symlink. Compare what the path names, not how it is spelled.
        guard let target = identity(of: path) else { return nil }
        return protected.contains { identity(of: $0).map { $0 == target } ?? false } ? reason : nil
    }

    /// Device and inode of what `path` names, following symlinks.
    private static func identity(of path: String) -> (dev_t, ino_t)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return (st.st_dev, st.st_ino)
    }

    private static func requiredPath(_ args: [String: Any]) throws -> String {
        guard let path = try optionalPath(args) else { throw ToolError.invalid("'path' is required.") }
        return path
    }

    private static func optionalPath(_ args: [String: Any]) throws -> String? {
        guard let raw = args["path"] else { return nil }
        guard let s = raw as? String, !s.isEmpty else { throw ToolError.invalid("'path' must be a non-empty string.") }
        return expand(s)
    }

    static func expand(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private static func clamp(_ value: Any?, default fallback: Int) -> Int {
        min(500, max(1, (value as? Int) ?? fallback))
    }

    // MARK: JSON shapes

    /// One decimal, serialized exactly ("49.9", not "49.899999999999999").
    static func decimal(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value))
    }

    private static func percent(_ fraction: Double) -> NSDecimalNumber { decimal(fraction * 100) }

    private static func sizeJSON(_ bytes: Int64) -> [String: Any] {
        ["human": bytes.humanBytes, "bytes": bytes]
    }

    private static func signedSizeJSON(_ bytes: Int64) -> [String: Any] {
        ["human": (bytes >= 0 ? "+" : "−") + abs(bytes).humanBytes, "bytes": bytes]
    }

    static func date(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
    }

    private static func kind(of n: FileNode) -> String {
        n.isPackage ? "bundle" : (n.isDirectory ? "folder" : "file")
    }

    private static func nodeJSON(_ n: FileNode, parentSize: Int64) -> [String: Any] {
        var out: [String: Any] = [
            "path": n.path,
            "size": n.allocatedSize.humanBytes,
            "bytes": n.allocatedSize,
            "kind": kind(of: n),
            "category": n.effectiveCategory.rawValue,
        ]
        if n.isDirectory { out["files"] = n.fileCount }
        if let m = n.modified { out["modified"] = date(m) }
        if parentSize > 0 { out["percent"] = percent(Double(n.allocatedSize) / Double(parentSize)) }
        return out
    }

    private static func safetyJSON(_ s: SafetyInfo) -> [String: Any] {
        let level: String
        switch s.level {
        case .safe: level = "safe"
        case .usuallySafe: level = "usually_safe"
        case .caution: level = "caution"
        case .never: level = "never"
        case .unknown: level = "unknown"
        }
        return ["level": level, "verdict": s.level.title, "what": s.what, "advice": s.advice, "rule": s.source]
    }
}

/// Trees scanned for agents. Keeps the two most recent roots so a session of calls on one
/// folder (overview, drill-down, cleanup, duplicates) scans it once.
actor ScanStore {
    private var scans: [MCPServer.Scan] = []
    private let capacity = 2

    func lookup(_ path: String) -> (scan: MCPServer.Scan, node: FileNode)? {
        for s in scans {
            if let node = MCPServer.find(path, in: s.root) { return (s, node) }
        }
        return nil
    }

    func scan(_ path: String) async throws -> (scan: MCPServer.Scan, node: FileNode) {
        let counters = ScanCounters()
        let started = Date()
        let root = try await DiskScanner(counters: counters, options: ScanOptions()).scan(root: URL(fileURLWithPath: path))
        let scan = MCPServer.Scan(root: root, scannedAt: Date(), duration: Date().timeIntervalSince(started),
                                  unreadable: counters.snapshot.errors, source: "mcp")
        // The new tree replaces cached trees it overlaps with.
        scans.removeAll { MCPServer.find(path, in: $0.root) != nil || MCPServer.find($0.root.path, in: root) != nil }
        scans.insert(scan, at: 0)
        if scans.count > capacity { scans.removeLast(scans.count - capacity) }
        return (scan, root)
    }

    /// Drops trashed nodes from cached trees so later answers stay correct.
    func forget(_ nodes: [FileNode]) {
        for n in nodes { n.parent?.removeChild(n) }
        scans.removeAll { s in nodes.contains { $0 === s.root } }
    }
}
