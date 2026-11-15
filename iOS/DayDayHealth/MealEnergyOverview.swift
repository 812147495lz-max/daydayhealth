import SwiftUI

struct MealFoodSearch: View {
  let history: [MealEntry]
  let onSelect: (MealFoodEstimate) -> Void
  let onReuseMeal: ((MealEntry) -> Void)?
  @Environment(\.dismiss) private var dismiss
  @AppStorage(PackagedNutritionLabel.storageKey) private var packagedStorage = Data()
  @State private var query = ""
  @State private var matches: [MealNutritionCatalog.Entry] = []
  @State private var packagedMatches: [MealNutritionCatalog.Entry] = []
  @State private var resolvedQuery = ""

  private func recent(matching search: FoodSearchQuery, savedNames: Set<String>) -> [MealFoodEstimate] {
    var names = Set<String>()
    let foods = history.sorted { $0.date > $1.date }.lazy
      .flatMap { $0.items ?? [] }
    var results: [(food: MealFoodEstimate, score: Int)] = []
    for food in foods where food.isValid {
      let name = FoodSearchQuery.normalize(food.name)
      guard !savedNames.contains(name), names.insert(name).inserted else { continue }
      let score = search.normalized.isEmpty ? 1 : search.score([FoodSearchQuery.Field(food.name)])
      if score > 0 { results.append((food, score)) }
    }
    return results.sorted { $0.score > $1.score }.prefix(20).map(\.food)
  }

  private var manualMeals: [MealEntry] {
    guard onReuseMeal != nil else { return [] }
    let search = FoodSearchQuery(query)
    var names = Set<String>()
    let meals = MealHistoryPicker.matches(history.filter { ($0.items ?? []).isEmpty }, query: search)
      .filter { names.insert(FoodSearchQuery.normalize($0.food)).inserted }
    return Array(meals.prefix(12))
  }

  var body: some View {
    NavigationStack {
      List {
        let search = FoodSearchQuery(query)
        let labels = PackagedNutritionLabel.search(search, in: packagedStorage)
        let savedNames = Set(labels.map { FoodSearchQuery.normalize($0.displayName) })
        let previous = recent(matching: search, savedNames: savedNames)
        let manual = manualMeals
        if !labels.isEmpty {
          Section("我的食品") {
            ForEach(labels.prefix(search.normalized.isEmpty ? 20 : 30), id: \.catalogKey) { label in
              if let food = label.portion {
                foodRow(food, detail: label.barcode)
              }
            }
          }
        }
        if !previous.isEmpty {
          Section("吃过的食物") {
            ForEach(previous, id: \.name) { food in foodRow(food) }
          }
        }
        if let onReuseMeal, !manual.isEmpty {
          Section("以前的手动记录") {
            ForEach(manual) { meal in
              Button {
                onReuseMeal(meal)
                dismiss()
              } label: {
                LabeledContent(meal.food, value: meal.calories.map { MealEnergyMath.kcal(Double($0)) } ?? "复用一餐")
              }
            }
          }
        }
        let searchingCatalog = resolvedQuery != query && !search.normalized.isEmpty
        if !searchingCatalog && !packagedMatches.isEmpty {
          let savedCodes = Set(labels.map(\.catalogKey))
          let products = packagedMatches.filter { entry in
            guard let code = entry.barcode else { return true }
            return !savedCodes.contains("barcode:\(code)")
          }
          if !products.isEmpty {
            Section("预包装食品") {
              ForEach(products, id: \.id) { product in
                let details = [product.quantity, product.barcode, product.source]
                  .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                foodRow(product.portion, detail: details, showMacros: true)
                  .contextMenu {
                    if let sourceURL = product.sourceURL {
                      Link("查看品牌营养标签", destination: sourceURL)
                    } else if let barcode = product.barcode,
                              let url = URL(string: "https://world.openfoodfacts.org/product/\(barcode)") {
                      Link("查看 Open Food Facts 商品", destination: url)
                    }
                  }
              }
            }
          }
        }
        if !searchingCatalog && !matches.isEmpty {
          Section("食品成分库") {
            ForEach(matches, id: \.id) { entry in
              foodRow(entry.portion, detail: entry.source ?? "USDA")
            }
          }
        }
        if !searchingCatalog && (!matches.isEmpty || !packagedMatches.isEmpty) {
          DisclosureGroup("数据来源") {
            Link("Open Food Facts 贡献者 · 预包装食品",
              destination: URL(string: "https://world.openfoodfacts.org/data")!)
            Link("预包装食品数据许可 · ODbL 1.0",
              destination: URL(string: "https://opendatacommons.org/licenses/odbl/1-0/")!)
            if let url = MealNutritionCatalog.chinaPackagedURL {
              ShareLink(item: url) { Label("导出预包装食品数据", systemImage: "square.and.arrow.up") }
            }
            Link("台湾食药署 · 食品营养成分资料集",
              destination: URL(string: "https://data.gov.tw/dataset/8543")!)
            Link("Guan 等 · 八大菜系 320 道菜（CC BY 4.0）",
              destination: URL(string: "https://doi.org/10.6084/m9.figshare.32721765.v1")!)
            Link("Long 等 · 亚洲食谱营养数据（CC BY 4.0）",
              destination: URL(string: "https://doi.org/10.6084/m9.figshare.25999843.v3")!)
            Text("八大菜系按研究的 300 克配方基准换算；中式食谱按原表每份估算。食药署资料依政府资料开放授权条款第 1 版提供。")
              .font(.footnote).foregroundStyle(.secondary)
          }
        }
        if searchingCatalog && labels.isEmpty && previous.isEmpty && manual.isEmpty {
          ProgressView("正在搜索食品成分库")
        } else if !searchingCatalog && labels.isEmpty && previous.isEmpty && manual.isEmpty
                    && matches.isEmpty && packagedMatches.isEmpty {
          Text(query.isEmpty ? "输入食物名称开始搜索" : "没有匹配的食物，可通过营养表录入包装食品")
            .foregroundStyle(.secondary)
        }
      }
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索名称、品牌、类别或条码")
      .navigationTitle("添加食物")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
      .task(id: query) {
        let term = query
        if FoodSearchQuery(term).normalized.isEmpty {
          matches = []
          packagedMatches = []
          resolvedQuery = term
          return
        }
        do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
        let found = await Task.detached(priority: .userInitiated) {
          (MealNutritionCatalog.search(term), MealNutritionCatalog.searchPackaged(term))
        }.value
        guard !Task.isCancelled, term == query else { return }
        (matches, packagedMatches) = found
        resolvedQuery = term
      }
    }
  }

