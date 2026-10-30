import Foundation

/// One local web server, as stored in servers.json.
struct ServerConfig: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// The folder the command runs in. `~` is expanded.
    var cwd: String
    /// An executable name found on the login shell's PATH (`node`, `npm`), or a path.
    var command: String
    var args: [String] = []
    var port: Int?
    /// What "Open in browser" opens. Defaults to http://127.0.0.1:<port>.
    var url: String?
    var env: [String: String] = [:]
    /// Start this server whenever LocalWeb starts (so at login, when LocalWeb opens at login).
    var startAtLogin: Bool = false

    init(id: String, name: String, cwd: String, command: String, args: [String] = [], port: Int? = nil,
         url: String? = nil, env: [String: String] = [:], startAtLogin: Bool = false) {
        self.id = id; self.name = name; self.cwd = cwd; self.command = command; self.args = args
        self.port = port; self.url = url; self.env = env; self.startAtLogin = startAtLogin
    }

    // Hand-edited files may leave out anything optional.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ServerConfig.slug(name)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? "~"
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        startAtLogin = try c.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false
    }

    var workingDirectory: URL {
        URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath, isDirectory: true)
    }

    var openURL: URL? {
        if let url, !url.isEmpty { return URL(string: url) }
        if let port { return URL(string: "http://127.0.0.1:\(port)") }
        return nil
    }

    /// Problems that would stop the server from starting, or nil.
    var problem: String? {
        if id.isEmpty || id.contains("/") { return "id must be non-empty and contain no \"/\"" }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "name is required" }
        if command.trimmingCharacters(in: .whitespaces).isEmpty { return "command is required" }
        if let port, !(1...65535).contains(port) { return "port must be 1–65535" }
        return nil
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(lowered).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "server" : joined
    }
}

struct ConfigFile: Codable {
    var version: Int = 1
    var servers: [ServerConfig] = []
}

/// Reads and writes ~/Library/Application Support/LocalWeb/servers.json, and calls
/// `onChange` when someone else (a person, Claude Code, Codex) edits it.
final class ConfigStore {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("LocalWeb", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }()
    static let fileURL = folder.appendingPathComponent("servers.json")

    var onChange: ((ConfigFile) -> Void)?
    /// Set when the file can't be parsed; the last good config stays in use.
    private(set) var loadError: String?
    private var lastData: Data?
    private var watcher: DispatchSourceFileSystemObject?

    func load() -> ConfigFile {
        guard let data = try? Data(contentsOf: ConfigStore.fileURL) else {
            let empty = ConfigFile()
            save(empty)
            return empty
        }
        lastData = data
        do {
            var file = try JSONDecoder().decode(ConfigFile.self, from: data)
            file.servers = ConfigStore.uniqued(file.servers)
            loadError = nil
            return file
        } catch {
            loadError = "servers.json: \(ConfigStore.describe(error))"
            return ConfigFile()
        }
    }

    func save(_ file: ConfigFile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(file) else { return }
        data.append(0x0A)
        lastData = data
        try? data.write(to: ConfigStore.fileURL, options: .atomic)
        loadError = nil
    }

    /// Watches the folder rather than the file, because editors and `save` replace the
    /// file atomically, which would leave a file watcher looking at the old inode.
    func watch() {
        let fd = open(ConfigStore.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            // Let the writer finish before reading.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.reloadIfChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func reloadIfChanged() {
        guard let data = try? Data(contentsOf: ConfigStore.fileURL), data != lastData else { return }
        let previousError = loadError
        let file = load()
        if loadError == nil || loadError != previousError { onChange?(file) }
    }

    private static func uniqued(_ servers: [ServerConfig]) -> [ServerConfig] {
        var seen = Set<String>()
        return servers.map { server in
            var server = server
            var candidate = server.id
            var n = 2
            while seen.contains(candidate) { candidate = "\(server.id)-\(n)"; n += 1 }
            server.id = candidate
            seen.insert(candidate)
            return server
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let ctx):
            return "missing \"\(key.stringValue)\" at \(path(ctx))"
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx):
            return "wrong type at \(path(ctx))"
        case DecodingError.dataCorrupted(let ctx):
            return ctx.codingPath.isEmpty ? "not valid JSON" : "bad value at \(path(ctx))"
        default:
            return error.localizedDescription
        }
    }

    private static func path(_ ctx: DecodingError.Context) -> String {
        let parts = ctx.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }
        return parts.isEmpty ? "top level" : parts.joined()
    }
}

/// Reads `.claude/launch.json` files: `{version, configurations: [{name, runtimeExecutable, runtimeArgs, port, url}]}`.
enum LaunchJSONImporter {
    struct Launch: Decodable {
        struct Configuration: Decodable {
            var name: String
            var runtimeExecutable: String?
            var runtimeArgs: [String]?
            var port: Int?
            var url: String?
            var cwd: String?
            var env: [String: String]?
        }
        var configurations: [Configuration]
    }

    /// `path` may be the launch.json file, its `.claude` folder, or the project folder.
    static func servers(from path: String) throws -> [ServerConfig] {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            url = url.lastPathComponent == ".claude" ? url.appendingPathComponent("launch.json")
                : url.appendingPathComponent(".claude/launch.json")
        }
        let data = try Data(contentsOf: url)
        let launch = try JSONDecoder().decode(Launch.self, from: data)
        // launch.json lives in <project>/.claude/, and its commands run from <project>.
        let claudeFolder = url.deletingLastPathComponent()
        let project = claudeFolder.lastPathComponent == ".claude" ? claudeFolder.deletingLastPathComponent() : claudeFolder
        return launch.configurations.compactMap { c in
            guard let exe = c.runtimeExecutable, !exe.isEmpty else { return nil }
            var cwd = project.path
            if let rel = c.cwd, !rel.isEmpty {
                cwd = rel.hasPrefix("/") || rel.hasPrefix("~") ? rel : project.appendingPathComponent(rel).standardized.path
            }
            return ServerConfig(id: ServerConfig.slug(c.name), name: c.name, cwd: abbreviate(cwd), command: exe,
                                args: c.runtimeArgs ?? [], port: c.port, url: c.url, env: c.env ?? [:])
        }
    }

    private static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
