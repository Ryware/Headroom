import Foundation

/// `Headroom <command> [path] [options]`: the MCP tools as shell commands, for agents and
/// scripts that can run a terminal. Options come from each tool's input schema, so the CLI and
/// the MCP server never drift apart. Like `--mcp`, calls go to the running app when there is
/// one (same scan as the window) and are handled in-process otherwise. Output is JSON.
enum HeadroomCLI {
    /// Command name → MCP tool name, in the order `help` lists them.
    static let commands: KeyValuePairs<String, String> = [
        "status": "disk_status",
        "state": "headroom_state",
        "scan": "scan_folder",
        "list": "list_folder",
        "largest": "largest_files",
        "cleanup": "find_cleanup",
        "explain": "explain_path",
        "duplicates": "find_duplicates",
        "open": "open_in_headroom",
        "trash": "move_to_trash",
    ]

    /// How the user (or agent) ran the binary, so help shows commands they can paste back.
    static var program: String {
        let p = CommandLine.arguments.first ?? "Headroom"
        return p.contains(" ") ? "'" + p.replacingOccurrences(of: "'", with: #"'\''"#) + "'" : p
    }

    /// Whether `argv` (without the program name) asks for the CLI rather than the app.
    /// Any word does, so a mistyped command prints an error instead of opening the window and
    /// blocking the caller's shell. Finder and Xcode only ever pass flags (`-NSDocumentRevisionsDebugMode YES`).
    static func handles(_ argv: [String]) -> Bool {
        guard let first = argv.first else { return false }
        return ["--help", "-h", "--version"].contains(first) || !first.hasPrefix("-")
    }

    static func run(_ argv: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task.detached {
            let code = await execute(argv)
            exit(code)
        }
        // Keep the main queue running: moving to the Trash goes through NSWorkspace on main.
        dispatchMain()
    }

    static func execute(_ argv: [String]) async -> Int32 {
        guard let first = argv.first else { print(usage); return 0 }
        switch first {
        case "help", "--help", "-h":
            if let name = argv.dropFirst().first {
                guard let t = tool(named: name) else { return fail("Unknown command '\(name)'. Run '\(program) help'.") }
                print(help(for: name, t))
            } else {
                print(usage)
            }
            return 0
        case "--version":
            print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
            return 0
        default:
            break
        }
        guard let t = tool(named: first), let toolName = t["name"] as? String else {
            return fail("Unknown command '\(first)'. Run '\(program) help'.")
        }
        let rest = Array(argv.dropFirst())
        if rest.contains("--help") || rest.contains("-h") { print(help(for: first, t)); return 0 }
        let args: [String: Any]
        do { args = try arguments(for: t, rest) } catch { return fail("\(error)") }
        if toolName == "move_to_trash" && !rest.contains("--yes") {
            return fail("'trash' moves items to the Trash. Ask the user first, then repeat the command with --yes.")
        }
        return await call(toolName, args)
    }

    // MARK: Calling the tool

    private static func call(_ name: String, _ args: [String: Any]) async -> Int32 {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": name, "arguments": args]]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return fail("Cannot encode the request.") }
        let response: Data?
        switch await MCPHTTPServer.forward(data) {
        case .handled(let r): response = r
        case .unavailable: response = await MCPServer.handle(data)
        }
        guard let response, let reply = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            return fail("No response from Headroom.")
        }
        if let error = reply["error"] as? [String: Any] { return fail(error["message"] as? String ?? "Error") }
        let result = reply["result"] as? [String: Any] ?? [:]
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        if result["isError"] as? Bool == true { return fail(text) }
        print(text)
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("headroom: \(message)\n".utf8))
        return 1
    }

    // MARK: Arguments

    struct UsageError: Error, CustomStringConvertible { let description: String }

    static func tool(named command: String) -> [String: Any]? {
        let name = commands.first { $0.key == command }?.value ?? command
        return MCPServer.tools.first { $0["name"] as? String == name }
    }

    private static func properties(of tool: [String: Any]) -> [String: [String: Any]] {
        (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: [String: Any]] ?? [:]
    }

    /// Turns `[path…] [--name value] [--flag]` into tool arguments, typed by the tool's schema.
    /// `--min-size-mb 10` sets `min_size_mb`; `--refresh` sets a boolean; `--yes` is the CLI's own.
    static func arguments(for tool: [String: Any], _ argv: [String]) throws -> [String: Any] {
        let props = properties(of: tool)
        var args: [String: Any] = [:]
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            i += 1
            guard arg.hasPrefix("--") else {
                if props["paths"] != nil {
                    args["paths", default: [String]()] = (args["paths"] as? [String] ?? []) + [arg]
                } else if props["path"] != nil, args["path"] == nil {
                    args["path"] = arg
                } else {
                    throw UsageError(description: "Unexpected argument '\(arg)'.")
                }
                continue
            }
            if arg == "--yes" { continue }
            var name = String(arg.dropFirst(2))
            var inline: String?
            if let eq = name.firstIndex(of: "=") {
                inline = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            let key = name.replacingOccurrences(of: "-", with: "_")
            guard let schema = props[key], key != "paths" else {
                throw UsageError(description: "Unknown option '--\(name)'.")
            }
            let type = schema["type"] as? String ?? "string"
            if type == "boolean" {
                args[key] = inline.map { !["false", "0", "no"].contains($0.lowercased()) } ?? true
                continue
            }
            guard let value = inline ?? (i < argv.count ? argv[i] : nil) else {
                throw UsageError(description: "Option '--\(name)' needs a value.")
            }
            if inline == nil { i += 1 }
            switch type {
            case "integer":
                guard let n = Int(value) else { throw UsageError(description: "'--\(name)' expects a whole number.") }
                args[key] = n
            case "number":
                guard let n = Double(value) else { throw UsageError(description: "'--\(name)' expects a number.") }
                args[key] = n
            default:
                if let allowed = schema["enum"] as? [String], !allowed.contains(value) {
                    throw UsageError(description: "'--\(name)' must be one of: \(allowed.joined(separator: ", ")).")
                }
                args[key] = value
            }
        }
        return args
    }

    // MARK: Help

    static var usage: String {
        var lines = [
            "Headroom: disk usage on this Mac, with safety advice for every item. Output is JSON.",
            "While the app is open, commands use the folder shown in its window; otherwise they scan on their own.",
            "",
            "Usage: \(program) <command> [path] [options]",
            "",
            "Commands:",
        ]
        for (command, toolName) in commands {
            guard let t = tool(named: toolName) else { continue }
            let usage = "\(command) \(positional(of: t))".trimmingCharacters(in: .whitespaces)
            lines.append("  " + usage.padding(toLength: 20, withPad: " ", startingAt: 0) + firstSentence(t["description"] as? String ?? ""))
        }
        lines += [
            "",
            "Run '\(program) help <command>' for its options. Start with 'status' and 'state'.",
            "Check 'explain <path>' before deleting anything. 'trash' needs --yes: ask the user first.",
        ]
        return lines.joined(separator: "\n")
    }

    static func help(for command: String, _ tool: [String: Any]) -> String {
        let props = properties(of: tool)
        let options = props.keys.filter { $0 != "path" && $0 != "paths" }.sorted()
        var lines = [
            "Usage: \(program) \(command) \(positional(of: tool))\(options.isEmpty ? "" : " [options]")".trimmingCharacters(in: .whitespaces),
            "",
            tool["description"] as? String ?? "",
        ]
        if let path = props["path"] ?? props["paths"], let d = path["description"] as? String {
            lines += ["", "  " + positional(of: tool).padding(toLength: 22, withPad: " ", startingAt: 0) + d]
        }
        if !options.isEmpty { lines += ["", "Options:"] }
        for key in options {
            let schema = props[key] ?? [:]
            let flag = "--" + key.replacingOccurrences(of: "_", with: "-")
            let value: String
            switch schema["type"] as? String {
            case "boolean": value = ""
            case "integer", "number": value = " <n>"
            default: value = (schema["enum"] as? [String]).map { " <\($0.joined(separator: "|"))>" } ?? " <value>"
            }
            lines.append("  " + (flag + value).padding(toLength: 22, withPad: " ", startingAt: 0) + (schema["description"] as? String ?? ""))
        }
        if tool["name"] as? String == "move_to_trash" {
            lines += ["  --yes                 Required. Confirms the user agreed to move these items to the Trash."]
        }
        return lines.joined(separator: "\n")
    }

    private static func positional(of tool: [String: Any]) -> String {
        let props = properties(of: tool)
        let required = (tool["inputSchema"] as? [String: Any])?["required"] as? [String] ?? []
        if props["paths"] != nil { return "<path>..." }
        if props["path"] != nil { return required.contains("path") ? "<path>" : "[path]" }
        return ""
    }

    private static func firstSentence(_ s: String) -> String {
        guard let end = s.range(of: #"\. (?=[A-Z])"#, options: .regularExpression) else { return s }
        return String(s[..<end.lowerBound]) + "."
    }
}
