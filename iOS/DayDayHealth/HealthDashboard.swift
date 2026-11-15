import SwiftUI
import Charts

enum HealthChartDate {
  static let chinese = Locale(identifier: "zh_CN")
  static let day = Date.FormatStyle.dateTime.year().month().day().locale(chinese)
  static let minute = day.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
  static let year = Date.FormatStyle.dateTime.year().locale(chinese)
  private static let month = Date.FormatStyle.dateTime.month().locale(chinese)
  private static let clock = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted))
    .minute(.twoDigits).locale(chinese)

  static func tickLabel(_ date: Date, span: TimeInterval) -> String {
    if span < 2 * 86400 { return date.formatted(month.day()) + "\n" + date.formatted(clock) }
    return date.formatted(span >= 365 * 86400 ? month : month.day())
  }

  static func yearMarkers(_ range: ClosedRange<Date>, calendar: Calendar = .current) -> [Date] {
    var dates = [range.lowerBound]
    var cursor = range.lowerBound
    while let next = calendar.dateInterval(of: .year, for: cursor)?.end,
          next > cursor, next < range.upperBound {
      dates.append(next)
      cursor = next
    }
    return dates
  }
}

@AxisContentBuilder
func healthChartXAxis(_ range: ClosedRange<Date>) -> some AxisContent {
  let span = range.upperBound.timeIntervalSince(range.lowerBound)
  let years = HealthChartDate.yearMarkers(range)
  AxisMarks(values: [range.lowerBound]) { _ in
    AxisValueLabel(anchor: .topLeading, collisionResolution: .disabled) {
      Text(range.lowerBound.formatted(HealthChartDate.year))
    }
  }
  AxisMarks(values: Array(years.dropFirst())) { value in
    AxisGridLine()
    if let date = value.as(Date.self), date.timeIntervalSince(range.lowerBound) >= span / 7 {
      AxisValueLabel { Text(date.formatted(HealthChartDate.year)) }
    }
  }
  AxisMarks(values: .automatic(desiredCount: span < 2 * 86400 ? 3 : 4)) { value in
    if let date = value.as(Date.self), !years.contains(date) {
      AxisGridLine()
      if years.allSatisfy({ abs(date.timeIntervalSince($0)) >= span / 7 }) {
        AxisValueLabel {
          Text(HealthChartDate.tickLabel(date, span: span)).multilineTextAlignment(.center)
        }
      }
    }
  }
}

private enum TimePreset: String, CaseIterable {
  case lastWeek = "近7天", lastMonth = "近30天", lastYear = "近1年"

  func window(endingAt end: Date, calendar: Calendar = .current) -> DateInterval? {
    let offset: DateComponents = switch self {
    case .lastWeek: DateComponents(day: -7)
    case .lastMonth: DateComponents(day: -30)
    case .lastYear: DateComponents(year: -1)
    }
    guard let start = calendar.date(byAdding: offset, to: end) else { return nil }
    return DateInterval(start: start, end: end)
  }
}

enum ChartPanBounds {
  static func reachableStarts(from start: Date, duration: TimeInterval, dates: [Date],
                              bucket: HealthBucket?, calendar: Calendar = .current)
    -> ClosedRange<Date>? {
    guard duration > 0 else { return nil }
    var component: ClosedRange<Date>?
    for date in dates.sorted() {
      // A sample stays in view while the window overlaps its timestamp or its daily column.
      let end = bucket.flatMap { calendar.dateInterval(of: $0.component, for: date)?.end } ?? date
      let candidate = date.addingTimeInterval(-duration)...end
      if let previous = component {
        if candidate.lowerBound <= previous.upperBound {
          component = previous.lowerBound...max(previous.upperBound, candidate.upperBound)
        } else if previous.contains(start) {
          return previous
        } else if candidate.lowerBound > start {
          return nil
        } else {
          component = candidate
        }
      } else {
        component = candidate
      }
    }
    return component.flatMap { $0.contains(start) ? $0 : nil }
  }
}

/// Presets and gestures change the viewport, independently of the metric's data resolution.
@MainActor final class ChartViewport: ObservableObject {
  @Published private(set) var start = Date().addingTimeInterval(-30 * 86400)
  @Published private(set) var duration: TimeInterval = 30 * 86400
  @Published private(set) var revision = 0
  @Published private(set) var label = "近30天"
  @Published private(set) var earliest: Date?
  @Published private(set) var latest: Date?

  var range: ClosedRange<Date> { start...start.addingTimeInterval(duration) }
  var visibleLabel: String {
    let format = duration < 2 * 86400 ? HealthChartDate.minute : HealthChartDate.day
    return "\(start.formatted(format)) 至 \(range.upperBound.formatted(format))"
  }
  private var hasChosenWindow = false

