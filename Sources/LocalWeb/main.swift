import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var manager: ServerManager?

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.manager?.shutdown()
    }
}

@main
struct LocalWebApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var manager: ServerManager
    @StateObject private var updates: UpdateChecker
    private let api: APIServer

    init() {
        let manager = ServerManager()
        AppDelegate.manager = manager
        let api = APIServer(manager: manager)
        api.start()
        self.api = api
        _manager = StateObject(wrappedValue: manager)
        let updates = UpdateChecker(appName: "LocalWeb", repo: "getguruhat/localweb-macos")
        updates.start()
        _updates = StateObject(wrappedValue: updates)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(manager: manager, updates: updates, api: api)
        } label: {
            let running = manager.states.values.filter { $0.status == .running || $0.status == .starting }.count
            let crashed = manager.states.values.contains { $0.status == .crashed || $0.status == .failed }
            Image(systemName: crashed ? "exclamationmark.triangle" : running > 0 ? "globe.americas.fill" : "globe.americas")
            if running > 0 { Text("\(running)") }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: Menu

struct MenuContent: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject var updates: UpdateChecker
    let api: APIServer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LocalWeb").font(.headline)
                Spacer()
                Button("Start all") { manager.startAll() }.disabled(manager.servers.isEmpty)
                Button("Stop all") { manager.stopAll() }.disabled(manager.runningCount == 0)
            }
            .controlSize(.small)

            if let error = manager.configError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = api.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            if manager.servers.isEmpty {
                Text("No servers yet. Add one, import a .claude/launch.json, or ask Claude Code or Codex to set one up (see the README).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(manager.servers) { server in
                            ServerRow(manager: manager, server: server, state: manager.state(server.id))
                        }
                    }
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let update = updates.available {
                Link("LocalWeb \(update.version) is available ›", destination: update.page).font(.caption)
            }
            Divider()
            HStack(spacing: 12) {
                iconButton("plus", "Add server") { EditWindowController.show(manager: manager, editing: nil) }
                iconButton("square.and.arrow.down", "Import .claude/launch.json…") { importLaunchJSON() }
                iconButton("curlybraces", "Open servers.json") { NSWorkspace.shared.open(manager.configFileURL) }
                Spacer()
                iconButton("info.circle", "About LocalWeb") { AboutWindowController.shared.show() }
                iconButton("power", "Quit LocalWeb (stops its servers)") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 28, height: 24) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(help)
    }

    private func importLaunchJSON() {
        let panel = NSOpenPanel()
        panel.title = "Import servers from .claude/launch.json"
        panel.message = "Choose a project folder or its .claude/launch.json file."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json, .folder]
        panel.showsHiddenFiles = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        do {
            let added = try manager.importLaunchJSON(at: url.path)
            alert.messageText = added.isEmpty ? "Nothing new to import" : "Imported \(added.count) server\(added.count == 1 ? "" : "s")"
            alert.informativeText = added.isEmpty ? "Every configuration in that launch.json is already in LocalWeb." : added.map(\.name).joined(separator: ", ")
        } catch {
            alert.messageText = "Couldn't import"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}

struct ServerRow: View {
    @ObservedObject var manager: ServerManager
    let server: ServerConfig
    let state: ServerState

