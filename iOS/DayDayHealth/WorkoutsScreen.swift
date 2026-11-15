import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

struct WorkoutsScreen: View {
  @ObservedObject var store: HealthStore
  let reauthenticate: () -> Void

  @State private var showMeals = false

  var body: some View {
    VStack(spacing: 0) {
      Picker("记录类型", selection: $showMeals) {
        Text("训练").tag(false)
        Text("饮食").tag(true)
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, HealthTheme.spacing)
      .padding(.vertical, 8)
      if showMeals { MealLog(store: store) }
      else { workouts }
    }
    .background(HealthTheme.background)
    .navigationTitle("训练与饮食")
  }

  private var workouts: some View {
    let legacy = store.workouts.filter { record in
      guard let id = record.external_id else { return true }
      return !store.syncedWorkouts.contains {
        $0.source == record.source && $0.source_id == id
      }
    }
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        SectionTitle("训练历史")
        if store.workoutAuthRequired {
          Button("前往设置重新认证", action: reauthenticate)
        }
        if !store.configured && !store.trainingConfigured {
          Text("请先在设置中配置后端。")
        } else if legacy.isEmpty && store.syncedWorkouts.isEmpty && !store.syncingTraining {
          Text("暂无可显示的训练记录。").foregroundStyle(.secondary)
        }

        ForEach(store.syncedWorkouts) { workout in
          row(WorkoutDisplay(workout))
        }
        if !legacy.isEmpty {
          SectionTitle("其他来源", caption: "不同来源的记录可能重复")
          ForEach(legacy) { workout in row(WorkoutDisplay(workout)) }
        }
        if store.canLoadMoreWorkouts && !store.workoutAuthRequired {
          Button(store.isLoadingMoreWorkouts ? "正在加载…" : "加载更多其他来源记录") {
            Task { await store.loadMoreWorkouts() }
          }
          .buttonStyle(QuietActionStyle())
          .disabled(store.isLoadingMoreWorkouts)
        }
      }
      .padding(HealthTheme.spacing)
      .frame(maxWidth: 740)
      .frame(maxWidth: .infinity)
    }
    .background(HealthTheme.background)
    .task { await store.synchronizeTraining() }
    .refreshable {
      await store.synchronizeTraining()
      if !store.workoutAuthRequired { await store.refresh() }
    }
  }

  private func row(_ workout: WorkoutDisplay) -> some View {
    NavigationLink {
      WorkoutDetail(workout: workout)
    } label: {
      HealthCard {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(workout.displayTitle).font(.headline)
            Spacer()
            Text(workout.durationLabel).monospacedDigit()
            Image(systemName: "chevron.right").font(.caption)
          }
          Text(workout.dateLabel).foregroundStyle(.secondary)
          Text(workout.source).font(.caption).foregroundStyle(.secondary)
          Text(workout.exerciseNames.isEmpty
            ? "暂无动作明细" : workout.exerciseNames.joined(separator: "、"))
            .lineLimit(2)
          if !workout.sets.isEmpty {
            Text("\(workout.exerciseNames.count) 个动作 · \(workout.groupCount) 组")
          }
          Text("训练容量  " + workout.volumeLabel)
            .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .buttonStyle(.plain)
  }
}

private enum WorkoutExerciseNames {
  private struct Catalog: Decodable {
    let names: [String: String]
  }

  private static let names: [String: String] = {
    guard let url = Bundle.main.url(forResource: "WorkoutExerciseNames", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [:] }
    return catalog.names
  }()

  static func chineseName(for original: String) -> String {
    let key = original.precomposedStringWithCompatibilityMapping.lowercased()
      .replacingOccurrences(of: "‐", with: "-")
      .replacingOccurrences(of: "–", with: "-")
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return names[key] ?? original
  }
}

private struct WorkoutDisplay {
  struct Exercise: Identifiable {
    let id: Int
    let name: String
    let sets: [ExerciseSetItem]
  }

