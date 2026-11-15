import Foundation
import SQLite3

/// Durable event queue shared by metric and workout collectors.
/// The event rows and the corresponding HealthKit anchor are committed in ONE transaction.
actor HealthOutboxDB {
  static let shared = HealthOutboxDB(archive: false)
  private var db: OpaquePointer?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  static let archive = HealthOutboxDB(archive: true)

  private let isArchive: Bool

  private init(archive: Bool) { isArchive = archive }

  private func open(archive: Bool) throws {
    guard db == nil else { return }
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
      in: .userDomainMask)[0]
    let directory = archive ? try AppleHealthArchiveFiles.directory() : appSupport
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("DayDayHealthHealthOutbox-v2.sqlite3")
    if sqlite3_open_v2(url.path, &db,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
      let failure = error()
      sqlite3_close(db)
      db = nil
      throw failure
    }
    do {
      try execute("PRAGMA journal_mode=WAL;")
      try execute("PRAGMA synchronous=FULL;")
      try execute("""
        CREATE TABLE IF NOT EXISTS events (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          namespace TEXT NOT NULL,
          kind TEXT NOT NULL,
          payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS ix_health_event_queue ON events(namespace, kind, id);
        CREATE TABLE IF NOT EXISTS anchors (key TEXT PRIMARY KEY, data BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS migrations (key TEXT PRIMARY KEY);
        """)
    } catch {
      sqlite3_close(db)
      db = nil
      throw error
    }
  }

  func prepareArchive() throws { try open(archive: true) }

  func archivePendingCount(namespace: String, kind: String) throws -> Int {
    let stmt = try prepare("SELECT count(*) FROM events WHERE namespace=? AND kind=?;")
    defer { sqlite3_finalize(stmt) }
    bind(namespace, to: stmt, at: 1)
    bind(kind, to: stmt, at: 2)
    guard sqlite3_step(stmt) == SQLITE_ROW else { throw error() }
    return Int(sqlite3_column_int64(stmt, 0))
  }

  func assignArchiveHistory(from device: String, to account: String, kind: String) throws {
    try transaction {
      let events = try prepare("UPDATE events SET namespace=? WHERE namespace=? AND kind=?;")
      defer { sqlite3_finalize(events) }
      bind(account, to: events, at: 1)
      bind(device, to: events, at: 2)
      bind(kind, to: events, at: 3)
      guard sqlite3_step(events) == SQLITE_DONE else { throw error() }

      let oldPrefix = device + "/"
      let newPrefix = account + "/"
      let anchors = try prepare("""
        INSERT OR IGNORE INTO anchors(key, data)
        SELECT ? || substr(key, length(?) + 1), data FROM anchors
        WHERE substr(key, 1, length(?)) = ?;
        """)
      defer { sqlite3_finalize(anchors) }
      for (index, value) in [newPrefix, oldPrefix, oldPrefix, oldPrefix].enumerated() {
        bind(value, to: anchors, at: Int32(index + 1))
      }
      guard sqlite3_step(anchors) == SQLITE_DONE else { throw error() }

      let remove = try prepare("DELETE FROM anchors WHERE substr(key, 1, length(?)) = ?;")
      defer { sqlite3_finalize(remove) }
      bind(oldPrefix, to: remove, at: 1)
      bind(oldPrefix, to: remove, at: 2)
      guard sqlite3_step(remove) == SQLITE_DONE else { throw error() }
    }
  }

  private func error() -> Error {
    NSError(domain: "DayDayHealthHealthOutbox", code: 1, userInfo: [
      NSLocalizedDescriptionKey: db.map { String(cString: sqlite3_errmsg($0)) }
        ?? "无法打开健康同步数据库"
    ])
  }
  private func ensure() throws -> OpaquePointer {
    if db == nil { try open(archive: isArchive) }
    guard let db else { throw error() }
    return db
  }
  private func execute(_ sql: String) throws {
    let db = try ensure()
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
  }
  private func prepare(_ sql: String) throws -> OpaquePointer {
    let db = try ensure()
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else { throw error() }
    return statement
  }
  private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
    sqlite3_bind_text(statement, index, value, -1, transient)
  }
  private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) {
    value.withUnsafeBytes { buffer in
      _ = sqlite3_bind_blob(statement, index, buffer.baseAddress,
        Int32(buffer.count), transient)
    }
  }
  private func transaction(_ work: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE;")
    do { try work(); try execute("COMMIT;") }
    catch { try? execute("ROLLBACK;"); throw error }
  }

  private func insert<T: Encodable>(_ values: [T], namespace: String, kind: String) throws {
    guard !values.isEmpty else { return }
    let statement = try prepare("INSERT INTO events(namespace,kind,payload) VALUES(?,?,?);")
    defer { sqlite3_finalize(statement) }
    let encoder = JSONEncoder()
    for value in values {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      bind(namespace, to: statement, at: 1)
      bind(kind, to: statement, at: 2)
      bind(try encoder.encode(value), to: statement, at: 3)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
  }

  /// A transaction includes both event inserts and the new query anchor.
  /// Empty pages still advance the anchor.
  func enqueue<T: Encodable>(_ values: [T], namespace: String, kind: String,
                            anchorKey: String? = nil, anchorData: Data? = nil) throws {
    try transaction {
      try insert(values, namespace: namespace, kind: kind)
      if let anchorKey, let anchorData {
        let stmt = try prepare("INSERT OR REPLACE INTO anchors(key,data) VALUES(?,?);")
        defer { sqlite3_finalize(stmt) }
        bind(anchorKey, to: stmt, at: 1)
        bind(anchorData, to: stmt, at: 2)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
      }
    }
  }

  /// Take a consistent SQLite snapshot, including rows still in the WAL.
  func backupData() throws -> Data {
    let source = try ensure()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite3")
    var destination: OpaquePointer?
    defer {
      sqlite3_close(destination)
      try? FileManager.default.removeItem(at: url)
    }
    guard sqlite3_open(url.path, &destination) == SQLITE_OK,
      let copy = sqlite3_backup_init(destination, "main", source, "main") else { throw error() }
    let step = sqlite3_backup_step(copy, -1)
    let finish = sqlite3_backup_finish(copy)
    guard step == SQLITE_DONE, finish == SQLITE_OK else { throw error() }
    return try Data(contentsOf: url)
  }

  func anchorData(for key: String) throws -> Data? {
    let stmt = try prepare("SELECT data FROM anchors WHERE key=?;")
    defer { sqlite3_finalize(stmt) }
    bind(key, to: stmt, at: 1)
    let result = sqlite3_step(stmt)
    if result == SQLITE_DONE { return nil }
    guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw error() }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
  }

  struct Queued<T> {
    let id: Int64
    let value: T
  }

  func peek<T: Decodable>(_ type: T.Type, namespace: String, kind: String,
                          limit: Int) throws -> [Queued<T>] {
    try peek(type, namespace: namespace, kind: kind, limit: limit, byteBudget: .max)
  }

  func peekArchive<T: Decodable>(_ type: T.Type, namespace: String, kind: String) throws -> [Queued<T>] {
    try peek(type, namespace: namespace, kind: kind, limit: 24, byteBudget: 1024 * 1024)
  }

  private func peek<T: Decodable>(_ type: T.Type, namespace: String, kind: String,
                                  limit: Int, byteBudget: Int) throws -> [Queued<T>] {
    let stmt = try prepare("SELECT id,payload FROM events WHERE namespace=? AND kind=? ORDER BY id LIMIT ?;")
    defer { sqlite3_finalize(stmt) }
    bind(namespace, to: stmt, at: 1)
    bind(kind, to: stmt, at: 2)
    sqlite3_bind_int(stmt, 3, Int32(max(1, min(limit, 1000))))
    let decoder = JSONDecoder()
    var output: [Queued<T>] = []
    var bytesLeft = byteBudget
    while true {
      let result = sqlite3_step(stmt)
      if result == SQLITE_DONE { return output }
      guard result == SQLITE_ROW else { throw error() }
      let size = Int(sqlite3_column_bytes(stmt, 1))
      if !output.isEmpty && size > bytesLeft { return output }
      guard let bytes = sqlite3_column_blob(stmt, 1) else { throw error() }
      let data = Data(bytes: bytes, count: size)
      output.append(Queued(id: sqlite3_column_int64(stmt, 0),
                           value: try decoder.decode(T.self, from: data)))
      if size >= bytesLeft { return output }
      bytesLeft -= size
    }
  }

  func acknowledge(_ ids: [Int64]) throws {
    guard !ids.isEmpty else { return }
    try transaction {
      let stmt = try prepare("DELETE FROM events WHERE id=?;")
      defer { sqlite3_finalize(stmt) }
      for id in ids {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
      }
    }
  }

  /// Copy the legacy JSON queue into SQLite exactly once. The old file is retained
  /// for a rollback; 'migrations' is committed atomically with the copied rows.
  func migrateLegacy<T: Codable>(_ type: T.Type, directory: String,
                                 namespace: String, kind: String) throws {
    let key = "\(directory)::\(namespace)::\(kind)"
    let check = try prepare("SELECT 1 FROM migrations WHERE key=?;")
    bind(key, to: check, at: 1)
    let migrated = sqlite3_step(check) == SQLITE_ROW
    sqlite3_finalize(check)
    if migrated { return }
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
      in: .userDomainMask)[0]
    let file = appSupport.appendingPathComponent(directory, isDirectory: true)
      .appendingPathComponent("\(namespace).json")
    let oldValues: [T]
    if FileManager.default.fileExists(atPath: file.path) {
      oldValues = try JSONDecoder().decode([T].self, from: Data(contentsOf: file))
    } else { oldValues = [] }
    try transaction {
      try insert(oldValues, namespace: namespace, kind: kind)
      let stmt = try prepare("INSERT INTO migrations(key) VALUES(?);")
      defer { sqlite3_finalize(stmt) }
      bind(key, to: stmt, at: 1)
      guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }
  }
}
