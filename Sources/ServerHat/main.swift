import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import Combine

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var manager: ServerManager?
    private var api: APIServer?
    private var menu: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Rename.copyOldDefaults()
        let manager = ServerManager()
        AppDelegate.manager = manager
        Notifier.shared.start(manager: manager)
        let api = APIServer(manager: manager)
        api.start()
        self.api = api
        let updates = UpdateChecker(appName: "ServerHat", repo: "getguruhat/serverhat-macos")
        updates.start()
        menu = MenuController(manager: manager, updates: updates, api: api)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.manager?.shutdown()
    }
}

/// Started with plain AppKit, like AI Meter: the menu is MenuController's own status item
/// and panel, and a SwiftUI App needs a scene, which macOS opens as an empty window.
@main
enum Entry {
    static func main() {
        // `ServerHat --mcp` is the MCP server for Claude Code, Codex and other clients, not the app.
        if CommandLine.arguments.dropFirst().contains("--mcp") { MCPServer.run() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// The menu bar item and the panel it opens, as in AI Meter. A MenuBarExtra window doesn't
/// shrink when its content does (a server removed, a note gone), so this panel is always
/// sized to its content, centered under the item, with its top edge just below the menu bar.
final class MenuController: NSObject {
    private let manager: ServerManager
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: MenuPanel
    private let hosting: MenuHostingView
    private var watchers: Set<AnyCancellable> = []
    private var outsideClicks: Any?

    init(manager: ServerManager, updates: UpdateChecker, api: APIServer) {
        self.manager = manager
        hosting = MenuHostingView(rootView: MenuContent(manager: manager, updates: updates, api: api))
        panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()

        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.onEscape = { [weak self] in self?.close() }
        hosting.onResize = { [weak self] in self?.fit() }

        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading
        updateItem()
        // Read the new values after they change (objectWillChange fires before).
        manager.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.updateItem()
        }.store(in: &watchers)
        // Edit, logs, About, alerts and open panels sit below the menu's level, so the menu
        // gets out of their way.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] note in
                guard let self, (note.object as? NSWindow) !== self.panel else { return }
                self.close()
            }.store(in: &watchers)
    }

    private func updateItem() {
        let states = manager.states.values
        let running = states.filter { [.running, .starting, .unhealthy].contains($0.status) }.count
        let crashed = states.contains { $0.status == .crashed || $0.status == .failed || $0.status == .unhealthy }
        let pending = !manager.pendingApprovals.isEmpty
        let symbol = crashed ? "exclamationmark.triangle" : pending ? "hand.raised" : running > 0 ? "globe.americas.fill" : "globe.americas"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ServerHat")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.title = running > 0 ? " \(running)" : ""
    }

    @objc private func toggle() {
        panel.isVisible ? close() : show()
    }

    func show() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let size = hosting.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        item.button?.highlight(false)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }

    /// Resizes the open panel to its content, keeping the top edge where it is.
    private func fit() {
        guard panel.isVisible else { return }
        // Measured on the next pass, once SwiftUI has laid out the change.
        DispatchQueue.main.async { [self] in
            hosting.layoutSubtreeIfNeeded()
            let size = hosting.fittingSize
            var frame = panel.frame
            guard abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
            frame.origin.y = frame.maxY - size.height
            frame.origin.x = frame.midX - size.width / 2
            frame.size = size
            panel.setFrame(frame, display: true)
        }
    }
}

/// Tells the controller when the menu's content wants a different size, whatever changed
/// it (a server, an update, a "Copied" note).
final class MenuHostingView: NSHostingView<MenuContent> {
    var onResize: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onResize?()
    }
}

/// A borderless panel that can take clicks and Escape without activating the app.
final class MenuPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
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

