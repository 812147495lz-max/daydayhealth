import Foundation
import SwiftUI
import Charts
import HealthKit

struct BloodPressurePair: Identifiable, Sendable {
  let id: UUID
  let date: Date
  let systolic: Double
  let diastolic: Double
  let sourceName: String
}

struct HealthFoodCorrelation: Identifiable, Sendable {
  let id: UUID
  let date: Date
  let name: String?
  let energyKcal: Double?
  let sourceName: String
}

/// Correct composite samples. Never pair unrelated BP numbers by nearest time.
actor HealthCorrelationRepository {
  static let shared = HealthCorrelationRepository()
  private let health = HKHealthStore()

  private func correlations(_ identifier: HKCorrelationTypeIdentifier,
                            in range: ClosedRange<Date>, limit: Int = 400,
                            excluding: NSPredicate? = nil) async throws -> [HKCorrelation] {
    guard let type = HKObjectType.correlationType(forIdentifier: identifier) else { return [] }
    let dates = HKQuery.predicateForSamples(withStart: range.lowerBound,
      end: range.upperBound, options: [])
    let predicate = excluding.map { NSCompoundPredicate(andPredicateWithSubpredicates: [dates, $0]) } ?? dates
    return try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
          ascending: false)]) { _, samples, error in
          if let error { continuation.resume(throwing: error); return }
          continuation.resume(returning: (samples ?? []).compactMap { $0 as? HKCorrelation })
        }
      health.execute(query)
    }
  }

  func bloodPressure(in range: ClosedRange<Date>) async throws -> [BloodPressurePair] {
    let rows = try await correlations(.bloodPressure, in: range, limit: HKObjectQueryNoLimit)
    return rows.compactMap { pair -> BloodPressurePair? in
      let samples = pair.objects.compactMap { $0 as? HKQuantitySample }
      let systolic = samples.first {
        $0.quantityType.identifier == HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue
      }
      let diastolic = samples.first {
        $0.quantityType.identifier == HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue
      }
      guard let s = systolic, let d = diastolic else { return nil }
      return BloodPressurePair(id: pair.uuid, date: pair.startDate,
        systolic: s.quantity.doubleValue(for: .millimeterOfMercury()),
        diastolic: d.quantity.doubleValue(for: .millimeterOfMercury()),
        sourceName: pair.sourceRevision.source.name)
    }.sorted { $0.date < $1.date }
  }

  func foods(in range: ClosedRange<Date>, meals: [MealEntry]) async throws -> [HealthFoodCorrelation] {
    let local = meals.filter { $0.isDeleted != true && range.contains($0.date) }.map {
      HealthFoodCorrelation(id: $0.id, date: $0.date, name: $0.food,
        energyKcal: MealTrendData.value(for: $0, identifier: MealTrendData.nutritionIDs[0]),
        sourceName: "天天健康")
    }
    let rows: [HKCorrelation]
    do {
      rows = try await correlations(.food, in: range, excluding: MealTrendData.excludingMeals(meals))
    } catch {
      try Task.checkCancellation()
      if local.isEmpty { throw error }
      return local.sorted { $0.date > $1.date }
    }
    let other = rows.map { item in
      let energy = item.objects.compactMap { $0 as? HKQuantitySample }
        .filter { $0.quantityType.identifier == HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue }
        .reduce(0.0) { $0 + $1.quantity.doubleValue(for: .kilocalorie()) }
      let hasEnergy = item.objects.contains {
        ($0 as? HKQuantitySample)?.quantityType.identifier ==
          HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue
      }
      return HealthFoodCorrelation(id: item.uuid, date: item.startDate,
        name: item.metadata?[HKMetadataKeyFoodType] as? String,
        energyKcal: hasEnergy ? energy : nil,
        sourceName: item.sourceRevision.source.name)
    }
    return (local + other).sorted { $0.date > $1.date }
  }
}

struct BloodPressurePairChart: View {
  let pairs: [BloodPressurePair]
  let range: ClosedRange<Date>
  @State private var selectedID: UUID?

