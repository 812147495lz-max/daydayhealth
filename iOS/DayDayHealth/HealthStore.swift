import Foundation
import OSLog
import SwiftUI

/// A single UI-facing state owner. The backend retains the source of truth.
@MainActor
final class HealthStore: ObservableObject {
  @AppStorage("wbServerURL") private var server = ""

  @Published private(set) var directModel = KeychainStore.loadDirectModel()
  private let mealSyncLog = Logger(subsystem: "DayDayHealth", category: "MealSync")
  private var syncingMealIDs = Set<UUID>()

  private var mealNASClient: APIClient? {
    KeychainStore.loadMealNAS().map { APIClient(server: $0.address, apiKey: $0.key) } ?? (try? client())
  }

  private var mealEntries: [MealEntry] {
    MealEntry.decode(UserDefaults.standard.data(forKey: MealEntry.storageKey) ?? Data())
  }

  private func pendingMeals(includeNAS: Bool) -> [MealEntry] {
    mealEntries.filter { meal in
      let retired = meal.retiredHealthRecords ?? []
      if retired.contains(where: { !$0.removedFromHealth || (includeNAS && $0.removedFromRemote != true) }) {
        return true
      }
      return meal.isDeleted != true && (
        (meal.items != nil && meal.healthReceipt == nil)
          || (includeNAS && meal.remoteUploaded != true && !HealthMetricsSync.remoteMealSamples(meal).isEmpty)
      )
    }
  }

  var hasPendingMealUploads: Bool {
    !pendingMeals(includeNAS: mealNASClient != nil).isEmpty
  }

  func saveMealEntry(_ draft: MealEntry, replacing id: UUID?) throws -> UUID {
    var current = mealEntries
    var meal = draft
    var affectedDates = [draft.date]
    if let id {
      let index = try editableMealIndex(id, in: current)
      let previous = current[index]
      if previous.date == draft.date, previous.food == draft.food,
         previous.calories == draft.calories, previous.items == draft.items, previous.occasion == draft.occasion { return id }
      affectedDates.append(previous.date)
      meal.id = id
      meal.healthRecordID = UUID()
      meal.retiredHealthRecords = retiredRecords(after: previous)
      current[index] = meal
    } else {
      current.append(meal)
    }
    try writeMeals(current)
    clearMealCompletion(for: affectedDates)
    return meal.id
  }

  func deleteMealEntry(_ id: UUID) throws {
    var current = mealEntries
    let index = try editableMealIndex(id, in: current)
    var meal = current[index]
    let retired = retiredRecords(after: meal)
    if retired.isEmpty {
      current.remove(at: index)
    } else {
      meal.isDeleted = true
      meal.retiredHealthRecords = retired
      meal.items = nil
      meal.healthReceipt = nil
      current[index] = meal
    }
    try writeMeals(current)
    clearMealCompletion(for: [meal.date])
  }

  private func clearMealCompletion(for dates: [Date]) {
    let key = MealEnergyMath.completionKey
    let defaults = UserDefaults.standard
    let confirmed = MealEnergyMath.confirmedDays(in: defaults.data(forKey: key) ?? Data())
    let updated = confirmed.subtracting(dates.map(MealEnergyMath.dayKey))
    if updated != confirmed, let data = try? JSONEncoder().encode(updated) {
      defaults.set(data, forKey: key)
    }
  }

  private func editableMealIndex(_ id: UUID, in meals: [MealEntry]) throws -> Int {
    guard !syncingMealIDs.contains(id) else {
      throw APIClient.APIError.message("这餐正在处理，请稍后再试。")
    }
    guard let index = meals.firstIndex(where: { $0.id == id && $0.isDeleted != true }) else {
      throw APIClient.APIError.message("找不到这条饮食记录。")
    }
    return index
  }