  private func foodRow(_ food: MealFoodEstimate, detail: String? = nil, showMacros: Bool = false) -> some View {
    let amount = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
    return Button {
      onSelect(food)
      dismiss()
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Text(food.name)
        Text("\(food.grams.formatted(.number.precision(.fractionLength(0...3)))) \(food.portionUnit.label) · \(MealEnergyMath.kcal(food.kcal))")
          .font(.subheadline).foregroundStyle(.secondary)
        if showMacros {
          Text("蛋白质 \(food.protein.formatted(amount)) g · 脂肪 \(food.fat.formatted(amount)) g · 碳水 \(food.carbs.formatted(amount)) g")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let detail, !detail.isEmpty {
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
}

struct MealHistoryPicker: View {
  let history: [MealEntry]
  let replacesDraft: Bool
  let onUse: (MealEntry) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var pending: MealEntry?

  static func matches(_ history: [MealEntry], query: FoodSearchQuery) -> [MealEntry] {
    history.compactMap { meal -> (meal: MealEntry, score: Int)? in
      guard meal.isDeleted != true,
        !meal.food.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !meal.reusableItems.isEmpty
      else { return nil }
      let score = query.normalized.isEmpty ? 1 : query.score(
        ([meal.food] + (meal.items ?? []).map(\.name)).map(FoodSearchQuery.Field.init))
      return score > 0 ? (meal, score) : nil
    }
    .sorted {
      $0.score == $1.score ? $0.meal.date > $1.meal.date : $0.score > $1.score
    }
    .map(\.meal)
  }

  var body: some View {
    NavigationStack {
      List {
        let meals = Self.matches(history, query: FoodSearchQuery(query))
        if meals.isEmpty {
          ContentUnavailableView(query.isEmpty ? "暂无饮食记录" : "没有匹配的历史记录",
            systemImage: "clock.arrow.circlepath")
        }
        ForEach(meals) { meal in
          Button {
            if replacesDraft {
              pending = meal
            } else {
              use(meal)
            }
          } label: {
            VStack(alignment: .leading, spacing: 5) {
              Text(meal.food.isEmpty ? meal.reusableItems.map(\.name).joined(separator: "、") : meal.food)
                .font(.headline)
              Text(meal.date, format: .dateTime.year().month().day().hour().minute().locale(HealthChartDate.chinese))
                .font(.subheadline)
                .foregroundStyle(.secondary)
              if let calories = meal.calories {
                Text(MealEnergyMath.kcal(Double(calories)))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索历史菜名或食物")
      .navigationTitle("从历史调取")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
      .confirmationDialog("替换当前餐食内容？", isPresented: Binding(
        get: { pending != nil }, set: { if !$0 { pending = nil } }
      ), titleVisibility: .visible, presenting: pending) { meal in
        Button("调取这餐", role: .destructive) { use(meal) }
        Button("取消", role: .cancel) {}
      } message: { _ in
        Text("保留当前用餐时间，载入所选记录的食物和份量。")
      }
    }
  }

  private func use(_ meal: MealEntry) {
    onUse(meal)
    dismiss()
  }
}

enum MealEnergyMath {
  static let kcalPerKilogram = 7_700.0

  static let completionKey = "wbMealCompleteDays"
  static let mealClock = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted))
    .minute(.twoDigits).locale(HealthChartDate.chinese)

  static func dayKey(_ date: Date) -> String {
    let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
    return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
  }

  static func confirmedDays(in data: Data) -> Set<String> {
    (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
  }

  static func kcal(_ value: Double) -> String {
    "\(value.formatted(.number.precision(.fractionLength(0)))) 千卡"
  }

  static func loggedIntake(_ meals: [MealEntry], confirmedEmpty: Bool = false) -> Double? {
    if meals.isEmpty { return confirmedEmpty ? 0 : nil }
    guard meals.allSatisfy({ ($0.calories ?? -1) >= 0 }) else { return nil }
    return meals.reduce(0) { $0 + Double($1.calories ?? 0) }
  }

  static func weeklyTargetDeficit(weeklyLossJin: Double, goalWeight: Double, currentWeight: Double?) -> Double? {
    let plannedLoss = weeklyLossJin / 2
    guard plannedLoss.isFinite, plannedLoss > 0 else { return 0 }
    guard goalWeight > 0 else { return plannedLoss * kcalPerKilogram }
    guard let currentWeight, currentWeight.isFinite, currentWeight > 0 else { return nil }
    return min(plannedLoss, max(0, currentWeight - goalWeight)) * kcalPerKilogram
  }

  enum WeeklyIntakeBudget {
    case awaitingWeight
    case awaitingExpenditure
    case paceTooHigh
    case available(Double)

    init(expenditure: Double?, targetDeficit: Double?) {
      // Use the NIDDK Body Weight Planner's lower bound to flag implausible plans.
      let minimumWeeklyIntake = 7 * 1_000.0
      guard let expenditure, expenditure.isFinite, expenditure >= minimumWeeklyIntake else {
        self = .awaitingExpenditure
        return
      }
      guard let targetDeficit else {
        self = .awaitingWeight
        return
      }
      let intake = expenditure - targetDeficit
      self = intake >= minimumWeeklyIntake ? .available(intake) : .paceTooHigh
    }

    var total: Double? {
      if case .available(let total) = self { return total }
      return nil
    }
  }

  static func weeklyDeficits(from week: Date, through today: Date, calendar: Calendar,
                             meals: [Date: [MealEntry]], confirmed: Set<String>,
                             basal: [Date: Double], active: [Date: Double]) -> [Double] {
    (0..<7).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: week), date <= today,
        let intake = loggedIntake(meals[date] ?? [], confirmedEmpty: confirmed.contains(dayKey(date))),
        let resting = basal[date], let movement = active[date] else { return nil }
      return resting + movement - intake
    }
  }

  struct DailyExpenditure {
    let basal: Double?
    let active: Double?

    var total: Double? {
      guard let basal, let active else { return nil }
      return basal + active
    }
  }

  static func recentDays(before today: Date, calendar: Calendar) -> [Date] {
    (1...7).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
  }

  static func fullDayExpenditure(now: Date, calendar: Calendar, basal: [Date: Double],
                                 active: [Date: Double], hourlyActivity: [TrendPoint],
                                 estimatedResting: Double?) -> DailyExpenditure {
    let today = calendar.startOfDay(for: now)
    let recent = recentDays(before: today, calendar: calendar)
    let typicalResting = average(recent.compactMap { basal[$0] }.filter { $0 > 0 }) ?? estimatedResting
    let resting = typicalResting.map { max($0, basal[today] ?? 0) }
    let typicalActivity = average(recent.compactMap { active[$0] })
    guard let actual = active[today] else {
      return DailyExpenditure(basal: resting, active: typicalActivity)
    }

    // Compare against when movement actually happened on complete recent days.
    // Use the full-day baseline if only daily totals are available.
    let hourlyByDay = Dictionary(grouping: hourlyActivity.filter {
      $0.date < today && $0.value.isFinite && $0.value >= 0
    }) { calendar.startOfDay(for: $0.date) }
    let elapsed = now.timeIntervalSince(today)
    let todayDuration = calendar.dateInterval(of: .day, for: now)?.duration
    let remaining = recent.compactMap { day -> Double? in
      guard let total = active[day], let hourly = hourlyByDay[day],
        let interval = calendar.dateInterval(of: .day, for: day), interval.duration == todayDuration
      else { return nil }
      let hourlyTotal = hourly.reduce(0.0) { $0 + $1.value }
      guard abs(hourlyTotal - total) <= max(10, total * 0.1) else { return nil }
      return hourly.reduce(0.0) { sum, point in
        guard let hour = calendar.dateInterval(of: .hour, for: point.date) else { return sum }
        let remainingFraction = min(1, max(0, (hour.end.timeIntervalSince(day) - elapsed) / hour.duration))
        return sum + point.value * remainingFraction
      }
    }
    let activity = remaining.count >= 3
      ? average(remaining).map { actual + $0 }
      : typicalActivity.map { max(actual, $0) }
    return DailyExpenditure(basal: resting, active: activity)
  }

  static func weeklyExpenditure(from week: Date, today: Date, calendar: Calendar,
                                basal: [Date: Double], active: [Date: Double],
                                todayForecast: DailyExpenditure) -> Double? {
    let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week) }
    guard days.count == 7, week <= today else { return nil }
    if days[6] < today {
      let totals = days.compactMap { day -> Double? in
        guard let resting = basal[day], resting > 0, let movement = active[day] else { return nil }
        return resting + movement
      }
      return totals.count == 7 ? totals.reduce(0, +) : nil
    }
    let recent = recentDays(before: today, calendar: calendar)
    let resting = average(recent.compactMap { basal[$0] }.filter { $0 > 0 }) ?? todayForecast.basal
    let movement = average(recent.compactMap { active[$0] })
    guard let resting, let movement, let todayTotal = todayForecast.total else { return nil }
    return days.reduce(0.0) { total, day in
      if day == today { return total + todayTotal }
      let recordedResting = basal[day].flatMap { $0 > 0 ? $0 : nil }
      return total + (recordedResting ?? resting) + (active[day] ?? movement)
    }
  }

  private static func average(_ values: [Double]) -> Double? {
    values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
  }

  static func restingFromBodyComposition(leanMass: [Date: Double], weight: [Date: Double],
                                         bodyFat: [Date: Double]) -> Double? {
    let dates = Set(leanMass.keys).union(bodyFat.keys).sorted(by: >)
    for day in dates {
      if let lean = leanMass[day], lean > 0 {
        return 500 + 22 * lean
      }
      if let kg = weight[day], kg > 0, let fraction = bodyFat[day], fraction > 0, fraction < 1 {
        return 500 + 22 * kg * (1 - fraction)
      }
    }
    return nil
  }

  static func healthSeries(_ type: String, in range: ClosedRange<Date>,
                                  calendar: Calendar, bucket: HealthBucket = .day, refresh: Bool = false) async -> [TrendPoint] {
    guard let metric = HealthMetricCatalog.all.first(where: { $0.identifier == "HKQuantityTypeIdentifier" + type })
    else { return [] }
    return (try? await HealthTrendRepository.shared.series(
      for: metric, range: range, bucket: bucket, calendar: calendar, refresh: refresh)) ?? []
  }

  static func daysToGoal(weight: Double, goal: Double, kgPerDay: Double) -> Int? {
    if weight <= goal { return 0 }
    guard kgPerDay > 0 else { return nil }
    let days = ceil((weight - goal) / kgPerDay)
    return days.isFinite && days <= Double(Int32.max) ? Int(days) : nil
  }

  static func lossTrend(_ points: [TrendPoint], today: Date, calendar: Calendar) -> Double? {
    let rows = points.filter { $0.value.isFinite && $0.value > 0 }.sorted { $0.date < $1.date }
    guard rows.count >= 3, let first = rows.first, let last = rows.last,
      calendar.dateComponents([.day], from: first.date, to: last.date).day ?? 0 >= 7,
      calendar.dateComponents([.day], from: last.date, to: today).day ?? 30 <= 14 else { return nil }
    let days = rows.map { Double(calendar.dateComponents([.day], from: first.date, to: $0.date).day ?? 0) }
    let count = Double(rows.count)
    let meanDay = days.reduce(0, +) / count
    let meanWeight = rows.map(\.value).reduce(0, +) / count
    let variance = days.reduce(0) { $0 + pow($1 - meanDay, 2) }
    guard variance > 0 else { return nil }
    let slope = zip(days, rows).reduce(0.0) { result, row in
      result + (row.0 - meanDay) * (row.1.value - meanWeight)
    } / variance
    return -slope
  }
}

struct MealEnergyOverview<Records: View>: View {
  @ObservedObject var store: HealthStore
  let selectedDay: Date
  let entries: [MealEntry]
  @ViewBuilder let records: () -> Records
  @AppStorage(MealGoalSettings.weightKey) private var goalWeight = 0.0
  @AppStorage(MealGoalSettings.lossKey) private var weeklyLoss = 0.0
  @AppStorage(MealGoalSettings.currentWeightKey) private var manualWeight = 0.0
  @AppStorage(MealEnergyMath.completionKey) private var completeStorage = Data()
  @Environment(\.scenePhase) private var scenePhase
  @State private var snapshot = DailyData()
  @State private var loadedWeek: Date?

  private struct DailyData {
    var basal: [Date: Double] = [:]
    var active: [Date: Double] = [:]
    var hourlyActivity: [TrendPoint] = []
    var weights: [TrendPoint] = []
    var estimatedResting: Double?
  }

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
  }

  private var today: Date { calendar.startOfDay(for: .now) }
  private var day: Date { calendar.startOfDay(for: selectedDay) }
  private var week: Date { calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day }
  private var currentWeek: Bool { calendar.isDate(week, equalTo: today, toGranularity: .weekOfYear) }
  private var dailyData: DailyData { loadedWeek == week ? snapshot : DailyData() }
  private var currentWeight: Double? { manualWeight > 0 ? manualWeight : dailyData.weights.last?.value }
  private var targetDeficit: Double? {
    MealEnergyMath.weeklyTargetDeficit(weeklyLossJin: weeklyLoss,
      goalWeight: currentWeek ? goalWeight : 0, currentWeight: currentWeight)
  }
  private var completeDays: Set<String> {
    MealEnergyMath.confirmedDays(in: completeStorage)
  }

  var body: some View {
    let mealsByDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
    let selectedMeals = (mealsByDay[day] ?? []).sorted { $0.date < $1.date }
    let confirmed = completeDays
    let deficits = MealEnergyMath.weeklyDeficits(from: week, through: today, calendar: calendar,
      meals: mealsByDay, confirmed: confirmed, basal: dailyData.basal, active: dailyData.active)
    let forecast = MealEnergyMath.fullDayExpenditure(now: .now, calendar: calendar,
      basal: dailyData.basal, active: dailyData.active, hourlyActivity: dailyData.hourlyActivity,
      estimatedResting: dailyData.estimatedResting)
    let expenditure = MealEnergyMath.weeklyExpenditure(from: week, today: today, calendar: calendar,
      basal: dailyData.basal, active: dailyData.active, todayForecast: forecast)
    let showingForecast = day == today
    let dailyExpenditure = showingForecast ? forecast
      : MealEnergyMath.DailyExpenditure(basal: dailyData.basal[day], active: dailyData.active[day])
    let weeklyIntake = (0..<7).map { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: week), date <= today else { return 0.0 }
      return (mealsByDay[date] ?? []).compactMap(\.calories).filter { $0 >= 0 }
        .reduce(0.0) { $0 + Double($1) }
    }
    MealEnergyRings(meals: selectedMeals, expenditure: dailyExpenditure, showingForecast: showingForecast,
      confirmedEmpty: confirmed.contains(MealEnergyMath.dayKey(day)),
      currentWeek: currentWeek, budget: .init(expenditure: expenditure, targetDeficit: targetDeficit),
      weeklyIntake: weeklyIntake)
      .listRowBackground(HealthTheme.surface)
      .listRowSeparator(.hidden)
      .task(id: "\(week.timeIntervalSince1970)|\(today.timeIntervalSince1970)|\(scenePhase)|\(store.healthEnabled)") {
        guard scenePhase == .active else { return }
        await refresh()
        while currentWeek && !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(120)) } catch { return }
          await refresh()
        }
      }

