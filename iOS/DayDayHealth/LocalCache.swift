import Foundation
import CryptoKit

/// Server-isolated snapshots, preserving the last verified response when offline.
struct LocalCache {
  static func namespace(_ server: String) -> String {
    let digest = SHA256.hash(data: Data(server.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func path(server: String, resource: String) throws -> URL {
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appendingPathComponent("DayDayHealthCache", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true
    )
    return directory.appendingPathComponent("\(namespace(server))-\(resource).json")
  }

  static func save<T: Codable>(
    _ value: T, server: String, resource: String
  ) throws {
    let snapshot = CacheSnapshot(savedAt: Date(), data: value)
    let data = try JSONEncoder().encode(snapshot)
    try data.write(to: path(server: server, resource: resource), options: .atomic)
  }

  static func remove(server: String, resource: String) throws {
    try FileManager.default.removeItem(at: path(server: server, resource: resource))
  }

  static func load<T: Codable>(
    server: String, resource: String, as _: T.Type
  ) -> CacheSnapshot<T>? {
    guard let url = try? path(server: server, resource: resource),
      let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(CacheSnapshot<T>.self, from: data)
  }
}

struct CacheSnapshot<T: Codable>: Codable {
  let savedAt: Date
  let data: T
}
