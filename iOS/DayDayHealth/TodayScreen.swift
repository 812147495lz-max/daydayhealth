import SwiftUI

struct TodayScreen: View {
  @ObservedObject var store: HealthStore

  private var upcoming: [TaskItem] {
    store.tasks.filter { !$0.isTerminal }.prefix(3).map { $0 }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        header
        if !store.configured {
          HealthCard {
            StateMessage(
              symbol: "network.slash", title: "连接后端",
              detail: "先到「设置」连接你的后台。"
            )
          }
        } else if store.isLoading && !store.isLoaded {
          ProgressView("正在读取真实记录…")
            .frame(maxWidth: .infinity, minHeight: 180)
        } else {
          overview
          upcomingTasks
          dataNotice
        }
        if let error = store.errorMessage {
          StatusLine(message: error, isError: true)
            .accessibilityIdentifier("dashboardError")
        }
      }
      .padding(HealthTheme.spacing)
      .frame(maxWidth: 740)
      .frame(maxWidth: .infinity)
    }
    .background(HealthTheme.background)
    .navigationTitle("今日概览")
    .refreshable { await store.refresh() }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          Task { await store.refresh() }
        } label: {
          Image(systemName: "arrow.clockwise")
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel("刷新概览")
        .disabled(store.isLoading)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "water.waves")
        .font(.system(size: 29, weight: .medium))
        .foregroundStyle(HealthTheme.accent)
        .frame(width: 58, height: 58)
        .background(HealthTheme.subtle, in: Rectangle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("让训练有迹可循")
          .font(.title2.weight(.bold))
      }
      Spacer()
    }
  }

  private var overview: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle("本周进度")
      HealthCard {
        if let report = store.summary {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(report.recorded_sessions)")
              .font(.system(size: 44, weight: .bold, design: .rounded))
              .monospacedDigit()
            Text("次训练记录")
              .font(.subheadline)
              .foregroundStyle(HealthTheme.secondaryText)
            Spacer()
            Image(systemName: "figure.run")
              .font(.title2)
              .foregroundStyle(HealthTheme.accent)
              .accessibilityHidden(true)
          }
          .accessibilityElement(children: .combine)
          if let goal = report.goals.first {
            Divider().padding(.vertical, 6)
            HStack {
              Text(goal.title).font(.subheadline.weight(.medium))
              Spacer()
              Text(goal.observed.map { "已记录 \($0) / 目标 \(goal.target)" }
                ?? "待确认目标类型，暂不计算进度")
                .font(.subheadline.monospacedDigit())
            }
            if let observed = goal.observed {
              ProgressView(
                value: Double(min(observed, goal.target)),
                total: Double(max(goal.target, 1))
              )
              .tint(HealthTheme.accent)
              .accessibilityLabel("目标记录进度")
            }
          } else {
            Text("尚无已确认的活跃目标，可在任务页新增目标。")
              .font(.subheadline)
              .foregroundStyle(HealthTheme.secondaryText)
          }
        } else {
          StateMessage(
            symbol: "chart.bar.xaxis", title: "周报尚不可用",
            detail: "暂时无法读取本周进度，请稍后刷新。"
          )
        }
      }
    }
  }

  private var upcomingTasks: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle("接下来", caption: "待执行的任务")
      HealthCard {
        if !store.tasksAvailable {
          StateMessage(
            symbol: "exclamationmark.arrow.triangle.2.circlepath",
            title: "任务暂不可用",
            detail: "无法确认是否存在待执行任务；请检查连接并刷新。"
          )
        } else if upcoming.isEmpty {
          StateMessage(
            symbol: "checkmark.circle", title: "没有待执行任务",
            detail: "可以在「任务」中添加下一次健身安排。"
          )
        } else {
          VStack(spacing: 0) {
            ForEach(upcoming) { task in
              HStack(alignment: .top, spacing: 12) {
                Image(systemName: "calendar")
                  .foregroundStyle(HealthTheme.accent)
                  .frame(width: 24)
                  .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                  Text(task.title).font(.subheadline.weight(.semibold))
                  Text(task.dueDate, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(HealthTheme.secondaryText)
                }
                Spacer()
                Text(task.statusTitle)
                  .font(.caption)
                  .foregroundStyle(HealthTheme.secondaryText)
              }
              .padding(.vertical, 10)
              if task.id != upcoming.last?.id { Divider() }
            }
          }
        }
      }
    }
  }

  private var dataNotice: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let timestamp = store.lastUpdated {
        Label {
          Text("最近请求：\(timestamp.formatted(date: .abbreviated, time: .shortened))")
        } icon: {
          Image(systemName: "arrow.clockwise.circle")
        }
        .font(.footnote)
        .foregroundStyle(HealthTheme.secondaryText)
      }
      StatusLine(
        message: "记录数只代表目前可见的来源。",
        isError: false
      )
    }
  }
}