  var body: some View {
    let visible = pairs.filter { range.contains($0.date) }
    let selected = visible.first { $0.id == selectedID }
    Chart {
      pressureLines(visible, value: \.systolic, title: "收缩压", color: .purple)
      pressureLines(visible, value: \.diastolic, title: "舒张压", color: .blue)
      ForEach(visible) { pair in
        RuleMark(x: .value("时间", pair.date),
          yStart: .value("舒张压", pair.diastolic),
          yEnd: .value("收缩压", pair.systolic))
          .foregroundStyle(Color.secondary.opacity(0.45))
        PointMark(x: .value("时间", pair.date), y: .value("收缩压", pair.systolic))
          .foregroundStyle(by: .value("血压", "收缩压"))
          .symbolSize(pair.id == selectedID ? 48 : 24)
        PointMark(x: .value("时间", pair.date), y: .value("舒张压", pair.diastolic))
          .foregroundStyle(by: .value("血压", "舒张压"))
          .symbolSize(pair.id == selectedID ? 48 : 24)
      }
      if let selected {
        RuleMark(x: .value("选中时间", selected.date))
          .foregroundStyle(HealthTheme.accent.opacity(0.45))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
      }
    }
    .chartXScale(domain: range)
    .chartYScale(domain: .automatic(includesZero: false))
    .chartXAxis { healthChartXAxis(range) }
    .chartForegroundStyleScale(["收缩压": Color.purple, "舒张压": Color.blue])
    .chartLegend(position: .bottom)
    .healthChartTap { proxy, tap in
      guard let date = proxy.value(atX: tap.x, as: Date.self),
        let index = HealthChartSelection.closestIndex(to: date, in: visible, date: \.date),
        let x = proxy.position(forX: visible[index].date), abs(tap.x - x) <= 28 else {
        selectedID = nil
        return
      }
      let id = visible[index].id
      selectedID = selectedID == id ? nil : id
    }
    .overlay(alignment: .topTrailing) {
      if let selected {
        HealthChartValueLabel(date: selected.date.formatted(HealthChartDate.minute),
          value: "\(HealthChartSelection.number(selected.systolic)) / \(HealthChartSelection.number(selected.diastolic)) mmHg",
          detail: "收缩压 / 舒张压")
        .padding(4)
      }
    }
  }

  @ChartContentBuilder
  private func pressureLines(_ visible: [BloodPressurePair], value: KeyPath<BloodPressurePair, Double>,
                             title: String, color: Color) -> some ChartContent {
    let points = visible.map {
      TrendPoint(epoch: $0.date.timeIntervalSince1970, value: $0[keyPath: value], sampleID: $0.id)
    }
    let lines = PlotDensity.segments(points)
    ForEach(lines) { item in
      LineMark(x: .value("时间", item.date), y: .value(title, item.value),
        series: .value("曲线", "\(title)-实测-\(item.segment)"))
        .foregroundStyle(color.opacity(0.75))
    }
    ForEach(PlotDensity.gapEndpoints(lines)) { item in
      LineMark(x: .value("时间", item.date), y: .value(title, item.value),
        series: .value("曲线", "\(title)-缺测-\(item.segment)"))
        .foregroundStyle(color.opacity(0.45))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }
    ForEach(TimeWindowTrend.make(points, visible: range)) { item in
      LineMark(x: .value("时间", item.date), y: .value(title, item.value),
        series: .value("曲线", "\(title)-拟合"))
        .foregroundStyle(color)
        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
    }
  }
}

// MARK: - HealthKit categories: event lists and real cross-midnight sleep columns

enum HealthDisplayKind {
  case numeric, sleep, alert, symptom, event, bloodPressure, food, workout

  static func classify(_ metric: HealthMetricDefinition) -> Self {
    switch metric.chart_template {
    case "sleep_stages": return .sleep
    case "event_alert": return .alert
    case "symptom_matrix": return .symptom
    case "event_calendar", "category_timeline", "reproductive_calendar": return .event
    case "bp_pair": return .bloodPressure
    case "food_records": return .food
    case "workout_sessions": return .workout
    default: return .numeric
    }
  }
}

struct HealthEventList: View {
  let metric: HealthMetricDefinition
  let events: [HealthTimelineEvent]
  var previewCount: Int? = nil

  private var rows: [HealthTimelineEvent] {
    let sorted = events.sorted { $0.start > $1.start }
    guard let previewCount else { return sorted }
    return Array(sorted.prefix(previewCount))
  }
  private var categoryName: String {
    switch HealthDisplayKind.classify(metric) {
    case .alert: return "健康通知与异常记录"
    case .symptom: return "症状记录"
    default: return "事件记录"
    }
  }

