import SwiftUI

struct TasksScreen: View {
  @ObservedObject var store: HealthStore
  @State private var showingNewTask = false
  @State private var showingNewGoal = false
  @State private var postponing: TaskItem?
  @State private var newDate = Date().addingTimeInterval(3600)

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if let error = store.errorMessage {
          StatusLine(message: error, isError: true)
        }
        SectionTitle("健身目标", caption: "明确确认后才监督")
        if !store.configured || !store.goalsAvailable {
          HealthCard {
            StateMessage(
              symbol: "wifi.exclamationmark", title: "无法确认目标状态",
              detail: "请检查后台连接后刷新。"
            )
          }
        } else if store.goals.isEmpty {
          HealthCard {
            StateMessage(
              symbol: "target", title: "还没有目标",
              detail: "添加每周训练次数，系统会基于真实记录进行核查。"
            )
          }
        } else {
          ForEach(store.goals.filter { $0.active }) { goal in
            HealthCard {
              HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                  Text(goal.title).font(.headline)
                  Text("每周 \(goal.target_per_week) 次")
                    .foregroundStyle(HealthTheme.secondaryText)
                    .font(.subheadline)
                  if goal.goal_type == "unclassified" {
                    Text("统计规则待确认")
                      .foregroundStyle(.orange).font(.caption)
                  }
                }
                Spacer()
                Text(goal.confirmed ? "已确认" : "未确认")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(HealthTheme.accent)
              }
            }
          }
        }
        Button {
          showingNewGoal = true
        } label: {
          Label("新增训练目标", systemImage: "plus")
        }
        .buttonStyle(QuietActionStyle())
        .disabled(!store.configured || store.isMutating)

        SectionTitle("任务", caption: "修改后会自动保存")
        if !store.configured || !store.tasksAvailable {
          HealthCard {
            StateMessage(
              symbol: "wifi.exclamationmark", title: "无法确认任务状态",
              detail: "请检查后台连接后刷新。"
            )
          }
        } else if store.tasks.isEmpty {
          HealthCard {
            StateMessage(
              symbol: "calendar.badge.plus", title: "暂无任务",
              detail: "添加时间明确的训练或生活任务。"
            )
          }
        }
        ForEach(store.tasks) { task in
          HealthCard {
            VStack(alignment: .leading, spacing: 12) {
              HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                  Text(task.title).font(.headline)
                  Text(task.dueDate, format: .dateTime.year().month().day().hour().minute())
                    .font(.subheadline)
                    .foregroundStyle(HealthTheme.secondaryText)
                }
                Spacer(minLength: 12)
                Text(task.statusTitle)
                  .font(.caption.weight(.medium))
                  .foregroundStyle(HealthTheme.accent)
              }
              if !task.isTerminal {
                HStack(spacing: 8) {
                  Button("完成") {
                    Task { _ = await store.updateTask(task, action: "complete") }
                  }
                  .buttonStyle(QuietActionStyle())
                  Button("延期") {
                    newDate = max(Date().addingTimeInterval(600), task.dueDate)
                    postponing = task
                  }
                  .buttonStyle(QuietActionStyle())
                  Button("跳过") {
                    Task { _ = await store.updateTask(task, action: "skip") }
                  }
                  .buttonStyle(QuietActionStyle())
                }
                .disabled(store.isMutating)
              }
            }
          }
        }
      }
      .padding(HealthTheme.spacing)
      .frame(maxWidth: 740)
      .frame(maxWidth: .infinity)
    }
    .background(HealthTheme.background)
    .navigationTitle("任务与目标")
    .refreshable { await store.refresh() }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button { showingNewTask = true } label: {
          Image(systemName: "plus").frame(width: 44, height: 44)
        }
        .accessibilityLabel("添加任务")
        .disabled(!store.configured || store.isMutating)
      }
    }
    .sheet(isPresented: $showingNewTask) {
      NewTaskSheet(store: store)
    }
    .sheet(isPresented: $showingNewGoal) {
      NewGoalSheet(store: store)
    }
    .sheet(item: $postponing) { task in
      NavigationStack {
        Form {
          DatePicker("新执行时间", selection: $newDate, in: Date()...)
          Button("确认延期") {
            Task {
              if await store.updateTask(task, action: "postpone", date: newDate) {
                postponing = nil
              }
            }
          }
          .disabled(store.isMutating)
        }
        .navigationTitle("延期任务")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("取消") { postponing = nil }
          }
        }
      }
      .presentationDetents([.medium])
    }
  }
}

private struct NewTaskSheet: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var store: HealthStore
  @State private var title = ""
  @State private var dueDate = Date().addingTimeInterval(3600)
  @State private var requestID = UUID().uuidString

  var body: some View {
    NavigationStack {
      Form {
        Section("任务信息") {
          TextField("例如：去健身房训练", text: $title)
            .submitLabel(.done)
          DatePicker("执行时间", selection: $dueDate, in: Date()...)
        }
        Section {
          Text("请在设置中开启通知权限，以便接收提醒。")
            .font(.footnote)
        }
      }
      .navigationTitle("添加任务")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            Task {
              if await store.createTask(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                date: dueDate, requestID: requestID
              ) { dismiss() }
            }
          }
          .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            store.isMutating)
        }
      }
    }
  }
}

private struct NewGoalSheet: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var store: HealthStore
  @State private var title = "每周健身"
  @State private var target = 3
  @State private var goalType = "strength_sessions"

  var body: some View {
    NavigationStack {
      Form {
        TextField("目标名称", text: $title)
        Stepper("每周 \(target) 次", value: $target, in: 1...14)
        Picker("统计类型", selection: $goalType) {
          Text("力量训练").tag("strength_sessions")
          Text("跑步").tag("running_sessions")
          Text("所有训练").tag("all_workouts")
          Text("睡眠记录").tag("sleep_entries")
        }
        Text("保存后，天天健康会按这个目标记录你的进度。")
          .font(.footnote)
          .foregroundStyle(HealthTheme.secondaryText)
      }
      .navigationTitle("添加目标")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("确认目标") {
            Task {
              if await store.createGoal(title: title, target: target, type: goalType) {
                dismiss()
              }
            }
          }
          .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            store.isMutating)
        }
      }
    }
  }
}
