import AppKit
import SwiftUI

/// For release-check.sh: opens the Settings window, saves each tab and the menu as a PNG,
/// and exits non-zero if a tab doesn't fit its window. Runs without the API, the menu or
/// notifications, and only with SERVERHAT_SUPPORT_FOLDER set, so it never reads or starts
/// the person's own servers.
enum Snapshot {
    static func run(to folder: URL) -> Never {
        guard let support = ProcessInfo.processInfo.environment["SERVERHAT_SUPPORT_FOLDER"], !support.isEmpty,
              ConfigStore.folder.standardizedFileURL.path == URL(fileURLWithPath: support).standardizedFileURL.path else {
            print("snapshot: set SERVERHAT_SUPPORT_FOLDER to an empty temporary folder first")
            exit(2)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let manager = ServerManager()
        let settings = SettingsWindowController.shared
        settings.show(manager: manager)

        var failures = 0
        let tabs = SettingsTab.Tab.allCases
        func shoot(_ index: Int) {
            guard index < tabs.count else { return shootMenu(manager: manager, to: folder) { exit(failures == 0 ? 0 : 1) } }
            settings.tab.current = tabs[index]
            // Give SwiftUI and the window a moment to settle on the new size.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let window = settings.window, let content = window.contentView, let frame = content.superview else { exit(1) }
                let name = tabs[index].rawValue.lowercased()
                let shown = window.contentLayoutRect.size, needed = content.fittingSize
                let fits = abs(shown.height - needed.height) < 1 && abs(shown.width - needed.width) < 1
                if !fits { failures += 1 }
                print("\(fits ? "ok  " : "FAIL") \(name): window \(Int(shown.width))×\(Int(shown.height)), content \(Int(needed.width))×\(Int(needed.height))")
                if let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("settings-\(name).png"))
                }
                shoot(index + 1)
            }
        }
        DispatchQueue.main.async { shoot(0) }
        app.run()
        exit(1)
    }

    /// Saves the menu panel as menu.png and menu-dark.png, after giving the folder's
    /// start-at-login servers a few seconds to come up (or crash). With servers.json in
    /// SERVERHAT_SUPPORT_FOLDER, these are the README pictures.
    private static func shootMenu(manager: ServerManager, to folder: URL, then done: @escaping () -> Void) {
        let updates = UpdateChecker(appName: "ServerHat", repo: "getguruhat/serverhat-macos")
        let api = APIServer(manager: manager)
        DispatchQueue.main.asyncAfter(deadline: .now() + (manager.servers.isEmpty ? 0 : 5)) {
            for (name, appearance) in [("menu", NSAppearance.Name.aqua), ("menu-dark", .darkAqua)] {
                let hosting = NSHostingView(rootView: MenuContent(manager: manager, updates: updates, api: api))
                hosting.appearance = NSAppearance(named: appearance)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
                }
                print("ok   \(name): \(Int(hosting.bounds.width))×\(Int(hosting.bounds.height))")
            }
            manager.shutdown()
            done()
        }
    }
}