    private var isActive: Bool { [.running, .starting, .stopping].contains(state.status) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9).padding(.top, 5)
                .accessibilityLabel(statusText)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(server.name).fontWeight(.medium).lineLimit(1)
                    if let port = server.port { Text(":\(String(port))").font(.caption).foregroundStyle(.secondary) }
                }
                Text(state.detail ?? statusText)
                    .font(.caption).foregroundStyle(state.status == .crashed || state.status == .failed ? .red : .secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                if isActive {
                    action("stop.fill", "Stop") { manager.stop(server.id) }
                } else {
                    action("play.fill", "Start") { try? manager.start(server.id) }
                        .disabled(state.status == .portInUse)
                }
                action("arrow.clockwise", "Restart") { try? manager.restart(server.id) }
                action("safari", "Open in browser") { if let url = server.openURL { NSWorkspace.shared.open(url) } }
                    .disabled(server.openURL == nil)
                Menu {
                    Button("View logs") { LogWindowController.show(manager: manager, server: server) }
                    Button("Edit…") { EditWindowController.show(manager: manager, editing: server) }
                    Button("Show folder in Finder") { NSWorkspace.shared.open(server.workingDirectory) }
                    if state.status == .portInUse, let pid = state.pid {
                        Divider()
                        Button("Stop the process using port \(String(server.port ?? 0))…") { confirmKill(pid) }
                    }
                    Divider()
                    Button("Remove…") { confirmRemove() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26)
                .help("More")
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .contextMenu {
            Button("View logs") { LogWindowController.show(manager: manager, server: server) }
            Button("Edit…") { EditWindowController.show(manager: manager, editing: server) }
        }
    }

    private func action(_ symbol: String, _ help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: symbol).frame(width: 24, height: 22) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel("\(help) \(server.name)")
    }

    private var statusText: String {
        switch state.status {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        case .crashed: return "Crashed"
        case .portInUse: return "Port in use"
        case .failed: return "Couldn't start"
        }
    }

    private var color: Color {
        switch state.status {
        case .running: return .green
        case .starting, .stopping: return .yellow
        case .crashed, .failed: return .red
        case .portInUse: return .orange
        case .stopped: return .gray.opacity(0.5)
        }
    }

    private func confirmRemove() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove \(server.name)?"
        alert.informativeText = "LocalWeb stops it if it's running and forgets its settings. Its folder isn't touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { try? manager.remove(server.id) }
    }

    private func confirmKill(_ pid: pid_t) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Stop the process using port \(server.port ?? 0)?"
        alert.informativeText = (state.detail ?? "") + "\n\nLocalWeb didn't start it. It will be asked to quit (SIGTERM)."
        alert.addButton(withTitle: "Stop It")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { kill(pid, SIGTERM) }
    }
}

// MARK: Logs

enum LogWindowController {
    private static var windows: [String: NSWindow] = [:]

