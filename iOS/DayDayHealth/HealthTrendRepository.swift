import Foundation
import HealthKit
import CryptoKit

/// The same visible duration is applied to every metric, but statistics are type-specific.
enum HealthBucket: String, Codable, Sendable {
  case hour, day, week, month, year

  static func forDuration(_ duration: TimeInterval) -> HealthBucket {
    let days = duration / 86400
    if days <= 3 { return .hour }
    if days <= 60 { return .day }
    if days <= 550 { return .week }
    return days <= 3 * 365 ? .month : .year
  }

  var component: Calendar.Component {
    switch self {
    case .hour: return .hour
    case .day: return .day
    case .week: return .weekOfYear
    case .month: return .month
    case .year: return .year
    }
  }
  var interval: DateComponents {
    switch self {
    case .hour: return DateComponents(hour: 1)
    case .day: return DateComponents(day: 1)
    case .week: return DateComponents(weekOfYear: 1)
    case .month: return DateComponents(month: 1)
    case .year: return DateComponents(year: 1)
    }
  }
}

extension TrendPoint {
  func plotted(in range: ClosedRange<Date>, bucket: HealthBucket,
               calendar: Calendar = .current) -> TrendPoint? {
    guard date <= range.upperBound else { return nil }
    guard date < range.lowerBound else { return self }
    guard let interval = calendar.dateInterval(of: bucket.component, for: date),
          interval.end > range.lowerBound else { return nil }
    // A bucket may begin before the screen and still contain visible dates.
    // Place its summary inside the visible portion so a lone point is not clipped.
    let end = min(interval.end, range.upperBound)
    let visibleEpoch = range.lowerBound.addingTimeInterval(
      end.timeIntervalSince(range.lowerBound) / 2).timeIntervalSince1970
    return TrendPoint(epoch: visibleEpoch, value: value, sampleCount: sampleCount,
                      minimum: minimum, maximum: maximum, sampleID: sampleID)
  }
}

struct HealthMetricBounds: Sendable {
  let earliest: Date
  let latest: Date
}

struct HealthTimelineEvent: Identifiable, Sendable {
  let id: UUID
  let start: Date
  let end: Date
  let categoryValue: Int
  let source: String
}

enum MealTrendData {
  static let nutritionIDs = [
    "HKQuantityTypeIdentifierDietaryEnergyConsumed", "HKQuantityTypeIdentifierDietaryProtein",
    "HKQuantityTypeIdentifierDietaryFatTotal", "HKQuantityTypeIdentifierDietaryCarbohydrates"
  ]
  static let foodID = "HKCorrelationTypeIdentifierFood"
  static let identifiers = Set(nutritionIDs + [foodID])

  static func value(for meal: MealEntry, identifier: String) -> Double? {
    let foods = meal.items ?? []
    switch identifier {
    case nutritionIDs[0]:
      if !foods.isEmpty { return foods.reduce(0) { $0 + $1.kcal } }
      return meal.calories.map(Double.init)
    case nutritionIDs[1]: return foods.isEmpty ? nil : foods.reduce(0) { $0 + $1.protein }
    case nutritionIDs[2]: return foods.isEmpty ? nil : foods.reduce(0) { $0 + $1.fat }
    case nutritionIDs[3]: return foods.isEmpty ? nil : foods.reduce(0) { $0 + $1.carbs }
    default: return nil
    }
  }

  static func healthIDs(_ meals: [MealEntry]) -> Set<UUID> {
    Set(meals.flatMap { [$0.currentHealthRecordID] + ($0.retiredHealthRecords ?? []).map(\.id) })
  }

