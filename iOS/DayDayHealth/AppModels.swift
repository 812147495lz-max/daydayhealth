import Foundation

struct TaskItem: Codable, Identifiable {
  let id: Int
  let title: String
  let due_epoch: Double
  let status: String
  let version: Int

  var dueDate: Date { Date(timeIntervalSince1970: due_epoch) }
  var isTerminal: Bool {
    ["completed", "skipped", "cancelled"].contains(status)
  }

  var statusTitle: String {
    switch status {
    case "completed": return "已完成"
    case "skipped": return "已跳过"
    case "cancelled": return "已取消"
    case "acknowledged": return "已确认"
    case "scheduled": return "已安排"
    default: return "待执行"
    }
  }
}

struct WorkoutItem: Codable, Identifiable {
  let id: Int
  var external_id: String? = nil
  let source: String
  let kind: String
  let started_epoch: Double
  let ended_epoch: Double
  let sets: [ExerciseSetItem]

  var startDate: Date { Date(timeIntervalSince1970: started_epoch) }
  var durationMinutes: Int {
    max(0, Int((ended_epoch - started_epoch) / 60))
  }
}

struct ExerciseSetItem: Codable {
  let exercise: String
  let set_index: Int
  let repetitions: Double?
  let weight_kg: Double?
  let rpe: Double?
  var seconds: Double? = nil
  var rir: Double? = nil
  var warmup: Bool? = nil
  var side: String? = nil
}

struct ChatReply: Decodable {
  let conversation_id: String
  let answer: String
  let model: String
}

struct ChatHistoryItem: Codable, Identifiable {
  let id: Int
  let role: String
  let content: String
}

struct ChatInput: Encodable {
  let message: String
  let conversation_id: String?
}

struct CreateTaskInput: Encodable {
  let title: String
  let due_at: Date
  let request_id: String
}

struct TaskActionInput: Encodable {
  let action: String
  let expected_version: Int
  let due_at: Date?
}

struct GoalItem: Codable, Identifiable {
  let id: Int
  let title: String
  let target_per_week: Int
  let confirmed: Bool
  let active: Bool
  let version: Int
  let goal_type: String?
}

struct GoalInput: Encodable {
  let title: String
  let target_per_week: Int
  let confirmed: Bool
  let goal_type: String
}