  var body: some View {
    if rows.isEmpty {
      Text("当前时间范围内未检测到可读取记录")
        .font(.footnote).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    } else {
      LazyVStack(alignment: .leading, spacing: 10) {
        ForEach(rows) { event in
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
              Label(metric.title, systemImage: metric.chart_template == "event_alert" ?
                "bell.badge" : metric.chart_template == "symptom_matrix" ? "cross.case" : "calendar")
                .font(.subheadline.weight(.medium))
              Spacer(minLength: 4)
              Text(event.start.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
              Text("原始分类值：\(event.categoryValue)")
              if event.end > event.start {
                let seconds = Int(event.end.timeIntervalSince(event.start))
                if seconds >= 60 { Text("持续 \(seconds / 60) 分钟") }
              }
            }
            .font(.caption).foregroundStyle(.secondary)
            Text("来源：\(event.source)")
              .font(.caption2).foregroundStyle(.secondary)
          }
          Divider()
        }
      }
      .accessibilityLabel(categoryName)
    }
  }
}

enum SleepStage: Int, Sendable {
  case inBed = 0, unspecified = 1, awake = 2, core = 3, deep = 4, rem = 5

  var label: String {
    switch self {
    case .inBed: return "卧床"
    case .unspecified: return "未分期"
    case .awake: return "清醒"
    case .core: return "核心"
    case .deep: return "深睡"
    case .rem: return "REM"
    }
  }
  var color: Color {
    switch self {
    case .inBed: return .gray.opacity(0.18)
    case .unspecified: return .gray.opacity(0.65)
    case .awake: return Color(red: 0.99, green: 0.36, blue: 0.38)
    case .core: return Color(red: 0.34, green: 0.73, blue: 0.91)
    case .deep: return Color(red: 0.34, green: 0.29, blue: 0.72)
    case .rem: return Color(red: 0.39, green: 0.83, blue: 0.73)
    }
  }
  var priority: Int {
    switch self {
    case .awake: return 5
    case .deep, .rem, .core: return 4
    case .unspecified: return 2
    case .inBed: return 0
    }
  }
}

struct SleepSlice: Sendable {
  let start: Date
  let end: Date
  let stage: SleepStage
}

struct SleepEpisode: Identifiable, Sendable {
  let id: String
  let sleepDay: Date
  let start: Date
  let end: Date
  let segments: [SleepSlice]
  let inBed: [SleepSlice]
  let source: String
  var isPrimary = false

  var asleepSeconds: TimeInterval {
    segments.filter { $0.stage != .awake }.reduce(0) {
      $0 + $1.end.timeIntervalSince($1.start)
    }
  }
  var stagedSeconds: TimeInterval {
    segments.filter { [.core, .deep, .rem].contains($0.stage) }.reduce(0) {
      $0 + $1.end.timeIntervalSince($1.start)
    }
  }
}

