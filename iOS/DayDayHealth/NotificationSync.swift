import Foundation
import UserNotifications

/// Reconcile the phone's actual pending notifications with the server snapshot.
struct NotificationSync {
  let client: APIClient

  func run(requestPermission: Bool = true) async throws -> Int {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    let allowed: Bool
    if settings.authorizationStatus == .authorized ||
        settings.authorizationStatus == .provisional {
      allowed = true
    } else if requestPermission {
      allowed = try await center.requestAuthorization(options: [.alert, .sound, .badge])
    } else {
      allowed = false
    }
    guard allowed else {
      throw NSError(domain: "DayDayHealth", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "通知权限未授予"])
    }
    HealthNotificationDelegate.registerCategories()
    let state: NotificationState = try await client.send("/v1/notifications/state")
    let previous = UserDefaults.standard.string(
      forKey: "wbNotificationInstance-\(LocalCache.namespace(client.server))"
    )
    let desired = Dictionary(
      state.commands.map { ($0.notification_key, $0) },
      uniquingKeysWith: { _, new in new }
    )
    let pending = await center.pendingNotificationRequests()
    let existing = pending.filter { $0.identifier.hasPrefix("daydayhealth-task-") }
    let existingIDs = Set(existing.map(\.identifier))
    let notificationTitle = "训练提醒"
    // Reconcile even when the server identity has not changed: local requests
    // can disappear after OS changes or task edits.
    let stale = existing.filter { request in
      guard let command = desired[request.identifier] else { return true }
      let oldEpoch = request.content.userInfo["fire_epoch"] as? Int
      return oldEpoch != command.fire_epoch || previous != state.instance_id
        || request.content.title != notificationTitle
    }.map(\.identifier)
    if !stale.isEmpty {
      center.removePendingNotificationRequests(withIdentifiers: stale)
      center.removeDeliveredNotifications(withIdentifiers: stale)
    }
    var changed = stale.count
    let removed = Set(stale)
    for command in state.commands {
      if existingIDs.contains(command.notification_key) &&
          !removed.contains(command.notification_key) {
        continue
      }
      let seconds = Double(command.fire_epoch) - Date().timeIntervalSince1970
      if seconds <= 0 { continue }
      let content = UNMutableNotificationContent()
      content.title = notificationTitle
      content.body = command.title
      content.sound = .default
      content.categoryIdentifier = "WB_TASK_ACTIONS"
      content.userInfo = [
        "task_id": command.task_id ?? 0,
        "fire_epoch": command.fire_epoch
      ]
      let trigger = UNTimeIntervalNotificationTrigger(
        timeInterval: max(1, seconds), repeats: false
      )
      let request = UNNotificationRequest(
        identifier: command.notification_key,
        content: content, trigger: trigger
      )
      try await center.add(request)
      let data = try JSONSerialization.data(withJSONObject: [
        "device_id": Self.deviceIdentifier(), "result": "scheduled_locally"
      ])
      let _: NotificationReceiptResult = try await client.send(
        "/v1/notifications/\(command.id)/receipt", method: "POST", body: data
      )
      changed += 1
    }
    UserDefaults.standard.set(state.instance_id,
      forKey: "wbNotificationInstance-\(LocalCache.namespace(client.server))")
    return changed
  }

  static func deviceIdentifier() -> String {
    if let old = UserDefaults.standard.string(forKey: "wbDeviceID") {
      return old
    }
    let id = UUID().uuidString
    UserDefaults.standard.set(id, forKey: "wbDeviceID")
    return id
  }
}