  let displayTitle: String
  let source: String
  let startDate: Date?
  let endDate: Date?
  let recordedDate: String?
  let exercises: [Exercise]
  private static let timestamp = Date.FormatStyle.dateTime.year().month().day()
    .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "zh_CN"))

  init(_ workout: WorkoutItem) {
    switch workout.kind {
    case "strength": displayTitle = "力量训练"
    case "running": displayTitle = "跑步"
    default: displayTitle = "运动记录"
    }
    source = Self.sourceLabel(workout.source)
    recordedDate = nil
    startDate = workout.startDate
    endDate = Date(timeIntervalSince1970: workout.ended_epoch)
    var seen = Set<String>()
    let names = workout.sets.map(\.exercise).filter { seen.insert($0).inserted }
    exercises = names.enumerated().map { index, name in
      Exercise(id: index, name: WorkoutExerciseNames.chineseName(for: name),
               sets: workout.sets.filter { $0.exercise == name })
    }
  }

  init(_ workout: SyncedWorkout) {
    displayTitle = workout.name
    source = Self.sourceLabel(workout.source)
    recordedDate = workout.date
    startDate = workout.started_at
    endDate = workout.ended_at
    exercises = workout.exercises.enumerated().map { index, exercise in
      Exercise(id: index, name: WorkoutExerciseNames.chineseName(for: exercise.name),
               sets: exercise.sets.map { set in
        ExerciseSetItem(exercise: exercise.name, set_index: set.index,
                        repetitions: set.reps, weight_kg: set.weight_kg, rpe: set.rpe,
                        seconds: set.seconds, rir: set.rir, warmup: set.warmup, side: set.side)
      })
    }
  }

  var dateLabel: String {
    if let startDate { return startDate.formatted(Self.timestamp) }
    guard let recordedDate else { return "日期未记录" }
    let parts = recordedDate.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return recordedDate }
    return "\(parts[0])年\(parts[1])月\(parts[2])日"
  }

  var endDateLabel: String { endDate?.formatted(Self.timestamp) ?? "未记录" }

  private static func sourceLabel(_ source: String) -> String {
    switch source.lowercased() {
    case "apple_health_workout", "healthkit": return "Apple 健康"
    case "opengym": return "openGym"
    default: return source
    }
  }

  var durationLabel: String {
    guard let startDate, let endDate, endDate >= startDate else { return "时长未记录" }
    return "\(Int(endDate.timeIntervalSince(startDate) / 60)) 分钟"
  }

  var groupCount: Int {
    exercises.reduce(0) { $0 + Set($1.sets.map(\.set_index)).count }
  }
  var sets: [ExerciseSetItem] { exercises.flatMap(\.sets) }

  var exerciseNames: [String] {
    exercises.map(\.name)
  }

  var volumeLabel: String {
    let loads = sets.compactMap { item -> Double? in
      guard let weight = item.weight_kg, let reps = item.repetitions else { return nil }
      return weight * reps
    }
    guard !loads.isEmpty else { return "暂无数据" }
    let total = loads.reduce(0, +).formatted(.number.precision(.fractionLength(0...2)))
    return "\(total) 公斤" + (loads.count == sets.count ? "" : "（已知组）")
  }
}

private struct WorkoutDetail: View {
  let workout: WorkoutDisplay

  var body: some View {
    List {
      Section("训练概览") {
        LabeledContent("类型", value: workout.displayTitle)
        LabeledContent("日期 / 开始", value: workout.dateLabel)
        LabeledContent("结束", value: workout.endDateLabel)
        LabeledContent("时长", value: workout.durationLabel)
        LabeledContent("组数", value: workout.groupCount.formatted())
        LabeledContent("训练容量", value: workout.volumeLabel)
        LabeledContent("来源", value: workout.source)
      }
      if workout.sets.isEmpty {
        Section("动作明细") {
          Text("这条记录没有提供动作、重量和次数。")
            .foregroundStyle(.secondary)
        }
      } else {
        ForEach(workout.exercises) { exercise in
          Section(exercise.name) {
            let sets = exercise.sets
            ForEach(Array(sets.enumerated()), id: \.offset) { row in
              let set = row.element
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text("第 \(set.set_index) 组")
                  if set.side == "left" { Text("左侧") }
                  if set.side == "right" { Text("右侧") }
                  Spacer()
                  if let warmup = set.warmup { Text(warmup ? "热身组" : "正式组") }
                }
                let details = [
                  set.weight_kg.map { "\($0.formatted()) 公斤" },
                  set.repetitions.map { "\($0.formatted()) 次" },
                  set.seconds.map { "\($0.formatted()) 秒" },
                  set.rpe.map { "主观强度 \($0.formatted())" },
                  set.rir.map { "余力 \($0.formatted()) 次" }
                ].compactMap { $0 }
                if !details.isEmpty {
                  Text(details.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                }
              }
              .font(.subheadline.monospacedDigit())
            }
          }
        }
      }
    }
    .listStyle(.plain)
    .navigationTitle("训练详情")
    .navigationBarTitleDisplayMode(.inline)
  }
}