  private func retiredRecords(after meal: MealEntry) -> [RetiredMealHealthRecord] {
    var retired = meal.retiredHealthRecords ?? []
    if meal.items != nil || !HealthMetricsSync.remoteMealSamples(meal).isEmpty {
      retired.append(RetiredMealHealthRecord(id: meal.currentHealthRecordID,
        externalIDs: meal.healthReceipt?.map(\.external_id) ?? [],
        removedFromHealth: meal.items == nil))
    }
    return retired
  }

  private func writeMeals(_ meals: [MealEntry]) throws {
    UserDefaults.standard.set(try JSONEncoder().encode(meals), forKey: MealEntry.storageKey)
  }

  func saveMealToHealth(_ id: UUID) async {
    let api = forcedPasswordCredentials == nil ? mealNASClient : nil
    await syncMeal(id, uploadClient: api, requestPermission: true)
  }

  func uploadPendingMeals() async {
    guard forcedPasswordCredentials == nil else { return }
    let api = mealNASClient
    for meal in pendingMeals(includeNAS: api != nil) {
      guard !Task.isCancelled else { return }
      await syncMeal(meal.id, uploadClient: api, requestPermission: false)
    }
  }

  private func persistMeal(_ meal: MealEntry) throws {
    var current = mealEntries
    guard let index = current.firstIndex(where: { $0.id == meal.id }) else { throw CancellationError() }
    if meal.isDeleted == true && (meal.retiredHealthRecords ?? []).isEmpty {
      current.remove(at: index)
    } else {
      current[index] = meal
    }
    try writeMeals(current)
  }

  private func syncMeal(_ id: UUID, uploadClient: APIClient?, requestPermission: Bool) async {
    guard var meal = pendingMeals(includeNAS: uploadClient != nil).first(where: { $0.id == id }),
      syncingMealIDs.insert(id).inserted else { return }
    defer { syncingMealIDs.remove(id) }
    let original = meal
    async let remote: Bool = syncRemoteMeal(original, client: uploadClient)
    do {
      var retired = meal.retiredHealthRecords ?? []
      for index in retired.indices where !retired[index].removedFromHealth {
        try Task.checkCancellation()
        let recordID = retired[index].id
        if retired[index].externalIDs.isEmpty {
          retired[index].externalIDs = try await HealthMetricsSync.shared.mealExternalIDs(recordID)
          meal.retiredHealthRecords = retired
          try persistMeal(meal)
        }
        try await HealthMetricsSync.shared.removeMeal(recordID)
        retired[index].removedFromHealth = true
        meal.retiredHealthRecords = retired
        try persistMeal(meal)
      }

      if meal.isDeleted != true, meal.items != nil, meal.healthReceipt == nil {
        meal.healthReceipt = try await HealthMetricsSync.shared.saveMeal(
          meal, requestPermission: requestPermission)
        try persistMeal(meal)
      }
    } catch where !Task.isCancelled {
      let failure = error as NSError
      mealSyncLog.error("Apple Health meal pending: \(failure.domain, privacy: .public) (\(failure.code, privacy: .public))")
    } catch { }

    guard await remote else { return }
    do {
      if !HealthMetricsSync.remoteMealSamples(original).isEmpty { meal.remoteUploaded = true }
      let retired = (meal.retiredHealthRecords ?? []).compactMap { record -> RetiredMealHealthRecord? in
        if record.removedFromHealth { return nil }
        var pending = record
        pending.removedFromRemote = true
        return pending
      }
      meal.retiredHealthRecords = retired.isEmpty ? nil : retired
      try persistMeal(meal)
    } catch {
      let failure = error as NSError
      mealSyncLog.error("Meal upload state pending: \(failure.domain, privacy: .public) (\(failure.code, privacy: .public))")
    }
  }

