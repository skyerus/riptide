import Foundation
import RiptideCore
import Synchronization
import UserNotifications

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let current = Mutex<Delivery?>(nil)

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = request.content
        let data = content.userInfo
        guard let workspace = data["workspace"] as? String, let chat = data["chat"] as? String,
              let event = data["replyEventID"] as? String,
              let locator = NotificationReplyLocator(workspace: workspace, chat: chat, eventID: event),
              let store = NotificationReplyStore.shared else {
            contentHandler(content)
            return
        }
        let delivery = Delivery(content, handler: contentHandler)
        current.withLock { $0 = delivery }
        let download = Task {
            try? await store.download(locator)
            delivery.finish()
        }
        Task {
            try? await Task.sleep(for: .seconds(6))
            download.cancel()
            delivery.finish()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        current.withLock { $0 }?.finish()
    }
}

private final class Delivery: @unchecked Sendable {
    private let content: UNNotificationContent
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?

    init(_ content: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        self.content = content
        self.handler = handler
    }

    func finish() {
        let complete = lock.withLock {
            let complete = handler
            handler = nil
            return complete
        }
        complete?(content)
    }
}
