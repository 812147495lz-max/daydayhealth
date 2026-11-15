import Foundation

/// Explicit outbound data sharing to a user-configured remote AI provider.
/// Independent of HealthKit read permissions and the chart privacy toggle.
enum AIDataAuthorization {
  enum Source: String, CaseIterable, Identifiable {
    case health, workouts, meals, sensitiveHealth
    var id: String { rawValue }
    var title: String {
      switch self {
      case .health: return "健康指标（后台和 Apple 健康）"
      case .workouts: return "训练记录"
      case .meals: return "饮食记录"
      case .sensitiveHealth: return "敏感及未分类健康指标（单独授权）"
      }
    }
  }

  static func allowed(_ source: Source, identity: String) -> Bool {
    UserDefaults.standard.bool(forKey: key(source, identity: identity))
  }
  static func set(_ value: Bool, for source: Source, identity: String) {
    UserDefaults.standard.set(value, forKey: key(source, identity: identity))
  }
  static func grantedSources(identity: String) -> [String] {
    Source.allCases.filter { $0 != .sensitiveHealth && allowed($0, identity: identity) }.map(\.rawValue)
  }
  static func sharesChatCity(identity: String) -> Bool {
    UserDefaults.standard.bool(forKey: "wbChatCitySharing.\(LocalCache.namespace(identity))")
  }

  static func setChatCitySharing(_ enabled: Bool, identity: String) {
    UserDefaults.standard.set(enabled, forKey: "wbChatCitySharing.\(LocalCache.namespace(identity))")
  }

  static func sharesChatEnvironment(identity: String) -> Bool {
    UserDefaults.standard.bool(forKey: "wbChatEnvironment.\(LocalCache.namespace(identity))")
  }

  static func setChatEnvironmentSharing(_ enabled: Bool, identity: String) {
    UserDefaults.standard.set(enabled, forKey: "wbChatEnvironment.\(LocalCache.namespace(identity))")
  }

  private static func key(_ source: Source, identity: String) -> String {
    "wbRemoteAIData.\(LocalCache.namespace(identity)).\(source.rawValue)"
  }
}
