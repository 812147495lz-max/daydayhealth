import SwiftUI
import Charts

/// The application shell only owns navigation and shared UI state.
struct ContentView: View {
  @ObservedObject var store: HealthStore
  @EnvironmentObject private var digest: DailyDigest
  @Environment(\.scenePhase) private var scenePhase

  @State private var selectedTab = 0

  var body: some View {
    TabView(selection: $selectedTab) {
      NavigationStack {
        ChatScreen(store: store)
      }
      .tabItem { Label("管家", systemImage: "bubble.left.and.bubble.right") }
      .tag(0)

      NavigationStack {
        WorkoutsScreen(store: store, reauthenticate: { selectedTab = 3 })
      }
      .tabItem { Label("训练与饮食", systemImage: "list.bullet.rectangle") }
      .tag(1)

      NavigationStack {
        HealthTrendsScreen(store: store)
      }
      .tabItem { Label("健康趋势", systemImage: "chart.xyaxis.line") }
      .tag(2)

      NavigationStack {
        SettingsScreen(store: store)
      }
      .tabItem { Label("设置", systemImage: "gearshape") }
      .tag(3)
    }
    .onChange(of: digest.topicRequest, initial: true) { previous, request in
      if request != nil || previous != nil { selectedTab = 0 }
    }
    .tint(HealthTheme.accent)
    .task {
      store.restoreCache()
      async let legacy: Void = store.refresh()
      await legacy
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      while !Task.isCancelled {
        await store.synchronizeTraining()
        do { try await Task.sleep(for: .seconds(60)) }
        catch { return }
      }
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      await store.uploadPendingMeals()
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      while !Task.isCancelled {
        await store.resumeSynchronization()
        do { try await Task.sleep(for: .seconds(3600)) }
        catch { return }
      }
    }
  }
}

struct TrendPoint: Codable, Identifiable, Sendable, Equatable {
  let epoch: Double
  let value: Double
  var sampleCount: Int? = nil
  var minimum: Double? = nil
  var maximum: Double? = nil
  var sampleID: UUID? = nil

  var id: Double { epoch }
  var chartID: String { sampleID?.uuidString ?? String(epoch) }
  var date: Date { Date(timeIntervalSince1970: epoch) }
}
