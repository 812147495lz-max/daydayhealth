import Foundation

struct SyncedWorkout: Codable, Identifiable {
  struct Exercise: Codable {
    struct Set: Codable {
      let index: Int
      let weight_kg: Double?
      let reps: Double?
      let seconds: Double?
      let rpe: Double?
      let rir: Double?
      let warmup: Bool?
      let side: String?
    }

    let id: String
    let name: String
    let sets: [Set]
  }

  let id: String
  let source: String
  let source_id: String
  let date: String?
  let started_at: Date?
  let ended_at: Date?
  let name: String
  let exercises: [Exercise]
}

struct WorkoutSyncPage: Decodable {
  struct Change: Decodable {
    enum Operation: String, Decodable { case upsert, delete }

    let op: Operation
    let workout_id: String
    let workout: SyncedWorkout?
  }

  let schema_version: Int
  let next_cursor: String
  let has_more: Bool
  let changes: [Change]

  static func decode(_ data: Data) throws -> Self {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let raw = try container.decode(String.self)
      if let date = try? Date(raw, strategy: .iso8601) { return date }
      let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
      if let date = try? Date(raw, strategy: fractional) {
        return date
      }
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
    }
    return try decoder.decode(Self.self, from: data)
  }
}

enum WorkoutSyncError: Error {
  case invalidCursor
  case invalidPage
}

struct WorkoutSyncState: Codable {
  let cursor: String
  let workouts: [String: SyncedWorkout]
  let completedAt: Date?
}

struct WorkoutSyncService {
  let account: String
  let fetch: (String?) async throws -> WorkoutSyncPage
  private let resource = "workout-sync-v1"

  var snapshot: WorkoutSyncState? {
    LocalCache.load(server: account, resource: resource, as: WorkoutSyncState.self)?.data
  }

  func synchronize() async throws {
    let initial = snapshot
    do {
      try await pull(initial)
    } catch WorkoutSyncError.invalidCursor where initial != nil {
      // Keep the previous snapshot visible until its replacement is complete.
      try await pull(nil)
    }
  }

  private func pull(_ initial: WorkoutSyncState?) async throws {
    var cursor = initial?.cursor
    var workouts = initial?.workouts ?? [:]
    var seenCursors = Set(cursor.map { [$0] } ?? [])
    while true {
      try Task.checkCancellation()
      let page = try await fetch(cursor)
      try Task.checkCancellation()
      guard page.schema_version == 1, !page.next_cursor.isEmpty,
        !page.has_more || seenCursors.insert(page.next_cursor).inserted else {
        throw WorkoutSyncError.invalidPage
      }

      for change in page.changes {
        guard !change.workout_id.isEmpty else { throw WorkoutSyncError.invalidPage }
        switch change.op {
        case .upsert:
          guard let workout = change.workout, workout.id == change.workout_id else {
            throw WorkoutSyncError.invalidPage
          }
          workouts[change.workout_id] = workout
        case .delete:
          guard change.workout == nil else { throw WorkoutSyncError.invalidPage }
          workouts.removeValue(forKey: change.workout_id)
        }
      }

      if initial != nil || !page.has_more {
        let state = WorkoutSyncState(
          cursor: page.next_cursor, workouts: workouts,
          completedAt: page.has_more ? initial?.completedAt : Date()
        )
        try LocalCache.save(state, server: account, resource: resource)
      }
      if !page.has_more { return }
      cursor = page.next_cursor
    }
  }
}