  private func apply(_ proposed: Date, _ requested: TimeInterval) {
    let now = Date()
    let first = min(now, earliest ?? now.addingTimeInterval(-30 * 86400))
    let span = max(60, now.timeIntervalSince(first))
    let newDuration = min(max(3600, requested), span)
    duration = newDuration
    start = max(first, min(now.addingTimeInterval(-newDuration), proposed))
  }
  func setBounds(_ value: HealthMetricBounds, focus: Bool = false) {
    earliest = min(earliest ?? value.earliest, value.earliest)
    latest = max(latest ?? value.latest, value.latest)
    if focus && !hasChosenWindow {
      let end = min(Date(), value.latest.addingTimeInterval(86400))
      let width = min(30 * 86400, max(3600, end.timeIntervalSince(value.earliest)))
      apply(end.addingTimeInterval(-width), width)
    } else { clampCurrentWindow() }
    commit()
  }
  func pinch(_ scale: CGFloat, from startDate: Date, duration old: TimeInterval) {
    let length = old / max(0.1, Double(scale))
    let center = startDate.addingTimeInterval(old / 2)
    label = "自定义"
    hasChosenWindow = true
    apply(center.addingTimeInterval(-length / 2), length)
  }
  func pan(_ seconds: TimeInterval, from baseline: Date,
           earliestRecord: Date?, recordBucket: HealthBucket?,
           reachable: ClosedRange<Date>) {
    let lastStart = Date().addingTimeInterval(-duration)
    let firstRecord = earliestRecord ?? earliest ?? reachable.lowerBound
    let firstPoint = recordBucket.flatMap {
      Calendar.current.dateInterval(of: $0.component, for: firstRecord)?.start
    } ?? firstRecord
    // Leave a small inset so the last visible bar or dot isn't clipped at the edge.
    let inset = min(duration * 0.015, 6 * 3600)
    let lower = min(baseline, max(min(firstPoint, lastStart), reachable.lowerBound.addingTimeInterval(inset)))
    let upper = max(baseline, min(lastStart, reachable.upperBound.addingTimeInterval(-inset)))
    let proposed = baseline.addingTimeInterval(seconds)
    let next = min(upper, max(lower, proposed))
    guard next != start else { return }
    label = "自定义"
    hasChosenWindow = true
    start = next
  }
  fileprivate func preset(_ value: TimePreset) {
    guard let window = value.window(endingAt: Date()) else { return }
    let first = max(window.start, earliest ?? window.start)
    guard first < window.end else { return }
    start = first
    duration = window.end.timeIntervalSince(first)
    hasChosenWindow = true
    label = value.rawValue
    commit()
  }
  func reset() {
    let end = min(Date(), (latest ?? Date()).addingTimeInterval(86400))
    apply(end.addingTimeInterval(-30 * 86400), 30 * 86400)
    hasChosenWindow = true
    label = "近30天"
    commit()
  }
  func replaceBounds(_ values: [HealthMetricBounds]) {
    earliest = values.map(\.earliest).min()
    latest = values.map(\.latest).max()
    clampCurrentWindow()
    commit()
  }
  private func clampCurrentWindow() {
    guard let earliest, earliest > start else { return }
    let end = range.upperBound
    if earliest < end {
      start = earliest
      duration = end.timeIntervalSince(earliest)
    } else {
      apply(start, duration)
    }
  }
  func commit() { revision &+= 1 }
  func queryRange(sleep: Bool = false) -> ClosedRange<Date> {
    let margin = sleep ? 8 * 86400 : min(duration * 0.35, 30 * 86400)
    let beginning = max((earliest ?? start).addingTimeInterval(sleep ? -86400 : 0),
                        start.addingTimeInterval(-margin))
    let end = max(beginning, min(Date(), range.upperBound.addingTimeInterval(margin)))
    return beginning...end
  }
}

private struct HealthTimeRangeMenu: View {
  @ObservedObject var viewport: ChartViewport

  var body: some View {
    Menu {
      ForEach(TimePreset.allCases, id: \.self) { preset in
        Button(preset.rawValue) { viewport.preset(preset) }
      }
    } label: {
      Label(viewport.label, systemImage: "calendar")
    }
    .controlSize(.small)
  }
}

private func metricSymbol(_ metric: HealthMetricDefinition) -> String {
  switch HealthDisplayKind.classify(metric) {
  case .sleep: return "moon.stars"
  case .alert: return "bell.badge"
  case .symptom: return "cross.case"
  case .event: return "calendar.badge.clock"
  case .bloodPressure: return "heart.text.square"
  case .food: return "fork.knife"
  case .workout: return "dumbbell"
  case .numeric:
    switch metric.group {
    case "心脏": return "heart"
    case "运动", "行动能力": return "figure.walk"
    case "营养": return "fork.knife"
    case "呼吸": return "lungs"
    case "身体测量": return "scalemass"
    default: return "chart.xyaxis.line"
    }
  }
}

struct HealthTrendsScreen: View {
  @ObservedObject var store: HealthStore
  @StateObject private var viewport = ChartViewport()
  @State private var selected: HealthMetricDefinition?
  @State private var showAlerts = false
  @State private var directory = false
  @State private var search = ""
  @State private var expanded = Set<String>()
  @State private var collapsed = Set<String>()
  @State private var favorites = Set(HealthMetricCatalog.mainIdentifiers)
  @State private var available: [String: Bool] = [:]
  @State private var directoryAvailability: [String: Bool] = [:]
  @State private var directoryAvailabilityRevision = 0
  @State private var boundsByMetric: [String: HealthMetricBounds] = [:]
  @State private var scanning = false
  @AppStorage("wbSensitiveChartsEnabled") private var showSensitive = false
  @AppStorage(MealEntry.storageKey) private var mealStorage = Data()
  @AppStorage("wbMealTrendFavoritesAdded") private var mealFavoritesAdded = false