    static func show(manager: ServerManager, server: ServerConfig) {
        if let window = windows[server.id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = LogView(log: manager.log(server.id), manager: manager, id: server.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(server.name) — Logs"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.setFrameAutosaveName("LocalWebLogs")
        windows[server.id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            windows[server.id] = nil
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct LogView: View {
    @ObservedObject var log: LogBuffer
    @ObservedObject var manager: ServerManager
    let id: String

    var body: some View {
        VStack(spacing: 0) {
            LogTextView(text: log.lines.joined(separator: "\n"), revision: log.revision)
            Divider()
            HStack {
                Text(manager.state(id).detail ?? manager.state(id).status.rawValue).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Clear") { log.clear() }
                Button("Open log file") { NSWorkspace.shared.open(log.fileURL) }
            }
            .padding(8)
        }
    }
}

/// An NSTextView, because SwiftUI's Text gets slow with thousands of lines.
struct LogTextView: NSViewRepresentable {
    let text: String
    let revision: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        let atBottom = scroll.verticalScroller.map { $0.floatValue > 0.98 } ?? true || textView.string.isEmpty
        textView.string = text
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }
}

// MARK: Add / edit

enum EditWindowController {
    private static var window: NSWindow?

    static func show(manager: ServerManager, editing: ServerConfig?) {
        window?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let view = EditView(manager: manager, original: editing, form: EditForm(editing)) { window.close() }
        window.title = editing == nil ? "Add Server" : "Edit \(editing!.name)"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class EditForm: ObservableObject {
    @Published var name = ""
    @Published var cwd = "~"
    @Published var command = ""
    @Published var args = ""
    @Published var port = ""
    @Published var url = ""
    @Published var env = ""
    @Published var startAtLogin = false
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var error: String?

    init(_ s: ServerConfig?) {
        guard let s else { return }
        name = s.name; cwd = s.cwd; command = s.command
        args = s.args.map(ServerManager.shellQuoted).joined(separator: " ")
        port = s.port.map(String.init) ?? ""
        url = s.url ?? ""
        env = s.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        startAtLogin = s.startAtLogin
    }
}

struct EditView: View {
    let manager: ServerManager
    let original: ServerConfig?
    @ObservedObject var form: EditForm
    let close: () -> Void

    var body: some View {
        Form {
            TextField("Name", text: $form.name)
            HStack {
                TextField("Folder", text: $form.cwd)
                Button("Choose…") { chooseFolder() }
            }
            TextField("Command", text: $form.command, prompt: Text("node, npm, python3, or a path"))
            TextField("Arguments", text: $form.args, prompt: Text("server.mjs --port 4319"))
            TextField("Port", text: $form.port, prompt: Text("optional"))
            TextField("URL", text: $form.url, prompt: Text("optional, defaults to http://127.0.0.1:<port>"))
            VStack(alignment: .leading, spacing: 4) {
                Text("Environment (one NAME=value per line)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $form.env).font(.system(.body, design: .monospaced)).frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
            Toggle("Start this server when LocalWeb starts", isOn: $form.startAtLogin)
            if form.startAtLogin {
                Toggle("Open LocalWeb at login", isOn: $form.openAtLogin)
                    .onChange(of: form.openAtLogin) { setOpenAtLogin($0) }
            }
            if let error = form.error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Text("Arguments split on spaces; use quotes for spaces inside one.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add" : "Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func save() {
        var environment: [String: String] = [:]
        for line in form.env.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let eq = line.firstIndex(of: "=") else { form.error = "Environment line \"\(line)\" needs NAME=value."; return }
            environment[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: eq)...])
        }
        let portNumber = form.port.trimmingCharacters(in: .whitespaces)
        if !portNumber.isEmpty && Int(portNumber) == nil { form.error = "Port must be a number."; return }
        let config = ServerConfig(id: original?.id ?? "", name: form.name.trimmingCharacters(in: .whitespaces), cwd: form.cwd,
                                  command: form.command.trimmingCharacters(in: .whitespaces), args: EditView.splitArguments(form.args),
                                  port: Int(portNumber), url: form.url.isEmpty ? nil : form.url, env: environment, startAtLogin: form.startAtLogin)
        do {
            if let original { try manager.update(original.id, to: config) } else { try manager.add(config) }
            close()
        } catch {
            form.error = error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { form.cwd = (url.path as NSString).abbreviatingWithTildeInPath }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            form.error = error.localizedDescription
        }
        if SMAppService.mainApp.status == .requiresApproval { form.error = "Allow LocalWeb in System Settings → General → Login Items." }
    }

    /// Splits like a shell would for simple cases: spaces separate, quotes group.
    static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var inArg = false
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch; inArg = true
            } else if ch == " " || ch == "\t" {
                if inArg { result.append(current); current = ""; inArg = false }
            } else {
                current.append(ch); inArg = true
            }
        }
        if inArg { result.append(current) }
        return result
    }
}

// MARK: About

final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About LocalWeb"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: AboutView())
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AboutView: View {
    private let donationURL = URL(string: "https://www.paypal.com/donate/?hosted_button_id=FHGYWD46722JS")!

    var body: some View {
        VStack(spacing: 14) {
            if let iconURL = Bundle.main.url(forResource: "icon", withExtension: "png"),
               let icon = NSImage(contentsOf: iconURL) {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 88, height: 88)
            }
            Text("LocalWeb").font(.title2).bold()
            Text("Version \(appVersion)").foregroundStyle(.secondary)
            Text("Your local web servers, one click away.").font(.headline)
            Text("Free and open source (MIT). No account, no analytics.")
                .font(.caption).foregroundStyle(.secondary)
            Divider().padding(.vertical, 6)
            Link(destination: donationURL) {
                Label("Support GuruHat", systemImage: "heart.fill").frame(maxWidth: .infinity)
            }
            Text("Donations keep GuruHat apps free. Thank you!")
                .font(.caption).foregroundStyle(.secondary)
            Link("guruhat.com", destination: URL(string: "https://guruhat.com")!).font(.caption)
        }
        .padding(28)
        .frame(width: 390, height: 430)
    }
}
