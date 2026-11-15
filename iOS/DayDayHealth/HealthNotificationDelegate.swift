import Foundation
import UserNotifications

/// Handle task actions without requiring an open UI screen.
final class HealthNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  static let shared = HealthNotificationDelegate()

  static func registerCategories() {
    let go = UNNotificationAction(
      identifier: "WB_ACKNOWLEDGE", title: "去健身", options: []
    )
    let postpone = UNNotificationAction(
      identifier: "WB_POSTPONE", title: "延期一小时", options: []
    )
    let rest = UNNotificationAction(
      identifier: "WB_SKIP", title: "今天休息", options: []
    )
    let category = UNNotificationCategory(
      identifier: "WB_TASK_ACTIONS", actions: [go, postpone, rest],
      intentIdentifiers: [], options: []
    )
    UNUserNotificationCenter.current().setNotificationCategories([category])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    if notification.request.content.userInfo["wb_daily_digest"] != nil { return [.banner, .list, .sound] }
    return []
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let id = response.notification.request.content.userInfo["wb_daily_digest"] as? String {
      Task { @MainActor in
        DailyDigest.shared.open(id)
        completionHandler()
      }
      return
    }
    guard let taskID = response.notification.request.content.userInfo["task_id"]
        as? Int, taskID > 0 else {
      completionHandler()
      return
    }
    let action: String
    switch response.actionIdentifier {
    case "WB_ACKNOWLEDGE": action = "acknowledge"
    case "WB_POSTPONE": action = "postpone"
    case "WB_SKIP": action = "skip"
    default:
      completionHandler()
      return
    }
    Task {
      await NotificationActionQueue.shared.record(taskID: taskID, action: action)
      await NotificationActionQueue.shared.flush()
      completionHandler()
    }
  }
}

struct PendingNotificationAction: Codable {
  let id: String
  let server: String
  let taskID: Int
  let action: String
  let createdAt: Date
}

actor NotificationActionQueue {
  static let shared = NotificationActionQueue()
  private let key = "wbPendingNotificationActions"

  func record(taskID: Int, action: String) {
    var items = pending()
    items.append(PendingNotificationAction(
      id: UUID().uuidString,
      server: UserDefaults.standard.string(forKey: "wbServerURL") ?? "",
      taskID: taskID,
      action: action, createdAt: Date()
    ))
    save(items)
  }

  func flush() async {
    guard let server = UserDefaults.standard.string(forKey: "wbServerURL"),
      let apiKey = KeychainStore.load(), !apiKey.isEmpty else { return }
    let client = APIClient(server: server, apiKey: apiKey)
    var remaining: [PendingNotificationAction] = []
    for item in pending() {
      guard item.server == server else {
        remaining.append(item)
        continue
      }
      do {
        let tasks: [TaskItem] = try await client.send("/v1/tasks")
        guard let task = tasks.first(where: { $0.id == item.taskID }),
          !task.isTerminal else { continue }
        let dueAt = item.action == "postpone"
          ? ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
          : nil
        let object: [String: Any] = [
          "action": item.action, "expected_version": task.version,
          "due_at": dueAt as Any? ?? NSNull()
        ]
        let body = try JSONSerialization.data(withJSONObject: object)
        let _: TaskItem = try await client.send(
          "/v1/tasks/\(item.taskID)/action", method: "POST", body: body
        )
      } catch {
        remaining.append(item)
      }
    }
    save(remaining)
  }

  private func pending() -> [PendingNotificationAction] {
    guard let data = UserDefaults.standard.data(forKey: key),
      let rows = try? JSONDecoder().decode(
        [PendingNotificationAction].self, from: data
      ) else { return [] }
    return rows
  }

  private func save(_ actions: [PendingNotificationAction]) {
    guard let data = try? JSONEncoder().encode(actions) else { return }
    UserDefaults.standard.set(data, forKey: key)
  }
}