  private let order = ["生命体征", "心脏", "呼吸", "睡眠", "身体测量", "运动", "训练",
    "行动能力", "营养", "心理健康", "症状", "听力", "生殖健康", "其他健康记录"]
  private func rank(_ title: String) -> Int { order.firstIndex(of: title) ?? order.count }
  private var catalog: [HealthMetricDefinition] {
    HealthMetricCatalog.all.filter { showSensitive || !$0.isSensitive }
  }
  private var starred: [HealthMetricDefinition] {
    catalog.filter {
      favorites.contains($0.identifier) && (!$0.isSpecial || $0.identifier == MealTrendData.foodID)
    }
  }
  private var list: [HealthMetricDefinition] {
    if !directory { return starred.filter { available[$0.identifier] == true } }
    return catalog.filter {
      search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) ||
      $0.identifier.localizedCaseInsensitiveContains(search) ||
      $0.group.localizedCaseInsensitiveContains(search)
    }
  }
  private var sections: [(String, [HealthMetricDefinition])] {
    Dictionary(grouping: list, by: \.group).sorted {
      rank($0.key) == rank($1.key) ? $0.key < $1.key : rank($0.key) < rank($1.key)
    }.map { ($0.key, $0.value.sorted { $0.title < $1.title }) }
  }

  var body: some View {
    ScrollViewReader { proxy in
      VStack(spacing: 0) {
        VStack(spacing: 8) {
          HStack(spacing: 8) {
            Text(viewport.visibleLabel).font(.caption.monospacedDigit())
              .lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 2)
            HealthTimeRangeMenu(viewport: viewport)
          }
          HStack(spacing: 8) {
            Picker("指标", selection: $directory) {
              Text("有数据").tag(false)
              Text("全部194项").tag(true)
            }.pickerStyle(.segmented)
          }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)

        ZStack(alignment: .trailing) {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
              if directory {
                TextField("搜索健康指标", text: $search)
                  .textFieldStyle(.roundedBorder)
                  .onChange(of: search) { _, value in
                    if !value.isEmpty { expanded = Set(sections.map(\.0)) }
                  }
                Toggle("显示敏感健康类别", isOn: $showSensitive)
                  .font(.footnote)
              }
              if scanning && available.isEmpty && !directory {
                ProgressView("检查有记录的指标…").padding(.vertical, 24)
              }
              if sections.isEmpty && !scanning && !directory {
                ContentUnavailableView("暂无可读取的关注指标", systemImage: "chart.bar.xaxis")
              }
              ForEach(sections, id: \.0) { section in
                VStack(alignment: .leading, spacing: 8) {
                  Button {
                    if directory {
                      if expanded.remove(section.0) == nil { expanded.insert(section.0) }
                    } else {
                      if collapsed.remove(section.0) == nil { collapsed.insert(section.0) }
                    }
                  } label: {
                    HStack {
                      Text(section.0).font(.headline)
                      Text("\(section.1.count) 项").font(.caption).foregroundStyle(.secondary)
                      Spacer()
                      let expandedNow = directory ? expanded.contains(section.0) : !collapsed.contains(section.0)
                      Image(systemName: expandedNow ? "chevron.down" : "chevron.right")
                    }
                    .contentShape(Rectangle()).frame(minHeight: 42)
                  }.buttonStyle(.plain)
                  if directory ? expanded.contains(section.0) : !collapsed.contains(section.0) {
                    if directory {
                      directoryRows(section.1)
                    } else {
                      ForEach(section.1) { metric in
                        HealthMetricCard(metric: metric, viewport: viewport,
                          earliestRecord: boundsByMetric[metric.identifier]?.earliest,
                          mealStorage: MealTrendData.identifiers.contains(metric.identifier) ? mealStorage : nil) {
                          selected = metric
                        }
                        Divider()
                      }
                    }
                  }
                }
                .id(section.0)
              }
            }
            .padding(.leading, 15).padding(.trailing, 47).padding(.bottom, 22)
          }
          .refreshable {
            refreshDirectoryAvailability()
            await loadAvailable(force: true)
            viewport.commit()
          }
          VStack(spacing: 3) {
            Button { showAlerts = true } label: {
              Image(systemName: "bell.badge").frame(width: 34, height: 32)
            }.accessibilityLabel("通知与异常")
            Divider()
            ForEach(sections, id: \.0) { section in
              Button {
                if directory { expanded.insert(section.0) }
                withAnimation(.easeOut(duration: 0.2)) {
                  proxy.scrollTo(section.0, anchor: .top)
                }
              } label: {
                Text(String(section.0.prefix(2)))
                  .font(.system(size: 10, weight: .medium))
                  .frame(width: 34, height: 28)
              }.accessibilityLabel("跳转到\(section.0)")
            }
          }
          .buttonStyle(.plain)
          .foregroundStyle(HealthTheme.accent)
          .frame(width: 34)
          .padding(.vertical, 7)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
          .padding(.trailing, 3)
        }
      }
    }
    .background(HealthTheme.background)
    .navigationTitle("健康趋势")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $selected) { metric in
      NavigationStack { HealthMetricDetail(metric: metric, favorites: $favorites) }
    }
    .sheet(isPresented: $showAlerts) {
      NavigationStack { HealthAlertsScreen() }
    }
    .onChange(of: store.lastHealthSync) { _, _ in
      refreshDirectoryAvailability()
      Task { await loadAvailable(force: true); viewport.commit() }
    }
    .onChange(of: mealStorage) { _, _ in
      refreshDirectoryAvailability()
      Task { await loadAvailable(force: true) }
    }
    .onChange(of: favorites) { _, value in
      UserDefaults.standard.set(Array(value), forKey: "wbFavoriteHealthMetrics")
      Task { await loadAvailable() }
    }
    .task {
      if let saved = UserDefaults.standard.stringArray(forKey: "wbFavoriteHealthMetrics") {
        favorites = Set(saved)
      }
      if !mealFavoritesAdded {
        favorites.formUnion(MealTrendData.identifiers)
        UserDefaults.standard.set(Array(favorites), forKey: "wbFavoriteHealthMetrics")
        mealFavoritesAdded = true
      }
      await loadAvailable()
    }
  }

  private struct DirectoryCheck: Equatable {
    let identifiers: [String]
    let revision: Int
  }

  private func directoryRows(_ metrics: [HealthMetricDefinition]) -> some View {
    let withData = metrics.filter { directoryAvailability[$0.identifier] == true }
    let unchecked = metrics.filter { directoryAvailability[$0.identifier] == nil }
    let withoutData = metrics.filter { directoryAvailability[$0.identifier] == false }
    return VStack(spacing: 8) {
      ForEach(withData + unchecked + withoutData) { metric in
        Button { selected = metric } label: {
          HStack(spacing: 8) {
            Image(systemName: metricSymbol(metric)).frame(width: 20)
            Text(metric.title).foregroundStyle(.primary)
            Spacer()
            if favorites.contains(metric.identifier) {
              Image(systemName: "star.fill").foregroundStyle(.orange)
            }
            if directoryAvailability[metric.identifier] == false {
              Text("暂无数据").font(.caption2).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption)
          }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Divider()
      }
    }
    .task(id: DirectoryCheck(identifiers: metrics.map(\.identifier),
                             revision: directoryAvailabilityRevision)) {
      let meals = MealEntry.decode(mealStorage)
      for metric in metrics {
        guard !Task.isCancelled else { return }
        guard directoryAvailability[metric.identifier] == nil else { continue }
        do {
          let hasRecords: Bool
          if MealTrendData.identifiers.contains(metric.identifier) {
            hasRecords = try await HealthTrendRepository.shared.mealTrendBounds(for: metric, meals: meals) != nil
          } else {
            hasRecords = try await HealthTrendRepository.shared.hasRecords(for: metric)
          }
          guard !Task.isCancelled else { return }
          directoryAvailability[metric.identifier] = hasRecords
        } catch { continue }
      }
    }
  }

  private func refreshDirectoryAvailability() {
    directoryAvailability.removeAll()
    directoryAvailabilityRevision &+= 1
  }

  @MainActor private func loadAvailable(force: Bool = false) async {
    guard !scanning else { return }
    scanning = true
    defer { scanning = false }
    let meals = MealEntry.decode(mealStorage)
    for metric in starred {
      do {
        let bounds: HealthMetricBounds?
        if MealTrendData.identifiers.contains(metric.identifier) {
          bounds = try await HealthTrendRepository.shared.mealTrendBounds(for: metric, meals: meals, refresh: force)
        } else {
          bounds = try await HealthTrendRepository.shared.bounds(for: metric, refresh: force)
        }
        if let bounds {
          available[metric.identifier] = true
          boundsByMetric[metric.identifier] = bounds
        } else {
          available[metric.identifier] = false
          boundsByMetric.removeValue(forKey: metric.identifier)
        }
      } catch { /* Keep previous state: failure is not evidence of no data. */ }
    }
    viewport.replaceBounds(starred.compactMap { boundsByMetric[$0.identifier] })
  }
}