enum MealOccasion: String, Codable {
  case breakfast, lunch, dinner, snack

  var title: String {
    switch self {
    case .breakfast: return "早餐"
    case .lunch: return "午餐"
    case .dinner: return "晚餐"
    case .snack: return "加餐"
    }
  }


}

struct MealEntry: Identifiable, Codable {
  static let storageKey = "wbMealLog"

  var id = UUID()
  let date: Date
  let food: String
  let calories: Int?
  var occasion: MealOccasion? = nil
  var items: [MealFoodEstimate]? = nil
  var healthReceipt: [HealthMetricUpload]? = nil
  var remoteUploaded: Bool? = nil
  var healthRecordID: UUID? = nil
  var retiredHealthRecords: [RetiredMealHealthRecord]? = nil
  var isDeleted: Bool? = nil

  var currentHealthRecordID: UUID { healthRecordID ?? id }
  var reusableItems: [MealFoodEstimate] {
    guard let items, items.allSatisfy(\.isValid) else { return [] }
    return items
  }

  static func decode(_ data: Data) -> [Self] {
    (try? JSONDecoder().decode([Self].self, from: data)) ?? []
  }
}

struct RetiredMealHealthRecord: Codable {
  let id: UUID
  var externalIDs: [String]
  var removedFromHealth = false
  var removedFromRemote: Bool? = nil
}

enum MealPortionUnit: String, CaseIterable, Codable, Sendable {
  case grams, milliliters, servings

  var label: String {
    switch self {
    case .grams: "克"
    case .milliliters: "毫升"
    case .servings: "份"
    }
  }
}

struct MealFoodEstimate: Codable, Equatable, Sendable {
  var name: String
  // Keep the existing storage key. Old records default to grams.
  var grams: Double
  var kcal: Double
  var protein: Double
  var fat: Double
  var carbs: Double
  var reference: String? = nil
  var unit: MealPortionUnit? = nil

  var portionUnit: MealPortionUnit { unit ?? .grams }

  var isValid: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80
      && grams > 0 && grams <= 10_000
      && [kcal, protein, fat, carbs].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 10_000 }
  }


}

private struct MealLog: View {
  @ObservedObject var store: HealthStore
  @Environment(\.dynamicTypeSize) private var dynamicType
  @AppStorage(MealEntry.storageKey) private var storage = Data()
  @State private var editingMeal: MealEntry?
  @State private var selectedDay = Calendar.current.startOfDay(for: Date())
  @State private var pendingDeletion: MealEntry?
  @State private var deleteError: String?

  private var entries: [MealEntry] {
    MealEntry.decode(storage).filter { $0.isDeleted != true }
  }