  private func syncRemoteMeal(_ meal: MealEntry, client: APIClient?) async -> Bool {
    let pending = (meal.retiredHealthRecords ?? []).filter { $0.removedFromRemote != true }
    let samples = meal.remoteUploaded == true ? [] : HealthMetricsSync.remoteMealSamples(meal)
    var removals = Set(pending.flatMap { $0.externalIDs + HealthMetricsSync.remoteMealIDs($0.id) })
    if !samples.isEmpty {
      // A previously synced meal may still use its Apple Health sample UUIDs remotely.
      removals.formUnion((meal.healthReceipt ?? []).map(\.external_id))
    }
    guard !samples.isEmpty || !removals.isEmpty else { return true }
    guard let client else { return false }
    do {
      try Task.checkCancellation()
      try await HealthMetricsSync.shared.uploadMeal(samples, deleting: removals.sorted(), client: client)
      return true
    } catch {
      if !Task.isCancelled {
        let failure = error as NSError
        mealSyncLog.error("Remote meal pending: \(failure.domain, privacy: .public) (\(failure.code, privacy: .public))")
      }
      return false
    }
  }

  func saveDirectModel(_ configuration: DirectModelConfiguration) throws {
    try KeychainStore.saveDirectModel(configuration)
    directModel = configuration
  }

  @Published private(set) var summary: SupervisorSummary?
  @Published private(set) var tasks: [TaskItem] = []
  @Published private(set) var workouts: [WorkoutItem] = []
  @Published private(set) var goals: [GoalItem] = []
  @Published private(set) var summaryAvailable = false
  @Published private(set) var tasksAvailable = false
  @Published private(set) var workoutsAvailable = false
  @Published private(set) var canLoadMoreWorkouts = false
  @Published private(set) var isLoadingMoreWorkouts = false
  @Published private(set) var goalsAvailable = false
  @Published private(set) var isLoading = false
  @Published private(set) var isMutating = false
  @Published private(set) var isLoaded = false
  @Published private(set) var lastUpdated: Date?
  @Published var errorMessage: String?
  @Published var syncMessage: String?
  @Published private(set) var syncingHealth = false
  @Published private(set) var healthSyncMessage: String?
  @Published private(set) var lastHealthSync: Date?
  private var usesLocalHealthTrends = false

  var healthEnabled: Bool {
    UserDefaults.standard.bool(forKey: AppleHealthArchiveSync.setupHealthKey)
      || UserDefaults.standard.bool(forKey: "wbHealthEnabled")
  }

  @Published private(set) var syncedWorkouts: [SyncedWorkout] = []
  @Published private(set) var workoutSyncedAt: Date?
  @Published private(set) var workoutSyncError: String?
  @Published private(set) var workoutAuthRequired = false
  @Published private(set) var syncingTraining = false
  @Published private(set) var backendConnection = HealthStore.loadTrainingBackend()

  private var syncInFlight = Set<String>()
  private var rejectedAccounts = Set<String>()
  private static let backendKey = "wbTrainingBackendConnection"

  private static func loadTrainingBackend() -> BackendConnection? {
    if let data = UserDefaults.standard.data(forKey: backendKey),
       let settings = try? JSONDecoder().decode(BackendConnection.self, from: data) {
      return settings
    }
    guard let credentials = KeychainStore.loadFNOS() else { return nil }
    return BackendConnection(loginServer: credentials.server, dataServer: credentials.server,
      requiresCloudflareAccess: credentials.clientID != nil && credentials.clientSecret != nil)
  }

  func saveTrainingBackend(_ settings: BackendConnection) throws {
    guard settings != backendConnection else { return }
    let data = try JSONEncoder().encode(settings)
    try KeychainStore.clearFNOS()
    UserDefaults.standard.set(data, forKey: Self.backendKey)
    backendConnection = settings
    restoreTrainingConnection()
  }

  @Published private(set) var forcedPasswordCredentials: FNOSWorkoutCredentials? = {
    let credentials = KeychainStore.loadFNOS()
    return credentials?.mustChangePassword == true ? credentials : nil
  }()