  static func excludingMeals(_ meals: [MealEntry], suffix: String = "") -> NSPredicate? {
    let ids = healthIDs(meals)
    guard !ids.isEmpty else { return nil }
    let existing = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier,
      allowedValues: ids.map { HealthMetricsSync.mealSyncIDPrefix + $0.uuidString + suffix })
    return NSCompoundPredicate(notPredicateWithSubpredicate: existing)
  }

  static func dailyPoints(_ meals: [MealEntry], identifier: String,
                          range: Range<Date>, calendar: Calendar) -> [Date: Double] {
    meals.reduce(into: [:]) { totals, meal in
      guard meal.isDeleted != true, range.contains(meal.date),
        let value = value(for: meal, identifier: identifier), value.isFinite, value >= 0 else { return }
      totals[calendar.startOfDay(for: meal.date), default: 0] += value
    }
  }
}

/// Range-limited HealthKit reads + bounded on-disk statistics cache.
/// This is intentionally independent of the HealthKit upload anchor and FNOS network.
actor HealthTrendRepository {
  static let shared = HealthTrendRepository()
  private let store = HKHealthStore()

  private struct Snapshot: Codable {
    let identifier: String
    let cachedAt: Date
    let points: [TrendPoint]
  }
  private var memory: [String: Snapshot] = [:]
  private var boundCache: [String: HealthMetricBounds] = [:]
  private var confirmedEmpty: Set<String> = []
  private var active: [String: Task<[TrendPoint], Error>] = [:]
  private let maxMemoryEntries = 48

  private func directory() throws -> URL {
    let folder = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
      .appendingPathComponent("DayDayHealthChartCache-v1", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }
  private func key(_ metric: HealthMetricDefinition, _ start: Date, _ end: Date,
                   _ bucket: HealthBucket, _ calendar: Calendar) -> String {
    // Calendar-derived bucket boundaries make adjacent views reuse cached results.
    let material = "v4|\(metric.identifier)|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(bucket.rawValue)|\(calendar.timeZone.identifier)"
    return SHA256.hash(data: Data(material.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
  private func isFresh(_ snapshot: Snapshot, end: Date) -> Bool {
    let ttl: TimeInterval = end < Date().addingTimeInterval(-2 * 86400) ? 7 * 86400 : 120
    return Date().timeIntervalSince(snapshot.cachedAt) < ttl
  }

  func series(for metric: HealthMetricDefinition, range: ClosedRange<Date>,
              bucket: HealthBucket, calendar: Calendar,
              refresh: Bool = false, preserveSamples: Bool = false) async throws -> [TrendPoint] {
    guard !metric.isSpecial, range.upperBound > range.lowerBound else { return [] }
    let start = calendar.dateInterval(of: bucket.component, for: range.lowerBound)?.start
      ?? range.lowerBound
    let endBucket = calendar.dateInterval(of: bucket.component, for: range.upperBound)
    let end = endBucket?.end ?? range.upperBound
    let cacheKey = key(metric, start, end, bucket, calendar) + (preserveSamples ? "-samples" : "")
    if !refresh {
      if let cached = memory[cacheKey], isFresh(cached, end: end) { return cached.points }
      if let cached = try? load(cacheKey), isFresh(cached, end: end) {
        memory[cacheKey] = cached
        return cached.points
      }
    }
    if let running = active[cacheKey] { return try await running.value }
    let task = Task { [self] in
      try await read(metric: metric, range: start...end, bucket: bucket, calendar: calendar,
                     preserveSamples: preserveSamples)
    }
    active[cacheKey] = task
    defer { active[cacheKey] = nil }
    let points = try await task.value
    let snapshot = Snapshot(identifier: metric.identifier, cachedAt: Date(), points: points)
    memory[cacheKey] = snapshot
    if memory.count > maxMemoryEntries { memory.removeAll(keepingCapacity: true); memory[cacheKey] = snapshot }
    try? save(snapshot, key: cacheKey)
    return points
  }

  func mealNutritionSeries(for metric: HealthMetricDefinition, range: ClosedRange<Date>,
                           meals: [MealEntry], calendar: Calendar) async throws -> [TrendPoint] {
    guard !meals.isEmpty else {
      return try await series(for: metric, range: range, bucket: .day, calendar: calendar)
    }
    let start = calendar.startOfDay(for: range.lowerBound)
    let end = calendar.dateInterval(of: .day, for: range.upperBound)?.end ?? range.upperBound
    guard end > start else { return [] }
    var totals = MealTrendData.dailyPoints(meals, identifier: metric.identifier,
      range: start..<end, calendar: calendar)
    do {
      if let type = metric.sampleType as? HKQuantityType, let info = metric.quantityInfo {
        let other = try await quantityStatistics(type: type, unit: info.unit,
          scale: metric.displayScale, range: start...end, bucket: .day, calendar: calendar,
          additionalPredicate: MealTrendData.excludingMeals(meals, suffix: "-" + metric.identifier))
        for point in other where point.date >= start && point.date < end {
          totals[point.date, default: 0] += point.value
        }
      }
    } catch {
      try Task.checkCancellation()
      if totals.isEmpty { throw error }
    }
    return totals.keys.sorted().map { TrendPoint(epoch: $0.timeIntervalSince1970, value: totals[$0] ?? 0) }
  }

  func mealTrendBounds(for metric: HealthMetricDefinition, meals: [MealEntry],
                       refresh: Bool = false) async throws -> HealthMetricBounds? {
    let isFood = metric.identifier == MealTrendData.foodID
    let local = meals.lazy.filter { meal in
      guard meal.isDeleted != true else { return false }
      if isFood { return true }
      return MealTrendData.value(for: meal, identifier: metric.identifier).map { $0.isFinite && $0 >= 0 } ?? false
    }.map(\.date)
    let firstLocal = local.min()
    let lastLocal = local.max()
    let type = isFood ? HKObjectType.correlationType(forIdentifier: .food) : metric.sampleType
    var firstHealth: Date?
    var lastHealth: Date?
    do {
      if let type, let predicate = MealTrendData.excludingMeals(meals, suffix: isFood ? "" : "-" + metric.identifier) {
        async let oldest = edgeDate(type: type, ascending: true, predicate: predicate)
        async let newest = edgeDate(type: type, ascending: false, predicate: predicate)
        (firstHealth, lastHealth) = try await (oldest, newest)
      } else if isFood, let type {
        async let oldest = edgeDate(type: type, ascending: true)
        async let newest = edgeDate(type: type, ascending: false)
        (firstHealth, lastHealth) = try await (oldest, newest)
      } else {
        let health = try await bounds(for: metric, refresh: refresh)
        (firstHealth, lastHealth) = (health?.earliest, health?.latest)
      }
    } catch {
      try Task.checkCancellation()
      if firstLocal == nil { throw error }
    }
    guard let first = [firstHealth, firstLocal].compactMap({ $0 }).min(),
      let last = [lastHealth, lastLocal].compactMap({ $0 }).max() else { return nil }
    return HealthMetricBounds(earliest: first, latest: last)
  }

  func hasRecords(for metric: HealthMetricDefinition) async throws -> Bool {
    let type: HKSampleType?
    switch metric.chart_template {
    case "bp_pair":
      type = HKObjectType.correlationType(forIdentifier: .bloodPressure)
    case "food_records":
      type = HKObjectType.correlationType(forIdentifier: .food)
    case "workout_sessions":
      type = HKObjectType.workoutType()
    default:
      type = metric.sampleType
    }
    guard let type else { return false }
    return try await edgeDate(type: type, ascending: false) != nil
  }

  /// Query just the first and last readable sample for a metric, never a fabricated
  /// fixed year. HealthKit does not reveal whether a zero-result query means denial.
  func bounds(for metric: HealthMetricDefinition, refresh: Bool = false) async throws -> HealthMetricBounds? {
    if !refresh {
      if let existing = boundCache[metric.identifier] { return existing }
      if confirmedEmpty.contains(metric.identifier) { return nil }
    }
    guard let type = metric.sampleType else { return nil }
    async let oldest = edgeDate(type: type, ascending: true)
    async let newest = edgeDate(type: type, ascending: false)
    guard let first = try await oldest, let last = try await newest else {
      confirmedEmpty.insert(metric.identifier)
      boundCache.removeValue(forKey: metric.identifier)
      return nil
    }
    let value = HealthMetricBounds(earliest: first, latest: last)
    boundCache[metric.identifier] = value
    confirmedEmpty.remove(metric.identifier)
    return value
  }

  private func edgeDate(type: HKSampleType, ascending: Bool, predicate: NSPredicate? = nil) async throws -> Date? {
    try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
          ascending: ascending)]) { _, samples, error in
        if let error { continuation.resume(throwing: error); return }
        continuation.resume(returning: samples?.first?.startDate)
      }
      store.execute(query)
    }
  }

  /// A sync report can invalidate a metric without deleting any HealthKit records.
  func invalidate(identifier: String) {
    boundCache.removeValue(forKey: identifier)
    confirmedEmpty.remove(identifier)
    memory = memory.filter { $0.value.identifier != identifier }
    guard let folder = try? directory(),
          let urls = try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: nil) else { return }
    for url in urls where url.pathExtension == "json" {
      if let data = try? Data(contentsOf: url),
         let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
         snapshot.identifier == identifier {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }

  private func load(_ key: String) throws -> Snapshot {
    let url = try directory().appendingPathComponent("\(key).json")
    return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
  }
  private func save(_ snapshot: Snapshot, key: String) throws {
    let url = try directory().appendingPathComponent("\(key).json")
    try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
  }

  private func read(metric: HealthMetricDefinition, range: ClosedRange<Date>,
                    bucket: HealthBucket, calendar: Calendar,
                    preserveSamples: Bool) async throws -> [TrendPoint] {
    guard let type = metric.sampleType else { return [] }
    if let quantityType = type as? HKQuantityType, let info = metric.quantityInfo {
      if preserveSamples {
        return try await quantitySamples(type: quantityType, unit: info.unit,
          scale: metric.displayScale, range: range)
      }
      let statistics = try await quantityStatistics(type: quantityType, unit: info.unit,
        scale: metric.displayScale, range: range, bucket: bucket, calendar: calendar)
      if quantityType.identifier == HKQuantityTypeIdentifier.heartRate.rawValue,
         statistics.contains(where: { $0.minimum == nil || $0.maximum == nil }) {
        let samples = try await quantitySamples(type: quantityType, unit: info.unit,
          scale: metric.displayScale, range: range)
        return heartRateRanges(samples, bucket: bucket, calendar: calendar)
      }
      return statistics
    }
    if type is HKCategoryType {
      let events = try await events(for: metric, range: range, limit: nil)
      return aggregateEvents(events, metric: metric, bucket: bucket, calendar: calendar)
    }
    return []
  }

  private func heartRateRanges(_ samples: [TrendPoint], bucket: HealthBucket,
                               calendar: Calendar) -> [TrendPoint] {
    // Samples are sorted by time. Fold each bucket once and pass only its summary to Charts.
    var ranges: [TrendPoint] = []
    var interval: DateInterval?
    var total = 0.0
    var count = 0
    var low = 0.0
    var high = 0.0

    func finishBucket() {
      guard let interval, count > 0 else { return }
      ranges.append(TrendPoint(epoch: interval.start.timeIntervalSince1970,
        value: total / Double(count), sampleCount: count, minimum: low, maximum: high))
    }

    for sample in samples {
      let date = sample.date
      if interval.map({ date >= $0.start && date < $0.end }) != true {
        finishBucket()
        interval = calendar.dateInterval(of: bucket.component, for: date)
        total = 0
        count = 0
        low = sample.value
        high = sample.value
      }
      total += sample.value
      count += 1
      low = min(low, sample.value)
      high = max(high, sample.value)
    }
    finishBucket()
    return ranges
  }

  private func quantitySamples(type: HKQuantityType, unit: HKUnit, scale: Double,
                               range: ClosedRange<Date>) async throws -> [TrendPoint] {
    let predicate = HKQuery.predicateForSamples(withStart: range.lowerBound,
      end: range.upperBound, options: .strictStartDate)
    return try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) {
        _, samples, error in
        if let error { continuation.resume(throwing: error); return }
        let points = (samples ?? []).compactMap { sample -> TrendPoint? in
          guard let sample = sample as? HKQuantitySample, sample.quantity.is(compatibleWith: unit)
          else { return nil }
          let value = sample.quantity.doubleValue(for: unit) * scale
          guard value.isFinite else { return nil }
          return TrendPoint(epoch: sample.startDate.timeIntervalSince1970,
                            value: value, sampleID: sample.uuid)
        }
        continuation.resume(returning: points)
      }
      store.execute(query)
    }
  }

  private func quantityStatistics(type: HKQuantityType, unit: HKUnit,
                                  scale: Double, range: ClosedRange<Date>,
                                  bucket: HealthBucket, calendar: Calendar,
                                  additionalPredicate: NSPredicate? = nil) async throws -> [TrendPoint] {
    let dates = HKQuery.predicateForSamples(withStart: range.lowerBound,
      end: range.upperBound, options: .strictStartDate)
    let predicate = additionalPredicate.map {
      NSCompoundPredicate(andPredicateWithSubpredicates: [dates, $0])
    } ?? dates
    let options: HKStatisticsOptions
    switch type.aggregationStyle {
    case .cumulative:
      options = .cumulativeSum
    case .discreteArithmetic:
      options = [.discreteAverage, .discreteMin, .discreteMax]
    case .discreteTemporallyWeighted, .discreteEquivalentContinuousLevel:
      options = .discreteAverage
    @unknown default:
      return []
    }
    let anchor = calendar.dateInterval(of: bucket.component, for: range.lowerBound)?.start
      ?? range.lowerBound
    return try await withCheckedThrowingContinuation { continuation in
      let query = HKStatisticsCollectionQuery(quantityType: type,
        quantitySamplePredicate: predicate, options: options,
        anchorDate: anchor, intervalComponents: bucket.interval)
      query.initialResultsHandler = { _, results, error in
        if let error { continuation.resume(throwing: error); return }
        guard let results else { continuation.resume(returning: []); return }
        var points: [TrendPoint] = []
        results.enumerateStatistics(from: range.lowerBound, to: range.upperBound) { statistic, _ in
          func converted(_ quantity: HKQuantity?) -> Double? {
            guard let quantity, quantity.is(compatibleWith: unit) else { return nil }
            let value = quantity.doubleValue(for: unit) * scale
            return value.isFinite ? value : nil
          }
          let central = options.contains(.cumulativeSum) ? statistic.sumQuantity() : statistic.averageQuantity()
          guard let value = converted(central) else { return }
          let minimum = options.contains(.discreteMin) ? converted(statistic.minimumQuantity()) : nil
          let maximum = options.contains(.discreteMax) ? converted(statistic.maximumQuantity()) : nil
          points.append(TrendPoint(epoch: statistic.startDate.timeIntervalSince1970,
            value: value, sampleCount: nil, minimum: minimum, maximum: maximum))
        }
        continuation.resume(returning: points.sorted { $0.epoch < $1.epoch })
      }
      store.execute(query)
    }
  }

  struct WorkoutSnapshot: Sendable {
    let date: Date
    let name: String
    let minutes: Double
  }

  func recentWorkouts(from start: Date, to end: Date, limit: Int? = 64) async throws -> [WorkoutSnapshot] {
    let type = HKObjectType.workoutType()
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
      options: .strictStartDate)
    return try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit ?? HKObjectQueryNoLimit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) {
        _, samples, error in
        if let error { continuation.resume(throwing: error); return }
        let workouts = (samples ?? []).compactMap { sample -> WorkoutSnapshot? in
          guard let workout = sample as? HKWorkout, workout.startDate < end else { return nil }
          let name: String
          switch workout.workoutActivityType {
          case .traditionalStrengthTraining, .functionalStrengthTraining: name = "力量训练"
          case .running: name = "跑步"
          case .walking: name = "步行"
          case .hiking: name = "徒步"
          case .cycling: name = "骑行"
          case .swimming: name = "游泳"
          case .yoga: name = "瑜伽"
          case .pilates: name = "普拉提"
          case .highIntensityIntervalTraining: name = "高强度间歇训练"
          case .elliptical: name = "椭圆机"
          case .rowing: name = "划船"
          case .dance: name = "舞蹈"
          default: name = "其他锻炼"
          }
          return WorkoutSnapshot(date: workout.startDate, name: name, minutes: workout.duration / 60)
        }
        continuation.resume(returning: workouts)
      }
      store.execute(query)
    }
  }

  func events(for metric: HealthMetricDefinition, range: ClosedRange<Date>,
              limit: Int? = 2000) async throws -> [HealthTimelineEvent] {
    guard let type = metric.sampleType as? HKCategoryType else { return [] }
    let predicate = HKQuery.predicateForSamples(withStart: range.lowerBound,
      end: range.upperBound, options: [])
    return try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit ?? HKObjectQueryNoLimit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) {
        _, samples, error in
        if let error { continuation.resume(throwing: error); return }
        let result = (samples ?? []).compactMap { sample -> HealthTimelineEvent? in
          guard let item = sample as? HKCategorySample else { return nil }
          return HealthTimelineEvent(id: item.uuid, start: item.startDate,
            end: item.endDate, categoryValue: item.value,
            source: item.sourceRevision.source.name)
        }
        continuation.resume(returning: result.sorted { $0.start < $1.start })
      }
      store.execute(query)
    }
  }

  private func aggregateEvents(_ events: [HealthTimelineEvent],
                               metric: HealthMetricDefinition,
                               bucket: HealthBucket, calendar: Calendar) -> [TrendPoint] {
    var totals: [Date: Double] = [:]
    var counts: [Date: Int] = [:]
    if metric.chart_template == "sleep_stages" {
      // Count only asleep stages; union overlapping samples to avoid cross-device double counting.
      let asleep = events.filter { [1, 3, 4, 5].contains($0.categoryValue) && $0.end > $0.start }
      var union: [(Date, Date)] = []
      for event in asleep.sorted(by: { $0.start < $1.start }) {
        if let last = union.last, event.start <= last.1 {
          union[union.count - 1].1 = max(last.1, event.end)
        } else { union.append((event.start, event.end)) }
      }
      for (start, end) in union {
        let day = calendar.startOfDay(for: end.addingTimeInterval(-1))
        let date = calendar.dateInterval(of: bucket.component, for: day)?.start ?? day
        totals[date, default: 0] += end.timeIntervalSince(start) / 3600
        counts[date, default: 0] += 1
      }
    } else if metric.chart_template == "mindfulness" {
      for event in events where event.end > event.start {
        let date = calendar.dateInterval(of: bucket.component, for: event.start)?.start
          ?? calendar.startOfDay(for: event.start)
        totals[date, default: 0] += event.end.timeIntervalSince(event.start) / 60
        counts[date, default: 0] += 1
      }
    } else if metric.chart_template == "stand_hour" {
      // Apple's stand-hour value 1 represents a standing hour; only count it once.
      var hours = Set<Date>()
      for event in events where event.categoryValue == 1 {
        if let hour = calendar.dateInterval(of: .hour, for: event.start)?.start {
          hours.insert(hour)
        }
      }
      for hour in hours {
        let date = calendar.dateInterval(of: bucket.component, for: hour)?.start ?? hour
        totals[date, default: 0] += 1
        counts[date, default: 0] += 1
      }
    } else {
      for event in events {
        let date = calendar.dateInterval(of: bucket.component, for: event.start)?.start
          ?? calendar.startOfDay(for: event.start)
        totals[date, default: 0] += 1
        counts[date, default: 0] += 1
      }
    }
    return totals.keys.sorted().map { date in
      TrendPoint(epoch: date.timeIntervalSince1970, value: totals[date] ?? 0,
                 sampleCount: counts[date], minimum: nil, maximum: nil)
    }
  }
}
