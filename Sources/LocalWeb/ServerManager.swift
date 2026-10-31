import AppKit
import CryptoKit
import Darwin

enum ServerStatus: String, Codable {
    case stopped, starting, running, stopping, crashed
    case portInUse = "port-in-use"
    /// The command couldn't be started at all (not found, bad folder).
    case failed
}

struct ServerState: Equatable {
    var status: ServerStatus = .stopped
    /// A sentence for people: why it crashed, who holds the port, and so on.
    var detail: String?
    var pid: pid_t?
    var startedAt: Date?
    var exitCode: Int32?
}

struct ManagerError: LocalizedError {
    let message: String
    var status = 400
    var errorDescription: String? { message }
}

/// The last lines a server printed, kept in memory for the menu and the API, and
/// appended to ~/Library/Logs/LocalWeb/<id>.log.
final class LogBuffer: ObservableObject {
    static let folder: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LocalWeb", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private static let maxLines = 5000
    private static let maxFileBytes: UInt64 = 5 * 1024 * 1024

    @Published private(set) var revision = 0
    private(set) var lines: [String] = []
    private var partial = Data()
    private var file: FileHandle?
    private var publishScheduled = false
    let fileURL: URL

    init(id: String) {
        fileURL = LogBuffer.folder.appendingPathComponent("\(id).log")
    }

    func beginRun(_ header: String) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64, size > LogBuffer.maxFileBytes {
            let old = fileURL.deletingPathExtension().appendingPathExtension("1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: fileURL, to: old)
        }
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
        file = try? FileHandle(forWritingTo: fileURL)
        _ = try? file?.seekToEnd()
        append(line: header)
    }

    func endRun(_ footer: String) {
        flushPartial()
        append(line: footer)
        try? file?.close()
        file = nil
    }

    func append(data: Data) {
        partial.append(data)
        while let newline = partial.firstIndex(of: 0x0A) {
            let lineData = partial[partial.startIndex..<newline]
            partial.removeSubrange(partial.startIndex...newline)
            append(line: String(decoding: lineData, as: UTF8.self))
        }
        // A line with no newline yet (a prompt, a progress bar) still shows up eventually.
        if partial.count > 16 * 1024 { flushPartial() }
    }

    func append(line: String) {
        let clean = line.hasSuffix("\r") ? String(line.dropLast()) : line
        lines.append(clean)
        if lines.count > LogBuffer.maxLines { lines.removeFirst(lines.count - LogBuffer.maxLines) }
        file?.write(Data((clean + "\n").utf8))
        schedulePublish()
    }

    func tail(_ count: Int) -> [String] { Array(lines.suffix(max(0, count))) }

    func clear() {
        lines.removeAll()
        schedulePublish()
    }

    private func flushPartial() {
        guard !partial.isEmpty else { return }
        let data = partial
        partial = Data()
        append(line: String(decoding: data, as: UTF8.self))
    }

    /// Chatty servers print thousands of lines a second; redraw at most 10 times a second.
    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.publishScheduled = false
            self?.revision += 1
        }
    }
}

/// Starts and stops the configured servers. Everything here runs on the main queue.
final class ServerManager: ObservableObject {
    @Published private(set) var servers: [ServerConfig] = []
    @Published private(set) var states: [String: ServerState] = [:]
    @Published private(set) var configError: String?
    /// Fingerprints of what the user has allowed to run. See `needsApproval`.
    @Published private(set) var approved: Set<String> = []

    private let store = ConfigStore()
    private var logs: [String: LogBuffer] = [:]
    private var running: [String: RunningProcess] = [:]
    private var restartAfterExit = Set<String>()
    private var environment: [String: String]?
    private var waitingForEnvironment: [() -> Void] = []
    private var ticker: Timer?
    private var askedForApproval: [String: Date] = [:]
    private static let approvalsKey = "approvedCommands"

    private final class RunningProcess {
        let pid: pid_t
        let output: FileHandle
        var exitSource: DispatchSourceProcess?
        var killTimer: DispatchWorkItem?
        var stopRequested = false
        var waitingForPort = true
        let started = Date()
        init(pid: pid_t, output: FileHandle) { self.pid = pid; self.output = output }
    }