enum SleepEpisodeBuilder {
  /// Sleep days run noon(previous date) -> noon(label date). A nap after noon belongs
  /// to the next sleep-day column, which preserves the real continuous time coordinate.
  static func sleepDay(endingAt end: Date, calendar: Calendar = .current) -> Date {
    let date = calendar.startOfDay(for: end)
    let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: end)
      ?? date.addingTimeInterval(12 * 3600)
    return end < noon ? date : (calendar.date(byAdding: .day, value: 1, to: date) ?? date)
  }

  static func interval(for day: Date, calendar: Calendar = .current) -> DateInterval {
    let before = calendar.date(byAdding: .day, value: -1, to: day) ?? day.addingTimeInterval(-86400)
    let start = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: before)
      ?? before.addingTimeInterval(43200)
    let end = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)
      ?? day.addingTimeInterval(43200)
    return DateInterval(start: start, end: end)
  }

  /// Build distinct sessions per source, then prefer staged recordings for overlaps.
  /// Source conflicts are never summed together.
  static func make(events: [HealthTimelineEvent], calendar: Calendar = .current) -> [SleepEpisode] {
    let valid = events.filter {
      (0...5).contains($0.categoryValue) && $0.end > $0.start
    }
    let bySource = Dictionary(grouping: valid, by: \.source)
    var candidates: [SleepEpisode] = []
    for (source, original) in bySource {
      let rows = original.sorted { $0.start < $1.start }
      var group: [HealthTimelineEvent] = []
      var groupEnd: Date?
      func appendGroup() {
        guard !group.isEmpty else { return }
        // Start at the first actual asleep sample, NOT the earlier inBed start.
        let sleepSamples = group.filter { [1, 3, 4, 5].contains($0.categoryValue) }
        let first = sleepSamples.map(\.start).min() ?? group.map(\.start).min()!
        let latestAsleepEnd = sleepSamples.map(\.end).max() ?? group.map(\.end).max()!
        let wakeTail = group.filter {
          $0.categoryValue == SleepStage.awake.rawValue &&
          $0.start <= latestAsleepEnd.addingTimeInterval(45 * 60) &&
          $0.end >= latestAsleepEnd
        }.map(\.end).max()
        let last = max(latestAsleepEnd, wakeTail ?? latestAsleepEnd)
        let clipped = group.filter { $0.end > first && $0.start < last }
        let times = Array(Set([first, last] + clipped.flatMap { item in
          [max(first, item.start), min(last, item.end)]
        })).sorted()
        var slices: [SleepSlice] = []
        let bed = clipped.compactMap { item -> SleepSlice? in
          guard item.categoryValue == SleepStage.inBed.rawValue else { return nil }
          return SleepSlice(start: max(item.start, first), end: min(item.end, last), stage: .inBed)
        }
        if times.count > 1 {
          for index in 0..<(times.count - 1) {
            let time = times[index], next = times[index + 1]
            guard next > time else { continue }
            let matching = clipped.compactMap { item -> SleepStage? in
              guard item.start <= time && item.end >= next else { return nil }
              return SleepStage(rawValue: item.categoryValue)
            }
            guard let best = matching.max(by: { $0.priority < $1.priority }), best != .inBed else { continue }
            if let previous = slices.last, previous.end == time, previous.stage == best {
              slices[slices.count - 1] = SleepSlice(start: previous.start, end: next, stage: best)
            } else {
              slices.append(SleepSlice(start: time, end: next, stage: best))
            }
          }
        }
        candidates.append(SleepEpisode(id: "\(source)-\(first.timeIntervalSince1970)",
          sleepDay: sleepDay(endingAt: last, calendar: calendar), start: first,
          end: last, segments: slices, inBed: bed, source: source))
        group = []
      }
      for row in rows {
        if let lastEnd = groupEnd, row.start.timeIntervalSince(lastEnd) > 45 * 60 {
          appendGroup()
          groupEnd = nil
        }
        group.append(row)
        if let last = groupEnd { groupEnd = max(last, row.end) }
        else { groupEnd = row.end }
      }
      appendGroup()
    }
    // Discard mostly-overlapping duplicate sessions from secondary devices. A distinct
    // nap remains its own episode even if it occurs on the same day.
    let ranked = candidates.sorted {
      $0.stagedSeconds == $1.stagedSeconds ? $0.asleepSeconds > $1.asleepSeconds :
        $0.stagedSeconds > $1.stagedSeconds
    }
    var selected: [SleepEpisode] = []
    for episode in ranked {
      let duration = max(1, episode.end.timeIntervalSince(episode.start))
      let duplicated = selected.contains { previous in
        let overlap = max(0, min(episode.end, previous.end).timeIntervalSince(
          max(episode.start, previous.start)))
        return overlap / duration > 0.65
      }
      if !duplicated { selected.append(episode) }
    }
    var byDay = Dictionary(grouping: selected, by: \.sleepDay)
    for (day, rows) in byDay {
      guard let main = rows.max(by: { $0.asleepSeconds < $1.asleepSeconds })?.id else { continue }
      byDay[day] = rows.map { episode in
        var updated = episode
        updated.isPrimary = episode.id == main
        return updated
      }
    }
    return byDay.values.flatMap { $0 }.sorted { $0.start < $1.start }
  }
}

