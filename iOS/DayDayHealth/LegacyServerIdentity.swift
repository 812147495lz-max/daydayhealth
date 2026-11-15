import Foundation

/// Avoids making collection depend on a round-trip to the legacy /v1/instance
/// endpoint once an instance has been verified at least once.
actor LegacyServerIdentity {
  static let shared = LegacyServerIdentity()

  func instanceID(client: APIClient) async throws -> String {
    let key = "wbLegacyInstanceID.\(LocalCache.namespace(client.server))"
    do {
      let instance: ServerInstance = try await client.send("/v1/instance")
      UserDefaults.standard.set(instance.instance_id, forKey: key)
      return instance.instance_id
    } catch {
      if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
        return saved
      }
      // On a never-connected device the server namespace is unknown; do not
      // invent a namespace and advance anchors into a mismatched queue.
      throw error
    }
  }
}