    init() {
        let file = store.load()
        servers = file.servers
        configError = store.loadError
        store.onChange = { [weak self] file in self?.configChangedOnDisk(file) }
        store.watch()
        for server in servers { states[server.id] = ServerState() }
        if let saved = UserDefaults.standard.stringArray(forKey: ServerManager.approvalsKey) {
            approved = Set(saved)
        } else {
            // First run with approvals: everything already set up counts as allowed.
            approved = Set(servers.map(ServerManager.fingerprint))
            saveApprovals()
        }
        DispatchQueue.main.async { [weak self] in self?.askForPendingApprovals() }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        loadEnvironment()
        whenEnvironmentReady { [weak self] in
            guard let self else { return }
            for server in self.servers where server.startAtLogin { try? self.start(server.id) }
        }
    }

    // MARK: Lookup

    func server(_ id: String) -> ServerConfig? { servers.first { $0.id == id } }
    func state(_ id: String) -> ServerState { states[id] ?? ServerState() }

    func log(_ id: String) -> LogBuffer {
        if let log = logs[id] { return log }
        let log = LogBuffer(id: id)
        logs[id] = log
        return log
    }

    var configFileURL: URL { ConfigStore.fileURL }

    // MARK: Editing

    @discardableResult
    func add(_ server: ServerConfig, approved byUser: Bool = false) throws -> ServerConfig {
        var server = server
        if server.id.isEmpty { server.id = ServerConfig.slug(server.name) }
        if let problem = server.problem { throw ManagerError(message: problem) }
        if self.server(server.id) != nil { throw ManagerError(message: "a server with id \"\(server.id)\" already exists", status: 409) }
        servers.append(server)
        states[server.id] = ServerState()
        if byUser { approve(server.id) }
        save()
        refreshPort(server.id)
        askForPendingApprovals()
        return server
    }

    /// Replaces a server's settings. A running server keeps its old settings until it restarts.
    @discardableResult
    func update(_ id: String, to new: ServerConfig, approved byUser: Bool = false) throws -> ServerConfig {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { throw ManagerError(message: "no server \"\(id)\"", status: 404) }
        var new = new
        new.id = id
        if let problem = new.problem { throw ManagerError(message: problem) }
        servers[index] = new
        if byUser { approve(id) }
        save()
        askForPendingApprovals()
        return new
    }

