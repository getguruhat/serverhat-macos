import Foundation
import Testing
@testable import ServerHat

// These tests only use pure functions and temporary folders: nothing here reads or writes
// the real servers.json, api-token or preferences.

// MARK: API request checks

private let port: UInt16 = 47317
private let token = String(repeating: "a", count: 64)

private func request(_ method: String = "GET", _ path: String = "/v1/servers", headers: [String: String] = [:],
                     body: String = "", auth: Bool = true, host: String = "127.0.0.1:47317") -> APIServer.Request {
    var all = ["host": host]
    if auth { all["authorization"] = "Bearer \(token)" }
    for (name, value) in headers { all[name.lowercased()] = value }
    return APIServer.Request(method: method, path: path, query: [:], headers: all, body: Data(body.utf8))
}

private func status(_ request: APIServer.Request) -> Int? {
    APIServer.refusal(for: request, port: port, token: token)?.status
}

@Suite struct RequestChecks {
    @Test func acceptsTheRightToken() {
        #expect(status(request()) == nil)
        #expect(status(request(host: "localhost:47317")) == nil)
    }

    @Test func healthNeedsNoToken() {
        #expect(status(request("GET", "/v1/health", auth: false)) == nil)
    }

    @Test func refusesMissingOrWrongToken() {
        #expect(status(request(auth: false)) == 401)
        #expect(status(request(headers: ["Authorization": "Bearer " + String(repeating: "b", count: 64)], auth: false)) == 401)
        #expect(status(request(headers: ["Authorization": "Bearer " + String(token.dropLast())], auth: false)) == 401)
        #expect(status(request(headers: ["Authorization": token], auth: false)) == 401)
    }

    @Test func refusesOtherHosts() {
        // DNS rebinding: a page on evil.example resolving to 127.0.0.1 still sends its own Host.
        #expect(status(request(host: "evil.example:47317")) == 403)
        #expect(status(request(host: "127.0.0.1:8080")) == 403)
        #expect(status(request("GET", "/v1/health", auth: false, host: "evil.example:47317")) == 403)
    }

    @Test func refusesWebPages() {
        #expect(status(request(headers: ["Origin": "https://example.com"])) == 403)
        #expect(status(request(headers: ["Sec-Fetch-Site": "cross-site"])) == 403)
        #expect(status(request(headers: ["Sec-Fetch-Site": "same-site"])) == 403)
        #expect(status(request(headers: ["Sec-Fetch-Site": "none"])) == nil)
        #expect(status(request("OPTIONS")) == 403)
    }

    @Test func bodiesMustBeJSON() {
        #expect(status(request("POST", headers: ["Content-Type": "text/plain"], body: "{}")) == 415)
        #expect(status(request("POST", body: "{}")) == 415)
        #expect(status(request("POST", headers: ["Content-Type": "application/json; charset=utf-8"], body: "{}")) == nil)
        #expect(status(request("POST", "/v1/servers/x/start")) == nil)
    }
}

// MARK: HTTP parsing

@Suite struct Parsing {
    private func parse(_ text: String) -> APIServer.Parse { APIServer.parse(Data(text.utf8)) }

    @Test func parsesARequest() throws {
        guard case .request(let r) = parse("post /v1/servers/a/start?wait=30 HTTP/1.1\r\nHost: 127.0.0.1:47317\r\nContent-Length: 2\r\n\r\n{}") else {
            Issue.record("didn't parse"); return
        }
        #expect(r.method == "POST")
        #expect(r.path == "/v1/servers/a/start")
        #expect(r.query["wait"] == "30")
        #expect(r.headers["host"] == "127.0.0.1:47317")
        #expect(r.body == Data("{}".utf8))
    }

    @Test func waitsForTheWholeBody() {
        guard case .needMore = parse("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}") else { Issue.record("expected needMore"); return }
        guard case .needMore = parse("GET / HTTP/1.1\r\nHost: x") else { Issue.record("expected needMore"); return }
    }

    @Test func rejectsBadRequests() {
        guard case .bad = parse("GET /\r\n\r\n") else { Issue.record("bad request line accepted"); return }
        guard case .bad = parse("POST / HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n") else { Issue.record("oversized body accepted"); return }
        guard case .bad = parse("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") else { Issue.record("negative length accepted"); return }
        guard case .bad = parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") else { Issue.record("chunked accepted"); return }
    }
}