// MARK: - Scroll-friendly pinch and horizontal pan

struct TimelineGesture: ViewModifier {
  @ObservedObject var viewport: ChartViewport
  var earliestRecord: Date? = nil
  var recordBucket: HealthBucket? = nil
  let dates: () -> [Date]
  @State private var pinchStart: Date?
  @State private var pinchDuration: TimeInterval?
  @State private var panStart: Date?
  @State private var panDuration: TimeInterval?
  @State private var panBounds: ClosedRange<Date>?

  func body(content: Content) -> some View {
    content
      .simultaneousGesture(MagnifyGesture()
        .onChanged { value in
          if pinchStart == nil {
            pinchStart = viewport.start
            pinchDuration = viewport.duration
          }
          guard let pinchStart, let pinchDuration else { return }
          viewport.pinch(value.magnification, from: pinchStart, duration: pinchDuration)
        }
        .onEnded { _ in
          pinchStart = nil
          pinchDuration = nil
          viewport.commit()
        })
      .simultaneousGesture(DragGesture(minimumDistance: 22)
        .onChanged { value in
          guard pinchStart == nil, abs(value.translation.width) > abs(value.translation.height) * 1.6 else { return }
          if panStart == nil {
            panStart = viewport.start
            panDuration = viewport.duration
            panBounds = ChartPanBounds.reachableStarts(from: viewport.start, duration: viewport.duration,
              dates: dates(), bucket: recordBucket)
          }
          guard let panStart, let panDuration, let panBounds else { return }
          viewport.pan(-Double(value.translation.width / 320) * panDuration, from: panStart,
            earliestRecord: earliestRecord, recordBucket: recordBucket, reachable: panBounds)
        }
        .onEnded { _ in
          if let panStart, viewport.start != panStart { viewport.commit() }
          panStart = nil
          panDuration = nil
          panBounds = nil
        })
  }
}

private func metricBars(_ metric: HealthMetricDefinition) -> Bool {
  ["bar_sum", "spark_sum", "bars_nutrition", "stacked_macro", "stand_hour", "mindfulness"]
    .contains(metric.chart_template)
}
private func metricRange(_ metric: HealthMetricDefinition) -> Bool {
  ["range_line", "hearing_line"].contains(metric.chart_template)
}
private func metricRecordBucket(_ metric: HealthMetricDefinition) -> HealthBucket? {
  metricBars(metric) || metricRange(metric) ? .day : nil
}
private struct NutritionChartRequest: Equatable {
  let revision: Int
  let mealStorage: Data?
}

private struct NutritionMealRow: View {
  let item: HealthFoodCorrelation

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(item.name ?? "未标注食物名称")
      Text(item.date.formatted(HealthChartDate.minute))
        .font(.caption).foregroundStyle(.secondary)
      if let energy = item.energyKcal {
        Text(MealEnergyMath.kcal(energy)).font(.subheadline)
      }
    }
  }
}