    records()

    if weeklyLoss > 0 {
      Section {
        weeklyProgress(deficits: deficits)
          .listRowBackground(HealthTheme.surface)
          .listRowSeparator(.hidden)
      } header: {
        SectionTitle("每周减重计划")
      }
    }
    if goalWeight > 0 {
      Section {
        weightProgress.listRowBackground(HealthTheme.surface)
      } header: {
        SectionTitle("体重目标")
      }
    }
  }

  private var weekLabel: String {
    let lastDay = calendar.date(byAdding: .day, value: 6, to: week) ?? week
    let format = Date.FormatStyle.dateTime.month().day().locale(HealthChartDate.chinese)
    return "\(week.formatted(format)) 至 \(lastDay.formatted(format))"
  }

  private func weeklyProgress(deficits: [Double]) -> some View {
    let achieved = deficits.reduce(0, +)
    var bars: [MealBalanceChart.Bar] = []
    if let targetDeficit {
      bars.append(.init(title: "计划缺口", value: targetDeficit, color: MealEnergyPalette.target))
    }
    if !deficits.isEmpty {
      bars.append(.init(title: achieved >= 0 ? "消耗多于摄入" : "摄入多于消耗", value: achieved,
        color: achieved >= 0 ? MealEnergyPalette.deficit : MealEnergyPalette.surplus))
    }
    return VStack(alignment: .leading, spacing: 14) {
      Text(weekLabel)
        .font(.subheadline)
      if !bars.isEmpty { MealBalanceChart(bars: bars) }
      if targetDeficit == nil { Text("补充当前体重后计算计划缺口").font(.subheadline) }
      if deficits.isEmpty { Text("暂无可比较记录").font(.subheadline) }
    }
    .padding(.vertical, 10)
  }

  private var weightProgress: some View {
    let weights = dailyData.weights
    let trend = MealEnergyMath.lossTrend(weights, today: today, calendar: calendar)
    let estimate = currentWeight.flatMap { weight in
      trend.flatMap { MealEnergyMath.daysToGoal(weight: weight, goal: goalWeight, kgPerDay: $0) }
    }
    let plan = currentWeight.flatMap {
      MealEnergyMath.daysToGoal(weight: $0, goal: goalWeight, kgPerDay: weeklyLoss * 0.5 / 7)
    }
    return Group {
      LabeledContent("目标体重", value: "\(goalWeight.formatted(.number.precision(.fractionLength(0...1)))) 公斤")
      if let currentWeight {
        LabeledContent("当前体重", value: "\(currentWeight.formatted(.number.precision(.fractionLength(0...1)))) 公斤")
        if currentWeight <= goalWeight {
          LabeledContent("目标进度", value: "已达到目标体重")
        } else if let estimate {
          LabeledContent("按近 28 天体重趋势", value: "约 \(estimate) 天")
        } else {
          if let plan {
            LabeledContent("按设定速度估算", value: "约 \(plan) 天")
          } else {
            LabeledContent("预计达成", value: "暂无趋势估计")
          }
        }
      } else {
        LabeledContent("预计达成", value: "暂无近期体重记录")
      }
    }
  }

  private func refresh() async {
    let start = week
    let calendar = calendar
    let today = today
    guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: start),
      let recentEnergyStart = calendar.date(byAdding: .day, value: -7, to: today),
      let weightStart = calendar.date(byAdding: .day, value: -27, to: today) else { return }
    let energyStart = currentWeek ? min(start, recentEnergyStart) : start
    let now = Date()
    let recent: [TrendPoint]
    let basal: [TrendPoint]
    let active: [TrendPoint]
    let lean: [TrendPoint]
    let fat: [TrendPoint]
    var hourlyActivity: [TrendPoint] = []
    #if !targetEnvironment(macCatalyst)
    if store.healthEnabled {
      async let basalSeries = MealEnergyMath.healthSeries("BasalEnergyBurned",
        in: energyStart...min(weekEnd, now), calendar: calendar, refresh: currentWeek)
      async let activeSeries = MealEnergyMath.healthSeries("ActiveEnergyBurned",
        in: energyStart...min(weekEnd, now), calendar: calendar, refresh: currentWeek)
      async let weightSeries = MealEnergyMath.healthSeries("BodyMass", in: weightStart...now,
        calendar: calendar, refresh: currentWeek)
      async let leanSeries = currentWeek
        ? MealEnergyMath.healthSeries("LeanBodyMass", in: weightStart...now, calendar: calendar) : []
      async let fatSeries = currentWeek
        ? MealEnergyMath.healthSeries("BodyFatPercentage", in: weightStart...now, calendar: calendar) : []
      async let hourlySeries = currentWeek
        ? MealEnergyMath.healthSeries("ActiveEnergyBurned", in: recentEnergyStart...today,
          calendar: calendar, bucket: .hour) : []
      (basal, active, recent, lean, fat, hourlyActivity) = await
        (basalSeries, activeSeries, weightSeries, leanSeries, fatSeries, hourlySeries)
    } else {
      (basal, active, recent, lean, fat) = await backendSeries(calendar: calendar)
    }
    #else
    (basal, active, recent, lean, fat) = await backendSeries(calendar: calendar)
    #endif
    guard !Task.isCancelled, start == week else { return }
    let compositionEnd = calendar.dateInterval(of: .day, for: now)?.end ?? now
    let restingEstimate = currentWeek ? MealEnergyMath.restingFromBodyComposition(
      leanMass: dailyValues(lean, from: weightStart, until: compositionEnd),
      weight: dailyValues(recent, from: weightStart, until: compositionEnd),
      bodyFat: dailyValues(fat, from: weightStart, until: compositionEnd)) : nil
    snapshot = DailyData(
      basal: dailyValues(basal, from: energyStart, until: weekEnd),
      active: dailyValues(active, from: energyStart, until: weekEnd),
      hourlyActivity: hourlyActivity,
      weights: recent.filter { $0.date >= weightStart && $0.date <= now && $0.value.isFinite && $0.value > 0 }
        .sorted { $0.date < $1.date },
      estimatedResting: restingEstimate
    )
    loadedWeek = start
  }

  private func dailyValues(_ points: [TrendPoint], from start: Date, until end: Date) -> [Date: Double] {
    points.reduce(into: [:]) { values, point in
      guard point.date >= start, point.date < end, point.date <= Date(),
        point.value.isFinite, point.value >= 0 else { return }
      values[calendar.startOfDay(for: point.date)] = point.value
    }
  }

  private func backendSeries(calendar: Calendar) async
    -> ([TrendPoint], [TrendPoint], [TrendPoint], [TrendPoint], [TrendPoint]) {
    let timezone = calendar.timeZone.identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Asia/Shanghai"
    let trends = (try? await store.healthTrends(bucket: "day", timezone: timezone, calendar: calendar)) ?? [:]
    // Synced body fat is stored as percent, while the composition calculation uses a fraction.
    let bodyFat = (trends["body_fat_percentage"] ?? []).map {
      TrendPoint(epoch: $0.epoch, value: $0.value / 100)
    }
    return (trends["resting_energy"] ?? [], trends["active_energy"] ?? [], trends["body_mass"] ?? [],
      trends["lean_body_mass"] ?? [], bodyFat)
  }
}