  func requireTrainingPasswordChange(_ credentials: FNOSWorkoutCredentials) {
    guard var saved = KeychainStore.loadFNOS(), saved.token == credentials.token,
      saved.server == credentials.server else { return }
    saved.mustChangePassword = true
    forcedPasswordCredentials = saved
    syncingTraining = false
    workoutSyncError = nil
    do {
      try KeychainStore.saveFNOS(saved)
      AppleHealthArchiveSync.shared.connectionChanged()
    } catch {
      FNOSLoginClient.diagnostics.error("Could not persist mandatory password change")
    }
  }

  func completeRequiredPasswordChange(_ credentials: FNOSWorkoutCredentials) throws {
    guard var saved = KeychainStore.loadFNOS(), saved.token == credentials.token,
      saved.server == credentials.server else { throw CancellationError() }
    saved.mustChangePassword = false
    try KeychainStore.saveFNOS(saved)
    restoreTrainingConnection()
  }

  var trainingConfigured: Bool { trainingClient() != nil }

  private func trainingClient() -> APIClient? {
    guard forcedPasswordCredentials == nil else { return nil }
    if let credentials = KeychainStore.loadFNOS() {
      return credentials.mustChangePassword == true ? nil : credentials.client
    }
    #if targetEnvironment(simulator) && DEBUG
    if ProcessInfo.processInfo.environment["WB_WORKOUT_SYNC_MOCK_JSON"] != nil,
      let api = try? client(), api.server == LocalTestConfiguration.address { return api }
    #endif
    return nil
  }

  func restoreTrainingConnection(reauthenticated: Bool = false) {
    AppleHealthArchiveSync.shared.connectionChanged()
    workoutSyncError = nil
    let credentials = KeychainStore.loadFNOS()
    forcedPasswordCredentials = credentials?.mustChangePassword == true ? credentials : nil
    guard let api = trainingClient() else {
      workoutAuthRequired = false
      syncingTraining = false
      restoreTraining(nil)
      return
    }
    let account = api.cacheAccount
    if reauthenticated { rejectedAccounts.remove(account) }
    let service = WorkoutSyncService(account: account) {
      try await api.workoutSyncPage(cursor: $0)
    }
    restoreTraining(service.snapshot)
    workoutAuthRequired = rejectedAccounts.contains(account)
    syncingTraining = syncInFlight.contains(account)
  }

  func signOutTraining() throws {
    if let backendConnection {
      let data = try JSONEncoder().encode(backendConnection)
      UserDefaults.standard.set(data, forKey: Self.backendKey)
    }
    try KeychainStore.clearFNOS()
    restoreTrainingConnection()
  }

  func expireTraining(_ credentials: FNOSWorkoutCredentials) {
    guard let current = KeychainStore.loadFNOS(), current.token == credentials.token,
      current.server == credentials.server else { return }
    do {
      try signOutTraining()
    } catch {
      rejectedAccounts.insert(credentials.client.cacheAccount)
    }
    workoutAuthRequired = true
    workoutSyncError = "登录已失效，请重新登录。"
  }

  func synchronizeTraining() async {
    guard let api = trainingClient() else { return }
    let account = api.cacheAccount
    if rejectedAccounts.contains(account) {
      workoutAuthRequired = true
      workoutSyncError = "登录已失效，请重新认证。"
      return
    }
    guard syncInFlight.insert(account).inserted else { return }
    syncingTraining = true
    workoutSyncError = nil
    let service = WorkoutSyncService(account: account) { cursor in
      guard (self.trainingClient()?.cacheAccount) == account else { throw CancellationError() }
      let page = try await api.workoutSyncPage(cursor: cursor)
      guard (self.trainingClient()?.cacheAccount) == account else { throw CancellationError() }
      return page
    }
    defer {
      syncInFlight.remove(account)
      if (trainingClient()?.cacheAccount) == account {
        syncingTraining = false
        restoreTraining(service.snapshot)
      }
    }
    do {
      try await service.synchronize()
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled, let current = trainingClient(), current.cacheAccount == account,
        current.workoutCredentials?.token == api.workoutCredentials?.token else { return }
      if case APIClient.APIError.passwordChangeRequired = error,
        let credentials = api.workoutCredentials {
        requireTrainingPasswordChange(credentials)
        return
      }
      if case APIClient.APIError.httpStatus(401) = error {
        if let credentials = api.workoutCredentials {
          expireTraining(credentials)
          return
        }
        rejectedAccounts.insert(account)
      }
      workoutAuthRequired = rejectedAccounts.contains(account)
      if case APIClient.APIError.httpStatus(403) = error {
        workoutSyncError = "访问被拒绝，请检查后端的访问权限。"
      } else {
        workoutSyncError = workoutAuthRequired ? "登录已失效，请重新认证。" :
          "训练同步失败，已缓存的记录仍可查看。"
      }
    }
  }

