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
enum Entry {
    static func main() {
        // `ServerHat --mcp` is the MCP server for Claude Code, Codex and other clients, not the app.
        if CommandLine.arguments.dropFirst().contains("--mcp") { MCPServer.run() }
        ServerHatApp.main()
    }
}

struct ServerHatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var manager: ServerManager
    @StateObject private var updates: UpdateChecker
    private let api: APIServer

    init() {
        Rename.copyOldDefaults()
        let manager = ServerManager()
        AppDelegate.manager = manager
        Notifier.shared.start(manager: manager)
        let api = APIServer(manager: manager)
        api.start()
        self.api = api
        _manager = StateObject(wrappedValue: manager)
        let updates = UpdateChecker(appName: "ServerHat", repo: "getguruhat/serverhat-macos")
        updates.start()
        _updates = StateObject(wrappedValue: updates)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(manager: manager, updates: updates, api: api)
        } label: {
            let running = manager.states.values.filter { $0.status == .running || $0.status == .starting }.count
            let crashed = manager.states.values.contains { $0.status == .crashed || $0.status == .failed }
            let pending = !manager.pendingApprovals.isEmpty
            Image(systemName: crashed ? "exclamationmark.triangle" : pending ? "hand.raised" : running > 0 ? "globe.americas.fill" : "globe.americas")
            if running > 0 { Text("\(running)") }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: Theme

/// The menu's own palette, light or dark with the system appearance: a grey page,
/// cards that stand out from it, vivid accents.
enum Theme {
    static let page = dynamic(rgb(0.953, 0.957, 0.969), rgb(0.078, 0.078, 0.086))
    static let card = dynamic(.white, rgb(0.118, 0.122, 0.133))
    static let accent = dynamic(rgb(0.263, 0.384, 1.0), rgb(0.322, 0.435, 1.0))
    static let green = dynamic(rgb(0.086, 0.678, 0.369), rgb(0.263, 0.812, 0.494))
    static let red = dynamic(rgb(0.882, 0.227, 0.227), rgb(0.937, 0.333, 0.333))
    static let orange = dynamic(rgb(0.961, 0.502, 0.098), rgb(1.0, 0.616, 0.263))
    static let yellow = dynamic(rgb(0.937, 0.659, 0.0), rgb(1.0, 0.784, 0.231))
    static let text = dynamic(rgb(0.102, 0.110, 0.137), rgb(0.961, 0.965, 0.973))
    static let secondary = dynamic(rgb(0.420, 0.443, 0.494), rgb(0.616, 0.635, 0.678))
    static let grey = dynamic(rgb(0.600, 0.616, 0.651), rgb(0.494, 0.514, 0.557))
    static let stroke = dynamic(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.09))
    static let control = dynamic(rgb(0.937, 0.941, 0.953), rgb(0.180, 0.184, 0.200))

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

struct PillButtonStyle: ButtonStyle {
    var color: Color
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(Capsule().fill(color.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

/// A small tinted capsule, for secondary actions such as Start all.
struct TintButtonStyle: ButtonStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(color.opacity(configuration.isPressed ? 0.2 : 0.12)))
            .contentShape(Capsule())
    }
}

struct CircleButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var fill: Color = Theme.control
    var foreground: Color = Theme.text
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .contentShape(Circle())
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
    }
}

// MARK: Menu

/// A short confirmation under the menu, such as "Copied". (@State needs a macro plugin
/// the command-line toolchain lacks.)
final class Note: ObservableObject {
    @Published private(set) var text: String?
    private var hide: DispatchWorkItem?

    func show(_ text: String) {
        self.text = text
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.text = nil }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}