enum MealEnergyPalette {
  static let basal = HealthTheme.accent
  static let active = Color.blue
  static let deficit = HealthTheme.accent
  static let surplus = Color.orange
  static let target = Color.indigo
  private static let meals: [Color] = [.orange, .purple, .pink, .indigo, .brown]
  private static let weekdays: [Color] = [.blue, .orange, .teal, .purple, .pink, .indigo, .brown]

  static func meal(_ index: Int) -> Color { meals[index % meals.count] }
  static func weekday(_ index: Int) -> Color { weekdays[index] }
}

private struct MealBalanceChart: View {
  struct Bar: Identifiable {
    let title: String
    let value: Double
    let color: Color
    var id: String { title }
  }

  let bars: [Bar]

  var body: some View {
    let lower = min(0, bars.map(\.value).min() ?? 0)
    let upper = max(1, bars.map(\.value).max() ?? 0)
    let range = upper - lower
    VStack(spacing: 13) {
      ForEach(bars) { bar in
        VStack(spacing: 5) {
          LabeledContent {
            Text(MealEnergyMath.kcal(abs(bar.value)))
              .fontWeight(.semibold)
              .monospacedDigit()
              .foregroundStyle(.primary)
          } label: {
            Text(bar.title)
          }
          .font(.subheadline)
          GeometryReader { geometry in
            let scale = geometry.size.width / range
            let zero = -lower * scale
            ZStack(alignment: .leading) {
              Capsule().fill(HealthTheme.subtle)
              if bar.value != 0 {
                Capsule().fill(bar.color)
                  .frame(width: abs(bar.value) * scale)
                  .offset(x: min(zero, (bar.value - lower) * scale))
              }
              if lower < 0 {
                Rectangle().fill(.primary.opacity(0.35)).frame(width: 1).offset(x: zero)
              }
            }
          }
          .frame(height: 8)
          .accessibilityHidden(true)
        }
      }
    }
  }
}

