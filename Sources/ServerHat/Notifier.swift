import AppKit
import UserNotifications

/// macOS notifications for things that happen while the menu is closed: a server
/// crashed, or a server added through the API is waiting for the user to allow it.
/// Permission is asked the first time there's something to say.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    weak var manager: ServerManager?

    private enum Kind: String { case crash, approval }

    /// nil outside an app bundle (swift run), where UNUserNotificationCenter would crash.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func start(manager: ServerManager) {
        self.manager = manager
        center?.delegate = self
    }

    func crashed(_ server: ServerConfig, detail: String) {
        post(.crash, server: server, title: T("{0} crashed", server.name), body: Loc.auto(detail) + " " + T("Click to see its log."))
    }

    func approvalNeeded(_ server: ServerConfig) {
        let command = ([server.command] + server.args).map(ServerManager.shellQuoted).joined(separator: " ")
        post(.approval, server: server, title: T("Review command for {0}", server.name),
             body: T("{0}\nin {1}. Click to review and allow.", command, server.cwd))
    }

    private func post(_ kind: Kind, server: ServerConfig, title: String, body: String) {
        guard let center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["kind": kind.rawValue, "id": server.id]
            // One per server and kind, so repeats replace each other.
            center.add(UNNotificationRequest(identifier: "\(kind.rawValue)-\(server.id)", content: content, trigger: nil))
        }
    }

    // ServerHat is a menu-bar app, so show banners even while it counts as active.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let kind = (info["kind"] as? String).flatMap(Kind.init)
        let id = info["id"] as? String ?? ""
        DispatchQueue.main.async { [weak self] in
            guard let manager = self?.manager, let server = manager.server(id) else { return }
            switch kind {
            case .crash: LogWindowController.show(manager: manager, server: server)
            case .approval: ApprovalPrompt.ask(manager: manager, server: server)
            case nil: break
            }
        }
        completionHandler()
    }
}