// MARK: Approval fingerprints

@Suite struct Approval {
    private let base = ServerConfig(id: "app", name: "App", cwd: "/tmp/app", command: "npm", args: ["run", "dev"],
                                    port: 5173, env: ["A": "1"])

    @Test func whatRunsChangesTheFingerprint() {
        let original = ServerManager.fingerprint(base)
        var changed = base; changed.command = "node"
        #expect(ServerManager.fingerprint(changed) != original)
        changed = base; changed.args = ["run", "build"]
        #expect(ServerManager.fingerprint(changed) != original)
        changed = base; changed.cwd = "/tmp/other"
        #expect(ServerManager.fingerprint(changed) != original)
        changed = base; changed.env = ["A": "2"]
        #expect(ServerManager.fingerprint(changed) != original)
        changed = base; changed.env = ["A": "1", "B": "1"]
        #expect(ServerManager.fingerprint(changed) != original)
    }

    @Test func otherSettingsDontNeedApprovalAgain() {
        var changed = base
        changed.name = "Renamed"; changed.port = 3000; changed.url = "http://localhost:3000"
        changed.startAtLogin = true; changed.restartOnCrash = true; changed.healthContains = "ok"
        #expect(ServerManager.fingerprint(changed) == ServerManager.fingerprint(base))
    }

    @Test func argumentsCantBeShuffledIntoTheSameFingerprint() {
        var a = base; a.command = "sh"; a.args = ["-c", "x"]
        var b = base; b.command = "sh -c"; b.args = ["x"]
        #expect(ServerManager.fingerprint(a) != ServerManager.fingerprint(b))
    }

    @Test func equivalentFoldersMatch() {
        var a = base; a.cwd = "/tmp/app"
        var b = base; b.cwd = "/tmp/./app/"
        #expect(ServerManager.fingerprint(a) == ServerManager.fingerprint(b))
    }
}

// MARK: servers.json

@Suite struct ConfigFormat {
    private func decode(_ json: String) throws -> ServerConfig {
        try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
    }

    @Test func fillsInDefaults() throws {
        let server = try decode(#"{"name": "My App!", "command": "node"}"#)
        #expect(server.id == "my-app")
        #expect(server.cwd == "~")
        #expect(server.args.isEmpty && server.env.isEmpty)
        #expect(!server.startAtLogin && !server.restartOnCrash)
        #expect(server.restartLimit == 3)
    }

    @Test func requiresNameAndCommand() {
        #expect(throws: (any Error).self) { try decode(#"{"command": "node"}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"name": "x"}"#) }
    }

    @Test func clampsTheRestartLimit() throws {
        #expect(try decode(#"{"name": "a", "command": "x", "restartLimit": 99}"#).restartLimit == 10)
        #expect(try decode(#"{"name": "a", "command": "x", "restartLimit": 0}"#).restartLimit == 1)
    }

    @Test func reportsProblems() throws {
        #expect(try decode(#"{"name": "a", "command": "x", "port": 70000}"#).problem != nil)
        #expect(try decode(#"{"name": "a", "id": "a/b", "command": "x"}"#).problem != nil)
        #expect(try decode(#"{"name": "a", "command": " "}"#).problem != nil)
        #expect(try decode(#"{"name": "a", "command": "x", "port": 3000}"#).problem == nil)
    }

    @Test func slugs() {
        #expect(ServerConfig.slug("AI Experts") == "ai-experts")
        #expect(ServerConfig.slug("  --  ") == "server")
    }

    @Test func openURLFallsBackToThePort() throws {
        #expect(try decode(#"{"name": "a", "command": "x", "port": 4319}"#).openURL?.absoluteString == "http://127.0.0.1:4319")
        #expect(try decode(#"{"name": "a", "command": "x"}"#).openURL == nil)
    }
}

// MARK: Importers

private func project(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("serverhat-test-\(UUID().uuidString)/site")
    for (path, contents) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite struct Importers {
    @Test func launchJSONRunsFromTheProjectFolder() throws {
        let root = try project([".claude/launch.json": """
            {"version": "0.0.1", "configurations": [
              {"name": "Web", "runtimeExecutable": "npm", "runtimeArgs": ["run", "dev"], "port": 5173},
              {"name": "No command"}
            ]}
            """])
        for path in [root.path, root.appendingPathComponent(".claude").path, root.appendingPathComponent(".claude/launch.json").path] {
            let servers = try LaunchJSONImporter.servers(from: path)
            #expect(servers.count == 1)
            #expect(servers.first?.id == "web")
            #expect(servers.first?.args == ["run", "dev"])
            #expect(servers.first?.port == 5173)
            #expect(servers.first?.workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
                    == root.standardizedFileURL.resolvingSymlinksInPath())
        }
    }

    @Test func packageJSONPrefersDevAndTheLockfilesManager() throws {
        let root = try project([
            "package.json": #"{"scripts": {"start": "node server.js", "dev": "vite --port 5174"}}"#,
            "pnpm-lock.yaml": "",
        ])
        let server = try #require(try ProjectImporter.suggestions(from: root.path).first)
        #expect(server.command == "pnpm")
        #expect(server.args == ["run", "dev"])
        #expect(server.port == 5174)
    }

    @Test func procfileAndCompose() throws {
        let root = try project(["Procfile": "worker: x\nweb: python3 -m http.server --port 8000\n", "compose.yaml": ""])
        let servers = try ProjectImporter.suggestions(from: root.path)
        #expect(servers.map(\.command) == ["/bin/zsh", "docker"])
        #expect(servers.first?.port == 8000)
    }

    @Test func emptyFolderExplainsWhatItLookedFor() throws {
        let root = try project([:])
        #expect(throws: (any Error).self) { try ProjectImporter.suggestions(from: root.path) }
    }
}

// MARK: Languages

@Suite struct Languages {
    @Test func picksTheFirstLanguageServerHatHas() {
        #expect(Loc.pick(from: ["de-AT", "en"]) == "de")
        #expect(Loc.pick(from: ["it-IT", "fr-FR"]) == "fr")
        #expect(Loc.pick(from: ["pt-BR"]) == "pt")
        #expect(Loc.pick(from: ["es-419"]) == "es")
        #expect(Loc.pick(from: ["ja-JP"]) == "ja")
        #expect(Loc.pick(from: ["ko-KR"]) == "ko")
    }