private struct HealthMetricCard: View {
  let metric: HealthMetricDefinition
  @ObservedObject var viewport: ChartViewport
  let earliestRecord: Date?
  let mealStorage: Data?
  let open: () -> Void
  @State private var points: [TrendPoint] = []
  @State private var events: [HealthTimelineEvent] = []
  @State private var foods: [HealthFoodCorrelation] = []
  @State private var pressure: [BloodPressurePair] = []
  @State private var loading = false
  @State private var error: String?
  private var kind: HealthDisplayKind { .classify(metric) }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: open) {
        HStack {
          Image(systemName: metricSymbol(metric)).foregroundStyle(HealthTheme.accent)
          Text(metric.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
          Spacer()
          if kind == .numeric { Text(metric.display_unit).font(.caption).foregroundStyle(.secondary) }
          Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
      if points.isEmpty && events.isEmpty && foods.isEmpty && pressure.isEmpty {
        Text(loading ? "读取中…" : (error ?? "当前范围内无记录"))
          .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 6)
      } else {
        switch kind {
        case .sleep:
          SleepDailyColumnsChart(events: events, viewport: viewport, compact: true,
            earliestRecord: earliestRecord)
            .frame(height: 155)
        case .alert, .symptom, .event:
          HealthEventList(metric: metric, events: events.filter {
            $0.start <= viewport.range.upperBound && $0.end >= viewport.range.lowerBound
          }, previewCount: 3)
        case .food:
          ForEach(foods.lazy.filter { viewport.range.contains($0.date) }.prefix(3)) {
            NutritionMealRow(item: $0)
          }
        case .bloodPressure:
          BloodPressurePairChart(pairs: pressure, range: viewport.range)
            .frame(height: 155)
            .modifier(TimelineGesture(viewport: viewport, earliestRecord: earliestRecord,
              dates: { pressure.map(\.date) }))
        case .numeric:
          MetricChart(metric: metric, points: points, range: viewport.range,
            revision: viewport.revision)
            .frame(height: 155)
            .modifier(TimelineGesture(viewport: viewport, earliestRecord: earliestRecord,
              recordBucket: metricRecordBucket(metric), dates: { points.map(\.date) }))
        default:
          Text("进入详情查看").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 5)
    .task(id: NutritionChartRequest(revision: viewport.revision, mealStorage: mealStorage)) { await load() }
  }

  private func load() async {
    loading = true
    error = nil
    defer { loading = false }
    let range = viewport.queryRange(sleep: kind == .sleep)
    do {
      switch kind {
      case .sleep, .alert, .symptom, .event:
        let result = try await HealthTrendRepository.shared.events(for: metric, range: range, limit: nil)
        guard !Task.isCancelled else { return }
        events = result
      case .food:
        let result = try await HealthCorrelationRepository.shared.foods(in: range,
          meals: MealEntry.decode(mealStorage ?? Data()))
        guard !Task.isCancelled else { return }
        foods = result
      case .numeric:
        let result: [TrendPoint]
        if let mealStorage {
          result = try await HealthTrendRepository.shared.mealNutritionSeries(for: metric, range: range,
            meals: MealEntry.decode(mealStorage), calendar: .current)
        } else {
          result = try await HealthTrendRepository.shared.series(for: metric, range: range,
            bucket: .day, calendar: .current, preserveSamples: metricRecordBucket(metric) == nil)
        }
        guard !Task.isCancelled else { return }
        points = result
      case .bloodPressure:
        let result = try await HealthCorrelationRepository.shared.bloodPressure(in: range)
        guard !Task.isCancelled else { return }
        pressure = result
      default: break
      }
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
}

private struct HealthMetricDetail: View {
  let metric: HealthMetricDefinition
  @Binding var favorites: Set<String>
  @StateObject private var viewport = ChartViewport()
  @Environment(\.dismiss) private var dismiss
  @State private var points: [TrendPoint] = []
  @State private var events: [HealthTimelineEvent] = []
  @State private var bpPairs: [BloodPressurePair] = []
  @State private var foodEntries: [HealthFoodCorrelation] = []
  @State private var error: String?
  @AppStorage(MealEntry.storageKey) private var mealStorage = Data()
  private var nutritionStorage: Data? {
    MealTrendData.identifiers.contains(metric.identifier) ? mealStorage : nil
  }
  private var kind: HealthDisplayKind { .classify(metric) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(viewport.visibleLabel).font(.caption.monospacedDigit())
          .lineLimit(1).minimumScaleFactor(0.75)
        Spacer()
        Button("重置") { viewport.reset() }.buttonStyle(.bordered).controlSize(.small)
        if kind != .workout { HealthTimeRangeMenu(viewport: viewport) }
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      switch kind {
      case .sleep:
        SleepDailyColumnsChart(events: events, viewport: viewport)
          .frame(height: 330)
        Text("纵轴从前一天 12:00 到当天 12:00。彩柱表示睡眠阶段，细柱表示零碎睡眠。紫色和蓝色分别表示入睡和醒来时间，粗虚线为拟合，细虚线跨过缺测日。")
          .font(.caption).foregroundStyle(.secondary)
      case .alert, .symptom, .event:
        ScrollView {
          HealthEventList(metric: metric, events: events.filter {
            $0.start <= viewport.range.upperBound && $0.end >= viewport.range.lowerBound
          })
        }
      case .bloodPressure:
        if bpPairs.isEmpty { emptyMessage }
        else { BloodPressurePairChart(pairs: bpPairs, range: viewport.range)
          .frame(height: 260)
          .modifier(TimelineGesture(viewport: viewport, dates: { bpPairs.map(\.date) })) }
      case .food:
        let visible = foodEntries.filter { viewport.range.contains($0.date) }
        if visible.isEmpty { emptyMessage }
        else { List(visible) { NutritionMealRow(item: $0) }.listStyle(.plain) }
      case .workout:
        ContentUnavailableView("请查看训练与饮食", systemImage: "dumbbell")
      case .numeric:
        if points.isEmpty { emptyMessage }
        else {
          MetricChart(metric: metric, points: points, range: viewport.range,
            revision: viewport.revision)
            .frame(height: 275).modifier(TimelineGesture(viewport: viewport,
              recordBucket: metricRecordBucket(metric), dates: { points.map(\.date) }))
          Text(metricBars(metric) ? "橙色虚线为拟合趋势。" : "橙色虚线为拟合趋势，细虚线跨过缺测时段。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14).padding(.top, 12)
    .navigationTitle(metric.title).navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          if favorites.contains(metric.identifier) { favorites.remove(metric.identifier) }
          else { favorites.insert(metric.identifier) }
        } label: {
          Image(systemName: favorites.contains(metric.identifier) ? "star.fill" : "star")
        }
      }
    }
    .task(id: nutritionStorage) { await loadBounds() }
    .task(id: NutritionChartRequest(revision: viewport.revision, mealStorage: nutritionStorage)) { await load() }
  }
  private var emptyMessage: some View {
    Text("当前范围内没有可读取数据")
      .font(.footnote).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: 80)
  }
  @MainActor private func loadBounds() async {
    guard !metric.isSpecial || kind == .food else { return }
    do {
      let result: HealthMetricBounds?
      if let nutritionStorage {
        result = try await HealthTrendRepository.shared.mealTrendBounds(for: metric,
          meals: MealEntry.decode(nutritionStorage))
      } else {
        result = try await HealthTrendRepository.shared.bounds(for: metric)
      }
      if let result, !Task.isCancelled { viewport.setBounds(result, focus: true) }
    } catch { self.error = error.localizedDescription }
  }
  private func load() async {
    guard kind != .workout else { return }
    error = nil
    let range = viewport.queryRange(sleep: kind == .sleep)
    do {
      switch kind {
      case .sleep, .alert, .symptom, .event:
        let result = try await HealthTrendRepository.shared.events(for: metric, range: range, limit: nil)
        guard !Task.isCancelled else { return }
        events = result
      case .bloodPressure:
        let result = try await HealthCorrelationRepository.shared.bloodPressure(in: range)
        guard !Task.isCancelled else { return }
        bpPairs = result
      case .food:
        let result = try await HealthCorrelationRepository.shared.foods(in: range,
          meals: MealEntry.decode(mealStorage))
        guard !Task.isCancelled else { return }
        foodEntries = result
      case .numeric:
        let result: [TrendPoint]
        if let nutritionStorage {
          result = try await HealthTrendRepository.shared.mealNutritionSeries(for: metric, range: range,
            meals: MealEntry.decode(nutritionStorage), calendar: .current)
        } else {
          result = try await HealthTrendRepository.shared.series(for: metric,
            range: range, bucket: .day, calendar: .current,
            preserveSamples: metricRecordBucket(metric) == nil)
        }
        guard !Task.isCancelled else { return }
        points = result
      case .workout: break
      }
    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
  }
}

// MARK: - Visual density and robust trends

struct PlotPoint: Identifiable, Sendable {
  let point: TrendPoint
  let segment: Int
  var date: Date { point.date }
  var value: Double { point.value }
  var measurementSeries: String { "测量-\(segment)" }
  var bandSeries: String { "范围-\(segment)" }
  var id: String { "\(segment)-\(point.chartID)" }
}

enum PlotDensity {
  /// Limit the evaluation positions of the fitted line, never the measured series.
  static func fittingAnchors(_ points: [TrendPoint], limit: Int) -> [TrendPoint] {
    guard points.count > limit else { return points }
    return (0..<limit).map { index in
      points[index * (points.count - 1) / (limit - 1)]
    }
  }

  static func visibleMarkers(_ points: [PlotPoint], limit: Int) -> [TrendPoint] {
    guard points.count > limit else { return points.map(\.point) }
    let selected = Set((0..<limit).map { $0 * (points.count - 1) / (limit - 1) })
    return points.indices.compactMap { index in
      let point = points[index]
      // A singleton segment has no line to represent it, so keep its symbol.
      let joinsPrevious = index > 0 && points[index - 1].segment == point.segment
      let joinsNext = index + 1 < points.count && points[index + 1].segment == point.segment
      return selected.contains(index) || (!joinsPrevious && !joinsNext) ? point.point : nil
    }
  }

  static func segments(_ points: [TrendPoint], maximumGap: TimeInterval = 5 * 86400) -> [PlotPoint] {
    var series = 0
    var last: TrendPoint?
    return points.map { current in
      if let last, current.epoch - last.epoch > maximumGap { series += 1 }
      last = current
      return PlotPoint(point: current, segment: series)
    }
  }

  static func gapEndpoints(_ points: [PlotPoint]) -> [PlotPoint] {
    zip(points, points.dropFirst()).flatMap { previous, next -> [PlotPoint] in
      guard previous.segment != next.segment else { return [] }
      return [PlotPoint(point: previous.point, segment: next.segment), next]
    }
  }
}

enum TimeWindowTrend {
  /// Fit against elapsed time. Widen sparse neighborhoods to three measured times.
  static func make(_ points: [TrendPoint], visible: ClosedRange<Date>) -> [TrendPoint] {
    let seconds = visible.upperBound.timeIntervalSince(visible.lowerBound)
    let radius = max(3 * 86400, min(21 * 86400, seconds * 0.15))
    let visiblePoints = points.filter { $0.value.isFinite && $0.epoch.isFinite && visible.contains($0.date) }
    let source = Dictionary(grouping: visiblePoints, by: \.epoch).map { epoch, samples in
      TrendPoint(epoch: epoch, value: samples.reduce(0) { $0 + $1.value } / Double(samples.count))
    }.sorted { $0.epoch < $1.epoch }
    guard source.count >= 3 else { return [] }
    return PlotDensity.fittingAnchors(source, limit: 45).map { anchor in
      var neighbors = source.filter { abs($0.epoch - anchor.epoch) <= radius }
      if neighbors.count < 3 {
        let index = HealthChartSelection.closestIndex(to: anchor.date, in: source, date: \.date) ?? 0
        var lower = index
        var upper = index
        while upper - lower < 2 {
          if upper == source.count - 1 || (lower > 0 &&
              anchor.epoch - source[lower - 1].epoch <= source[upper + 1].epoch - anchor.epoch) {
            lower -= 1
          } else {
            upper += 1
          }
        }
        neighbors = Array(source[lower...upper])
      }
      let count = Double(neighbors.count)
      let meanX = neighbors.reduce(0) { $0 + ($1.epoch - anchor.epoch) } / count
      let meanY = neighbors.reduce(0) { $0 + $1.value } / count
      let variance = neighbors.reduce(0) { $0 + pow($1.epoch - anchor.epoch - meanX, 2) }
      let covariance = neighbors.reduce(0) { $0 + ($1.epoch - anchor.epoch - meanX) * ($1.value - meanY) }
      let estimate = variance > 0 ? meanY - meanX * covariance / variance : meanY
      let bounds = neighbors.map(\.value)
      return TrendPoint(epoch: anchor.epoch,
        value: min(bounds.max() ?? meanY, max(bounds.min() ?? meanY, estimate)))
    }
  }
}

enum HealthChartSelection {
  static func closestIndex<T>(to target: Date, in records: [T], date: KeyPath<T, Date>) -> Int? {
    guard !records.isEmpty else { return nil }
    var lower = 0
    var upper = records.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if records[middle][keyPath: date] < target { lower = middle + 1 }
      else { upper = middle }
    }
    if lower == 0 { return 0 }
    if lower == records.count { return lower - 1 }
    let previous = records[lower - 1][keyPath: date]
    let next = records[lower][keyPath: date]
    return target.timeIntervalSince(previous) <= next.timeIntervalSince(target) ? lower - 1 : lower
  }

  static func number(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...4)))
  }
}

