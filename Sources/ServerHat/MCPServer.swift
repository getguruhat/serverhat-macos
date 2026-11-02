import Foundation

/// `ServerHat --mcp`: a Model Context Protocol server on stdin/stdout, so Claude Code,
/// Codex and other MCP clients get ServerHat as tools. It drives the running app through
/// the local API (opening the app if it isn't running) and reads the API token itself,
/// so the token never appears in an MCP config or a chat.
enum MCPServer {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
                continue
            }
            handle(message)
        }
        exit(0)
    }

    // MARK: JSON-RPC

    private static func handle(_ message: [String: Any]) {
        // Responses to requests we never send, and notifications such as
        // notifications/initialized, need no answer.
        guard let method = message["method"] as? String, let id = message["id"] else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            reply(id, [
                "protocolVersion": supportedVersions.contains(requested) ? requested : supportedVersions[0],
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "serverhat", "title": "ServerHat", "version": appVersion],
                "instructions": """
                    ServerHat runs the user's local web servers from the Mac menu bar. Use these tools instead \
                    of starting dev servers in your own shell, so they keep running after your session and the \
                    user can control them. List servers before adding one, and don't stop or remove servers the \
                    user didn't mention. New or changed commands require the user's approval in ServerHat. \
                    If a start is actually blocked for approval, tell the user once with the exact command \
                    and folder shown in the error. The notification opens a review with Allow, Remove and \
                    Later choices. Don't repeat generic approval warnings.
                    """,
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            reply(id, call(name, args))
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found: \(method)"]])
        }
    }

    private static func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    // MARK: Tools

    private static let serverFields: [String: Any] = [
        "name": ["type": "string", "description": "What the menu shows."],
        "cwd": ["type": "string", "description": "Absolute folder the command runs in. ~ works."],
        "command": ["type": "string", "description": "A program on the login shell's PATH (node, npm, python3) or a path to one. Run directly, not through a shell: no pipes, && or cd. For shell syntax use /bin/zsh with args [\"-lc\", \"…\"]."],
        "args": ["type": "array", "items": ["type": "string"], "description": "Arguments, one string each."],
        "port": ["type": "integer", "description": "The port the server really listens on, so ServerHat can tell when it's up."],
        "url": ["type": "string", "description": "What Open in browser opens. Defaults to http://127.0.0.1:<port>."],
        "healthContains": ["type": "string", "description": "Optional text that must appear in the loopback HTTP response before the app is considered ready."],
        "env": ["type": "object", "additionalProperties": ["type": "string"], "description": "Extra environment variables."],
        "startAtLogin": ["type": "boolean", "description": "Start this server whenever ServerHat starts."],
        "restartOnCrash": ["type": "boolean", "description": "Retry after an unexpected non-zero exit."],
        "restartLimit": ["type": "integer", "description": "Maximum automatic retries, 1–10. Default 3."],
    ]

    private static func tool(_ name: String, _ title: String, _ description: String, properties: [String: Any] = [:],
                             required: [String] = [], readOnly: Bool = false, destructive: Bool = false) -> [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
            "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive, "openWorldHint": false],
        ]
    }

    private static let idProperty: [String: Any] = ["id": ["type": "string", "description": "The server's id, from list_servers."]]

    static let tools: [[String: Any]] = [
        tool("list_servers", "List servers",
             "Every server in ServerHat with its settings and status (stopped, starting, running, unhealthy, stopping, crashed, port-in-use or failed). Check this before adding a server.",
             readOnly: true),
        tool("get_server", "Get server", "One server's settings and status.",
             properties: idProperty, required: ["id"], readOnly: true),
        tool("start_server", "Start server",
             "Start a server and wait until it's ready or has failed. If approval is required, the error names the command and folder; report that specific prompt once. If startup fails, the answer includes recent output.",
             properties: idProperty.merging(["wait": ["type": "integer", "description": "Seconds to wait, up to 60. Default 30."]]) { a, _ in a },
             required: ["id"]),
        tool("stop_server", "Stop server", "Stop a server (and whatever it started).",
             properties: idProperty, required: ["id"], destructive: true),
        tool("restart_server", "Restart server",
             "Stop a server and start it again, for example after changing its settings. Waits until it's ready or has failed. If approval is required, report the specific command and folder once.",
             properties: idProperty.merging(["wait": ["type": "integer", "description": "Seconds to wait, up to 60. Default 30."]]) { a, _ in a },
             required: ["id"]),
        tool("get_logs", "Get logs", "The last lines a server printed. Use them to diagnose a crash or an unhealthy app.",
             properties: idProperty.merging(["lines": ["type": "integer", "description": "How many lines, up to 1000. Default 100."]]) { a, _ in a },
             required: ["id"], readOnly: true),
        tool("add_server", "Add server",
             "Add a server to ServerHat. If start is true and approval is needed, the user gets one notification showing the command and folder; clicking it opens Allow/Remove/Later choices.",
             properties: serverFields.merging([
                "id": ["type": "string", "description": "Short unique id. Made from name if left out."],
                "start": ["type": "boolean", "description": "Start it after adding and wait until it's running."],
             ]) { a, _ in a },
             required: ["name", "command", "cwd"]),
        tool("update_server", "Update server",
             "Change some of a server's settings. Only the fields you send change; null clears port or url. Restart the server afterwards to use them. Changing command, args, cwd or env needs the user's approval again.",
             properties: serverFields.merging(idProperty) { a, _ in a }, required: ["id"]),
        tool("remove_server", "Remove server",
             "Stop a server and remove it from ServerHat. Its folder isn't touched. Only do this when the user asks.",
             properties: idProperty, required: ["id"], destructive: true),
        tool("import_launch_json", "Import launch.json",
             "Add the servers in a project's .claude/launch.json. Ones already in ServerHat are skipped.",
             properties: ["path": ["type": "string", "description": "Absolute path to the project folder or its .claude/launch.json."]],
             required: ["path"]),
        tool("import_project", "Import project",
             "Suggest local web server commands from package.json dev/start scripts, a web Procfile entry, or Docker Compose. Import only when the user asks.",
             properties: ["path": ["type": "string", "description": "Absolute path to a project folder."]], required: ["path"]),
    ]

    private static func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
        do {
            let id = args["id"] as? String ?? ""
            let path = "/v1/servers/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? id)
            func seconds(_ key: String, _ fallback: Int, max: Int) -> String {
                String(min(max, Swift.max(0, (args[key] as? Int) ?? fallback)))
            }
            switch name {
            case "list_servers":
                return result(try API.shared.request("GET", "/v1/servers"))
            case "get_server":
                return result(try API.shared.request("GET", path))
            case "start_server", "restart_server":
                let action = name == "start_server" ? "start" : "restart"
                let answer = try API.shared.request("POST", path + "/" + action, query: ["wait": seconds("wait", 30, max: 60)])
                return result(withLogsIfFailed(answer, id: id))
            case "stop_server":
                return result(try API.shared.request("POST", path + "/stop", query: ["wait": "10"]))
            case "get_logs":
                return result(try API.shared.request("GET", path + "/logs", query: ["lines": seconds("lines", 100, max: 1000)]))
            case "add_server":
                var body = args
                let start = body.removeValue(forKey: "start") as? Bool ?? false
                let added = try API.shared.request("POST", "/v1/servers", body: body)
                guard start, added.ok, let newID = (added.json as? [String: Any])?["id"] as? String else { return result(added) }
                let started = try API.shared.request("POST", "/v1/servers/\(newID)/start", query: ["wait": "60"])
                return result(withLogsIfFailed(started, id: newID))
            case "update_server":
                var body = args
                body["id"] = nil
                return result(try API.shared.request("PATCH", path, body: body))
            case "remove_server":
                return result(try API.shared.request("DELETE", path))
            case "import_launch_json":
                return result(try API.shared.request("POST", "/v1/import", body: ["path": args["path"] as? String ?? ""]))
            case "import_project":
                return result(try API.shared.request("POST", "/v1/import-project", body: ["path": args["path"] as? String ?? ""]))
            default:
                return failure("unknown tool \(name)")
            }
        } catch {
            return failure(error.localizedDescription)
        }
    }

    /// Adds the server's recent output when it didn't come up, so the agent can fix it in one step.
    private static func withLogsIfFailed(_ answer: API.Answer, id: String) -> API.Answer {
        guard answer.ok, var object = answer.json as? [String: Any],
              let state = (object["status"] as? [String: Any])?["state"] as? String,
              ["crashed", "failed", "port-in-use", "unhealthy"].contains(state),
              let logs = try? API.shared.request("GET", "/v1/servers/\(id)/logs", query: ["lines": "40"]),
              let lines = (logs.json as? [String: Any])?["lines"] else { return answer }
        object["recentLogs"] = lines
        return API.Answer(status: answer.status, json: object)
    }

    private static func result(_ answer: API.Answer) -> [String: Any] {
        let object = answer.json ?? ["status": answer.status]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": !answer.ok]
    }

    private static func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }
}

