import CryptoKit
import Foundation
import SwiftUI

struct AppBackupInfo: Decodable, Identifiable {
  let id: String
  let created_at: String
  let bytes: Int

  var date: Date? { ISO8601DateFormatter().date(from: created_at) }
}

private struct AppBackupArchive: Codable {
  let version: Int
  let account: String
  let preferences: [String: Data]
  let files: [String: Data]
  let healthQueue: Data?
  let legacyHealthState: [String: Data]?

  private static let commonKeys: Set<String> = [
    MealEntry.storageKey, MealGoalSettings.weightKey, MealGoalSettings.lossKey, MealGoalSettings.currentWeightKey,
    MealEnergyMath.completionKey, PackagedNutritionLabel.storageKey, "wbFavoriteHealthMetrics",
    "wbMealTrendFavoritesAdded", "wbSensitiveChartsEnabled", "wbLocalChatTopic", "wbConversationID"
  ]

  private static var support: URL { URL.applicationSupportDirectory }

  @MainActor static func capture(account: String, identity: String, healthQueue: Data?) throws -> Self {
    let identities = [identity, ChatTopicStore.deviceIdentity]
    let topicKeys = identities.map { ChatTopicStore.key(for: $0) }
    let defaults = UserDefaults.standard
    var preferences: [String: Data] = [:]
    for key in commonKeys.union(topicKeys) {
      if let value = defaults.object(forKey: key) {
        preferences[key] = try PropertyListSerialization.data(
          fromPropertyList: ["value": value], format: .binary, options: 0)
      }
    }

    var cacheNames: Set<String> = [LocalCache.namespace(account) + "-workout-sync-v1.json"]
    var topicResources: [String] = []
    for (topicKey, identity) in zip(topicKeys, identities) {
      guard let data = defaults.data(forKey: topicKey) else { continue }
      let index = try JSONDecoder().decode(ChatTopicIndex.self, from: data)
      topicResources += index.topics.map { ChatTopicStore.cacheKey(for: $0, identity: identity) }
    }
    if let legacy = defaults.string(forKey: "wbLocalChatTopic"), !legacy.isEmpty {
      topicResources.append(legacy)
    }
    for topic in topicResources {
      for resource in ["coach-history", "coach-summaries"] {
        cacheNames.insert(LocalCache.namespace(topic) + "-" + resource + ".json")
      }
    }

    var files: [String: Data] = [:]
    for name in cacheNames {
      let path = "DayDayHealthCache/" + name
      let url = support.appendingPathComponent(path)
      if FileManager.default.fileExists(atPath: url.path) { files[path] = try Data(contentsOf: url) }
    }
    let charts = support.appendingPathComponent("DayDayHealthChartCache-v1")
    if FileManager.default.fileExists(atPath: charts.path) {
      for url in try FileManager.default.contentsOfDirectory(at: charts, includingPropertiesForKeys: nil)
        where url.pathExtension == "json" {
        files["DayDayHealthChartCache-v1/" + url.lastPathComponent] = try Data(contentsOf: url)
      }
    }
    var legacyHealthState: [String: Data] = [:]
    for (key, value) in defaults.dictionaryRepresentation()
      where key.hasPrefix("wbHealthAnchor-") || key.hasPrefix("wbMetricAnchor-") {
      if let data = value as? Data { legacyHealthState["Preferences/" + key] = data }
    }
    for name in ["DayDayHealthHealthOutbox", "DayDayHealthMetricOutbox"] {
      let directory = support.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: directory.path) {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          where url.pathExtension == "json" {
          legacyHealthState[name + "/" + url.lastPathComponent] = try Data(contentsOf: url)
        }
      }
    }
    return Self(version: 1, account: account, preferences: preferences, files: files,
      healthQueue: healthQueue, legacyHealthState: legacyHealthState)
  }

  @MainActor func restore(account expected: String, identity: String, source: Data) throws {
    let allowedKeys = Self.commonKeys.union([identity, ChatTopicStore.deviceIdentity].map {
      ChatTopicStore.key(for: $0)
    })
    guard version == 1, account == expected, Set(preferences.keys).isSubset(of: allowedKeys),
      files.keys.allSatisfy({ $0.range(
        of: #"^(DayDayHealthCache|DayDayHealthChartCache-v1)/[a-f0-9]{64}([-][a-z0-9-]+)?[.]json$"#,
        options: .regularExpression) != nil }) else {
      throw APIClient.APIError.message("备份格式或所属账号不匹配。")
    }
    let values = try preferences.mapValues { data -> Any in
      guard let wrapper = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        let value = wrapper["value"] else {
        throw APIClient.APIError.message("备份中的设置无法读取。")
      }
      return value
    }
    let manager = FileManager.default
    // Keep the exact downloaded archive, including the device-bound upload queue.
    let recovery = Self.support.appendingPathComponent("AppBackupRecovery")
    try manager.createDirectory(at: recovery, withIntermediateDirectories: true)
    try source.write(to: recovery.appendingPathComponent("restored-\(Self.digest(source)).backup"),
      options: [.atomic, .completeFileProtectionUnlessOpen])

    var previous: [String: Data] = [:]
    var written: [String] = []
    for path in files.keys {
      let url = Self.support.appendingPathComponent(path)
      if manager.fileExists(atPath: url.path) { previous[path] = try Data(contentsOf: url) }
    }
    do {
      for (path, content) in files {
        let url = Self.support.appendingPathComponent(path)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        written.append(path)
      }
    } catch {
      for path in written {
        let url = Self.support.appendingPathComponent(path)
        if let data = previous[path] { try? data.write(to: url, options: .atomic) }
        else { try? manager.removeItem(at: url) }
      }
      throw error
    }
    for key in allowedKeys {
      if let value = values[key] { UserDefaults.standard.set(value, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

@MainActor final class AppBackup: ObservableObject {
  @Published private(set) var busy = false
  @Published private(set) var snapshots: [AppBackupInfo] = []
  @Published private(set) var message: String?
  @Published private(set) var revision = 0
  @AppStorage("wbAppBackupAccount") private var owner = ""
  @AppStorage("wbAppBackupLastSuccess") private var lastSuccess = 0.0
  private var displayedAccount: String?
  private let path = "/api/v1/app-backups"
  private let maxBytes = 64 * 1024 * 1024

  var isEnabled: Bool {
    !owner.isEmpty && owner == KeychainStore.loadFNOS()?.client.cacheAccount
  }

  func automaticBackup() async {
    guard isEnabled, Date().timeIntervalSince1970 - lastSuccess >= 6 * 3600 else { return }
    await upload(reload: false)
  }

  func refresh() async {
    await operation { credentials in
      snapshots = try await list(credentials)
    }
  }

  func upload(reload: Bool = true) async {
    await operation { credentials in
      let info = try await saveCurrent(credentials)
      owner = credentials.client.cacheAccount
      lastSuccess = Date().timeIntervalSince1970
      message = "备份成功"
      if reload {
        if !snapshots.contains(where: { $0.id == info.id }) { snapshots.insert(info, at: 0) }
      }
    }
  }

  func restore(_ backup: AppBackupInfo) async {
    await operation { credentials in
      let account = credentials.client.cacheAccount
      let identity = ChatTopicStore.identity()
      let data = try await request(path + "/" + backup.id, credentials: credentials)
      guard data.count == backup.bytes, AppBackupArchive.digest(data) == backup.id else {
        throw APIClient.APIError.message("备份校验失败。")
      }
      let archive = try PropertyListDecoder().decode(AppBackupArchive.self, from: data)
      guard archive.version == 1, archive.account == account else {
        throw APIClient.APIError.message("备份格式或所属账号不匹配。")
      }
      // Save the device's current records as a separate server version before replacing them.
      let checkpoint = try await saveCurrent(credentials)
      try assertCurrent(credentials)
      try archive.restore(account: account, identity: identity, source: data)
      if !snapshots.contains(where: { $0.id == checkpoint.id }) { snapshots.insert(checkpoint, at: 0) }
      owner = account
      lastSuccess = Date().timeIntervalSince1970
      revision += 1
      message = "恢复成功"
    }
  }

  private func list(_ credentials: FNOSWorkoutCredentials) async throws -> [AppBackupInfo] {
    let data = try await request(path, credentials: credentials)
    let entries = try JSONDecoder().decode([AppBackupInfo].self, from: data)
    guard entries.allSatisfy({
      $0.bytes > 0 && $0.bytes <= maxBytes
        && $0.id.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
    }) else {
      throw APIClient.APIError.message("服务器返回的备份清单无效。")
    }
    return entries
  }

  private func saveCurrent(_ credentials: FNOSWorkoutCredentials) async throws -> AppBackupInfo {
    let queue = try await HealthOutboxDB.shared.backupData()
    try assertCurrent(credentials)
    let archive = try AppBackupArchive.capture(account: credentials.client.cacheAccount,
      identity: ChatTopicStore.identity(), healthQueue: queue)
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let data = try encoder.encode(archive)
    guard data.count <= maxBytes else { throw APIClient.APIError.message("备份超过 64 MB，未上传。") }
    let response = try await request(path, credentials: credentials, payload: data)
    let info = try JSONDecoder().decode(AppBackupInfo.self, from: response)
    guard info.id == AppBackupArchive.digest(data), info.bytes == data.count else {
      throw APIClient.APIError.message("服务器备份校验失败。")
    }
    return info
  }

  private func operation(_ work: (FNOSWorkoutCredentials) async throws -> Void) async {
    guard !busy else { return }
    guard let credentials = KeychainStore.loadFNOS(), credentials.mustChangePassword != true else {
      snapshots = []
      message = "请先登录后端账号。"
      return
    }
    let account = credentials.client.cacheAccount
    if displayedAccount != account {
      snapshots = []
      displayedAccount = account
    }
    guard owner.isEmpty || owner == account else {
      message = "此设备的数据已绑定另一备份账号。"
      return
    }
    busy = true
    message = nil
    defer { busy = false }
    do { try await work(credentials) }
    catch is CancellationError {}
    catch { message = error.localizedDescription }
  }

  private func assertCurrent(_ credentials: FNOSWorkoutCredentials) throws {
    try Task.checkCancellation()
    guard KeychainStore.loadFNOS()?.client.cacheAccount == credentials.client.cacheAccount,
      KeychainStore.loadFNOS()?.token == credentials.token else { throw CancellationError() }
  }

  private func request(_ path: String, credentials: FNOSWorkoutCredentials,
                       payload: Data? = nil) async throws -> Data {
    var request = try credentials.client.makeRequest(path, method: payload == nil ? "GET" : "POST", body: payload)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    credentials.authorize(&request)
    if payload != nil { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
    let (data, response) = try await URLSession.shared.data(for: request, delegate: RejectHTTPRedirects())
    try assertCurrent(credentials)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    switch status {
    case 200: return data
    case 404: throw APIClient.APIError.message("后端尚未开通备份，或该备份已不可用。")
    case 413: throw APIClient.APIError.message("备份超过服务器允许的大小。")
    case 507: throw APIClient.APIError.message("远端备份空间已满。")
    default: throw APIClient.APIError.httpStatus(status)
    }
  }
}

struct AppBackupScreen: View {
  @EnvironmentObject private var backup: AppBackup
  @State private var selected: AppBackupInfo?

  var body: some View {
    Form {
      Section {
        Button("立即完整备份", systemImage: "arrow.up.circle") { Task { await backup.upload() } }
        if backup.busy { ProgressView() }
        if let message = backup.message { Text(message) }
      }
      Section("远端备份") {
        if backup.isEnabled { Text("自动备份已开启") }
        ForEach(backup.snapshots) { entry in
          Button {
            selected = entry
          } label: {
            LabeledContent(entry.date?.formatted(date: .abbreviated, time: .shortened) ?? entry.created_at,
              value: ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file))
          }
        }
        if backup.snapshots.isEmpty && !backup.busy { Text("暂无可用备份") }
      }
    }
    .navigationTitle("备份与恢复")
    .disabled(backup.busy)
    .task { await backup.refresh() }
    .refreshable { await backup.refresh() }
    .confirmationDialog("恢复这份备份？", isPresented: Binding(get: { selected != nil },
      set: { if !$0 { selected = nil } }), presenting: selected) { entry in
        Button("备份现有数据并恢复") { Task { await backup.restore(entry) } }
      } message: { _ in
        Text("此操作会替换本机记录。替换前会先保存一份远端备份。")
      }
  }
}