extension View {
  func healthChartTap(_ action: @escaping (ChartProxy, CGPoint) -> Void) -> some View {
    chartOverlay { proxy in
      GeometryReader { geometry in
        Rectangle().fill(.clear).contentShape(Rectangle())
          .simultaneousGesture(SpatialTapGesture().onEnded { tap in
            guard let frame = proxy.plotFrame.map({ geometry[$0] }), frame.contains(tap.location) else { return }
            action(proxy, CGPoint(x: tap.location.x - frame.minX, y: tap.location.y - frame.minY))
          })
      }
    }
  }
}

struct HealthChartValueLabel: View {
  let date: String
  let value: String
  var detail: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(date).font(.caption)
      Text(value).font(.caption.weight(.semibold)).monospacedDigit()
      if let detail { Text(detail).font(.caption2).monospacedDigit() }
    }
    .padding(7)
    .background(.regularMaterial)
    .accessibilityElement(children: .combine)
    .allowsHitTesting(false)
  }
}

private struct MetricChart: View {
  let metric: HealthMetricDefinition
  let points: [TrendPoint]
  let range: ClosedRange<Date>
  let revision: Int
  @State private var trend: [TrendPoint] = []
  @State private var selectedID: String?

  private var selected: TrendPoint? {
    guard let selectedID else { return nil }
    return points.first { $0.chartID == selectedID }
  }