private struct MealEnergyRings: View {
  let meals: [MealEntry]
  let expenditure: MealEnergyMath.DailyExpenditure
  let showingForecast: Bool
  let confirmedEmpty: Bool
  let currentWeek: Bool
  let budget: MealEnergyMath.WeeklyIntakeBudget
  let weeklyIntake: [Double]

  @Environment(\.dynamicTypeSize) private var dynamicType
  private static let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

  var body: some View {
    let logged = meals.compactMap(\.calories).filter { $0 >= 0 }
    let intake = logged.reduce(0.0) { $0 + Double($1) }
    let knownIntake = !logged.isEmpty || (meals.isEmpty && confirmedEmpty)
    let scale = expenditure.total.flatMap { $0 > 0 ? $0 : nil }
    let ringsLayout = dynamicType.isAccessibilitySize
      ? AnyLayout(VStackLayout(spacing: 18)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    let legendLayout = dynamicType.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 8))

    VStack(spacing: 16) {
      ringsLayout {
        VStack(spacing: 9) {
          Text("当日热量").font(.headline)
          ZStack {
            let intakeSlices = meals.enumerated().map {
              (Double(max(0, $0.element.calories ?? 0)), MealEnergyPalette.meal($0.offset))
            }
            ring(scale == nil ? [] : intakeSlices, scale: scale ?? 1, lineWidth: 10)
            ring(scale == nil ? [] : [(expenditure.basal ?? 0, MealEnergyPalette.basal),
              (expenditure.active ?? 0, MealEnergyPalette.active)], scale: scale ?? 1, lineWidth: 8)
              .padding(14)
            ringValue(knownIntake ? intake : nil, label: "已摄入")
          }
          .aspectRatio(1, contentMode: .fit)
          .frame(maxWidth: 132)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)

        weeklyRing
      }

      let loggedDays = weeklyIntake.indices.filter { weeklyIntake[$0] > 0 }
      if !loggedDays.isEmpty {
        let columns = Array(repeating: GridItem(.flexible()), count: dynamicType.isAccessibilitySize ? 1 : 2)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
          ForEach(loggedDays, id: \.self) { weekday in
            weekdayLegend(weekday, intake: weeklyIntake[weekday])
          }
        }
      }