  var body: some View {
    let meals = entries.filter { Calendar.current.isDate($0.date, inSameDayAs: selectedDay) }
      .sorted { $0.date < $1.date }
    List {
      dayNavigation
      MealEnergyOverview(store: store, selectedDay: selectedDay, entries: entries) {
        Section {
          if meals.isEmpty {
            Text("暂无饮食记录")
              .listRowBackground(HealthTheme.surface)
          }
          ForEach(Array(meals.enumerated()), id: \.element.id) { index, entry in
            mealRow(entry, color: MealEnergyPalette.meal(index))
              .listRowBackground(HealthTheme.surface)
          }
        } header: {
          SectionTitle("饮食记录")
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .sheet(item: $editingMeal) { meal in
      MealEditorSheet(store: store, meal: meal) { entry in
        selectedDay = Calendar.current.startOfDay(for: entry.date)
      }
    }
    .confirmationDialog("删除这餐？", isPresented: Binding(
      get: { pendingDeletion != nil },
      set: { if !$0 { pendingDeletion = nil } }
    ), titleVisibility: .visible, presenting: pendingDeletion) { meal in
      Button("删除", role: .destructive) {
        do {
          try store.deleteMealEntry(meal.id)
          Task { await store.saveMealToHealth(meal.id) }
        } catch { deleteError = error.localizedDescription }
      }
    }
    .alert("删除失败", isPresented: Binding(
      get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }
    )) { Button("好", role: .cancel) {} } message: { Text(deleteError ?? "") }
  }

  private var dayNavigation: some View {
    HStack {
      Button { shiftDay(-1) } label: {
        Image(systemName: "chevron.left").frame(width: 44, height: 44)
      }
      .accessibilityLabel("前一天")
      DatePicker("日期", selection: $selectedDay, in: ...Date(), displayedComponents: .date)
        .environment(\.locale, HealthChartDate.chinese)
        .labelsHidden()
        .frame(maxWidth: .infinity)
      Button { shiftDay(1) } label: {
        Image(systemName: "chevron.right").frame(width: 44, height: 44)
      }
      .accessibilityLabel("后一天")
      .disabled(Calendar.current.isDateInToday(selectedDay))
    }
    .buttonStyle(.borderless)
    .listRowBackground(HealthTheme.background)
    .listRowSeparator(.hidden)
  }

  private func mealRow(_ entry: MealEntry, color: Color) -> some View {
    let layout = dynamicType.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
    return Button {
      editingMeal = entry
    } label: {
      VStack(alignment: .leading, spacing: 7) {
        layout {
          Text(entry.food)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
          if let value = entry.calories {
            Text(MealEnergyMath.kcal(Double(value)))
              .font(.headline.monospacedDigit())
              .layoutPriority(1)
          }
        }
        HStack(spacing: 6) {
          if (entry.calories ?? 0) > 0 {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
          }
          Text(entry.date, format: MealEnergyMath.mealClock)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(HealthTheme.secondaryText)
        }
      }
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .swipeActions(allowsFullSwipe: false) {
      Button("删除", role: .destructive) { pendingDeletion = entry }
      Button("编辑") { editingMeal = entry }.tint(HealthTheme.accent)
    }
    .contextMenu {
      Button("编辑", systemImage: "pencil") { editingMeal = entry }
      Button("删除", systemImage: "trash", role: .destructive) { pendingDeletion = entry }
    }
  }

  private func shiftDay(_ amount: Int) {
    if let day = Calendar.current.date(byAdding: .day, value: amount, to: selectedDay) {
      selectedDay = min(day, Date())
    }
  }

}

struct MealEditorSheet: View {
  @ObservedObject var store: HealthStore
  var meal: MealEntry? = nil
  var onSaved: (MealEntry) -> Void = { _ in }
  @Environment(\.dismiss) private var dismiss
  @AppStorage(MealEntry.storageKey) private var storage = Data()

  var body: some View {
    MealEditor(meal: meal, date: Date(),
      history: MealEntry.decode(storage).filter { $0.isDeleted != true },
      model: store.directModel) { entry in
      let id = try store.saveMealEntry(entry, replacing: meal?.id)
      onSaved(entry)
      dismiss()
      Task { await store.saveMealToHealth(id) }
    }
  }
}

private struct MealEditor: View {
  let meal: MealEntry?
  let history: [MealEntry]
  let model: DirectModelConfiguration?
  let onSave: (MealEntry) throws -> Void
  @Environment(\.dismiss) private var dismiss
  @ScaledMetric(relativeTo: .body) private var weightFieldWidth = 80.0
  @State private var date = Date()
  @State private var occasion: MealOccasion?
  @State private var description = ""
  @State private var calories = ""
  @State private var attachments = ModelPhotoSelection()
  @State private var estimating = false
  @State private var estimatedPortions: [MealPortionDraft] = []
  @State private var addedPortions: [MealPortionDraft] = []
  @State private var showLabelEditor = false
  @State private var showingFoodSearch = false
  @State private var showingHistory = false
  @State private var message: String?

  init(meal: MealEntry?, date: Date, history: [MealEntry], model: DirectModelConfiguration?,
       onSave: @escaping (MealEntry) throws -> Void) {
    self.meal = meal
    self.history = history
    self.model = model
    _date = State(initialValue: meal?.date ?? date)
    _occasion = State(initialValue: meal?.occasion)
    self.onSave = onSave
    if let meal {
      _description = State(initialValue: meal.food)
      _calories = State(initialValue: meal.items == nil ? (meal.calories.map { String($0) } ?? "") : "")
      _estimatedPortions = State(initialValue: (meal.items ?? []).map(MealPortionDraft.init))
    }
  }

  private var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var hasDraft: Bool {
    !trimmedDescription.isEmpty || !calories.isEmpty || !estimatedPortions.isEmpty
      || !addedPortions.isEmpty || !attachments.items.isEmpty
  }
  private var items: [MealFoodEstimate] { (estimatedPortions + addedPortions).map(\.estimate) }
  private var totalCalories: Int? {
    let foods = items
    guard !foods.isEmpty, foods.allSatisfy(\.isValid) else { return nil }
    return Int(exactly: foods.reduce(0) { $0 + $1.kcal }.rounded())
  }

  private var valid: Bool {
    if !items.isEmpty { return totalCalories != nil }
    return !trimmedDescription.isEmpty && (calories.isEmpty || (Int(calories) ?? -1) >= 0)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          DatePicker("用餐时间", selection: $date, in: ...Date())
            .environment(\.locale, HealthChartDate.chinese)
          TextField("吃了什么、吃了多少", text: $description, axis: .vertical)
            .lineLimit(2...4)
          PhotosPicker(selection: $attachments.items, maxSelectionCount: ModelPhotoSelection.limit,
                       selectionBehavior: .ordered, matching: .images) {
            Label("选择餐食照片", systemImage: "photo.on.rectangle")
          }
          if attachments.loading { ProgressView("正在读取照片…") }
          if let error = attachments.error { Text(error).foregroundStyle(.red) }
          ModelPhotoStrip(photos: attachments.readyPhotos, onRemove: { attachments.remove(at: $0) })
          Button(estimating ? "正在估算…" : "AI 估算",
                 systemImage: "sparkles") {
            Task { await estimate() }
          }
          .disabled(estimating || !attachments.ready
            || (attachments.readyPhotos.isEmpty && trimmedDescription.isEmpty))
        }
        .disabled(estimating)
        Button("搜索并添加食物", systemImage: "magnifyingglass") {
          showingFoodSearch = true
        }.disabled(estimating)
        Button("从历史调取", systemImage: "clock.arrow.circlepath") {
          showingHistory = true
        }.disabled(estimating)
        Button("添加包装食品营养表", systemImage: "doc.text.viewfinder") {
          showLabelEditor = true
        }.disabled(estimating)

        if items.isEmpty {
          TextField("手动热量（千卡，选填）", text: $calories).keyboardType(.numberPad)
        } else {
          Section {
            LabeledContent("总热量", value: totalCalories.map { "\($0.formatted()) 大卡" } ?? "—")
              .font(.headline)
            portionRows($estimatedPortions)
            portionRows($addedPortions)
          }
        }
        if let message { Text(message).foregroundStyle(.red) }
      }
      .navigationTitle(meal == nil ? "记录一餐" : "编辑饮食")
      .onChange(of: description) { _, _ in
        if meal == nil { estimatedPortions = [] }
      }
      .sheet(isPresented: $showingFoodSearch) {
        MealFoodSearch(history: history, onSelect: { portion in
          addedPortions.append(MealPortionDraft(portion))
        }, onReuseMeal: hasDraft ? nil : reuseMeal)
      }
      .sheet(isPresented: $showingHistory) {
        MealHistoryPicker(history: history, replacesDraft: hasDraft, onUse: reuseMeal)
      }
      .sheet(isPresented: $showLabelEditor) {
        PackagedNutritionEditor(model: model) { portion in
          estimatedPortions.removeAll { $0.name == portion.name }
          addedPortions.append(MealPortionDraft(portion))
        }
      }
      .task(id: attachments.items) {
        guard attachments.loading else { return }
        let items = attachments.items
        let result = await ModelPhotoSelection.load(items)
        guard !Task.isCancelled, items == attachments.items else { return }
        attachments.finish(result, for: items)
      }
      .onChange(of: attachments.items) { _, _ in
        if meal == nil { estimatedPortions = [] }
        message = nil
      }
      .interactiveDismissDisabled(estimating)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }.disabled(estimating)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(meal != nil ? "保存" : (items.isEmpty ? "保存到本机" : "确认并保存"),
                 action: save).disabled(!valid || estimating || attachments.loading)
        }
      }
    }
  }

  private func portionRows(_ portions: Binding<[MealPortionDraft]>) -> some View {
    ForEach(portions.wrappedValue.indices, id: \.self) { index in
      let food = portions.wrappedValue[index].estimate
      VStack(alignment: .leading, spacing: 7) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          if meal != nil {
            TextField("菜名", text: portions[index].name).font(.headline)
          } else {
            Text(food.name).font(.headline)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 6)
          TextField("", text: portions[index].weightInput)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(width: weightFieldWidth)
          .accessibilityLabel("\(food.name)份量（\(food.portionUnit.label)）")
          Text(food.portionUnit.label)
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityHidden(true)
        }
        if food.isValid {
          Text("\(food.kcal.formatted(.number.precision(.fractionLength(0)))) 千卡 · 蛋白质 \(grams(food.protein)) g · 脂肪 \(grams(food.fat)) g · 碳水 \(grams(food.carbs)) g")
            .font(.footnote)
        }
      }
    }
    .onDelete { portions.wrappedValue.remove(atOffsets: $0) }
  }

  private func grams(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...1)))
  }

  private func reuseMeal(_ previous: MealEntry) {
    let portions = previous.reusableItems
    description = previous.food
    calories = portions.isEmpty ? previous.calories.map(String.init) ?? "" : ""
    occasion = previous.occasion
    estimatedPortions = []
    addedPortions = portions.map(MealPortionDraft.init)
    attachments = ModelPhotoSelection()
    message = nil
  }

  private func save() {
    do {
      if items.isEmpty {
        try onSave(MealEntry(date: date, food: trimmedDescription, calories: Int(calories), occasion: occasion))
      } else if let total = totalCalories {
        let name = items.map(\.name).joined(separator: "、")
        try onSave(MealEntry(date: date, food: name, calories: total, occasion: occasion, items: items))
      }
    } catch { message = error.localizedDescription }
  }

  private var descriptionForAI: String {
    let names = addedPortions.map(\.name)
    guard !names.isEmpty else { return trimmedDescription }
    return trimmedDescription + "\n以下食品已手动加入这餐，请不要重复估算："
      + names.joined(separator: "、")
  }

  private func estimate() async {
    guard !estimating, attachments.ready else { return }
    guard let model else { message = "请先在设置里配置 AI 模型。"; return }
    estimating = true
    defer { estimating = false }
    message = nil
    if meal == nil { estimatedPortions = [] }
    do {
      let estimate = try await MealFoodEstimate.estimate(description: descriptionForAI, photos: attachments.readyPhotos, model: model)
      estimatedPortions = estimate.map(MealPortionDraft.init)
    } catch {
      message = error.localizedDescription
    }
  }

}

