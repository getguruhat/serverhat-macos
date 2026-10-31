import Foundation
import Network
import Security

/// A small JSON API on 127.0.0.1 so Claude Code, Codex and scripts can configure
/// and control ServerHat. See README.md › API.
///
/// Every request needs `Authorization: Bearer <token>`, where the token is in a file
/// only this user can read. Requests with another Host header (DNS rebinding) or
/// from a web page (an Origin or cross-site Sec-Fetch-Site header) are refused.
final class APIServer {
    static let defaultPort: UInt16 = 47317
    static let tokenURL = ConfigStore.folder.appendingPathComponent("api-token")
    static let infoURL = ConfigStore.folder.appendingPathComponent("api.json")
    private static let maxBody = 1 << 20

    let port: UInt16
    private(set) var problem: String?
    private let manager: ServerManager
    private let token: String
    private var listener: NWListener?

    var baseURL: String { "http://127.0.0.1:\(port)" }

    init(manager: ServerManager) {
        self.manager = manager
        let configured = UserDefaults.standard.integer(forKey: "apiPort")
        port = (1...65535).contains(configured) ? UInt16(configured) : APIServer.defaultPort
        token = APIServer.loadOrCreateToken()
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed(let error) = state {
                    self.problem = "API couldn't listen on 127.0.0.1:\(self.port): \(error.localizedDescription)"
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            writeInfo()
        } catch {
            problem = "API couldn't start: \(error.localizedDescription)"
        }
    }

