import Foundation
import HealthKit

struct WorkoutPayload: Codable {
  let source: String
  let external_id: String
  let kind: String
  let started_at: Date
  let ended_at: Date
}

struct WorkoutOperation: Codable {
  let externalID: String
  let action: String
  let payload: WorkoutPayload?
}

/// Anchored HealthKit queries with a durable, per-server upload outbox.
actor HealthSync {
  static let shared = HealthSync()
  private let healthStore = HKHealthStore()
  private let batchSize = 200

  func synchronize(client: APIClient) async throws -> Int {
    let instanceID = try await LegacyServerIdentity.shared.instanceID(client: client)
    let namespace = LocalCache.namespace(client.server + instanceID)
    try await HealthOutboxDB.shared.migrateLegacy(WorkoutOperation.self,
      directory: "DayDayHealthHealthOutbox", namespace: namespace, kind: "workouts")
    var anchor = try await loadAnchor(namespace: namespace)
    var count = 0
    while true {
      try Task.checkCancellation()
      let page = try await fetch(anchor: anchor)
      guard let nextAnchor = page.anchor else { break }
      let operations = page.samples.compactMap { item -> WorkoutOperation? in
        guard let workout = item as? HKWorkout else { return nil }
        let kind: String
        switch workout.workoutActivityType {
        case .traditionalStrengthTraining, .functionalStrengthTraining:
          kind = "strength"
        case .running:
          kind = "running"
        default:
          kind = "other"
        }
        let payload = WorkoutPayload(
          source: "apple_health_workout", external_id: workout.uuid.uuidString,
          kind: kind, started_at: workout.startDate, ended_at: workout.endDate
        )
        return WorkoutOperation(
          externalID: workout.uuid.uuidString,
          action: "upsert", payload: payload
        )
      } + page.deleted.map {
        WorkoutOperation(externalID: $0.uuid.uuidString,
                         action: "delete", payload: nil)
      }
      // Workout operations and anchor move together in one SQLite transaction.
      let anchorData = try NSKeyedArchiver.archivedData(
        withRootObject: nextAnchor, requiringSecureCoding: true)
      try await HealthOutboxDB.shared.enqueue(operations, namespace: namespace,
        kind: "workouts", anchorKey: anchorKey(namespace: namespace), anchorData: anchorData)
      anchor = nextAnchor
      count += operations.count
      if page.samples.count + page.deleted.count < batchSize { break }
    }
    try await flush(client: client, namespace: namespace)
    return count
  }

  private struct QueryPage {
    let samples: [HKSample]
    let deleted: [HKDeletedObject]
    let anchor: HKQueryAnchor?
  }

  private func fetch(anchor: HKQueryAnchor?) async throws -> QueryPage {
    try await withCheckedThrowingContinuation { continuation in
      let query = HKAnchoredObjectQuery(
        type: HKObjectType.workoutType(), predicate: nil,
        anchor: anchor, limit: batchSize
      ) { _, samples, deleted, nextAnchor, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: QueryPage(
            samples: samples ?? [], deleted: deleted ?? [], anchor: nextAnchor
          ))
        }
      }
      healthStore.execute(query)
    }
  }

  private func anchorKey(namespace: String) -> String {
    "wbHealthAnchor-\(namespace)"
  }

  private func loadAnchor(namespace: String) async throws -> HKQueryAnchor? {
    let key = anchorKey(namespace: namespace)
    if let data = try await HealthOutboxDB.shared.anchorData(for: key) {
      return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
    guard let legacy = UserDefaults.standard.data(forKey: key) else { return nil }
    return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: legacy)
  }

  private func flush(client: APIClient, namespace: String) async throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    while true {
      let pending = try await HealthOutboxDB.shared.peek(WorkoutOperation.self,
        namespace: namespace, kind: "workouts", limit: 1)
      guard let queued = pending.first else { return }
      let item = queued.value
      if let payload = item.payload, item.action == "upsert" {
        let _: WorkoutUploadResult = try await client.send(
          "/v1/workouts", method: "POST", body: encoder.encode(payload))
      } else {
        let body = try JSONSerialization.data(withJSONObject: [
          "source": "apple_health_workout", "external_id": item.externalID
        ])
        let _: WorkoutDeletedResult = try await client.send(
          "/v1/workouts/delete", method: "POST", body: body)
      }
      try await HealthOutboxDB.shared.acknowledge([queued.id])
    }
  }

}

struct WorkoutDeletedResult: Decodable {
  let deleted: Bool
}