struct ModelPhotoSelection {
  static let limit = 6

  var items: [PhotosPickerItem] = []
  private var loadedItems: [PhotosPickerItem] = []
  private var photos: [Data] = []
  private var failure: String?

  var ready: Bool { items.isEmpty || (items == loadedItems && failure == nil) }
  var loading: Bool { !items.isEmpty && items != loadedItems }
  var error: String? { items == loadedItems ? failure : nil }
  var readyPhotos: [Data] { items.isEmpty || !ready ? [] : photos }

  mutating func finish(_ result: Result<[Data], Error>, for selection: [PhotosPickerItem]) {
    loadedItems = selection
    switch result {
    case .success(let photos):
      self.photos = photos
      failure = nil
    case .failure(let error):
      photos = []
      failure = error.localizedDescription
    }
  }

  mutating func remove(at index: Int) {
    guard ready, items.indices.contains(index), photos.indices.contains(index) else { return }
    items.remove(at: index)
    photos.remove(at: index)
    loadedItems = items
  }

  static func load(_ items: [PhotosPickerItem], maxPixelSize: Int = 1200) async -> Result<[Data], Error> {
    do {
      var photos: [Data] = []
      for (index, item) in items.enumerated() {
        try Task.checkCancellation()
        guard let data = try? await item.loadTransferable(type: Data.self),
          let photo = await Task.detached(priority: .userInitiated, operation: {
            mealJPEG(data, maxPixelSize: maxPixelSize, quality: 0.72)
          }).value else {
          throw APIClient.APIError.message("无法读取第\(index + 1)张照片，请重新选择。")
        }
        photos.append(photo)
      }
      return .success(photos)
    } catch {
      return .failure(error)
    }
  }
}

struct ModelPhotoStrip: View {
  let photos: [Data]
  var onRemove: ((Int) -> Void)? = nil

  var body: some View {
    if !photos.isEmpty {
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(photos.indices, id: \.self) { index in
            if let thumbnail = UIImage(data: photos[index]) {
              Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 76, height: 76)
                .clipped()
                .accessibilityLabel("照片 \(index + 1)")
                .overlay(alignment: .topTrailing) {
                  if let onRemove {
                    Button { onRemove(index) } label: {
                      Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.8))
                        .frame(width: 44, height: 44, alignment: .topTrailing)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除照片 \(index + 1)")
                  }
                }
            }
          }
        }
      }
      .scrollIndicators(.hidden)
    }
  }
}

func mealJPEG(_ data: Data, maxPixelSize: Int = 1440, quality: Double = 0.75) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
      ] as CFDictionary) else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? output as Data : nil
}