struct SleepDailyColumnsChart: View {
  let events: [HealthTimelineEvent]
  @ObservedObject var viewport: ChartViewport
  var compact = false
  var earliestRecord: Date? = nil
  private let calendar = Calendar.current
  private var range: ClosedRange<Date> { viewport.range }
  @State private var episodes: [SleepEpisode] = []
  @State private var selectedDay: Date?
  private var leftInset: CGFloat { compact ? 34 : 45 }
  private let rightInset: CGFloat = 6
  private var eventFingerprint: String {
    "\(events.count)|\(events.first?.id.uuidString ?? "")|\(events.last?.id.uuidString ?? "")"
  }
  private var days: [Date] {
    var result: [Date] = []
    var date = calendar.startOfDay(for: range.lowerBound)
    let end = calendar.startOfDay(for: range.upperBound)
    while date <= end {
      result.append(date)
      guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
      date = next
    }
    return result
  }
  private func clockLabel(_ minute: Int) -> String {
    let m = (minute + 720) % 1440
    return String(format: "%02d:%02d", m / 60, m % 60)
  }

  var body: some View {
    let days = self.days
    let dayIndices = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element, $0.offset) })
    let records = episodes.filter { dayIndices[$0.sleepDay] != nil }
    Group {
    if records.isEmpty {
      if !events.isEmpty && episodes.isEmpty {
        ProgressView("整理睡眠记录…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Text("当前范围内暂无可读取睡眠阶段")
          .font(.footnote).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      VStack(alignment: .leading, spacing: 4) {
        Canvas { context, size in
          let left = leftInset
          let right = rightInset
          let top: CGFloat = 8
          let bottom: CGFloat = compact ? 16 : 24
          let width = max(1, size.width - left - right)
          let height = max(1, size.height - top - bottom)
          let count = max(1, days.count)
          let slot = width / CGFloat(count)
          let shown = Dictionary(grouping: records, by: \.sleepDay)

          if let selectedDay, let index = dayIndices[selectedDay], shown[selectedDay] != nil {
            let rect = CGRect(x: left + CGFloat(index) * slot, y: top, width: slot, height: height)
            context.fill(Path(rect), with: .color(HealthTheme.accent.opacity(0.12)))
          }

          for (tick, minute) in [0, 360, 720, 1080, 1440].enumerated() {
            let y = top + CGFloat(minute) / 1440 * height
            var line = Path()
            line.move(to: CGPoint(x: left, y: y))
            line.addLine(to: CGPoint(x: left + width, y: y))
            context.stroke(line, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
            context.draw(Text(clockLabel(minute)).font(.system(size: compact ? 9 : 10))
              .foregroundColor(.secondary), at: CGPoint(x: left / 2, y: y))
            if tick == 4 { continue }
          }

          let labelCount = max(1, min(compact ? 5 : 8, Int(width / 56)))
          let step = max(1, Int(ceil(Double(count) / Double(labelCount))))
          let span = range.upperBound.timeIntervalSince(range.lowerBound)
          let labelY = top + height + bottom / 2
          var yearPositions = [left]
          context.draw(Text(range.lowerBound.formatted(HealthChartDate.year))
            .font(.system(size: compact ? 9 : 10)).foregroundColor(.secondary),
            at: CGPoint(x: left, y: labelY), anchor: .leading)
          for year in HealthChartDate.yearMarkers(range).dropFirst() {
            guard let index = dayIndices[calendar.startOfDay(for: year)] else { continue }
            let x = left + (CGFloat(index) + 0.5) * slot
            guard x >= (yearPositions.last ?? left) + 48 else { continue }
            yearPositions.append(x)
            context.draw(Text(year.formatted(HealthChartDate.year))
              .font(.system(size: compact ? 9 : 10)).foregroundColor(.secondary),
              at: CGPoint(x: min(size.width - 24, x), y: labelY))
          }
          for (index, day) in days.enumerated() where index % step == 0 {
            let x = left + (CGFloat(index) + 0.5) * slot
            guard x >= left + 55, yearPositions.dropFirst().allSatisfy({ abs($0 - x) >= 44 })
            else { continue }
            context.draw(Text(HealthChartDate.tickLabel(day, span: max(2 * 86400, span)))
              .font(.system(size: compact ? 9 : 10)).foregroundColor(.secondary),
              at: CGPoint(x: min(size.width - 24, x), y: labelY))
          }

          for (index, day) in days.enumerated() {
            guard let entries = shown[day] else { continue }
            let rows = entries.sorted {
              if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
              return $0.start < $1.start
            }
            let usable = slot * 0.8
            let weights: [CGFloat] = rows.map { $0.isPrimary ? 1.5 : 1 }
            let widthPerWeight = min(compact ? 6 : 8, usable * 0.85 / weights.reduce(0, +))
            let gap = rows.count > 1 ? min(2, usable * 0.15 / CGFloat(rows.count - 1)) : 0
            let widths = weights.map { $0 * widthPerWeight }
            let totalWidth = widths.reduce(0, +) + CGFloat(rows.count - 1) * gap
            let anchorX = left + (CGFloat(index) + 0.5) * slot
            var x = anchorX - totalWidth / 2
            let dayInterval = SleepEpisodeBuilder.interval(for: day, calendar: calendar)
            for (rowIndex, episode) in rows.enumerated() {
              let barWidth = widths[rowIndex]
              for slice in episode.inBed + episode.segments {
                let low = max(dayInterval.start, slice.start)
                let high = min(dayInterval.end, slice.end)
                guard high > low, dayInterval.duration > 0 else { continue }
                let y0 = top + CGFloat(low.timeIntervalSince(dayInterval.start) / dayInterval.duration) * height
                let y1 = top + CGFloat(high.timeIntervalSince(dayInterval.start) / dayInterval.duration) * height
                let rect = CGRect(x: x, y: y0, width: barWidth, height: max(1, y1-y0))
                context.fill(Path(rect), with: .color(slice.stage.color))
              }
              x += barWidth + gap
            }
          }

          let main = records.filter(\.isPrimary)
          let timeTrends: [(Bool, Color)] = [(true, .purple), (false, .blue)]
          for (start, color) in timeTrends {
            let clock = main.compactMap { episode -> TrendPoint? in
              let interval = SleepEpisodeBuilder.interval(for: episode.sleepDay, calendar: calendar)
              let moment = start ? episode.start : episode.end
              let fraction = moment.timeIntervalSince(interval.start) / interval.duration
              guard (0...1).contains(fraction) else { return nil }
              return TrendPoint(epoch: episode.sleepDay.timeIntervalSince1970, value: fraction)
            }.sorted { $0.epoch < $1.epoch }
            func position(_ point: TrendPoint) -> CGPoint? {
              guard let index = dayIndices[point.date] else { return nil }
              let x = left + (CGFloat(index) + 0.5) * slot
              return CGPoint(x: x, y: top + CGFloat(point.value) * height)
            }
            func path(_ points: [PlotPoint]) -> Path {
              var trail = Path()
              var segment: Int?
              for item in points {
                guard let point = position(item.point) else { continue }
                if segment == item.segment { trail.addLine(to: point) }
                else { trail.move(to: point) }
                segment = item.segment
              }
              return trail
            }
            // Calendar slots are consecutive when their indices differ by one, even across DST.
            let lines = clock.reduce(into: [PlotPoint]()) { result, point in
              let previous = result.last
              let gap = previous.flatMap { dayIndices[$0.date] }.map { (dayIndices[point.date] ?? $0) - $0 } ?? 0
              result.append(PlotPoint(point: point, segment: (previous?.segment ?? 0) + (gap > 1 ? 1 : 0)))
            }
            context.stroke(path(lines), with: .color(color.opacity(0.55)), lineWidth: 1)
            context.stroke(path(PlotDensity.gapEndpoints(lines)), with: .color(color.opacity(0.45)),
              style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            if let first = days.first, let last = days.last {
              let fit = TimeWindowTrend.make(clock, visible: first...last)
              context.stroke(path(fit.map { PlotPoint(point: $0, segment: 0) }), with: .color(color.opacity(0.85)),
                style: StrokeStyle(lineWidth: compact ? 1.4 : 2, dash: [4, 3]))
            }
          }
        }
        .overlay {
          GeometryReader { geometry in
            Rectangle().fill(.clear).contentShape(Rectangle())
              .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                let width = max(1, geometry.size.width - leftInset - rightInset)
                let offset = tap.location.x - leftInset
                let bottom: CGFloat = compact ? 16 : 24
                guard !days.isEmpty, offset >= 0, offset < width,
                  tap.location.y >= 8, tap.location.y < geometry.size.height - bottom else { return }
                let index = Int(offset / width * CGFloat(days.count))
                guard days.indices.contains(index) else { return }
                let day = days[index]
                selectedDay = selectedDay == day || !records.contains(where: { $0.sleepDay == day }) ? nil : day
              })
          }
        }
        .overlay(alignment: .topTrailing) {
          if let selectedDay {
            let selected = records.filter { $0.sleepDay == selectedDay }
            if !selected.isEmpty {
              let minutes = Int((selected.map(\.asleepSeconds).reduce(0, +) / 60).rounded())
              let primary = selected.first(where: \.isPrimary)
              HealthChartValueLabel(date: selectedDay.formatted(HealthChartDate.day),
                value: "睡眠 \(minutes / 60) 小时 \(minutes % 60) 分钟",
                detail: primary.map { "\($0.start.formatted(date: .omitted, time: .shortened))–\($0.end.formatted(date: .omitted, time: .shortened))" })
              .padding(4)
            }
          }
        }
        if !compact {
          HStack(spacing: 10) {
            ForEach([SleepStage.awake, .rem, .core, .deep, .unspecified], id: \.rawValue) { stage in
              HStack(spacing: 3) {
                Circle().fill(stage.color).frame(width: 7, height: 7)
                Text(stage.label).font(.caption2)
              }
            }
          }
          HStack(spacing: 16) {
            Label("入睡时间：7日滚动中位数", systemImage: "line.diagonal")
              .foregroundStyle(.purple)
            Label("醒来时间：7日滚动中位数", systemImage: "line.diagonal")
              .foregroundStyle(.blue)
          }.font(.caption2)
        }
      }
      .accessibilityLabel("跨日睡眠柱图，纵轴从前一日中午到当日中午；各色为睡眠阶段，含零碎睡眠")

    }
    }
    .modifier(TimelineGesture(viewport: viewport, earliestRecord: earliestRecord,
      recordBucket: .day, dates: { episodes.map(\.sleepDay) }))
    .onChange(of: viewport.revision) { _, _ in selectedDay = nil }
    .task(id: eventFingerprint) {
      let copied = events
      let computed = await Task.detached(priority: .utility) {
        SleepEpisodeBuilder.make(events: copied)
      }.value
      if !Task.isCancelled { episodes = computed }
    }
  }
}