      Divider()
      legendLayout {
        energyLegend(showingForecast ? "预估静息" : "静息能量", kcal: expenditure.basal, color: MealEnergyPalette.basal)
        energyLegend(showingForecast ? "预估活动" : "活动热量", kcal: expenditure.active, color: MealEnergyPalette.active)
        energyLegend(showingForecast ? "全天预估消耗" : "总消耗", kcal: expenditure.total, color: nil)
      }
    }
    .padding(.vertical, 14)
  }

  private var weeklyRing: some View {
    let intake = weeklyIntake.reduce(0, +)
    let total = budget.total
    let balance = total.map { $0 - intake }
    let slices = weeklyIntake.enumerated().map { ($0.element, MealEnergyPalette.weekday($0.offset)) }

    return VStack(spacing: 9) {
      Text(currentWeek ? "本周剩余摄入" : "当周预算结余").font(.headline)
      ZStack {
        ring(total == nil ? [] : slices, scale: total ?? 1, lineWidth: 10)
        ringValue(balance.map { max(0, $0) }, label: "热量缺口")
      }
      .aspectRatio(1, contentMode: .fit)
      .frame(maxWidth: 132)
      Group {
        switch budget {
        case .awaitingWeight:
          Text("等待当前体重")
        case .awaitingExpenditure:
          Text("消耗数据不足")
        case .paceTooHigh:
          Text("减重速度过高，请调整目标")
        case .available:
          if let balance, balance < 0 {
            Text("超出计划 \(MealEnergyMath.kcal(-balance))")
          }
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }

  private func ringValue(_ value: Double?, label: String) -> some View {
    VStack(spacing: 3) {
      Text(value?.formatted(.number.precision(.fractionLength(0))) ?? "—")
        .font(.title2.weight(.bold).monospacedDigit())
        .minimumScaleFactor(0.55)
        .lineLimit(1)
      Text(label).font(.caption)
        .minimumScaleFactor(0.7)
        .lineLimit(1)
    }
    .padding(.horizontal, 24)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityValue(value.map(MealEnergyMath.kcal) ?? "暂无数据")
  }

  private func energyLegend(_ title: String, kcal: Double?, color: Color?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 5) {
        if let color {
          Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
        }
        Text(title).font(.subheadline)
      }
      Text(kcal.map(MealEnergyMath.kcal) ?? "—")
        .font(.subheadline.weight(.semibold).monospacedDigit())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private func weekdayLegend(_ weekday: Int, intake: Double) -> some View {
    HStack(spacing: 5) {
      Circle().fill(MealEnergyPalette.weekday(weekday)).frame(width: 8, height: 8)
        .accessibilityHidden(true)
      Text(Self.weekdays[weekday])
      Text(MealEnergyMath.kcal(intake)).monospacedDigit()
    }
    .font(.caption)
    .accessibilityElement(children: .combine)
  }

  private func ring(_ values: [(Double, Color)], scale: Double, lineWidth: CGFloat) -> some View {
    let ends = values.reduce(into: [0.0]) { result, item in
      result.append(min(1, (result.last ?? 0) + item.0 / scale))
    }
    return ZStack {
      Circle().strokeBorder(HealthTheme.subtle, lineWidth: lineWidth)
      ForEach(values.indices, id: \.self) { index in
        if ends[index + 1] > ends[index] {
          Circle().inset(by: lineWidth / 2).trim(from: ends[index], to: ends[index + 1])
            .stroke(values[index].1, lineWidth: lineWidth)
            .rotationEffect(.degrees(-90))
        }
      }
    }
    .accessibilityHidden(true)
  }
}

struct MealGoalSettings: View {
  static let weightKey = "wbMealGoalWeightKG"
  static let lossKey = "wbMealGoalLossJinPerWeek"
  static let currentWeightKey = "wbMealCurrentWeightKG"

  @AppStorage(MealGoalSettings.weightKey) private var goalWeight = 0.0
  @AppStorage(MealGoalSettings.lossKey) private var weeklyLoss = 0.0
  @AppStorage(MealGoalSettings.currentWeightKey) private var manualWeight = 0.0
  @Environment(\.dismiss) private var dismiss
  @State private var current = ""
  @State private var goal = ""
  @State private var loss = ""

  private func number(_ text: String) -> Double? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return 0 }
    guard let number = try? Double(value, format: .number), number.isFinite, number > 0,
      number < 1_000 else { return nil }
    return number
  }

  var body: some View {
    Form {
      Section {
        LabeledContent("当前体重（公斤）") {
          TextField("使用健康数据", text: $current).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        }
        LabeledContent("目标体重（公斤）") {
          TextField("不设目标", text: $goal).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        }
        LabeledContent("每周目标减重（斤）") {
          TextField("不设目标", text: $loss).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        }
      }
      if goalWeight > 0 || weeklyLoss > 0 || manualWeight > 0 {
        Section {
          Button("清除所有目标", role: .destructive) {
            goalWeight = 0
            weeklyLoss = 0
            manualWeight = 0
            dismiss()
          }
        }
      }
    }
    .navigationTitle("体重与热量目标")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("保存") {
          guard let weight = number(goal), let weekly = number(loss), let currentWeight = number(current)
          else { return }
          goalWeight = weight
          weeklyLoss = weekly
          manualWeight = currentWeight
          dismiss()
        }
        .disabled(number(goal) == nil || number(loss) == nil || number(current) == nil)
      }
    }
    .onAppear {
      current = manualWeight > 0 ? manualWeight.formatted(.number.grouping(.never)) : ""
      goal = goalWeight > 0 ? goalWeight.formatted(.number.grouping(.never)) : ""
      loss = weeklyLoss > 0 ? weeklyLoss.formatted(.number.grouping(.never)) : ""
    }
  }
}