// MARK: API client

/// Talks to the app's local API, opening ServerHat first if it isn't running.
private final class API {
    static let shared = API()

    struct Answer {
        var status: Int
        var json: Any?
        var ok: Bool { (200..<300).contains(status) }
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    private var base: URL?
    private var token = ""

    func request(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) throws -> Answer {
        if base == nil { try connect() }
        do {
            return try send(method, path, query: query, body: body)
        } catch {
            // ServerHat may have quit since the last call.
            try connect()
            return try send(method, path, query: query, body: body)
        }
    }

    private func send(_ method: String, _ path: String, query: [String: String], body: [String: Any]?) throws -> Answer {
        guard let base, var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw Failure(errorDescription: "ServerHat's API address is unknown")
        }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        // Up to 60 s waiting for approval, then up to 60 s for the server to come up.
        var request = URLRequest(url: components.url!, timeoutInterval: 135)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (status, data) = try API.perform(request)
        return Answer(status: status, json: data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data))
    }

    private func connect() throws {
        if !readInfoAndCheckHealth() {
            openApp()
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                if readInfoAndCheckHealth() { break }
            }
        }
        guard base != nil, !token.isEmpty else {
            throw Failure(errorDescription: "ServerHat isn't running and couldn't be opened. Ask the user to open ServerHat from Applications.")
        }
    }

    /// Reads api.json and the token file (both written by the app), then checks /v1/health.
    private func readInfoAndCheckHealth() -> Bool {
        var url = "http://127.0.0.1:\(APIServer.defaultPort)"
        var tokenFile = APIServer.tokenURL.path
        if let data = try? Data(contentsOf: APIServer.infoURL),
           let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            url = info["url"] as? String ?? url
            tokenFile = info["tokenFile"] as? String ?? tokenFile
        }
        guard let baseURL = URL(string: url),
              let health = try? API.perform(URLRequest(url: baseURL.appendingPathComponent("/v1/health"), timeoutInterval: 2)),
              health.0 == 200,
              let token = try? String(contentsOfFile: (tokenFile as NSString).expandingTildeInPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return false }
        base = baseURL
        self.token = token
        return true
    }

    /// Opens the ServerHat.app this binary belongs to, or the installed one, in the background.
    private func openApp() {
        let bundle = Bundle.main.bundleURL
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = bundle.pathExtension == "app" ? ["-g", bundle.path] : ["-g", "-b", "com.guruhat.serverhat"]
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        try? open.run()
        open.waitUntilExit()
    }

    private static func perform(_ request: URLRequest) throws -> (Int, Data) {
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<(Int, Data), Error> = .failure(Failure(errorDescription: "no answer from ServerHat"))
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                outcome = .failure(error)
            } else {
                outcome = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
            }
            done.signal()
        }.resume()
        done.wait()
        return try outcome.get()
    }
}