    func remove(_ id: String) throws {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { throw ManagerError(message: "no server \"\(id)\"", status: 404) }
        stop(id)
        servers.remove(at: index)
        if running[id] == nil { states[id] = nil }
        save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        servers.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    /// Adds every configuration in a `.claude/launch.json` that isn't already here
    /// (same folder, command and arguments). Returns the servers it added.
    func importLaunchJSON(at path: String, approved byUser: Bool = false) throws -> [ServerConfig] {
        let found: [ServerConfig]
        do { found = try LaunchJSONImporter.servers(from: path) } catch {
            throw ManagerError(message: "couldn't read launch.json: \(ConfigStore.describe(error))")
        }
        var added: [ServerConfig] = []
        for var candidate in found {
            let duplicate = servers.contains {
                $0.workingDirectory.standardized == candidate.workingDirectory.standardized
                    && $0.command == candidate.command && $0.args == candidate.args
            }
            if duplicate { continue }
            let base = candidate.id
            var n = 2
            while server(candidate.id) != nil { candidate.id = "\(base)-\(n)"; n += 1 }
            added.append(try add(candidate, approved: byUser))
        }
        return added
    }

    func reloadConfig() {
        configChangedOnDisk(store.load())
    }

    private func save() {
        store.save(ConfigFile(servers: servers))
        configError = nil
    }

    private func configChangedOnDisk(_ file: ConfigFile) {
        configError = store.loadError
        guard store.loadError == nil else { return }
        let newIDs = Set(file.servers.map(\.id))
        for old in servers where !newIDs.contains(old.id) {
            stop(old.id)
            if running[old.id] == nil { states[old.id] = nil }
        }
        servers = file.servers
        for server in servers where states[server.id] == nil {
            states[server.id] = ServerState()
            refreshPort(server.id)
        }
        askForPendingApprovals()
    }

    // MARK: Approval

    /// True when a server's folder, command, arguments or environment is something the
    /// user hasn't allowed yet: it was added or changed through the API (so by an agent)
    /// or by editing servers.json. It can't start until the user clicks Allow. Changes
    /// made in LocalWeb's own windows count as allowed.
    func needsApproval(_ id: String) -> Bool {
        guard let server = server(id) else { return false }
        return !approved.contains(ServerManager.fingerprint(server))
    }

    var pendingApprovals: [ServerConfig] { servers.filter { needsApproval($0.id) } }

    func approve(_ id: String) {
        guard let server = server(id) else { return }
        // Forget approvals for settings no server has any more.
        let current = Set(servers.map(ServerManager.fingerprint))
        approved = approved.intersection(current).union([ServerManager.fingerprint(server)])
        saveApprovals()
    }

    /// Notifies the user about a server waiting for approval, at most every 15 seconds each.
    func askForApproval(_ id: String) {
        guard let server = server(id), needsApproval(id) else { return }
        let key = ServerManager.fingerprint(server)
        if let last = askedForApproval[key], Date().timeIntervalSince(last) < 15 { return }
        askedForApproval[key] = Date()
        Notifier.shared.approvalNeeded(server)
    }

    private func askForPendingApprovals() {
        for server in pendingApprovals where askedForApproval[ServerManager.fingerprint(server)] == nil {
            askForApproval(server.id)
        }
    }

    private func saveApprovals() {
        UserDefaults.standard.set(approved.sorted(), forKey: ServerManager.approvalsKey)
    }

    static func fingerprint(_ server: ServerConfig) -> String {
        let parts = [server.workingDirectory.standardized.path, server.command] + server.args
            + server.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let data = (try? JSONSerialization.data(withJSONObject: parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Running

    func start(_ id: String) throws {
        guard let server = server(id) else { throw ManagerError(message: "no server \"\(id)\"", status: 404) }
        if needsApproval(id) {
            askForApproval(id)
            throw ManagerError(message: "\(server.name) is waiting for approval: ask the user to click Allow in the LocalWeb menu (they got a notification)", status: 403)
        }
        if let process = running[id] {
            // Start while it's still stopping means "start it again once it has stopped".
            if process.stopRequested { restartAfterExit.insert(id) }
            return
        }
        guard environment != nil else {
            states[id]?.status = .starting
            states[id]?.detail = "Reading your shell's PATH…"
            whenEnvironmentReady { [weak self] in try? self?.start(id) }
            return
        }
        if let problem = server.problem {
            setState(id, ServerState(status: .failed, detail: problem))
            throw ManagerError(message: problem)
        }
        if let port = server.port, PortProbe.isListening(port) {
            setState(id, ServerState(status: .portInUse, detail: "Port \(port) is already in use."))
            describePortOwner(id, port: port)
            throw ManagerError(message: "port \(port) is already in use", status: 409)
        }

        let log = log(id)
        let commandLine = ([server.command] + server.args).map(ServerManager.shellQuoted).joined(separator: " ")
        log.beginRun("=== \(ServerManager.timestamp()) Starting in \(server.cwd): \(commandLine)")
        let spawned: (pid_t, FileHandle)
        do {
            spawned = try Spawner.spawn(server, environment: environment ?? [:])
        } catch {
            let message = (error as? ManagerError)?.message ?? error.localizedDescription
            log.endRun("=== Couldn't start: \(message)")
            setState(id, ServerState(status: .failed, detail: message))
            throw ManagerError(message: message)
        }

        let process = RunningProcess(pid: spawned.0, output: spawned.1)
        running[id] = process
        spawned.1.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { log.append(data: data) }
        }
        let source = DispatchSource.makeProcessSource(identifier: spawned.0, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.reap(id) }
        source.resume()
        process.exitSource = source

        process.waitingForPort = server.port != nil
        setState(id, ServerState(status: server.port == nil ? .running : .starting,
                                 detail: server.port.map { "Waiting for port \($0)…" }, pid: spawned.0, startedAt: process.started))
        reap(id) // in case it exited before the exit source was watching
    }

    func stop(_ id: String) {
        restartAfterExit.remove(id)
        guard let process = running[id] else {
            if let status = states[id]?.status, status == .crashed || status == .failed {
                states[id] = ServerState()
                refreshPort(id)
            }
            return
        }
        guard !process.stopRequested else { return }
        process.stopRequested = true
        states[id]?.status = .stopping
        states[id]?.detail = nil
        // The server runs in its own process group, so this also reaches the
        // processes it started (npm → node → vite).
        kill(-process.pid, SIGTERM)
        let force = DispatchWorkItem { [weak self] in
            guard self?.running[id] === process else { return }
            self?.log(id).append(line: "=== Still running after 5 seconds; sending SIGKILL")
            kill(-process.pid, SIGKILL)
        }
        process.killTimer = force
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: force)
    }

    func restart(_ id: String) throws {
        guard server(id) != nil else { throw ManagerError(message: "no server \"\(id)\"", status: 404) }
        if needsApproval(id) { try start(id) } // explains, without stopping the old one
        if running[id] != nil {
            stop(id)
            restartAfterExit.insert(id)
        } else {
            if states[id]?.status != .portInUse { states[id] = ServerState() }
            try start(id)
        }
    }

    func startAll() {
        for server in servers where running[server.id] == nil && !needsApproval(server.id) { try? start(server.id) }
    }

    func stopAll() {
        for id in running.keys { stop(id) }
    }

    var runningCount: Int { running.count }

    /// Called when LocalWeb quits: stop everything and give it a moment to exit.
    func shutdown() {
        let pids = running.values.map(\.pid)
        for pid in pids { kill(-pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 && !ServerManager.isZombie($0) }) {
            usleep(50_000)
        }
        for pid in pids { kill(-pid, SIGKILL) }
    }

    private func reap(_ id: String) {
        guard let process = running[id] else { return }
        var status: Int32 = 0
        guard waitpid(process.pid, &status, WNOHANG) == process.pid else { return }
        process.exitSource?.cancel()
        process.killTimer?.cancel()
        // Children the server left behind would otherwise keep the port busy.
        kill(-process.pid, SIGTERM)
        running[id] = nil

        let exited = (status & 0x7f) == 0
        let code = exited ? (status >> 8) & 0xff : 0
        let signal = exited ? 0 : status & 0x7f
        let log = log(id)
        // Let the last output arrive before writing the footer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let how = exited ? "exit code \(code)" : "signal \(signal) (\(String(cString: strsignal(signal))))"
            log.endRun("=== \(ServerManager.timestamp()) Exited with \(how)")
        }

        guard server(id) != nil else { states[id] = nil; return }
        if process.stopRequested {
            setState(id, ServerState())
        } else if exited && code == 0 {
            setState(id, ServerState(status: .stopped, detail: "Exited on its own.", exitCode: 0))
        } else {
            let lastLine = log.lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("===") }
            var detail = exited ? "Crashed with exit code \(code)." : "Killed by signal \(signal)."
            if let lastLine { detail += " " + String(lastLine.prefix(160)) }
            setState(id, ServerState(status: .crashed, detail: detail, exitCode: exited ? code : 128 + signal))
            if let server = server(id) { Notifier.shared.crashed(server, detail: detail) }
        }
        if restartAfterExit.remove(id) != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in try? self?.start(id) }
        } else {
            refreshPort(id)
        }
    }

    private func tick() {
        for (id, process) in running {
            reap(id)
            guard running[id] === process, process.waitingForPort, !process.stopRequested,
                  let port = server(id)?.port else { continue }
            if PortProbe.isListening(port) {
                process.waitingForPort = false
                states[id]?.status = .running
                states[id]?.detail = nil
            } else if Date().timeIntervalSince(process.started) > 90 {
                process.waitingForPort = false
                states[id]?.status = .running
                states[id]?.detail = "Running, but nothing is listening on port \(port)."
            }
        }
        // Every few seconds, notice ports that something outside LocalWeb opened or closed.
        if Int(Date().timeIntervalSince1970) % 3 == 0 {
            for server in servers where running[server.id] == nil { refreshPort(server.id) }
        }
    }

    private func refreshPort(_ id: String) {
        guard running[id] == nil, let server = server(id), let state = states[id] else { return }
        guard let port = server.port else { return }
        let busy = PortProbe.isListening(port)
        if busy && (state.status == .stopped) {
            setState(id, ServerState(status: .portInUse, detail: "Port \(port) is already in use."))
            describePortOwner(id, port: port)
        } else if !busy && state.status == .portInUse {
            setState(id, ServerState())
        }
    }

    private func describePortOwner(_ id: String, port: Int) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let owner = PortProbe.owner(of: port) else { return }
            DispatchQueue.main.async {
                guard let self, self.states[id]?.status == .portInUse else { return }
                self.states[id]?.detail = "Port \(port) is in use by \(owner.command) (pid \(owner.pid))."
                self.states[id]?.pid = owner.pid
            }
        }
    }

    private func setState(_ id: String, _ state: ServerState) {
        if states[id] != state { states[id] = state }
    }

    // MARK: Environment

    /// Apps opened from Finder get a bare PATH, so read the one the login shell sets
    /// up (Homebrew, nvm, and so on) once, the way Terminal would see it.
    private func loadEnvironment() {
        DispatchQueue.global(qos: .userInitiated).async {
            var env = ProcessInfo.processInfo.environment
            let fallback = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            let path = ServerManager.loginShellPath() ?? ((env["PATH"].map { [$0] } ?? []) + fallback).joined(separator: ":")
            env["PATH"] = path
            DispatchQueue.main.async {
                self.environment = env
                let waiting = self.waitingForEnvironment
                self.waitingForEnvironment = []
                waiting.forEach { $0() }
            }
        }
    }

    private func whenEnvironmentReady(_ work: @escaping () -> Void) {
        if environment != nil { work() } else { waitingForEnvironment.append(work) }
    }

    private static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '__LOCALWEB__%s__LOCALWEB__' \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.components(separatedBy: "__LOCALWEB__")
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    // MARK: Helpers

    static func shellQuoted(_ arg: String) -> String {
        if !arg.isEmpty, arg.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    private static func isZombie(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == pid
    }
}

