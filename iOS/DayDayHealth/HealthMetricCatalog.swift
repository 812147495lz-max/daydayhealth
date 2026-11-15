import Foundation
import HealthKit

/// 194 entries are defined in HealthMetricCatalog.json; do not infer availability from the catalog.
struct HealthMetricDefinition: Codable, Identifiable, Hashable, Sendable {
  let identifier: String
  let source: String
  let label_zh: String
  let group: String
  let chart_template: String
  let display_unit: String
  let source_unit: String
  let category: String
  let privacy_class: String
  let aggregation_rule: String
  let quality_rule: String
  let visibility: String
  let min_ios_version: String?

  var id: String { identifier }
  var title: String { chart_template == "food_records" ? "饮食记录" : label_zh }
  var isSensitive: Bool { privacy_class == "sensitive_health" }
  var isSpecial: Bool { source == "probe_special" || identifier == "HKWorkout" || identifier.contains("CorrelationTypeIdentifierFood") }
  var isEvent: Bool { identifier.hasPrefix("HKCategoryTypeIdentifier") }

  var sampleType: HKSampleType? {
    if identifier.hasPrefix("HKQuantityTypeIdentifier") {
      return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier))
    }
    if isEvent {
      return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier))
    }
    return nil
  }

  /// The runtime HKUnit remains the original HealthKit-compatible unit; the display
  /// conversion is applied only after reading it (e.g. g→mg, m→km).
  var displayScale: Double {
    switch (source_unit, display_unit) {
    case ("m", "cm"): return 100
    case ("m", "km"): return 0.001
    case ("g", "mg"): return 1_000
    case ("g", "µg"), ("g", "μg"): return 1_000_000
    default: return 1
    }
  }

  var quantityInfo: (unit: HKUnit, kind: String, cumulative: Bool)? {
    guard identifier.hasPrefix("HKQuantityTypeIdentifier") else { return nil }
    if let core = HealthMetricsSync.quantitySpec(identifier) {
      let cumulative = Set(["step_count", "active_energy", "resting_energy",
        "walking_running_distance", "exercise_time", "flights_climbed",
        "dietary_energy", "dietary_protein", "dietary_fat", "dietary_carbohydrates"])
        .contains(core.kind)
      return (core.unit, core.kind, cumulative)
    }
    guard let extra = AdditionalHealthMetric.byIdentifier[identifier], extra.mode != .event else {
      return nil
    }
    return (extra.quantityUnit, extra.kind, extra.mode == .total)
  }
}

struct HealthMetricCatalog {
  private struct Resource: Decodable { let version: Int; let metrics: [HealthMetricDefinition] }

  static let all: [HealthMetricDefinition] = {
    guard let url = Bundle.main.url(forResource: "HealthMetricCatalog", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let resource = try? JSONDecoder().decode(Resource.self, from: data),
          resource.version == 1, resource.metrics.count == 194 else {
      // Do not silently replace the catalog with an invented list.
      return []
    }
    return resource.metrics
  }()

  static let mainIdentifiers: [String] = [
    "HKQuantityTypeIdentifierBodyMass", "HKQuantityTypeIdentifierRestingHeartRate",
    "HKQuantityTypeIdentifierStepCount", "HKCategoryTypeIdentifierSleepAnalysis",
    "HKQuantityTypeIdentifierActiveEnergyBurned", "HKQuantityTypeIdentifierDietaryEnergyConsumed",
    "HKQuantityTypeIdentifierDietaryProtein", "HKQuantityTypeIdentifierHeartRate"
  ]

  static func preferred(_ metric: HealthMetricDefinition) -> Bool {
    mainIdentifiers.contains(metric.identifier)
  }
}