    @Test func englishFirstStaysEnglish() {
        #expect(Loc.pick(from: ["en-GB", "de"]) == "en")
        #expect(Loc.pick(from: ["it-IT"]) == "en")
        #expect(Loc.pick(from: []) == "en")
    }

    @Test func chineseNeedsTheSimplifiedScript() {
        #expect(Loc.pick(from: ["zh-Hans-CN"]) == "zh-Hans")
        #expect(Loc.pick(from: ["zh-Hant-TW", "en"]) == "en")
        #expect(Loc.pick(from: ["zh-Hant-HK", "ko"]) == "ko")
    }

    @Test func fillsPlaceholdersOnce() {
        #expect(Loc.fill("{0} of {1}", ["a", "{1}"]) == "a of {1}")
        #expect(Loc.fill("no placeholders", ["x"]) == "no placeholders")
        #expect(Loc.fill("{2} stays", ["x"]) == "{2} stays")
    }

    @Test func everyLanguageHasTheSameKeysAndPlaceholders() {
        func placeholders(_ text: String) -> [String] {
            ["{0}", "{1}", "{2}", "{3}"].filter { text.contains($0) }
        }
        let languages = Loc.tables
        #expect(languages.count == 7)
        let keys = Set(languages.values.first!.keys)
        for (code, table) in languages {
            #expect(Set(table.keys) == keys, "\(code) has a different set of strings")
            for (english, translated) in table {
                #expect(placeholders(english) == placeholders(translated), "\(code): \(english)")
                #expect(!translated.isEmpty)
            }
        }
    }

    @Test func translatesSentencesBuiltInEnglish() {
        #expect(Loc.translate("Port 3000 is already in use.", to: "es") == "El puerto 3000 ya está en uso.")
        #expect(Loc.translate("Port 3000 is in use by node (pid 42).", to: "de") == "Port 3000 wird von node verwendet (PID 42).")
        #expect(Loc.translate("Crashed with exit code 1. Automatic restart limit reached.", to: "fr")
                == Loc.translate("Crashed with exit code 1.", to: "fr") + " " + Loc.translate("Automatic restart limit reached.", to: "fr"))
        #expect(Loc.translate("Something nobody translated.", to: "ko") == "Something nobody translated.")
        #expect(Loc.translate("Port 3000 is already in use.", to: "en") == "Port 3000 is already in use.")
    }
}