  private func restoreTraining(_ snapshot: WorkoutSyncState?) {
    syncedWorkouts = (snapshot?.workouts.values.map { $0 } ?? []).sorted {
      let left = $0.date ?? ""
      let right = $1.date ?? ""
      if left != right { return left > right }
      let start = $0.started_at ?? .distantPast
      let other = $1.started_at ?? .distantPast
      return start == other ? $0.id < $1.id : start > other
    }
    workoutSyncedAt = snapshot?.completedAt
  }

  private var connectionKey: String? {
    #if (targetEnvironment(macCatalyst) || targetEnvironment(simulator)) && DEBUG
    if server == LocalTestConfiguration.address,
      let key = LocalTestConfiguration.key { return key }
    #endif
    return KeychainStore.load()
  }

  var configured: Bool {
    APIClient.validServer(server) &&
      !(connectionKey ?? "").isEmpty
  }

  func client() throws -> APIClient {
    guard configured, let token = connectionKey else {
      throw NSError(
        domain: "DayDayHealth", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "此设备还没有可用的后端服务"]
      )
    }
    return APIClient(server: server, apiKey: token)
  }

  func refresh() async {
    guard configured else {
      errorMessage = "尚未连接后端。"
      return
    }
    if isLoading { return }
    isLoading = true
    defer { isLoading = false }
    guard let api = try? client() else { return }
    let account = api.cacheAccount

    // Start independent requests together; preserve previous verified data
    // when one endpoint fails. Never translate unavailable into zero.
    async let fetchedSummary: SupervisorSummary = api.send("/v1/supervisor/weekly")
    async let fetchedTasks: [TaskItem] = api.send("/v1/tasks")
    async let fetchedWorkouts: [WorkoutItem] = legacyWorkouts(api)
    async let fetchedGoals: [GoalItem] = api.send("/v1/goals")
    var issues: [String] = []
    var successes = 0
    do {
      let value = try await fetchedSummary
      guard (try? client().cacheAccount) == account else { return }
      summary = value
      summaryAvailable = true
      try? LocalCache.save(value, server: account, resource: "summary")
      successes += 1
    } catch { issues.append("周报：\(error.localizedDescription)") }
    do {
      let value = try await fetchedTasks
      guard (try? client().cacheAccount) == account else { return }
      tasks = value
      tasksAvailable = true
      try? LocalCache.save(value, server: account, resource: "tasks")
      successes += 1
    } catch { issues.append("任务：\(error.localizedDescription)") }
    do {
      let value = try await fetchedWorkouts
      guard (try? client().cacheAccount) == account else { return }
      workouts = value
      canLoadMoreWorkouts = value.count == 50
      workoutsAvailable = true
      try? LocalCache.save(value, server: account, resource: "workouts")
      successes += 1
    } catch { issues.append("训练：\(error.localizedDescription)") }
    do {
      let value = try await fetchedGoals
      guard (try? client().cacheAccount) == account else { return }
      goals = value
      goalsAvailable = true
      try? LocalCache.save(value, server: account, resource: "goals")
      successes += 1
    } catch { issues.append("目标：\(error.localizedDescription)") }
    guard (try? client().cacheAccount) == account else { return }
    isLoaded = true
    if successes > 0 { lastUpdated = Date() }
    errorMessage = issues.isEmpty ? nil :
      "部分数据可能已过期。\n" + issues.joined(separator: "\n")
  }

  func restoreCache() {
    restoreTrainingConnection()
    guard let api = try? client() else { return }
    let account = api.cacheAccount
    if let snapshot = LocalCache.load(
      server: account, resource: "summary", as: SupervisorSummary.self
    ) { summary = snapshot.data; summaryAvailable = true; lastUpdated = snapshot.savedAt }
    if let snapshot = LocalCache.load(
      server: account, resource: "tasks", as: [TaskItem].self
    ) { tasks = snapshot.data; tasksAvailable = true }
    if let snapshot = LocalCache.load(
      server: account, resource: "workouts", as: [WorkoutItem].self
    ) { workouts = snapshot.data; workoutsAvailable = true }
    if let snapshot = LocalCache.load(
      server: account, resource: "goals", as: [GoalItem].self
    ) { goals = snapshot.data; goalsAvailable = true }
    isLoaded = summaryAvailable || tasksAvailable || workoutsAvailable || goalsAvailable
  }

  func resumeSynchronization() async {
    guard forcedPasswordCredentials == nil else { return }
    async let health: Void = syncHealth()
    await NotificationActionQueue.shared.flush()
    if let api = try? client() {
      _ = try? await NotificationSync(client: api).run(requestPermission: false)
    }
    await health
  }

  func resetConnectionData() {
    summary = nil
    tasks = []
    workouts = []
    canLoadMoreWorkouts = false
    goals = []
    summaryAvailable = false
    tasksAvailable = false
    workoutsAvailable = false
    goalsAvailable = false
    isLoaded = false
    lastUpdated = nil
    errorMessage = nil
  }

  func loadMoreWorkouts() async {
    guard canLoadMoreWorkouts, !isLoadingMoreWorkouts,
      let last = workouts.last, let api = try? client() else { return }
    isLoadingMoreWorkouts = true
    defer { isLoadingMoreWorkouts = false }
    do {
      let path = "/v1/workouts?limit=50&before_epoch=\(Int(last.started_epoch))" +
        "&before_id=\(last.id)"
      let newRows: [WorkoutItem] = try await api.send(path)
      let account = api.cacheAccount
      guard (try? client().cacheAccount) == account else { return }
      let existingIDs = Set(workouts.map(\.id))
      workouts += newRows.filter { !existingIDs.contains($0.id) }
      canLoadMoreWorkouts = newRows.count == 50
      try? LocalCache.save(workouts, server: account, resource: "workouts")
    } catch {
      errorMessage = "加载更多训练失败：\(error.localizedDescription)"
    }
  }

  private func legacyWorkouts(_ api: APIClient) async throws -> [WorkoutItem] {
    guard !rejectedAccounts.contains(api.cacheAccount) else {
      throw APIClient.APIError.httpStatus(401)
    }
    return try await api.send("/v1/workouts?limit=50")
  }

  func createTask(title: String, date: Date, requestID: String) async -> Bool {
    let saved = await change {
      let body = CreateTaskInput(
        title: title, due_at: date, request_id: requestID
      )
      let result: TaskItem = try await $0.send(
        "/v1/tasks", method: "POST", body: Self.json(body)
      )
      _ = result
    }
    if saved { await syncNotifications() }
    return saved
  }

  func updateTask(_ task: TaskItem, action: String, date: Date? = nil) async -> Bool {
    let saved = await change {
      let body = TaskActionInput(
        action: action, expected_version: task.version, due_at: date
      )
      let result: TaskItem = try await $0.send(
        "/v1/tasks/\(task.id)/action", method: "POST", body: Self.json(body)
      )
      _ = result
    }
    if saved { await syncNotifications() }
    return saved
  }

  func createGoal(title: String, target: Int, type: String) async -> Bool {
    await change {
      let body = GoalInput(title: title, target_per_week: target,
                           confirmed: true, goal_type: type)
      let result: APIEmptyResult = try await $0.send(
        "/v1/goals", method: "POST", body: Self.json(body)
      )
      _ = result
    }
  }

  func syncNotifications() async {
    guard let api = try? client() else {
      syncMessage = "此设备还没有可用的后端服务。"
      return
    }
    isMutating = true
    defer { isMutating = false }
    do {
      let count = try await NotificationSync(client: api).run()
      syncMessage = "已处理 \(count) 项通知变更。"
    } catch {
      syncMessage = "通知同步失败：\(error.localizedDescription)"
    }
  }

  func syncHealth(manual: Bool = false) async {
    #if !targetEnvironment(macCatalyst)
    guard (manual || UserDefaults.standard.bool(forKey: "wbHealthEnabled")), !syncingHealth, forcedPasswordCredentials == nil else {
      return
    }
    syncingHealth = true
    healthSyncMessage = nil
    defer { syncingHealth = false }
    if manual {
      do { try await HealthMetricsSync.shared.authorize() }
      catch {
        if error.localizedDescription.contains("com.apple.developer.healthkit entitlement") {
          healthSyncMessage = "当前安装缺少 Apple 健康权限，请安装保留 HealthKit 签名的版本。"
        } else {
          healthSyncMessage = "无法访问 Apple 健康：\(error.localizedDescription)"
        }
        return
      }
    }
    guard let api = try? client() else { return }
    // These are independent flows: one failed upload must not prevent the other.
    async let workoutResult = uploadHealthWorkouts(api)
    async let metricsResult = uploadHealthMetrics(api)
    let workout = await workoutResult
    let metrics = await metricsResult
    guard !Task.isCancelled else { return }
    var messages: [String] = []
    switch workout {
    case .success(let count): messages.append("Apple Health 锻炼：处理了 \(count) 条变更。")
    case .failure(let error): messages.append("锻炼上传失败，保留待上传记录：\(error.localizedDescription)")
    }
    switch metrics {
    case .success(let count):
      messages.append("健康指标：处理了 \(count) 条变更（上传至现有旧 AI 后台）。")
      lastHealthSync = Date()
    case .failure(let error):
      messages.append("健康指标上传失败，保留待上传记录：\(error.localizedDescription)")
    }
    healthSyncMessage = messages.joined(separator: "\n")
    // Never perform an unrelated full-history trends scan as an error fallback.
    // Rendering uses HealthTrendRepository independently and is available offline.
    #endif
  }

  private func uploadHealthWorkouts(_ api: APIClient) async -> Result<Int, Error> {
    do { return .success(try await HealthSync.shared.synchronize(client: api)) }
    catch { return .failure(error) }
  }

  private func uploadHealthMetrics(_ api: APIClient) async -> Result<Int, Error> {
    do { return .success(try await HealthMetricsSync.shared.synchronize(client: api)) }
    catch { return .failure(error) }
  }

  func healthTrends(bucket: String, timezone: String,
                    calendar: Calendar, refresh: Bool = false) async throws -> [String: [TrendPoint]] {
    // Never block local charts on an unavailable legacy /v1 health server.
    #if !targetEnvironment(macCatalyst)
    if healthEnabled {
      return try await HealthMetricsSync.shared.localTrends(
        bucket: bucket, calendar: calendar, refresh: refresh
      )
    }
    #endif
    if let api = try? client(),
       let remote: [String: [TrendPoint]] = try? await api
        .send("/v1/health/trends?bucket=\(bucket)&tz=\(timezone)") {
      return remote
    }
    throw NSError(domain: "DayDayHealth", code: 3,
      userInfo: [NSLocalizedDescriptionKey: "请先在设置中授权读取健康数据。"])
  }

  private func change(_ operation: (APIClient) async throws -> Void) async -> Bool {
    guard let api = try? client() else {
      errorMessage = "此设备还没有可用的后端服务。"
      return false
    }
    isMutating = true
    defer { isMutating = false }
    do {
      try await operation(api)
      await refresh()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private static func json<T: Encodable>(_ item: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(item)
  }
}