struct MenuContent: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject var updates: UpdateChecker
    let api: APIServer
    @StateObject private var note = Note()
    @StateObject private var window = MenuWindowShape()

    private var activeCount: Int { manager.states.values.filter { $0.status == .running || $0.status == .starting }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if manager.servers.isEmpty { emptyState }

            if let error = manager.configError { notice(error, color: Theme.orange) }
            if let problem = api.problem { notice(problem, color: Theme.orange) }

            if !manager.servers.isEmpty {
                HStack(spacing: 6) {
                    Text("Servers").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                    if activeCount > 0 {
                        Text("\(activeCount) running").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.green)
                    }
                    Spacer()
                    // With one server its own play and stop buttons are enough.
                    if manager.servers.count > 1 {
                        if activeCount < manager.servers.count {
                            Button("Start all") { manager.startAll() }.buttonStyle(TintButtonStyle(color: Theme.accent))
                        }
                        if manager.runningCount > 0 {
                            Button("Stop all") { manager.stopAll() }.buttonStyle(TintButtonStyle(color: Theme.red))
                        }
                    }
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 26)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(manager.servers) { server in
                            ServerRow(manager: manager, server: server, state: manager.state(server.id))
                        }
                    }
                }
                .frame(maxHeight: 400)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let update = updates.available {
                Link(destination: update.page) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.accent)
                        Text("ServerHat \(update.version) is available").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    }
                    .card(padding: 12)
                }
                .buttonStyle(.plain)
            }

            if let copied = note.text {
                Label(copied, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.green)
                    .padding(.horizontal, 4)
            }
        }
        .padding(14)
        .frame(width: 380)
        .foregroundStyle(Theme.text)
        // Opaque, in the window's own rounded shape (an opaque background otherwise fills
        // its corners square). Light or dark follows the system, like the Theme colors.
        .background(Theme.page)
        .clipShape(RoundedRectangle(cornerRadius: window.radius, style: .continuous))
        .background(MenuWindowReader(shape: window))
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "globe.americas.fill").font(.system(size: 16)).foregroundStyle(Theme.accent)
                Text("ServerHat").font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.stroke))

            Spacer()

            Button { EditWindowController.show(manager: manager, editing: nil) } label: { Image(systemName: "plus") }
                .buttonStyle(CircleButtonStyle(size: 32, fill: Theme.card))
                .overlay(Circle().strokeBorder(Theme.stroke))
                .help("Add server").accessibilityLabel("Add server")

            Menu {
                Button("Import .claude/launch.json…") { importLaunchJSON() }
                Button("Open servers.json") { NSWorkspace.shared.open(manager.configFileURL) }
                Divider()
                Button("Copy MCP setup for Claude Code") { copyMCP(client: "claude", label: "Claude Code") }
                Button("Copy MCP setup for Codex") { copyMCP(client: "codex", label: "Codex") }
                Divider()
                Button("About ServerHat") { AboutWindowController.shared.show() }
                Button("Quit ServerHat (stops its servers)") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32, height: 32)
            .background(Circle().fill(Theme.card))
            .overlay(Circle().strokeBorder(Theme.stroke))
            .help("More")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "globe.americas")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Theme.accent.opacity(0.13)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("No servers yet").font(.system(size: 19, weight: .semibold))
                    Text("Add one, import a launch.json, or ask Claude Code or Codex.")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button("Add a server") { EditWindowController.show(manager: manager, editing: nil) }
                    .buttonStyle(PillButtonStyle(color: Theme.accent))
                Button("Import launch.json") { importLaunchJSON() }
                    .buttonStyle(PillButtonStyle(color: Theme.control, foreground: Theme.text))
            }
        }
        .card(padding: 16)
    }

    private func notice(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 12)
    }

    private func copyMCP(client: String, label: String) {
        let binary = Bundle.main.executablePath ?? "/Applications/ServerHat.app/Contents/MacOS/ServerHat"
        let command = client == "claude"
            ? "claude mcp add --scope user serverhat -- \(ServerManager.shellQuoted(binary)) --mcp"
            : "codex mcp add serverhat -- \(ServerManager.shellQuoted(binary)) --mcp"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        note.show("Copied. Paste it in Terminal to add ServerHat to \(label).")
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
            let added = try manager.importLaunchJSON(at: url.path, approved: true)
            alert.messageText = added.isEmpty ? "Nothing new to import" : "Imported \(added.count) server\(added.count == 1 ? "" : "s")"
            alert.informativeText = added.isEmpty ? "Every configuration in that launch.json is already in ServerHat." : added.map(\.name).joined(separator: ", ")
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
        if manager.needsApproval(server.id) { pending } else { normal }
    }

    /// A server added or changed through the API or servers.json, waiting for the user.
    private var pending: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.orange.opacity(0.13)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(isActive ? "Changed. Allow the new settings to restart it." : "New. Allow it to run this command?")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.orange)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(ApprovalPrompt.commandLine(server))
                    .font(.system(size: 12, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                Text("in \(server.cwd)").font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                if !server.env.isEmpty {
                    Text("with " + server.env.keys.sorted().joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.control))
            HStack(spacing: 8) {
                Button("Allow") { manager.approve(server.id) }.buttonStyle(TintButtonStyle(color: Theme.accent))
                Button("Remove") { confirmRemove() }.buttonStyle(TintButtonStyle(color: Theme.red))
                Spacer()
                Button("Edit…") { EditWindowController.show(manager: manager, editing: server) }
                    .buttonStyle(TintButtonStyle(color: Theme.secondary))
            }
        }
        .card(padding: 12)
    }

    private var normal: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(Circle().fill(color.opacity(0.13)))
                .accessibilityLabel(statusText)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(server.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if let port = server.port, !(state.status == .running && server.openURL != nil) {
                        Text(":\(String(port))").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                    }
                }
                if state.status == .running, let url = server.openURL {
                    // The address itself, so a closed browser tab is one click away.
                    Button { NSWorkspace.shared.open(url) } label: {
                        HStack(spacing: 3) {
                            Text(ServerRow.display(url)).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(url.absoluteString)")
                } else {
                    Text(state.detail ?? statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(color == Theme.grey ? Theme.secondary : color)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                if isActive {
                    Button { manager.stop(server.id) } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(CircleButtonStyle(size: 32, fill: Theme.red, foreground: .white))
                        .help("Stop").accessibilityLabel("Stop \(server.name)")
                } else {
                    Button { try? manager.start(server.id) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(CircleButtonStyle(size: 32, fill: Theme.accent, foreground: .white))
                        .disabled(state.status == .portInUse)
                        .help("Start").accessibilityLabel("Start \(server.name)")
                }
                Button { try? manager.restart(server.id) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(CircleButtonStyle(size: 28))
                    .help("Restart").accessibilityLabel("Restart \(server.name)")
                Button { if let url = server.openURL { NSWorkspace.shared.open(url) } } label: { Image(systemName: "safari") }
                    .buttonStyle(CircleButtonStyle(size: 28))
                    .disabled(server.openURL == nil)
                    .help("Open in browser").accessibilityLabel("Open \(server.name) in browser")
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
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.control))
                .help("More")
            }
        }
        .card(padding: 12)
        .contextMenu {
            Button("View logs") { LogWindowController.show(manager: manager, server: server) }
            Button("Edit…") { EditWindowController.show(manager: manager, editing: server) }
        }
    }

    /// "127.0.0.1:4319" for http://127.0.0.1:4319/, keeping any path.
    static func display(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["http://", "https://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
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

    private var symbol: String {
        switch state.status {
        case .running: return "bolt.fill"
        case .starting, .stopping: return "hourglass"
        case .crashed, .failed: return "exclamationmark.triangle.fill"
        case .portInUse: return "exclamationmark.circle.fill"
        case .stopped: return "globe.americas"
        }
    }

    private var color: Color {
        switch state.status {
        case .running: return Theme.green
        case .starting, .stopping: return Theme.yellow
        case .crashed, .failed: return Theme.red
        case .portInUse: return Theme.orange
        case .stopped: return Theme.grey
        }
    }

    private func confirmRemove() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove \(server.name)?"
        alert.informativeText = "ServerHat stops it if it's running and forgets its settings. Its folder isn't touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { try? manager.remove(server.id) }
    }

    private func confirmKill(_ pid: pid_t) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Stop the process using port \(server.port ?? 0)?"
        alert.informativeText = (state.detail ?? "") + "\n\nServerHat didn't start it. It will be asked to quit (SIGTERM)."
        alert.addButton(withTitle: "Stop It")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { kill(pid, SIGTERM) }
    }
}