    private func writeInfo() {
        let info: [String: Any] = [
            "url": baseURL,
            "tokenFile": APIServer.tokenURL.path,
            "configFile": ConfigStore.fileURL.path,
            "docs": "https://github.com/getguruhat/serverhat-macos#api",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: APIServer.infoURL, options: .atomic)
        }
    }

    private static func loadOrCreateToken() -> String {
        let fm = FileManager.default
        if let existing = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 32 {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        // Create it unreadable to others from the start rather than tightening it afterwards.
        try? fm.removeItem(at: tokenURL)
        fm.createFile(atPath: tokenURL.path, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600])
        return token
    }

    // MARK: HTTP

    private struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data
    }

    private struct Response {
        var status: Int
        var body: Any

        static func error(_ status: Int, _ message: String) -> Response { Response(status: status, body: ["error": message]) }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
        // Drop connections that never finish sending a request.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch APIServer.parse(buffer) {
            case .needMore where !isComplete && error == nil && buffer.count <= APIServer.maxBody + 65536:
                self.receive(connection, buffer: buffer)
            case .request(let request):
                self.handle(request) { self.send($0, on: connection) }
            case .bad(let message):
                self.send(.error(400, message), on: connection)
            default:
                self.send(.error(400, "incomplete or oversized request"), on: connection)
            }
        }
    }

    private enum Parse { case needMore, request(Request), bad(String) }

    private static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .needMore }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .bad("headers aren't UTF-8") }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3 else { return .bad("bad request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBody else { return .bad("bad Content-Length") }
        if headers["transfer-encoding"] != nil { return .bad("chunked bodies aren't supported; send Content-Length") }
        let body = data[end.upperBound...]
        guard body.count >= length else { return .needMore }

        let target = String(parts[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .request(Request(method: String(parts[0]).uppercased(), path: components?.percentEncodedPath ?? target,
                                query: query, headers: headers, body: Data(body.prefix(length))))
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let json = (try? JSONSerialization.data(withJSONObject: response.body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status).capitalized
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(json.count + 1)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(json)
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Checks

    private func refusal(for request: Request) -> Response? {
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.headers["host"]?.lowercased(), allowedHosts.contains(host) else {
            return .error(403, "Host must be 127.0.0.1:\(port)")
        }
        if request.headers["origin"] != nil {
            return .error(403, "requests from web pages aren't allowed")
        }
        if let site = request.headers["sec-fetch-site"]?.lowercased(), site != "none" {
            return .error(403, "requests from web pages aren't allowed")
        }
        if request.method == "OPTIONS" { return .error(403, "CORS isn't supported") }
        if request.path == "/v1/health" { return nil }
        guard let auth = request.headers["authorization"], auth.hasPrefix("Bearer "),
              APIServer.constantTimeEqual(String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces), token) else {
            return .error(401, "missing or wrong token; send Authorization: Bearer $(cat \(APIServer.tokenURL.path.replacingOccurrences(of: " ", with: "\\ ")))")
        }
        if ["POST", "PUT", "PATCH"].contains(request.method), !request.body.isEmpty,
           !(request.headers["content-type"]?.lowercased().hasPrefix("application/json") ?? false) {
            return .error(415, "send JSON with Content-Type: application/json")
        }
        return nil
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: Routes

    private func handle(_ request: Request, reply: @escaping (Response) -> Void) {
        if let refusal = refusal(for: request) { return reply(refusal) }
        let segments = request.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard segments.first == "v1" else { return reply(.error(404, "unknown path; the API lives under /v1")) }
        let route = Array(segments.dropFirst())
        do {
            switch (request.method, route.count) {
            case ("GET", 1) where route[0] == "health":
                reply(Response(status: 200, body: ["ok": true, "app": "ServerHat"]))
            case ("GET", 1) where route[0] == "servers":
                reply(Response(status: 200, body: ["servers": manager.servers.map(describe), "configFile": ConfigStore.fileURL.path,
                                                   "configError": manager.configError as Any? ?? NSNull()]))
            case ("POST", 1) where route[0] == "servers":
                var config = try decodeServer(from: try jsonObject(request.body))
                if config.id.isEmpty { config.id = ServerConfig.slug(config.name) }
                let added = try manager.add(config)
                reply(Response(status: 201, body: describe(added)))
            case ("POST", 1) where route[0] == "import":
                let body = try jsonObject(request.body)
                guard let path = body["path"] as? String else { throw ManagerError(message: "send {\"path\": \"/folder/with/.claude/launch.json\"}") }
                let added = try manager.importLaunchJSON(at: path)
                reply(Response(status: 200, body: ["added": added.map(describe)]))
            case ("POST", 1) where route[0] == "start-all":
                manager.startAll()
                reply(Response(status: 200, body: ["servers": manager.servers.map(describe)]))
            case ("POST", 1) where route[0] == "stop-all":
                manager.stopAll()
                reply(Response(status: 200, body: ["servers": manager.servers.map(describe)]))
            case ("POST", 1) where route[0] == "reload":
                manager.reloadConfig()
                reply(Response(status: 200, body: ["servers": manager.servers.map(describe),
                                                   "configError": manager.configError as Any? ?? NSNull()]))
            case (_, 2) where route[0] == "servers":
                try handleServer(route[1], request: request, reply: reply)
            case ("GET", 3) where route[0] == "servers" && route[2] == "logs":
                let id = route[1]
                guard manager.server(id) != nil else { throw ManagerError(message: "no server \"\(id)\"", status: 404) }
                let count = min(5000, Int(request.query["lines"] ?? "") ?? 200)
                let log = manager.log(id)
                reply(Response(status: 200, body: ["id": id, "lines": log.tail(count), "file": log.fileURL.path]))
            case ("POST", 3) where route[0] == "servers" && ["start", "stop", "restart"].contains(route[2]):
                let id = route[1]
                guard manager.server(id) != nil else { throw ManagerError(message: "no server \"\(id)\"", status: 404) }
                let wait = min(60, Double(request.query["wait"] ?? "") ?? 0)
                if route[2] != "stop" && manager.needsApproval(id) && wait > 0 {
                    // Give the user the wait time to click Allow, then go ahead (or explain).
                    manager.askForApproval(id)
                    waitForApproval(id, seconds: wait) { [weak self] in self?.control(id, route[2], wait: wait, reply: reply) }
                } else {
                    control(id, route[2], wait: wait, reply: reply)
                }
            default:
                reply(.error(404, "no route for \(request.method) \(request.path)"))
            }
        } catch let error as ManagerError {
            reply(.error(error.status, error.message))
        } catch {
            reply(.error(400, ConfigStore.describe(error)))
        }
    }

    private func handleServer(_ id: String, request: Request, reply: (Response) -> Void) throws {
        guard let current = manager.server(id) else { throw ManagerError(message: "no server \"\(id)\"", status: 404) }
        switch request.method {
        case "GET":
            reply(Response(status: 200, body: describe(current)))
        case "PATCH", "PUT":
            let body = try jsonObject(request.body)
            if let newID = body["id"] as? String, newID != id { throw ManagerError(message: "id can't be changed; remove and add instead") }
            var merged: [String: Any]
            if request.method == "PATCH" {
                merged = try configDictionary(current)
                // null clears an optional setting such as "port" or "url".
                for (key, value) in body { if value is NSNull { merged[key] = nil } else { merged[key] = value } }
            } else {
                merged = body
            }
            merged["id"] = id
            let updated = try manager.update(id, to: try decodeServer(from: merged))
            var description = describe(updated)
            if manager.state(id).pid != nil, updated != current { description["note"] = "restart the server to use the new settings" }
            reply(Response(status: 200, body: description))
        case "DELETE":
            try manager.remove(id)
            reply(Response(status: 200, body: ["removed": id]))
        default:
            reply(.error(405, "use GET, PATCH, PUT or DELETE"))
        }
    }

    private func control(_ id: String, _ action: String, wait: Double, reply: @escaping (Response) -> Void) {
        do {
            switch action {
            case "start": try manager.start(id)
            case "stop": manager.stop(id)
            default: try manager.restart(id)
            }
        } catch let error as ManagerError {
            return reply(.error(error.status, error.message))
        } catch {
            return reply(.error(400, error.localizedDescription))
        }
        waitUntilSettled(id, seconds: wait) { [weak self] in
            guard let self, let server = self.manager.server(id) else { return reply(.error(404, "no server \"\(id)\"")) }
            reply(Response(status: 200, body: self.describe(server)))
        }
    }

    /// Calls back once the user has allowed the server (or it's gone), or after `seconds`.
    private func waitForApproval(_ id: String, seconds: Double, then done: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(seconds)
        func check() {
            if Date() >= deadline || !manager.needsApproval(id) { return done() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: check)
        }
        check()
    }

    /// Calls back once the server is no longer starting or stopping, or after `seconds`.
    private func waitUntilSettled(_ id: String, seconds: Double, then done: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(seconds)
        func check() {
            let status = manager.state(id).status
            if Date() >= deadline || ![.starting, .stopping].contains(status) { return done() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: check)
        }
        // A restart passes through "stopped" before starting again.
        DispatchQueue.main.asyncAfter(deadline: .now() + (seconds > 0 ? 0.5 : 0), execute: check)
    }

    // MARK: JSON

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManagerError(message: "body must be a JSON object")
        }
        return object
    }

    private func decodeServer(from object: [String: Any]) throws -> ServerConfig {
        var object = object
        object["status"] = nil
        object["log"] = nil
        object["note"] = nil
        if object["id"] == nil { object["id"] = "" }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(ServerConfig.self, from: data)
    }

    private func configDictionary(_ server: ServerConfig) throws -> [String: Any] {
        let data = try JSONEncoder().encode(server)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func describe(_ server: ServerConfig) -> [String: Any] {
        var object = (try? configDictionary(server)) ?? ["id": server.id]
        let state = manager.state(server.id)
        var status: [String: Any] = ["state": state.status.rawValue]
        if let detail = state.detail { status["detail"] = detail }
        if let pid = state.pid { status["pid"] = Int(pid) }
        if let started = state.startedAt { status["startedAt"] = ISO8601DateFormatter().string(from: started) }
        if let code = state.exitCode { status["exitCode"] = Int(code) }
        object["status"] = status
        if manager.needsApproval(server.id) {
            object["needsApproval"] = true
            object["approvalNote"] = "New or changed command: it can't start until the user clicks Allow in the ServerHat menu."
        }
        object["log"] = manager.log(server.id).fileURL.path
        if let url = server.openURL { object["openURL"] = url.absoluteString }
        return object
    }
}