/// Starts a server with posix_spawn so it gets its own process group (which lets
/// Stop reach everything it started) and inherits no file descriptors except its output pipe.
enum Spawner {
    static func spawn(_ server: ServerConfig, environment: [String: String]) throws -> (pid_t, FileHandle) {
        let cwd = server.workingDirectory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir), isDir.boolValue else {
            throw ManagerError(message: "The folder \(server.cwd) doesn't exist.")
        }
        var env = environment
        for (key, value) in server.env { env[key] = value }
        guard let executable = resolve(server.command, in: cwd, path: env["PATH"] ?? "") else {
            throw ManagerError(message: "Couldn't find \"\(server.command)\" on your PATH.")
        }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ManagerError(message: "Couldn't create a pipe: \(String(cString: strerror(errno)))") }
        let (readFD, writeFD) = (fds[0], fds[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t(), allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([executable] + server.args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(writeFD)
        guard result == 0 else {
            close(readFD)
            throw ManagerError(message: "Couldn't start \(executable): \(String(cString: strerror(result)))")
        }
        return (pid, FileHandle(fileDescriptor: readFD, closeOnDealloc: true))
    }

    static func resolve(_ command: String, in cwd: URL, path: String) -> String? {
        let fm = FileManager.default
        if command.contains("/") {
            let expanded = (command as NSString).expandingTildeInPath
            let full = expanded.hasPrefix("/") ? expanded : cwd.appendingPathComponent(expanded).standardized.path
            return fm.isExecutableFile(atPath: full) ? full : nil
        }
        for dir in path.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(command)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

enum PortProbe {
    /// True when something accepts connections on the port at 127.0.0.1 or ::1.
    static func isListening(_ port: Int) -> Bool {
        connects(family: AF_INET, port: port) || connects(family: AF_INET6, port: port)
    }

    private static func connects(family: Int32, port: Int) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
        } else {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            addr.sin6_addr = in6addr_loopback
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
            }
        }
    }

    /// The process listening on a port, from lsof.
    static func owner(of port: Int) -> (pid: pid_t, command: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var pid: pid_t?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p") { pid = pid_t(line.dropFirst()) }
            if line.hasPrefix("c"), let pid { return (pid, String(line.dropFirst())) }
        }
        return nil
    }
}
