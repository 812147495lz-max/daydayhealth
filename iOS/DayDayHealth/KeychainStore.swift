import Foundation
import Security

enum KeychainStore {
  private static let service = "DayDayHealth"
  private static let account = "api_key"

  static func save(_ token: String) throws {
    try saveData(Data(token.utf8), account: account)
  }

  static func saveDirectModel(_ configuration: DirectModelConfiguration) throws {
    try saveData(JSONEncoder().encode(configuration), account: "direct_model")
  }

  static func loadDirectModel() -> DirectModelConfiguration? {
    guard let data = loadData(account: "direct_model") else { return nil }
    return try? JSONDecoder().decode(DirectModelConfiguration.self, from: data)
  }

  struct MealNASConnection: Codable {
    let address: String
    let key: String
  }

  static func loadMealNAS() -> MealNASConnection? {
    guard let data = loadData(account: "meal_nas") else { return nil }
    return try? JSONDecoder().decode(MealNASConnection.self, from: data)
  }

  static func saveFNOS(_ credentials: FNOSWorkoutCredentials) throws {
    try saveData(JSONEncoder().encode(credentials), account: "fnos_workouts")
  }

  static func loadFNOS() -> FNOSWorkoutCredentials? {
    guard let data = loadData(account: "fnos_workouts") else { return nil }
    return try? JSONDecoder().decode(FNOSWorkoutCredentials.self, from: data)
  }

  static func clearFNOS() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "fnos_workouts"
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NSError(domain: "Keychain", code: Int(status))
    }
  }

  private static func saveData(_ data: Data, account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    let updates = [kSecValueData as String: data]
    let existing = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
    if existing == errSecSuccess { return }
    guard existing == errSecItemNotFound else {
      throw NSError(domain: "Keychain", code: Int(existing))
    }
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(domain: "Keychain", code: Int(status))
    }
  }

  static func load() -> String? {
    loadData(account: account).flatMap { String(data: $0, encoding: .utf8) }
  }

  private static func loadData(account: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
       let data = result as? Data else { return nil }
    return data
  }
}