struct HealthAlertRecord: Identifiable {
  let metric: HealthMetricDefinition
  let event: HealthTimelineEvent
  var id: String { "\(metric.identifier)-\(event.id.uuidString)" }
}

struct HealthAlertsScreen: View {
  @State private var records: [HealthAlertRecord] = []
  @State private var loading = false
  @State private var error: String?
  @State private var selectedIdentifier = "all"

  private var categories: [HealthMetricDefinition] {
    HealthMetricCatalog.all.filter { $0.chart_template == "event_alert" }
  }
  private var filtered: [HealthAlertRecord] {
    records.filter { selectedIdentifier == "all" || $0.metric.identifier == selectedIdentifier }
  }

  var body: some View {
    VStack(spacing: 8) {
      Menu {
        Button("所有类型") { selectedIdentifier = "all" }
        ForEach(categories) { metric in
          Button(metric.title) { selectedIdentifier = metric.identifier }
        }
      } label: {
        Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
      .padding(.horizontal)
      if loading && records.isEmpty {
        ProgressView("读取异常记录中…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error, records.isEmpty {
        ContentUnavailableView("无法读取异常记录", systemImage: "exclamationmark.triangle",
          description: Text(error))
      } else if filtered.isEmpty {
        ContentUnavailableView("未检测到可读取异常记录", systemImage: "bell.slash")
      } else {
        List(filtered) { record in
          VStack(alignment: .leading, spacing: 5) {
            Label(record.metric.title, systemImage: "bell.badge")
              .font(.headline)
            Text(record.event.start.formatted(date: .abbreviated, time: .shortened))
              .font(.subheadline.monospacedDigit())
          }.padding(.vertical, 4)
        }
        .listStyle(.plain)
      }
    }
    .navigationTitle("通知与异常")
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
  }

  @MainActor private func load() async {
    loading = true
    defer { loading = false }
    let now = Date()
    // Recent alerts, by exact HealthKit event time. An empty result isn't a diagnosis.
    let range = now.addingTimeInterval(-365 * 86400)...now
    var collected: [HealthAlertRecord] = []
    for metric in categories {
      do {
        let events = try await HealthTrendRepository.shared.events(for: metric, range: range, limit: nil)
        collected += events.map { HealthAlertRecord(metric: metric, event: $0) }
      } catch {
        self.error = error.localizedDescription
      }
    }
    records = collected.sorted { $0.event.start > $1.event.start }
  }
}