// MARK: Menu window

final class MenuWindowShape: ObservableObject {
    @Published var radius: CGFloat = 12
}

/// Finds the corner radius macOS gives the menu's window, hides the system's translucent
/// backdrop behind our opaque content (where that's possible), and makes the shadow
/// follow the rounded shape.
struct MenuWindowReader: NSViewRepresentable {
    let shape: MenuWindowShape

    func makeNSView(context: Context) -> NSView { Probe(shape: shape) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        let shape: MenuWindowShape
        init(shape: MenuWindowShape) { self.shape = shape; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let frame = window.contentView?.superview ?? window.contentView else { return }
                if let radius = Probe.cornerRadius(in: frame, skipping: window.contentView), radius > 0, radius != self.shape.radius {
                    self.shape.radius = radius
                }
                window.backgroundColor = .clear
                window.isOpaque = false
                Probe.hideBackdrops(in: frame, keeping: self)
                window.invalidateShadow()
            }
        }

        /// The window's own rounding, from the system views around our content.
        static func cornerRadius(in view: NSView, skipping content: NSView?) -> CGFloat? {
            if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView, glass.cornerRadius > 0 { return glass.cornerRadius }
            if let effect = view as? NSVisualEffectView, let mask = effect.maskImage, mask.capInsets.top > 0 { return mask.capInsets.top }
            if let radius = view.layer?.cornerRadius, radius > 0 { return radius }
            for subview in view.subviews where subview !== content {
                if let radius = cornerRadius(in: subview, skipping: content) { return radius }
            }
            return nil
        }