  private var visible: [TrendPoint] {
    if let bucket = metricRecordBucket(metric) {
      return points.compactMap { $0.plotted(in: range, bucket: bucket) }
    }
    return points.filter { range.contains($0.date) }
  }
  private struct TrendRequest: Equatable {
    let revision: Int
    let points: [TrendPoint]
  }
  var body: some View {
    GeometryReader { geometry in
      let raw = visible
      let bars = metricBars(metric)
      let rangeStyle = metricRange(metric)
      let scatter = metric.chart_template == "glucose_scatter"
      let plotLines = bars ? [] : PlotDensity.segments(raw,
        maximumGap: rangeStyle ? 1.5 * 86400 : 5 * 86400)
      let gaps = PlotDensity.gapEndpoints(plotLines)
      let markerLimit = max(2, Int(geometry.size.width / 13))
      let markers = scatter ? raw : PlotDensity.visibleMarkers(plotLines, limit: markerLimit)
      let wideWindow = range.upperBound.timeIntervalSince(range.lowerBound) >= 180 * 86400
      let markerSize: CGFloat = wideWindow || raw.count > markerLimit ? 4 : 12
      let barWidth = min(18, geometry.size.width / CGFloat(max(1, raw.count)) * 0.60)
      let rangeCounts = rangeStyle ? Dictionary(grouping: plotLines, by: \.segment).mapValues(\.count) : [:]
      let bucket = metricRecordBucket(metric)
      let selection = selected
      let highlight: TrendPoint? = selection.flatMap { point in
        if let bucket { return point.plotted(in: range, bucket: bucket) }
        return range.contains(point.date) ? point : nil
      }
      Chart {
        if bars {
          ForEach(raw, id: \.chartID) { item in
            BarMark(x: .value("时间", item.date),
              y: .value(metric.title, item.value), width: .fixed(barWidth))
              .foregroundStyle(HealthTheme.accent)
          }
        } else if rangeStyle {
          ForEach(plotLines) { item in
            let value = item.point
            if let low = value.minimum, let high = value.maximum {
              if rangeCounts[item.segment] == 1 {
                RuleMark(x: .value("时间", value.date),
                  yStart: .value("低", low), yEnd: .value("高", high))
                  .foregroundStyle(HealthTheme.accent.opacity(0.35))
              } else {
                AreaMark(x: .value("时间", value.date),
                  yStart: .value("低", low), yEnd: .value("高", high),
                  series: .value("曲线", item.bandSeries))
                  .foregroundStyle(HealthTheme.accent.opacity(0.23))
                  .interpolationMethod(.linear)
              }
            }
            LineMark(x: .value("时间", value.date), y: .value("均值", value.value),
              series: .value("曲线", item.measurementSeries))
              .foregroundStyle(HealthTheme.accent)
              .interpolationMethod(.linear)
          }
        } else {
          if #available(iOS 18.0, *) {
            LinePlot(plotLines, x: .value("时间", \.date), y: .value(metric.title, \.value),
              series: .value("曲线", \.measurementSeries))
              .foregroundStyle(HealthTheme.accent)
              .interpolationMethod(.linear)
          } else {
            ForEach(plotLines) { item in
              LineMark(x: .value("时间", item.date),
                y: .value(metric.title, item.value),
                series: .value("曲线", item.measurementSeries))
                .foregroundStyle(HealthTheme.accent)
                .interpolationMethod(.linear)
            }
          }
        }
        ForEach(gaps) { item in
          LineMark(x: .value("时间", item.date), y: .value(metric.title, item.value),
            series: .value("曲线", "缺测-\(item.segment)"))
            .foregroundStyle(HealthTheme.accent.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        if !bars {
          if #available(iOS 18.0, *) {
            PointPlot(markers, x: .value("时间", \.date), y: .value(metric.title, \.value))
              .symbolSize(markerSize)
              .foregroundStyle(HealthTheme.accent)
          } else {
            ForEach(markers, id: \.chartID) { point in
              PointMark(x: .value("时间", point.date), y: .value(metric.title, point.value))
                .symbolSize(markerSize)
                .foregroundStyle(HealthTheme.accent)
            }
          }
        }
        ForEach(trend) { point in
          LineMark(x: .value("时间", point.date),
            y: .value("拟合", point.value),
            series: .value("曲线", "拟合"))
            .foregroundStyle(Color.orange)
            .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
            .interpolationMethod(.linear)
        }
        if let highlight {
          RuleMark(x: .value("选中时间", highlight.date))
            .foregroundStyle(HealthTheme.accent.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
          PointMark(x: .value("选中时间", highlight.date),
            y: .value(metric.title, highlight.value))
            .foregroundStyle(HealthTheme.accent)
            .symbolSize(48)
        }
      }
      .chartXScale(domain: range)
      .chartYScale(domain: .automatic(includesZero: bars))
      .chartPlotStyle { $0.clipped() }
      .chartXAxis { healthChartXAxis(range) }
      .healthChartTap { proxy, tap in
        selectPoint(at: tap, proxy: proxy, visible: raw, bucket: bucket)
      }
      .overlay(alignment: .topTrailing) {
        if highlight != nil, let selection {
          let prefix = bars ? "当日合计 " : (rangeStyle ? "日均 " : "")
          let date = selection.date.formatted(bucket == nil ? HealthChartDate.minute : HealthChartDate.day)
          HealthChartValueLabel(date: date,
            value: "\(prefix)\(HealthChartSelection.number(selection.value)) \(metric.display_unit)",
            detail: rangeLabel(selection))
          .padding(4)
        }
      }
    }
    .onChange(of: revision) { _, _ in selectedID = nil }
    .task(id: TrendRequest(revision: revision, points: points)) {
      trend = []
      let copied = visible
      let committed = range
      let result = await Task.detached(priority: .utility) {
        TimeWindowTrend.make(copied, visible: committed)
      }.value
      if !Task.isCancelled { trend = result }
    }
  }

  private func rangeLabel(_ point: TrendPoint) -> String? {
    guard let low = point.minimum, let high = point.maximum, low != high else { return nil }
    return "最低 \(HealthChartSelection.number(low)) · 最高 \(HealthChartSelection.number(high))"
  }

  private func selectPoint(at tap: CGPoint, proxy: ChartProxy, visible: [TrendPoint], bucket: HealthBucket?) {
    guard let date = proxy.value(atX: tap.x, as: Date.self),
      let closest = HealthChartSelection.closestIndex(to: date, in: visible, date: \.date),
      let x = proxy.position(forX: visible[closest].date), abs(tap.x - x) <= 28 else {
      selectedID = nil
      return
    }
    let closestPoint = visible[closest]
    let point: TrendPoint
    if let bucket {
      let start = Calendar.current.dateInterval(of: bucket.component, for: closestPoint.date)?.start
      point = points.first { $0.date == start } ?? closestPoint
    } else {
      // Multiple samples can share one timestamp. Select the one closest to the tap vertically.
      var lower = closest
      var upper = closest
      while lower > 0, visible[lower - 1].epoch == closestPoint.epoch { lower -= 1 }
      while upper + 1 < visible.count, visible[upper + 1].epoch == closestPoint.epoch { upper += 1 }
      point = visible[lower...upper].min {
        abs((proxy.position(forY: $0.value) ?? tap.y) - tap.y)
          < abs((proxy.position(forY: $1.value) ?? tap.y) - tap.y)
      } ?? closestPoint
    }
    selectedID = selectedID == point.chartID ? nil : point.chartID
  }
}
