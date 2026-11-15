import Foundation

/// One local topic index per signed-in identity. No cross-account fallback.
struct ChatTopicEntry: Codable, Identifiable, Hashable {
  var id: String
  var title: String
  var createdAt: Date
  var updatedAt: Date
  var remoteConversationID: String?
  /// A device-local legacy topic is only imported into the device-only identity.
  var legacyCacheKey: String?
}

struct ChatTopicIndex: Codable {
  var selectedID: String
  var topics: [ChatTopicEntry]
}

enum ChatTopicStore {
  static let deviceIdentity = "device-only"

  static func identity() -> String {
    guard let session = KeychainStore.loadFNOS() else { return deviceIdentity }
    let id = session.userID ?? session.username ?? "unknown"
    return "fnos|\(session.server)|\(id)"
  }

  static func key(for identity: String) -> String {
    "wbTopics.v2.\(LocalCache.namespace(identity))"
  }
  static func cacheKey(for topic: ChatTopicEntry, identity: String) -> String {
    topic.legacyCacheKey ?? "conversation|\(identity)|\(topic.id)"
  }

  static func load(for identity: String) -> ChatTopicIndex {
    if let data = UserDefaults.standard.data(forKey: key(for: identity)),
       let saved = try? JSONDecoder().decode(ChatTopicIndex.self, from: data),
       !saved.topics.isEmpty { return saved }
    let now = Date()
    let legacy = identity == deviceIdentity
      ? UserDefaults.standard.string(forKey: "wbLocalChatTopic") : nil
    let legacyID = legacy.flatMap { $0.isEmpty ? nil : $0 }
    let topic = ChatTopicEntry(id: UUID().uuidString, title: "新话题", createdAt: now,
      updatedAt: now, remoteConversationID: nil, legacyCacheKey: legacyID)
    let index = ChatTopicIndex(selectedID: topic.id, topics: [topic])
    save(index, for: identity)
    return index
  }

  @MainActor
  static func addDailyDigest(_ report: DailyDigestReport, identity: String) throws {
    guard let content = report.openingMessage else { return }
    var index = load(for: identity)
    if let existing = index.topics.first(where: { $0.id == report.id }) {
      let key = cacheKey(for: existing, identity: identity)
      var messages = ConversationLine.localHistory(in: key)
      guard let first = messages.first, first.id == report.id, first.content != content else { return }
      messages[0] = ConversationLine(id: first.id, role: first.role, content: content, date: first.date)
      try LocalCache.save(messages, server: key, resource: ConversationLine.resource)
      return
    }
    let now = Date()
    let topic = ChatTopicEntry(id: report.id, title: "健康日报 · \(report.date)", createdAt: now,
      updatedAt: now, remoteConversationID: nil, legacyCacheKey: nil)
    let key = cacheKey(for: topic, identity: identity)
    if ConversationLine.localHistory(in: key).isEmpty {
      try LocalCache.save([ConversationLine(id: report.id, role: "assistant", content: content, date: now)],
        server: key, resource: ConversationLine.resource)
    }
    index.topics.insert(topic, at: 0)
    save(index, for: identity)
  }

  static func save(_ index: ChatTopicIndex, for identity: String) {
    guard let data = try? JSONEncoder().encode(index) else { return }
    UserDefaults.standard.set(data, forKey: key(for: identity))
  }
}