        /// Hides translucent backdrops that aren't drawn around our content, so only our
        /// clipped background shows and the corners can't disagree.
        static func hideBackdrops(in view: NSView, keeping content: NSView) {
            var isBackdrop = view is NSVisualEffectView
            if #available(macOS 26.0, *) { isBackdrop = isBackdrop || view is NSGlassEffectView }
            if isBackdrop && !content.isDescendant(of: view) { view.isHidden = true; return }
            for subview in view.subviews { hideBackdrops(in: subview, keeping: content) }
        }
    }
}

// MARK: Approval

enum ApprovalPrompt {
    static func commandLine(_ server: ServerConfig) -> String {
        ([server.command] + server.args).map(ServerManager.shellQuoted).joined(separator: " ")
    }

    /// The same choice as the menu's Allow and Remove, for when the user clicks the notification.
    static func ask(manager: ServerManager, server: ServerConfig) {
        guard manager.needsApproval(server.id) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow \(server.name) to run?"
        var details = "Command: \(commandLine(server))\nFolder: \(server.cwd)"
        if !server.env.isEmpty { details += "\nEnvironment: " + server.env.keys.sorted().joined(separator: ", ") }
        alert.informativeText = details + "\n\nIt was added or changed through ServerHat's API (for example by Claude Code or Codex) or in servers.json. It will run as you."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn: manager.approve(server.id)
        case .alertSecondButtonReturn: try? manager.remove(server.id)
        default: break
        }
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
        window.setFrameAutosaveName("ServerHatLogs")
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
            Toggle("Start this server when ServerHat starts", isOn: $form.startAtLogin)
            if form.startAtLogin {
                Toggle("Open ServerHat at login", isOn: $form.openAtLogin)
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
            // Saving here is the user's own change, so it counts as allowed.
            if let original { try manager.update(original.id, to: config, approved: true) } else { try manager.add(config, approved: true) }
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
        if SMAppService.mainApp.status == .requiresApproval { form.error = "Allow ServerHat in System Settings → General → Login Items." }
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
        window.title = "About ServerHat"
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
            Text("ServerHat").font(.title2).bold()
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