/// A short confirmation, such as "Copied", that goes away by itself. (@State needs a macro plugin
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

    private var activeCount: Int { manager.states.values.filter { [.running, .starting, .unhealthy].contains($0.status) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if manager.servers.isEmpty { emptyState }

            if let error = manager.configError { notice(error, color: Theme.orange) }
            if let problem = api.problem { notice(problem, color: Theme.orange) }

            // Every server shares one card, as AI Meter's windows do, so the status colors
            // and buttons are what stands out.
            if !manager.servers.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    // With one server its own play and stop buttons are enough.
                    if manager.servers.count > 1 {
                        HStack(spacing: 6) {
                            Text("\(manager.servers.count) servers").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                            Spacer()
                            if activeCount < manager.servers.count {
                                Button("Start all") { manager.startAll() }.buttonStyle(TintButtonStyle(color: Theme.accent))
                            }
                            if manager.runningCount > 0 {
                                Button("Stop all") { manager.stopAll() }.buttonStyle(TintButtonStyle(color: Theme.red))
                            }
                        }
                        .frame(minHeight: 24)
                        Divider()
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(manager.servers.enumerated()), id: \.element.id) { index, server in
                                if index > 0 { Divider() }
                                ServerRow(manager: manager, server: server, state: manager.state(server.id))
                            }
                        }
                    }
                    .frame(maxHeight: 420)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .card(padding: 12)
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

        }
        .padding(12)
        .frame(width: 360)
        .foregroundStyle(Theme.text)
        .fixedSize(horizontal: false, vertical: true)
        // Opaque, in the panel's rounded shape. Light or dark follows the system, like the Theme colors.
        .background(Theme.page)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// What's running, then Add, Settings and Quit, on one row, like AI Meter's header.
    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "globe.americas.fill").font(.system(size: 13)).foregroundStyle(Theme.accent)
                Text("ServerHat").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                if activeCount > 0 {
                    Circle().fill(Theme.green).frame(width: 7, height: 7)
                    Text("\(activeCount) active").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.green)
                } else if !manager.servers.isEmpty {
                    Text("All stopped").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.stroke))

            Menu {
                Button("Add server…") { EditWindowController.show(manager: manager, editing: nil) }
                Divider()
                Button("Import project…") { importProject() }
                Button("Import .claude/launch.json…") { importLaunchJSON() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Theme.card))
            .overlay(Circle().strokeBorder(Theme.stroke))
            .help("Add or import servers").accessibilityLabel("Add or import servers")

            Button { SettingsWindowController.shared.show(manager: manager) } label: { Image(systemName: "gearshape") }
                .buttonStyle(CircleButtonStyle(size: 30, fill: Theme.card))
                .overlay(Circle().strokeBorder(Theme.stroke))
                .help("Settings and About").accessibilityLabel("Settings")

            Button { quit() } label: { Image(systemName: "power") }
                .buttonStyle(CircleButtonStyle(size: 30, fill: Theme.card))
                .overlay(Circle().strokeBorder(Theme.stroke))
                .help("Quit ServerHat (stops its servers)").accessibilityLabel("Quit ServerHat")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "globe.americas")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Theme.accent.opacity(0.13)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("No servers yet").font(.system(size: 15, weight: .semibold))
                    Text("Add one, import a project, or ask Claude Code or Codex.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 8) {
                Button("Add a server") { EditWindowController.show(manager: manager, editing: nil) }
                    .buttonStyle(PillButtonStyle(color: Theme.accent))
                HStack(spacing: 8) {
                    Button("Import project") { importProject() }
                        .buttonStyle(PillButtonStyle(color: Theme.control, foreground: Theme.text))
                    Button("Import launch.json") { importLaunchJSON() }
                        .buttonStyle(PillButtonStyle(color: Theme.control, foreground: Theme.text))
                }
            }
        }
        .card(padding: 12)
    }

    /// Quitting stops every server ServerHat started, so ask first when any are running.
    private func quit() {
        if manager.runningCount > 0 {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Quit ServerHat?"
            alert.informativeText = "It stops the \(manager.runningCount == 1 ? "server" : "\(manager.runningCount) servers") it's running."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        NSApplication.shared.terminate(nil)
    }

    private func notice(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 12)
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

    private func importProject() {
        let panel = NSOpenPanel()
        panel.title = "Import project servers"
        panel.message = "Choose a project folder. ServerHat looks for package.json, Procfile, and Docker Compose files."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        do {
            let added = try manager.importProject(at: url.path, approved: true)
            alert.messageText = added.isEmpty ? "Nothing new to import" : "Imported \(added.count) server\(added.count == 1 ? "" : "s")"
            alert.informativeText = added.isEmpty ? "Those project commands are already in ServerHat." : added.map { "\($0.name): \($0.command) \($0.args.joined(separator: " "))" }.joined(separator: "\n")
        } catch {
            alert.messageText = "Couldn't import project"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}

struct ServerRow: View {
    @ObservedObject var manager: ServerManager
    let server: ServerConfig
    let state: ServerState

    private var isActive: Bool { [.running, .starting, .stopping, .unhealthy].contains(state.status) }

    var body: some View {
        if manager.needsApproval(server.id) { pending } else { normal }
    }

    /// A server added or changed through the API or servers.json, waiting for the user.
    private var pending: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .layoutPriority(1).help(server.name)
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
                Button("Allow") {
                    manager.approve(server.id)
                    manager.startAndOpen(server.id)
                }
                .buttonStyle(TintButtonStyle(color: Theme.accent))
                Button("Remove") { confirmRemove() }.buttonStyle(TintButtonStyle(color: Theme.red))
                Spacer()
                Button("Edit…") { EditWindowController.show(manager: manager, editing: server) }
                    .buttonStyle(TintButtonStyle(color: Theme.secondary))
            }
        }
        .contentShape(Rectangle())
    }

    private var normal: some View {
        HStack(alignment: .center, spacing: 10) {
            // A plain colored symbol, not a circle, so it reads as status, not as a button.
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22)
                .accessibilityLabel(statusText)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(server.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .layoutPriority(1).help(server.name)
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
                    Text(detailText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(color == Theme.grey ? Theme.secondary : color)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            // Quiet grey buttons, so the status colors are what stands out. Restart only
            // while it's running (on a stopped server it's just Start), on the left, so Start
            // and Stop stay in one column.
            HStack(spacing: 6) {
                if state.status == .running || state.status == .unhealthy {
                    Button { try? manager.restart(server.id) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(CircleButtonStyle(size: 28))
                        .help("Restart").accessibilityLabel("Restart \(server.name)")
                }
                if isActive {
                    Button { manager.stop(server.id) } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(CircleButtonStyle(size: 28))
                        .help("Stop").accessibilityLabel("Stop \(server.name)")
                } else {
                    Button { manager.startAndOpen(server.id) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(CircleButtonStyle(size: 28, foreground: Theme.accent))
                        .disabled(state.status == .portInUse)
                        .help("Start").accessibilityLabel("Start \(server.name)")
                }
                Menu {
                    if let url = server.openURL {
                        Button("Open in browser") { NSWorkspace.shared.open(url) }
                    }
                    Button("View logs") { LogWindowController.show(manager: manager, server: server) }
                    Button("Edit…") { EditWindowController.show(manager: manager, editing: server) }
                    Button("Show folder in Finder") { NSWorkspace.shared.open(server.workingDirectory) }
                    if state.status == .portInUse, let pid = state.pid {
                        Divider()
                        Button("Stop process using port \(String(server.port ?? 0))…") { confirmKill(pid) }
                    }
                    Divider()
                    Button("Remove…") { confirmRemove() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.control))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Server menu").accessibilityLabel("Server menu for \(server.name)")
            }
        }
        .contentShape(Rectangle())
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
        case .unhealthy: return "Unhealthy"
        case .stopping: return "Stopping…"
        case .crashed: return "Crashed"
        case .portInUse: return "Port in use"
        case .failed: return "Couldn't start"
        }
    }

    private var detailText: String {
        let detail = state.detail ?? statusText
        guard state.detail == nil, state.status != .running, let port = server.port else { return detail }
        return "\(detail) · :\(port)"
    }

    private var symbol: String {
        switch state.status {
        case .running: return "bolt.fill"
        case .starting, .stopping: return "hourglass"
        case .crashed, .failed, .unhealthy: return "exclamationmark.triangle.fill"
        case .portInUse: return "exclamationmark.circle.fill"
        case .stopped: return "globe.americas"
        }
    }

    private var color: Color {
        switch state.status {
        case .running: return Theme.green
        case .starting, .stopping: return Theme.yellow
        case .crashed, .failed, .unhealthy: return Theme.red
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
        case .alertFirstButtonReturn:
            manager.approve(server.id)
            manager.startAndOpen(server.id)
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
    @Published var healthContains = ""
    @Published var env = ""
    @Published var startAtLogin = false
    @Published var restartOnCrash = false
    @Published var restartLimit = "3"
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var error: String?

    init(_ s: ServerConfig?) {
        guard let s else { return }
        name = s.name; cwd = s.cwd; command = s.command
        args = s.args.map(ServerManager.shellQuoted).joined(separator: " ")
        port = s.port.map(String.init) ?? ""
        url = s.url ?? ""
        healthContains = s.healthContains ?? ""
        env = s.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        startAtLogin = s.startAtLogin
        restartOnCrash = s.restartOnCrash
        restartLimit = String(s.restartLimit)
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
            TextField("Ready when response contains", text: $form.healthContains,
                      prompt: Text("optional; for example, a known page title"))
            VStack(alignment: .leading, spacing: 4) {
                Text("Environment (one NAME=value per line)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $form.env).font(.system(.body, design: .monospaced)).frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
            Toggle("Start this server when ServerHat starts", isOn: $form.startAtLogin)
            Toggle("Restart automatically after a crash", isOn: $form.restartOnCrash)
            if form.restartOnCrash {
                HStack {
                    Text("Maximum restart attempts")
                    Spacer()
                    TextField("3", text: $form.restartLimit).frame(width: 55)
                }
            }
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
                                  port: Int(portNumber), url: form.url.isEmpty ? nil : form.url,
                                  healthContains: form.healthContains.isEmpty ? nil : form.healthContains,
                                  env: environment, startAtLogin: form.startAtLogin,
                                  restartOnCrash: form.restartOnCrash, restartLimit: Int(form.restartLimit) ?? 3)
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

// MARK: Settings and About

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(manager: ServerManager) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // A hosting controller, not a hosting view: the window takes its preferred size, and
        // follows it when the tab or a message changes the content's height.
        let hosting = NSHostingController(rootView: SettingsView(manager: manager, login: LoginItem(), note: Note(), tab: SettingsTab()))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "ServerHat Settings"
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Whether ServerHat opens when you log in. Read from the system each time the window
/// opens, since it can also be changed in System Settings → General → Login Items.
final class LoginItem: ObservableObject {
    @Published var enabled = SMAppService.mainApp.status == .enabled
    @Published var problem: String?

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            problem = SMAppService.mainApp.status == .requiresApproval
                ? "Allow ServerHat in System Settings → General → Login Items." : nil
        } catch {
            problem = error.localizedDescription
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

/// Which tab the Settings window shows. (@State needs a macro plugin the command-line
/// toolchain lacks.)
final class SettingsTab: ObservableObject {
    enum Tab: String, CaseIterable { case settings = "Settings", about = "About" }
    @Published var current: Tab = .settings
}

struct SettingsView: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject var login: LoginItem
    @ObservedObject var note: Note
    @ObservedObject var tab: SettingsTab
    private let donationURL = URL(string: "https://www.paypal.com/donate/?hosted_button_id=FHGYWD46722JS")!

    var body: some View {
        VStack(spacing: 16) {
            tabSwitch
            switch tab.current {
            case .settings: settings
            case .about: about
            }
        }
        .padding(20)
        .frame(width: 390)
        .foregroundStyle(Theme.text)
        .background(Theme.page)
    }

    /// The same soft track and white pill as AI Meter's Codex/Claude switch.
    private var tabSwitch: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.Tab.allCases, id: \.self) { item in
                let selected = item == tab.current
                Button { tab.current = item } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Theme.text : Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(Capsule().fill(selected ? Theme.card : Color.clear)
                            .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1.5, y: 0.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .frame(width: 220)
    }

    private var settings: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open ServerHat at login").font(.system(size: 13, weight: .semibold))
                        Text("Servers set to start with ServerHat start too.")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Toggle("Open ServerHat at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                if let problem = login.problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(Theme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .card(padding: 12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Use from Claude Code or Codex").font(.system(size: 13, weight: .semibold))
                Text("Copies the command that adds ServerHat's MCP tools. Paste it in Terminal.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Copy for Claude Code") { copyMCP(client: "claude", label: "Claude Code") }
                        .buttonStyle(TintButtonStyle(color: Theme.accent))
                    Button("Copy for Codex") { copyMCP(client: "codex", label: "Codex") }
                        .buttonStyle(TintButtonStyle(color: Theme.accent))
                }
                if let copied = note.text {
                    Label(copied, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.green)
                }
            }
            .card(padding: 12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Your servers").font(.system(size: 13, weight: .semibold))
                Text("Save them to a file, or edit servers.json directly. ServerHat reloads it on save.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    // A Menu ignores button styles, so its label is drawn like TintButtonStyle.
                    Menu {
                        Button("Export servers…") { exportServers(includeEnvironment: false) }
                        Button("Export with environment values…") { exportServers(includeEnvironment: true) }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Export")
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(Theme.accent.opacity(0.12)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).fixedSize()
                    .disabled(manager.servers.isEmpty)
                    Button("Edit servers.json") { NSWorkspace.shared.open(manager.configFileURL) }
                        .buttonStyle(TintButtonStyle(color: Theme.accent))
                }
            }
            .card(padding: 12)
        }
    }

    private var about: some View {
        VStack(spacing: 12) {
            if let iconURL = Bundle.main.url(forResource: "icon", withExtension: "png"),
               let icon = NSImage(contentsOf: iconURL) {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 76, height: 76)
            }
            VStack(spacing: 4) {
                Text("ServerHat").font(.title2).bold()
                Text("Version \(appVersion)").foregroundStyle(.secondary)
                Text("Your local web servers, one click away.").font(.headline)
            }
            Text("Free and open source (MIT). No account, no analytics.")
                .font(.caption).foregroundStyle(.secondary)
            Divider().padding(.vertical, 2)
            Link(destination: donationURL) {
                Label("Support GuruHat", systemImage: "heart.fill").frame(maxWidth: .infinity)
            }
            .foregroundStyle(Theme.accent)
            Text("Donations keep GuruHat apps free. Thank you!")
                .font(.caption).foregroundStyle(.secondary)
            Link("guruhat.com", destination: URL(string: "https://guruhat.com")!).font(.caption).foregroundStyle(Theme.accent)
        }
    }

    private func exportServers(includeEnvironment: Bool) {
        let panel = NSSavePanel()
        panel.title = includeEnvironment ? "Export servers with environment values" : "Export servers"
        panel.nameFieldStringValue = "ServerHat-servers.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var servers = manager.servers
        if !includeEnvironment {
            for index in servers.indices { servers[index].env = [:] }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            var data = try encoder.encode(ConfigFile(servers: servers))
            data.append(0x0A)
            try data.write(to: url, options: .atomic)
            let alert = NSAlert()
            alert.messageText = "Servers exported"
            alert.informativeText = includeEnvironment
                ? "The export includes environment values. Treat the file as potentially sensitive."
                : "Environment values were omitted from the export."
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't export servers"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func copyMCP(client: String, label: String) {
        // The installed copy when there is one: a path to a development build breaks as
        // soon as that folder is renamed or rebuilt.
        let installed = "/Applications/ServerHat.app/Contents/MacOS/ServerHat"
        let binary = FileManager.default.isExecutableFile(atPath: installed) ? installed : (Bundle.main.executablePath ?? installed)
        let command = client == "claude"
            ? "claude mcp add --scope user serverhat -- \(ServerManager.shellQuoted(binary)) --mcp"
            : "codex mcp add serverhat -- \(ServerManager.shellQuoted(binary)) --mcp"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        note.show("Copied. Paste it in Terminal to add ServerHat to \(label).")
    }
}
