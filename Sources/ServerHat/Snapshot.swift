import AppKit

/// For release-check.sh: opens the Settings window, saves each tab as a PNG, and exits
/// non-zero if a tab doesn't fit its window. Runs without the API, the menu or
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
            guard index < tabs.count else { exit(failures == 0 ? 0 : 1) }
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
}
