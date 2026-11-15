import UserNotifications
import SwiftUI
import BackgroundTasks

@main
struct DayDayHealthApp: App {
  @UIApplicationDelegateAdaptor(AppleHealthArchiveAppDelegate.self) private var archiveDelegate
  @StateObject private var healthArchive = AppleHealthArchiveSync.shared
  @StateObject private var store = HealthStore()
  @StateObject private var backup = AppBackup()
  @StateObject private var digest = DailyDigest.shared
  @Environment(\.scenePhase) private var scenePhase

  private var workoutRefreshID: String {
    (Bundle.main.bundleIdentifier ?? "DayDayHealth") + ".workout-refresh"
  }

  init() {
    UserDefaults.standard.removeObject(forKey: "wbFNOSLoginRetryAfter")
    #if (targetEnvironment(macCatalyst) || targetEnvironment(simulator)) && DEBUG
    if let address = LocalTestConfiguration.address {
      UserDefaults.standard.set(address, forKey: "wbServerURL")
    }
    #endif
    UNUserNotificationCenter.current().delegate = HealthNotificationDelegate.shared
    HealthNotificationDelegate.registerCategories()
  }
  var body: some Scene {
    WindowGroup {
      Group {
        if let credentials = store.forcedPasswordCredentials {
          NavigationStack {
            FNOSPasswordSettings(store: store, credentials: credentials, required: true)
          }
        } else {
          ContentView(store: store)
            .id(backup.revision)
        }
      }
      .environmentObject(backup)
      .environmentObject(digest)
      .environmentObject(healthArchive)
      .task(id: scenePhase) {
        healthArchive.setForeground(scenePhase == .active)
        guard scenePhase == .active else { return }
        await healthArchive.requestInitialAuthorization()
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(45)) } catch { return }
          healthArchive.refresh()
        }
      }
      .sheet(item: $digest.openedReport) { DailyDigestDetail(report: $0) }
      .task(id: scenePhase) {
        guard scenePhase == .active else { return }
        digest.loadLatest()
        while !Task.isCancelled {
          await digest.refresh(store: store)
          let delay = digest.foregroundRefreshDelay()
          do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
      }
      .task(id: scenePhase) {
        if scenePhase == .active { await backup.automaticBackup() }
      }
      #if !targetEnvironment(macCatalyst)
      .task(id: digest.scheduleRevision) { await scheduleWorkoutRefresh() }
      .task(id: healthArchive.enabled) { await scheduleWorkoutRefresh() }
      #endif
    }
    #if !targetEnvironment(macCatalyst)
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { Task { await scheduleWorkoutRefresh() } }
    }
    .backgroundTask(.appRefresh(workoutRefreshID)) {
      async let archive: Void = healthArchive.runBackgroundRefresh()
      await scheduleWorkoutRefresh()
      if await digest.enabled { await store.restoreCache() }
      async let report: Void = digest.refresh(store: store)
      async let training: Void = store.synchronizeTraining()
      async let meals: Void = store.uploadPendingMeals()
      async let snapshot: Void = backup.automaticBackup()
      await store.resumeSynchronization()
      await training
      await meals
      await snapshot
      await archive
      await report
      await scheduleWorkoutRefresh()
    }
    #endif
  }

  #if !targetEnvironment(macCatalyst)
  @MainActor
  private func scheduleWorkoutRefresh() async {
    guard store.forcedPasswordCredentials == nil else { return }
    let now = Date()
    let needsSync = healthArchive.enabled || store.healthEnabled || (store.trainingConfigured && !store.workoutAuthRequired)
      || store.hasPendingMealUploads || backup.isEnabled
    let syncDate = needsSync ? now.addingTimeInterval(3600) : nil
    guard let next = [syncDate, digest.nextRefresh(at: now)].compactMap({ $0 }).min() else { return }
    let scheduler = BGTaskScheduler.shared
    let pending = await scheduler.pendingTaskRequests()
    guard !pending.contains(where: {
      $0.identifier == workoutRefreshID && ($0.earliestBeginDate ?? .distantPast) <= next
    }) else { return }
    let request = BGAppRefreshTaskRequest(identifier: workoutRefreshID)
    request.earliestBeginDate = next
    try? scheduler.submit(request)
  }
  #endif
}

#if (targetEnvironment(macCatalyst) || targetEnvironment(simulator)) && DEBUG
enum LocalTestConfiguration {
  private static let config: [String: Any] = {
    let url = URL(fileURLWithPath: "/private/tmp/DayDayHealth-local-test/config.json")
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
  }()
  static var address: String? {
    if let value = ProcessInfo.processInfo.environment["WB_LOCAL_TEST_URL"] { return value }
    guard let port = config["port"] as? Int else { return nil }
    return "http://127.0.0.1:\(port)"
  }
  static var key: String? {
    ProcessInfo.processInfo.environment["WB_LOCAL_TEST_KEY"] ?? config["api_key"] as? String
  }
}
#endif
